//! wellmusic: a native music library — add local audio files, browse
//! and search them, play through the runtime audio effect family, and
//! remove tracks you no longer want. There is no built-in sample catalog.
//!
//! Authoring split (markup-first, two shells): the header and
//! now-playing bars are `.native` views compiled at comptime; the album
//! grid, album detail, and track rows are Zig views because they need
//! what the closed markup grammar deliberately excludes — square cover
//! images, grid column counts, scaled paragraph headings, and per-row
//! native context menus. `src/view.zig` composes both kinds under one
//! root — the DESKTOP shell — and recomposes the same shared content
//! pieces into a COMPACT shell for phone-class surfaces.

const std = @import("std");
const builtin = @import("builtin");
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

/// The app's own vector icon, parsed at comptime from the common
/// stroke-icon dialect (24x24, stroke-width 2, currentColor). Lives
/// under src/ so `@embedFile` reaches it from the module root (and the
/// contract's source hash covers icon changes-adjacent code).
const waveform_icon = canvas.svg_icon.parseComptime(@embedFile("icons/waveform.svg"));

/// The album-grid glyph for the declared mobile tab bar (a 2x2 tile
/// grid): tab icons come from the registered app-icon vocabulary, so
/// the projected native bar tints the app's own artwork.
const albums_icon = canvas.svg_icon.parseComptime(@embedFile("icons/albums.svg"));

/// Single-track loop glyph for the transport play-mode cycle (the SDK
/// ships plain `repeat` / `shuffle`; the "1" badge is app-owned).
const repeat_1_icon = canvas.svg_icon.parseComptime(@embedFile("icons/repeat-1.svg"));

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
    .{ .name = "waveform", .icon = &waveform_icon },
    .{ .name = "albums", .icon = &albums_icon },
    .{ .name = "repeat-1", .icon = &repeat_1_icon },
    .{ .name = "sequential", .icon = &sequential_icon },
    .{ .name = "queue", .icon = &queue_icon },
};

/// Install the app icon table; once, before views build (main does it
/// first thing, and the tests' harness setup mirrors it).
pub fn registerIcons() void {
    canvas.icons.registerAppIcons(&app_icons);
}

// ------------------------------------------------------------------ boot

