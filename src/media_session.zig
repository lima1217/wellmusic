//! macOS Now Playing info bridge (best-effort).
//!
//! Native SDK hosts do not expose MPNowPlayingInfoCenter yet. This module
//! updates Now Playing metadata through MediaPlayer via dlopen+dlsym so
//! tests never need to link objc. Remote-command targets are intentionally
//! omitted — `objc_msgSend` ABI for `addTarget:action:` is fragile without
//! a real ObjC bridge; transport control rides the status-item menu and
//! focused media keys instead.
//!
//! On arm64, `objc_msgSend` must NOT be called as a C varargs function:
//! variadic args go on the stack while the real method expects registers.
//! Each call casts the symbol to the exact method signature.
//!
//! Non-macOS builds and the Zig test binary are honest no-ops.

const std = @import("std");
const builtin = @import("builtin");

pub const Command = enum(u8) {
    none = 0,
    toggle_play,
    next,
    previous,
};

var pending: std.atomic.Value(u8) = .init(0);
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
};
var objc_fns: ?ObjcFns = null;

pub fn poll() Command {
    const raw = pending.swap(0, .acq_rel);
    return switch (raw) {
        @intFromEnum(Command.toggle_play) => .toggle_play,
        @intFromEnum(Command.next) => .next,
        @intFromEnum(Command.previous) => .previous,
        else => .none,
    };
}

pub fn publish(title: []const u8, artist: []const u8, duration_ms: u32, elapsed_ms: u32, playing: bool) void {
    if (comptime builtin.os.tag != .macos) return;
    if (comptime builtin.is_test) return;
    ensureInstalled();
    macPublish(title, artist, duration_ms, elapsed_ms, playing);
}

pub fn clear() void {
    if (comptime builtin.os.tag != .macos) return;
    if (comptime builtin.is_test) return;
    if (!installed) return;
    macClear();
}

fn ensureInstalled() void {
    if (installed) return;
    installed = true;
    if (comptime builtin.os.tag != .macos) return;
    objc_lib = std.DynLib.open("/usr/lib/libobjc.A.dylib") catch null;
    media_player_lib = std.DynLib.open("/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer") catch null;
    loadObjc();
}

fn loadObjc() void {
    var lib = objc_lib orelse return;
    var fns: ObjcFns = .{};
    fns.get_class = lib.lookup(*const fn (name: [*:0]const u8) callconv(.c) Id, "objc_getClass") orelse return;
    fns.sel_register = lib.lookup(*const fn (name: [*:0]const u8) callconv(.c) Sel, "sel_registerName") orelse return;
    fns.msg_send = lib.lookup(MsgSendRaw, "objc_msgSend") orelse return;
    objc_fns = fns;
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

fn nsString(bytes: []const u8) Id {
    const ns = cls("NSString") orelse return null;
    var buf: [512]u8 = undefined;
    const len = @min(bytes.len, buf.len - 1);
    @memcpy(buf[0..len], bytes[0..len]);
    buf[len] = 0;
    return msgCString(ns, "stringWithUTF8String:", @ptrCast(&buf));
}

fn lookupCfString(symbol: [:0]const u8) Id {
    var lib = media_player_lib orelse return null;
    const slot = lib.lookup(*Id, symbol) orelse return null;
    return slot.*;
}

fn macPublish(title: []const u8, artist: []const u8, duration_ms: u32, elapsed_ms: u32, playing: bool) void {
    if (objc_fns == null) return;
    const info_cls = cls("MPNowPlayingInfoCenter") orelse return;
    const center = msg(info_cls, "defaultCenter") orelse return;
    const dict_cls = cls("NSMutableDictionary") orelse return;
    const dict = msg(dict_cls, "dictionary") orelse return;

    const title_key = lookupCfString("MPMediaItemPropertyTitle") orelse nsString("title");
    const artist_key = lookupCfString("MPMediaItemPropertyArtist") orelse nsString("artist");
    const duration_key = lookupCfString("MPMediaItemPropertyPlaybackDuration") orelse nsString("playbackDuration");
    const elapsed_key = lookupCfString("MPNowPlayingInfoPropertyElapsedPlaybackTime") orelse nsString("elapsedPlaybackTime");
    const rate_key = lookupCfString("MPNowPlayingInfoPropertyPlaybackRate") orelse nsString("playbackRate");

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
}

fn macClear() void {
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
