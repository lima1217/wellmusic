//! wellmusic: a native music library — add local audio files, browse
//! them, play through the runtime audio effect family, and
//! remove tracks you no longer want. There is no built-in sample catalog.
//!
//! Authoring split (markup-first): the header and
//! now-playing bars are `.native` views compiled at comptime; the album
//! grid, album detail, and track rows are Zig views because they need
//! what the closed markup grammar deliberately excludes — square cover
//! images, grid column counts, scaled paragraph headings, and per-row
//! native context menus. `src/view.zig` composes both kinds under one
//! root — the desktop shell.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const model_mod = @import("model.zig");
const theme = @import("theme.zig");
const view_mod = @import("view.zig");
const media_session = @import("media_session.zig");
const ui_font = @import("ui_font.zig");

pub const Model = model_mod.Model;
pub const Msg = model_mod.Msg;
pub const update = model_mod.update;
pub const rootView = view_mod.rootView;

pub const canvas_label = "wellmusic-canvas";
pub const window_width: f32 = 1080;
pub const window_height: f32 = 720;
/// Content min-size floor the window enforces: the smallest size where
/// the header, album grid, and now-playing rail lay out without clipping
/// or overlap — proven by the layout audit sweep in tests.zig, which
/// sweeps from exactly this floor. The model owns the value because it
/// doubles as the pre-first-frame `canvas_width` default the adaptive
/// album grid derives from.
pub const window_min_width: f32 = model_mod.min_canvas_width;
pub const window_min_height: f32 = 600;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Music library canvas", .accessibility_label = "WellMusic music library", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "WellMusic",
    .width = window_width,
    .height = window_height,
    .min_width = window_min_width,
    .min_height = window_min_height,
    .restore_state = false,
    // Tall hidden-inset titlebar (declared in app.zon too, which threads
    // it through the STARTUP window create): the header bar IS the
    // titlebar — it pads its leading edge past the traffic lights via
    // `on_chrome` and is the window's drag surface (`window-drag` in
    // header.native).
    .titlebar = .hidden_inset_tall,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// -------------------------------------------------------------- app icons

/// Sequential (play-through once) glyph: a list with a forward arrow,
/// distinct from the looping `repeat` mark.
const sequential_icon = canvas.svg_icon.parseComptime(@embedFile("icons/sequential.svg"));

/// Play-next queue / up-next glyph for the always-visible transport
/// toggle (bullet list — distinct from sequential's list+arrow).
const queue_icon = canvas.svg_icon.parseComptime(@embedFile("icons/queue.svg"));

/// The registered icon table: ONE declaration feeds boot-time
/// registration (`registerIcons`, called from main and the test
/// harness) AND the model contract's `app_icons` list (the emit step
/// reflects this decl), so markup `app:<name>` references are verified
/// by `native check` against exactly what the app registers.
pub const app_icons = [_]canvas.icons.Entry{
    .{ .name = "sequential", .icon = &sequential_icon },
    .{ .name = "queue", .icon = &queue_icon },
};

/// Install the app icon table; once, before views build (main does it
/// first thing, and the tests' harness setup mirrors it).
pub fn registerIcons() void {
    canvas.icons.registerAppIcons(&app_icons);
}

// ------------------------------------------------------------------ boot

/// Boot effect: library is already restored synchronously in `main` so the
/// first frame has albums. Session restore is cheap and async; covers /
/// migrate / title heal wait for `library_hydrate` on the first present.
pub fn boot(model: *Model, fx: *model_mod.Effects) void {
    model_mod.bootSession(model, fx);
}

// -------------------------------------------------------------------- app

pub const WellMusicApp = native_sdk.UiApp(Model, Msg);

/// Filled once after `ui_font.load` so `Options.fonts` can borrow a
/// stable slice for the installing-frame registration.
var ui_font_regs: [1]WellMusicApp.FontRegistration = undefined;
var ui_font_reg_count: usize = 0;

/// Platform lifecycle flag — not Model state. The SDK copies
/// `Options.fonts` during the installing frame (before any `on_frame`);
/// after that copy, the app-side ~23 MB buffer is redundant. Freed on
/// the first `onFrame` callback; see `ui_font.releaseBytes`.
var ui_font_bytes_released: bool = false;
var media_session_warmed: bool = false;

fn prepareUiFonts() void {
    ui_font.load(std.heap.page_allocator);
    if (!ui_font.ready()) {
        ui_font_reg_count = 0;
        return;
    }
    ui_font_regs[0] = .{
        .id = ui_font.font_id,
        .name = ui_font.name(),
        .ttf = ui_font.faceBytes(),
    };
    ui_font_reg_count = 1;
}

