//! wellmusic model: a user-owned music library with playback,
//! navigation, and theming state the views bind to.
//!
//! There is no built-in sample catalog. Tracks enter through the native
//! file dialog (`add_music` → Library album) or folder import
//! (`import_album` → new album). Audio (and covers) are copied into the
//! app data `media/` directory so moving the originals cannot break
//! playback; `library.txt` stores those managed paths.
//! Playback is real audio through the runtime audio effect family:
//! pressing play issues `fx.playAudio` for the track's absolute path
//! and every report — load acknowledgment, position ticks, completion,
//! failures — arrives as an `.audio_event` Msg.
//!
//! Fixed capacities (loud by design):
//!   - `max_user_albums` user albums (Library + folder imports)
//!   - `max_user_tracks` imported tracks across all albums
//!   - playlist sized to `max_user_tracks` (full album / play-next list)

const std = @import("std");
const native_sdk = @import("native_sdk");
const metadata = @import("metadata.zig");
const media_session = @import("media_session.zig");

const canvas = native_sdk.canvas;

pub const Effects = native_sdk.Effects(Msg);

// ------------------------------------------------------------------ library

pub const Album = struct {
    id: u8,
    title: []const u8,
    artist: []const u8,
    year: u16,
    initials: []const u8,
    art: ?[]const u8,
    track_start: u8,
    track_count: u8,
};

pub const Track = struct {
    id: u8,
    album: u8,
    number: u8,
    title: []const u8,
    /// Per-track artist; empty falls back to the album artist in the UI.
    artist: []const u8,
    path: []const u8,
    duration_ms: u32,
};

/// Album id 1 is the catch-all for loose file imports (`add_music`).
pub const imported_album_id: u8 = 1;
pub const first_user_album_id: u8 = 1;
pub const first_user_track_id: u8 = 1;
pub const max_user_albums = 32;
pub const max_user_tracks = 64;
pub const max_user_title = 128;
pub const max_user_path = 1024;
pub const max_library_store_bytes = 256 * 1024;
pub const max_store_path = 512;
pub const library_write_key: u64 = 4;
pub const session_read_key: u64 = 5;
pub const session_write_key: u64 = 6;
pub const session_store_header = "wellmusic-session v1";
pub const max_session_store_bytes = 4 * 1024;
/// Cover reads use `cover_read_key_base + album_id` so concurrent loads
/// stay attributable when several albums restore covers at once.
pub const cover_read_key_base: u64 = 100;
/// Encoded cover file ceiling for the sync load path. Larger than the
/// `fx.readFile` 1 MiB bound so phone photos can be imported; the pixels
/// are then downscaled to `max_cover_register_edge` before registration.
pub const max_cover_file_bytes: usize = 32 * 1024 * 1024;
/// Longest edge accepted from the platform decoder before we refuse.
/// 4096² RGBA ≈ 64 MiB temporary decode scratch.
pub const max_cover_decode_edge: usize = 4096;
/// Longest edge registered into the canvas image slot. Half the SDK
/// 512² avatar budget: album tiles and the 52pt now-playing cover do
/// not need full-res pixels, and 256² cuts texture RSS ~4×.
pub const max_cover_register_edge: usize = 256;
pub const library_store_header_v1 = "wellmusic-library v1";
pub const library_store_header_v2 = "wellmusic-library v2";
pub const library_store_header = "wellmusic-library v3";

pub fn coverReadKey(album_id: u8) u64 {
    return cover_read_key_base + album_id;
}

pub fn albumIdFromCoverKey(key: u64) ?u8 {
    if (key < cover_read_key_base or key > cover_read_key_base + 255) return null;
    return @intCast(key - cover_read_key_base);
}

pub fn isUserTrackId(id: u8) bool {
    return id >= first_user_track_id;
}

pub const UserAlbum = struct {
    id: u8 = 0,
    title_storage: [max_user_title]u8 = undefined,
    title_len: usize = 0,
    artist_storage: [max_user_title]u8 = undefined,
    artist_len: usize = 0,
    year: u16 = 2026,
    initials_storage: [2]u8 = .{ 'A', 'A' },
    cover_path_storage: [max_user_path]u8 = undefined,
    cover_path_len: usize = 0,
    /// Non-zero when a cover image is registered (ImageId == album id).
    cover: canvas.ImageId = 0,

    pub fn title(album: *const UserAlbum) []const u8 {
        return album.title_storage[0..album.title_len];
    }

    pub fn artist(album: *const UserAlbum) []const u8 {
        return album.artist_storage[0..album.artist_len];
    }

    pub fn initials(album: *const UserAlbum) []const u8 {
        return album.initials_storage[0..2];
    }

    pub fn coverPath(album: *const UserAlbum) []const u8 {
        return album.cover_path_storage[0..album.cover_path_len];
    }

    pub fn asAlbum(album: *const UserAlbum) Album {
        return .{
            .id = album.id,
            .title = album.title(),
            .artist = album.artist(),
            .year = album.year,
            .initials = album.initials(),
            .art = null,
            .track_start = 0,
            .track_count = 0,
        };
    }

    pub fn setTitle(album: *UserAlbum, value: []const u8) void {
        const len = @min(value.len, max_user_title);
        @memcpy(album.title_storage[0..len], value[0..len]);
        album.title_len = len;
        album.refreshInitials();
    }

    pub fn setArtist(album: *UserAlbum, value: []const u8) void {
        const len = @min(value.len, max_user_title);
        @memcpy(album.artist_storage[0..len], value[0..len]);
        album.artist_len = len;
        album.refreshInitials();
    }

    pub fn setCoverPath(album: *UserAlbum, value: []const u8) void {
        const len = @min(value.len, max_user_path);
        @memcpy(album.cover_path_storage[0..len], value[0..len]);
        album.cover_path_len = len;
    }

    pub fn clearCoverPath(album: *UserAlbum) void {
        album.cover_path_len = 0;
        album.cover = 0;
    }

    fn refreshInitials(album: *UserAlbum) void {
        const t = album.title();
        const a = album.artist();
        album.initials_storage[0] = if (t.len > 0) std.ascii.toUpper(t[0]) else 'A';
        album.initials_storage[1] = if (a.len > 0)
            std.ascii.toUpper(a[0])
        else if (t.len > 1)
            std.ascii.toUpper(t[1])
        else
            'A';
    }
};

pub const UserTrack = struct {
    id: u8 = 0,
    album: u8 = imported_album_id,
    number: u8 = 0,
    title_storage: [max_user_title]u8 = undefined,
    title_len: usize = 0,
    artist_storage: [max_user_title]u8 = undefined,
    artist_len: usize = 0,
    path_storage: [max_user_path]u8 = undefined,
    path_len: usize = 0,
    duration_ms: u32 = 0,

    pub fn title(track: *const UserTrack) []const u8 {
        return track.title_storage[0..track.title_len];
    }

    pub fn artist(track: *const UserTrack) []const u8 {
        return track.artist_storage[0..track.artist_len];
    }

    pub fn path(track: *const UserTrack) []const u8 {
        return track.path_storage[0..track.path_len];
    }

    pub fn asTrack(track: *const UserTrack) Track {
        return .{
            .id = track.id,
            .album = track.album,
            .number = track.number,
            .title = track.title(),
            .artist = track.artist(),
            .path = track.path(),
            .duration_ms = track.duration_ms,
        };
    }

    pub fn setTitle(track: *UserTrack, value: []const u8) void {
        const len = @min(value.len, max_user_title);
        @memcpy(track.title_storage[0..len], value[0..len]);
        track.title_len = len;
    }

    pub fn setArtist(track: *UserTrack, value: []const u8) void {
        const len = @min(value.len, max_user_title);
        @memcpy(track.artist_storage[0..len], value[0..len]);
        track.artist_len = len;
    }

    fn setPath(track: *UserTrack, value: []const u8) void {
        const len = @min(value.len, max_user_path);
        @memcpy(track.path_storage[0..len], value[0..len]);
        track.path_len = len;
    }
};

// -------------------------------------------------------------- capacities

/// Playlist capacity: large enough for every imported track so Play Album
/// can show the whole record. Play Next and double-click / Enter play
/// append into the same list.
pub const max_queue = max_user_tracks;
/// The header bar's natural height, and the floor `header_height` falls
/// back to when no titlebar band overlays the content (fullscreen,
/// standard chrome, tests). Matches the tall hidden-inset band the
/// system reports through `on_chrome` — keep the header no taller than
/// that band so `cross="center"` lands controls on the midline.
pub const header_natural_height: f32 = 52;
/// The window's content min-width floor (main.zig declares it on the
/// shell window) and the default `canvas_width` before the first
/// presented frame reports the real surface size. Defaulting to the
/// FLOOR is deliberate: a tree built before any frame arrives (boot,
/// tree-level tests, the layout audit's smallest swept size) derives an
/// album grid that fits the narrowest window the shell allows — it can
/// underfill a wider surface for one frame, never overflow a narrow one.
pub const min_canvas_width: f32 = 1056;

/// Effect keys, model-owned identity (effect-key style). Audio playback
/// keys are the track ids themselves — one key namespace per channel.
// library_write_key lives with the user-library caps.

/// The honest degraded state when a track's file cannot load.
pub const assets_missing_title = "couldn’t play this file";
pub const assets_missing_hint = "check the path or re-add the track";

// ------------------------------------------------------------------- model

/// How the transport picks the next track when one finishes (or the
/// user skips). When the current track is in the playlist, modes walk
/// that list; otherwise Play Next entries are consumed FIFO, then the
/// mode falls back to album order.
pub const PlayMode = enum {
    /// Wrap within the playlist (or album when the playlist is empty).
    list_loop,
    /// Play the playlist (or album) once and stop on the last track.
    sequential,
};

/// App-owned light/dark preference. `system` means follow the OS color
/// scheme from `appearance`; `light`/`dark` lock the tokens until the
/// user toggles again (high contrast / reduce motion still come from
/// the system appearance either way).
pub const ThemePreference = enum {
    system,
    light,
    dark,

    pub fn colorScheme(pref: ThemePreference, system: native_sdk.ColorScheme) native_sdk.ColorScheme {
        return switch (pref) {
            .system => system,
            .light => .light,
            .dark => .dark,
        };
    }
};

/// One presented frame's clock. Historically used to interpolate the
/// rendered playback clock between coarse player position ticks. The
/// live app has no seek scrubber, so this path is journal/test-only;
/// elapsed time comes from audio position events.
pub const FrameClock = struct {
    timestamp_ns: u64,
    interval_ns: u64,
};

/// How far the rendered clock may run AHEAD of a player position tick
/// before the disagreement stops being interpolation drift and gets
/// snapped. Drift per poll tick is a few milliseconds; anything past a
/// full tick means reality changed (an external seek, a stall the
/// buffering flag has not reported yet), and honesty beats smoothness.
const position_snap_slack_ms: u32 = 1200;

/// Playback-state poll while playing. The platform emits `.spectrum`
/// (~25 Hz) alongside position when `on_event` is set; WellMusic draws no
/// analyzer. So `playAudio` intentionally omits `on_event`, and this
/// timer (every ~2 s) mirrors position / completion / failure from
/// `fx.audioSnapshot()` instead. No seek scrubber and no elapsed label
/// means UiApp's mandatory rebuild-on-Msg is pure overhead for steady
/// ticks — 2 s still catches natural end quickly, and Now Playing is
/// updated inside the poll (content-throttled) without waiting on view.
pub const audio_poll_timer_key: u64 = 43;
pub const audio_poll_interval_ms: u64 = 2000;

