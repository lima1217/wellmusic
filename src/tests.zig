//! wellmusic tests: user library add/remove/persist, empty-library UI,
//! theming, chrome, shell switching, and markup parity. There is no
//! built-in sample catalog — playback assertions seed imported tracks.

const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");
const model_mod = @import("model.zig");
const theme = @import("theme.zig");
const view_mod = @import("view.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

const Model = main.Model;
const Msg = main.Msg;
const Ui = view_mod.Ui;
const App = main.WellMusicApp;

fn buildTree(arena: std.mem.Allocator, model: *const Model) !Ui.Tree {
    main.registerIcons();
    var ui = Ui.init(arena);
    return ui.finalizeWithTokens(view_mod.rootView(&ui, model), main.tokensFromModel(model));
}

fn apply(model: *Model, msg: Msg) void {
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.update(model, msg, &fx);
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}

fn findByLabel(widget: canvas.Widget, label: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.semantics.label, label)) return widget;
    for (widget.children) |child| {
        if (findByLabel(child, label)) |found| return found;
    }
    return null;
}

fn countListItems(widget: canvas.Widget) usize {
    var total: usize = 0;
    if (widget.semantics.role == .listitem) total += 1;
    for (widget.children) |child| total += countListItems(child);
    return total;
}

fn collectIds(widget: canvas.Widget, ids: *std.ArrayListUnmanaged(canvas.ObjectId), allocator: std.mem.Allocator) !void {
    try ids.append(allocator, widget.id);
    for (widget.children) |child| try collectIds(child, ids, allocator);
}

const surface_size = geometry.SizeF.init(main.window_width, main.window_height);
const phone_size = geometry.SizeF.init(393, 852);

const LiveApp = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *App,
    size: geometry.SizeF,

    fn start(image_decode: bool) !LiveApp {
        return startSized(image_decode, surface_size);
    }

    fn startSized(image_decode: bool, size: geometry.SizeF) !LiveApp {
        main.registerIcons();
        const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = size });
        errdefer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        harness.null_platform.image_decode = image_decode;

        const app_state = try testing.allocator.create(App);
        errdefer testing.allocator.destroy(app_state);
        app_state.* = App.init(std.heap.page_allocator, .{}, main.wellMusicOptions());
        app_state.effects.executor = .fake;
        try harness.start(app_state.app());
        try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .gpu_surface_frame = .{
            .label = main.canvas_label,
            .size = size,
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
            .nonblank = true,
        } });
        return .{ .harness = harness, .app_state = app_state, .size = size };
    }

    fn stop(self: LiveApp) void {
        self.app_state.deinit();
        testing.allocator.destroy(self.app_state);
        self.harness.destroy(testing.allocator);
    }

    fn dispatch(self: LiveApp, msg: Msg) !void {
        try self.app_state.dispatch(&self.harness.runtime, 1, msg);
    }
};

test "no built-in sample catalog" {
    try testing.expectEqual(@as(usize, 0), model_mod.albums.len);
    try testing.expectEqual(@as(usize, 0), model_mod.tracks.len);
    try testing.expectEqual(@as(u8, 1), model_mod.imported_album_id);
    try testing.expectEqual(@as(u8, 1), model_mod.first_user_track_id);
    try testing.expectEqualStrings("", model_mod.manifest_url_base);
}

