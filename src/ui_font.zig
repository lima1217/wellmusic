//! System UI face for CJK-capable text.
//!
//! The Geist pack's bundled face covers Latin and a handful of symbols
//! only (~650 glyphs). Song titles and artists with Chinese / Japanese /
//! Korean codepoints render as tofu unless the app registers a face that
//! actually maps them.
//!
//! macOS ships two Supplemental TrueType faces under the SDK's 24 MiB
//! registration budget. The smaller GB18030 face (~7 MiB) is tried first,
//! with Arial Unicode (~22 MiB) as the fallback; a candidate is accepted
//! only if it passes the same `Face.parse` registration runs. Current
//! macOS ships NISC18030 without a 'head' table, so Arial Unicode is the
//! face in practice. The app package stays small; only
//! the process RSS grows by the chosen face size.
//!
//! Boot skips registration when the restored library has no CJK text
//! (`libraryNeedsCjkFont`). When a later import or edit brings the first
//! CJK text into a Latin-only session, main.zig registers the face late
//! through `runtime.registerCanvasFont`; UiApp then re-measures every
//! surface on the next frame.
//!
//! Candidate paths are macOS-only. Other targets need their own paths
//! or a bundled face.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");

const canvas = native_sdk.canvas;

/// Canvas font id for the system Unicode face. At or above
/// `min_registered_font_id` so it is not a reserved built-in slot.
pub const font_id: canvas.FontId = canvas.min_registered_font_id;

/// Smaller GB18030 face first (Chinese-dense, ~7 MiB). Broad Arial
/// Unicode (~22 MiB) remains the fallback for installs that lack NISC
/// or reject it on outline budgets.
const candidate_paths = [_][]const u8{
    "/System/Library/Fonts/Supplemental/NISC18030.ttf",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
};

/// Keep in lockstep with `canvas_limits.max_registered_canvas_font_bytes`.
/// `native_sdk` root does not re-export that constant (only image budgets),
/// so the literal stays here until the SDK surfaces it.
const max_font_bytes: usize = 24 * 1024 * 1024;

/// Heap-owned face bytes, filled by `load` and cleared by `releaseBytes`
/// after the installing frame copies them into the registry. Empty when
/// no candidate accepted — the app then keeps the Geist default.
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
        // Accept only what registration will: the `maxp` budget prefilter
        // alone let NISC18030 through, but it is an Apple 'true' face
        // without a 'head' table, so the runtime refused it and the theme
        // still named its font id — CJK stayed tofu. `parseFailureReason`
        // runs the same `Face.parse` registration does.
        if (!faceWithinOutlineBudgets(face_bytes) or canvas.font_ttf.parseFailureReason(face_bytes) != null) {
            allocator.free(face_bytes);
            continue;
        }
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

/// Drop a loaded face the runtime refused, so the theme stops stamping a
/// font id that was never registered.
pub fn discard(allocator: std.mem.Allocator) void {
    releaseBytes(allocator);
    face_ready = false;
    loaded_name = "";
}

fn faceWithinOutlineBudgets(bytes: []const u8) bool {
    // Reject obvious non-glyf containers before touching maxp.
    if (bytes.len < 12) return false;
    const tag = bytes[0..4];
    const is_ttf = std.mem.eql(u8, tag, &.{ 0, 1, 0, 0 }) or std.mem.eql(u8, tag, "true");
    if (!is_ttf) return false;
    const maxima = canvas.font_ttf.declaredGlyphMaxima(bytes) orelse return false;
    return maxima.withinBudgets();
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

/// Test-only: drop a loaded face so the next `load` can pick again.
pub fn resetForTest(allocator: std.mem.Allocator) void {
    releaseBytes(allocator);
    loaded_name = "";
    face_ready = false;
}

test "load only accepts a face the runtime can register" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    resetForTest(alloc);
    defer resetForTest(alloc);

    load(alloc);
    try std.testing.expect(ready());
    // Registration runs `Face.parse`; whichever candidate won must pass it.
    try std.testing.expectEqual(@as(?[]const u8, null), canvas.font_ttf.parseFailureReason(faceBytes()));
    try std.testing.expect(faceBytes().len <= max_font_bytes);
}

test "outline budget prefilter accepts Supplemental TrueType headers" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try readAbsolute(alloc, io, candidate_paths[0]);
    defer alloc.free(bytes);
    try std.testing.expect(faceWithinOutlineBudgets(bytes));
    try std.testing.expect(!faceWithinOutlineBudgets("not a font"));
}