pub const Msg = union(enum) {
    /// Header: cycle the app theme light ↔ dark (locks off
    /// system-follow on first press).
    toggle_theme,
    /// Header overflow (⋯): open or close the actions menu.
    toggle_header_menu,
    /// Header overflow: Escape / click-outside dismisses without acting.
    close_header_menu,
    /// Empty-state Add control: open or close the Add Song / Add Album menu.
    toggle_add_menu,
    /// Add dropdown: Escape / click-outside dismisses without importing.
    close_add_menu,
    set_appearance: native_sdk.Appearance,
    /// Chrome overlay geometry (tall hidden-inset titlebar): the header
    /// pads its leading edge past the traffic lights and matches its
    /// height to the titlebar band. Delivered through `on_chrome`.
    chrome_changed: native_sdk.WindowChrome,
    /// The canvas surface width, mirrored from presented frames through
    /// `on_frame` (main.zig emits it only when the width actually
    /// changed; unchanged-width frames instead carry the playback frame
    /// clock while audio moves, and nothing at all otherwise). The album
    /// grid derives its column count from this — the layout system's
    /// grid takes a FIXED column count and rows/columns never
    /// flow-wrap, so adapting to the window is the model's job: track
    /// the width, chunk in the view.
    canvas_resized: f32,
    open_album: u8,
    close_album,
    play_album: u8,
    play_track: u8,
    /// Single click (and Space activation) on a track row: SELECTION
    /// only — playback needs the double click, Enter, or the transport.
    select_track: u8,
    /// Arrow keys through the app-level key fallback: the selection
    /// walks the track list on screen, clamped at its ends, without
    /// touching playback.
    select_next,
    select_previous,
    /// Enter through the app-level key fallback: play the selected
    /// track (toggling pause when it is already the loaded one).
    play_selected,
    /// One presented frame: advances the rendered playback clock between
    /// coarse position ticks. Journal/test path only — the live app has
    /// no seek scrubber and does not arm a playback timer.
    frame_clock: FrameClock,
    /// ~2 s mirror of `fx.audioSnapshot()` while a track is loaded.
    /// Replaces platform `on_event` delivery so ~25 Hz spectrum reports
    /// never enter the TEA loop (see `audio_poll_timer_key`).
    audio_poll: native_sdk.EffectTimer,
    toggle_play,
    next_track,
    prev_track,
    /// Cycle the transport play mode: list loop ↔ sequential.
    cycle_play_mode,
    /// Volume slider changed; the applied fraction rides the Msg so a
    /// rebuild-time `sync` cannot clobber a just-restored volume with
    /// the previous frame's slider thumb (default 1.0 on first launch).
    volume_changed: f32,
    /// Toggle the playlist panel above the transport.
    toggle_queue,
    /// Remove one entry from the playlist by track id.
    remove_queued: u8,
    /// Clear the playlist.
    clear_queue,
    /// Drain a macOS remote-command / media-key binding into transport.
    media_command: enum { toggle_play, next, previous },
    /// Every audio playback report: the load acknowledgment, position
    /// ticks, the one completion, and failures. Tests and journals send
    /// these directly; the live player does not — see `audio_poll`.
    audio_event: native_sdk.EffectAudio,
    /// Controlled scroll: each region's applied offset lands here and the
    /// view echoes it back, so a rebuild mid-gesture can never reset it.
    grid_scrolled: canvas.ScrollState,
    detail_scrolled: canvas.ScrollState,
    /// Context menu: queue a track to play after the current one.
    queue_track: u8,
    /// Header: open a native multi-select file dialog and
    /// import the chosen audio files into the Library album.
    add_music,
    /// Header / empty state: pick a folder and import it as a new album.
    import_album,
    /// Context menu: remove a user-imported track from the library.
    remove_track: u8,
    /// Context menu: open the edit-song dialog for a user track.
    edit_track: u8,
    /// Album tile / detail: open the edit-album dialog.
    edit_album: u8,
    /// Edit dialog text fields (shared by song and album dialogs).
    edit_title: canvas.TextInputEvent,
    edit_artist: canvas.TextInputEvent,
    /// Edit dialog: commit title/artist and close.
    save_edit_track,
    /// Edit dialog: dismiss without saving.
    close_edit_track,
    /// Edit album dialog: commit title/artist and close.
    save_edit_album,
    /// Edit album dialog: dismiss without saving.
    close_edit_album,
    /// Album / cover menu: pick a new cover image for this album.
    change_cover: u8,
    /// First presented frame: migrate paths and heal titles. Covers then
    /// load one album per subsequent present (`cover_hydrate`). Armed
    /// once at launch after sync library restore; never persisted.
    library_hydrate,
    /// One album cover decode after `library_hydrate` (or after import).
    /// Spread across presents so first paint stays light.
    cover_hydrate,
    /// Persist library writes (reads are sync at launch via `loadLibrarySync`).
    library_done: native_sdk.EffectFileResult,
    /// Persist / restore playback session (now, queue, mode, volume).
    session_done: native_sdk.EffectFileResult,
    /// Decode a chosen cover image into the matching album cover slot.
    cover_done: native_sdk.EffectFileResult,

    /// Zig-only dispatch: the Zig-built views (album grid, track rows,
    /// context menus), the app-level key fallback, and the runtime
    /// channels (appearance, chrome, frames, audio, scroll echoes,
    /// process exits) send these — never a markup on-* event — so the
    /// dead-state lint must not ask for one.
    pub const view_unbound = .{
        "set_appearance", "chrome_changed", "canvas_resized",
        "open_album",     "close_album",    "play_album",
        "play_track",     "select_track",   "select_next",
        "select_previous", "play_selected", "frame_clock",
        "audio_poll",
        "audio_event",    "grid_scrolled",  "detail_scrolled",
        "queue_track",    "remove_track",   "edit_track",
        "edit_album",     "edit_title",     "edit_artist",
        "save_edit_track", "close_edit_track",
        "save_edit_album", "close_edit_album", "change_cover",
        "library_hydrate", "cover_hydrate",
        "library_done",   "cover_done",     "volume_changed",
        "toggle_queue",   "remove_queued",  "clear_queue",
        "media_command",
        "session_done",
    };
};

