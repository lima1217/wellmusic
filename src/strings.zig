//! User-facing text in the languages WellMusic speaks.
//!
//! The model carries a `Lang` (picked from the system's preferred
//! languages at launch, English otherwise); views and markup bindings
//! read strings through `text`, and the few counted phrases through the
//! formatting helpers below. Accessibility labels go through the same
//! table so VoiceOver speaks the language the screen shows.

const std = @import("std");

pub const Lang = enum { en, zh };

pub const Key = enum {
    // Header
    add_music,
    add_song,
    add_album,
    dark_mode,
    light_mode,
    // Now playing
    now_playing,
    nothing_playing,
    pick_to_start,
    cannot_play,
    cannot_play_hint,
    playback_controls,
    playback_options,
    previous_track,
    next_track,
    play_or_pause,
    show_now_playing,
    mode_shuffle_on,
    mode_shuffle_off,
    mode_repeat_off,
    mode_repeat_all,
    mode_repeat_one,
    volume,
    mute,
    unmute,
    toggle_queue,
    // Library
    library_empty,
    library_empty_hint,
    loose_album_title,
    loose_album_artist,
    album_grid,
    albums,
    album_detail,
    album_tracks,
    back_to_albums,
    play_album,
    open_album,
    edit_info,
    change_cover,
    remove_album,
    play_next,
    remove_from_library,
    // Queue
    playlist,
    playlist_clear,
    playlist_empty,
    playlist_empty_hint,
    remove_from_playlist,
    move_up,
    move_down,
    move_to_top,
    move_to_bottom,
    shuffle_album,
    // Dialogs
    edit_song,
    edit_album,
    title,
    artist,
    cancel,
    save,
    // Notices
    undo,
    dismiss,
    notice,
    // File dialogs
    dialog_add_music,
    dialog_import_album,
    dialog_choose_cover,
    dialog_audio,
    dialog_images,
    dialog_all_files,
    // Status item
    play,
    pause,
    next,
    previous,
    show_queue,
    hide_queue,
};

const Pair = struct { en: []const u8, zh: []const u8 };

