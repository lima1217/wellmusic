//! wellmusic tests: user library add/remove/persist, empty-library UI,
//! theming, chrome, and markup parity. There is no
//! built-in sample catalog — playback assertions seed imported tracks.

const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");
const model_mod = @import("model.zig");
const theme = @import("theme.zig");
const ui_font = @import("ui_font.zig");
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

fn applyFx(model: *Model, msg: Msg, fx: *model_mod.Effects) void {
    main.update(model, msg, fx);
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
    try testing.expectEqual(@as(u8, 1), model_mod.imported_album_id);
    try testing.expectEqual(@as(u8, 1), model_mod.first_user_track_id);
    const model = Model{};
    try testing.expectEqual(@as(usize, 0), model.user_album_count);
    try testing.expectEqual(@as(usize, 0), model.user_track_count);
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

test "track ids recycle so repeated add/remove never exhausts the id space" {
    var model: Model = .{};
    var path_buf: [64]u8 = undefined;
    var round: usize = 0;
    // Well past 255 cumulative imports: a monotonic u8 counter would
    // overflow here.
    while (round < 300) : (round += 1) {
        const path = try std.fmt.bufPrint(&path_buf, "/tmp/cycle-{d}.mp3", .{round});
        try testing.expect(model.addUserTrack(path));
        try testing.expectEqual(@as(u8, model_mod.first_user_track_id), model.user_tracks[0].id);
        try testing.expect(model.removeUserTrack(model.user_tracks[0].id));
    }
    try testing.expectEqual(@as(usize, 0), model.user_track_count);
}

test "a restored library with id 255 still accepts imports" {
    var model: Model = .{};
    const bytes = model_mod.library_store_header ++ "\n" ++
        "album\t1\tLibrary\tMy Music\t2026\t\n" ++
        "track\t255\t1\t1\tLast\t\t/Music/last.mp3\t0\n";
    try testing.expect(model.restoreLibrary(bytes));
    try testing.expect(model.addUserTrack("/Music/next.mp3"));
    try testing.expectEqual(@as(u8, model_mod.first_user_track_id), model.user_tracks[1].id);
}

test "library capacity holds more than an album's worth of tracks" {
    var model: Model = .{};
    var path_buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < model_mod.max_user_tracks) : (i += 1) {
        const path = try std.fmt.bufPrint(&path_buf, "/tmp/cap-{d}.mp3", .{i});
        try testing.expect(model.addUserTrack(path));
    }
    try testing.expect(!model.addUserTrack("/tmp/one-too-many.mp3"));
    try testing.expectEqual(@as(u8, model_mod.max_user_tracks), model.userTrackById(model_mod.max_user_tracks).?.number);
}

test "title truncation keeps whole UTF-8 sequences" {
    var track: model_mod.UserTrack = .{};
    // 43 three-byte CJK characters = 129 bytes: one byte over the cap.
    const long = "\u{97f3}" ** 43;
    track.setTitle(long);
    try testing.expectEqual(@as(usize, 126), track.title().len);
    try testing.expect(std.unicode.utf8ValidateSlice(track.title()));
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

test "edit album info updates title and artist" {
    var model: Model = .{};
    const album_id = model.addUserAlbum("Blue Album", "Weezer") orelse return error.TestUnexpectedResult;
    try testing.expect(model.addUserTrackToAlbum(album_id, "/Music/Weezer/Blue Album/01.mp3"));
    try testing.expect(model.beginEditAlbum(album_id));
    try testing.expect(model.isEditingAlbum());
    try testing.expect(!model.isEditingTrack());
    model.edit_title_buffer.set("Pinkerton");
    model.edit_artist_buffer.set("Weezer");
    try testing.expect(model.applyEditAlbum());
    try testing.expect(!model.isEditingAlbum());
    const album = model.userAlbumById(album_id) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Pinkerton", album.title());
    try testing.expectEqualStrings("Weezer", album.artist());

    var buffer: [model_mod.max_library_store_bytes]u8 = undefined;
    const bytes = model.serializeLibrary(&buffer);
    var restored: Model = .{};
    try testing.expect(restored.restoreLibrary(bytes));
    const restored_album = restored.userAlbumById(album_id) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Pinkerton", restored_album.title());
    try testing.expectEqualStrings("Weezer", restored_album.artist());
}

test "empty library shows the add-music empty state" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const tree = try buildTree(arena_state.allocator(), &Model{});
    try testing.expect(findByLabel(tree.root, "Your library is empty") != null);
    try testing.expect(findByLabel(tree.root, "Add to library") != null);
    try testing.expect(findByLabel(tree.root, "More") != null);
    try testing.expectEqual(@as(usize, 0), countListItems(tree.root));
}

test "sync library load paints albums before first frame" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var seeded: Model = .{};
    try testing.expect(seeded.addUserTrack("/Music/Alpha/Song One.mp3"));
    var store_buf: [model_mod.max_library_store_bytes]u8 = undefined;
    const bytes = seeded.serializeLibrary(&store_buf);

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const store_path = "/tmp/wellmusic-sync-library-load.txt";
    {
        var file = try std.Io.Dir.createFileAbsolute(io, store_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, bytes);
    }
    defer std.Io.Dir.deleteFileAbsolute(io, store_path) catch {};

    var model: Model = .{};
    model.setStorePath(store_path);
    model_mod.loadLibrarySync(&model);
    try testing.expectEqual(@as(usize, 1), model.user_album_count);
    try testing.expectEqual(@as(usize, 1), model.user_track_count);

    const tree = try buildTree(arena_state.allocator(), &model);
    try testing.expect(findByLabel(tree.root, "Your library is empty") == null);
    try testing.expect(findByText(tree.root, .text, "Library") != null);
}

test "first frame hydrates library after album grid can paint" {
    var model: Model = .{};
    try testing.expect(model.addUserTrack("/Music/Alpha/Song One.mp3"));
    model.library_hydrate_pending = true;

    const frame = native_sdk.platform.GpuFrame{
        .size = geometry.SizeF.init(model.canvas_width, 720),
    };
    const msg = main.onFrame(&model, frame);
    try testing.expect(msg != null);
    try testing.expect(msg.? == .library_hydrate);

    apply(&model, msg.?);
    try testing.expect(!model.library_hydrate_pending);
    try testing.expect(model.cover_hydrate_pending);

    // Covers trickle one present later; albums without paths clear in one tick.
    const cover_msg = main.onFrame(&model, frame);
    try testing.expect(cover_msg != null);
    try testing.expect(cover_msg.? == .cover_hydrate);
    apply(&model, cover_msg.?);
    try testing.expect(!model.cover_hydrate_pending);

    // Then tag re-probes, one track per present.
    while (main.onFrame(&model, frame)) |heal_msg| {
        try testing.expect(heal_msg == .title_heal);
        apply(&model, heal_msg);
    }
    try testing.expect(!model.title_heal_pending);
}

test "header overflow consolidates add and theme actions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model: Model = .{};

    apply(&model, .toggle_header_menu);
    try testing.expect(model.header_menu_open);
    const open_tree = try buildTree(arena_state.allocator(), &model);
    try testing.expect(findByLabel(open_tree.root, "More") != null);
    try testing.expect(findByText(open_tree.root, .menu_item, "Add Song") != null);
    try testing.expect(findByText(open_tree.root, .menu_item, "Add Album") != null);
    try testing.expect(findByText(open_tree.root, .menu_item, "Dark mode") != null);

    apply(&model, .close_header_menu);
    try testing.expect(!model.header_menu_open);
}