pub const Model = struct {
    // Source-of-truth state only; everything else is derived per rebuild.
    appearance: native_sdk.Appearance = .{},
    /// Light/dark preference for tokens. Defaults to system-follow so a
    /// fresh install matches the OS; `toggle_theme` locks light or dark.
    theme: ThemePreference = .system,
    open_album: ?u8 = null,
    /// Controlled scroll offsets (album grid and album detail):
    /// the model observes the applied offset and echoes it back.
    grid_scroll: f32 = 0,
    detail_scroll: f32 = 0,
    /// Chrome overlay geometry from `on_chrome` (tall hidden-inset
    /// titlebar): the header leads with a spacer this wide so its
    /// controls clear the traffic lights, and matches its height to the
    /// titlebar band. Both fall back to the natural header when no band
    /// overlays the content (fullscreen, standard chrome, tests).
    chrome_leading: f32 = 0,
    /// The trailing twin: how far OS window controls overlay the
    /// header's END (Windows delivers the min/max/close cluster here;
    /// macOS reports zero). The header closes with a spacer this wide
    /// so the trailing controls clear the caption buttons.
    chrome_trailing: f32 = 0,
    header_height: f32 = header_natural_height,
    /// The live canvas width, from `canvas_resized`. Seeds at the window
    /// min-width floor (see `min_canvas_width`) so pre-first-frame trees
    /// fit the narrowest window; the first presented frame corrects it.
    canvas_width: f32 = min_canvas_width,
    now: ?u8 = null, // playing track id
    /// Transport play mode: list loop or sequential.
    /// Default matches the historic wrap-within-album advance.
    play_mode: PlayMode = .list_loop,
    /// The SELECTED track id — the inverted accent row in track lists.
    /// Distinct from `now` on purpose: single click / arrows move the
    /// selection, only a double click, Enter, or the transport moves
    /// playback. Starting a track selects it too (the playing row is the
    /// current row), but selecting never plays.
    selected: ?u8 = null,
    playing: bool = false,
    /// Playback clock for session restore and Now Playing. Advanced by
    /// player position ticks (and the journal-only `frame_clock` path);
    /// there is no live scrubber and the view does not bind this field.
    elapsed_ms: u32 = 0,
    /// The last `frame_clock` timestamp, the delta base for the rendered
    /// clock. Never reset: a stale gap (pause, occlusion, boot) is
    /// bounded by the frame-interval clamp in `advanceRenderedClock`.
    frame_ns: u64 = 0,
    /// The loaded track's TOTAL: the manifest duration when present,
    /// otherwise the platform's self-reported duration (see
    /// `handleAudioEvent`). Used for session/media-session metadata —
    /// not a visible scrubber denominator.
    now_duration_ms: u32 = 0,
    /// The platform player's own duration report, mirrored verbatim
    /// from the audio events: observable state for tests and debugging,
    /// and the fallback total above — never the displayed number while
    /// the manifest has one.
    platform_duration_ms: u32 = 0,
    /// A track's file failed to load (it was moved, deleted, or the platform has no
    /// audio playback): playback is cleared and the now-playing bar
    /// shows the prepare hint instead.
    assets_missing: bool = false,
    /// Armed when the audio-poll fx timer is live. Edge-triggered so
    /// re-arming every update cannot starve fires. Model-owned for
    /// test / journal isolation.
    audio_poll_armed: bool = false,
    /// Playlist (Play Album fills it with the whole record; Play Next and
    /// double-click / Enter play append).
    queue: [max_queue]u8 = @splat(0),
    queue_len: usize = 0,
    queue_dropped: u32 = 0,
    /// Volume slider value (0..1), set by `volume_changed` and applied
    /// with `fx.setAudioVolume`. Remembered in the session store.
    volume: f32 = 1.0,
    /// Whether the playlist panel is expanded above the transport.
    queue_open: bool = false,
    /// Header overflow (⋯): the anchored actions menu is open.
    /// Ephemeral — not persisted; Escape / outside click / an action
    /// choice clears it.
    header_menu_open: bool = false,
    /// Empty-state Add control: the anchored dropdown is open.
    /// Ephemeral — not persisted; Escape / outside click / an import
    /// choice clears it.
    add_menu_open: bool = false,
    /// Track currently open in the edit-song dialog (null = closed).
    editing_track: ?u8 = null,
    /// Album currently open in the edit-album dialog (null = closed).
    /// Mutually exclusive with `editing_track`.
    editing_album: ?u8 = null,
    edit_title_buffer: canvas.TextBuffer(max_user_title) = .{},
    edit_artist_buffer: canvas.TextBuffer(max_user_title) = .{},
    /// User albums (Library + folder imports). Cap is loud by design.
    user_albums: [max_user_albums]UserAlbum = undefined,
    user_album_count: usize = 0,
    next_user_album_id: u8 = first_user_album_id + 1,
    /// User-imported tracks across all albums. Cap is loud by design.
    user_tracks: [max_user_tracks]UserTrack = undefined,
    user_track_count: usize = 0,
    next_user_track_id: u8 = first_user_track_id,
    /// Application Support path for the user-library store.
    store_path_buffer: [max_store_path]u8 = undefined,
    store_path_len: usize = 0,
    /// Sibling session store (now / queue / mode / volume).
    session_path_buffer: [max_store_path]u8 = undefined,
    session_path_len: usize = 0,
    /// App-data directory that owns imported audio/cover copies.
    media_dir_buffer: [max_store_path]u8 = undefined,
    media_dir_len: usize = 0,
    store_write_inflight: bool = false,
    save_pending: bool = false,
    session_write_inflight: bool = false,
    session_save_pending: bool = false,
    /// Set after a session restore asks playback to resume — cleared
    /// once `applySessionResume` runs. Launch always resumes paused
    /// (ignores a stored playing=1); the flag still round-trips for tests.
    session_resume_track: ?u8 = null,
    session_resume_elapsed_ms: u32 = 0,
    session_resume_playing: bool = false,
    /// `now` is bound for UI after session restore, but `playAudio` has
    /// not run yet. Cleared on the first play (or when `startTrack`
    /// replaces the binding). Avoids decoding the last track at launch.
    audio_deferred: bool = false,
    /// Armed at launch after sync library restore; first frame clears it
    /// via `library_hydrate` so migrate / title heal never block the
    /// initial present. Cover loads follow via `cover_hydrate_pending`.
    library_hydrate_pending: bool = false,
    /// After hydrate (or import), decode one cover per present until
    /// every album with a path has been tried.
    cover_hydrate_pending: bool = false,
    cover_hydrate_index: usize = 0,

    /// Read by the ZIG-BUILT views (grid, detail, track rows), update
    /// logic, or main's launch wiring — never bound in markup — so
    /// opting them out keeps `native check`'s dead-state lint quiet
    /// without weakening it for real drift. The markup fragments bind
    /// the derived fns (`nowPlayingTitle`, `playPauseIcon`, ...) instead
    /// of these backing stores.
    pub const view_unbound = .{
        "open_album",      "grid_scroll",
        "detail_scroll",   "canvas_width",
        "now",             "selected",       "playing",
        "play_mode",
        "elapsed_ms",      "frame_ns",       "now_duration_ms",
        "platform_duration_ms",
        "assets_missing",
        "audio_poll_armed",
        "queue_dropped",
        "volume",
        "appearance",      "theme",          "queue",          "queue_len",
        "editing_track",   "editing_album",  "edit_title_buffer",
        "edit_artist_buffer",
        "colorScheme",     "hasNowPlaying",
        "visibleAlbums",
        "albumCount",
        "user_albums",     "user_album_count", "next_user_album_id",
        "user_tracks",     "user_track_count", "next_user_track_id",
        "store_path_buffer", "store_path_len", "store_write_inflight",
        "session_path_buffer", "session_path_len",
        "media_dir_buffer", "media_dir_len",
        "session_write_inflight", "session_save_pending",
        "session_resume_track", "session_resume_elapsed_ms",
        "session_resume_playing",
        "audio_deferred",
        "library_hydrate_pending",
        "cover_hydrate_pending", "cover_hydrate_index",
        "save_pending",
        "storePath",       "sessionPath",    "mediaDir",
        "editTitle",
        "editArtist",      "isEditingTrack",
        "isEditingAlbum",  "queuedTracks",   "volumeFraction",
    };

    // ------------------------------------------------------------- queries

    pub fn colorScheme(model: *const Model) native_sdk.ColorScheme {
        return model.theme.colorScheme(model.appearance.color_scheme);
    }

    /// Glyph for the theme toggle: show the destination (moon → dark,
    /// sun → light) so the control names what pressing it will do.
    pub fn themeIcon(model: *const Model) []const u8 {
        return switch (model.colorScheme()) {
            .light => "moon",
            .dark => "sun",
        };
    }

    /// Menu label for the theme toggle — same destination naming as
    /// `themeIcon` (pressing switches to this mode).
    pub fn themeLabel(model: *const Model) []const u8 {
        return switch (model.colorScheme()) {
            .light => "Dark mode",
            .dark => "Light mode",
        };
    }

    pub fn coverFor(model: *const Model, album_id: u8) canvas.ImageId {
        const album = model.userAlbumById(album_id) orelse return 0;
        return album.cover;
    }

    pub fn storePath(model: *const Model) []const u8 {
        return model.store_path_buffer[0..model.store_path_len];
    }

    pub fn setStorePath(model: *Model, value: []const u8) void {
        if (value.len > max_store_path) return;
        @memcpy(model.store_path_buffer[0..value.len], value);
        model.store_path_len = value.len;
    }

    pub fn sessionPath(model: *const Model) []const u8 {
        return model.session_path_buffer[0..model.session_path_len];
    }

    pub fn setSessionPath(model: *Model, value: []const u8) void {
        if (value.len > max_store_path) return;
        @memcpy(model.session_path_buffer[0..value.len], value);
        model.session_path_len = value.len;
    }

    pub fn mediaDir(model: *const Model) []const u8 {
        return model.media_dir_buffer[0..model.media_dir_len];
    }

    pub fn setMediaDir(model: *Model, value: []const u8) void {
        if (value.len > max_store_path) return;
        @memcpy(model.media_dir_buffer[0..value.len], value);
        model.media_dir_len = value.len;
    }

    pub fn volumeFraction(model: *const Model) f32 {
        return std.math.clamp(model.volume, 0, 1);
    }

    pub fn userAlbumById(model: *const Model, id: u8) ?*const UserAlbum {
        for (model.user_albums[0..model.user_album_count]) |*album| {
            if (album.id == id) return album;
        }
        return null;
    }

    pub fn userAlbumByIdMut(model: *Model, id: u8) ?*UserAlbum {
        for (model.user_albums[0..model.user_album_count]) |*album| {
            if (album.id == id) return album;
        }
        return null;
    }

    /// Resolve a user album into the shared Album shape. Slices borrow
    /// from the model buffers — valid while the model is not mutated.
    pub fn albumById(model: *const Model, id: u8) ?Album {
        const album = model.userAlbumById(id) orelse return null;
        return album.asAlbum();
    }

    pub fn isEditingTrack(model: *const Model) bool {
        return model.editing_track != null;
    }

    pub fn isEditingAlbum(model: *const Model) bool {
        return model.editing_album != null;
    }

    pub fn editTitle(model: *const Model) []const u8 {
        return model.edit_title_buffer.text();
    }

    pub fn editArtist(model: *const Model) []const u8 {
        return model.edit_artist_buffer.text();
    }

    pub fn albumCount(model: *const Model) usize {
        var count: usize = 0;
        for (model.user_albums[0..model.user_album_count]) |*album| {
            if (model.tracksInAlbum(album.id) > 0) count += 1;
        }
        return count;
    }

    pub fn tracksInAlbum(model: *const Model, album_id: u8) usize {
        var count: usize = 0;
        for (model.user_tracks[0..model.user_track_count]) |*track| {
            if (track.album == album_id) count += 1;
        }
        return count;
    }

    pub fn userTrackById(model: *const Model, id: u8) ?*const UserTrack {
        for (model.user_tracks[0..model.user_track_count]) |*track| {
            if (track.id == id) return track;
        }
        return null;
    }

    pub fn userTrackByIdMut(model: *Model, id: u8) ?*UserTrack {
        for (model.user_tracks[0..model.user_track_count]) |*track| {
            if (track.id == id) return track;
        }
        return null;
    }

    /// Resolve a user track into the shared Track shape. Slices borrow
    /// from the model buffers — valid while the model is not mutated.
    pub fn resolveTrack(model: *const Model, id: u8) ?Track {
        if (model.userTrackById(id)) |track| return track.asTrack();
        return null;
    }

    pub fn nowTrack(model: *const Model) ?Track {
        const id = model.now orelse return null;
        return model.resolveTrack(id);
    }

    /// The open album's title, for the detail page's markup heading
    /// (album_title.native binds it). Total over the model on purpose —
    /// markup bindings resolve on every rebuild — so it answers "" when
    /// no album is open (the grid page, where the fragment is not
    /// composed).
    pub fn openAlbumTitle(model: *const Model) []const u8 {
        const id = model.open_album orelse return "";
        const album = model.userAlbumById(id) orelse return "";
        return album.title();
    }

    pub fn hasNowPlaying(model: *const Model) bool {
        return model.now != null;
    }

    pub fn idle(model: *const Model) bool {
        return model.now == null;
    }

    /// Data-driven icon choice for the transport's primary button: the
    /// markup binds `icon="{playPauseIcon}"`, so ONE button swaps its
    /// glyph with playback state - no if/else arms, no shared key to
    /// keep its identity stable.
    pub fn playPauseIcon(model: *const Model) []const u8 {
        return if (model.playing) "pause" else "play";
    }

    /// Glyph for the play-mode cycle button.
    pub fn playModeIcon(model: *const Model) []const u8 {
        return switch (model.play_mode) {
            .list_loop => "repeat",
            .sequential => "app:sequential",
        };
    }

    pub fn nowPlayingCover(model: *const Model) canvas.ImageId {
        const track = model.nowTrack() orelse return 0;
        return model.coverFor(track.album);
    }

    pub fn nowPlayingInitials(model: *const Model) []const u8 {
        const track = model.nowTrack() orelse return "--";
        const album = model.userAlbumById(track.album) orelse return "--";
        return album.initials();
    }

    /// The bar's first line doubles as the status line: the honest
    /// assets-not-prepared notice replaces the track title after a load
    /// failure, so the user is told what to run instead of hearing
    /// nothing.
    pub fn nowPlayingTitle(model: *const Model) []const u8 {
        if (model.assets_missing) return assets_missing_title;
        const track = model.nowTrack() orelse return "Nothing playing";
        return track.title;
    }

    pub fn nowPlayingArtist(model: *const Model) []const u8 {
        if (model.assets_missing) return assets_missing_hint;
        const track = model.nowTrack() orelse return "Pick an album or a song to start";
        if (track.artist.len > 0) return track.artist;
        const album = model.userAlbumById(track.album) orelse return "";
        return album.artist();
    }

    /// Playlist rows for the queue panel (includes the now-playing track
    /// when it is part of the list — Play Album puts the whole record here).
    pub fn queuedTracks(model: *const Model, arena: std.mem.Allocator) []const TrackRow {
        const out = arena.alloc(TrackRow, model.queue_len) catch return &.{};
        var count: usize = 0;
        for (model.queue[0..model.queue_len]) |id| {
            const track = model.resolveTrack(id) orelse continue;
            out[count] = model.trackRow(arena, track, .with_album);
            count += 1;
        }
        return out[0..count];
    }

    /// Index of `track_id` in the playlist, if present.
    pub fn queueIndexOf(model: *const Model, track_id: u8) ?usize {
        for (model.queue[0..model.queue_len], 0..) |queued, i| {
            if (queued == track_id) return i;
        }
        return null;
    }

    /// Visible albums, derived into the build arena.
    pub fn visibleAlbums(model: *const Model, arena: std.mem.Allocator) []const AlbumCell {
        const out = arena.alloc(AlbumCell, model.user_album_count) catch return &.{};
        var count: usize = 0;
        for (model.user_albums[0..model.user_album_count]) |*user| {
            if (model.tracksInAlbum(user.id) == 0) continue;
            const album = user.asAlbum();
            out[count] = .{
                .id = album.id,
                .title = album.title,
                .artist = album.artist,
                .initials = album.initials,
                .cover = model.coverFor(album.id),
            };
            count += 1;
        }
        return out[0..count];
    }

    /// One album's tracks for the detail view.
    pub fn albumTrackRows(model: *const Model, arena: std.mem.Allocator, album_id: u8) []const TrackRow {
        const total = model.tracksInAlbum(album_id);
        const out = arena.alloc(TrackRow, total) catch return &.{};
        var count: usize = 0;
        var number: u8 = 1;
        while (number <= total) : (number += 1) {
            const user = model.userTrackInAlbumByNumber(album_id, number) orelse continue;
            out[count] = model.trackRow(arena, user.asTrack(), .number_only);
            count += 1;
        }
        return out[0..count];
    }

    const TrackRowStyle = enum { with_album, number_only };

    fn trackRow(model: *const Model, arena: std.mem.Allocator, track: Track, style: TrackRowStyle) TrackRow {
        const album = model.userAlbumById(track.album);
        const album_artist = if (album) |a| a.artist() else "";
        const album_title = if (album) |a| a.title() else "";
        const artist = if (track.artist.len > 0) track.artist else album_artist;
        return .{
            .id = track.id,
            .number = std.fmt.allocPrint(arena, "{d}", .{track.number}) catch "",
            .title = track.title,
            .subtitle = switch (style) {
                .with_album => std.fmt.allocPrint(arena, "{s} — {s}", .{ artist, album_title }) catch "",
                .number_only => if (track.artist.len > 0) track.artist else "",
            },
            .duration = formatMs(arena, track.duration_ms),
            .now = model.now == track.id,
            .playing = model.now == track.id and model.playing,
            .selected = model.selected == track.id,
            .removable = isUserTrackId(track.id),
        };
    }

    fn isQueued(model: *const Model, track_id: u8) bool {
        for (model.queue[0..model.queue_len]) |queued| {
            if (queued == track_id) return true;
        }
        return false;
    }

    fn userTrackInAlbumByNumber(model: *const Model, album_id: u8, number: u8) ?*const UserTrack {
        for (model.user_tracks[0..model.user_track_count]) |*track| {
            if (track.album == album_id and track.number == number) return track;
        }
        return null;
    }

    fn firstTrackIdInAlbum(model: *const Model, album_id: u8) ?u8 {
        const track = model.userTrackInAlbumByNumber(album_id, 1) orelse return null;
        return track.id;
    }

    // ------------------------------------------------------------ mutation

    fn pushQueue(model: *Model, track_id: u8) void {
        if (model.isQueued(track_id)) return;
        if (model.queue_len >= max_queue) {
            model.queue_dropped += 1;
            return;
        }
        model.queue[model.queue_len] = track_id;
        model.queue_len += 1;
    }

    fn popQueue(model: *Model) ?u8 {
        if (model.queue_len == 0) return null;
        const next = model.queue[0];
        for (model.queue[1..model.queue_len], 0..) |moved, slot| {
            model.queue[slot] = moved;
        }
        model.queue_len -= 1;
        return next;
    }

    fn pathAlreadyImported(model: *const Model, path: []const u8) bool {
        for (model.user_tracks[0..model.user_track_count]) |*track| {
            if (std.mem.eql(u8, track.path(), path)) return true;
        }
        return false;
    }

    /// Ensure the Library album (id 1) exists for loose file imports.
    pub fn ensureLibraryAlbum(model: *Model) bool {
        if (model.userAlbumById(imported_album_id) != null) return true;
        if (model.user_album_count >= max_user_albums) return false;
        var album: UserAlbum = .{};
        album.id = imported_album_id;
        album.setTitle("Library");
        album.setArtist("My Music");
        album.year = 2026;
        model.user_albums[model.user_album_count] = album;
        model.user_album_count += 1;
        if (model.next_user_album_id <= imported_album_id) {
            model.next_user_album_id = imported_album_id + 1;
        }
        return true;
    }

    /// Create a user album. Returns the new album id, or null when full.
    pub fn addUserAlbum(model: *Model, title: []const u8, artist: []const u8) ?u8 {
        if (model.user_album_count >= max_user_albums) return null;
        if (model.next_user_album_id == 0) return null;
        // Never reuse the Library id for folder imports.
        if (model.next_user_album_id == imported_album_id) model.next_user_album_id += 1;
        if (model.next_user_album_id == 0) return null;
        var album: UserAlbum = .{};
        album.id = model.next_user_album_id;
        album.setTitle(if (title.len > 0) title else "Album");
        album.setArtist(if (artist.len > 0) artist else "My Music");
        album.year = 2026;
        model.user_albums[model.user_album_count] = album;
        model.user_album_count += 1;
        model.next_user_album_id += 1;
        return album.id;
    }

    fn removeUserAlbum(model: *Model, id: u8) void {
        var index: ?usize = null;
        var cover_buf: [max_user_path]u8 = undefined;
        var cover_len: usize = 0;
        for (model.user_albums[0..model.user_album_count], 0..) |*album, i| {
            if (album.id == id) {
                index = i;
                const cover = album.coverPath();
                if (cover.len > 0) {
                    @memcpy(cover_buf[0..cover.len], cover);
                    cover_len = cover.len;
                }
                break;
            }
        }
        const at = index orelse return;
        var write: usize = 0;
        for (model.user_albums[0..model.user_album_count], 0..) |album, i| {
            if (i == at) continue;
            model.user_albums[write] = album;
            write += 1;
        }
        model.user_album_count = write;
        if (model.open_album == id) model.open_album = null;
        if (model.editing_album == id) model.cancelEditAlbum();
        if (cover_len > 0) deleteManagedMediaFile(model, cover_buf[0..cover_len]);
    }

    fn renumberAlbumTracks(model: *Model, album_id: u8) void {
        var number: u8 = 1;
        for (model.user_tracks[0..model.user_track_count]) |*track| {
            if (track.album != album_id) continue;
            track.number = number;
            number += 1;
        }
    }

    /// Import one absolute audio path into the Library album. Returns
    /// false when the library is full, the path is empty/too long, or it
    /// is already present.
    pub fn addUserTrack(model: *Model, path: []const u8) bool {
        return model.addUserTrackToAlbum(imported_album_id, path);
    }

    /// Import one absolute audio path into a specific album.
    pub fn addUserTrackToAlbum(model: *Model, album_id: u8, path: []const u8) bool {
        return model.addUserTrackToAlbumNamed(album_id, path, path);
    }

    /// Like `addUserTrackToAlbum`, but when tags are missing the title falls
    /// back to `name_path`'s basename (the original import source), not the
    /// managed `media/t{id}` copy path.
    pub fn addUserTrackToAlbumNamed(
        model: *Model,
        album_id: u8,
        path: []const u8,
        name_path: []const u8,
    ) bool {
        if (path.len == 0 or path.len > max_user_path) return false;
        if (model.user_track_count >= max_user_tracks) return false;
        if (model.pathAlreadyImported(path)) return false;
        if (model.next_user_track_id == 0) return false;
        if (album_id == imported_album_id) {
            if (!model.ensureLibraryAlbum()) return false;
        } else if (model.userAlbumById(album_id) == null) {
            return false;
        }
        var track: UserTrack = .{};
        track.id = model.next_user_track_id;
        track.album = album_id;
        track.number = @intCast(model.tracksInAlbum(album_id) + 1);
        track.setPath(path);
        const meta = metadata.probeFile(path);
        if (meta.title_len > 0) {
            track.setTitle(meta.title[0..meta.title_len]);
        } else {
            track.setTitle(titleFromPath(name_path));
        }
        if (meta.artist_len > 0) track.setArtist(meta.artist[0..meta.artist_len]);
        if (meta.duration_ms > 0) track.duration_ms = meta.duration_ms;
        model.user_tracks[model.user_track_count] = track;
        model.user_track_count += 1;
        model.next_user_track_id += 1;
        // First track in a folder album can rename a generic album from tags.
        if (album_id != imported_album_id and track.number == 1) {
            if (model.userAlbumByIdMut(album_id)) |album| {
                if (meta.album_len > 0) album.setTitle(meta.album[0..meta.album_len]);
                if (meta.artist_len > 0 and std.mem.eql(u8, album.artist(), "My Music")) {
                    album.setArtist(meta.artist[0..meta.artist_len]);
                }
            }
        }
        return true;
    }

    /// Re-probe tracks whose title still equals the path basename (the
    /// managed `t{id}` fallback, or a tagless import). Fills title/artist/
    /// duration when the probe now succeeds — heals libraries imported
    /// before large-ID3 parsing worked.
    pub fn refreshTitlesFromMedia(model: *Model) bool {
        var changed = false;
        for (model.user_tracks[0..model.user_track_count]) |*track| {
            const path = track.path();
            const current = track.title();
            const fallback = titleFromPath(path);
            if (current.len > 0 and !std.mem.eql(u8, current, fallback)) continue;
            const meta = metadata.probeFile(path);
            if (meta.title_len > 0) {
                track.setTitle(meta.title[0..meta.title_len]);
                changed = true;
            }
            if (meta.artist_len > 0 and track.artist().len == 0) {
                track.setArtist(meta.artist[0..meta.artist_len]);
                changed = true;
            }
            if (meta.duration_ms > 0 and track.duration_ms == 0) {
                track.duration_ms = meta.duration_ms;
                changed = true;
            }
        }
        return changed;
    }

    pub fn removeUserTrack(model: *Model, id: u8) bool {
        var index: ?usize = null;
        var album_id: u8 = 0;
        var path_buf: [max_user_path]u8 = undefined;
        var path_len: usize = 0;
        for (model.user_tracks[0..model.user_track_count], 0..) |*track, i| {
            if (track.id == id) {
                index = i;
                album_id = track.album;
                const path = track.path();
                @memcpy(path_buf[0..path.len], path);
                path_len = path.len;
                break;
            }
        }
        const at = index orelse return false;
        var write: usize = 0;
        for (model.user_tracks[0..model.user_track_count], 0..) |track, i| {
            if (i == at) continue;
            model.user_tracks[write] = track;
            write += 1;
        }
        model.user_track_count = write;
        model.renumberAlbumTracks(album_id);
        if (model.tracksInAlbum(album_id) == 0) {
            model.removeUserAlbum(album_id);
        }
        // Drop queue entries and clear playback/selection that pointed here.
        var q_write: usize = 0;
        for (model.queue[0..model.queue_len]) |queued| {
            if (queued == id) continue;
            model.queue[q_write] = queued;
            q_write += 1;
        }
        model.queue_len = q_write;
        if (model.now == id) {
            model.now = null;
            model.playing = false;
            model.elapsed_ms = 0;
            model.now_duration_ms = 0;
            model.platform_duration_ms = 0;
        }
        if (model.selected == id) model.selected = null;
        if (path_len > 0) deleteManagedMediaFile(model, path_buf[0..path_len]);
        return true;
    }

    pub fn serializeLibrary(model: *const Model, buffer: []u8) []const u8 {
        var len: usize = 0;
        appendFmt(buffer, &len, "{s}\n", .{library_store_header});
        for (model.user_albums[0..model.user_album_count]) |*album| {
            appendFmt(buffer, &len, "album\t{d}\t{s}\t{s}\t{d}\t{s}\n", .{
                album.id,
                album.title(),
                album.artist(),
                album.year,
                album.coverPath(),
            });
        }
        for (model.user_tracks[0..model.user_track_count]) |*track| {
            appendFmt(buffer, &len, "track\t{d}\t{d}\t{d}\t{s}\t{s}\t{s}\t{d}\n", .{
                track.id,
                track.album,
                track.number,
                track.title(),
                track.artist(),
                track.path(),
                track.duration_ms,
            });
        }
        return buffer[0..len];
    }

    pub fn serializeSession(model: *const Model, buffer: []u8) []const u8 {
        var len: usize = 0;
        appendFmt(buffer, &len, "{s}\n", .{session_store_header});
        appendFmt(buffer, &len, "now\t{d}\n", .{model.now orelse 0});
        appendFmt(buffer, &len, "elapsed\t{d}\n", .{model.elapsed_ms});
        appendFmt(buffer, &len, "playing\t{d}\n", .{@as(u8, if (model.playing) 1 else 0)});
        appendFmt(buffer, &len, "mode\t{s}\n", .{playModeName(model.play_mode)});
        appendFmt(buffer, &len, "theme\t{s}\n", .{themePreferenceName(model.theme)});
        appendFmt(buffer, &len, "volume\t{d:.4}\n", .{std.math.clamp(model.volume, 0, 1)});
        appendFmt(buffer, &len, "queue_open\t{d}\n", .{@as(u8, if (model.queue_open) 1 else 0)});
        appendFmt(buffer, &len, "queue", .{});
        for (model.queue[0..model.queue_len]) |id| {
            appendFmt(buffer, &len, "\t{d}", .{id});
        }
        appendFmt(buffer, &len, "\n", .{});
        return buffer[0..len];
    }

    pub fn restoreSession(model: *Model, bytes: []const u8) bool {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        const header = lines.next() orelse return false;
        if (!std.mem.eql(u8, std.mem.trim(u8, header, " \r"), session_store_header)) return false;
        var now_id: u8 = 0;
        var elapsed: u32 = 0;
        var playing: bool = false;
        var mode: PlayMode = .list_loop;
        var theme: ThemePreference = .system;
        var volume: f32 = 1.0;
        var queue_open: bool = false;
        var queue_buf: [max_queue]u8 = @splat(0);
        var queue_len: usize = 0;
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \r");
            if (line.len == 0) continue;
            var parts = std.mem.splitScalar(u8, line, '\t');
            const key = parts.next() orelse return false;
            if (std.mem.eql(u8, key, "now")) {
                const text = parts.next() orelse return false;
                now_id = std.fmt.parseInt(u8, text, 10) catch return false;
            } else if (std.mem.eql(u8, key, "elapsed")) {
                const text = parts.next() orelse return false;
                elapsed = std.fmt.parseInt(u32, text, 10) catch return false;
            } else if (std.mem.eql(u8, key, "playing")) {
                const text = parts.next() orelse return false;
                playing = (std.fmt.parseInt(u8, text, 10) catch return false) != 0;
            } else if (std.mem.eql(u8, key, "mode")) {
                const text = parts.next() orelse return false;
                mode = parsePlayMode(text) orelse return false;
            } else if (std.mem.eql(u8, key, "theme")) {
                const text = parts.next() orelse return false;
                theme = parseThemePreference(text) orelse return false;
            } else if (std.mem.eql(u8, key, "volume")) {
                const text = parts.next() orelse return false;
                volume = std.fmt.parseFloat(f32, text) catch return false;
            } else if (std.mem.eql(u8, key, "queue_open")) {
                const text = parts.next() orelse return false;
                queue_open = (std.fmt.parseInt(u8, text, 10) catch return false) != 0;
            } else if (std.mem.eql(u8, key, "queue")) {
                while (parts.next()) |id_text| {
                    if (id_text.len == 0) continue;
                    if (queue_len >= max_queue) break;
                    queue_buf[queue_len] = std.fmt.parseInt(u8, id_text, 10) catch return false;
                    queue_len += 1;
                }
            } else return false;
        }
        model.play_mode = mode;
        model.theme = theme;
        model.volume = std.math.clamp(volume, 0, 1);
        model.queue_open = queue_open;
        model.queue = queue_buf;
        model.queue_len = queue_len;
        // Drop queue entries that no longer exist.
        var q_write: usize = 0;
        for (model.queue[0..model.queue_len]) |id| {
            if (model.userTrackById(id) == null) continue;
            model.queue[q_write] = id;
            q_write += 1;
        }
        model.queue_len = q_write;
        if (now_id != 0 and model.userTrackById(now_id) != null) {
            model.session_resume_track = now_id;
            model.session_resume_elapsed_ms = elapsed;
            model.session_resume_playing = playing;
        }
        return true;
    }

    pub fn restoreLibrary(model: *Model, bytes: []const u8) bool {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        const header = lines.next() orelse return false;
        const header_trim = std.mem.trim(u8, header, " \r");
        const version: u8 = if (std.mem.eql(u8, header_trim, library_store_header))
            3
        else if (std.mem.eql(u8, header_trim, library_store_header_v2))
            2
        else if (std.mem.eql(u8, header_trim, library_store_header_v1))
            1
        else
            return false;
        model.user_album_count = 0;
        model.user_track_count = 0;
        model.next_user_album_id = first_user_album_id + 1;
        model.next_user_track_id = first_user_track_id;
        var legacy_cover: ?[]const u8 = null;
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \r");
            if (line.len == 0) continue;
            var parts = std.mem.splitScalar(u8, line, '\t');
            const kind = parts.next() orelse return false;
            if (std.mem.eql(u8, kind, "cover")) {
                // v1/v2 Library cover line.
                const path = parts.next() orelse return false;
                if (parts.next() != null) return false;
                if (path.len == 0 or path.len > max_user_path) return false;
                legacy_cover = path;
                continue;
            }
            if (std.mem.eql(u8, kind, "album")) {
                if (version < 3) return false;
                const id_text = parts.next() orelse return false;
                const title = parts.next() orelse return false;
                const artist = parts.next() orelse return false;
                const year_text = parts.next() orelse return false;
                const cover_path = parts.next() orelse return false;
                if (parts.next() != null) return false;
                if (model.user_album_count >= max_user_albums) return false;
                const id = std.fmt.parseInt(u8, id_text, 10) catch return false;
                const year = std.fmt.parseInt(u16, year_text, 10) catch return false;
                if (id < first_user_album_id or title.len > max_user_title or artist.len > max_user_title) return false;
                if (cover_path.len > max_user_path) return false;
                var album: UserAlbum = .{};
                album.id = id;
                album.year = year;
                album.setTitle(title);
                album.setArtist(artist);
                if (cover_path.len > 0) album.setCoverPath(cover_path);
                model.user_albums[model.user_album_count] = album;
                model.user_album_count += 1;
                if (id >= model.next_user_album_id) model.next_user_album_id = id +% 1;
                continue;
            }
            if (!std.mem.eql(u8, kind, "track")) return false;
            const id_text = parts.next() orelse return false;
            const album_text: []const u8 = if (version >= 3) blk: {
                break :blk parts.next() orelse return false;
            } else "";
            const number_text = parts.next() orelse return false;
            const title = parts.next() orelse return false;
            const artist: []const u8 = if (version >= 2) blk: {
                break :blk parts.next() orelse return false;
            } else "";
            const path = parts.next() orelse return false;
            const duration_text = parts.next() orelse return false;
            if (parts.next() != null) return false;
            if (model.user_track_count >= max_user_tracks) return false;
            const id = std.fmt.parseInt(u8, id_text, 10) catch return false;
            const number = std.fmt.parseInt(u8, number_text, 10) catch return false;
            const duration_ms = std.fmt.parseInt(u32, duration_text, 10) catch return false;
            if (id < first_user_track_id or path.len == 0 or path.len > max_user_path) return false;
            if (title.len > max_user_title or artist.len > max_user_title) return false;
            const album_id: u8 = if (version >= 3)
                (std.fmt.parseInt(u8, album_text, 10) catch return false)
            else
                imported_album_id;
            if (version < 3) {
                if (!model.ensureLibraryAlbum()) return false;
            } else if (model.userAlbumById(album_id) == null) {
                return false;
            }
            var track: UserTrack = .{};
            track.id = id;
            track.album = album_id;
            track.number = number;
            track.duration_ms = duration_ms;
            track.setTitle(title);
            track.setArtist(artist);
            track.setPath(path);
            model.user_tracks[model.user_track_count] = track;
            model.user_track_count += 1;
            if (id >= model.next_user_track_id) model.next_user_track_id = id +% 1;
        }
        if (version < 3) {
            if (!model.ensureLibraryAlbum() and model.user_track_count > 0) return false;
            if (legacy_cover) |path| {
                if (model.userAlbumByIdMut(imported_album_id)) |album| {
                    album.setCoverPath(path);
                }
            }
        }
        return true;
    }

    pub fn beginEditTrack(model: *Model, id: u8) bool {
        const track = model.userTrackById(id) orelse return false;
        model.cancelEditAlbum();
        model.editing_track = id;
        model.edit_title_buffer.set(track.title());
        model.edit_artist_buffer.set(track.artist());
        return true;
    }

    pub fn applyEditTrack(model: *Model) bool {
        const id = model.editing_track orelse return false;
        const track = model.userTrackByIdMut(id) orelse return false;
        const title = std.mem.trim(u8, model.edit_title_buffer.text(), " \t");
        if (title.len == 0) return false;
        track.setTitle(title);
        track.setArtist(std.mem.trim(u8, model.edit_artist_buffer.text(), " \t"));
        model.cancelEditTrack();
        return true;
    }

    pub fn cancelEditTrack(model: *Model) void {
        model.editing_track = null;
        model.edit_title_buffer.clear();
        model.edit_artist_buffer.clear();
    }

    pub fn beginEditAlbum(model: *Model, id: u8) bool {
        const album = model.userAlbumById(id) orelse return false;
        model.cancelEditTrack();
        model.editing_album = id;
        model.edit_title_buffer.set(album.title());
        model.edit_artist_buffer.set(album.artist());
        return true;
    }

    pub fn applyEditAlbum(model: *Model) bool {
        const id = model.editing_album orelse return false;
        const album = model.userAlbumByIdMut(id) orelse return false;
        const title = std.mem.trim(u8, model.edit_title_buffer.text(), " \t");
        if (title.len == 0) return false;
        album.setTitle(title);
        album.setArtist(std.mem.trim(u8, model.edit_artist_buffer.text(), " \t"));
        model.cancelEditAlbum();
        return true;
    }

    pub fn cancelEditAlbum(model: *Model) void {
        model.editing_album = null;
        model.edit_title_buffer.clear();
        model.edit_artist_buffer.clear();
    }
};