pub fn wellMusicOptions() WellMusicApp.Options {
    return .{
        .name = "wellmusic",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .view = rootView,
        .init_fx = boot,
        .tokens_fn = tokensFromModel,
        .fonts = ui_font_regs[0..ui_font_reg_count],
        .on_appearance = onAppearance,
        .on_chrome = onChrome,
        .on_command = onCommand,
        .on_key = onKey,
        .on_frame = onFrame,
        .animations = animations,
        .status_item = .{
            .title = "♪",
            .tooltip = "WellMusic",
        },
        .status_item_fn = statusItem,
    };
}

fn statusItem(model: *const Model, scratch: *WellMusicApp.StatusItemScratch) WellMusicApp.StatusItemState {
    const title = blk: {
        if (model.nowTrack()) |track| {
            break :blk std.fmt.bufPrint(&scratch.title_buffer, "♪ {s}", .{track.title}) catch "♪";
        }
        break :blk "♪";
    };
    var count: usize = 0;
    scratch.items[count] = .{
        .id = 1,
        .label = if (model.playing) "Pause" else "Play",
        .command = "transport.toggle",
    };
    count += 1;
    scratch.items[count] = .{ .id = 2, .label = "Next", .command = "transport.next" };
    count += 1;
    scratch.items[count] = .{ .id = 3, .label = "Previous", .command = "transport.previous" };
    count += 1;
    scratch.items[count] = .{ .separator = true };
    count += 1;
    scratch.items[count] = .{
        .id = 4,
        .label = if (model.queue_open) "Hide Queue" else "Show Queue",
        .command = "transport.queue",
    };
    count += 1;
    return .{ .title = title, .items = scratch.items[0..count] };
}

/// The media-app keyboard conventions, all through the app-level key
/// FALLBACK (`on_key`), so the framework's precedence rule applies
/// before any of them fire: a RING-focused widget consumes its own keys
/// (a tabbed-to row selects on Space and plays on Enter, a slider takes
/// the arrows), and a focused editable field keeps typing — the
/// text-entry exception is structural (checked by widget kind in the
/// runtime), so a focused editable field blocks all of these without
/// this function knowing it exists. A QUIETLY focused track row (the)
/// state a click leaves behind) is transparent to keys by the
/// framework's quiet-list-row rule, so after clicking around the
/// library these still work app-wide:
///   - SPACE toggles the transport;
///   - Up/Down ARROWS move the SELECTION (the accent row), never
///     playback and never the focus ring — outlines belong to Tab;
///   - ENTER plays the selected track (pause toggle when it is the
///     loaded one).
pub fn onKey(keyboard: canvas.WidgetKeyboardEvent) ?Msg {
    if (keyboard.modifiers.hasNavigationModifier() or keyboard.modifiers.shift) return null;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "space")) return .toggle_play;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown")) return .select_next;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowup")) return .select_previous;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "enter")) return .play_selected;
    // Media keys (when the host forwards them) and common F-key bindings.
    if (std.ascii.eqlIgnoreCase(keyboard.key, "mediaplaypause") or
        std.ascii.eqlIgnoreCase(keyboard.key, "media_play_pause") or
        std.ascii.eqlIgnoreCase(keyboard.key, "f8"))
        return .{ .media_command = .toggle_play };
    if (std.ascii.eqlIgnoreCase(keyboard.key, "mediatracknext") or
        std.ascii.eqlIgnoreCase(keyboard.key, "media_track_next") or
        std.ascii.eqlIgnoreCase(keyboard.key, "f9"))
        return .{ .media_command = .next };
    if (std.ascii.eqlIgnoreCase(keyboard.key, "mediatrackprevious") or
        std.ascii.eqlIgnoreCase(keyboard.key, "media_track_previous") or
        std.ascii.eqlIgnoreCase(keyboard.key, "f7"))
        return .{ .media_command = .previous };
    return null;
}

/// Chrome overlay geometry flows into the model (tall hidden-inset
/// titlebar): delivered before the first view build and again when it
/// changes — entering fullscreen hides the traffic lights and this goes
/// to zero.
pub fn onChrome(chrome: native_sdk.WindowChrome) ?Msg {
    return .{ .chrome_changed = chrome };
}

/// Design tokens derive from the model's light/dark preference plus
/// OS-reported contrast and reduced motion. `theme` follows the system
/// until the user locks light or dark.
pub fn tokensFromModel(model: *const Model) canvas.DesignTokens {
    return theme.tokens(model.colorScheme(), model.appearance.high_contrast, model.appearance.reduce_motion);
}