test "user library add remove and persist round-trip" {
    var model: Model = .{};
    try testing.expect(model.addUserTrack("/Music/Alpha/Song One.mp3"));
    try testing.expect(model.addUserTrack("/Music/Beta/Song Two.m4a"));
    try testing.expect(!model.addUserTrack("/Music/Alpha/Song One.mp3"));
    try testing.expectEqual(@as(usize, 2), model.user_track_count);
    try testing.expectEqualStrings("Song One", model.user_tracks[0].title());
    try testing.expect(model.resolveTrack(model.user_tracks[0].id) != null);
    try testing.expectEqual(@as(usize, 1), model.user_album_count);
    try testing.expectEqual(@as(u8, model_mod.imported_album_id), model.user_tracks[0].album);

    model.user_tracks[0].setArtist("Alpha");
    model.userAlbumByIdMut(model_mod.imported_album_id).?.setCoverPath("/Covers/library.png");

    var buffer: [model_mod.max_library_store_bytes]u8 = undefined;
    const bytes = model.serializeLibrary(&buffer);
    try testing.expect(std.mem.startsWith(u8, bytes, model_mod.library_store_header));
    try testing.expect(std.mem.indexOf(u8, bytes, "album\t1\tLibrary\tMy Music\t") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "/Covers/library.png") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "Alpha") != null);

    var restored: Model = .{};
    try testing.expect(restored.restoreLibrary(bytes));
    try testing.expectEqual(@as(usize, 2), restored.user_track_count);
    try testing.expectEqual(@as(usize, 1), restored.user_album_count);
    try testing.expectEqualStrings(model.user_tracks[0].path(), restored.user_tracks[0].path());
    try testing.expectEqualStrings("Alpha", restored.user_tracks[0].artist());
    try testing.expectEqualStrings("/Covers/library.png", restored.userAlbumById(model_mod.imported_album_id).?.coverPath());

    const id = restored.user_tracks[0].id;
    try testing.expect(restored.removeUserTrack(id));
    try testing.expectEqual(@as(usize, 1), restored.user_track_count);
    try testing.expectEqual(@as(u8, 1), restored.user_tracks[0].number);
}

test "folder album import creates a separate album" {
    var model: Model = .{};
    try testing.expect(model.addUserTrack("/loose/a.mp3"));
    const album_id = model.addUserAlbum("Blue Album", "Weezer") orelse return error.TestUnexpectedResult;
    try testing.expect(model.addUserTrackToAlbum(album_id, "/Music/Weezer/Blue Album/01.mp3"));
    try testing.expect(model.addUserTrackToAlbum(album_id, "/Music/Weezer/Blue Album/02.mp3"));
    try testing.expectEqual(@as(usize, 2), model.user_album_count);
    try testing.expectEqual(@as(usize, 3), model.user_track_count);
    try testing.expectEqual(album_id, model.user_tracks[1].album);
    try testing.expectEqualStrings("Blue Album", model.userAlbumById(album_id).?.title());
    try testing.expectEqual(@as(usize, 2), model.tracksInAlbum(album_id));
    try testing.expectEqual(@as(usize, 1), model.tracksInAlbum(model_mod.imported_album_id));

    var buffer: [model_mod.max_library_store_bytes]u8 = undefined;
    const bytes = model.serializeLibrary(&buffer);
    var restored: Model = .{};
    try testing.expect(restored.restoreLibrary(bytes));
    try testing.expectEqual(@as(usize, 2), restored.user_album_count);
    try testing.expectEqual(@as(usize, 2), restored.tracksInAlbum(album_id));
}

test "v1 library restore stays compatible" {
    const v1 = "wellmusic-library v1\ntrack\t1\t1\tOld Song\t/Music/old.mp3\t120000\n";
    var model: Model = .{};
    try testing.expect(model.restoreLibrary(v1));
    try testing.expectEqual(@as(usize, 1), model.user_track_count);
    try testing.expectEqual(@as(usize, 1), model.user_album_count);
    try testing.expectEqualStrings("Old Song", model.user_tracks[0].title());
    try testing.expectEqualStrings("", model.user_tracks[0].artist());
    try testing.expectEqualStrings("/Music/old.mp3", model.user_tracks[0].path());
    try testing.expectEqual(@as(u8, model_mod.imported_album_id), model.user_tracks[0].album);
}

test "v2 library restore stays compatible" {
    const v2 = "wellmusic-library v2\ncover\t/Covers/library.png\ntrack\t1\t1\tOld Song\tSomeone\t/Music/old.mp3\t120000\n";
    var model: Model = .{};
    try testing.expect(model.restoreLibrary(v2));
    try testing.expectEqual(@as(usize, 1), model.user_track_count);
    try testing.expectEqualStrings("Someone", model.user_tracks[0].artist());
    try testing.expectEqualStrings("/Covers/library.png", model.userAlbumById(model_mod.imported_album_id).?.coverPath());
}

test "edit song info updates title and artist" {
    var model: Model = .{};
    try testing.expect(model.addUserTrack("/tmp/demo/Track A.mp3"));
    const id = model.user_tracks[0].id;
    try testing.expect(model.beginEditTrack(id));
    try testing.expect(model.isEditingTrack());
    model.edit_title_buffer.set("Renamed");
    model.edit_artist_buffer.set("Someone");
    try testing.expect(model.applyEditTrack());
    try testing.expect(!model.isEditingTrack());
    try testing.expectEqualStrings("Renamed", model.user_tracks[0].title());
    try testing.expectEqualStrings("Someone", model.user_tracks[0].artist());
}