// Vocabulary: docs/review/glossary.md. One verb per action across the app
// (Add, Remove, Play Next, Edit Info); "song" never "track" on screen;
// the play queue is "Queue" in English and 播放列表 in Chinese, which is
// what Chinese music apps call the list of what plays next.
const table = std.enums.EnumArray(Key, Pair).init(.{
    .add_music = .{ .en = "Add Music", .zh = "添加音乐" },
    .add_song = .{ .en = "Add Songs…", .zh = "添加歌曲…" },
    .add_album = .{ .en = "Add Album from Folder…", .zh = "从文件夹添加专辑…" },
    .dark_mode = .{ .en = "Dark Mode", .zh = "深色模式" },
    .light_mode = .{ .en = "Light Mode", .zh = "浅色模式" },
    .now_playing = .{ .en = "Now Playing", .zh = "正在播放" },
    .nothing_playing = .{ .en = "Not Playing", .zh = "未在播放" },
    .pick_to_start = .{ .en = "Double-click a song to play it", .zh = "双击歌曲即可播放" },
    .cannot_play = .{ .en = "Can’t play this song", .zh = "无法播放这首歌" },
    .cannot_play_hint = .{ .en = "The file may be damaged. Try adding it again.", .zh = "文件可能已损坏，可以重新添加试试。" },
    .playback_controls = .{ .en = "Playback controls", .zh = "播放控制" },
    .playback_options = .{ .en = "Playback options", .zh = "播放选项" },
    .previous_track = .{ .en = "Previous", .zh = "上一首" },
    .next_track = .{ .en = "Next", .zh = "下一首" },
    .play_or_pause = .{ .en = "Play or Pause", .zh = "播放或暂停" },
    .show_now_playing = .{ .en = "Show the playing album", .zh = "显示正在播放的专辑" },
    .mode_shuffle_on = .{ .en = "Shuffle On", .zh = "随机播放已开启" },
    .mode_shuffle_off = .{ .en = "Shuffle Off", .zh = "随机播放已关闭" },
    .mode_repeat_off = .{ .en = "Repeat Off", .zh = "不循环" },
    .mode_repeat_all = .{ .en = "Repeat All", .zh = "列表循环" },
    .mode_repeat_one = .{ .en = "Repeat One", .zh = "单曲循环" },
    .volume = .{ .en = "Volume", .zh = "音量" },
    .mute = .{ .en = "Mute", .zh = "静音" },
    .unmute = .{ .en = "Unmute", .zh = "取消静音" },
    .toggle_queue = .{ .en = "Queue", .zh = "播放列表" },
    .library_empty = .{ .en = "Your library is empty", .zh = "资料库还是空的" },
    .library_empty_hint = .{ .en = "You can also drag songs or folders into this window.", .zh = "也可以把歌曲或文件夹直接拖进窗口。" },
    .loose_album_title = .{ .en = "Singles", .zh = "单曲" },
    .loose_album_artist = .{ .en = "Various Artists", .zh = "群星" },
    .album_grid = .{ .en = "Albums", .zh = "专辑" },
    .albums = .{ .en = "Album list", .zh = "专辑列表" },
    .album_detail = .{ .en = "Album", .zh = "专辑详情" },
    .album_tracks = .{ .en = "Songs", .zh = "歌曲" },
    .back_to_albums = .{ .en = "Back to Albums", .zh = "返回专辑列表" },
    .play_album = .{ .en = "Play Album", .zh = "播放专辑" },
    .open_album = .{ .en = "Open Album", .zh = "打开专辑" },
    .edit_info = .{ .en = "Edit Info…", .zh = "编辑信息…" },
    .change_cover = .{ .en = "Change Cover…", .zh = "更换封面…" },
    .remove_album = .{ .en = "Remove Album from Library", .zh = "从资料库移除专辑" },
    .play_next = .{ .en = "Play Next", .zh = "下一首播放" },
    .remove_from_library = .{ .en = "Remove from Library", .zh = "从资料库移除" },
    .playlist = .{ .en = "Queue", .zh = "播放列表" },
    .playlist_clear = .{ .en = "Clear", .zh = "清空" },
    .playlist_empty = .{ .en = "The queue is empty", .zh = "播放列表是空的" },
    .playlist_empty_hint = .{ .en = "Play an album, or right-click a song and choose Play Next.", .zh = "播放一张专辑，或右键点击歌曲，选择“下一首播放”。" },
    .remove_from_playlist = .{ .en = "Remove from Queue", .zh = "从播放列表移除" },
    .move_up = .{ .en = "Move Up", .zh = "上移" },
    .move_down = .{ .en = "Move Down", .zh = "下移" },
    .move_to_top = .{ .en = "Move to Top", .zh = "移到最前" },
    .move_to_bottom = .{ .en = "Move to Bottom", .zh = "移到最后" },
    .shuffle_album = .{ .en = "Shuffle Album", .zh = "随机播放专辑" },
    .edit_song = .{ .en = "Edit Song Info", .zh = "编辑歌曲信息" },
    .edit_album = .{ .en = "Edit Album Info", .zh = "编辑专辑信息" },
    .title = .{ .en = "Title", .zh = "标题" },
    .artist = .{ .en = "Artist", .zh = "歌手" },
    .cancel = .{ .en = "Cancel", .zh = "取消" },
    .save = .{ .en = "Save", .zh = "保存" },
    .undo = .{ .en = "Undo", .zh = "撤销" },
    .dismiss = .{ .en = "Dismiss", .zh = "关闭" },
    .notice = .{ .en = "Status", .zh = "状态" },
    .dialog_add_music = .{ .en = "Add Songs", .zh = "添加歌曲" },
    .dialog_import_album = .{ .en = "Choose a Folder to Add as an Album", .zh = "选择要添加为专辑的文件夹" },
    .dialog_choose_cover = .{ .en = "Choose a Cover Image", .zh = "选择封面图片" },
    .dialog_audio = .{ .en = "Audio", .zh = "音频" },
    .dialog_images = .{ .en = "Images", .zh = "图片" },
    .dialog_all_files = .{ .en = "All Files", .zh = "所有文件" },
    .play = .{ .en = "Play", .zh = "播放" },
    .pause = .{ .en = "Pause", .zh = "暂停" },
    .next = .{ .en = "Next", .zh = "下一首" },
    .previous = .{ .en = "Previous", .zh = "上一首" },
    .show_queue = .{ .en = "Show Queue", .zh = "显示播放列表" },
    .hide_queue = .{ .en = "Hide Queue", .zh = "隐藏播放列表" },
});

