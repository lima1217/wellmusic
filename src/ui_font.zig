//! System UI face for CJK-capable text.
//!
//! The Geist pack's bundled face covers Latin and a handful of symbols
//! only (~650 glyphs). Song titles and artists with Chinese / Japanese /
//! Korean codepoints render as tofu unless the app registers a face that
//! actually maps them. macOS ships Arial Unicode MS under Supplemental —
//! TrueType, under the SDK's 24 MiB registration budget, dense enough
//! for CJK, and already on every supported system — so we load it once
//! at launch and hand the bytes to `Options.fonts`. The app package stays
//! small; only the process RSS grows by the face size.
//!
//! Candidate paths are macOS-only. Other targets need their own paths
//! or a bundled face.

const std = @import("std");
const native_sdk = @import("native_sdk");

const canvas = native_sdk.canvas;

/// Canvas font id for the system Unicode face. At or above
/// `min_registered_font_id` so it is not a reserved built-in slot.
pub const font_id: canvas.FontId = canvas.min_registered_font_id;

/// Prefer the broadest Supplemental TrueType first; fall back to the
/// GB18030 face when Arial Unicode is absent (unusual, but cheap).
const candidate_paths = [_][]const u8{
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    "/System/Library/Fonts/Supplemental/NISC18030.ttf",
};

/// Keep in lockstep with `canvas_limits.max_registered_canvas_font_bytes`.
/// `native_sdk` root does not re-export that constant (only image budgets),
/// so the literal stays here until the SDK surfaces it.
const max_font_bytes: usize = 24 * 1024 * 1024;

/// Heap-owned face bytes, filled by `load` and cleared by `releaseBytes`
/// after the installing frame copies them into the registry. Empty when
/// no candidate parsed — the app then keeps the Geist default.
var loaded_bytes: []u8 = &.{};
var loaded_name: []const u8 = "";
/// Survives `releaseBytes`: theme/`ready` still see a loaded face after
/// the transient buffer is freed.
var face_ready: bool = false;

pub fn load(allocator: std.mem.Allocator) void {
    if (face_ready) return;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    for (candidate_paths) |path| {
        const face_bytes = readAbsolute(allocator, io, path) catch continue;
        // Refuse faces the engine cannot outline (glyph budgets / parse).
        _ = canvas.font_ttf.Face.parse(face_bytes) catch {
            allocator.free(face_bytes);
            continue;
        };
        loaded_bytes = face_bytes;
        loaded_name = std.fs.path.basename(path);
        face_ready = true;
        return;
    }
}

/// Free the original face buffer after the SDK has copied it at
/// registration. Keeps `ready()` true so theme stamps still apply.
pub fn releaseBytes(allocator: std.mem.Allocator) void {
    if (loaded_bytes.len == 0) return;
    allocator.free(loaded_bytes);
    loaded_bytes = &.{};
}

fn readAbsolute(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const size = (try file.stat(io)).size;
    // Over-budget faces must fail closed — never truncate into a bad TTF.
    if (size > max_font_bytes) return error.StreamTooLong;
    const len: usize = @intCast(size);
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const n = try reader.interface.readSliceShort(buf);
    if (n != buf.len) return error.UnexpectedEndOfStream;
    return buf;
}

pub fn faceBytes() []const u8 {
    return loaded_bytes;
}

pub fn name() []const u8 {
    return loaded_name;
}

pub fn ready() bool {
    return face_ready;
}