test "edit album info updates title artist and year" {
    var model: Model = .{};
    const album_id = model.addUserAlbum("Blue Album", "Weezer") orelse return error.TestUnexpectedResult;
    try testing.expect(model.addUserTrackToAlbum(album_id, "/Music/Weezer/Blue Album/01.mp3"));
    try testing.expect(model.beginEditAlbum(album_id));
    try testing.expect(model.isEditingAlbum());
    try testing.expect(!model.isEditingTrack());
    model.edit_title_buffer.set("Pinkerton");
    model.edit_artist_buffer.set("Weezer");
    model.edit_year_buffer.set("1996");
    try testing.expect(model.applyEditAlbum());
    try testing.expect(!model.isEditingAlbum());
    const album = model.userAlbumById(album_id) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Pinkerton", album.title());
    try testing.expectEqualStrings("Weezer", album.artist());
    try testing.expectEqual(@as(u16, 1996), album.year);

    var buffer: [model_mod.max_library_store_bytes]u8 = undefined;
    const bytes = model.serializeLibrary(&buffer);
    var restored: Model = .{};
    try testing.expect(restored.restoreLibrary(bytes));
    const restored_album = restored.userAlbumById(album_id) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Pinkerton", restored_album.title());
    try testing.expectEqualStrings("Weezer", restored_album.artist());
    try testing.expectEqual(@as(u16, 1996), restored_album.year);
}

test "empty library shows the add-music empty state" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const tree = try buildTree(arena_state.allocator(), &Model{});
    try testing.expect(findByLabel(tree.root, "Empty library") != null);
    try testing.expect(findByLabel(tree.root, "Add to library") != null);
    try testing.expect(findByLabel(tree.root, "Switch library view") != null);
    try testing.expectEqual(@as(usize, 0), countListItems(tree.root));
}

test "library view toggle and add menu consolidate header actions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model: Model = .{};

    apply(&model, .toggle_library_view);
    try testing.expectEqual(model_mod.Tab.songs, model.tab);
    try testing.expectEqualStrings("music", model.libraryViewIcon());
    const songs_header = try buildTree(arena_state.allocator(), &model);
    try testing.expect(findByLabel(songs_header.root, "Switch library view") != null);

    apply(&model, .toggle_library_view);
    try testing.expectEqual(model_mod.Tab.albums, model.tab);
    try testing.expectEqualStrings("app:albums", model.libraryViewIcon());

    apply(&model, .toggle_add_menu);
    try testing.expect(model.add_menu_open);
    const open_tree = try buildTree(arena_state.allocator(), &model);
    try testing.expect(findByText(open_tree.root, .menu_item, "Add Song") != null);
    try testing.expect(findByText(open_tree.root, .menu_item, "Add Album") != null);

    apply(&model, .close_add_menu);
    try testing.expect(!model.add_menu_open);
}

test "imported tracks appear in albums and songs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model: Model = .{};
    try testing.expect(model.addUserTrack("/tmp/demo/Track A.mp3"));
    try testing.expect(model.addUserTrack("/tmp/demo/Track B.mp3"));

    const albums_tree = try buildTree(arena_state.allocator(), &model);
    try testing.expect(findByText(albums_tree.root, .text, "Library") != null);

    apply(&model, .show_songs);
    const songs_tree = try buildTree(arena_state.allocator(), &model);
    try testing.expectEqual(@as(usize, 2), countListItems(songs_tree.root));
    try testing.expect(findByText(songs_tree.root, .text, "Track A") != null);

    apply(&model, .{ .edit_track = model.user_tracks[0].id });
    const edit_tree = try buildTree(arena_state.allocator(), &model);
    try testing.expect(findByLabel(edit_tree.root, "Edit song") != null);
    try testing.expect(findByText(edit_tree.root, .button, "Save") != null);

    apply(&model, .close_edit_track);
    apply(&model, .{ .edit_album = model_mod.imported_album_id });
    const album_edit_tree = try buildTree(arena_state.allocator(), &model);
    try testing.expect(findByLabel(album_edit_tree.root, "Edit album") != null);
    try testing.expect(findByText(album_edit_tree.root, .button, "Save") != null);
}