test "imported tracks appear in albums and edit dialogs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model: Model = .{};
    try testing.expect(model.addUserTrack("/tmp/demo/Track A.mp3"));
    try testing.expect(model.addUserTrack("/tmp/demo/Track B.mp3"));

    const albums_tree = try buildTree(arena_state.allocator(), &model);
    try testing.expect(findByText(albums_tree.root, .text, "Library") != null);

    apply(&model, .{ .edit_track = model.user_tracks[0].id });
    const edit_tree = try buildTree(arena_state.allocator(), &model);
    try testing.expect(findByLabel(edit_tree.root, "Edit Song") != null);
    try testing.expect(findByText(edit_tree.root, .button, "Save") != null);

    apply(&model, .close_edit_track);
    apply(&model, .{ .edit_album = model_mod.imported_album_id });
    const album_edit_tree = try buildTree(arena_state.allocator(), &model);
    try testing.expect(findByLabel(album_edit_tree.root, "Edit Album") != null);
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
    // Untagged import must keep the original basename, not "t1".
    try testing.expectEqualStrings("wellmusic-import-source", model.user_tracks[0].title());
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

test "import with media dir never titles a track as t{id}" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const media_root = "/tmp/wellmusic-media-title-test";
    const source = "/tmp/My Favorite Song.flac";
    const managed = "/tmp/wellmusic-media-title-test/t1.flac";
    {
        var file = try std.Io.Dir.createFileAbsolute(io, source, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "fLaC");
    }
    defer std.Io.Dir.deleteFileAbsolute(io, source) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, managed) catch {};

    var model = Model{};
    model.setMediaDir(media_root);
    try testing.expect(model_mod.importAudioFromSource(&model, model_mod.imported_album_id, source));
    try testing.expectEqualStrings("My Favorite Song", model.user_tracks[0].title());
    try testing.expect(std.mem.indexOf(u8, model.user_tracks[0].path(), "/t1.flac") != null);
}

test "refreshTitlesFromMedia heals managed basename fallbacks when tags appear" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const managed = "/tmp/wellmusic-refresh-t1.mp3";
    defer std.Io.Dir.deleteFileAbsolute(io, managed) catch {};

    // Minimal ID3v2.3 with TIT2 only (same shape as metadata.zig unit test).
    var body: [64]u8 = undefined;
    var len: usize = 0;
    const title = "Recovered Title";
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
    body[len] = 0;
    len += 1;
    @memcpy(body[len .. len + title.len], title);
    len += title.len;

    var tag: [128]u8 = undefined;
    tag[0] = 'I';
    tag[1] = 'D';
    tag[2] = '3';
    tag[3] = 3;
    tag[4] = 0;
    tag[5] = 0;
    tag[6] = 0;
    tag[7] = 0;
    tag[8] = 0;
    tag[9] = @intCast(len);
    @memcpy(tag[10 .. 10 + len], body[0..len]);
    {
        var file = try std.Io.Dir.createFileAbsolute(io, managed, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, tag[0 .. 10 + len]);
    }

    var model = Model{};
    try testing.expect(model.addUserTrack(managed));
    // Simulate the pre-fix bug: title left as managed basename.
    model.user_tracks[0].setTitle("wellmusic-refresh-t1");
    try testing.expect(model.refreshTitlesFromMedia());
    try testing.expectEqualStrings("Recovered Title", model.user_tracks[0].title());
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

