//! Lightweight local-audio metadata probe for import-time honesty.
//!
//! Reads title / artist / album / duration from the file itself so the
//! library does not wait for the first play. Unsupported or missing
//! files return empty fields — callers keep the filename fallback.
//!
//! Formats covered (best-effort, no external tools):
//!   - ID3v2.3 / ID3v2.4 (mp3, and tags prepended to other containers)
//!   - FLAC Vorbis comments
//!   - MP4/M4A `ilst` atoms (+ `mdhd` duration)
//!   - Ogg Vorbis identification + comment packets (duration left 0)

const std = @import("std");

pub const Probe = struct {
    title: []const u8 = "",
    artist: []const u8 = "",
    album: []const u8 = "",
    duration_ms: u32 = 0,
};

pub const ProbeBuffers = struct {
    title: [128]u8 = undefined,
    title_len: usize = 0,
    artist: [128]u8 = undefined,
    artist_len: usize = 0,
    album: [128]u8 = undefined,
    album_len: usize = 0,
    duration_ms: u32 = 0,

    pub fn asProbe(self: *const ProbeBuffers) Probe {
        return .{
            .title = self.title[0..self.title_len],
            .artist = self.artist[0..self.artist_len],
            .album = self.album[0..self.album_len],
            .duration_ms = self.duration_ms,
        };
    }

    fn setTitle(self: *ProbeBuffers, value: []const u8) void {
        const kept = utf8Prefix(value, self.title.len);
        @memcpy(self.title[0..kept.len], kept);
        self.title_len = kept.len;
    }

    fn setArtist(self: *ProbeBuffers, value: []const u8) void {
        const kept = utf8Prefix(value, self.artist.len);
        @memcpy(self.artist[0..kept.len], kept);
        self.artist_len = kept.len;
    }

    fn setAlbum(self: *ProbeBuffers, value: []const u8) void {
        const kept = utf8Prefix(value, self.album.len);
        @memcpy(self.album[0..kept.len], kept);
        self.album_len = kept.len;
    }
};

/// The longest prefix of `value` that fits `max` bytes without splitting
/// a UTF-8 sequence. A byte cut mid-character (a long CJK tag hitting a
/// 128-byte field) leaves an invalid tail that renders as tofu.
pub fn utf8Prefix(value: []const u8, max: usize) []const u8 {
    if (value.len <= max) return value;
    var end = max;
    while (end > 0 and (value[end] & 0xC0) == 0x80) end -= 1;
    return value[0..end];
}

/// Probe an absolute audio path. Missing / unreadable files yield an
/// empty probe (no error) so import stays best-effort.
pub fn probeFile(path: []const u8) ProbeBuffers {
    var out: ProbeBuffers = .{};
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var file = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{}) catch return out
    else
        std.Io.Dir.cwd().openFile(io, path, .{}) catch return out;
    defer file.close(io);

    var header: [64 * 1024]u8 = undefined;
    const n = file.readPositionalAll(io, &header, 0) catch return out;
    if (n == 0) return out;
    const bytes = header[0..n];

    const file_size: u64 = (file.stat(io) catch return out).size;
    const has_id3 = bytes.len >= 10 and std.mem.eql(u8, bytes[0..3], "ID3");
    // Where the audio starts: after the ID3v2 tag (and its footer, v2.4).
    const audio_start: u64 = if (has_id3)
        10 + synchsafe(bytes[6..10]) + @as(u64, if (bytes[5] & 0x10 != 0) 10 else 0)
    else
        0;

    var mp4 = false;
    if (has_id3) {
        parseId3(bytes, &out);
    } else if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "fLaC")) {
        parseFlac(bytes, &out);
    } else if (bytes.len >= 8 and std.mem.eql(u8, bytes[4..8], "ftyp")) {
        mp4 = true;
        parseMp4(bytes, &out);
    } else if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "OggS")) {
        parseOggVorbisComments(bytes, &out);
    } else if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WAVE")) {
        out.duration_ms = wavDurationMs(bytes);
    }

    // Encoders that write the index last (ffmpeg's default) put `moov`
    // after a large `mdat`: the header window holds neither the tags nor
    // the duration. Walk the top-level atoms on disk to reach it.
    if (mp4 and (out.duration_ms == 0 or out.title_len == 0)) walkMp4File(file, io, file_size, &out);

    var has_id3v1 = false;
    if (out.title_len == 0 and out.artist_len == 0) {
        has_id3v1 = parseId3v1(file, io, &out) catch false;
    }

    // MP3 carries no length field of its own; read it off the first frame.
    if (out.duration_ms == 0 and !mp4) {
        const tail: u64 = if (has_id3v1) 128 else 0;
        out.duration_ms = mp3DurationMs(file, io, audio_start, file_size -| tail);
    }
    return out;
}