pub const AlbumCell = struct {
    id: u8,
    title: []const u8,
    artist: []const u8,
    initials: []const u8,
    cover: canvas.ImageId,
};

pub const TrackRow = struct {
    id: u8,
    number: []const u8,
    title: []const u8,
    subtitle: []const u8,
    duration: []const u8,
    /// This track is loaded in the now-playing bar (playing or paused).
    now: bool,
    playing: bool,
    /// This track is the SELECTION (accent row) — see `Model.selected`.
    selected: bool,
    /// User-imported tracks can be removed from the library.
    removable: bool,
};

fn formatMs(arena: std.mem.Allocator, ms: u32) []const u8 {
    const total_seconds = ms / 1000;
    return std.fmt.allocPrint(arena, "{d}:{d:0>2}", .{ total_seconds / 60, total_seconds % 60 }) catch "";
}

fn appendFmt(buffer: []u8, len: *usize, comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(buffer[len.*..], fmt, args) catch return;
    len.* += written.len;
}

/// Basename without extension — "Song Title.mp3" → "Song Title".
fn titleFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
        if (dot > 0) return base[0..dot];
    }
    return base;
}

fn isAudioExtension(ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, "mp3") or
        std.ascii.eqlIgnoreCase(ext, "m4a") or
        std.ascii.eqlIgnoreCase(ext, "wav") or
        std.ascii.eqlIgnoreCase(ext, "aac") or
        std.ascii.eqlIgnoreCase(ext, "flac") or
        std.ascii.eqlIgnoreCase(ext, "ogg");
}