test "shuffle and repeat are independent controls" {
    var model = Model{};
    const album_id = model.addUserAlbum("Demo", "Artist") orelse return error.TestUnexpectedResult;
    try testing.expect(model.addUserTrackToAlbum(album_id, "/tmp/demo/01.mp3"));
    try testing.expect(model.addUserTrackToAlbum(album_id, "/tmp/demo/02.mp3"));
    try testing.expect(model.addUserTrackToAlbum(album_id, "/tmp/demo/03.mp3"));
    const a = model.user_tracks[0].id;
    const b = model.user_tracks[1].id;
    const c = model.user_tracks[2].id;

    try testing.expectEqual(model_mod.Repeat.all, model.repeat);
    try testing.expect(model.repeatActive());
    try testing.expectEqualStrings("repeat", model.repeatIcon());
    apply(&model, .cycle_repeat);
    try testing.expectEqual(model_mod.Repeat.one, model.repeat);
    try testing.expectEqualStrings("app:repeat-one", model.repeatIcon());
    apply(&model, .cycle_repeat);
    try testing.expectEqual(model_mod.Repeat.off, model.repeat);
    try testing.expect(!model.repeatActive());
    apply(&model, .cycle_repeat);
    try testing.expectEqual(model_mod.Repeat.all, model.repeat);
    apply(&model, .toggle_shuffle);
    try testing.expect(model.shuffle);
    try testing.expectEqual(model_mod.Repeat.all, model.repeat);
    apply(&model, .toggle_shuffle);
    try testing.expect(!model.shuffle);

    // Double-click play appends to the playlist; list loop wraps that list.
    apply(&model, .{ .play_track = a });
    apply(&model, .{ .play_track = b });
    apply(&model, .{ .play_track = c });
    try testing.expectEqual(@as(usize, 3), model.queue_len);
    try testing.expectEqual(a, model.queue[0]);
    try testing.expectEqual(b, model.queue[1]);
    try testing.expectEqual(c, model.queue[2]);
    apply(&model, .{ .audio_event = .{ .key = c, .kind = .completed } });
    try testing.expectEqual(@as(?u8, a), model.now);
    try testing.expect(model.playing);

    // Sequential stops on the last playlist track; next on the last is a no-op.
    model.repeat = .off;
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

    // When the current track is not in the playlist, album order resumes;
    // Play Next still wins as a one-shot FIFO ahead of that.
    model.repeat = .all;
    apply(&model, .clear_queue);
    try testing.expectEqual(@as(usize, 0), model.queue_len);
    try testing.expectEqual(@as(?u8, b), model.now);
    apply(&model, .next_track);
    try testing.expectEqual(@as(?u8, c), model.now);
    apply(&model, .{ .queue_track = a });
    apply(&model, .next_track);
    try testing.expectEqual(@as(?u8, a), model.now);
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

test "without a loaded UI face tokens keep the pack default font" {
    // The suite never calls prepareUiFonts, so ready() stays false and
    // typography must not silently pick up the registered-slot id.
    try testing.expect(!ui_font.ready());
    const pack_default = canvas.DesignTokens.theme(.{
        .pack = .geist,
        .color_scheme = .light,
    }).typography.font_id;
    const resolved = theme.tokens(.light, false, false).typography.font_id;
    try testing.expectEqual(pack_default, resolved);
    try testing.expect(resolved != ui_font.font_id);
}

test "high contrast skips the pink accent and takes the pack loud register" {
    const pack_high = canvas.DesignTokens.theme(.{
        .pack = .geist,
        .color_scheme = .light,
        .contrast = .high,
    });
    try testing.expectEqualDeep(pack_high.colors, theme.tokens(.light, true, false).colors);
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
    try testing.expectEqual(@as(f32, 52), model.header_height);
    try testing.expectEqual(.hidden_inset_tall, main.shell_scene.windows[0].titlebar);

    // A shorter host band must win: painting taller than the OS titlebar
    // leaves cross-centered controls reading as top-heavy in the band.
    const short_band: native_sdk.WindowChrome = .{
        .insets = .{ .top = 44, .left = 78 },
        .buttons = native_sdk.geometry.RectF.init(20, 15, 52, 14),
    };
    const short_msg = main.onChrome(short_band) orelse return error.TestUnexpectedResult;
    model_mod.update(&model, short_msg, &fx);
    try testing.expectEqual(@as(f32, 44), model.header_height);
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
    const seeded = try buildTree(arena, &model);
    try testing.expectEqual(@as(usize, 1), countListItems(seeded.root));
    try testing.expect(countWidgets(seeded.root) < 1024);
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
    model.repeat = .all;
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
    try testing.expectEqual(model_mod.Repeat.all, restored.repeat);
    try testing.expectEqual(model_mod.ThemePreference.dark, restored.theme);
    try testing.expectApproxEqAbs(@as(f32, 0.4), restored.volume, 0.0001);
    try testing.expect(restored.queue_open);
    try testing.expectEqual(@as(usize, 1), restored.queue_len);
    try testing.expectEqual(b, restored.queue[0]);
    try testing.expectEqual(@as(?u8, a), restored.session_resume_track);
    try testing.expectEqual(@as(u32, 12345), restored.session_resume_elapsed_ms);
    try testing.expect(restored.session_resume_playing);
}

test "session resume restores volume and never auto-plays" {
    var model: Model = .{};
    try testing.expect(model.addUserTrack("/Music/a.mp3"));
    const a = model.user_tracks[0].id;
    model.now = a;
    model.elapsed_ms = 5000;
    model.playing = true;
    model.volume = 0.35;

    var buffer: [model_mod.max_session_store_bytes]u8 = undefined;
    const bytes = model.serializeSession(&buffer);

    var restored: Model = .{};
    try testing.expect(restored.addUserTrack("/Music/a.mp3"));

    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    applyFx(&restored, .{ .session_done = .{
        .key = model_mod.session_read_key,
        .op = .read,
        .outcome = .ok,
        .bytes = bytes,
    } }, &fx);

    try testing.expectEqual(@as(?u8, a), restored.now);
    try testing.expect(!restored.playing);
    try testing.expect(restored.audio_deferred);
    try testing.expectEqual(@as(u32, 5000), restored.elapsed_ms);
    try testing.expectApproxEqAbs(@as(f32, 0.35), restored.volume, 0.0001);
    try testing.expectEqual(@as(?u8, null), restored.session_resume_track);
    // Cold launch must not decode audio just to paint the transport.
    try testing.expect(fx.pendingAudio() == null);

    // Volume rides the Msg payload — not the rebuild-time sync path that
    // used to clobber a restored value with the previous slider thumb.
    apply(&restored, .{ .volume_changed = 0.2 });
    try testing.expectApproxEqAbs(@as(f32, 0.2), restored.volume, 0.0001);
}

test "session resume engages the player only on first play" {
    var model: Model = .{};
    try testing.expect(model.addUserTrack("/Music/a.mp3"));
    const a = model.user_tracks[0].id;
    model.now = a;
    model.elapsed_ms = 5000;
    model.playing = true;

    var buffer: [model_mod.max_session_store_bytes]u8 = undefined;
    const bytes = model.serializeSession(&buffer);

    var restored: Model = .{};
    try testing.expect(restored.addUserTrack("/Music/a.mp3"));
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    applyFx(&restored, .{ .session_done = .{
        .key = model_mod.session_read_key,
        .op = .read,
        .outcome = .ok,
        .bytes = bytes,
    } }, &fx);
    try testing.expect(restored.audio_deferred);
    try testing.expect(fx.pendingAudio() == null);

    applyFx(&restored, .toggle_play, &fx);
    try testing.expect(restored.playing);
    try testing.expect(!restored.audio_deferred);
    try testing.expectEqual(@as(u32, 5000), restored.elapsed_ms);
    const audio = fx.pendingAudio() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(a, audio.key);
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
    try testing.expect(model.queue_open);
    // User closed the panel; Play Album must start playback without
    // reopening it.
    apply(&model, .toggle_queue);
    try testing.expect(!model.queue_open);
    apply(&model, .{ .play_album = album_id });

    try testing.expectEqual(@as(?u8, a), model.now);
    try testing.expect(model.playing);
    try testing.expect(!model.queue_open);
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

fn audioPollPending(fx: *model_mod.Effects) bool {
    var i: usize = 0;
    while (i < fx.pendingTimerCount()) : (i += 1) {
        const timer = fx.pendingTimerAt(i) orelse continue;
        if (timer.key == model_mod.audio_poll_timer_key) return true;
    }
    return false;
}

test "audio poll timer arms while playing and cancels on pause" {
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var model: Model = .{};
    try testing.expect(model.addUserTrack("/tmp/wellmusic-test/poll.mp3"));
    const id = model.user_tracks[0].id;

    applyFx(&model, .{ .play_track = id }, &fx);
    try testing.expect(model.playing);
    try testing.expect(audioPollPending(&fx));
    try testing.expectEqual(model_mod.audio_poll_interval_ms, fx.pendingTimerAt(0).?.interval_ms);
    try testing.expectEqual(@as(u64, 2000), model_mod.audio_poll_interval_ms);

    applyFx(&model, .toggle_play, &fx);
    try testing.expect(!model.playing);
    try testing.expect(!audioPollPending(&fx));
}

test "libraryNeedsCjkFont detects CJK catalog text" {
    var model: Model = .{};
    try testing.expect(!model_mod.libraryNeedsCjkFont(&model));
    try testing.expect(model.addUserTrack("/tmp/wellmusic-test/latin.mp3"));
    try testing.expect(!model_mod.libraryNeedsCjkFont(&model));
    model.user_tracks[0].setTitle("夜曲");
    try testing.expect(model_mod.libraryNeedsCjkFont(&model));
}

test "cover hydrate loads one unresolved album cover per tick" {
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var model: Model = .{};
    const a = model.addUserAlbum("A", "Artist") orelse unreachable;
    const b = model.addUserAlbum("B", "Artist") orelse unreachable;
    if (model.userAlbumByIdMut(a)) |album| album.setCoverPath("/tmp/wellmusic-cover-a.png");
    if (model.userAlbumByIdMut(b)) |album| album.setCoverPath("/tmp/wellmusic-cover-b.png");

    model_mod.armCoverHydrate(&model);
    try testing.expect(model.cover_hydrate_pending);
    try testing.expectEqual(@as(usize, 0), model.cover_hydrate_index);

    applyFx(&model, .cover_hydrate, &fx);
    try testing.expect(model.cover_hydrate_pending);
    try testing.expectEqual(@as(usize, 1), model.cover_hydrate_index);

    applyFx(&model, .cover_hydrate, &fx);
    try testing.expect(!model.cover_hydrate_pending);
    try testing.expectEqual(@as(usize, 2), model.cover_hydrate_index);
}

test "oversized cover downscales into the canvas image slot" {
    // Phone photos and typical album art exceed the registered edge;
    // loadCoverFromPath must decode with a larger scratch, shrink, then
    // registerImage into the 256pt canvas budget.
    var live = try LiveApp.start(true);
    defer live.stop();

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const media_root = "/tmp/wellmusic-cover-oversize-media";
    const source = "/tmp/wellmusic-cover-oversize.png";
    const managed = "/tmp/wellmusic-cover-oversize-media/c1.png";
    defer std.Io.Dir.deleteFileAbsolute(io, source) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, managed) catch {};

    const width: usize = 600;
    const height: usize = 600;
    const pixels = try testing.allocator.alloc(u8, width * height * 4);
    defer testing.allocator.free(pixels);
    @memset(pixels, 200);

    const png_len = try canvas.png.encodedRgba8ByteLen(width, height);
    const png_buf = try testing.allocator.alloc(u8, png_len);
    defer testing.allocator.free(png_buf);
    var png_writer = std.Io.Writer.fixed(png_buf);
    try canvas.png.writeRgba8(&png_writer, width, height, pixels);
    {
        var file = try std.Io.Dir.createFileAbsolute(io, source, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, png_writer.buffered());
    }

    const model = &live.app_state.model;
    model.setMediaDir(media_root);
    try testing.expect(model.ensureLibraryAlbum());
    const album_id = model_mod.imported_album_id;
    try testing.expect(model_mod.importCoverFromSource(model, album_id, source));
    try testing.expect(model_mod.loadCoverFromPath(model, &live.app_state.effects, album_id));
    try testing.expect(model.coverFor(album_id) != 0);

    const info = live.harness.runtime.registeredCanvasImage(album_id).?;
    try testing.expectEqual(@as(usize, model_mod.max_cover_register_edge), info.width);
    try testing.expectEqual(@as(usize, model_mod.max_cover_register_edge), info.height);
}

test "covers load from the cached thumb without decoding again" {
    var live = try LiveApp.start(true);
    defer live.stop();
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const media_root = "/tmp/wellmusic-thumb-media";
    const source = "/tmp/wellmusic-thumb-source.png";
    const managed = "/tmp/wellmusic-thumb-media/c1.png";
    const thumb = "/tmp/wellmusic-thumb-media/c1.thumb";
    defer std.Io.Dir.deleteFileAbsolute(io, source) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, managed) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, thumb) catch {};

    const width: usize = 512;
    const pixels = try testing.allocator.alloc(u8, width * width * 4);
    defer testing.allocator.free(pixels);
    @memset(pixels, 90);
    const png_len = try canvas.png.encodedRgba8ByteLen(width, width);
    const png_buf = try testing.allocator.alloc(u8, png_len);
    defer testing.allocator.free(png_buf);
    var png_writer = std.Io.Writer.fixed(png_buf);
    try canvas.png.writeRgba8(&png_writer, width, width, pixels);
    try writeTestFile(io, source, png_writer.buffered());

    const model = &live.app_state.model;
    model.setMediaDir(media_root);
    try testing.expect(model.ensureLibraryAlbum());
    const album_id = model_mod.imported_album_id;
    try testing.expect(model_mod.importCoverFromSource(model, album_id, source));
    try testing.expect(model_mod.loadCoverFromPath(model, &live.app_state.effects, album_id));
    try testing.expect(model_mod.localAudioReadable(thumb));

    // Same size, undecodable bytes: only the thumb can satisfy this load.
    const junk = try testing.allocator.alloc(u8, png_writer.buffered().len);
    defer testing.allocator.free(junk);
    @memset(junk, 0);
    try writeTestFile(io, managed, junk);
    model.user_albums[0].cover = 0;
    try testing.expect(model_mod.loadCoverFromPath(model, &live.app_state.effects, album_id));
    try testing.expect(model.coverFor(album_id) != 0);

    // A new cover replaces the thumb rather than reusing a stale one.
    try testing.expect(model_mod.importCoverFromSource(model, album_id, source));
    try testing.expect(!model_mod.localAudioReadable(thumb));
}

