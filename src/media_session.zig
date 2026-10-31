//! macOS Now Playing bridge (best-effort).
//!
//! Native SDK hosts do not expose MPNowPlayingInfoCenter yet. This module
//! updates Now Playing metadata through MediaPlayer via dlopen+dlsym so
//! tests never need to link objc.
//!
//! Remote commands (Control Center, headphone buttons, media keys while
//! another app is focused) go through MPRemoteCommandCenter's
//! `addTarget:action:` with a tiny NSObject subclass built at runtime
//! (`objc_allocateClassPair` + `class_addMethod`): the targets are plain
//! C functions, so no block ABI is involved. A handler only records the
//! command and wakes the host loop; main.zig then delivers it as the same
//! `.command` event the status-item menu sends.
//!
//! On arm64, `objc_msgSend` must NOT be called as a C varargs function:
//! variadic args go on the stack while the real method expects registers.
//! Each call casts the symbol to the exact method signature.
//!
//! Non-macOS builds and the Zig test binary are honest no-ops.

const std = @import("std");
const builtin = @import("builtin");

var installed: bool = false;
var media_player_lib: ?std.DynLib = null;
var objc_lib: ?std.DynLib = null;

const Id = ?*anyopaque;
const Sel = ?*anyopaque;

/// Raw `objc_msgSend` prototype is intentionally empty — callers must
/// `@ptrCast` to the concrete method signature before invoking.
const MsgSendRaw = *const fn () callconv(.c) void;

const ObjcFns = struct {
    get_class: *const fn (name: [*:0]const u8) callconv(.c) Id = undefined,
    sel_register: *const fn (name: [*:0]const u8) callconv(.c) Sel = undefined,
    msg_send: MsgSendRaw = undefined,
    autorelease_push: ?*const fn () callconv(.c) ?*anyopaque = null,
    autorelease_pop: ?*const fn (token: ?*anyopaque) callconv(.c) void = null,
};
var objc_fns: ?ObjcFns = null;

/// Cached CFString keys for Now Playing info dictionary. Filled once
/// after MediaPlayer is opened; null entries fall back to NSString keys.
const CfKeys = struct {
    title: Id = null,
    artist: Id = null,
    duration: Id = null,
    elapsed: Id = null,
    rate: Id = null,
};
var cf_keys: ?CfKeys = null;

/// Platform-bridge publish cache — not Model state, not part of replay.
/// Remembers the last published content fingerprint (title/artist hashes,
/// duration, playing, elapsed seconds) so coarse position-tick rebuilds
/// skip identical `setNowPlayingInfo:` work. Hashes (not ptr+len) so in-place
/// edits of the same storage still republish.
const PublishCache = struct {
    title_hash: u64 = 0,
    artist_hash: u64 = 0,
    duration_ms: u32 = 0,
    playing: bool = false,
    elapsed_s: u32 = 0,
    valid: bool = false,

    fn matches(
        self: PublishCache,
        title_hash: u64,
        artist_hash: u64,
        duration_ms: u32,
        playing: bool,
        elapsed_s: u32,
    ) bool {
        return self.valid and
            self.title_hash == title_hash and
            self.artist_hash == artist_hash and
            self.duration_ms == duration_ms and
            self.playing == playing and
            self.elapsed_s == elapsed_s;
    }

    fn remember(
        title_hash: u64,
        artist_hash: u64,
        duration_ms: u32,
        playing: bool,
        elapsed_s: u32,
    ) PublishCache {
        return .{
            .title_hash = title_hash,
            .artist_hash = artist_hash,
            .duration_ms = duration_ms,
            .playing = playing,
            .elapsed_s = elapsed_s,
            .valid = true,
        };
    }
};
var last_publish: PublishCache = .{};