test "play pause and remove drive the audio effect for imported tracks" {
    const live = try LiveApp.start(false);
    defer live.stop();
    const app_state = live.app_state;

    try testing.expect(app_state.model.addUserTrack("/tmp/wellmusic-test/song.mp3"));
    const id = app_state.model.user_tracks[0].id;
    try live.dispatch(.{ .play_track = id });
    try testing.expectEqual(@as(?u8, id), app_state.model.now);
    try testing.expect(app_state.model.playing);
    try testing.expect(app_state.effects.audio.active);
    try testing.expectEqualStrings("/tmp/wellmusic-test/song.mp3", app_state.effects.audio.path_buffer[0..app_state.effects.audio.path_len]);

    try live.dispatch(.toggle_play);
    try testing.expect(!app_state.model.playing);

    try live.dispatch(.{ .remove_track = id });
    try testing.expectEqual(@as(usize, 0), app_state.model.user_track_count);
    try testing.expectEqual(@as(?u8, null), app_state.model.now);
}

test "localAudioReadable rejects moved or missing import paths" {
    const missing = "/tmp/wellmusic-definitely-missing-xyz.mp3";
    try testing.expect(!model_mod.localAudioReadable(missing));
    try testing.expect(!model_mod.localAudioReadable(""));

    const present = "/tmp/wellmusic-readable-probe.mp3";
    {
        var threaded = std.Io.Threaded.init(testing.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var file = try std.Io.Dir.createFileAbsolute(io, present, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "ID3");
    }
    defer {
        var threaded = std.Io.Threaded.init(testing.allocator, .{});
        defer threaded.deinit();
        std.Io.Dir.deleteFileAbsolute(threaded.io(), present) catch {};
    }
    try testing.expect(model_mod.localAudioReadable(present));
}

test "audio failure clears now and leaves assets_missing" {
    var model = Model{};
    try testing.expect(model.addUserTrack("/tmp/wellmusic-test/song.mp3"));
    const id = model.user_tracks[0].id;
    apply(&model, .{ .play_track = id });
    try testing.expectEqual(@as(?u8, id), model.now);
    apply(&model, .{ .audio_event = .{ .key = id, .kind = .failed } });
    try testing.expectEqual(@as(?u8, null), model.now);
    try testing.expect(!model.playing);
    try testing.expect(model.assets_missing);
}

test "import copies audio into the media directory and remove deletes it" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const media_root = "/tmp/wellmusic-media-test";
    const source = "/tmp/wellmusic-import-source.mp3";
    {
        var file = try std.Io.Dir.createFileAbsolute(io, source, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "ID3copied");
    }
    defer std.Io.Dir.deleteFileAbsolute(io, source) catch {};

    var model = Model{};
    model.setMediaDir(media_root);
    try testing.expect(model_mod.importAudioFromSource(&model, model_mod.imported_album_id, source));
    try testing.expectEqual(@as(usize, 1), model.user_track_count);
    const managed = model.user_tracks[0].path();
    try testing.expect(std.mem.startsWith(u8, managed, media_root));
    try testing.expect(model_mod.localAudioReadable(managed));
    // Original can go away; managed copy remains playable.
    std.Io.Dir.deleteFileAbsolute(io, source) catch {};
    try testing.expect(model_mod.localAudioReadable(managed));

    const id = model.user_tracks[0].id;
    var managed_buf: [model_mod.max_user_path]u8 = undefined;
    @memcpy(managed_buf[0..managed.len], managed);
    const managed_copy = managed_buf[0..managed.len];
    try testing.expect(model.removeUserTrack(id));
    try testing.expectEqual(@as(usize, 0), model.user_track_count);
    try testing.expect(!model_mod.localAudioReadable(managed_copy));
}

test "migrateExternalMedia copies legacy absolute paths into media/" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const media_root = "/tmp/wellmusic-media-migrate";
    const source = "/tmp/wellmusic-legacy-track.flac";
    {
        var file = try std.Io.Dir.createFileAbsolute(io, source, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "fLaC");
    }
    defer std.Io.Dir.deleteFileAbsolute(io, source) catch {};

    var model = Model{};
    try testing.expect(model.addUserTrack(source));
    model.setMediaDir(media_root);
    try testing.expect(model_mod.migrateExternalMedia(&model));
    const managed = model.user_tracks[0].path();
    try testing.expect(std.mem.startsWith(u8, managed, media_root));
    try testing.expect(model_mod.localAudioReadable(managed));
    _ = model.removeUserTrack(model.user_tracks[0].id);
}