pub fn text(lang: Lang, key: Key) []const u8 {
    const pair = table.get(key);
    return switch (lang) {
        .en => pair.en,
        .zh => pair.zh,
    };
}

fn songs(lang: Lang, n: usize) []const u8 {
    return switch (lang) {
        .en => if (n == 1) "song" else "songs",
        .zh => "首歌曲",
    };
}

/// The album page's count line, Apple Music's register: "12 songs,
/// 48 minutes" / "12 首歌曲，48 分钟". `known_ms` covers only the songs
/// whose length is known; when any is unknown (`all_known` false) the
/// total is left out rather than shown short — an undercount reads as fact.
pub fn trackSummary(arena: std.mem.Allocator, lang: Lang, tracks: usize, known_ms: u64, all_known: bool) []const u8 {
    const count = switch (lang) {
        .en => std.fmt.allocPrint(arena, "{d} {s}", .{ tracks, songs(lang, tracks) }) catch "",
        .zh => std.fmt.allocPrint(arena, "{d} {s}", .{ tracks, songs(lang, tracks) }) catch "",
    };
    if (!all_known or known_ms == 0 or tracks == 0) return count;
    const length = totalLength(arena, lang, known_ms);
    return switch (lang) {
        .en => std.fmt.allocPrint(arena, "{s}, {s}", .{ count, length }) catch "",
        .zh => std.fmt.allocPrint(arena, "{s}，{s}", .{ count, length }) catch "",
    };
}

/// A total running time, minutes rounded to nearest; under 30 s rounds up
/// to "1 minute" so a short album never reads as zero.
pub fn totalLength(arena: std.mem.Allocator, lang: Lang, ms: u64) []const u8 {
    const minutes = @max(1, (ms + 30_000) / 60_000);
    const hours = minutes / 60;
    const rest = minutes % 60;
    return switch (lang) {
        .en => if (hours == 0)
            std.fmt.allocPrint(arena, "{d} {s}", .{ minutes, if (minutes == 1) "minute" else "minutes" }) catch ""
        else if (rest == 0)
            std.fmt.allocPrint(arena, "{d} {s}", .{ hours, if (hours == 1) "hour" else "hours" }) catch ""
        else
            std.fmt.allocPrint(arena, "{d} hr {d} min", .{ hours, rest }) catch "",
        .zh => if (hours == 0)
            std.fmt.allocPrint(arena, "{d} 分钟", .{minutes}) catch ""
        else if (rest == 0)
            std.fmt.allocPrint(arena, "{d} 小时", .{hours}) catch ""
        else
            std.fmt.allocPrint(arena, "{d} 小时 {d} 分钟", .{ hours, rest }) catch "",
    };
}

/// One song's length: m:ss, h:mm:ss from an hour. Unknown (0) is blank —
/// "0:00" would state a length the file does not have.
pub fn songLength(arena: std.mem.Allocator, ms: u32) []const u8 {
    if (ms == 0) return "";
    const total_seconds = ms / 1000;
    const hours = total_seconds / 3600;
    if (hours > 0) {
        return std.fmt.allocPrint(arena, "{d}:{d:0>2}:{d:0>2}", .{ hours, (total_seconds / 60) % 60, total_seconds % 60 }) catch "";
    }
    return std.fmt.allocPrint(arena, "{d}:{d:0>2}", .{ total_seconds / 60, total_seconds % 60 }) catch "";
}

/// The queue's count, shown muted beside its heading.
pub fn songCount(arena: std.mem.Allocator, lang: Lang, count: usize) []const u8 {
    return std.fmt.allocPrint(arena, "{d} {s}", .{ count, songs(lang, count) }) catch "";
}

pub fn importing(arena: std.mem.Allocator, lang: Lang, current: usize, total: usize) []const u8 {
    return switch (lang) {
        .en => std.fmt.allocPrint(arena, "Adding song {d} of {d}…", .{ current, total }) catch "",
        .zh => std.fmt.allocPrint(arena, "正在添加第 {d} 首，共 {d} 首…", .{ current, total }) catch "",
    };
}