fn pendingTimer(fx: *model_mod.Effects, key: u64) ?u64 {
    var i: usize = 0;
    while (i < fx.pendingTimerCount()) : (i += 1) {
        const timer = fx.pendingTimerAt(i) orelse continue;
        if (timer.key == key) return timer.interval_ms;
    }
    return null;
}

test "a poll near the end of a track schedules a follow-up poll just past it" {
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var model: Model = .{};
    try testing.expect(model.addUserTrack("/tmp/wellmusic-test/end.mp3"));
    model.user_tracks[0].duration_ms = 10_000;
    const id = model.user_tracks[0].id;
    applyFx(&model, .{ .play_track = id }, &fx);

    fx.audio.active = true;
    fx.audio.key = id;
    fx.audio.playing = true;
    fx.audio.duration_ms = 10_000;

    // Far from the end: the regular 2 s cadence is enough.
    fx.audio.position_ms = 3_000;
    applyFx(&model, .{ .audio_poll = .{ .key = model_mod.audio_poll_timer_key } }, &fx);
    try testing.expectEqual(@as(?u64, null), pendingTimer(&fx, model_mod.audio_end_timer_key));

    // Inside the last interval: a one-shot lands right after the end.
    fx.audio.position_ms = 9_000;
    applyFx(&model, .{ .audio_poll = .{ .key = model_mod.audio_poll_timer_key } }, &fx);
    try testing.expectEqual(@as(?u64, 1_000 + model_mod.audio_end_margin_ms), pendingTimer(&fx, model_mod.audio_end_timer_key));

    // Pausing drops it with the regular poll.
    applyFx(&model, .toggle_play, &fx);
    try testing.expectEqual(@as(?u64, null), pendingTimer(&fx, model_mod.audio_end_timer_key));
}

/// Deliver every completed effect Msg, the way the runtime would.
fn drainFx(model: *Model, fx: *model_mod.Effects) void {
    while (fx.takeMsg()) |msg| applyFx(model, msg, fx);
}

fn writeTestFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

test "importing the same file twice is rejected even under another name" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const source = "/tmp/wellmusic-dup-source.mp3";
    const renamed = "/tmp/wellmusic-dup-renamed.mp3";
    const other = "/tmp/wellmusic-dup-other.mp3";
    try writeTestFile(io, source, "ID3same-bytes");
    defer std.Io.Dir.deleteFileAbsolute(io, source) catch {};
    try writeTestFile(io, renamed, "ID3same-bytes");
    defer std.Io.Dir.deleteFileAbsolute(io, renamed) catch {};
    try writeTestFile(io, other, "ID3diff-bytes");
    defer std.Io.Dir.deleteFileAbsolute(io, other) catch {};

    var model = Model{};
    model.setMediaDir("/tmp/wellmusic-dup-media");
    try testing.expect(model_mod.importAudioFromSource(&model, model_mod.imported_album_id, source));
    try testing.expect(!model_mod.importAudioFromSource(&model, model_mod.imported_album_id, source));
    try testing.expect(!model_mod.importAudioFromSource(&model, model_mod.imported_album_id, renamed));
    // Same size, different bytes: a different song.
    try testing.expect(model_mod.importAudioFromSource(&model, model_mod.imported_album_id, other));
    try testing.expectEqual(@as(usize, 2), model.user_track_count);
    while (model.user_track_count > 0) _ = model.removeUserTrack(model.user_tracks[0].id);
}

test "background import copies through a spawn and reports progress" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const good = "/tmp/wellmusic-bg-good.mp3";
    const bad = "/tmp/wellmusic-bg-bad.mp3";
    try writeTestFile(io, good, "ID3good");
    defer std.Io.Dir.deleteFileAbsolute(io, good) catch {};
    try writeTestFile(io, bad, "ID3bad!");
    defer std.Io.Dir.deleteFileAbsolute(io, bad) catch {};

    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    model.setMediaDir("/tmp/wellmusic-bg-media");
    const album = model.addUserAlbum("Folder", "Artist").?;
    try testing.expect(model_mod.queueImport(&model, album, good));
    try testing.expect(model_mod.queueImport(&model, album, bad));
    try testing.expect(!model_mod.queueImport(&model, album, good)); // already queued
    model_mod.pumpImport(&model, &fx);

    // Nothing lands until the copy exits; the UI shows progress.
    try testing.expectEqual(@as(usize, 0), model.user_track_count);
    try testing.expectEqualStrings("Importing 1 / 2…", model.importStatus(arena));
    const first = fx.pendingSpawnAt(0).?;
    try testing.expectEqualStrings("/bin/cp", first.argv[0]);
    try testing.expectEqualStrings(good, first.argv[3]);
    // Stand in for cp, then report success.
    try writeTestFile(io, first.argv[4], "ID3good");
    const dest = try testing.allocator.dupe(u8, first.argv[4]);
    defer testing.allocator.free(dest);
    try fx.feedExit(model_mod.import_spawn_key, 0);
    drainFx(&model, &fx);
    try testing.expectEqual(@as(usize, 1), model.user_track_count);
    try testing.expectEqualStrings(dest, model.user_tracks[0].path());
    try testing.expectEqualStrings("Importing 2 / 2…", model.importStatus(arena));

    // The second copy fails: no track, and the queue drains.
    try fx.feedExit(model_mod.import_spawn_key, 1);
    drainFx(&model, &fx);
    try testing.expectEqual(@as(usize, 1), model.user_track_count);
    try testing.expectEqualStrings("", model.importStatus(arena));
    try testing.expect(model.userAlbumById(album) != null);
    _ = model.removeUserTrack(model.user_tracks[0].id);
}

