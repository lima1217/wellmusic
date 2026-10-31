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

    if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "ID3")) {
        parseId3(bytes, &out);
    } else if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "fLaC")) {
        parseFlac(bytes, &out);
    } else if (bytes.len >= 8 and std.mem.eql(u8, bytes[4..8], "ftyp")) {
        parseMp4(bytes, &out);
        if (out.duration_ms == 0) {
            var wider: [256 * 1024]u8 = undefined;
            const wide_n = file.readPositionalAll(io, &wider, 0) catch 0;
            if (wide_n > 0) walkMp4(wider[0..wide_n], 0, wide_n, &out, 0);
        }
    } else if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "OggS")) {
        parseOggVorbisComments(bytes, &out);
    }

    if (out.title_len == 0 and out.artist_len == 0) {
        parseId3v1(file, io, &out) catch {};
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

fn parseId3v1(file: std.Io.File, io: std.Io, out: *ProbeBuffers) !void {
    const info = try file.stat(io);
    if (info.size < 128) return;
    var tag: [128]u8 = undefined;
    const n = try file.readPositionalAll(io, &tag, info.size - 128);
    if (n < 128) return;
    if (!std.mem.eql(u8, tag[0..3], "TAG")) return;
    if (out.title_len == 0) out.setTitle(trimId3v1(tag[3..33]));
    if (out.artist_len == 0) out.setArtist(trimId3v1(tag[33..63]));
    if (out.album_len == 0) out.setAlbum(trimId3v1(tag[63..93]));
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
        if (isContainer(typ)) {
            const child = if (std.mem.eql(u8, typ, "meta") and body.len >= 4) body[4..] else body;
            walkMp4(child, 0, child.len, out, depth + 1);
        } else if (std.mem.eql(u8, typ, "mdhd")) {
            parseMdhd(body, out);
        } else if (std.mem.eql(u8, typ, "\xA9nam") or std.mem.eql(u8, typ, "name")) {
            if (decodeIlstData(body)) |text| out.setTitle(text);
        } else if (std.mem.eql(u8, typ, "\xA9ART")) {
            if (decodeIlstData(body)) |text| out.setArtist(text);
        } else if (std.mem.eql(u8, typ, "\xA9alb")) {
            if (decodeIlstData(body)) |text| out.setAlbum(text);
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
        0, 3 => trimUtf8(payload), // ISO-8859-1 / UTF-8
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
    while (offset + 1 < raw.len and out_len + 3 < scratch.buf.len) {
        const code: u16 = if (big_endian)
            (@as(u16, raw[offset]) << 8) | raw[offset + 1]
        else
            (@as(u16, raw[offset + 1]) << 8) | raw[offset];
        offset += 2;
        if (code == 0) break;
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