fn parseId3(bytes: []const u8, out: *ProbeBuffers) void {
    if (bytes.len < 10) return;
    const major = bytes[3];
    if (major < 2 or major > 4) return;
    const tag_size = synchsafe(bytes[6..10]);
    if (tag_size == 0) return;
    // Embedded artwork often makes the declared tag larger than the
    // probe window. Parse whatever frames fit in the buffer — TIT2/TPE1
    // almost always precede APIC — instead of bailing on an incomplete tag.
    var offset: usize = 10;
    // Skip extended header (v2.3/v2.4 flag bit 6).
    if (bytes[5] & 0x40 != 0) {
        if (offset + 4 > bytes.len) return;
        const ext = if (major == 4) synchsafe(bytes[offset .. offset + 4]) else readU32(bytes[offset .. offset + 4]);
        offset += @min(ext, bytes.len - offset);
    }
    const end = @min(bytes.len, 10 + tag_size);
    while (offset + 10 <= end) {
        const id = bytes[offset .. offset + 4];
        if (id[0] == 0) break;
        const frame_size: usize = if (major == 4)
            synchsafe(bytes[offset + 4 .. offset + 8])
        else
            readU32(bytes[offset + 4 .. offset + 8]);
        offset += 10;
        if (frame_size == 0 or offset + frame_size > end) break;
        const data = bytes[offset .. offset + frame_size];
        offset += frame_size;
        if (std.mem.eql(u8, id, "TIT2")) {
            if (decodeTextFrame(data)) |text| out.setTitle(text);
        } else if (std.mem.eql(u8, id, "TPE1")) {
            if (decodeTextFrame(data)) |text| out.setArtist(text);
        } else if (std.mem.eql(u8, id, "TALB")) {
            if (decodeTextFrame(data)) |text| out.setAlbum(text);
        } else if (std.mem.eql(u8, id, "TLEN")) {
            if (decodeTextFrame(data)) |text| {
                const ms = std.fmt.parseInt(u32, text, 10) catch 0;
                if (ms > 0) out.duration_ms = ms;
            }
        }
    }
}

/// True when the file ends in an ID3v1 tag (whether or not it filled a field).
fn parseId3v1(file: std.Io.File, io: std.Io, out: *ProbeBuffers) !bool {
    const info = try file.stat(io);
    if (info.size < 128) return false;
    var tag: [128]u8 = undefined;
    const n = try file.readPositionalAll(io, &tag, info.size - 128);
    if (n < 128) return false;
    if (!std.mem.eql(u8, tag[0..3], "TAG")) return false;
    // ID3v1 has no encoding byte: it is whatever the ripper's code page
    // was — GBK on most Chinese rips, Latin-1 in the West.
    if (out.title_len == 0) out.setTitle(decodeLegacy(trimId3v1(tag[3..33])));
    if (out.artist_len == 0) out.setArtist(decodeLegacy(trimId3v1(tag[33..63])));
    if (out.album_len == 0) out.setAlbum(decodeLegacy(trimId3v1(tag[63..93])));
    return true;
}

fn trimId3v1(raw: []const u8) []const u8 {
    var end = raw.len;
    while (end > 0 and (raw[end - 1] == 0 or raw[end - 1] == ' ')) end -= 1;
    return raw[0..end];
}

fn parseFlac(bytes: []const u8, out: *ProbeBuffers) void {
    var offset: usize = 4;
    while (offset + 4 <= bytes.len) {
        const block_header = bytes[offset];
        const last = (block_header & 0x80) != 0;
        const kind = block_header & 0x7f;
        const size = readU24(bytes[offset + 1 .. offset + 4]);
        offset += 4;
        if (offset + size > bytes.len) break;
        const body = bytes[offset .. offset + size];
        offset += size;
        if (kind == 4) {
            parseVorbisComment(body, out);
        } else if (kind == 0 and body.len >= 18) {
            // STREAMINFO: total samples is 36 bits ending at byte 13..17.
            const sample_rate = (@as(u32, body[10]) << 12) | (@as(u32, body[11]) << 4) | (@as(u32, body[12]) >> 4);
            const total_hi = body[13] & 0x0f;
            const total = (@as(u64, total_hi) << 32) |
                (@as(u64, body[14]) << 24) |
                (@as(u64, body[15]) << 16) |
                (@as(u64, body[16]) << 8) |
                @as(u64, body[17]);
            if (sample_rate > 0 and total > 0) {
                out.duration_ms = @intCast(@min(total * 1000 / sample_rate, std.math.maxInt(u32)));
            }
        }
        if (last) break;
    }
}