test "a folder import whose every copy fails leaves no empty album" {
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var model = Model{};
    model.setMediaDir("/tmp/wellmusic-bg-media");
    const album = model.addUserAlbum("Broken", "Artist").?;
    try testing.expect(model_mod.queueImport(&model, album, "/tmp/wellmusic-bg-missing.mp3"));
    model_mod.pumpImport(&model, &fx);
    try fx.feedExit(model_mod.import_spawn_key, 1);
    drainFx(&model, &fx);
    try testing.expect(model.userAlbumById(album) == null);
}

test "titles cannot carry the store's field separators" {
    var track: model_mod.UserTrack = .{};
    track.setTitle("a\tb\nc\rd");
    try testing.expectEqualStrings("a b c d", track.title());
}

test "one malformed library record is skipped, not the whole library" {
    var model: Model = .{};
    const bytes = model_mod.library_store_header ++ "\n" ++
        "album\t1\tLibrary\tMy Music\t2026\t\n" ++
        "track\t1\t1\t1\tFirst\t\t/Music/1.mp3\t0\n" ++
        "track\t2\t1\t2\tBroken\n" ++
        "track\t3\t1\t3\tThird\t\t/Music/3.mp3\t0\n" ++
        "track\t3\t1\t4\tDuplicate id\t\t/Music/4.mp3\t0\n";
    try testing.expect(model.restoreLibrary(bytes));
    try testing.expectEqual(@as(usize, 2), model.user_track_count);
    // Numbering closes the gap so the album lists both rows.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const rows = model.albumTrackRows(arena_state.allocator(), model_mod.imported_album_id);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("Third", rows[1].title);
}

fn seedAlbum(model: *Model, count: usize) !u8 {
    const album = model.addUserAlbum("Shuffle Test", "Artist").?;
    var path_buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const path = try std.fmt.bufPrint(&path_buf, "/tmp/demo/mode-{d}.mp3", .{i});
        try testing.expect(model.addUserTrackToAlbum(album, path));
    }
    return album;
}

test "single loop repeats the track at its end but Next still moves on" {
    var model: Model = .{};
    const album = try seedAlbum(&model, 3);
    apply(&model, .{ .play_album = album });
    const first = model.now.?;
    model.repeat = .one;

    apply(&model, .{ .audio_event = .{ .key = first, .kind = .completed } });
    try testing.expectEqual(@as(?u8, first), model.now);
    try testing.expect(model.playing);

    apply(&model, .next_track);
    try testing.expectEqual(@as(?u8, model.queue[1]), model.now);
}

test "shuffle plays every track once before any repeats, and Previous retraces" {
    var model: Model = .{};
    const album = try seedAlbum(&model, 6);
    model.shuffle = true;
    apply(&model, .{ .play_album = album });

    var seen = std.StaticBitSet(256).initEmpty();
    var order: [6]u8 = undefined;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const now = model.now.?;
        try testing.expect(!seen.isSet(now));
        seen.set(now);
        order[i] = now;
        apply(&model, .{ .audio_event = .{ .key = now, .kind = .completed } });
    }
    // Seventh pick opens a new pass and never repeats the last track.
    try testing.expect(model.now.? != order[5]);
    try testing.expect(model.playing);

    // Previous walks back through what actually played.
    apply(&model, .prev_track);
    try testing.expectEqual(@as(?u8, order[5]), model.now);
    apply(&model, .prev_track);
    try testing.expectEqual(@as(?u8, order[4]), model.now);
}

test "shuffle order depends on the seed, not on the album order" {
    var orders: [2][5]u8 = undefined;
    for (&orders, [_]u64{ 1, 2 }) |*out, seed| {
        var model: Model = .{};
        model.shuffle_rng = seed;
        const album = try seedAlbum(&model, 5);
        model.shuffle = true;
        apply(&model, .{ .play_album = album });
        for (out) |*slot| {
            slot.* = model.now.?;
            apply(&model, .next_track);
        }
    }
    try testing.expect(!std.mem.eql(u8, &orders[0], &orders[1]));
}

test "shuffle, repeat, and mute survive a session round trip" {
    var model: Model = .{};
    model.repeat = .one;
    model.shuffle = true;
    model.muted = true;
    var buffer: [model_mod.max_session_store_bytes]u8 = undefined;
    const bytes = model.serializeSession(&buffer);
    var restored: Model = .{};
    try testing.expect(restored.restoreSession(bytes));
    try testing.expectEqual(model_mod.Repeat.one, restored.repeat);
    try testing.expect(restored.shuffle);
    try testing.expect(restored.muted);
}

test "sessions from the single play-mode button still load" {
    for ([_]struct { mode: []const u8, repeat: model_mod.Repeat, shuffle: bool }{
        .{ .mode = "list_loop", .repeat = .all, .shuffle = false },
        .{ .mode = "single_loop", .repeat = .one, .shuffle = false },
        .{ .mode = "shuffle", .repeat = .all, .shuffle = true },
        .{ .mode = "sequential", .repeat = .off, .shuffle = false },
    }) |case| {
        var buffer: [128]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&buffer, "{s}\nmode\t{s}\n", .{ model_mod.session_store_header, case.mode });
        var restored: Model = .{};
        try testing.expect(restored.restoreSession(bytes));
        try testing.expectEqual(case.repeat, restored.repeat);
        try testing.expectEqual(case.shuffle, restored.shuffle);
    }
}

test "remote play and pause never toggle the wrong way" {
    try testing.expectEqual(Msg{ .media_command = .play }, main.onCommand("transport.play").?);
    try testing.expectEqual(Msg{ .media_command = .pause }, main.onCommand("transport.pause").?);

    var model: Model = .{};
    try testing.expect(model.addUserTrack("/tmp/demo/remote.mp3"));
    apply(&model, .{ .media_command = .pause });
    try testing.expect(!model.playing);
    apply(&model, .{ .media_command = .play });
    try testing.expect(model.playing);
    apply(&model, .{ .media_command = .play });
    try testing.expect(model.playing);
    apply(&model, .{ .media_command = .pause });
    try testing.expect(!model.playing);
    apply(&model, .{ .media_command = .pause });
    try testing.expect(!model.playing);
}

test "every catalog save bumps the library revision" {
    var model: Model = .{};
    const before = model.library_revision;
    try testing.expect(model.addUserTrack("/tmp/demo/rev.mp3"));
    apply(&model, .{ .edit_track = model.user_tracks[0].id });
    model.edit_title_buffer.set("夜曲");
    apply(&model, .save_edit_track);
    try testing.expect(model.library_revision != before);
    try testing.expect(model_mod.libraryNeedsCjkFont(&model));
}