test "play mode cycles and drives list loop single loop sequential and shuffle" {
    var model = Model{};
    const album_id = model.addUserAlbum("Demo", "Artist") orelse return error.TestUnexpectedResult;
    try testing.expect(model.addUserTrackToAlbum(album_id, "/tmp/demo/01.mp3"));
    try testing.expect(model.addUserTrackToAlbum(album_id, "/tmp/demo/02.mp3"));
    try testing.expect(model.addUserTrackToAlbum(album_id, "/tmp/demo/03.mp3"));
    const a = model.user_tracks[0].id;
    const b = model.user_tracks[1].id;
    const c = model.user_tracks[2].id;

    try testing.expectEqual(model_mod.PlayMode.list_loop, model.play_mode);
    try testing.expectEqualStrings("repeat", model.playModeIcon());
    apply(&model, .cycle_play_mode);
    try testing.expectEqual(model_mod.PlayMode.single_loop, model.play_mode);
    try testing.expectEqualStrings("app:repeat-1", model.playModeIcon());
    apply(&model, .cycle_play_mode);
    try testing.expectEqual(model_mod.PlayMode.shuffle, model.play_mode);
    try testing.expectEqualStrings("shuffle", model.playModeIcon());
    apply(&model, .cycle_play_mode);
    try testing.expectEqual(model_mod.PlayMode.sequential, model.play_mode);
    try testing.expectEqualStrings("app:sequential", model.playModeIcon());
    apply(&model, .cycle_play_mode);
    try testing.expectEqual(model_mod.PlayMode.list_loop, model.play_mode);

    // List loop wraps the album on completion.
    apply(&model, .{ .play_track = c });
    apply(&model, .{ .audio_event = .{ .key = c, .kind = .completed } });
    try testing.expectEqual(@as(?u8, a), model.now);
    try testing.expect(model.playing);

    // Single loop restarts the same track on completion; next still advances.
    model.play_mode = .single_loop;
    apply(&model, .{ .play_track = b });
    apply(&model, .{ .audio_event = .{ .key = b, .kind = .completed } });
    try testing.expectEqual(@as(?u8, b), model.now);
    try testing.expect(model.playing);
    apply(&model, .next_track);
    try testing.expectEqual(@as(?u8, c), model.now);

    // Sequential stops on the last track; next on the last is a no-op.
    model.play_mode = .sequential;
    apply(&model, .{ .play_track = c });
    apply(&model, .{ .audio_event = .{ .key = c, .kind = .completed } });
    try testing.expectEqual(@as(?u8, c), model.now);
    try testing.expect(!model.playing);
    apply(&model, .{ .play_track = c });
    apply(&model, .next_track);
    try testing.expectEqual(@as(?u8, c), model.now);
    try testing.expect(model.playing);
    apply(&model, .{ .play_track = a });
    apply(&model, .next_track);
    try testing.expectEqual(@as(?u8, b), model.now);

    // Shuffle leaves the current album and never sticks on a solo choice
    // when more than one track exists.
    model.play_mode = .shuffle;
    apply(&model, .{ .play_track = a });
    var saw_other = false;
    var i: usize = 0;
    while (i < 24) : (i += 1) {
        const before = model.now.?;
        apply(&model, .next_track);
        if (model.now.? != before) saw_other = true;
        try testing.expect(model.now == a or model.now == b or model.now == c);
    }
    try testing.expect(saw_other);

    // Play Next still wins when the current track is not in the playlist.
    model.play_mode = .list_loop;
    apply(&model, .{ .play_track = a });
    apply(&model, .{ .queue_track = c });
    apply(&model, .next_track);
    try testing.expectEqual(@as(?u8, c), model.now);
}

test "the system appearance drives the custom tokens live" {
    const live = try LiveApp.start(true);
    defer live.stop();
    const app_state = live.app_state;

    try testing.expectEqual(model_mod.ThemePreference.system, app_state.model.theme);
    try testing.expectEqualDeep(theme.light_colors, main.tokensFromModel(&app_state.model).colors);
    const pink = canvas.Color.rgb8(207, 38, 104);
    try testing.expectEqualDeep(pink, theme.light_colors.accent);

    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .appearance_changed = .{ .color_scheme = .dark } });
    try testing.expectEqualDeep(theme.dark_colors, main.tokensFromModel(&app_state.model).colors);

    try live.harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .appearance_changed = .{ .color_scheme = .light } });
    try testing.expectEqualDeep(theme.light_colors, (try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label)).colors);
}