fn parseOggVorbisComments(bytes: []const u8, out: *ProbeBuffers) void {
    // Scan the first few Ogg pages for a Vorbis comment packet (type 0x03).
    var offset: usize = 0;
    var pages: usize = 0;
    while (offset + 27 <= bytes.len and pages < 8) : (pages += 1) {
        if (!std.mem.eql(u8, bytes[offset .. offset + 4], "OggS")) break;
        const nsegs = bytes[offset + 26];
        const seg_table = offset + 27;
        if (seg_table + nsegs > bytes.len) break;
        var packet_size: usize = 0;
        var i: usize = 0;
        while (i < nsegs) : (i += 1) packet_size += bytes[seg_table + i];
        const packet_off = seg_table + nsegs;
        if (packet_off + packet_size > bytes.len) break;
        const packet = bytes[packet_off .. packet_off + packet_size];
        if (packet.len > 7 and packet[0] == 3 and std.mem.eql(u8, packet[1..7], "vorbis")) {
            parseVorbisComment(packet[7..], out);
            return;
        }
        offset = packet_off + packet_size;
    }
}

fn parseVorbisComment(body: []const u8, out: *ProbeBuffers) void {
    if (body.len < 8) return;
    var offset: usize = 0;
    const vendor_len = readU32Le(body[offset .. offset + 4]);
    offset += 4;
    if (offset + vendor_len > body.len) return;
    offset += vendor_len;
    if (offset + 4 > body.len) return;
    const count = readU32Le(body[offset .. offset + 4]);
    offset += 4;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (offset + 4 > body.len) return;
        const len = readU32Le(body[offset .. offset + 4]);
        offset += 4;
        if (offset + len > body.len) return;
        const entry = body[offset .. offset + len];
        offset += len;
        if (std.ascii.startsWithIgnoreCase(entry, "TITLE=")) {
            out.setTitle(entry["TITLE=".len..]);
        } else if (std.ascii.startsWithIgnoreCase(entry, "ARTIST=")) {
            out.setArtist(entry["ARTIST=".len..]);
        } else if (std.ascii.startsWithIgnoreCase(entry, "ALBUM=")) {
            out.setAlbum(entry["ALBUM=".len..]);
        }
    }
}

fn parseMp4(bytes: []const u8, out: *ProbeBuffers) void {
    walkMp4(bytes, 0, bytes.len, out, 0);
}

fn walkMp4(bytes: []const u8, start: usize, end: usize, out: *ProbeBuffers, depth: u8) void {
    if (depth > 12) return;
    var offset = start;
    while (offset + 8 <= end) {
        var size: usize = readU32(bytes[offset .. offset + 4]);
        const typ = bytes[offset + 4 .. offset + 8];
        var header: usize = 8;
        if (size == 1) {
            if (offset + 16 > end) return;
            size = @intCast(readU64(bytes[offset + 8 .. offset + 16]));
            header = 16;
        } else if (size == 0) {
            size = end - offset;
        }
        if (size < header or offset + size > end) return;
        const body_start = offset + header;
        const body_end = offset + size;
        const body = bytes[body_start..body_end];
        // Tag keys first: `isContainer` also matches them, and walking
        // into one skips the `data` atom that holds the text.
        if (std.mem.eql(u8, typ, "\xA9nam")) {
            if (decodeIlstData(body)) |text| out.setTitle(text);
        } else if (std.mem.eql(u8, typ, "\xA9ART")) {
            if (decodeIlstData(body)) |text| out.setArtist(text);
        } else if (std.mem.eql(u8, typ, "\xA9alb")) {
            if (decodeIlstData(body)) |text| out.setAlbum(text);
        } else if (isContainer(typ)) {
            const child = if (std.mem.eql(u8, typ, "meta") and body.len >= 4) body[4..] else body;
            walkMp4(child, 0, child.len, out, depth + 1);
        } else if (std.mem.eql(u8, typ, "mdhd")) {
            parseMdhd(body, out);
        }
        offset += size;
    }
}

fn isContainer(typ: []const u8) bool {
    const containers = [_][]const u8{
        "moov", "trak", "mdia", "minf", "stbl", "udta", "meta", "ilst", "----",
    };
    for (containers) |c| {
        if (std.mem.eql(u8, typ, c)) return true;
    }
    // ilst children are themselves containers around a `data` atom.
    if (typ.len == 4 and (typ[0] == 0xA9 or std.ascii.isAlphanumeric(typ[0]))) {
        // Treat unknown 4cc under ilst as containers when they look like keys.
        return std.mem.eql(u8, typ, "\xA9nam") or std.mem.eql(u8, typ, "\xA9ART") or
            std.mem.eql(u8, typ, "\xA9alb") or std.mem.eql(u8, typ, "trkn");
    }
    return false;
}

fn parseMdhd(body: []const u8, out: *ProbeBuffers) void {
    if (body.len < 20) return;
    const version = body[0];
    if (version == 0 and body.len >= 24) {
        const timescale = readU32(body[12..16]);
        const duration = readU32(body[16..20]);
        if (timescale > 0) {
            out.duration_ms = @intCast(@min(@as(u64, duration) * 1000 / timescale, std.math.maxInt(u32)));
        }
    } else if (version == 1 and body.len >= 36) {
        const timescale = readU32(body[20..24]);
        const duration = readU64(body[24..32]);
        if (timescale > 0) {
            out.duration_ms = @intCast(@min(duration * 1000 / timescale, std.math.maxInt(u32)));
        }
    }
}