/// Why songs from one add did not make it in, counted per reason.
pub const ImportCounts = struct {
    added: usize = 0,
    /// Already in the library (same content, any name).
    duplicate: usize = 0,
    /// The copy into the app's media folder failed.
    failed: usize = 0,
    /// Not an audio format WellMusic plays (or a folder with none).
    unsupported: usize = 0,
    /// No room: the library holds `capacity` songs.
    full: usize = 0,
    capacity: usize = 0,
};

/// The summary left behind when an add finishes: what happened first,
/// then each reason something was left out, in one sentence.
pub fn importResult(arena: std.mem.Allocator, lang: Lang, c: ImportCounts) []const u8 {
    var parts: [4][]const u8 = undefined;
    var n: usize = 0;
    switch (lang) {
        .en => {
            if (c.duplicate > 0) {
                parts[n] = std.fmt.allocPrint(arena, "{d} already in your library", .{c.duplicate}) catch "";
                n += 1;
            }
            if (c.unsupported > 0) {
                parts[n] = std.fmt.allocPrint(arena, "{d} unsupported {s}", .{ c.unsupported, if (c.unsupported == 1) "file" else "files" }) catch "";
                n += 1;
            }
            if (c.failed > 0) {
                parts[n] = std.fmt.allocPrint(arena, "{d} couldn’t be copied", .{c.failed}) catch "";
                n += 1;
            }
            if (c.full > 0) {
                parts[n] = std.fmt.allocPrint(arena, "{d} over the {d}-song limit", .{ c.full, c.capacity }) catch "";
                n += 1;
            }
            const lead = if (c.added > 0)
                std.fmt.allocPrint(arena, "Added {d} {s}", .{ c.added, songs(lang, c.added) }) catch ""
            else
                "No songs added";
            if (n == 0) return lead;
            const reasons = std.mem.join(arena, ", ", parts[0..n]) catch "";
            return std.fmt.allocPrint(arena, "{s}: {s}", .{ lead, reasons }) catch "";
        },
        .zh => {
            if (c.duplicate > 0) {
                parts[n] = std.fmt.allocPrint(arena, "{d} 首已在资料库中", .{c.duplicate}) catch "";
                n += 1;
            }
            if (c.unsupported > 0) {
                parts[n] = std.fmt.allocPrint(arena, "{d} 个文件格式不支持", .{c.unsupported}) catch "";
                n += 1;
            }
            if (c.failed > 0) {
                parts[n] = std.fmt.allocPrint(arena, "{d} 首复制失败", .{c.failed}) catch "";
                n += 1;
            }
            if (c.full > 0) {
                parts[n] = std.fmt.allocPrint(arena, "资料库已满（最多 {d} 首），{d} 首未添加", .{ c.capacity, c.full }) catch "";
                n += 1;
            }
            const lead = if (c.added > 0)
                std.fmt.allocPrint(arena, "已添加 {d} 首歌曲", .{c.added}) catch ""
            else
                "没有添加歌曲";
            if (n == 0) return lead;
            const reasons = std.mem.join(arena, "，", parts[0..n]) catch "";
            return std.fmt.allocPrint(arena, "{s}：{s}", .{ lead, reasons }) catch "";
        },
    }
}

/// The album limit is a separate wall: a folder that would be album
/// number `max + 1` is turned away whole.
pub fn albumsFull(arena: std.mem.Allocator, lang: Lang, max: usize) []const u8 {
    return switch (lang) {
        .en => std.fmt.allocPrint(arena, "No album added: the library is full ({d} albums max)", .{max}) catch "",
        .zh => std.fmt.allocPrint(arena, "没有添加专辑：资料库已满（最多 {d} 张）", .{max}) catch "",
    };
}

pub fn removedTracks(arena: std.mem.Allocator, lang: Lang, count: usize) []const u8 {
    return switch (lang) {
        .en => std.fmt.allocPrint(arena, "Removed {d} {s}", .{ count, songs(lang, count) }) catch "",
        .zh => std.fmt.allocPrint(arena, "已移除 {d} 首歌曲", .{count}) catch "",
    };
}

pub fn skippedTrack(arena: std.mem.Allocator, lang: Lang, title: []const u8) []const u8 {
    return switch (lang) {
        .en => std.fmt.allocPrint(arena, "Can’t play “{s}”. Skipped to the next song.", .{title}) catch "",
        .zh => std.fmt.allocPrint(arena, "无法播放《{s}》，已跳到下一首", .{title}) catch "",
    };
}