test "launch title heal runs one track per step and then stops" {
    var model: Model = .{};
    try testing.expect(model.addUserTrack("/tmp/demo/heal-a.mp3"));
    try testing.expect(model.addUserTrack("/tmp/demo/heal-b.mp3"));
    model.user_tracks[1].setTitle("Tagged elsewhere");
    model.library_hydrate_pending = true;
    apply(&model, .library_hydrate);
    try testing.expect(model.title_heal_pending);
    model.cover_hydrate_pending = false;
    const frame = native_sdk.platform.GpuFrame{ .size = geometry.SizeF.init(model.canvas_width, 720) };
    try testing.expectEqual(Msg.title_heal, main.onFrame(&model, frame).?);

    apply(&model, .title_heal); // probes heal-a (still tagless)
    try testing.expect(model.title_heal_pending);
    apply(&model, .title_heal); // skips the tagged track, finds nothing left
    try testing.expect(!model.title_heal_pending);
}

/// Notice text in a per-test arena that lives as long as the test.
var notice_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

fn arenaText(model: *const Model) ![]const u8 {
    _ = notice_arena.reset(.retain_capacity);
    return model.noticeText(notice_arena.allocator());
}

test "the now-playing bar opens the playing album at the playing track" {
    var model: Model = .{};
    const album = try seedAlbum(&model, 4);
    apply(&model, .{ .play_album = album });
    apply(&model, .next_track);
    apply(&model, .next_track);
    const now = model.now.?;
    model.open_album = null;
    apply(&model, .reveal_now_playing);
    try testing.expectEqual(@as(?u8, album), model.open_album);
    try testing.expectEqual(@as(?u8, now), model.selected);
    try testing.expect(model.detail_scroll >= 0);
}

test "removing an album can be undone, then becomes final" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const media = "/tmp/wellmusic-undo-media";
    const managed = "/tmp/wellmusic-undo-media/t1.mp3";
    std.Io.Dir.cwd().createDirPath(io, media) catch {};
    try writeTestFile(io, managed, "ID3undo");
    defer std.Io.Dir.deleteFileAbsolute(io, managed) catch {};

    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var model: Model = .{};
    model.setMediaDir(media);
    const album = model.addUserAlbum("Gone", "Artist").?;
    try testing.expect(model.addUserTrackToAlbum(album, managed));
    try testing.expect(model.addUserTrackToAlbum(album, "/tmp/demo/undo-2.mp3"));

    applyFx(&model, .{ .remove_album = album }, &fx);
    try testing.expectEqual(@as(usize, 0), model.user_track_count);
    try testing.expect(model.userAlbumById(album) == null);
    try testing.expect(model.noticeCanUndo());
    try testing.expectEqualStrings("Removed 2 songs", try arenaText(&model));
    // The media is still there while Undo is offered.
    try testing.expect(model_mod.localAudioReadable(managed));

    applyFx(&model, .undo_remove, &fx);
    try testing.expectEqual(@as(usize, 2), model.user_track_count);
    try testing.expect(model.userAlbumById(album) != null);
    try testing.expect(!model.noticeCanUndo());

    // Again, and let the notice expire: now the file goes.
    applyFx(&model, .{ .remove_album = album }, &fx);
    applyFx(&model, .{ .notice_expired = .{ .key = model_mod.notice_timer_key } }, &fx);
    try testing.expect(!model_mod.localAudioReadable(managed));
    try testing.expectEqualStrings("", try arenaText(&model));
}

test "undo is withdrawn once something else changes the library" {
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var model: Model = .{};
    try testing.expect(model.addUserTrack("/tmp/demo/keep.mp3"));
    try testing.expect(model.addUserTrack("/tmp/demo/drop.mp3"));
    applyFx(&model, .{ .remove_track = model.user_tracks[1].id }, &fx);
    try testing.expect(model.noticeCanUndo());
    applyFx(&model, .{ .edit_track = model.user_tracks[0].id }, &fx);
    model.edit_title_buffer.set("Renamed");
    applyFx(&model, .save_edit_track, &fx);
    try testing.expect(!model.noticeCanUndo());
    applyFx(&model, .undo_remove, &fx);
    try testing.expectEqual(@as(usize, 1), model.user_track_count);
    try testing.expectEqualStrings("Renamed", model.user_tracks[0].title());
}

test "an import reports what it added and skipped" {
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var model: Model = .{};
    _ = model_mod.queueImport(&model, model_mod.imported_album_id, "/tmp/demo/r1.mp3");
    _ = model_mod.queueImport(&model, model_mod.imported_album_id, "/tmp/demo/r2.mp3");
    _ = model_mod.queueImport(&model, model_mod.imported_album_id, "/tmp/demo/r1.mp3");
    model_mod.pumpImport(&model, &fx);
    try testing.expectEqualStrings("Added 2 songs · skipped 1 already in the library", try arenaText(&model));
    applyFx(&model, .dismiss_notice, &fx);
    try testing.expectEqualStrings("", try arenaText(&model));
}

test "dropped files and folders import through the model" {
    var model: Model = .{};
    try testing.expect(model_mod.stageDroppedPaths(&.{ "/tmp/demo/dropped.mp3", "/tmp/demo/notes.txt" }));
    try testing.expectEqual(Msg.import_dropped, main.onCommand("library.import_dropped").?);
    apply(&model, .import_dropped);
    try testing.expectEqual(@as(usize, 1), model.user_track_count);
    try testing.expectEqualStrings("dropped", model.user_tracks[0].title());
}

test "mute restores the level it hid, and the slider unmutes" {
    var model: Model = .{};
    model.volume = 0.6;
    apply(&model, .toggle_mute);
    try testing.expect(model.muted);
    try testing.expectEqual(@as(f32, 0), model.volumeFraction());
    try testing.expectEqualStrings("app:volume-mute", model.volumeIcon());
    apply(&model, .toggle_mute);
    try testing.expectEqual(@as(f32, 0.6), model.volumeFraction());
    apply(&model, .toggle_mute);
    apply(&model, .{ .volume_changed = 0.3 });
    try testing.expect(!model.muted);
    apply(&model, .{ .volume_step = .up });
    try testing.expectApproxEqAbs(@as(f32, 0.4), model.volume, 0.001);
}

test "Music-app shortcuts map through onKey" {
    const cmd: canvas.WidgetKeyboardModifiers = .{ .super = true };
    try testing.expectEqual(Msg{ .media_command = .next }, main.onKey(.{ .key = "ArrowRight", .phase = .key_down, .modifiers = cmd }).?);
    try testing.expectEqual(Msg{ .media_command = .previous }, main.onKey(.{ .key = "ArrowLeft", .phase = .key_down, .modifiers = cmd }).?);
    try testing.expectEqual(Msg{ .volume_step = .down }, main.onKey(.{ .key = "ArrowDown", .phase = .key_down, .modifiers = cmd }).?);
    try testing.expectEqual(Msg.close_album, main.onKey(.{ .key = "[", .phase = .key_down, .modifiers = cmd }).?);
    try testing.expectEqual(Msg.close_album, main.onKey(.{ .key = "Escape", .phase = .key_down, .modifiers = .{} }).?);
    // Plain arrows still move the selection.
    try testing.expectEqual(Msg.select_next, main.onKey(.{ .key = "ArrowDown", .phase = .key_down, .modifiers = .{} }).?);
}

test "the album page sums durations and the grid marks the playing album" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model: Model = .{};
    const album = try seedAlbum(&model, 2);
    model.user_tracks[0].duration_ms = 3 * 60_000;
    model.user_tracks[1].duration_ms = 4 * 60_000;
    try testing.expectEqual(@as(u64, 7 * 60_000), model.albumDurationMs(album));
    apply(&model, .{ .play_album = album });
    const cells = model.visibleAlbums(arena_state.allocator());
    try testing.expect(cells[0].now and cells[0].playing);
}