fn sliceHash(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

pub fn publish(title: []const u8, artist: []const u8, duration_ms: u32, elapsed_ms: u32, playing: bool) void {
    if (comptime builtin.os.tag != .macos) return;
    if (comptime builtin.is_test) return;
    const elapsed_s = elapsed_ms / 1000;
    const title_hash = sliceHash(title);
    const artist_hash = sliceHash(artist);
    if (last_publish.matches(title_hash, artist_hash, duration_ms, playing, elapsed_s)) return;
    ensureInstalled();
    if (!macPublish(title, artist, duration_ms, elapsed_ms, playing)) return;
    last_publish = PublishCache.remember(title_hash, artist_hash, duration_ms, playing, elapsed_s);
}

/// Prefetch objc / MediaPlayer symbols after first paint so the first
/// real `publish` does not hitch on `dlopen`. Safe to call repeatedly.
pub fn warm() void {
    if (comptime builtin.os.tag != .macos) return;
    if (comptime builtin.is_test) return;
    ensureInstalled();
}

pub fn clear() void {
    if (comptime builtin.os.tag != .macos) return;
    if (comptime builtin.is_test) return;
    last_publish = .{};
    if (!installed) return;
    macClear();
}

/// Transport commands the system can send. The tag is the bit index in
/// `pending_remote`.
pub const RemoteCommand = enum(u3) {
    toggle_play,
    play,
    pause,
    next,
    previous,

    /// The status-item command name `onCommand` already maps.
    pub fn commandName(command: RemoteCommand) []const u8 {
        return switch (command) {
            .toggle_play => "transport.toggle",
            .play => "transport.play",
            .pause => "transport.pause",
            .next => "transport.next",
            .previous => "transport.previous",
        };
    }
};

/// Commands received but not yet delivered, one bit per command. A burst
/// of the same command collapses to one — the loop drains on wake.
var pending_remote: std.atomic.Value(u8) = .init(0);
var remote_wake: ?*const fn () void = null;
var remote_installed: bool = false;

/// Register the remote-command targets once. `wake` must be safe to call
/// from the main thread inside an AppKit callback; it nudges the host
/// loop so an idle app still reacts to Control Center at once.
pub fn installRemoteCommands(wake: *const fn () void) void {
    if (comptime builtin.os.tag != .macos) return;
    if (comptime builtin.is_test) return;
    if (remote_installed) return;
    remote_installed = true;
    remote_wake = wake;
    ensureInstalled();
    macInstallRemoteCommands();
}

/// The next command the system sent since the last call, if any.
pub fn takeRemoteCommand() ?RemoteCommand {
    while (true) {
        const bits = pending_remote.load(.acquire);
        if (bits == 0) return null;
        const index: u3 = @intCast(@ctz(bits));
        const cleared = bits & ~(@as(u8, 1) << index);
        if (pending_remote.cmpxchgWeak(bits, cleared, .acq_rel, .acquire) == null) {
            return @enumFromInt(index);
        }
    }
}

fn noteRemote(command: RemoteCommand) isize {
    _ = pending_remote.fetchOr(@as(u8, 1) << @intFromEnum(command), .acq_rel);
    if (remote_wake) |wake| wake();
    return 0; // MPRemoteCommandHandlerStatusSuccess
}

fn handleToggle(_: Id, _: Sel, _: Id) callconv(.c) isize {
    return noteRemote(.toggle_play);
}
fn handlePlay(_: Id, _: Sel, _: Id) callconv(.c) isize {
    return noteRemote(.play);
}
fn handlePause(_: Id, _: Sel, _: Id) callconv(.c) isize {
    return noteRemote(.pause);
}
fn handleNext(_: Id, _: Sel, _: Id) callconv(.c) isize {
    return noteRemote(.next);
}
fn handlePrevious(_: Id, _: Sel, _: Id) callconv(.c) isize {
    return noteRemote(.previous);
}

const RemoteHandler = struct {
    /// MPRemoteCommandCenter property holding the command.
    getter: [*:0]const u8,
    /// Selector added to the target class for this command.
    selector: [*:0]const u8,
    imp: *const fn (Id, Sel, Id) callconv(.c) isize,
};

const remote_handlers = [_]RemoteHandler{
    .{ .getter = "togglePlayPauseCommand", .selector = "wellmusicToggle:", .imp = &handleToggle },
    .{ .getter = "playCommand", .selector = "wellmusicPlay:", .imp = &handlePlay },
    .{ .getter = "pauseCommand", .selector = "wellmusicPause:", .imp = &handlePause },
    .{ .getter = "nextTrackCommand", .selector = "wellmusicNext:", .imp = &handleNext },
    .{ .getter = "previousTrackCommand", .selector = "wellmusicPrevious:", .imp = &handlePrevious },
};

fn macInstallRemoteCommands() void {
    if (objc_fns == null) return;
    var lib = objc_lib orelse return;
    const allocate_class = lib.lookup(*const fn (superclass: Id, name: [*:0]const u8, extra: usize) callconv(.c) Id, "objc_allocateClassPair") orelse return;
    const register_class = lib.lookup(*const fn (class: Id) callconv(.c) void, "objc_registerClassPair") orelse return;
    const add_method = lib.lookup(*const fn (class: Id, name: Sel, imp: *const anyopaque, types: [*:0]const u8) callconv(.c) bool, "class_addMethod") orelse return;

    const pool = pushAutoreleasePool();
    defer popAutoreleasePool(pool);

    const target_class = cls("WellMusicRemoteTarget") orelse blk: {
        const base = cls("NSObject") orelse return;
        const class = allocate_class(base, "WellMusicRemoteTarget", 0) orelse return;
        // "q@:@": NSInteger return, self, _cmd, MPRemoteCommandEvent *.
        for (remote_handlers) |handler| {
            _ = add_method(class, sel(handler.selector), @ptrCast(handler.imp), "q@:@");
        }
        register_class(class);
        break :blk class;
    };
    // +1 from alloc/init, deliberately never released: the target must
    // outlive every command the system can still send.
    const target = msg(msg(target_class, "alloc"), "init") orelse return;
    const center_class = cls("MPRemoteCommandCenter") orelse return;
    const center = msg(center_class, "sharedCommandCenter") orelse return;
    const set_enabled: *const fn (Id, Sel, bool) callconv(.c) void = @ptrCast(objc_fns.?.msg_send);
    const add_target: *const fn (Id, Sel, Id, Sel) callconv(.c) Id = @ptrCast(objc_fns.?.msg_send);
    for (remote_handlers) |handler| {
        const command = msg(center, handler.getter) orelse continue;
        set_enabled(command, sel("setEnabled:"), true);
        _ = add_target(command, sel("addTarget:action:"), target, sel(handler.selector));
    }
}

fn ensureInstalled() void {
    if (installed) return;
    installed = true;
    if (comptime builtin.os.tag != .macos) return;
    objc_lib = std.DynLib.open("/usr/lib/libobjc.A.dylib") catch null;
    media_player_lib = std.DynLib.open("/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer") catch null;
    loadObjc();
    cacheCfKeys();
}

fn loadObjc() void {
    var lib = objc_lib orelse return;
    var fns: ObjcFns = .{};
    fns.get_class = lib.lookup(*const fn (name: [*:0]const u8) callconv(.c) Id, "objc_getClass") orelse return;
    fns.sel_register = lib.lookup(*const fn (name: [*:0]const u8) callconv(.c) Sel, "sel_registerName") orelse return;
    fns.msg_send = lib.lookup(MsgSendRaw, "objc_msgSend") orelse return;
    fns.autorelease_push = lib.lookup(*const fn () callconv(.c) ?*anyopaque, "objc_autoreleasePoolPush");
    fns.autorelease_pop = lib.lookup(*const fn (token: ?*anyopaque) callconv(.c) void, "objc_autoreleasePoolPop");
    objc_fns = fns;
}

fn cacheCfKeys() void {
    cf_keys = .{
        .title = lookupCfString("MPMediaItemPropertyTitle"),
        .artist = lookupCfString("MPMediaItemPropertyArtist"),
        .duration = lookupCfString("MPMediaItemPropertyPlaybackDuration"),
        .elapsed = lookupCfString("MPNowPlayingInfoPropertyElapsedPlaybackTime"),
        .rate = lookupCfString("MPNowPlayingInfoPropertyPlaybackRate"),
    };
}

const PoolGuard = struct {
    token: ?*anyopaque = null,
    armed: bool = false,
};

fn pushAutoreleasePool() PoolGuard {
    const fns = objc_fns orelse return .{};
    const push = fns.autorelease_push orelse return .{};
    if (fns.autorelease_pop == null) return .{};
    return .{ .token = push(), .armed = true };
}

fn popAutoreleasePool(guard: PoolGuard) void {
    if (!guard.armed) return;
    const fns = objc_fns orelse return;
    const pop = fns.autorelease_pop orelse return;
    pop(guard.token);
}

fn cls(name: [*:0]const u8) Id {
    const fns = objc_fns orelse return null;
    return fns.get_class(name);
}

fn sel(name: [*:0]const u8) Sel {
    const fns = objc_fns orelse return null;
    return fns.sel_register(name);
}

fn msgSend(comptime Ret: type, comptime Args: type) *const fn (Id, Sel, Args) callconv(.c) Ret {
    const fns = objc_fns orelse unreachable;
    return @ptrCast(fns.msg_send);
}

fn msgSend0(comptime Ret: type) *const fn (Id, Sel) callconv(.c) Ret {
    const fns = objc_fns orelse unreachable;
    return @ptrCast(fns.msg_send);
}

fn msg(target: Id, selector: [*:0]const u8) Id {
    if (objc_fns == null) return null;
    return msgSend0(Id)(target, sel(selector));
}

fn msg1(target: Id, selector: [*:0]const u8, a: Id) Id {
    if (objc_fns == null) return null;
    return msgSend(Id, Id)(target, sel(selector), a);
}

fn msg2(target: Id, selector: [*:0]const u8, a: Id, b: Id) Id {
    if (objc_fns == null) return null;
    const send: *const fn (Id, Sel, Id, Id) callconv(.c) Id = @ptrCast(objc_fns.?.msg_send);
    return send(target, sel(selector), a, b);
}

fn msgDouble(target: Id, selector: [*:0]const u8, value: f64) Id {
    if (objc_fns == null) return null;
    const send: *const fn (Id, Sel, f64) callconv(.c) Id = @ptrCast(objc_fns.?.msg_send);
    return send(target, sel(selector), value);
}

fn msgUsize(target: Id, selector: [*:0]const u8, value: usize) Id {
    if (objc_fns == null) return null;
    const send: *const fn (Id, Sel, usize) callconv(.c) Id = @ptrCast(objc_fns.?.msg_send);
    return send(target, sel(selector), value);
}

fn msgCString(target: Id, selector: [*:0]const u8, value: [*:0]const u8) Id {
    if (objc_fns == null) return null;
    const send: *const fn (Id, Sel, [*:0]const u8) callconv(.c) Id = @ptrCast(objc_fns.?.msg_send);
    return send(target, sel(selector), value);
}

/// Byte length that fits in `max_len` without splitting a UTF-8 codepoint.
/// From the cut point, walks back over continuation bytes (`0b10xxxxxx`)
/// so the prefix is valid UTF-8 (or empty if even the first sequence
/// will not fit).
fn utf8TruncateLen(bytes: []const u8, max_len: usize) usize {
    if (bytes.len <= max_len) return bytes.len;
    var end = max_len;
    while (end > 0 and (bytes[end] & 0b1100_0000) == 0b1000_0000) {
        end -= 1;
    }
    // `end` sits on the lead of a character that may not fully fit
    // (or equals max_len when the cut was already on a boundary).
    if (end >= max_len) return max_len;
    const seq_len = std.unicode.utf8ByteSequenceLength(bytes[end]) catch return end;
    if (end + seq_len <= max_len) return end + seq_len;
    return end;
}

fn nsString(bytes: []const u8) Id {
    const ns = cls("NSString") orelse return null;
    var buf: [512]u8 = undefined;
    const len = utf8TruncateLen(bytes, buf.len - 1);
    @memcpy(buf[0..len], bytes[0..len]);
    buf[len] = 0;
    return msgCString(ns, "stringWithUTF8String:", @ptrCast(&buf));
}

fn lookupCfString(symbol: [:0]const u8) Id {
    var lib = media_player_lib orelse return null;
    const slot = lib.lookup(*Id, symbol) orelse return null;
    return slot.*;
}

fn macPublish(title: []const u8, artist: []const u8, duration_ms: u32, elapsed_ms: u32, playing: bool) bool {
    if (objc_fns == null) return false;
    const pool = pushAutoreleasePool();
    defer popAutoreleasePool(pool);

    const info_cls = cls("MPNowPlayingInfoCenter") orelse return false;
    const center = msg(info_cls, "defaultCenter") orelse return false;
    const dict_cls = cls("NSMutableDictionary") orelse return false;
    const dict = msg(dict_cls, "dictionary") orelse return false;

    const keys = cf_keys orelse CfKeys{};
    const title_key = keys.title orelse nsString("title");
    const artist_key = keys.artist orelse nsString("artist");
    const duration_key = keys.duration orelse nsString("playbackDuration");
    const elapsed_key = keys.elapsed orelse nsString("elapsedPlaybackTime");
    const rate_key = keys.rate orelse nsString("playbackRate");

    if (title_key) |k| {
        if (nsString(title)) |v| _ = msg2(dict, "setObject:forKey:", v, k);
    }
    if (artist_key) |k| {
        if (nsString(artist)) |v| _ = msg2(dict, "setObject:forKey:", v, k);
    }
    if (numberSeconds(duration_ms)) |num| {
        if (duration_key) |k| _ = msg2(dict, "setObject:forKey:", num, k);
    }
    if (numberSeconds(elapsed_ms)) |num| {
        if (elapsed_key) |k| _ = msg2(dict, "setObject:forKey:", num, k);
    }
    if (numberRate(if (playing) 1.0 else 0.0)) |num| {
        if (rate_key) |k| _ = msg2(dict, "setObject:forKey:", num, k);
    }

    _ = msg1(center, "setNowPlayingInfo:", dict);
    // MPNowPlayingPlaybackStatePlaying = 1, Paused = 2
    const state: usize = if (playing) 1 else 2;
    _ = msgUsize(center, "setPlaybackState:", state);
    return true;
}

fn macClear() void {
    const pool = pushAutoreleasePool();
    defer popAutoreleasePool(pool);
    const info_cls = cls("MPNowPlayingInfoCenter") orelse return;
    const center = msg(info_cls, "defaultCenter") orelse return;
    _ = msg1(center, "setNowPlayingInfo:", null);
}

fn numberSeconds(ms: u32) Id {
    const ns = cls("NSNumber") orelse return null;
    const seconds: f64 = @as(f64, @floatFromInt(ms)) / 1000.0;
    return msgDouble(ns, "numberWithDouble:", seconds);
}

fn numberRate(rate: f64) Id {
    const ns = cls("NSNumber") orelse return null;
    return msgDouble(ns, "numberWithDouble:", rate);
}

test "remote commands queue once each and drain in a stable order" {
    try std.testing.expectEqual(@as(?RemoteCommand, null), takeRemoteCommand());
    _ = noteRemote(.next);
    _ = noteRemote(.toggle_play);
    _ = noteRemote(.next); // a burst of the same command collapses
    try std.testing.expectEqual(@as(?RemoteCommand, .toggle_play), takeRemoteCommand());
    try std.testing.expectEqual(@as(?RemoteCommand, .next), takeRemoteCommand());
    try std.testing.expectEqual(@as(?RemoteCommand, null), takeRemoteCommand());
    try std.testing.expectEqualStrings("transport.pause", RemoteCommand.pause.commandName());
}

test "utf8TruncateLen keeps ASCII under the cap" {
    const s = "hello world";
    try std.testing.expectEqual(@as(usize, 11), utf8TruncateLen(s, 512));
    try std.testing.expectEqual(@as(usize, 5), utf8TruncateLen(s, 5));
}

test "utf8TruncateLen does not split a CJK codepoint" {
    // "你好" is 6 bytes (U+4F60 U+597D, 3 bytes each). Cap at 4 must
    // keep only the first character (3 bytes), not 4 (mid-sequence).
    const s = "你好";
    try std.testing.expectEqual(@as(usize, 6), utf8TruncateLen(s, 512));
    try std.testing.expectEqual(@as(usize, 3), utf8TruncateLen(s, 4));
    try std.testing.expectEqual(@as(usize, 3), utf8TruncateLen(s, 3));
    try std.testing.expectEqual(@as(usize, 0), utf8TruncateLen(s, 2));
}

test "utf8TruncateLen does not split a 4-byte emoji" {
    // 𝄞 (U+1D11E) is F0 9D 84 9E. Cap at 3 must yield empty.
    const s = "𝄞x";
    try std.testing.expectEqual(@as(usize, 0), utf8TruncateLen(s, 3));
    try std.testing.expectEqual(@as(usize, 4), utf8TruncateLen(s, 4));
    try std.testing.expectEqual(@as(usize, 5), utf8TruncateLen(s, 5));
}

test "publish cache misses on duration artist or title content change" {
    const title_a = sliceHash("Song A");
    const title_b = sliceHash("Song B"); // same length, different bytes
    const artist_a = sliceHash("Artist");
    const artist_b = sliceHash("Writer");
    const cached = PublishCache.remember(title_a, artist_a, 0, true, 0);

    try std.testing.expect(cached.matches(title_a, artist_a, 0, true, 0));
    // Platform duration adopt 0 → N must republish.
    try std.testing.expect(!cached.matches(title_a, artist_a, 180_000, true, 0));
    // Artist edit must republish even when title/elapsed/playing match.
    try std.testing.expect(!cached.matches(title_a, artist_b, 0, true, 0));
    // In-place same-length title edit changes the hash.
    try std.testing.expect(!cached.matches(title_b, artist_a, 0, true, 0));
    try std.testing.expect(!cached.matches(title_a, artist_a, 0, false, 0));
    try std.testing.expect(!cached.matches(title_a, artist_a, 0, true, 1));
}
