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
    // Header menu
    more,
    add_song,
    add_album,
    dark_mode,
    light_mode,
    // Now playing
    nothing_playing,
    pick_to_start,
    cannot_play,
    cannot_play_hint,
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
    album_eyebrow,
    library_empty,
    library_empty_hint,
    add_to_library,
    add_menu,
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
    // Playlist
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
    song_title,
    album_title,
    artist_name,
    song_artist,
    album_artist,
    cancel,
    save,
    // Notices
    undo,
    dismiss,
    import_progress,
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

const table = std.enums.EnumArray(Key, Pair).init(.{
    .more = .{ .en = "More", .zh = "更多" },
    .add_song = .{ .en = "Add Song", .zh = "添加歌曲" },
    .add_album = .{ .en = "Add Album", .zh = "添加专辑" },
    .dark_mode = .{ .en = "Dark mode", .zh = "深色模式" },
    .light_mode = .{ .en = "Light mode", .zh = "浅色模式" },
    .nothing_playing = .{ .en = "Nothing playing", .zh = "未在播放" },
    .pick_to_start = .{ .en = "Pick an album or a song to start", .zh = "选一张专辑或一首歌开始播放" },
    .cannot_play = .{ .en = "couldn’t play this file", .zh = "无法播放这个文件" },
    .cannot_play_hint = .{ .en = "check the path or re-add the track", .zh = "请检查文件，或重新添加这首歌" },
    .previous_track = .{ .en = "Previous track", .zh = "上一首" },
    .next_track = .{ .en = "Next track", .zh = "下一首" },
    .play_or_pause = .{ .en = "Play or pause", .zh = "播放或暂停" },
    .show_now_playing = .{ .en = "Show the playing album", .zh = "显示正在播放的专辑" },
    .mode_shuffle_on = .{ .en = "Shuffle: on", .zh = "随机播放：开" },
    .mode_shuffle_off = .{ .en = "Shuffle: off", .zh = "随机播放：关" },
    .mode_repeat_off = .{ .en = "Repeat: off", .zh = "循环：关" },
    .mode_repeat_all = .{ .en = "Repeat: all", .zh = "循环：全部" },
    .mode_repeat_one = .{ .en = "Repeat: one", .zh = "循环：单曲" },
    .volume = .{ .en = "Volume", .zh = "音量" },
    .mute = .{ .en = "Mute", .zh = "静音" },
    .unmute = .{ .en = "Unmute", .zh = "取消静音" },
    .toggle_queue = .{ .en = "Toggle play-next queue", .zh = "显示或隐藏播放列表" },
    .album_eyebrow = .{ .en = "Album", .zh = "专辑" },
    .library_empty = .{ .en = "Your library is empty", .zh = "资料库还是空的" },
    .library_empty_hint = .{ .en = "Add songs or import a folder as an album. You can also drop files here.", .zh = "添加歌曲，或把一个文件夹导入为专辑。也可以把文件直接拖进来。" },
    .add_to_library = .{ .en = "Add to library", .zh = "添加到资料库" },
    .add_menu = .{ .en = "Add menu", .zh = "添加菜单" },
    .album_grid = .{ .en = "Album grid", .zh = "专辑" },
    .albums = .{ .en = "Albums", .zh = "专辑列表" },
    .album_detail = .{ .en = "Album detail", .zh = "专辑详情" },
    .album_tracks = .{ .en = "Album tracks", .zh = "专辑曲目" },
    .back_to_albums = .{ .en = "Back to albums", .zh = "返回专辑" },
    .play_album = .{ .en = "Play Album", .zh = "播放专辑" },
    .open_album = .{ .en = "Open Album", .zh = "打开专辑" },
    .edit_info = .{ .en = "Edit Info…", .zh = "编辑信息…" },
    .change_cover = .{ .en = "Change Cover…", .zh = "更换封面…" },
    .remove_album = .{ .en = "Remove Album from Library", .zh = "从资料库移除专辑" },
    .play_next = .{ .en = "Play Next", .zh = "下一首播放" },
    .remove_from_library = .{ .en = "Remove from Library", .zh = "从资料库移除" },
    .playlist = .{ .en = "Playlist", .zh = "播放列表" },
    .playlist_clear = .{ .en = "Clear", .zh = "清空" },
    .playlist_empty = .{ .en = "Playlist is empty.", .zh = "播放列表是空的。" },
    .playlist_empty_hint = .{ .en = "Play an album, double-click a track, or right-click → Play Next", .zh = "播放一张专辑、双击一首歌，或右键 → 下一首播放" },
    .remove_from_playlist = .{ .en = "Remove from playlist", .zh = "从播放列表移除" },
    .move_up = .{ .en = "Move Up", .zh = "上移" },
    .move_down = .{ .en = "Move Down", .zh = "下移" },
    .move_to_top = .{ .en = "Move to Top", .zh = "移到最前" },
    .move_to_bottom = .{ .en = "Move to Bottom", .zh = "移到最后" },
    .shuffle_album = .{ .en = "Shuffle album", .zh = "随机播放专辑" },
    .edit_song = .{ .en = "Edit Song", .zh = "编辑歌曲" },
    .edit_album = .{ .en = "Edit Album", .zh = "编辑专辑" },
    .title = .{ .en = "Title", .zh = "标题" },
    .artist = .{ .en = "Artist", .zh = "歌手" },
    .song_title = .{ .en = "Song title", .zh = "歌曲标题" },
    .album_title = .{ .en = "Album title", .zh = "专辑标题" },
    .artist_name = .{ .en = "Artist name", .zh = "歌手名" },
    .song_artist = .{ .en = "Song artist", .zh = "歌曲歌手" },
    .album_artist = .{ .en = "Album artist", .zh = "专辑歌手" },
    .cancel = .{ .en = "Cancel", .zh = "取消" },
    .save = .{ .en = "Save", .zh = "保存" },
    .undo = .{ .en = "Undo", .zh = "撤销" },
    .dismiss = .{ .en = "Dismiss", .zh = "关闭" },
    .import_progress = .{ .en = "Import progress", .zh = "导入进度" },
    .dialog_add_music = .{ .en = "Add Music", .zh = "添加音乐" },
    .dialog_import_album = .{ .en = "Import Album", .zh = "导入专辑" },
    .dialog_choose_cover = .{ .en = "Choose Cover", .zh = "选择封面" },
    .dialog_audio = .{ .en = "Audio", .zh = "音频" },
    .dialog_images = .{ .en = "Images", .zh = "图片" },
    .dialog_all_files = .{ .en = "All files", .zh = "所有文件" },
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

/// "12 tracks · 48 min" / "12 首 · 48 分钟"; hours past 60 minutes.
pub fn trackSummary(arena: std.mem.Allocator, lang: Lang, artist: []const u8, tracks: usize, total_ms: u64) []const u8 {
    const minutes = (total_ms + 30_000) / 60_000;
    const hours = minutes / 60;
    const rest = minutes % 60;
    return switch (lang) {
        .en => if (total_ms == 0)
            std.fmt.allocPrint(arena, "{s} · {d} {s}", .{ artist, tracks, if (tracks == 1) "track" else "tracks" }) catch ""
        else if (hours > 0)
            std.fmt.allocPrint(arena, "{s} · {d} {s} · {d} hr {d} min", .{ artist, tracks, if (tracks == 1) "track" else "tracks", hours, rest }) catch ""
        else
            std.fmt.allocPrint(arena, "{s} · {d} {s} · {d} min", .{ artist, tracks, if (tracks == 1) "track" else "tracks", minutes }) catch "",
        .zh => if (total_ms == 0)
            std.fmt.allocPrint(arena, "{s} · {d} 首", .{ artist, tracks }) catch ""
        else if (hours > 0)
            std.fmt.allocPrint(arena, "{s} · {d} 首 · {d} 小时 {d} 分钟", .{ artist, tracks, hours, rest }) catch ""
        else
            std.fmt.allocPrint(arena, "{s} · {d} 首 · {d} 分钟", .{ artist, tracks, minutes }) catch "",
    };
}

pub fn playlistHeading(arena: std.mem.Allocator, lang: Lang, count: usize) []const u8 {
    return std.fmt.allocPrint(arena, "{s} · {d}", .{ text(lang, .playlist), count }) catch "";
}

pub fn importing(arena: std.mem.Allocator, lang: Lang, current: usize, total: usize) []const u8 {
    return switch (lang) {
        .en => std.fmt.allocPrint(arena, "Importing {d} / {d}…", .{ current, total }) catch "",
        .zh => std.fmt.allocPrint(arena, "正在导入 {d} / {d}…", .{ current, total }) catch "",
    };
}

/// The summary left behind when an import finishes.
pub fn importResult(arena: std.mem.Allocator, lang: Lang, added: usize, skipped: usize, failed: usize) []const u8 {
    var parts: [3][]const u8 = undefined;
    var n: usize = 0;
    switch (lang) {
        .en => {
            parts[n] = std.fmt.allocPrint(arena, "Added {d} {s}", .{ added, if (added == 1) "song" else "songs" }) catch "";
            n += 1;
            if (skipped > 0) {
                parts[n] = std.fmt.allocPrint(arena, "skipped {d} already in the library", .{skipped}) catch "";
                n += 1;
            }
            if (failed > 0) {
                parts[n] = std.fmt.allocPrint(arena, "{d} could not be copied", .{failed}) catch "";
                n += 1;
            }
        },
        .zh => {
            parts[n] = std.fmt.allocPrint(arena, "已添加 {d} 首", .{added}) catch "";
            n += 1;
            if (skipped > 0) {
                parts[n] = std.fmt.allocPrint(arena, "跳过 {d} 首已在资料库中的歌", .{skipped}) catch "";
                n += 1;
            }
            if (failed > 0) {
                parts[n] = std.fmt.allocPrint(arena, "{d} 首复制失败", .{failed}) catch "";
                n += 1;
            }
        },
    }
    const sep = if (lang == .zh) "，" else " · ";
    return std.mem.join(arena, sep, parts[0..n]) catch "";
}

pub fn removedTracks(arena: std.mem.Allocator, lang: Lang, count: usize) []const u8 {
    return switch (lang) {
        .en => std.fmt.allocPrint(arena, "Removed {d} {s}", .{ count, if (count == 1) "song" else "songs" }) catch "",
        .zh => std.fmt.allocPrint(arena, "已移除 {d} 首", .{count}) catch "",
    };
}

pub fn skippedTrack(arena: std.mem.Allocator, lang: Lang, title: []const u8) []const u8 {
    return switch (lang) {
        .en => std.fmt.allocPrint(arena, "Couldn’t play “{s}” — skipped to the next track", .{title}) catch "",
        .zh => std.fmt.allocPrint(arena, "无法播放《{s}》，已跳到下一首", .{title}) catch "",
    };
}

pub fn playlistRowLabel(arena: std.mem.Allocator, lang: Lang, title: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{s} {s}", .{ text(lang, .playlist), title }) catch "";
}

pub fn albumByArtist(arena: std.mem.Allocator, lang: Lang, title: []const u8, artist: []const u8) []const u8 {
    return switch (lang) {
        .en => std.fmt.allocPrint(arena, "{s} by {s}", .{ title, artist }) catch "",
        .zh => std.fmt.allocPrint(arena, "{s}，{s}", .{ title, artist }) catch "",
    };
}

pub fn coverLabel(arena: std.mem.Allocator, lang: Lang, title: []const u8) []const u8 {
    return switch (lang) {
        .en => std.fmt.allocPrint(arena, "{s} cover", .{title}) catch "",
        .zh => std.fmt.allocPrint(arena, "{s} 封面", .{title}) catch "",
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
    try std.testing.expectEqualStrings("A · 12 tracks · 48 min", trackSummary(arena, .en, "A", 12, 48 * 60_000));
    try std.testing.expectEqualStrings("A · 3 首 · 1 小时 5 分钟", trackSummary(arena, .zh, "A", 3, 65 * 60_000));
    try std.testing.expectEqualStrings("Added 3 songs · skipped 1 already in the library", importResult(arena, .en, 3, 1, 0));
    try std.testing.expectEqualStrings("已添加 2 首，1 首复制失败", importResult(arena, .zh, 2, 0, 1));
}