test "the UI speaks Chinese when the system does" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model: Model = .{};
    model.lang = .zh;
    const tree = try buildTree(arena_state.allocator(), &model);
    try testing.expect(findByLabel(tree.root, "资料库还是空的") != null);
    try testing.expectEqualStrings("未在播放", model.nowPlayingTitle());
    try testing.expectEqualStrings("更多", model.strMore());
}

test "revealing a track on a short album keeps the page at the top" {
    var model: Model = .{};
    const album = try seedAlbum(&model, 2);
    apply(&model, .{ .play_album = album });
    apply(&model, .next_track);
    apply(&model, .reveal_now_playing);
    try testing.expectEqual(@as(f32, 0), model.detail_scroll);
}

test "hour-long tracks show hours in their duration" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model: Model = .{};
    const album = try seedAlbum(&model, 1);
    model.user_tracks[0].duration_ms = (6 * 3600 + 15 * 60 + 4) * 1000;
    const rows = model.albumTrackRows(arena_state.allocator(), album);
    try testing.expectEqualStrings("6:15:04", rows[0].duration);
}

test "a track that fails to play skips to the next one" {
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var model: Model = .{};
    const album = try seedAlbum(&model, 3);
    applyFx(&model, .{ .play_album = album }, &fx);
    const first = model.now.?;
    applyFx(&model, .{ .audio_event = .{ .key = first, .kind = .failed } }, &fx);
    try testing.expect(model.now != null and model.now.? != first);
    try testing.expect(model.playing);
    try testing.expectEqual(model_mod.Notice.skipped, model.notice);
    try testing.expect(std.mem.indexOf(u8, try arenaText(&model), "mode-0") != null);
}

test "auto-skip gives up once every track has failed" {
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var model: Model = .{};
    const album = try seedAlbum(&model, 3);
    applyFx(&model, .{ .play_album = album }, &fx);
    var guard: usize = 0;
    while (model.now) |id| : (guard += 1) {
        try testing.expect(guard < 10);
        applyFx(&model, .{ .audio_event = .{ .key = id, .kind = .failed } }, &fx);
    }
    try testing.expect(model.assets_missing);
    try testing.expect(!model.playing);
}

test "pause ramps the volume down before the player stops" {
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var model: Model = .{};
    try testing.expect(model.addUserTrack("/tmp/demo/fade.mp3"));
    applyFx(&model, .{ .play_track = model.user_tracks[0].id }, &fx);
    applyFx(&model, .toggle_play, &fx);
    try testing.expect(!model.playing);
    try testing.expectEqual(model_mod.Fade.out, model.fade);
    try testing.expect(fx.audio.playing); // still ramping
    var i: usize = 0;
    while (i < model_mod.fade_steps) : (i += 1) {
        applyFx(&model, .{ .fade_tick = .{ .key = model_mod.fade_timer_key } }, &fx);
    }
    try testing.expectEqual(model_mod.Fade.none, model.fade);
    try testing.expect(!fx.audio.playing);

    // Resume ramps back up; a press mid-ramp reverses from where it is.
    applyFx(&model, .toggle_play, &fx);
    try testing.expectEqual(model_mod.Fade.in, model.fade);
    applyFx(&model, .{ .fade_tick = .{ .key = model_mod.fade_timer_key } }, &fx);
    applyFx(&model, .{ .fade_tick = .{ .key = model_mod.fade_timer_key } }, &fx);
    applyFx(&model, .toggle_play, &fx);
    try testing.expectEqual(model_mod.Fade.out, model.fade);
    try testing.expectEqual(model_mod.fade_steps - 2, model.fade_step);
}

test "the pause ramp is flat at both ends" {
    var model: Model = .{};
    model.volume = 1;
    model.fade = .out;
    const expected = [_]f32{ 1.0, 0.9330, 0.75, 0.5, 0.25, 0.0670, 0.0 };
    for (expected, 0..) |gain, k| {
        model.fade_step = @intCast(k);
        try testing.expectApproxEqAbs(gain, model_mod.fadeLevel(&model), 0.001);
    }
    // Reversal continuity: in(steps - k) == out(k).
    model.fade = .in;
    model.fade_step = model_mod.fade_steps - 2;
    try testing.expectApproxEqAbs(@as(f32, 0.75), model_mod.fadeLevel(&model), 0.001);
}

test "shuffle album turns shuffle on and starts the album" {
    var model: Model = .{};
    const album = try seedAlbum(&model, 4);
    apply(&model, .{ .shuffle_album = album });
    try testing.expect(model.shuffle);
    try testing.expect(model.playing);
    try testing.expectEqual(@as(usize, 4), model.queue_len);
}

test "an image dropped on an album page becomes its cover" {
    var model: Model = .{};
    const album = try seedAlbum(&model, 1);
    model.open_album = album;
    try testing.expect(model_mod.stageDroppedPaths(&.{"/tmp/demo/art.JPG"}));
    apply(&model, .import_dropped);
    try testing.expectEqualStrings("/tmp/demo/art.JPG", model.userAlbumById(album).?.coverPath());
    try testing.expectEqual(@as(usize, 1), model.user_track_count);
}

test "the page and scroll the user left come back" {
    var model: Model = .{};
    const album = try seedAlbum(&model, 2);
    model.open_album = album;
    model.grid_scroll = 120;
    model.detail_scroll = 48;
    var buffer: [model_mod.max_session_store_bytes]u8 = undefined;
    const bytes = model.serializeSession(&buffer);

    var restored: Model = .{};
    _ = try seedAlbum(&restored, 2);
    restored.applySessionView(bytes);
    try testing.expectEqual(@as(?u8, album), restored.open_album);
    try testing.expectEqual(@as(f32, 120), restored.grid_scroll);
    try testing.expectEqual(@as(f32, 48), restored.detail_scroll);
    // The full restore accepts (and leaves alone) the view keys.
    try testing.expect(restored.restoreSession(bytes));

    // An album that no longer exists is not reopened.
    var empty: Model = .{};
    empty.applySessionView(bytes);
    try testing.expectEqual(@as(?u8, null), empty.open_album);
}

test "playlist entries move up, down, to the top and bottom" {
    var model: Model = .{};
    const album = try seedAlbum(&model, 4);
    apply(&model, .{ .play_album = album });
    const ids = [_]u8{ model.queue[0], model.queue[1], model.queue[2], model.queue[3] };
    apply(&model, .{ .move_queued = .{ .id = ids[2], .move = .up } });
    try testing.expectEqualSlices(u8, &.{ ids[0], ids[2], ids[1], ids[3] }, model.queue[0..4]);
    apply(&model, .{ .move_queued = .{ .id = ids[0], .move = .bottom } });
    try testing.expectEqualSlices(u8, &.{ ids[2], ids[1], ids[3], ids[0] }, model.queue[0..4]);
    apply(&model, .{ .move_queued = .{ .id = ids[3], .move = .top } });
    try testing.expectEqualSlices(u8, &.{ ids[3], ids[2], ids[1], ids[0] }, model.queue[0..4]);
    apply(&model, .{ .move_queued = .{ .id = ids[0], .move = .down } }); // already last
    try testing.expectEqualSlices(u8, &.{ ids[3], ids[2], ids[1], ids[0] }, model.queue[0..4]);
}