/// System appearance changes land in the model so contrast / motion
/// (and system-follow theme) re-derive; a locked light/dark preference
/// keeps its scheme.
fn onAppearance(appearance: native_sdk.Appearance) ?Msg {
    return Msg{ .set_appearance = appearance };
}

/// The per-frame hook carries the album grid's width channel only.
/// There is no seek scrubber and no playback timer, so idle / paused /
/// playing apps present only on real UI changes (and short track-enter
/// animations) instead of locking the Metal surface to a clock.
///
/// A WIDTH CHANGE (live resize, fullscreen) dispatches into the model
/// so the grid re-derives its column count on the very next rebuild.
/// The one-frame lag is inherent and invisible: the resize-triggered
/// rebuild still lays out with the previous width, then the frame it
/// presents delivers the new one and the corrected grid is on screen
/// a frame later.
///
/// Remote-command targets are not wired in `media_session` (ObjC bridge
/// ABI is too fragile). Playback control rides the status-item menu
/// (`statusItem`), projection commands (`onCommand`), and focused media
/// keys (`onKey`). This frame hook only carries the canvas-width channel
/// plus a one-shot free of the UI-face buffer after registration.
///
/// Timing: `UiApp` registers `Options.fonts` exactly once on the
/// installing frame (copies the TTF bytes; see FontRegistration.ttf),
/// and that rebuild runs before any `on_frame` present. So the first
/// `onFrame` is safe to drop `ui_font.loaded_bytes` — `ui_font_regs`
/// may still hold a dangling slice, but the SDK never re-reads it.
///
/// The same first present also arms `library_hydrate` when launch set
/// `library_hydrate_pending`: migrate / titles / covers stay off the
/// critical path that paints the album grid. MediaPlayer/objc symbols
/// warm here too so the first now-playing publish does not hitch on
/// `dlopen` — kept out of `model` so the domain layer stays free of
/// the platform bridge.
pub fn onFrame(model: *const Model, frame: native_sdk.platform.GpuFrame) ?Msg {
    if (!ui_font_bytes_released) {
        ui_font_bytes_released = true;
        ui_font.releaseBytes(std.heap.page_allocator);
    }
    if (!media_session_warmed) {
        media_session_warmed = true;
        media_session.warm();
    }
    if (model.library_hydrate_pending) {
        return .library_hydrate;
    }
    if (frame.size.width != model.canvas_width) {
        return Msg{ .canvas_resized = frame.size.width };
    }
    return null;
}

// ------------------------------------------------------------- animations

/// Track-change enter: title and cover fade/slide in on a critically
/// damped spring (theme motion), gated on the PLAYBACK clock
/// (`elapsed_ms` restarts per track) AND on `playing`. Split + stagger —
/// title leads, cover follows ~80 ms later — so chunks move independently
/// instead of one container. Translate is small (8pt): enough to telegraph
/// arrival without a theatrical drop. Window matches the theme's slow
/// settle (~340 ms) plus stagger headroom. Reduce-motion zeroes durations
/// through the theme; the same Msg sequence replays the same set.
///
/// `playing` is required: UiApp re-bases `start_ns` to the latest frame
/// timestamp on every rebuild. A paused (or session-restored) track with
/// `elapsed_ms` still inside the window would otherwise re-arm the Metal
/// frame channel forever — audio position ticks keep rebuilding, the
/// spring never expires, and CPU pegs while edit/cover UI starves.
const motion_window_ms: u32 = 420;
/// Stagger between title and cover enter animations (nanoseconds).
const cover_stagger_ns: u64 = 80_000_000;

/// Whether the now-playing enter motion should still be declared. Pure
/// so tests can pin the pause/session-restore latch without a full tree.
pub fn trackEnterMotionActive(playing: bool, elapsed_ms: u32) bool {
    return playing and elapsed_ms <= motion_window_ms;
}