fn decodeIlstData(body: []const u8) ?[]const u8 {
    // Either the key atom body starts with a nested `data` atom, or the
    // body IS the data payload already.
    if (body.len >= 16 and std.mem.eql(u8, body[4..8], "data")) {
        const payload = body[16..];
        return trimUtf8(payload);
    }
    if (body.len >= 8 and std.mem.eql(u8, body[4..8], "data") == false) {
        // Walk for nested data.
        var offset: usize = 0;
        while (offset + 8 <= body.len) {
            const size = readU32(body[offset .. offset + 4]);
            if (size < 8 or offset + size > body.len) break;
            if (std.mem.eql(u8, body[offset + 4 .. offset + 8], "data") and size >= 16) {
                return trimUtf8(body[offset + 16 .. offset + size]);
            }
            offset += size;
        }
    }
    return null;
}

fn decodeTextFrame(data: []const u8) ?[]const u8 {
    if (data.len < 2) return null;
    const encoding = data[0];
    const payload = data[1..];
    return switch (encoding) {
        0 => decodeLegacy(payload), // "ISO-8859-1" — in practice also GBK
        3 => trimUtf8(payload), // UTF-8
        1, 2 => trimUtf16(payload, encoding == 2), // UTF-16 with/without BOM
        else => trimUtf8(payload),
    };
}

fn trimUtf8(raw: []const u8) []const u8 {
    var start: usize = 0;
    var end = raw.len;
    while (start < end and (raw[start] == 0 or raw[start] == ' ')) start += 1;
    while (end > start and (raw[end - 1] == 0 or raw[end - 1] == ' ')) end -= 1;
    // Strip a trailing UTF-16 NUL pair leftover if someone passed BOM text.
    return raw[start..end];
}

fn trimUtf16(raw: []const u8, be_forced: bool) ?[]const u8 {
    // Convert into a scratch on the caller's ProbeBuffers — use a
    // threadlocal static so Probe stays allocation-free.
    const scratch = struct {
        threadlocal var buf: [128]u8 = undefined;
    };
    if (raw.len < 2) return null;
    var offset: usize = 0;
    var big_endian = be_forced;
    if (!be_forced and raw.len >= 2) {
        if (raw[0] == 0xFE and raw[1] == 0xFF) {
            big_endian = true;
            offset = 2;
        } else if (raw[0] == 0xFF and raw[1] == 0xFE) {
            big_endian = false;
            offset = 2;
        }
    }
    var out_len: usize = 0;
    while (offset + 1 < raw.len and out_len + 4 < scratch.buf.len) {
        var code: u21 = readUnit(raw[offset .. offset + 2], big_endian);
        offset += 2;
        if (code == 0) break;
        // Characters outside the BMP (emoji, rare CJK) arrive as a
        // surrogate pair; encoding each half alone yields invalid UTF-8.
        if (code >= 0xD800 and code <= 0xDBFF and offset + 1 < raw.len) {
            const low = readUnit(raw[offset .. offset + 2], big_endian);
            if (low >= 0xDC00 and low <= 0xDFFF) {
                offset += 2;
                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
            }
        }
        if (code >= 0xD800 and code <= 0xDFFF) code = 0xFFFD;
        if (code >= 0x10000) {
            scratch.buf[out_len] = @intCast(0xF0 | (code >> 18));
            scratch.buf[out_len + 1] = @intCast(0x80 | ((code >> 12) & 0x3F));
            scratch.buf[out_len + 2] = @intCast(0x80 | ((code >> 6) & 0x3F));
            scratch.buf[out_len + 3] = @intCast(0x80 | (code & 0x3F));
            out_len += 4;
            continue;
        }
        if (code < 0x80) {
            scratch.buf[out_len] = @intCast(code);
            out_len += 1;
        } else if (code < 0x800) {
            scratch.buf[out_len] = @intCast(0xC0 | (code >> 6));
            scratch.buf[out_len + 1] = @intCast(0x80 | (code & 0x3F));
            out_len += 2;
        } else {
            scratch.buf[out_len] = @intCast(0xE0 | (code >> 12));
            scratch.buf[out_len + 1] = @intCast(0x80 | ((code >> 6) & 0x3F));
            scratch.buf[out_len + 2] = @intCast(0x80 | (code & 0x3F));
            out_len += 3;
        }
    }
    return scratch.buf[0..out_len];
}

fn readUnit(bytes: []const u8, big_endian: bool) u21 {
    return if (big_endian)
        (@as(u21, bytes[0]) << 8) | bytes[1]
    else
        (@as(u21, bytes[1]) << 8) | bytes[0];
}