test "selection shortcuts remove, queue, and reveal" {
    const cmd: canvas.WidgetKeyboardModifiers = .{ .super = true };
    const cmd_shift: canvas.WidgetKeyboardModifiers = .{ .super = true, .shift = true };
    try testing.expectEqual(Msg.remove_selected, main.onKey(.{ .key = "Backspace", .phase = .key_down, .modifiers = cmd }).?);
    try testing.expectEqual(Msg.reveal_now_playing, main.onKey(.{ .key = "l", .phase = .key_down, .modifiers = cmd }).?);
    try testing.expectEqual(Msg.queue_selected, main.onKey(.{ .key = "N", .phase = .key_down, .modifiers = cmd_shift }).?);

    var model: Model = .{};
    try testing.expect(model.addUserTrack("/tmp/demo/sel-a.mp3"));
    try testing.expect(model.addUserTrack("/tmp/demo/sel-b.mp3"));
    model.selected = model.user_tracks[1].id;
    apply(&model, .queue_selected);
    try testing.expectEqual(@as(usize, 1), model.queue_len);
    apply(&model, .remove_selected);
    try testing.expectEqual(@as(usize, 1), model.user_track_count);
}

test "reduce motion zeroes every motion duration" {
    for ([_]native_sdk.ColorScheme{ .light, .dark }) |scheme| {
        for ([_]bool{ false, true }) |high_contrast| {
            const motion = theme.tokens(scheme, high_contrast, true).motion;
            try testing.expectEqual(@as(u32, 0), motion.fast_ms);
            try testing.expectEqual(@as(u32, 0), motion.normal_ms);
            try testing.expectEqual(@as(u32, 0), motion.slow_ms);
        }
    }
}

test "undo survives a library save that was queued behind another" {
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var model: Model = .{};
    model.setStorePath("/tmp/wellmusic-undo-queue/library.txt");
    try testing.expect(model.addUserTrack("/tmp/demo/q1.mp3"));
    try testing.expect(model.addUserTrack("/tmp/demo/q2.mp3"));
    try testing.expect(model.addUserTrack("/tmp/demo/q3.mp3"));
    // First removal starts a write; the second lands while it is in flight.
    applyFx(&model, .{ .remove_track = model.user_tracks[2].id }, &fx);
    applyFx(&model, .{ .remove_track = model.user_tracks[1].id }, &fx);
    try testing.expect(model.noticeCanUndo());
    // The first write completes and the queued save flushes.
    applyFx(&model, .{ .library_done = .{ .key = model_mod.library_write_key, .op = .write } }, &fx);
    try testing.expect(model.noticeCanUndo());
    applyFx(&model, .undo_remove, &fx);
    try testing.expectEqual(@as(usize, 2), model.user_track_count);
}

test "a Chinese UI needs the CJK face even over a Latin-only library" {
    var model: Model = .{};
    try testing.expect(model.addUserTrack("/tmp/demo/latin-only.mp3"));
    try testing.expect(!model_mod.needsCjkFont(&model));
    model.lang = .zh;
    try testing.expect(model_mod.needsCjkFont(&model));
}

test "cover downscale averages a bounded sample grid per pixel" {
    // 8x8 source: left half black, right half white, scaled to 2x2.
    var src: [8 * 8 * 4]u8 = undefined;
    for (0..8) |y| for (0..8) |x| {
        const v: u8 = if (x < 4) 0 else 255;
        const i = (y * 8 + x) * 4;
        src[i] = v;
        src[i + 1] = v;
        src[i + 2] = v;
        src[i + 3] = 255;
    };
    var dst: [2 * 2 * 4]u8 = undefined;
    model_mod.downscaleRgbaForTest(&src, 8, 8, &dst, 2, 2);
    try testing.expectEqual(@as(u8, 0), dst[0]);
    try testing.expectEqual(@as(u8, 255), dst[4]);
    try testing.expectEqual(@as(u8, 255), dst[3]);
    // 3x3 source to 1x1: a 3-wide box keeps all 3 samples (mean of 0,0,255).
    const row = [_]u8{ 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255, 255 };
    var src3: [3 * 3 * 4]u8 = undefined;
    for (0..3) |r| @memcpy(src3[r * 12 ..][0..12], &row);
    var one: [4]u8 = undefined;
    model_mod.downscaleRgbaForTest(&src3, 3, 3, &one, 1, 1);
    try testing.expectEqual(@as(u8, 85), one[0]);
}

fn pendingWrites(fx: *model_mod.Effects, key: u64) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < fx.pendingFileCount()) : (i += 1) {
        const request = fx.pendingFileAt(i) orelse continue;
        if (request.key == key) count += 1;
    }
    return count;
}

test "a volume drag saves the session once it settles" {
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var model: Model = .{};
    model.setSessionPath("/tmp/wellmusic-debounce/session.txt");
    for ([_]f32{ 0.9, 0.8, 0.7, 0.6, 0.5 }) |level| {
        applyFx(&model, .{ .volume_changed = level }, &fx);
    }
    try testing.expectEqual(@as(usize, 0), pendingWrites(&fx, model_mod.session_write_key));
    try testing.expect(pendingTimer(&fx, model_mod.session_save_timer_key) != null);
    applyFx(&model, .{ .session_save_due = .{ .key = model_mod.session_save_timer_key } }, &fx);
    try testing.expectEqual(@as(usize, 1), pendingWrites(&fx, model_mod.session_write_key));
}

test "a background import writes the library in batches" {
    var fx = model_mod.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var model: Model = .{};
    model.setMediaDir("/tmp/wellmusic-batch-media");
    model.setStorePath("/tmp/wellmusic-batch-media/library.txt");
    var path_buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const path = try std.fmt.bufPrint(&path_buf, "/tmp/wellmusic-batch-src-{d}.mp3", .{i});
        try testing.expect(model_mod.queueImport(&model, model_mod.imported_album_id, path));
    }
    model_mod.pumpImport(&model, &fx);
    const revision_before = model.library_revision;
    var landed: usize = 0;
    while (landed < 7) : (landed += 1) {
        try fx.feedExit(model_mod.import_spawn_key, 0);
        drainFx(&model, &fx);
    }
    // Seven tracks in: the catalog moved, nothing written yet.
    try testing.expectEqual(@as(usize, 7), model.user_track_count);
    try testing.expect(model.library_revision != revision_before);
    try testing.expectEqual(@as(usize, 0), pendingWrites(&fx, model_mod.library_write_key));
    try fx.feedExit(model_mod.import_spawn_key, 0);
    drainFx(&model, &fx);
    try testing.expectEqual(@as(usize, 1), pendingWrites(&fx, model_mod.library_write_key));
    try testing.expectEqual(@as(usize, 0), model.import_unsaved);
    // The last two land and the drain flushes the rest (queued behind
    // the in-flight write).
    try fx.feedExit(model_mod.import_spawn_key, 0);
    drainFx(&model, &fx);
    try fx.feedExit(model_mod.import_spawn_key, 0);
    drainFx(&model, &fx);
    try testing.expectEqual(@as(usize, 10), model.user_track_count);
    try testing.expectEqual(@as(usize, 0), model.import_unsaved);
    try testing.expect(model.save_pending);
}

test "the quit flush writes the library atomically" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "/tmp/wellmusic-quit-flush";
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const path = "/tmp/wellmusic-quit-flush/library.txt";
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    var model: Model = .{};
    model.setStorePath(path);
    try testing.expect(model.addUserTrack("/tmp/demo/flush.mp3"));
    model_mod.saveLibraryNow(&model); // nothing unsaved: no write
    try testing.expect(!model_mod.localAudioReadable(path));
    model.import_unsaved = 1;
    model_mod.saveLibraryNow(&model);
    try testing.expect(model_mod.localAudioReadable(path));
    try testing.expect(!model_mod.localAudioReadable("/tmp/wellmusic-quit-flush/library.txt.tmp"));
    var restored: Model = .{};
    model_mod.loadLibrarySync(&restored); // no store path: stays empty
    restored.setStorePath(path);
    model_mod.loadLibrarySync(&restored);
    try testing.expectEqual(@as(usize, 1), restored.user_track_count);
}