fn isCoverFileName(name: []const u8) bool {
    const cover_names = [_][]const u8{
        "cover.jpg",  "cover.jpeg", "cover.png",  "cover.webp",
        "folder.jpg", "folder.jpeg", "folder.png", "folder.webp",
        "front.jpg",  "front.jpeg", "front.png",  "albumart.jpg",
        "albumart.jpeg", "albumart.png",
    };
    for (cover_names) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

fn albumArtistFromDir(dir_path: []const u8) []const u8 {
    const parent = std.fs.path.dirname(dir_path) orelse return "My Music";
    const name = std.fs.path.basename(parent);
    if (name.len == 0) return "My Music";
    // Drive roots / volume names are not useful album artists.
    if (std.mem.eql(u8, name, "/") or std.mem.eql(u8, name, "Volumes") or
        std.mem.eql(u8, name, "Users") or std.mem.eql(u8, name, "Music") or
        std.mem.eql(u8, name, "home"))
        return "My Music";
    return name;
}

fn lessIgnoreCase(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[i]);
        if (ca < cb) return true;
        if (ca > cb) return false;
    }
    return a.len < b.len;
}

pub fn persistLibrary(model: *Model, fx: *Effects) void {
    if (model.store_path_len == 0) return;
    if (model.store_write_inflight) {
        model.save_pending = true;
        return;
    }
    var buffer: [max_library_store_bytes]u8 = undefined;
    fx.writeFile(.{
        .key = library_write_key,
        .path = model.storePath(),
        .bytes = model.serializeLibrary(&buffer),
        .on_result = Effects.fileMsg(.library_done),
    });
    model.store_write_inflight = true;
}

/// Sync-read `library.txt` into the model before the first frame so the
/// album grid never flashes the empty state while an async restore races.
/// Missing file = honest empty library; oversize/corrupt is ignored.
pub fn loadLibrarySync(model: *Model) void {
    const path = model.storePath();
    if (path.len == 0) return;
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var file = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{}) catch return
    else
        std.Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer file.close(io);
    const size = (file.stat(io) catch return).size;
    if (size == 0) return;
    if (size > max_library_store_bytes) return;
    var buffer: [max_library_store_bytes]u8 = undefined;
    const len: usize = @intCast(size);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const n = reader.interface.readSliceShort(buffer[0..len]) catch return;
    if (n != len) return;
    _ = model.restoreLibrary(buffer[0..len]);
}

/// Kick session restore from `init_fx`. Covers / migrate / title heal wait
/// for the first presented frame (`library_hydrate`) so they cannot stall
/// the initial album-grid paint.
pub fn bootSession(model: *Model, fx: *Effects) void {
    requestSessionLoad(model, fx);
}

/// Post-first-frame library work: migrate external media and heal titles
/// from on-disk tags. Cover decode is staggered via `armCoverHydrate` so
/// the first present stays cheap. Safe with an empty library.
pub fn hydrateLibrary(model: *Model, fx: *Effects) void {
    var changed = migrateExternalMedia(model);
    if (model.refreshTitlesFromMedia()) changed = true;
    if (changed) persistLibrary(model, fx);
    armCoverHydrate(model);
    // Session-restored now-playing cover should appear with the transport
    // on the first trickle, not after every other album.
    if (model.nowTrack()) |track| {
        requestCoverLoad(model, fx, track.album);
    }
}

/// Queue a one-cover-per-present walk of albums that still have a path
/// but no registered image (or need a refresh after import).
pub fn armCoverHydrate(model: *Model) void {
    model.cover_hydrate_index = 0;
    model.cover_hydrate_pending = model.user_album_count > 0;
}

/// Decode the next album cover; clears the pending flag when done.
fn hydrateNextCover(model: *Model, fx: *Effects) void {
    while (model.cover_hydrate_index < model.user_album_count) {
        const album = &model.user_albums[model.cover_hydrate_index];
        model.cover_hydrate_index += 1;
        if (album.cover_path_len == 0) continue;
        if (album.cover != 0) continue;
        requestCoverLoad(model, fx, album.id);
        if (model.cover_hydrate_index >= model.user_album_count) {
            model.cover_hydrate_pending = false;
        }
        return;
    }
    model.cover_hydrate_pending = false;
}

pub fn persistSession(model: *Model, fx: *Effects) void {
    if (model.session_path_len == 0) return;
    if (model.session_write_inflight) {
        model.session_save_pending = true;
        return;
    }
    var buffer: [max_session_store_bytes]u8 = undefined;
    fx.writeFile(.{
        .key = session_write_key,
        .path = model.sessionPath(),
        .bytes = model.serializeSession(&buffer),
        .on_result = Effects.fileMsg(.session_done),
    });
    model.session_write_inflight = true;
}

fn requestSessionLoad(model: *Model, fx: *Effects) void {
    if (model.session_path_len == 0) return;
    fx.readFile(.{
        .key = session_read_key,
        .path = model.sessionPath(),
        .on_result = Effects.fileMsg(.session_done),
    });
}

fn playModeName(mode: PlayMode) []const u8 {
    return switch (mode) {
        .list_loop => "list_loop",
        .sequential => "sequential",
    };
}

fn parsePlayMode(name: []const u8) ?PlayMode {
    if (std.mem.eql(u8, name, "list_loop")) return .list_loop;
    // Older sessions used both modes; preserve their safe wrapping
    // behavior after the two-mode transport migration.
    if (std.mem.eql(u8, name, "single_loop")) return .list_loop;
    if (std.mem.eql(u8, name, "shuffle")) return .list_loop;
    if (std.mem.eql(u8, name, "sequential")) return .sequential;
    return null;
}

fn themePreferenceName(pref: ThemePreference) []const u8 {
    return switch (pref) {
        .system => "system",
        .light => "light",
        .dark => "dark",
    };
}

fn parseThemePreference(name: []const u8) ?ThemePreference {
    if (std.mem.eql(u8, name, "system")) return .system;
    if (std.mem.eql(u8, name, "light")) return .light;
    if (std.mem.eql(u8, name, "dark")) return .dark;
    return null;
}

fn isManagedMediaPath(model: *const Model, path: []const u8) bool {
    const root = model.mediaDir();
    if (root.len == 0 or path.len <= root.len) return false;
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path[root.len] == std.fs.path.sep;
}

fn deleteManagedMediaFile(model: *const Model, path: []const u8) void {
    if (!isManagedMediaPath(model, path)) return;
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    std.Io.Dir.deleteFileAbsolute(threaded.io(), path) catch {};
}

fn mediaDestPath(
    model: *const Model,
    prefix: u8,
    id: u8,
    source: []const u8,
    buffer: *[max_user_path]u8,
) ?[]const u8 {
    const root = model.mediaDir();
    if (root.len == 0) return null;
    const ext = std.fs.path.extension(source);
    return std.fmt.bufPrint(buffer, "{s}{c}{c}{d}{s}", .{
        root,
        std.fs.path.sep,
        prefix,
        id,
        ext,
    }) catch null;
}

fn copySourceToManagedPath(source: []const u8, dest: []const u8) bool {
    if (!std.fs.path.isAbsolute(source) or !std.fs.path.isAbsolute(dest)) return false;
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.copyFileAbsolute(source, dest, io, .{ .make_path = true, .replace = true }) catch return false;
    return true;
}

/// Copy `source` into the app media directory and register it. When no
/// media dir is configured (unit tests), stores the source path as-is.
pub fn importAudioFromSource(model: *Model, album_id: u8, source: []const u8) bool {
    if (model.mediaDir().len == 0) return model.addUserTrackToAlbum(album_id, source);
    if (source.len == 0 or source.len > max_user_path) return false;
    if (model.user_track_count >= max_user_tracks) return false;
    if (model.next_user_track_id == 0) return false;
    if (album_id == imported_album_id) {
        if (!model.ensureLibraryAlbum()) return false;
    } else if (model.userAlbumById(album_id) == null) {
        return false;
    }
    const id = model.next_user_track_id;
    var dest_buf: [max_user_path]u8 = undefined;
    const dest = mediaDestPath(model, 't', id, source, &dest_buf) orelse return false;
    if (model.pathAlreadyImported(dest)) return false;
    if (!copySourceToManagedPath(source, dest)) return false;
    // Title fallback must use the original source basename ("Song.mp3"),
    // never the managed copy ("t1.mp3").
    if (!model.addUserTrackToAlbumNamed(album_id, dest, source)) {
        deleteManagedMediaFile(model, dest);
        return false;
    }
    return true;
}

/// Copy a cover image into the media directory and attach it to the album.
/// Falls back to storing the source path when media dir is unset.
pub fn importCoverFromSource(model: *Model, album_id: u8, source: []const u8) bool {
    const album = model.userAlbumByIdMut(album_id) orelse return false;
    if (source.len == 0 or source.len > max_user_path) return false;
    if (model.mediaDir().len == 0) {
        album.setCoverPath(source);
        return true;
    }
    var dest_buf: [max_user_path]u8 = undefined;
    const dest = mediaDestPath(model, 'c', album_id, source, &dest_buf) orelse return false;
    var old_buf: [max_user_path]u8 = undefined;
    const old = album.coverPath();
    const old_len = old.len;
    if (old_len > 0) @memcpy(old_buf[0..old_len], old);
    if (!copySourceToManagedPath(source, dest)) return false;
    album.setCoverPath(dest);
    if (old_len > 0 and !std.mem.eql(u8, old_buf[0..old_len], dest)) {
        deleteManagedMediaFile(model, old_buf[0..old_len]);
    }
    return true;
}