// ------------------------------------------------------- legacy encodings

/// Text a tag labels ISO-8859-1 (ID3v2 encoding 0, all of ID3v1). Three
/// things hide behind that label in real libraries, tried in order:
///   1. UTF-8 (some taggers write it regardless of the flag),
///   2. GBK — Chinese rippers wrote the system code page; every high
///      byte then pairs as lead 0x81–0xFE + trail 0x40–0xFE,
///   3. genuine Latin-1 ("Beyoncé").
/// Copying the bytes through unchanged (the old behaviour) stored invalid
/// UTF-8, which renders as garbage or tofu.
fn decodeLegacy(raw: []const u8) []const u8 {
    const text = trimUtf8(raw);
    if (std.unicode.utf8ValidateSlice(text)) return text;
    const scratch = struct {
        threadlocal var buf: [256]u8 = undefined;
    };
    if (gbkPrefixLen(text)) |gbk_len| {
        if (gb18030ToUtf8(text[0..gbk_len], &scratch.buf)) |decoded| return decoded;
    }
    return latin1ToUtf8(text, &scratch.buf);
}

/// The length of `text` that reads as GBK, or null when it does not.
/// A fixed-width ID3v1 field can cut the last character in half, so one
/// dangling lead byte at the very end is dropped rather than disqualifying.
fn gbkPrefixLen(text: []const u8) ?usize {
    var i: usize = 0;
    var saw_pair = false;
    while (i < text.len) {
        const b = text[i];
        if (b < 0x80) {
            i += 1;
            continue;
        }
        if (b < 0x81 or b == 0xFF) return null;
        if (i + 1 == text.len) return if (saw_pair) i else null;
        const trail = text[i + 1];
        if (trail < 0x40 or trail == 0x7F or trail == 0xFF) return null;
        saw_pair = true;
        i += 2;
    }
    return if (saw_pair) text.len else null;
}

fn latin1ToUtf8(text: []const u8, buf: []u8) []const u8 {
    var len: usize = 0;
    for (text) |b| {
        if (len + 2 > buf.len) break;
        if (b < 0x80) {
            buf[len] = b;
            len += 1;
        } else {
            buf[len] = 0xC0 | (b >> 6);
            buf[len + 1] = 0x80 | (b & 0x3F);
            len += 2;
        }
    }
    return buf[0..len];
}

/// GB18030 (a superset of GBK) → UTF-8 through CoreFoundation, loaded the
/// same no-link way `locale.zig` reads the preferred languages. Null off
/// macOS or when CoreFoundation rejects the bytes.
fn gb18030ToUtf8(text: []const u8, buf: []u8) ?[]const u8 {
    if (comptime @import("builtin").os.tag != .macos) return null;
    const CFTypeRef = ?*anyopaque;
    const encoding_gb18030: u32 = 0x0632; // kCFStringEncodingGB_18030_2000
    const encoding_utf8: u32 = 0x08000100;
    var lib = std.DynLib.open("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation") catch return null;
    defer lib.close();
    const create = lib.lookup(*const fn (CFTypeRef, [*]const u8, isize, u32, bool) callconv(.c) CFTypeRef, "CFStringCreateWithBytes") orelse return null;
    const get_c = lib.lookup(*const fn (CFTypeRef, [*]u8, isize, u32) callconv(.c) bool, "CFStringGetCString") orelse return null;
    const release = lib.lookup(*const fn (CFTypeRef) callconv(.c) void, "CFRelease") orelse return null;
    const string = create(null, text.ptr, @intCast(text.len), encoding_gb18030, false) orelse return null;
    defer release(string);
    if (!get_c(string, buf.ptr, @intCast(buf.len), encoding_utf8)) return null;
    return std.mem.sliceTo(buf, 0);
}

// -------------------------------------------------------------- durations

/// MPEG audio (mp3) duration from the first frame after the ID3v2 tag:
/// the Xing/Info or VBRI frame count when the encoder wrote one (every
/// LAME/ffmpeg file does, VBR or not), else the constant-bitrate estimate
/// from the audio byte length. 0 when no Layer III frame is found.
fn mp3DurationMs(file: std.Io.File, io: std.Io, audio_start: u64, audio_end: u64) u32 {
    if (audio_end <= audio_start) return 0;
    var window: [4096]u8 = undefined;
    const n = file.readPositionalAll(io, &window, audio_start) catch return 0;
    return mp3DurationFromWindow(window[0..n], audio_end - audio_start);
}