pub fn animations(model: *const Model, tree: *const WellMusicApp.Ui.Tree, start_ns: u64, out: []canvas.CanvasRenderAnimation) usize {
    // Keep Control Center / Now Playing in sync with the model. Cheap
    // and only runs on rebuilds that already happened.
    if (model.nowTrack()) |track| {
        const artist = if (track.artist.len > 0) track.artist else blk: {
            const album = model.userAlbumById(track.album);
            break :blk if (album) |a| a.artist() else "";
        };
        media_session.publish(track.title, artist, model.now_duration_ms, model.elapsed_ms, model.playing);
    } else {
        media_session.clear();
    }
    if (model.now == null) return 0;
    if (!trackEnterMotionActive(model.playing, model.elapsed_ms)) return 0;
    const motion = tokensFromModel(model).motion;

    var count: usize = 0;
    if (findByLabel(tree.root, "Now playing title")) |title| {
        count += slideIn(motion, title.id, text_slot, start_ns, out[count..]);
    }
    if (findByLabel(tree.root, "Now playing cover")) |cover| {
        const cover_start = start_ns +% cover_stagger_ns;
        count += slideIn(motion, cover.id, fill_slot, cover_start, out[count..]);
        count += slideIn(motion, cover.id, image_slot, cover_start, out[count..]);
    }
    return count;
}

// Widget display-list part slots (`canvas.widgetCommandPartId`).
const fill_slot: canvas.ObjectId = 1;
const image_slot: canvas.ObjectId = 3;
const text_slot: canvas.ObjectId = 4;

fn slideIn(motion: anytype, widget_id: canvas.ObjectId, slot: canvas.ObjectId, start_ns: u64, out: []canvas.CanvasRenderAnimation) usize {
    if (out.len == 0) return 0;
    out[0] = motion.animation(.{
        .id = canvas.widgetCommandPartId(.{ .widget_id = widget_id, .slot = slot }),
        .start_ns = start_ns,
        .duration = .slow,
        .easing = .spring,
        .from_opacity = 0,
        .to_opacity = 1,
        .from_transform = canvas.Affine.translate(0, 8),
        .to_transform = canvas.Affine.identity(),
    });
    return 1;
}

fn findByLabel(widget: canvas.Widget, label: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.semantics.label, label)) return widget;
    for (widget.children) |child| {
        if (findByLabel(child, label)) |found| return found;
    }
    return null;
}

/// Menu-bar status-item commands arrive as transport events.
pub fn onCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, "transport.toggle")) return .{ .media_command = .toggle_play };
    if (std.mem.eql(u8, name, "transport.next")) return .{ .media_command = .next };
    if (std.mem.eql(u8, name, "transport.previous")) return .{ .media_command = .previous };
    if (std.mem.eql(u8, name, "transport.queue")) return .toggle_queue;
    return null;
}

// ------------------------------------------------------------------- main

pub fn main(init: std.process.Init) !void {
    registerIcons();
    prepareUiFonts();
    var model: Model = .{};
    var data_dir_buffer: [model_mod.max_store_path]u8 = undefined;
    var store_file_buffer: [model_mod.max_store_path]u8 = undefined;
    const data_dir = native_sdk.app_dirs.resolveOne(
        .{ .name = "wellmusic" },
        native_sdk.app_dirs.currentPlatform(),
        native_sdk.debug.envFromMap(init.environ_map),
        .data,
        &data_dir_buffer,
    ) catch "";
    if (data_dir.len > 0) {
        if (native_sdk.app_dirs.join(
            native_sdk.app_dirs.currentPlatform(),
            &store_file_buffer,
            &.{ data_dir, "library.txt" },
        )) |store_path| {
            model.setStorePath(store_path);
        } else |_| {}
        var session_file_buffer: [model_mod.max_store_path]u8 = undefined;
        if (native_sdk.app_dirs.join(
            native_sdk.app_dirs.currentPlatform(),
            &session_file_buffer,
            &.{ data_dir, "session.txt" },
        )) |session_path| {
            model.setSessionPath(session_path);
        } else |_| {}
        var media_dir_buffer: [model_mod.max_store_path]u8 = undefined;
        if (native_sdk.app_dirs.join(
            native_sdk.app_dirs.currentPlatform(),
            &media_dir_buffer,
            &.{ data_dir, "media" },
        )) |media_dir| {
            model.setMediaDir(media_dir);
        } else |_| {}
    }
    // Restore before UiApp.init so the first painted frame already has
    // the catalog — avoids the empty-library flash of an async read.
    model_mod.loadLibrarySync(&model);
    // Covers / migrate / title heal run after the first present.
    model.library_hydrate_pending = true;
    const app_state = try std.heap.page_allocator.create(WellMusicApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = WellMusicApp.init(std.heap.page_allocator, model, wellMusicOptions());
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "wellmusic",
        .window_title = "WellMusic",
        .bundle_id = "app.wellmusic",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
    _ = @import("metadata.zig");
    _ = @import("ui_font.zig");
    _ = @import("media_session.zig");
}