/// Copy any still-external library paths into `media/` so older installs
/// survive source-file moves. Returns true when the library changed.
pub fn migrateExternalMedia(model: *Model) bool {
    if (model.mediaDir().len == 0) return false;
    var changed = false;
    for (model.user_tracks[0..model.user_track_count]) |*track| {
        const source = track.path();
        if (isManagedMediaPath(model, source)) continue;
        if (!localAudioReadable(source)) continue;
        var dest_buf: [max_user_path]u8 = undefined;
        const dest = mediaDestPath(model, 't', track.id, source, &dest_buf) orelse continue;
        if (!copySourceToManagedPath(source, dest)) continue;
        track.setPath(dest);
        changed = true;
    }
    for (model.user_albums[0..model.user_album_count]) |*album| {
        const source = album.coverPath();
        if (source.len == 0 or isManagedMediaPath(model, source)) continue;
        if (!localAudioReadable(source)) continue;
        var dest_buf: [max_user_path]u8 = undefined;
        const dest = mediaDestPath(model, 'c', album.id, source, &dest_buf) orelse continue;
        if (!copySourceToManagedPath(source, dest)) continue;
        album.setCoverPath(dest);
        changed = true;
    }
    return changed;
}

fn pickAndImportMusic(model: *Model, fx: *Effects) void {
    const services = fx.services orelse return;
    var buffer: [native_sdk.platform.max_dialog_paths_bytes]u8 = undefined;
    const result = services.showOpenDialog(.{
        .title = "Add Music",
        .filters = &.{
            .{ .name = "Audio", .extensions = &.{ "mp3", "m4a", "wav", "aac", "flac", "ogg" } },
            .{ .name = "All files", .extensions = &.{ "*" } },
        },
        .allow_multiple = true,
    }, &buffer) catch return;
    if (result.count == 0) return;
    var added: u32 = 0;
    var paths = std.mem.splitScalar(u8, result.paths, '\n');
    while (paths.next()) |path| {
        const trimmed = std.mem.trim(u8, path, " \r");
        if (trimmed.len == 0) continue;
        if (model.user_track_count >= max_user_tracks) break;
        if (importAudioFromSource(model, imported_album_id, trimmed)) added += 1;
    }
    if (added > 0) persistLibrary(model, fx);
}

fn pickAndImportAlbum(model: *Model, fx: *Effects) void {
    const services = fx.services orelse return;
    var buffer: [native_sdk.platform.max_dialog_paths_bytes]u8 = undefined;
    const result = services.showOpenDialog(.{
        .title = "Import Album",
        .allow_directories = true,
        .allow_multiple = false,
    }, &buffer) catch return;
    if (result.count == 0) return;
    var paths = std.mem.splitScalar(u8, result.paths, '\n');
    const dir_path = while (paths.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \r");
        if (trimmed.len > 0) break trimmed;
    } else return;
    if (dir_path.len > max_user_path) return;

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var audio_paths: [max_user_tracks][max_user_path]u8 = undefined;
    var audio_lens: [max_user_tracks]usize = undefined;
    var audio_count: usize = 0;
    var cover_path_buf: [max_user_path]u8 = undefined;
    var cover_path_len: usize = 0;

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (isCoverFileName(entry.name) and cover_path_len == 0) {
            var joined_buf: [max_user_path]u8 = undefined;
            const joined = std.fmt.bufPrint(&joined_buf, "{s}{c}{s}", .{ dir_path, std.fs.path.sep, entry.name }) catch continue;
            @memcpy(cover_path_buf[0..joined.len], joined);
            cover_path_len = joined.len;
            continue;
        }
        const ext = std.fs.path.extension(entry.name);
        const ext_body = if (ext.len > 0 and ext[0] == '.') ext[1..] else ext;
        if (!isAudioExtension(ext_body)) continue;
        if (audio_count >= max_user_tracks) break;
        var joined_buf: [max_user_path]u8 = undefined;
        const joined = std.fmt.bufPrint(&joined_buf, "{s}{c}{s}", .{ dir_path, std.fs.path.sep, entry.name }) catch continue;
        @memcpy(audio_paths[audio_count][0..joined.len], joined);
        audio_lens[audio_count] = joined.len;
        audio_count += 1;
    }

    if (audio_count == 0) return;

    // Sort by basename so track numbers follow filename order.
    var order: [max_user_tracks]usize = undefined;
    for (0..audio_count) |i| order[i] = i;
    var a: usize = 0;
    while (a + 1 < audio_count) : (a += 1) {
        var b = a + 1;
        while (b < audio_count) : (b += 1) {
            const path_a = audio_paths[order[a]][0..audio_lens[order[a]]];
            const path_b = audio_paths[order[b]][0..audio_lens[order[b]]];
            if (lessIgnoreCase(std.fs.path.basename(path_b), std.fs.path.basename(path_a))) {
                const tmp = order[a];
                order[a] = order[b];
                order[b] = tmp;
            }
        }
    }

    const title = std.fs.path.basename(dir_path);
    const artist = albumArtistFromDir(dir_path);
    const album_id = model.addUserAlbum(title, artist) orelse return;

    var added: u32 = 0;
    for (order[0..audio_count]) |idx| {
        if (model.user_track_count >= max_user_tracks) break;
        const path = audio_paths[idx][0..audio_lens[idx]];
        if (importAudioFromSource(model, album_id, path)) added += 1;
    }

    if (added == 0) {
        model.removeUserAlbum(album_id);
        return;
    }

    if (cover_path_len > 0) {
        if (importCoverFromSource(model, album_id, cover_path_buf[0..cover_path_len])) {
            requestCoverLoad(model, fx, album_id);
        }
    }

    model.open_album = album_id;
    model.detail_scroll = 0;
    persistLibrary(model, fx);
}

fn pickAndSetCover(model: *Model, fx: *Effects, album_id: u8) void {
    if (model.userAlbumById(album_id) == null) return;
    const services = fx.services orelse return;
    var buffer: [native_sdk.platform.max_dialog_paths_bytes]u8 = undefined;
    const result = services.showOpenDialog(.{
        .title = "Choose Cover",
        .filters = &.{
            .{ .name = "Images", .extensions = &.{ "png", "jpg", "jpeg", "webp", "gif" } },
            .{ .name = "All files", .extensions = &.{ "*" } },
        },
        .allow_multiple = false,
    }, &buffer) catch return;
    if (result.count == 0) return;
    var paths = std.mem.splitScalar(u8, result.paths, '\n');
    const path = while (paths.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \r");
        if (trimmed.len > 0) break trimmed;
    } else return;
    if (path.len > max_user_path) return;
    if (!importCoverFromSource(model, album_id, path)) return;
    persistLibrary(model, fx);
    _ = loadCoverFromPath(model, fx, album_id);
}

fn requestCoverLoad(model: *Model, fx: *Effects, album_id: u8) void {
    _ = loadCoverFromPath(model, fx, album_id);
}

/// True when any catalog string needs a CJK-capable face. Used at boot
/// to skip the ~7 MiB system face for Latin-only libraries. Late imports
/// cannot register a font after the installing frame — relaunch picks
/// them up.
pub fn libraryNeedsCjkFont(model: *const Model) bool {
    for (model.user_albums[0..model.user_album_count]) |*album| {
        if (textHasCjk(album.title())) return true;
        if (textHasCjk(album.artist())) return true;
    }
    for (model.user_tracks[0..model.user_track_count]) |*track| {
        if (textHasCjk(track.title())) return true;
        if (textHasCjk(track.artist())) return true;
    }
    return false;
}

fn textHasCjk(bytes: []const u8) bool {
    var i: usize = 0;
    while (i < bytes.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            i += 1;
            continue;
        };
        if (i + seq_len > bytes.len) break;
        const cp = std.unicode.utf8Decode(bytes[i..][0..seq_len]) catch {
            i += 1;
            continue;
        };
        if (codepointNeedsCjkFont(cp)) return true;
        i += seq_len;
    }
    return false;
}

fn codepointNeedsCjkFont(cp: u21) bool {
    return (cp >= 0x3040 and cp <= 0x30FF) // Hiragana + Katakana
    or (cp >= 0x3400 and cp <= 0x4DBF) // CJK Extension A
    or (cp >= 0x4E00 and cp <= 0x9FFF) // CJK Unified
    or (cp >= 0xAC00 and cp <= 0xD7AF) // Hangul syllables
    or (cp >= 0xF900 and cp <= 0xFAFF); // CJK Compatibility Ideographs
}

/// Push Control Center / Now Playing from model state. Content-throttled
/// inside `media_session`; safe to call on every poll tick.
fn syncNowPlaying(model: *const Model) void {
    if (model.nowTrack()) |track| {
        const artist = if (track.artist.len > 0) track.artist else blk: {
            const album = model.userAlbumById(track.album);
            break :blk if (album) |a| a.artist() else "";
        };
        media_session.publish(track.title, artist, model.now_duration_ms, model.elapsed_ms, model.playing);
    } else {
        media_session.clear();
    }
}

/// Process-lifetime RGBA decode scratch shared across sequential cover
/// loads so boot-time hydration does not alloc/free ~64 MiB per album.
var cover_decode_scratch: []u8 = &.{};

fn coverDecodeScratch(bytes: usize) ?[]u8 {
    if (cover_decode_scratch.len >= bytes) return cover_decode_scratch[0..bytes];
    if (cover_decode_scratch.len > 0) std.heap.page_allocator.free(cover_decode_scratch);
    cover_decode_scratch = std.heap.page_allocator.alloc(u8, bytes) catch {
        cover_decode_scratch = &.{};
        return null;
    };
    return cover_decode_scratch;
}

fn applySessionResume(model: *Model, fx: *Effects) void {
    fx.setAudioVolume(model.volume);
    const id = model.session_resume_track orelse return;
    const elapsed = model.session_resume_elapsed_ms;
    // Always resume paused: launching the app must not auto-play, even
    // when the previous run quit mid-playback (`playing` in the store).
    model.session_resume_track = null;
    model.session_resume_playing = false;

    const track = model.resolveTrack(id) orelse return;
    model.now = id;
    model.selected = id;
    model.elapsed_ms = elapsed;
    model.now_duration_ms = track.duration_ms;
    model.platform_duration_ms = 0;
    model.assets_missing = false;
    model.playing = false;
    // Defer playAudio/seek until the user presses play — cold launch
    // should not decode the last track just to show the transport.
    model.audio_deferred = true;
    requestCoverLoad(model, fx, track.album);
    syncNowPlaying(model);
    syncAudioPollTimer(model, fx);
}

/// Load the deferred session track into the platform player (seek + play
/// or pause). No-op when playback already engaged the engine.
fn engageDeferredAudio(model: *Model, fx: *Effects, play: bool) void {
    if (!model.audio_deferred) return;
    const id = model.now orelse {
        model.audio_deferred = false;
        return;
    };
    const track = model.resolveTrack(id) orelse {
        model.audio_deferred = false;
        return;
    };
    const elapsed = model.elapsed_ms;
    model.audio_deferred = false;
    if (fx.executor != .fake and !localAudioReadable(track.path)) {
        model.assets_missing = true;
        model.now = null;
        model.playing = false;
        model.elapsed_ms = 0;
        model.now_duration_ms = 0;
        model.platform_duration_ms = 0;
        persistSession(model, fx);
        return;
    }
    fx.playAudio(.{
        .key = id,
        .path = track.path,
    });
    fx.setAudioVolume(model.volume);
    if (elapsed > 0) fx.seekAudio(elapsed);
    model.playing = play;
    if (play) {
        fx.resumeAudio();
    } else {
        fx.pauseAudio();
    }
    syncAudioPollTimer(model, fx);
    syncNowPlaying(model);
    persistSession(model, fx);
}

/// Read the album's cover file, decode via the platform codec, downscale
/// to the canvas image slot budget, and register pixels under `album_id`.
/// Returns false when the file cannot be turned into a registered image.
pub fn loadCoverFromPath(model: *Model, fx: *Effects, album_id: u8) bool {
    const album = model.userAlbumByIdMut(album_id) orelse return false;
    if (album.cover_path_len == 0) {
        album.cover = 0;
        _ = fx.unregisterImage(album_id);
        return true;
    }
    const encoded = readCoverFileBytes(album.coverPath()) orelse {
        album.cover = 0;
        return false;
    };
    defer std.heap.page_allocator.free(encoded);
    return registerCoverEncoded(model, fx, album_id, encoded);
}

fn readCoverFileBytes(path: []const u8) ?[]u8 {
    if (path.len == 0) return null;
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var file = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null
    else
        std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const size = (file.stat(io) catch return null).size;
    if (size == 0 or size > max_cover_file_bytes) return null;
    const len: usize = @intCast(size);
    const buf = std.heap.page_allocator.alloc(u8, len) catch return null;
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const n = reader.interface.readSliceShort(buf) catch {
        std.heap.page_allocator.free(buf);
        return null;
    };
    if (n != buf.len) {
        std.heap.page_allocator.free(buf);
        return null;
    }
    return buf;
}