fn mp3DurationFromWindow(bytes: []const u8, audio_len: u64) u32 {
    var i: usize = 0;
    while (i + 4 <= bytes.len) : (i += 1) {
        if (bytes[i] != 0xFF or bytes[i + 1] & 0xE0 != 0xE0) continue;
        const frame = MpegFrame.parse(bytes[i .. i + 4]) orelse continue;
        // A lone 0xFFE sync is common in random data: trust it only when
        // the next frame header follows where this frame says it ends.
        const next = i + frame.length(bytes[i + 2]);
        if (next + 4 > bytes.len or MpegFrame.parse(bytes[next .. next + 4]) == null or bytes[next] != 0xFF) continue;
        // Xing/Info sits after the side information; VBRI at a fixed 32.
        const side: usize = if (frame.mpeg1)
            (if (frame.mono) 17 else 32)
        else
            (if (frame.mono) 9 else 17);
        const xing = i + 4 + side;
        if (xing + 12 <= bytes.len and (std.mem.eql(u8, bytes[xing .. xing + 4], "Xing") or std.mem.eql(u8, bytes[xing .. xing + 4], "Info"))) {
            const flags = readU32(bytes[xing + 4 .. xing + 8]);
            if (flags & 1 != 0) return frame.framesToMs(readU32(bytes[xing + 8 .. xing + 12]));
        }
        const vbri = i + 4 + 32;
        if (vbri + 18 <= bytes.len and std.mem.eql(u8, bytes[vbri .. vbri + 4], "VBRI")) {
            return frame.framesToMs(readU32(bytes[vbri + 14 .. vbri + 18]));
        }
        const audio_bytes = audio_len -| i;
        return @intCast(@min(audio_bytes * 8 / frame.bitrate_kbps, std.math.maxInt(u32)));
    }
    return 0;
}

const MpegFrame = struct {
    mpeg1: bool,
    mono: bool,
    sample_rate: u32,
    bitrate_kbps: u32,

    fn parse(h: []const u8) ?MpegFrame {
        const version = (h[1] >> 3) & 0x3; // 0 = 2.5, 2 = 2, 3 = 1
        const layer = (h[1] >> 1) & 0x3; // 1 = Layer III
        if (version == 1 or layer != 1) return null;
        const bitrate_index = h[2] >> 4;
        const rate_index = (h[2] >> 2) & 0x3;
        if (bitrate_index == 0 or bitrate_index == 15 or rate_index == 3) return null;
        const mpeg1 = version == 3;
        const v1_rates = [_]u32{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320 };
        const v2_rates = [_]u32{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 };
        const base_rates = [_]u32{ 44100, 48000, 32000 };
        const divisor: u32 = switch (version) {
            3 => 1,
            2 => 2,
            else => 4,
        };
        return .{
            .mpeg1 = mpeg1,
            .mono = (h[3] >> 6) == 3,
            .sample_rate = base_rates[rate_index] / divisor,
            .bitrate_kbps = if (mpeg1) v1_rates[bitrate_index] else v2_rates[bitrate_index],
        };
    }

    /// Bytes in this frame, header included (Layer III).
    fn length(frame: MpegFrame, flags_byte: u8) usize {
        const padding: usize = (flags_byte >> 1) & 1;
        const coefficient: usize = if (frame.mpeg1) 144 else 72;
        return coefficient * frame.bitrate_kbps * 1000 / frame.sample_rate + padding;
    }

    fn framesToMs(frame: MpegFrame, frames: usize) u32 {
        const samples_per_frame: u64 = if (frame.mpeg1) 1152 else 576;
        return @intCast(@min(@as(u64, frames) * samples_per_frame * 1000 / frame.sample_rate, std.math.maxInt(u32)));
    }
};

/// PCM WAV: the `data` chunk length over the `fmt ` byte rate.
fn wavDurationMs(bytes: []const u8) u32 {
    var offset: usize = 12;
    var byte_rate: u64 = 0;
    while (offset + 8 <= bytes.len) {
        const id = bytes[offset .. offset + 4];
        const size: u64 = readU32Le(bytes[offset + 4 .. offset + 8]);
        if (std.mem.eql(u8, id, "fmt ") and offset + 20 <= bytes.len) {
            byte_rate = readU32Le(bytes[offset + 16 .. offset + 20]);
        } else if (std.mem.eql(u8, id, "data")) {
            if (byte_rate == 0) return 0;
            return @intCast(@min(size * 1000 / byte_rate, std.math.maxInt(u32)));
        }
        offset += 8 + @as(usize, @intCast(size + (size & 1)));
    }
    return 0;
}

/// Top-level MP4 atoms read from disk until `moov`, which is then walked
/// in memory. Capped at 8 MiB: a moov that large is an hours-long video.
fn walkMp4File(file: std.Io.File, io: std.Io, file_size: u64, out: *ProbeBuffers) void {
    var offset: u64 = 0;
    while (offset + 8 <= file_size) {
        var head: [16]u8 = undefined;
        const n = file.readPositionalAll(io, &head, offset) catch return;
        if (n < 8) return;
        var size: u64 = readU32(head[0..4]);
        if (size == 1) {
            if (n < 16) return;
            size = readU64(head[8..16]);
        } else if (size == 0) {
            size = file_size - offset;
        }
        if (size < 8) return;
        if (std.mem.eql(u8, head[4..8], "moov")) {
            if (size > 8 * 1024 * 1024) return;
            const buf = std.heap.page_allocator.alloc(u8, @intCast(size)) catch return;
            defer std.heap.page_allocator.free(buf);
            const got = file.readPositionalAll(io, buf, offset) catch return;
            walkMp4(buf[0..got], 0, got, out, 0);
            return;
        }
        offset += size;
    }
}