/// Boot effect: restore the persisted user library when a store path is set.
pub fn boot(model: *Model, fx: *model_mod.Effects) void {
    if (model.storePath().len > 0) {
        fx.readFile(.{
            .key = model_mod.library_read_key,
            .path = model.storePath(),
            .on_result = model_mod.Effects.fileMsg(.library_done),
        });
    }
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
        .sync = sync,
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
/// runtime), so the header's search field blocks all of these without
/// this function knowing it exists. A QUIETLY focused track row (the
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
/// Playback clock advances come from the ~20 Hz `scrubber_tick` timer
/// in the model (not display-rate presents), so an idle or paused app
/// presents zero frames and a playing app stays near 20 Hz instead of
/// locking the Metal surface to the panel refresh.
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
pub fn onFrame(model: *const Model, frame: native_sdk.platform.GpuFrame) ?Msg {
    if (!ui_font_bytes_released) {
        ui_font_bytes_released = true;
        ui_font.releaseBytes(std.heap.page_allocator);
    }
    if (frame.size.width != model.canvas_width) {
        return Msg{ .canvas_resized = frame.size.width };
    }
    return null;
}

/// The runtime owns transient slider state (`.change` carries no value);
/// mirror the seek and volume sliders' reconciled values into the model
/// before each update so the Msg arms read what the user dragged to.
fn sync(model: *Model, layout: canvas.WidgetLayoutTree) void {
    for (layout.nodes) |node| {
        if (node.widget.kind != .slider) continue;
        if (std.mem.eql(u8, node.widget.semantics.label, "Seek")) {
            model.seek_fraction = node.widget.value;
        } else if (std.mem.eql(u8, node.widget.semantics.label, "Volume")) {
            model.volume = node.widget.value;
        }
    }
}

// ------------------------------------------------------------- animations

/// Track-change enter: title and cover fade/slide in on a critically
/// damped spring (theme motion), gated on the PLAYBACK clock
/// (`elapsed_ms` restarts per track). Split + stagger — title leads,
/// cover follows ~80 ms later — so chunks move independently instead of
/// one container. Translate is small (8pt): enough to telegraph arrival
/// without a theatrical drop. Window matches the theme's slow settle
/// (~340 ms) plus stagger headroom. Reduce-motion zeroes durations
/// through the theme; the same Msg sequence replays the same set.
const motion_window_ms: u32 = 420;
/// Stagger between title and cover enter animations (nanoseconds).
const cover_stagger_ns: u64 = 80_000_000;

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
    if (model.elapsed_ms > motion_window_ms) return 0;
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

// ----------------------------------------------------------------- mobile

/// Mobile embed seam: the same Model/Msg/update/view compiled into the
/// embed static library (`zig build lib`, which `native dev --target
/// ios` drives) with the canonical single-surface mobile scene. The
/// desktop window constants above — size, min size, the tall titlebar —
/// belong to the DESKTOP scene only: the mobile scene is the full-screen
/// surface the host owns, so nothing here constrains the phone. The
/// model seeds its pre-first-frame canvas width at a phone-portrait
/// value so the installing frame already composes the compact shell; the
/// first presented frame corrects it, exactly like the desktop seed.
pub fn initModel() Model {
    // The mobile host has no main(): the icon table installs here, once,
    // before any view builds (registration is idempotent — one static
    // table — so the test harness's own install never conflicts).
    registerIcons();
    prepareUiFonts();
    var model: Model = .{ .canvas_width = model_mod.compact_seed_canvas_width };
    // Streaming configuration, resolved once at boot exactly like the
    // desktop main() below — replay's deterministic-init contract holds
    // on phones too: no env read ever happens inside update. Without
    // this, every `fx.playAudio` would carry an empty cache_path and a
    // streamed track would re-download on every single play; with it,
    // the platform cache-fill installs the verified bytes under the
    // resolved directory's audio/ child and the next play is local.
    if (embedEnvValue("NATIVE_SDK_MUSIC_URL_BASE")) |base| model.setUrlBase(base);
    var cache_dir_buffer: [model_mod.max_cache_dir]u8 = undefined;
    const cache_dir = native_sdk.app_dirs.resolveOne(
        .{ .name = "wellmusic" },
        native_sdk.app_dirs.currentPlatform(),
        embedEnv(),
        .cache,
        &cache_dir_buffer,
    ) catch "";
    model.setCacheDir(cache_dir);
    return model;
}

/// The embed entry's environment for directory resolution: there is no
/// `std.process.Init` on this path (the host library calls `initModel()`
/// directly), so instead of `native_sdk.debug.envFromMap` over an owned
/// env map the values come from the process environment through libc.
/// Both phone platforms publish the app's directory namespace there
/// before any app code runs — iOS processes get HOME (the sandbox
/// container root) and TMPDIR from the OS itself, and the toolkit's
/// Android host exports HOME (the app data directory) and TMPDIR (its
/// cache/ child) in its activity's onCreate — and HOME/TMPDIR are the
/// only keys the phone resolvers read, so the desktop-only keys stay
/// null. A build that cannot reach `getenv` (see `embed_env_readable`)
/// has no environment to read: resolution fails honestly and the cache
/// stays disabled ("" — streaming still plays, each play just
/// re-downloads).
fn embedEnv() native_sdk.app_dirs.Env {
    return .{
        .home = embedEnvValue("HOME"),
        .tmpdir = embedEnvValue("TMPDIR"),
    };
}

/// Whether this compilation can emit a `getenv` call at all. The embed
/// static library declares no libc of its own (the Android slice
/// cross-compiles pure-Zig, without an NDK sysroot, so `std.c` symbols
/// are refused at compile time and `link_libc` is false) — but on the
/// phone targets the enclosing host process always links the system C
/// runtime (iOS apps link it unconditionally; the Android static lib
/// lands inside the host .so, which links bionic), so a plain extern
/// reference below resolves at the host link and the read is safe.
/// Everywhere else the call is emitted only when libc is actually
/// linked, so a libc-less desktop test build still links.
const embed_env_readable = builtin.link_libc or
    builtin.os.tag == .ios or
    (@hasField(@TypeOf(builtin.abi), "android") and builtin.abi == .android);

/// libc's environment lookup, declared as a bare external symbol (not
/// through `std.c`, whose declarations demand a declared libc
/// dependency): the symbol stays unreferenced unless
/// `embed_env_readable` holds, and where it holds the final link always
/// carries the C runtime that defines it.
extern fn getenv(name: [*:0]const u8) ?[*:0]u8;

/// One env read on the embed path (gated, see `embed_env_readable`). A
/// set but empty value comes back as "" — exactly what an env map's
/// `get` reports — so set-empty semantics (an empty URL base disables
/// streaming) match the desktop launch path.
fn embedEnvValue(name: [*:0]const u8) ?[]const u8 {
    if (comptime !embed_env_readable) return null;
    const value = getenv(name) orelse return null;
    return std.mem.span(value);
}

/// Declared platform chrome for the mobile scene: the Albums/Songs
/// navigation as a REAL system tab bar (the canonical music-app shape).
/// The ids are command ids — a projected tap dispatches them through
/// `onCommand` into the same `show_albums`/`show_songs` Msgs the
/// in-canvas switcher sends, and `selectedTab` mirrors `model.tab` back
/// so the bar always projects the model. No primary floating action on
/// purpose: the transport lives in the mini player bar, and a floating
/// play control would project playback twice.
const mobile_tab_albums_command = "tabs.albums";
const mobile_tab_songs_command = "tabs.songs";

/// The platform back command: a completed edge-swipe-back on the album
/// detail dispatches this id, which maps onto the exact `close_album`
/// Msg the in-canvas back button sends — the gesture and the button are
/// indistinguishable in the journal. A cancelled swipe dispatches
/// nothing.
const mobile_nav_back_command = "nav.back";

const mobile_chrome_tabs = [_]native_sdk.ShellTab{
    .{ .id = mobile_tab_albums_command, .label = "Albums", .icon = "app:albums" },
    .{ .id = mobile_tab_songs_command, .label = "Songs", .icon = "music" },
};

/// The canonical single-surface mobile scene plus the declared chrome.
const mobile_scene: native_sdk.ShellConfig = .{
    .windows = native_sdk.embed.mobile_shell_scene.windows,
    .chrome = .{ .tabs = &mobile_chrome_tabs },
};

/// Projected chrome taps and the menu-bar status item arrive as command
/// events; they map onto the same Msgs the canvas controls dispatch.
pub fn onCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, mobile_tab_albums_command)) return .show_albums;
    if (std.mem.eql(u8, name, mobile_tab_songs_command)) return .show_songs;
    if (std.mem.eql(u8, name, mobile_nav_back_command)) return .close_album;
    if (std.mem.eql(u8, name, "transport.toggle")) return .{ .media_command = .toggle_play };
    if (std.mem.eql(u8, name, "transport.next")) return .{ .media_command = .next };
    if (std.mem.eql(u8, name, "transport.previous")) return .{ .media_command = .previous };
    if (std.mem.eql(u8, name, "transport.queue")) return .toggle_queue;
    return null;
}