fn fitCoverSize(src_w: usize, src_h: usize) struct { w: usize, h: usize } {
    const max = max_cover_register_edge;
    if (src_w == 0 or src_h == 0) return .{ .w = 0, .h = 0 };
    if (src_w <= max and src_h <= max) return .{ .w = src_w, .h = src_h };
    if (src_w >= src_h) {
        return .{
            .w = max,
            .h = @max(1, (src_h * max) / src_w),
        };
    }
    return .{
        .w = @max(1, (src_w * max) / src_h),
        .h = max,
    };
}

fn downscaleRgba(
    src: []const u8,
    src_w: usize,
    src_h: usize,
    dst: []u8,
    dst_w: usize,
    dst_h: usize,
) void {
    var y: usize = 0;
    while (y < dst_h) : (y += 1) {
        const sy = y * src_h / dst_h;
        var x: usize = 0;
        while (x < dst_w) : (x += 1) {
            const sx = x * src_w / dst_w;
            const si = (sy * src_w + sx) * 4;
            const di = (y * dst_w + x) * 4;
            dst[di..][0..4].* = src[si..][0..4].*;
        }
    }
}

fn registerCoverEncoded(model: *Model, fx: *Effects, album_id: u8, encoded: []const u8) bool {
    const album = model.userAlbumByIdMut(album_id) orelse return false;
    if (encoded.len == 0) {
        album.cover = 0;
        return false;
    }

    if (fx.services) |services| {
        const decode_bytes = max_cover_decode_edge * max_cover_decode_edge * 4;
        const decode_buf = coverDecodeScratch(decode_bytes) orelse {
            album.cover = 0;
            return false;
        };

        const decoded = services.decodeImage(encoded, decode_buf) catch {
            album.cover = 0;
            return false;
        };
        if (decoded.width == 0 or decoded.height == 0) {
            album.cover = 0;
            return false;
        }
        if (decoded.width > max_cover_decode_edge or decoded.height > max_cover_decode_edge) {
            album.cover = 0;
            return false;
        }

        const fitted = fitCoverSize(decoded.width, decoded.height);
        var scaled_storage: [max_cover_register_edge * max_cover_register_edge * 4]u8 = undefined;
        const rgba: []const u8 = if (fitted.w == decoded.width and fitted.h == decoded.height)
            decoded.rgba8
        else blk: {
            const need = fitted.w * fitted.h * 4;
            downscaleRgba(decoded.rgba8, decoded.width, decoded.height, scaled_storage[0..need], fitted.w, fitted.h);
            break :blk scaled_storage[0..need];
        };

        fx.registerImage(album_id, fitted.w, fitted.h, rgba) catch {
            album.cover = 0;
            return false;
        };
        album.cover = album_id;
        return true;
    }

    // Codec-less / unbound hosts: only images that already fit the SDK
    // registerImageBytes scratch can succeed.
    _ = fx.registerImageBytes(album_id, encoded) catch {
        album.cover = 0;
        return false;
    };
    album.cover = album_id;
    return true;
}

fn applyCoverBytes(model: *Model, fx: *Effects, album_id: u8, bytes: []const u8) bool {
    return registerCoverEncoded(model, fx, album_id, bytes);
}

fn closeHeaderMenus(model: *Model) void {
    model.header_menu_open = false;
    model.add_menu_open = false;
}

// ------------------------------------------------------------------ update

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    defer syncAudioPollTimer(model, fx);
    switch (msg) {
        .toggle_theme => {
            // Lock to the opposite of whatever is showing now (system-
            // follow included): first press leaves the OS and every
            // later press flips light ↔ dark.
            model.theme = switch (model.colorScheme()) {
                .light => .dark,
                .dark => .light,
            };
            closeHeaderMenus(model);
            persistSession(model, fx);
        },
        .toggle_header_menu => {
            model.header_menu_open = !model.header_menu_open;
            if (model.header_menu_open) model.add_menu_open = false;
        },
        .close_header_menu => model.header_menu_open = false,
        .toggle_add_menu => {
            model.add_menu_open = !model.add_menu_open;
            if (model.add_menu_open) model.header_menu_open = false;
        },
        .close_add_menu => model.add_menu_open = false,
        .set_appearance => |appearance| model.appearance = appearance,
        .chrome_changed => |chrome| {
            // Pad whichever edge the platform puts its window controls
            // on (macOS: traffic lights leading; Windows: min/max/close
            // trailing) — the unused edge arrives as an honest zero.
            model.chrome_leading = chrome.insets.left;
            model.chrome_trailing = chrome.insets.right;
            // Match the header to the titlebar band so cross-centered
            // controls sit on the band midline; the natural height is
            // the floor when no band overlays the content. Prefer the
            // live inset when the host reports one — never grow taller
            // than the OS band, or the painted chrome outruns the
            // titlebar and the controls read as top-heavy.
            model.header_height = if (chrome.insets.top > 0)
                chrome.insets.top
            else
                header_natural_height;
        },
        .canvas_resized => |width| model.canvas_width = width,
        .grid_scrolled => |state| model.grid_scroll = state.offset,
        .detail_scrolled => |state| model.detail_scroll = state.offset,
        .open_album => |id| {
            model.open_album = id;
            // A fresh record opens at its top.
            model.detail_scroll = 0;
            // Detail cover should not wait on the staggered hydrate walk.
            requestCoverLoad(model, fx, id);
        },
        .close_album => model.open_album = null,
        .play_album => |id| {
            const first = model.firstTrackIdInAlbum(id) orelse return;
            // Replace the playlist with the whole album so list_loop /
            // sequential walk that list instead of consuming a
            // one-shot "up next" FIFO. Leave the panel closed — Play Album
            // starts playback; the user opens the queue when they want it.
            model.queue_len = 0;
            model.queue_dropped = 0;
            const count = model.tracksInAlbum(id);
            var number: u8 = 1;
            while (number <= count) : (number += 1) {
                const track = model.userTrackInAlbumByNumber(id, number) orelse continue;
                model.pushQueue(track.id);
            }
            startTrack(model, fx, first);
        },
        .play_track => |id| playOrToggle(model, fx, id),
        .select_track => |id| model.selected = id,
        .select_next => moveSelection(model, .next),
        .select_previous => moveSelection(model, .previous),
        .play_selected => {
            if (model.selected) |id| playOrToggle(model, fx, id);
        },
        .frame_clock => |frame| advanceRenderedClock(model, frame),
        .audio_poll => |timer| {
            if (timer.outcome != .fired) return;
            pollAudioChannel(model, fx);
        },
        .toggle_play => {
            if (model.now == null) {
                if (model.user_track_count > 0) {
                    startTrack(model, fx, model.user_tracks[0].id);
                }
            } else {
                setPlaying(model, fx, !model.playing);
            }
        },
        .next_track => skipForward(model, fx, false),
        .prev_track => previous(model, fx),
        .cycle_play_mode => {
            model.play_mode = switch (model.play_mode) {
                .list_loop => .sequential,
                .sequential => .list_loop,
            };
            persistSession(model, fx);
        },
        .volume_changed => |value| {
            model.volume = std.math.clamp(value, 0, 1);
            fx.setAudioVolume(model.volume);
            persistSession(model, fx);
        },
        .toggle_queue => model.queue_open = !model.queue_open,
        .clear_queue => {
            model.queue_len = 0;
            model.queue_open = false;
            persistSession(model, fx);
        },
        .remove_queued => |id| {
            var write: usize = 0;
            for (model.queue[0..model.queue_len]) |queued| {
                if (queued == id) continue;
                model.queue[write] = queued;
                write += 1;
            }
            model.queue_len = write;
            if (model.queue_len == 0) model.queue_open = false;
            persistSession(model, fx);
        },
        .media_command => |cmd| switch (cmd) {
            .toggle_play => update(model, .toggle_play, fx),
            .next => update(model, .next_track, fx),
            .previous => update(model, .prev_track, fx),
        },
        .audio_event => |event| handleAudioEvent(model, fx, event),
        .queue_track => |id| {
            model.pushQueue(id);
            model.queue_open = true;
            persistSession(model, fx);
        },
        .add_music => {
            closeHeaderMenus(model);
            pickAndImportMusic(model, fx);
        },
        .import_album => {
            closeHeaderMenus(model);
            pickAndImportAlbum(model, fx);
        },
        .remove_track => |id| {
            if (!isUserTrackId(id)) return;
            const was_playing = model.now == id;
            if (!model.removeUserTrack(id)) return;
            if (model.editing_track == id) model.cancelEditTrack();
            if (was_playing) {
                fx.stopAudio();
                // Publish moved out of animations — clear Control Center
                // when the loaded track disappears.
                syncNowPlaying(model);
                persistSession(model, fx);
            }
            persistLibrary(model, fx);
        },
        .edit_track => |id| {
            if (!isUserTrackId(id)) return;
            _ = model.beginEditTrack(id);
        },
        .edit_album => |id| {
            _ = model.beginEditAlbum(id);
        },
        .edit_title => |edit| model.edit_title_buffer.apply(edit),
        .edit_artist => |edit| model.edit_artist_buffer.apply(edit),
        .save_edit_track => {
            if (!model.applyEditTrack()) return;
            persistLibrary(model, fx);
        },
        .close_edit_track => model.cancelEditTrack(),
        .save_edit_album => {
            if (!model.applyEditAlbum()) return;
            persistLibrary(model, fx);
        },
        .close_edit_album => model.cancelEditAlbum(),
        .change_cover => |album_id| pickAndSetCover(model, fx, album_id),
        .library_hydrate => {
            if (!model.library_hydrate_pending) return;
            model.library_hydrate_pending = false;
            hydrateLibrary(model, fx);
        },
        .cover_hydrate => {
            if (!model.cover_hydrate_pending) return;
            hydrateNextCover(model, fx);
        },
        .library_done => |result| switch (result.op) {
            // Launch loads the library sync; async reads are unused.
            .read => {},
            .write => {
                model.store_write_inflight = false;
                if (result.outcome == .ok and model.save_pending) {
                    model.save_pending = false;
                    persistLibrary(model, fx);
                }
            },
        },
        .session_done => |result| switch (result.op) {
            .read => switch (result.outcome) {
                .ok => {
                    if (model.restoreSession(result.bytes)) {
                        applySessionResume(model, fx);
                    }
                },
                .not_found => {},
                else => {},
            },
            .write => {
                model.session_write_inflight = false;
                if (result.outcome == .ok and model.session_save_pending) {
                    model.session_save_pending = false;
                    persistSession(model, fx);
                }
            },
        },
        .cover_done => |result| {
            const album_id = albumIdFromCoverKey(result.key) orelse return;
            switch (result.outcome) {
                .ok => _ = applyCoverBytes(model, fx, album_id, result.bytes),
                else => if (model.userAlbumByIdMut(album_id)) |album| {
                    album.cover = 0;
                },
            }
        },
    }
}

/// Every playback report flows through here. The audio key is the track
/// id, so a straggler for a track the model no longer plays is dropped
/// by identity — never misattributed to the current one.
///
/// Events carry the platform player's own duration and position readout.
/// Imported tracks can begin without a known duration, so the first
/// platform report fills that value for the session and library record.
fn handleAudioEvent(model: *Model, fx: *Effects, event: native_sdk.EffectAudio) void {
    const now = model.now orelse return;
    if (event.key != now) return;
    switch (event.kind) {
        .loaded => {
            adoptPlatformDuration(model, fx, event.duration_ms);
            model.elapsed_ms = @intCast(event.position_ms);
            model.playing = event.playing;
        },
        .position => {
            const position: u32 = @intCast(event.position_ms);
            adoptPlatformDuration(model, fx, event.duration_ms);
            // The coarse tick CORRECTS any frame-advanced rendered
            // clock (journal path). In motion, forward corrections
            // apply and small backward ones hold flat — elapsed must
            // never visibly rewind because frames ran a few ms ahead
            // of the player — while a past-slack disagreement is a
            // real desync (an external seek) and snaps. When paused the
            // tick is simply the truth.
            if (model.playing) {
                if (position > model.elapsed_ms or model.elapsed_ms - position > position_snap_slack_ms) {
                    model.elapsed_ms = position;
                }
            } else {
                model.elapsed_ms = position;
            }
        },
        // Real band-magnitude reports from hosts that analyze their own
        // playback. WellMusic draws no analyzer — and live playback does
        // not register `on_event`, so these never reach update on device.
        // Kept as a no-op for journal / test feeds that still send them.
        .spectrum => {},
        .completed => onTrackCompleted(model, fx),
        .failed, .rejected => {
            // Playback could not run because the local file is unreadable
            // or the host cannot decode it. Persist so a later launch
            // does not keep auto-resuming a dead path.
            model.assets_missing = true;
            model.now = null;
            model.playing = false;
            model.elapsed_ms = 0;
            model.now_duration_ms = 0;
            model.platform_duration_ms = 0;
            syncNowPlaying(model);
            persistSession(model, fx);
        },
    }
}