fn synchsafe(bytes: []const u8) usize {
    return (@as(usize, bytes[0] & 0x7f) << 21) |
        (@as(usize, bytes[1] & 0x7f) << 14) |
        (@as(usize, bytes[2] & 0x7f) << 7) |
        @as(usize, bytes[3] & 0x7f);
}

fn readU24(bytes: []const u8) usize {
    return (@as(usize, bytes[0]) << 16) | (@as(usize, bytes[1]) << 8) | bytes[2];
}

fn readU32(bytes: []const u8) usize {
    return (@as(usize, bytes[0]) << 24) | (@as(usize, bytes[1]) << 16) |
        (@as(usize, bytes[2]) << 8) | bytes[3];
}

fn readU32Le(bytes: []const u8) usize {
    return @as(usize, bytes[0]) | (@as(usize, bytes[1]) << 8) |
        (@as(usize, bytes[2]) << 16) | (@as(usize, bytes[3]) << 24);
}

fn readU64(bytes: []const u8) u64 {
    return (@as(u64, bytes[0]) << 56) | (@as(u64, bytes[1]) << 48) |
        (@as(u64, bytes[2]) << 40) | (@as(u64, bytes[3]) << 32) |
        (@as(u64, bytes[4]) << 24) | (@as(u64, bytes[5]) << 16) |
        (@as(u64, bytes[6]) << 8) | @as(u64, bytes[7]);
}

test "id3v2 title artist album" {
    var body: [256]u8 = undefined;
    var len: usize = 0;
    const frames = [_]struct { id: []const u8, text: []const u8 }{
        .{ .id = "TIT2", .text = "Hello Title" },
        .{ .id = "TPE1", .text = "Some Artist" },
        .{ .id = "TALB", .text = "Some Album" },
        .{ .id = "TLEN", .text = "125000" },
    };
    for (frames) |frame| {
        const payload_len = 1 + frame.text.len;
        @memcpy(body[len .. len + 4], frame.id);
        len += 4;
        body[len] = 0;
        body[len + 1] = 0;
        body[len + 2] = 0;
        body[len + 3] = @intCast(payload_len);
        len += 4;
        body[len] = 0;
        body[len + 1] = 0;
        len += 2;
        body[len] = 0; // encoding
        len += 1;
        @memcpy(body[len .. len + frame.text.len], frame.text);
        len += frame.text.len;
    }
    var tag: [512]u8 = undefined;
    @memcpy(tag[0..3], "ID3");
    tag[3] = 3;
    tag[4] = 0;
    tag[5] = 0;
    const ss = len;
    tag[6] = @intCast((ss >> 21) & 0x7f);
    tag[7] = @intCast((ss >> 14) & 0x7f);
    tag[8] = @intCast((ss >> 7) & 0x7f);
    tag[9] = @intCast(ss & 0x7f);
    @memcpy(tag[10 .. 10 + len], body[0..len]);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "zig-out/metadata-id3-test.mp3";
    {
        var payload: [1024]u8 = undefined;
        @memcpy(payload[0 .. 10 + len], tag[0 .. 10 + len]);
        const pad = [_]u8{ 0xff, 0xfb, 0x90, 0x00 } ** 32;
        @memcpy(payload[10 + len .. 10 + len + pad.len], &pad);
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = payload[0 .. 10 + len + pad.len],
        });
    }
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const probed = probeFile(path);
    try std.testing.expectEqualStrings("Hello Title", probed.title[0..probed.title_len]);
    try std.testing.expectEqualStrings("Some Artist", probed.artist[0..probed.artist_len]);
    try std.testing.expectEqualStrings("Some Album", probed.album[0..probed.album_len]);
    try std.testing.expectEqual(@as(u32, 125000), probed.duration_ms);
}

test "missing file yields empty probe" {
    const probed = probeFile("/tmp/wellmusic-definitely-missing-track.mp3");
    try std.testing.expectEqual(@as(usize, 0), probed.title_len);
    try std.testing.expectEqual(@as(u32, 0), probed.duration_ms);
}