/// The model's selected tab as its declared command id — the projection
/// the native bar mirrors (an open album detail is still the Albums
/// tab, exactly like the in-canvas switcher's selected state).
pub fn selectedTab(model: *const Model) []const u8 {
    return switch (model.tab) {
        .albums => mobile_tab_albums_command,
        .songs => mobile_tab_songs_command,
    };
}

/// The model's navigation depth — the projection a host presents REAL
/// push/pop transitions from (album grid -> album detail pushes; back
/// pops). Depth follows the VISIBLE page stack, so an open album counts
/// only while the Albums tab shows it: switching to Songs with a detail
/// open is a lateral tab change (the host reconciles with no
/// transition), exactly like switching back. Presentation only — the
/// state is `model.open_album`, owned by update.
pub fn navigationDepth(model: *const Model) usize {
    return if (model.tab == .albums and model.open_album != null) 1 else 0;
}

pub fn mobileOptions() WellMusicApp.Options {
    return .{
        .name = "wellmusic",
        .scene = mobile_scene,
        .canvas_label = native_sdk.embed.mobile_gpu_surface_label,
        .update_fx = update,
        .view = rootView,
        .init_fx = boot,
        .tokens_fn = tokensFromModel,
        .fonts = ui_font_regs[0..ui_font_reg_count],
        .on_appearance = onAppearance,
        .on_chrome = onChrome,
        .on_command = onCommand,
        .selected_tab_fn = selectedTab,
        .navigation_depth_fn = navigationDepth,
        .navigation_back_command = mobile_nav_back_command,
        .on_key = onKey,
        .on_frame = onFrame,
        .animations = animations,
        .sync = sync,
    };
}

// ------------------------------------------------------------------- main

pub fn main(init: std.process.Init) !void {
    registerIcons();
    prepareUiFonts();
    // Streaming configuration, resolved once at launch: the env URL
    // base overrides the manifest's committed one (so a locally served
    // pack needs no re-prepare), and the platform caches directory
    // (~/Library/Caches/wellmusic on macOS, XDG cache on Linux) hosts
    // the track cache in its audio/ child — delete that directory to
    // clear the cache. Both land in the INITIAL model, so replay's
    // deterministic-init contract holds: no env read ever happens
    // inside update.
    var model: Model = .{};
    if (init.environ_map.get("NATIVE_SDK_MUSIC_URL_BASE")) |base| model.setUrlBase(base);
    var cache_dir_buffer: [model_mod.max_cache_dir]u8 = undefined;
    const cache_dir = native_sdk.app_dirs.resolveOne(
        .{ .name = "wellmusic" },
        native_sdk.app_dirs.currentPlatform(),
        native_sdk.debug.envFromMap(init.environ_map),
        .cache,
        &cache_dir_buffer,
    ) catch "";
    model.setCacheDir(cache_dir);
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