/// Mirror the platform's duration report, and adopt it as the displayed
/// total ONLY when the manifest gave none (see the duration rule on
/// `handleAudioEvent`).
fn adoptPlatformDuration(model: *Model, fx: *Effects, reported_ms: u64) void {
    if (reported_ms == 0) return;
    const clamped: u32 = @intCast(@min(reported_ms, std.math.maxInt(u32)));
    model.platform_duration_ms = clamped;
    if (model.now_duration_ms == 0) {
        model.now_duration_ms = clamped;
        // Remember durations for user imports so the list stays honest
        // after the first play.
        if (model.now) |id| {
            if (model.userTrackByIdMut(id)) |track| {
                if (track.duration_ms == 0) {
                    track.duration_ms = clamped;
                    persistLibrary(model, fx);
                }
            }
        }
    }
}

/// The play gesture on a specific track (double click, Enter, context
/// paths): a different track starts fresh, the loaded one toggles
/// play/pause in place. Either way the track becomes the selection —
/// the playing row is the current row — and is appended to the playlist
/// when it is not already there (same append rule as Play Next, without
/// forcing the panel open).
fn playOrToggle(model: *Model, fx: *Effects, track_id: u8) void {
    model.selected = track_id;
    model.pushQueue(track_id);
    if (model.now == track_id) {
        setPlaying(model, fx, !model.playing);
    } else {
        startTrack(model, fx, track_id);
    }
}

const SelectionStep = enum { previous, next };

/// Whether a track sits in the album detail list currently on screen.
/// The album grid has no track list, so arrows move nothing there.
fn trackInCurrentList(model: *const Model, track: Track) bool {
    return if (model.open_album) |album_id| track.album == album_id else false;
}

/// Move the selection one row up or down the visible track list,
/// clamped at the ends (no wrap — arrows at an edge hold, they never
/// teleport). No selection yet (or one filtered out of view): down
/// enters at the top, up at the bottom. One pass over the flattened
/// track table, which IS view order for both list shapes.
fn moveSelection(model: *Model, step: SelectionStep) void {
    var first: ?u8 = null;
    var last: ?u8 = null;
    var before: ?u8 = null;
    var after: ?u8 = null;
    var seen_selected = false;
    const consider = struct {
        fn go(model_inner: *const Model, track: Track, first_id: *?u8, last_id: *?u8, before_id: *?u8, after_id: *?u8, seen: *bool) void {
            if (!trackInCurrentList(model_inner, track)) return;
            if (first_id.* == null) first_id.* = track.id;
            last_id.* = track.id;
            if (model_inner.selected == track.id) {
                seen.* = true;
            } else if (!seen.*) {
                before_id.* = track.id;
            } else if (after_id.* == null) {
                after_id.* = track.id;
            }
        }
    }.go;
    for (model.user_tracks[0..model.user_track_count]) |*user| {
        consider(model, user.asTrack(), &first, &last, &before, &after, &seen_selected);
    }
    const target: ?u8 = switch (step) {
        .next => if (seen_selected) (after orelse model.selected) else first,
        .previous => if (seen_selected) (before orelse model.selected) else last,
    };
    if (target) |id| model.selected = id;
}

/// Arm or disarm the ~2 s audio poll while actually playing.
/// Paused / idle stay quiet. Idempotent edge transitions only
/// (re-arming every update starves fires).
fn syncAudioPollTimer(model: *Model, fx: *Effects) void {
    const want = model.playing and model.now != null;
    if (want == model.audio_poll_armed) return;
    model.audio_poll_armed = want;
    if (want) {
        fx.startTimer(.{
            .key = audio_poll_timer_key,
            .interval_ms = audio_poll_interval_ms,
            .mode = .repeating,
            .on_fire = Effects.timerMsg(.audio_poll),
        });
    } else {
        fx.cancelTimer(audio_poll_timer_key);
    }
}

/// Mirror the platform player into the model without riding `on_event`
/// (which would also deliver ~25 Hz spectrum reports into TEA).
///
/// UiApp rebuilds on every Msg, and the view does not bind `elapsed_ms`,
/// so steady-state ticks are overhead. Keep mutations to completion /
/// failure / first duration adoption (those change visible UI); always
/// refresh Now Playing here (content-throttled) so Control Center does
/// not depend on a view rebuild.
fn pollAudioChannel(model: *Model, fx: *Effects) void {
    const now_id = model.now orelse {
        syncNowPlaying(model);
        return;
    };
    if (model.audio_deferred) return;
    const snap = fx.audioSnapshot();
    if (snap.active and snap.key != now_id) return;
    if (!snap.active) {
        // Player gone while we still hold this track — treat as failure
        // (decode miss, host without audio, stopped under us).
        model.assets_missing = true;
        model.now = null;
        model.playing = false;
        model.elapsed_ms = 0;
        model.now_duration_ms = 0;
        model.platform_duration_ms = 0;
        syncNowPlaying(model);
        persistSession(model, fx);
        return;
    }

    adoptPlatformDuration(model, fx, snap.duration_ms);
    const position: u32 = @intCast(@min(snap.position_ms, std.math.maxInt(u32)));

    // We still show playing but the transport stopped → natural end.
    // User pause sets `model.playing = false` before `pauseAudio`, so it
    // never takes this branch.
    if (model.playing and !snap.playing) {
        model.elapsed_ms = if (model.now_duration_ms > 0) model.now_duration_ms else position;
        syncNowPlaying(model);
        onTrackCompleted(model, fx);
        return;
    }

    // Position is session/Now Playing only — no view binding. Skip the
    // write when nothing moved so identical rebuilds stay cheap.
    if (model.playing) {
        if (position > model.elapsed_ms or model.elapsed_ms - position > position_snap_slack_ms) {
            model.elapsed_ms = position;
        }
    } else {
        model.elapsed_ms = position;
    }
    syncNowPlaying(model);
}

/// Journal/test path: advance the rendered clock by the real frame
/// delta, clamped to a few display intervals so a stale gap steps
/// gently, and capped at the duration. Motion-gated so a replayed
/// journal straddling a pause boundary stays exact.
fn advanceRenderedClock(model: *Model, frame: FrameClock) void {
    const last = model.frame_ns;
    model.frame_ns = frame.timestamp_ns;
    if (!model.playing or model.now == null) return;
    const interval: u64 = if (frame.interval_ns > 0) frame.interval_ns else std.time.ns_per_s / 60;
    const delta_ns: u64 = if (last == 0 or frame.timestamp_ns <= last)
        interval
    else
        @min(frame.timestamp_ns - last, interval * 4);
    const advanced = @as(u64, model.elapsed_ms) + delta_ns / std.time.ns_per_ms;
    const limit: u64 = if (model.now_duration_ms > 0) model.now_duration_ms else advanced;
    model.elapsed_ms = @intCast(@min(advanced, limit));
}

fn startTrack(model: *Model, fx: *Effects, track_id: u8) void {
    const track = model.resolveTrack(track_id) orelse return;
    model.now = track_id;
    // Starting a track selects it: the playing row is the current row
    // for the arrow keys and the inverted accent register alike.
    model.selected = track_id;
    // `elapsed_ms` restarts here and advances with position ticks /
    // journal `frame_clock` — session restore and Now Playing only.
    model.elapsed_ms = 0;
    // The manifest's measured duration is the total for the whole
    // playback — the same number the track lists render, so the two
    // surfaces agree by construction (the duration rule on
    // `handleAudioEvent`). The platform's estimate mirror restarts too.
    // User imports often start at 0 and adopt the platform report.
    model.now_duration_ms = track.duration_ms;
    model.platform_duration_ms = 0;
    // A fresh attempt clears the degraded notices; if the source is
    // still unplayable the `.failed` event raises the right one again.
    model.assets_missing = false;
    model.playing = true;
    model.audio_deferred = false;
    // Now-playing cover should not wait on the staggered hydrate walk.
    requestCoverLoad(model, fx, track.album);
    // Imported tracks are local paths. If a file was moved or deleted,
    // fail before asking the host — and
    // persist so session resume does not keep retrying a dead path.
    // Fake-executor tests seed placeholder paths; skip the open check
    // there so playback logic stays unit-testable without real files.
    if (fx.executor != .fake and !localAudioReadable(track.path)) {
        model.assets_missing = true;
        model.now = null;
        model.playing = false;
        model.elapsed_ms = 0;
        model.now_duration_ms = 0;
        model.platform_duration_ms = 0;
        syncNowPlaying(model);
        persistSession(model, fx);
        return;
    }
    // One player total: a new playAudio replaces whatever played before,
    // and the track id keys the audioSnapshot mirror. `on_event` is
    // intentionally omitted — the host pushes ~25 Hz `.spectrum` reports
    // that would otherwise rebuild the whole UI; `audio_poll` mirrors
    // position / completion / failure from the snapshot instead.
    fx.playAudio(.{
        .key = track_id,
        .path = track.path,
    });
    fx.setAudioVolume(model.volume);
    syncNowPlaying(model);
    persistSession(model, fx);
}

/// Whether an absolute (or cwd-relative) audio path can still be opened.
/// Used to catch moved/deleted imports before a host play attempt.
pub fn localAudioReadable(path: []const u8) bool {
    if (path.len == 0) return false;
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var file = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false
    else
        std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

/// Play/pause drive the platform player in place; the optimistic flag
/// keeps the transport responsive and the next audio event confirms it.
fn setPlaying(model: *Model, fx: *Effects, playing: bool) void {
    if (model.audio_deferred) {
        // Session-restored binding: first play engages the engine (+seek);
        // pause with no engine is already the restored state.
        if (playing) engageDeferredAudio(model, fx, true);
        return;
    }
    model.playing = playing;
    if (playing) {
        fx.resumeAudio();
    } else {
        fx.pauseAudio();
    }
    syncNowPlaying(model);
    persistSession(model, fx);
}

/// A track finished through the same path the next button uses.
fn onTrackCompleted(model: *Model, fx: *Effects) void {
    skipForward(model, fx, true);
}

/// Advance order: (1) walk the playlist when `now` is in it, (2) consume
/// a Play Next entry that is not yet part of a playlist cursor, (3) fall
/// back to album order. `from_completion` distinguishes auto-advance at
/// the end of sequential playback (stop) from a mid-track skip on the
/// last song (no-op).
fn skipForward(model: *Model, fx: *Effects, from_completion: bool) void {
    if (model.now) |now_id| {
        if (model.queueIndexOf(now_id)) |idx| {
            advanceWithinPlaylist(model, fx, idx, from_completion);
            return;
        }
    }
    if (model.popQueue()) |queued| {
        startTrack(model, fx, queued);
        return;
    }
    const track = model.nowTrack() orelse return;
    const count = model.tracksInAlbum(track.album);
    if (count == 0) return;

    switch (model.play_mode) {
        .list_loop => {
            const next_number: u8 = @intCast((@as(usize, track.number) % count) + 1);
            const next = model.userTrackInAlbumByNumber(track.album, next_number) orelse return;
            startTrack(model, fx, next.id);
        },
        .sequential => {
            if (track.number >= count) {
                if (from_completion) stopAtEnd(model);
                return;
            }
            const next = model.userTrackInAlbumByNumber(track.album, track.number + 1) orelse return;
            startTrack(model, fx, next.id);
        },
    }
}

fn advanceWithinPlaylist(model: *Model, fx: *Effects, idx: usize, from_completion: bool) void {
    const len = model.queue_len;
    if (len == 0) return;
    switch (model.play_mode) {
        .list_loop => {
            const next = (idx + 1) % len;
            startTrack(model, fx, model.queue[next]);
        },
        .sequential => {
            if (idx + 1 >= len) {
                if (from_completion) stopAtEnd(model);
                return;
            }
            startTrack(model, fx, model.queue[idx + 1]);
        },
    }
}

fn stopAtEnd(model: *Model) void {
    model.playing = false;
    if (model.now_duration_ms > 0) model.elapsed_ms = model.now_duration_ms;
    // Poll already published while `playing` was still true; republish
    // paused state so Control Center does not keep advancing.
    syncNowPlaying(model);
}

/// Restart the current track when it is a few seconds in; otherwise the
/// previous track in the playlist (or album). Sequential mode does not
/// wrap past the first track; list loop wraps.
fn previous(model: *Model, fx: *Effects) void {
    const track = model.nowTrack() orelse return;
    if (model.elapsed_ms > 3000) {
        model.elapsed_ms = 0;
        fx.seekAudio(0);
        syncNowPlaying(model);
        return;
    }
    if (model.queueIndexOf(track.id)) |idx| {
        if (model.play_mode == .sequential and idx == 0) {
            model.elapsed_ms = 0;
            fx.seekAudio(0);
            syncNowPlaying(model);
            return;
        }
        const len = model.queue_len;
        if (len == 0) return;
        const prev_idx = (idx + len - 1) % len;
        startTrack(model, fx, model.queue[prev_idx]);
        return;
    }
    const count = model.tracksInAlbum(track.album);
    if (count == 0) return;
    if (model.play_mode == .sequential and track.number <= 1) {
        model.elapsed_ms = 0;
        fx.seekAudio(0);
        syncNowPlaying(model);
        return;
    }
    const prev_number: u8 = @intCast((@as(usize, track.number) + count - 2) % count + 1);
    const prev = model.userTrackInAlbumByNumber(track.album, prev_number) orelse return;
    startTrack(model, fx, prev.id);
}