test "id3v2 still reads title when declared tag exceeds probe window" {
    // TIT2 first, then claim a huge tag size (as if APIC artwork followed).
    var body: [128]u8 = undefined;
    var len: usize = 0;
    const title = "Partial Window Title";
    @memcpy(body[len .. len + 4], "TIT2");
    len += 4;
    const payload_len: u8 = @intCast(1 + title.len);
    body[len] = 0;
    body[len + 1] = 0;
    body[len + 2] = 0;
    body[len + 3] = payload_len;
    len += 4;
    body[len] = 0;
    body[len + 1] = 0;
    len += 2;
    body[len] = 0; // encoding
    len += 1;
    @memcpy(body[len .. len + title.len], title);
    len += title.len;

    var tag: [256]u8 = undefined;
    tag[0] = 'I';
    tag[1] = 'D';
    tag[2] = '3';
    tag[3] = 3;
    tag[4] = 0;
    tag[5] = 0;
    // Declare a 200KB tag — larger than the 64KB probe read.
    const claimed: usize = 200 * 1024;
    tag[6] = @intCast((claimed >> 21) & 0x7f);
    tag[7] = @intCast((claimed >> 14) & 0x7f);
    tag[8] = @intCast((claimed >> 7) & 0x7f);
    tag[9] = @intCast(claimed & 0x7f);
    @memcpy(tag[10 .. 10 + len], body[0..len]);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = "zig-out/metadata-id3-partial-test.mp3";
    {
        const pad = [_]u8{ 0xff, 0xfb, 0x90, 0x00 } ** 8;
        var payload: [512]u8 = undefined;
        @memcpy(payload[0 .. 10 + len], tag[0 .. 10 + len]);
        @memcpy(payload[10 + len .. 10 + len + pad.len], &pad);
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = payload[0 .. 10 + len + pad.len],
        });
    }
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const probed = probeFile(path);
    try std.testing.expectEqualStrings(title, probed.title[0..probed.title_len]);
}

test "legacy tag text: UTF-8 passes, GBK and Latin-1 decode" {
    try std.testing.expectEqualStrings("晴天", decodeLegacy("晴天"));
    // "后来" in GBK, as a Chinese ripper's ID3v1 field holds it.
    try std.testing.expectEqualStrings("后来", decodeLegacy("\xba\xf3\xc0\xb4"));
    // A 30-byte ID3v1 field can cut the last GBK character in half.
    try std.testing.expectEqualStrings("后来", decodeLegacy("\xba\xf3\xc0\xb4\xce"));
    try std.testing.expectEqualStrings("Beyoncé", decodeLegacy("Beyonc\xe9"));
    try std.testing.expectEqualStrings("Café Olé", decodeLegacy("Caf\xe9 Ol\xe9"));
}

test "utf-16 surrogate pairs become one 4-byte character" {
    // "a🌙" little-endian with BOM: U+1F319 = D83C DF19.
    const text = trimUtf16("\xff\xfea\x00\x3c\xd8\x19\xdf", false).?;
    try std.testing.expectEqualStrings("a🌙", text);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
}

test "mp3 duration: Xing frame count, else constant bitrate" {
    // MPEG-1 Layer III, 128 kbps, 44.1 kHz, stereo.
    var frame = [_]u8{0} ** 424;
    // Two consecutive frame headers, 417 bytes apart (128 kbps, 44.1 kHz).
    for ([_]usize{ 0, 417 }) |at| {
        frame[at] = 0xFF;
        frame[at + 1] = 0xFB;
        frame[at + 2] = 0x90;
        frame[at + 3] = 0x00;
    }
    @memcpy(frame[36..40], "Info");
    frame[43] = 1; // flags: frame count present
    // 1000 frames × 1152 samples / 44100 Hz = 26.122 s
    frame[46] = 0x03;
    frame[47] = 0xE8;
    try std.testing.expectEqual(@as(u32, 26122), mp3DurationFromWindow(&frame, 1_000_000));
    // No Xing header: 160 000 bytes at 128 kbps = 10 s.
    @memset(frame[36..48], 0);
    try std.testing.expectEqual(@as(u32, 10_000), mp3DurationFromWindow(&frame, 160_000));
    try std.testing.expectEqual(@as(u32, 0), mp3DurationFromWindow("not audio", 9));
    // A single stray sync with no frame after it is not audio.
    @memset(frame[417..421], 0);
    try std.testing.expectEqual(@as(u32, 0), mp3DurationFromWindow(&frame, 160_000));
}

test "wav duration from byte rate and data length" {
    var wav = [_]u8{0} ** 44;
    @memcpy(wav[0..4], "RIFF");
    @memcpy(wav[8..12], "WAVE");
    @memcpy(wav[12..16], "fmt ");
    wav[16] = 16;
    // byte rate 176400 (44.1 kHz, 16-bit stereo) = 0x0002B110
    wav[28] = 0x10;
    wav[29] = 0xB1;
    wav[30] = 0x02;
    @memcpy(wav[36..40], "data");
    // 352800 bytes = 2 s → 0x00056220
    wav[40] = 0x20;
    wav[41] = 0x62;
    wav[42] = 0x05;
    try std.testing.expectEqual(@as(u32, 2000), wavDurationMs(&wav));
}