test "toggle theme locks light and dark off the system appearance" {
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var model = model_mod.Model{};
    model.appearance.color_scheme = .light;
    try testing.expectEqual(model_mod.ThemePreference.system, model.theme);
    try testing.expectEqual(native_sdk.ColorScheme.light, model.colorScheme());
    try testing.expectEqualStrings("moon", model.themeIcon());

    model_mod.update(&model, .toggle_theme, &fx);
    try testing.expectEqual(model_mod.ThemePreference.dark, model.theme);
    try testing.expectEqual(native_sdk.ColorScheme.dark, model.colorScheme());
    try testing.expectEqualStrings("sun", model.themeIcon());
    try testing.expectEqualDeep(theme.dark_colors, main.tokensFromModel(&model).colors);

    // System flips to light; the locked dark preference wins.
    model_mod.update(&model, .{ .set_appearance = .{ .color_scheme = .light } }, &fx);
    try testing.expectEqual(native_sdk.ColorScheme.dark, model.colorScheme());
    try testing.expectEqualDeep(theme.dark_colors, main.tokensFromModel(&model).colors);

    model_mod.update(&model, .toggle_theme, &fx);
    try testing.expectEqual(model_mod.ThemePreference.light, model.theme);
    try testing.expectEqual(native_sdk.ColorScheme.light, model.colorScheme());
    try testing.expectEqualDeep(theme.light_colors, main.tokensFromModel(&model).colors);
}

test "light and dark schemes keep page and chrome one step apart" {
    // Geist stocks both schemes with identical page/surface fills; the
    // app's elevation override is what makes the header and now-playing
    // bar read as bands. Guard both schemes so a future pack bump that
    // re-collapses them cannot silently undo the light fix. Values are
    // OKLCH L steps snapped to sRGB (see theme.zig).
    try testing.expectEqual(canvas.Color.rgb8(240, 240, 240), theme.light_colors.background);
    try testing.expectEqual(canvas.Color.rgb8(255, 255, 255), theme.light_colors.surface);
    try testing.expectEqual(canvas.Color.rgb8(16, 16, 16), theme.dark_colors.background);
    try testing.expectEqual(canvas.Color.rgb8(32, 32, 32), theme.dark_colors.surface);
    // Body ink keeps an honest lightness gap on the lifted page.
    try testing.expectEqual(canvas.Color.rgb8(22, 22, 22), theme.light_colors.text);
    try testing.expectEqual(canvas.Color.rgb8(238, 238, 238), theme.dark_colors.text);
}

test "chrome geometry pads the header and matches its height to the tall band" {
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var model = model_mod.Model{};
    try testing.expectEqual(model_mod.header_natural_height, model.header_height);

    const chrome: native_sdk.WindowChrome = .{
        .insets = .{ .top = 52, .left = 78 },
        .buttons = native_sdk.geometry.RectF.init(20, 19, 52, 14),
    };
    const msg = main.onChrome(chrome) orelse return error.TestUnexpectedResult;
    model_mod.update(&model, msg, &fx);
    try testing.expectEqual(@as(f32, 78), model.chrome_leading);
    try testing.expectEqual(@max(model_mod.header_natural_height, 52), model.header_height);
    try testing.expectEqual(.hidden_inset_tall, main.shell_scene.windows[0].titlebar);
}

test "the form-factor rule: compact strictly below the desktop floor" {
    var model = Model{};
    model.canvas_width = model_mod.min_canvas_width;
    try testing.expectEqual(model_mod.FormFactor.regular, model.formFactor());
    model.canvas_width = model_mod.min_canvas_width - 1;
    try testing.expectEqual(model_mod.FormFactor.compact, model.formFactor());
}

