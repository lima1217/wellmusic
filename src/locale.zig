//! The UI language, read once at launch from the system's preferred
//! languages (System Settings → Language & Region) through CoreFoundation
//! via dlopen — the same no-link approach as `media_session`. Anything
//! that is not Chinese falls back to English; tests always get English.

const std = @import("std");
const builtin = @import("builtin");
const strings = @import("strings.zig");

const CFTypeRef = ?*anyopaque;
const k_cf_string_encoding_utf8: u32 = 0x08000100;

pub fn preferredLang() strings.Lang {
    if (comptime builtin.os.tag != .macos) return .en;
    if (comptime builtin.is_test) return .en;
    var lib = std.DynLib.open("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation") catch return .en;
    defer lib.close();
    const copy_languages = lib.lookup(*const fn () callconv(.c) CFTypeRef, "CFLocaleCopyPreferredLanguages") orelse return .en;
    const array_count = lib.lookup(*const fn (CFTypeRef) callconv(.c) isize, "CFArrayGetCount") orelse return .en;
    const array_at = lib.lookup(*const fn (CFTypeRef, isize) callconv(.c) CFTypeRef, "CFArrayGetValueAtIndex") orelse return .en;
    const string_bytes = lib.lookup(*const fn (CFTypeRef, [*]u8, isize, u32) callconv(.c) bool, "CFStringGetCString") orelse return .en;
    const release = lib.lookup(*const fn (CFTypeRef) callconv(.c) void, "CFRelease") orelse return .en;

    const languages = copy_languages() orelse return .en;
    defer release(languages);
    if (array_count(languages) < 1) return .en;
    var buffer: [64]u8 = undefined;
    if (!string_bytes(array_at(languages, 0), &buffer, buffer.len, k_cf_string_encoding_utf8)) return .en;
    return langForTag(std.mem.sliceTo(&buffer, 0));
}

/// "zh-Hans-CN", "zh-Hant", "zh" → Chinese; everything else English.
pub fn langForTag(tag: []const u8) strings.Lang {
    if (std.mem.eql(u8, tag, "zh") or std.mem.startsWith(u8, tag, "zh-") or std.mem.startsWith(u8, tag, "zh_")) return .zh;
    return .en;
}

test "language tags map to the UI languages we have" {
    try std.testing.expectEqual(strings.Lang.zh, langForTag("zh-Hans-CN"));
    try std.testing.expectEqual(strings.Lang.zh, langForTag("zh"));
    try std.testing.expectEqual(strings.Lang.en, langForTag("en-US"));
    try std.testing.expectEqual(strings.Lang.en, langForTag("ja-JP"));
    try std.testing.expectEqual(strings.Lang.en, langForTag("zhx"));
}