/// A song's spoken label: title, then artist when there is one.
pub fn songLabel(arena: std.mem.Allocator, lang: Lang, title: []const u8, artist: []const u8) []const u8 {
    if (artist.len == 0) return title;
    return switch (lang) {
        .en => std.fmt.allocPrint(arena, "{s}, {s}", .{ title, artist }) catch "",
        .zh => std.fmt.allocPrint(arena, "{s}，{s}", .{ title, artist }) catch "",
    };
}

pub fn albumByArtist(arena: std.mem.Allocator, lang: Lang, title: []const u8, artist: []const u8) []const u8 {
    if (artist.len == 0) return title;
    return switch (lang) {
        .en => std.fmt.allocPrint(arena, "{s} by {s}", .{ title, artist }) catch "",
        .zh => std.fmt.allocPrint(arena, "{s}，{s}", .{ title, artist }) catch "",
    };
}

pub fn coverLabel(arena: std.mem.Allocator, lang: Lang, title: []const u8) []const u8 {
    return switch (lang) {
        .en => std.fmt.allocPrint(arena, "Cover of {s}", .{title}) catch "",
        .zh => std.fmt.allocPrint(arena, "{s}的封面", .{title}) catch "",
    };
}

test "every key has both languages" {
    for (std.enums.values(Key)) |key| {
        try std.testing.expect(text(.en, key).len > 0);
        try std.testing.expect(text(.zh, key).len > 0);
    }
}

test "summaries read naturally" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("12 songs, 48 minutes", trackSummary(arena, .en, 12, 48 * 60_000, true));
    try std.testing.expectEqualStrings("1 song, 1 minute", trackSummary(arena, .en, 1, 20_000, true));
    try std.testing.expectEqualStrings("3 首歌曲，1 小时 5 分钟", trackSummary(arena, .zh, 3, 65 * 60_000, true));
    try std.testing.expectEqualStrings("2 songs, 2 hours", trackSummary(arena, .en, 2, 120 * 60_000, true));
    // Any unknown length: the count stands alone instead of an undercount.
    try std.testing.expectEqualStrings("9 首歌曲", trackSummary(arena, .zh, 9, 10_000, false));
    try std.testing.expectEqualStrings("0 songs", trackSummary(arena, .en, 0, 0, true));
    try std.testing.expectEqualStrings("Added 3 songs: 1 already in your library", importResult(arena, .en, .{ .added = 3, .duplicate = 1 }));
    try std.testing.expectEqualStrings("已添加 2 首歌曲：1 首复制失败", importResult(arena, .zh, .{ .added = 2, .failed = 1 }));
    try std.testing.expectEqualStrings("No songs added: 2 unsupported files", importResult(arena, .en, .{ .unsupported = 2 }));
    try std.testing.expectEqualStrings("没有添加歌曲：资料库已满（最多 240 首），5 首未添加", importResult(arena, .zh, .{ .full = 5, .capacity = 240 }));
    try std.testing.expectEqualStrings("Added 1 song", importResult(arena, .en, .{ .added = 1 }));
}

test "song lengths: blank when unknown, hours when long" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("", songLength(arena, 0));
    try std.testing.expectEqualStrings("0:00", songLength(arena, 999));
    try std.testing.expectEqualStrings("3:05", songLength(arena, 185_400));
    try std.testing.expectEqualStrings("1:01:40", songLength(arena, 3_700_023));
}

test "no counted phrase joins with a middle dot" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]Lang{ .en, .zh }) |lang| {
        const samples = [_][]const u8{
            trackSummary(arena, lang, 4, 300_000, true),
            importResult(arena, lang, .{ .added = 1, .duplicate = 1, .failed = 1, .unsupported = 1, .full = 1, .capacity = 240 }),
            songCount(arena, lang, 3),
        };
        for (samples) |sample| try std.testing.expect(std.mem.indexOf(u8, sample, "·") == null);
    }
    for (std.enums.values(Key)) |key| {
        try std.testing.expect(std.mem.indexOf(u8, text(.en, key), "·") == null);
        try std.testing.expect(std.mem.indexOf(u8, text(.zh, key), "·") == null);
    }
}