test "markup engine parity: header and now-playing build identical trees" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    try testing.expect(model.addUserTrack("/tmp/a.mp3"));
    try testing.expect(model.addUserTrack("/tmp/b.mp3"));
    apply(&model, .{ .play_track = model.user_tracks[0].id });
    apply(&model, .{ .queue_track = model.user_tracks[1].id });

    inline for (.{
        .{ view_mod.header_markup, view_mod.CompiledHeaderView },
        .{ view_mod.nowplaying_markup, view_mod.CompiledNowPlayingView },
    }) |case| {
        var interpreter = try canvas.MarkupView(Model, Msg).init(arena, case[0]);
        var compiled_ui = Ui.init(arena);
        const compiled = try compiled_ui.finalize(case[1].build(&compiled_ui, &model));
        var interpreted_ui = Ui.init(arena);
        const interpreted = try interpreted_ui.finalize(try interpreter.build(&interpreted_ui, &model));

        var compiled_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
        defer compiled_ids.deinit(testing.allocator);
        var interpreted_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
        defer interpreted_ids.deinit(testing.allocator);
        try collectIds(compiled.root, &compiled_ids, testing.allocator);
        try collectIds(interpreted.root, &interpreted_ids, testing.allocator);
        try testing.expectEqualSlices(canvas.ObjectId, interpreted_ids.items, compiled_ids.items);
        try testing.expectEqual(interpreted.handlers.len, compiled.handlers.len);
    }
}

test "album detail heading markup matches the hand-built paragraph" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    try testing.expect(model.addUserTrack("/tmp/a.mp3"));
    apply(&model, .{ .open_album = model_mod.imported_album_id });
    const album = model.albumById(model_mod.imported_album_id) orelse return error.TestUnexpectedResult;

    var markup_ui = Ui.init(arena);
    const markup_node = view_mod.AlbumTitleView.build(&markup_ui, &model);
    var hand_ui = Ui.init(arena);
    const hand_node = hand_ui.paragraph(.{ .semantics = .{ .label = album.title } }, &.{
        .{ .text = album.title, .weight = .bold, .scale = 2.05 },
    });

    try testing.expectEqualStrings(hand_node.widget.text, markup_node.widget.text);
    try testing.expectEqualStrings("Library", markup_node.widget.text);
}

fn countWidgets(widget: canvas.Widget) usize {
    var total: usize = 1;
    for (widget.children) |child| total += countWidgets(child);
    return total;
}

test "empty and seeded trees stay within the widget budget" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const empty = try buildTree(arena, &Model{});
    try testing.expect(countWidgets(empty.root) < 1024);

    var model: Model = .{};
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/tmp/track-{d}.mp3", .{i});
        try testing.expect(model.addUserTrack(path));
    }
    apply(&model, .show_songs);
    const seeded = try buildTree(arena, &model);
    try testing.expectEqual(@as(usize, 8), countListItems(seeded.root));
    try testing.expect(countWidgets(seeded.root) < 1024);
}

test "compact shell composes on a phone-sized surface" {
    const live = try LiveApp.startSized(false, phone_size);
    defer live.stop();
    try live.dispatch(.{ .canvas_resized = phone_size.width });
    try testing.expectEqual(model_mod.FormFactor.compact, live.app_state.model.formFactor());

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const tree = try buildTree(arena_state.allocator(), &live.app_state.model);
    try testing.expect(findByLabel(tree.root, "Compact header") != null);
}

test "session round-trip restores now queue mode theme and volume" {
    var model: Model = .{};
    try testing.expect(model.addUserTrack("/Music/a.mp3"));
    try testing.expect(model.addUserTrack("/Music/b.mp3"));
    const a = model.user_tracks[0].id;
    const b = model.user_tracks[1].id;
    model.now = a;
    model.elapsed_ms = 12345;
    model.playing = true;
    model.play_mode = .shuffle;
    model.theme = .dark;
    model.volume = 0.4;
    model.queue_open = true;
    model.queue[0] = b;
    model.queue_len = 1;

    var buffer: [model_mod.max_session_store_bytes]u8 = undefined;
    const bytes = model.serializeSession(&buffer);
    try testing.expect(std.mem.startsWith(u8, bytes, model_mod.session_store_header));
    try testing.expect(std.mem.indexOf(u8, bytes, "theme\tdark\n") != null);

    var restored: Model = .{};
    try testing.expect(restored.addUserTrack("/Music/a.mp3"));
    try testing.expect(restored.addUserTrack("/Music/b.mp3"));
    try testing.expect(restored.restoreSession(bytes));
    try testing.expectEqual(model_mod.PlayMode.shuffle, restored.play_mode);
    try testing.expectEqual(model_mod.ThemePreference.dark, restored.theme);
    try testing.expectApproxEqAbs(@as(f32, 0.4), restored.volume, 0.0001);
    try testing.expect(restored.queue_open);
    try testing.expectEqual(@as(usize, 1), restored.queue_len);
    try testing.expectEqual(b, restored.queue[0]);
    try testing.expectEqual(@as(?u8, a), restored.session_resume_track);
    try testing.expectEqual(@as(u32, 12345), restored.session_resume_elapsed_ms);
    try testing.expect(restored.session_resume_playing);
}

test "play album fills the playlist with every track and list-loop wraps it" {
    var model = Model{};
    const album_id = model.addUserAlbum("Demo", "Artist") orelse return error.TestUnexpectedResult;
    try testing.expect(model.addUserTrackToAlbum(album_id, "/tmp/demo/01.mp3"));
    try testing.expect(model.addUserTrackToAlbum(album_id, "/tmp/demo/02.mp3"));
    try testing.expect(model.addUserTrackToAlbum(album_id, "/tmp/demo/03.mp3"));
    const a = model.user_tracks[0].id;
    const b = model.user_tracks[1].id;
    const c = model.user_tracks[2].id;

    // Stale play-next entries from another context must be replaced.
    apply(&model, .{ .queue_track = a });
    apply(&model, .{ .play_album = album_id });

    try testing.expectEqual(@as(?u8, a), model.now);
    try testing.expect(model.playing);
    try testing.expect(model.queue_open);
    try testing.expectEqual(@as(usize, 3), model.queue_len);
    try testing.expectEqual(a, model.queue[0]);
    try testing.expectEqual(b, model.queue[1]);
    try testing.expectEqual(c, model.queue[2]);

    apply(&model, .next_track);
    try testing.expectEqual(@as(?u8, b), model.now);
    // Playlist stays intact while advancing — not a consuming FIFO.
    try testing.expectEqual(@as(usize, 3), model.queue_len);
    try testing.expectEqual(a, model.queue[0]);

    apply(&model, .{ .play_track = c });
    apply(&model, .{ .audio_event = .{ .key = c, .kind = .completed } });
    try testing.expectEqual(@as(?u8, a), model.now);
    try testing.expect(model.playing);
    try testing.expectEqual(@as(usize, 3), model.queue_len);
}

test "queue panel appears when play-next is open" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model: Model = .{};
    try testing.expect(model.addUserTrack("/tmp/demo/Track A.mp3"));
    try testing.expect(model.addUserTrack("/tmp/demo/Track B.mp3"));
    apply(&model, .{ .queue_track = model.user_tracks[1].id });
    try testing.expect(model.queue_open);
    try testing.expectEqual(@as(usize, 1), model.queue_len);

    const tree = try buildTree(arena_state.allocator(), &model);
    try testing.expect(findByLabel(tree.root, "Playlist") != null);
    try testing.expect(findByText(tree.root, .button, "Clear") != null);
    try testing.expect(findByLabel(tree.root, "Toggle play-next queue") != null);
}

test "queue toggle is always on the now-playing bar" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model: Model = .{};
    try testing.expect(model.addUserTrack("/tmp/demo/Track A.mp3"));
    try testing.expectEqual(@as(usize, 0), model.queue_len);
    try testing.expect(!model.queue_open);

    const closed = try buildTree(arena_state.allocator(), &model);
    try testing.expect(findByLabel(closed.root, "Toggle play-next queue") != null);
    try testing.expect(findByLabel(closed.root, "Playlist") == null);

    apply(&model, .toggle_queue);
    try testing.expect(model.queue_open);
    const open = try buildTree(arena_state.allocator(), &model);
    try testing.expect(findByLabel(open.root, "Playlist") != null);
    try testing.expect(findByText(open.root, .button, "Clear") == null);
}

test "media command keys map through onKey" {
    const play = main.onKey(.{ .key = "MediaPlayPause", .phase = .key_down, .modifiers = .{} });
    try testing.expectEqual(Msg{ .media_command = .toggle_play }, play.?);
    const next = main.onKey(.{ .key = "F9", .phase = .key_down, .modifiers = .{} });
    try testing.expectEqual(Msg{ .media_command = .next }, next.?);
    const prev = main.onKey(.{ .key = "F7", .phase = .key_down, .modifiers = .{} });
    try testing.expectEqual(Msg{ .media_command = .previous }, prev.?);
}
