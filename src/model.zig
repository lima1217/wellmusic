//! wellmusic model: a user-owned music library with playback, search,
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
//!   - 48-byte search buffer

const std = @import("std");
const native_sdk = @import("native_sdk");
const metadata = @import("metadata.zig");

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
    file: []const u8,
    duration_ms: u32,
    bytes: u64,
};

/// No committed sample albums or tracks — the library is user-owned.
pub const albums = [_]Album{};
pub const tracks = [_]Track{};

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
pub const library_read_key: u64 = 3;
pub const library_write_key: u64 = 4;
pub const session_read_key: u64 = 5;
pub const session_write_key: u64 = 6;
pub const session_store_header = "wellmusic-session v1";
pub const max_session_store_bytes = 4 * 1024;
/// Cover reads use `cover_read_key_base + album_id` so concurrent loads
/// stay attributable when several albums restore covers at once.
pub const cover_read_key_base: u64 = 100;
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

pub fn trackById(id: u8) *const Track {
    _ = id;
    @panic("wellmusic has no built-in tracks; use Model.resolveTrack");
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

    pub fn setYear(album: *UserAlbum, value: u16) void {
        album.year = value;
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
            .file = "",
            .duration_ms = track.duration_ms,
            .bytes = 0,
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
/// can show the whole record. Play Next appends into the same list.
pub const max_queue = max_user_tracks;
pub const max_search = 48;
/// The header bar's natural height, and the floor `header_height` falls
/// back to when no titlebar band overlays the content (fullscreen,
/// standard chrome, tests). Matches the tall hidden-inset band the
/// system reports through `on_chrome` — the band must not be taller
/// than the OS band, or the header's controls center below the traffic
/// lights the system centers within its own band.
pub const header_natural_height: f32 = 52;
/// The window's content min-width floor (main.zig declares it on the
/// shell window) and the default `canvas_width` before the first
/// presented frame reports the real surface size. Defaulting to the
/// FLOOR is deliberate: a tree built before any frame arrives (boot,
/// tree-level tests, the layout audit's smallest swept size) derives an
/// album grid that fits the narrowest window the shell allows — it can
/// underfill a wider surface for one frame, never overflow a narrow one.
pub const min_canvas_width: f32 = 1056;

/// The pre-first-frame `canvas_width` the MOBILE entry seeds instead
/// (main.zig's `initModel`): a mainstream phone-portrait width, so the
/// installing frame on a phone already composes the compact shell — the
/// full-screen mobile host has no window min-width to seed from, and
/// seeding the desktop floor would flash a desktop tree onto a 390pt
/// surface for one frame. The first presented frame corrects the value
/// exactly like the desktop seed; only the boot frame reads it.
pub const compact_seed_canvas_width: f32 = 390;

/// Which shell the root view composes. The two shells share every
/// content piece (tiles, rows, headings, the now-playing bindings) and
/// differ only in composition: `regular` is the desktop shape (wide
/// header bar, adaptive multi-column grid, full transport rail),
/// `compact` the phone shape (stacked touch header, mini player,
/// safe-area padding).
pub const FormFactor = enum { compact, regular };

/// Effect keys, model-owned identity (effect-key style). Audio playback
/// keys are the track ids themselves — one key namespace per channel.
pub const copy_key: u64 = 2;
// library_read_key / library_write_key live with the user-library caps.

/// The honest degraded state when a track's file cannot load.
pub const assets_missing_title = "couldn’t play this file";
pub const assets_missing_hint = "check the path or re-add the track";

/// The honest degraded state when a STREAM fails (a URL base is
/// configured, the local file was absent, and the network let the
/// playback down — offline with a cold cache, a dead host, a mid-flight
/// drop). Distinct from the assets notice on purpose: the remedy is
/// different.
pub const stream_failed_title = "stream unavailable";
pub const stream_failed_hint = "check the connection and try again";

/// The artist line while a stream is stalled waiting for bytes — the
/// honest state between "playing" and "paused" that only URL sources
/// have.
pub const buffering_hint = "buffering…";

/// Streaming configuration bounds: optional URL base override via
/// NATIVE_SDK_MUSIC_URL_BASE (unused for local imports) and the
/// platform cache directory resolved in main.
pub const max_url_base = 256;
pub const max_cache_dir = 512;

/// No committed streaming catalog — local files only by default.
pub const manifest_url_base: []const u8 = "";

// ------------------------------------------------------------------- model

pub const Tab = enum { albums, songs };

/// How the transport picks the next track when one finishes (or the
/// user skips). When the current track is in the playlist, modes walk
/// that list; otherwise Play Next entries are consumed FIFO, then the
/// mode falls back to album order.
pub const PlayMode = enum {
    /// Wrap within the playlist (or album when the playlist is empty).
    list_loop,
    /// Restart the same track when it completes; skip still advances.
    single_loop,
    /// Pick another track in the playlist (or album) at random.
    shuffle,
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

/// One presented frame's clock. Historically delivered through `on_frame`
/// at display rate while playing; the live path now drives the same
/// advance from a ~20 Hz fx timer (`scrubber_tick`) so playback does not
/// keep a full Metal present loop warm. Tests and journals may still
/// send `frame_clock` directly.
pub const FrameClock = struct {
    timestamp_ns: u64,
    interval_ns: u64,
};

/// How far the rendered clock may run AHEAD of a player position tick
/// before the disagreement stops being interpolation drift and gets
/// snapped. Drift per 500 ms tick is a few milliseconds; anything past a
/// full tick means reality changed (an external seek, a stall the
/// buffering flag has not reported yet), and honesty beats smoothness.
const position_snap_slack_ms: u32 = 600;

/// Scrubber / now-playing clock while audio moves. 50 ms ≈ 20 Hz: smooth
/// enough for the seek bar, far cheaper than tying the canvas to the
/// display refresh for the whole track.
pub const scrubber_timer_key: u64 = 42;
pub const scrubber_interval_ms: u64 = 50;

pub const Msg = union(enum) {
    show_albums,
    show_songs,
    /// Header / compact: cycle Albums ↔ Songs with one control.
    toggle_library_view,
    /// Header / compact: cycle the app theme light ↔ dark (locks off
    /// system-follow on first press).
    toggle_theme,
    /// Header / compact / empty state: open or close the Add menu.
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
    search_edit: canvas.TextInputEvent,
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
    /// One presented frame while playing: advances the rendered playback
    /// clock so the scrubber moves between coarse position ticks. Kept
    /// for tests/journals; the live app prefers `scrubber_tick`.
    frame_clock: FrameClock,
    /// ~20 Hz fx timer while playing: same clock advance as `frame_clock`,
    /// without sustaining a display-rate Metal present loop.
    scrubber_tick: native_sdk.EffectTimer,
    toggle_play,
    next_track,
    prev_track,
    /// Cycle the transport play mode: list loop → single → shuffle →
    /// sequential → list loop.
    cycle_play_mode,
    /// Seek slider changed; the reconciled value arrives through the
    /// `sync` hook (`seek_fraction`) before this message is applied.
    seeked,
    /// Volume slider changed; mirrored through `sync` (`volume`).
    volume_changed,
    /// Toggle the playlist panel above the transport.
    toggle_queue,
    /// Remove one entry from the playlist by track id.
    remove_queued: u8,
    /// Clear the playlist.
    clear_queue,
    /// Drain a macOS remote-command / media-key binding into transport.
    media_command: enum { toggle_play, next, previous },
    /// Every audio playback report: the load acknowledgment, position
    /// ticks, the one completion, and failures. Plain data — safe to
    /// read whole in update.
    audio_event: native_sdk.EffectAudio,
    /// Controlled scroll: each region's applied offset lands here and the
    /// view echoes it back, so a rebuild mid-gesture can never reset it.
    grid_scrolled: canvas.ScrollState,
    detail_scrolled: canvas.ScrollState,
    songs_scrolled: canvas.ScrollState,
    /// Context menu: queue a track to play after the current one.
    queue_track: u8,
    /// Context menu: copy the track title to the clipboard via `pbcopy`
    /// (the effects channel has no clipboard call today).
    copy_title: u8,
    copied: native_sdk.EffectExit,
    /// Header / compact: open a native multi-select file dialog and
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
    edit_year: canvas.TextInputEvent,
    /// Edit dialog: commit title/artist and close.
    save_edit_track,
    /// Edit dialog: dismiss without saving.
    close_edit_track,
    /// Edit album dialog: commit title/artist/year and close.
    save_edit_album,
    /// Edit album dialog: dismiss without saving.
    close_edit_album,
    /// Album / cover menu: pick a new cover image for this album.
    change_cover: u8,
    /// Persist / restore the user library file.
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
        // Mobile native tab bar (and tests) still send these; the in-canvas
        // header now uses `toggle_library_view` instead.
        "show_albums",    "show_songs",
        "open_album",     "close_album",    "play_album",
        "play_track",     "select_track",   "select_next",
        "select_previous", "play_selected", "frame_clock",
        "scrubber_tick",
        "audio_event",    "grid_scrolled",  "detail_scrolled",
        "songs_scrolled", "queue_track",    "copy_title",
        "copied",         "remove_track",   "edit_track",
        "edit_album",     "edit_title",     "edit_artist",
        "edit_year",      "save_edit_track", "close_edit_track",
        "save_edit_album", "close_edit_album", "change_cover",
        "library_done",   "cover_done",     "volume_changed",
        "toggle_queue",   "remove_queued",  "clear_queue",
        "media_command",
        "session_done",
    };
};

pub const Model = struct {
    // Source-of-truth state only; everything else is derived per rebuild.
    tab: Tab = .albums,
    appearance: native_sdk.Appearance = .{},
    /// Light/dark preference for tokens. Defaults to system-follow so a
    /// fresh install matches the OS; `toggle_theme` locks light or dark.
    theme: ThemePreference = .system,
    open_album: ?u8 = null,
    /// Controlled scroll offsets (album grid, album detail, all songs):
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
    /// so the search field clears the caption buttons.
    chrome_trailing: f32 = 0,
    /// The chrome band heights at the surface's TOP and BOTTOM edges,
    /// stored raw (no header floor applied). On phones the window-chrome
    /// channel carries the SAFE AREAS — status bar / Dynamic Island
    /// above, home indicator below — and the compact shell pads exactly
    /// these so content never sits under either. The desktop shell reads
    /// the floored `header_height` derivation below instead and has no
    /// bottom band to clear, so these stay untouched there.
    chrome_top: f32 = 0,
    chrome_bottom: f32 = 0,
    /// The host-reported form factor from the window-chrome channel
    /// (`chrome_changed`), null until a host reports one. When present
    /// it OWNS the shell switch (`formFactor` below) and the width
    /// derivation becomes the fallback for hosts that never report —
    /// desktop windows, tests, older hosts. Sticky by design: a host
    /// that reported once keeps its last report (an explicit `.unknown`
    /// never arrives as a Msg payload worth erasing state over).
    host_form_factor: ?FormFactor = null,
    /// True while the host projects the declared chrome tabs as a REAL
    /// native tab bar (`chrome_changed` carries the flag). The compact
    /// header yields its in-canvas Albums/Songs switcher while set —
    /// one tab affordance on screen, the system's — and keeps it
    /// everywhere the declaration is inert.
    native_tabs: bool = false,
    header_height: f32 = header_natural_height,
    /// The live canvas width, from `canvas_resized`. Seeds at the window
    /// min-width floor (see `min_canvas_width`) so pre-first-frame trees
    /// fit the narrowest window; the first presented frame corrects it.
    canvas_width: f32 = min_canvas_width,
    songs_scroll: f32 = 0,
    now: ?u8 = null, // playing track id
    /// Transport play mode: list loop / single / shuffle / sequential.
    /// Default matches the historic wrap-within-album advance.
    play_mode: PlayMode = .list_loop,
    /// Advances on every shuffle pick so consecutive skips diverge
    /// without a system CSPRNG (Zig 0.16 random lives behind Io).
    shuffle_nonce: u64 = 0,
    /// The SELECTED track id — the inverted accent row in track lists.
    /// Distinct from `now` on purpose: single click / arrows move the
    /// selection, only a double click, Enter, or the transport moves
    /// playback. Starting a track selects it too (the playing row is the
    /// current row), but selecting never plays.
    selected: ?u8 = null,
    playing: bool = false,
    /// The RENDERED playback clock (labels, scrubber, the motion window).
    /// While playing it advances every presented frame (`frame_clock`,
    /// bounded per-frame steps) and the player's coarse position ticks
    /// correct it: forward corrections apply, small backward ones hold
    /// flat (the bar never visibly rewinds mid-play), and only a
    /// past-slack disagreement snaps. Paused, buffering, and seeking
    /// snap exactly — interpolation exists only where there is motion.
    elapsed_ms: u32 = 0,
    /// The last `frame_clock` timestamp, the delta base for the rendered
    /// clock. Never reset: a stale gap (pause, occlusion, boot) is
    /// bounded by the frame-interval clamp in `advanceRenderedClock`.
    frame_ns: u64 = 0,
    /// The loaded track's TOTAL for display and seek math: the manifest
    /// duration, the same number the track lists render — the two
    /// surfaces must agree. The platform's self-reported duration never
    /// replaces a nonzero manifest value (it is an estimate for this
    /// catalog — see `handleAudioEvent`); only a track the manifest
    /// carries no duration for adopts the platform's report, since an
    /// estimated scrubber beats a dead one.
    now_duration_ms: u32 = 0,
    /// The platform player's own duration report, mirrored verbatim
    /// from the audio events: observable state for tests and debugging,
    /// and the fallback total above — never the displayed number while
    /// the manifest has one.
    platform_duration_ms: u32 = 0,
    /// A track's file failed to load (the gitignored audio assets are
    /// not prepared, no URL base is configured, or the platform has no
    /// audio playback): playback is cleared and the now-playing bar
    /// shows the prepare hint instead.
    assets_missing: bool = false,
    /// A STREAM failed (a URL base is configured and the network let
    /// the playback down): playback is cleared and the now-playing bar
    /// shows the connection hint instead of the prepare hint.
    stream_failed: bool = false,
    /// The stream is stalled waiting for network bytes — mirrored from
    /// the audio events' buffering flag so the bar can show the honest
    /// third state between playing and paused. Local files never set it.
    buffering: bool = false,
    /// Armed when `startTimer` for the scrubber is live. Starting an
    /// already active fx timer re-arms it (and would starve fires if
    /// called every update), so transitions only flip this flag. Lives
    /// on the Model so tests and journal replay stay isolated.
    scrubber_timer_armed: bool = false,
    /// Set when the scrubber timer was rejected (table full, no platform
    /// timer service). Blocks re-arm for the rest of this play session so
    /// reject → retry cannot loop; cleared when playback no longer wants
    /// the timer (pause / stop / buffer).
    scrubber_degraded: bool = false,
    /// The streaming URL base: the manifest's committed value (the
    /// hosted catalog mirror, so streaming works out of the box) until
    /// main overrides it from NATIVE_SDK_MUSIC_URL_BASE. Empty means
    /// local-only playback (the variable set empty disables streaming).
    url_base_buffer: [max_url_base]u8 = blk: {
        var buffer: [max_url_base]u8 = @splat(0);
        @memcpy(buffer[0..manifest_url_base.len], manifest_url_base);
        break :blk buffer;
    },
    url_base_len: usize = manifest_url_base.len,
    /// The platform caches directory for this app (app_dirs `.cache`),
    /// resolved in main; the track cache lives in its audio/ child.
    /// Empty (tests, resolution failure) disables the cache — streams
    /// still play, they just never persist.
    cache_dir_buffer: [max_cache_dir]u8 = @splat(0),
    cache_dir_len: usize = 0,
    /// Playlist (Play Album fills it with the whole record; Play Next appends).
    queue: [max_queue]u8 = @splat(0),
    queue_len: usize = 0,
    queue_dropped: u32 = 0,
    search_buffer: canvas.TextBuffer(max_search) = .{},
    /// Seek slider value, mirrored from the runtime through `sync`.
    seek_fraction: f32 = 0,
    /// Volume slider value (0..1), mirrored through `sync` and applied
    /// with `fx.setAudioVolume`. Remembered in the session store.
    volume: f32 = 1.0,
    /// Whether the playlist panel is expanded above the transport.
    queue_open: bool = false,
    /// Header / empty-state Add control: the anchored dropdown is open.
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
    edit_year_buffer: canvas.TextBuffer(8) = .{},
    /// Copy-to-clipboard bookkeeping: how many pbcopy spawns finished ok.
    copies_done: u32 = 0,
    copy_failed: bool = false,
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
    /// once `startTrack` runs from `library_done`/`session_done`.
    session_resume_track: ?u8 = null,
    session_resume_elapsed_ms: u32 = 0,
    session_resume_playing: bool = false,
    /// Last import/remove status for the now-playing / empty surfaces.
    library_notice: enum { none, added, removed, full, cancelled, failed, updated } = .none,
    library_notice_count: u32 = 0,

    /// Read by the ZIG-BUILT views (grid, detail, track rows), update
    /// logic, or main's launch wiring — never bound in markup — so
    /// opting them out keeps `native check`'s dead-state lint quiet
    /// without weakening it for real drift. The markup fragments bind
    /// the derived fns (`nowPlayingTitle`, `playPauseIcon`,
    /// `progressFraction`, ...) instead of these backing stores.
    pub const view_unbound = .{
        "tab",             "open_album",     "grid_scroll",
        "detail_scroll",   "canvas_width",   "songs_scroll",
        "now",             "selected",       "playing",
        "play_mode",       "shuffle_nonce",
        "elapsed_ms",      "frame_ns",       "now_duration_ms",
        "platform_duration_ms",
        "assets_missing",  "stream_failed",  "buffering",
        "scrubber_timer_armed", "scrubber_degraded",
        "url_base_len",    "cache_dir_len",  "queue_dropped",
        "seek_fraction",   "volume",
        "copies_done",    "copy_failed",
        "appearance",      "theme",          "search_buffer",  "url_base_buffer",
        "cache_dir_buffer", "queue",         "queue_len",
        "editing_track",   "editing_album",  "edit_title_buffer",
        "edit_artist_buffer", "edit_year_buffer",
        "chrome_top",      "chrome_bottom",  "host_form_factor",
        "native_tabs",     "urlBase",
        "cacheDir",        "streamingConfigured", "searching",
        "colorScheme",     "hasNowPlaying",  "playingAlbum",
        "visibleAlbums",   "visibleTracks",  "miniBarVisible",
        "formFactor",
        "albumsShowing",   "songsShowing", "libraryViewLabel",
        "albumCount",      "trackCount",
        "user_albums",     "user_album_count", "next_user_album_id",
        "user_tracks",     "user_track_count", "next_user_track_id",
        "store_path_buffer", "store_path_len", "store_write_inflight",
        "session_path_buffer", "session_path_len",
        "media_dir_buffer", "media_dir_len",
        "session_write_inflight", "session_save_pending",
        "session_resume_track", "session_resume_elapsed_ms",
        "session_resume_playing",
        "save_pending",    "library_notice", "library_notice_count",
        "storePath",       "sessionPath",    "mediaDir",
        "editTitle",
        "editArtist",      "editYear",       "isEditingTrack",
        "isEditingAlbum",  "queuedTracks",   "volumeFraction",
    };

    // ------------------------------------------------------------- queries

    pub fn search(model: *const Model) []const u8 {
        return model.search_buffer.text();
    }

    pub fn urlBase(model: *const Model) []const u8 {
        return model.url_base_buffer[0..model.url_base_len];
    }

    pub fn cacheDir(model: *const Model) []const u8 {
        return model.cache_dir_buffer[0..model.cache_dir_len];
    }

    /// Whether tracks can stream on demand: a URL base is configured
    /// (manifest or env). This is what turns the "assets not prepared"
    /// story into "streams on demand".
    pub fn streamingConfigured(model: *const Model) bool {
        return model.url_base_len > 0;
    }

    /// Install the streaming base (launch-time: env override or the
    /// manifest default). A trailing slash is trimmed so URL assembly
    /// is uniform; an over-long value is refused whole — a truncated
    /// base would stream garbage politely.
    pub fn setUrlBase(model: *Model, base: []const u8) void {
        const trimmed = std.mem.trimEnd(u8, base, "/");
        if (trimmed.len > max_url_base) return;
        @memcpy(model.url_base_buffer[0..trimmed.len], trimmed);
        model.url_base_len = trimmed.len;
    }

    /// Install the platform cache directory (launch-time). Over-long
    /// values are refused whole, leaving the cache disabled — honest
    /// degrade, streams still play.
    pub fn setCacheDir(model: *Model, dir: []const u8) void {
        if (dir.len > max_cache_dir) return;
        @memcpy(model.cache_dir_buffer[0..dir.len], dir);
        model.cache_dir_len = dir.len;
    }

    pub fn searching(model: *const Model) bool {
        return model.search().len > 0;
    }

    pub fn albumsShowing(model: *const Model) bool {
        return model.tab == .albums;
    }

    pub fn songsShowing(model: *const Model) bool {
        return model.tab == .songs;
    }

    /// Label for the single library view switcher: the view currently
    /// on screen. Press cycles to the other via `toggle_library_view`.
    pub fn libraryViewLabel(model: *const Model) []const u8 {
        return switch (model.tab) {
            .albums => "Albums",
            .songs => "Songs",
        };
    }

    /// Icon for the library view switcher — grid when on albums, music
    /// note when on the flat songs list.
    pub fn libraryViewIcon(model: *const Model) []const u8 {
        return switch (model.tab) {
            .albums => "app:albums",
            .songs => "music",
        };
    }

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

    pub fn editYear(model: *const Model) []const u8 {
        return model.edit_year_buffer.text();
    }

    pub fn albumCount(model: *const Model) usize {
        var count: usize = 0;
        for (model.user_albums[0..model.user_album_count]) |*album| {
            if (model.tracksInAlbum(album.id) > 0) count += 1;
        }
        return count;
    }

    pub fn trackCount(model: *const Model) usize {
        return model.user_track_count;
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

    /// The shell rule: the HOST-REPORTED form factor owns the switch
    /// when a host has reported one (the window-chrome channel carries
    /// it, so it arrived as a Msg and replays with the journal); the
    /// width rule below is the fallback for hosts that never report —
    /// desktop windows, tests, older hosts.
    ///
    /// The width fallback, one strict comparison with no hysteresis:
    /// COMPACT strictly below the desktop shell's proven min content
    /// width (`min_canvas_width` — the floor the desktop layout audit
    /// sweeps from), the desktop shell at the floor and above. The
    /// boundary is honest by construction: every narrower surface is one
    /// the desktop composition has never been proven clean on (desktop
    /// windows enforce the floor, so only phone-class surfaces ever
    /// report less), and exactly AT the floor the audit proves the
    /// desktop shell clean. Both inputs are per-frame model state, so
    /// the same Msg sequence always lands the same shell.
    pub fn formFactor(model: *const Model) FormFactor {
        if (model.host_form_factor) |host| return host;
        return if (model.canvas_width < min_canvas_width) .compact else .regular;
    }

    /// Whether the compact shell's mini player is on screen: a track is
    /// loaded (playing OR paused — the bar must not vanish on pause), or
    /// a degraded playback notice needs a surface to read on (a failed
    /// load clears `now`, and the notice would otherwise be invisible on
    /// a phone with no persistent transport rail).
    pub fn miniBarVisible(model: *const Model) bool {
        return model.now != null or model.assets_missing or model.stream_failed;
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

    /// Glyph for the play-mode cycle button: built-in `repeat` /
    /// `shuffle` plus the app-owned single-loop and sequential marks.
    pub fn playModeIcon(model: *const Model) []const u8 {
        return switch (model.play_mode) {
            .list_loop => "repeat",
            .single_loop => "app:repeat-1",
            .shuffle => "shuffle",
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
        if (model.stream_failed) return stream_failed_title;
        if (model.assets_missing) return assets_missing_title;
        const track = model.nowTrack() orelse return "Nothing playing";
        return track.title;
    }

    pub fn nowPlayingArtist(model: *const Model) []const u8 {
        if (model.stream_failed) return stream_failed_hint;
        if (model.assets_missing) return assets_missing_hint;
        const track = model.nowTrack() orelse return "Pick an album or a song to start";
        // The honest third state: a stalled stream is not paused, but
        // nothing is coming out of the speakers either — say so where
        // the artist normally reads.
        if (model.buffering) return buffering_hint;
        if (track.artist.len > 0) return track.artist;
        const album = model.userAlbumById(track.album) orelse return "";
        return album.artist();
    }

    pub fn progressFraction(model: *const Model) f32 {
        if (model.now == null or model.now_duration_ms == 0) return 0;
        const fraction = @as(f32, @floatFromInt(model.elapsed_ms)) / @as(f32, @floatFromInt(model.now_duration_ms));
        return std.math.clamp(fraction, 0, 1);
    }

    pub fn elapsedLabel(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (model.now == null) return "-:--";
        return formatMs(arena, model.elapsed_ms);
    }

    pub fn durationLabel(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (model.now == null) return "-:--";
        return formatMs(arena, model.now_duration_ms);
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

    /// Albums matching the search query, derived into the build arena.
    pub fn visibleAlbums(model: *const Model, arena: std.mem.Allocator) []const AlbumCell {
        const out = arena.alloc(AlbumCell, model.user_album_count) catch return &.{};
        var count: usize = 0;
        for (model.user_albums[0..model.user_album_count]) |*user| {
            if (model.tracksInAlbum(user.id) == 0) continue;
            const album = user.asAlbum();
            if (!model.albumMatches(&album)) continue;
            out[count] = .{
                .id = album.id,
                .title = album.title,
                .artist = album.artist,
                .initials = album.initials,
                .cover = model.coverFor(album.id),
                .playing = model.playingAlbum() == album.id,
            };
            count += 1;
        }
        return out[0..count];
    }

    /// Library tracks matching the search query (title, artist, or album),
    /// derived into the build arena.
    pub fn visibleTracks(model: *const Model, arena: std.mem.Allocator) []const TrackRow {
        const out = arena.alloc(TrackRow, model.user_track_count) catch return &.{};
        var count: usize = 0;
        for (model.user_tracks[0..model.user_track_count]) |*user| {
            const track = user.asTrack();
            if (!model.trackMatches(&track)) continue;
            out[count] = model.trackRow(arena, track, .with_album);
            count += 1;
        }
        return out[0..count];
    }

    /// One album's tracks for the detail view (never search-filtered: the
    /// detail page is the whole record).
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

    pub fn playingAlbum(model: *const Model) u8 {
        const track = model.nowTrack() orelse return 0;
        return if (model.playing) track.album else 0;
    }

    fn albumMatches(model: *const Model, album: *const Album) bool {
        const query = model.search();
        if (query.len == 0) return true;
        return containsIgnoreCase(album.title, query) or containsIgnoreCase(album.artist, query);
    }

    fn trackMatches(model: *const Model, track: *const Track) bool {
        const query = model.search();
        if (query.len == 0) return true;
        const album = model.userAlbumById(track.album);
        const album_artist = if (album) |a| a.artist() else "";
        const album_title = if (album) |a| a.title() else "";
        return containsIgnoreCase(track.title, query) or
            containsIgnoreCase(track.artist, query) or
            containsIgnoreCase(album_artist, query) or
            containsIgnoreCase(album_title, query);
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
            .queued = model.isQueued(track.id),
            .removable = isUserTrackId(track.id),
        };
    }

    fn isQueued(model: *const Model, track_id: u8) bool {
        // The now-playing track can sit in the playlist; the "Up next"
        // badge is only for entries still waiting their turn.
        if (model.now == track_id) return false;
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
            track.setTitle(titleFromPath(path));
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
            model.buffering = false;
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
        model.edit_year_buffer.clear();
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
        model.edit_year_buffer.clear();
    }

    pub fn beginEditAlbum(model: *Model, id: u8) bool {
        const album = model.userAlbumById(id) orelse return false;
        model.cancelEditTrack();
        model.editing_album = id;
        model.edit_title_buffer.set(album.title());
        model.edit_artist_buffer.set(album.artist());
        var year_buf: [8]u8 = undefined;
        const year_text = std.fmt.bufPrint(&year_buf, "{d}", .{album.year}) catch return false;
        model.edit_year_buffer.set(year_text);
        return true;
    }

    pub fn applyEditAlbum(model: *Model) bool {
        const id = model.editing_album orelse return false;
        const album = model.userAlbumByIdMut(id) orelse return false;
        const title = std.mem.trim(u8, model.edit_title_buffer.text(), " \t");
        if (title.len == 0) return false;
        const year_text = std.mem.trim(u8, model.edit_year_buffer.text(), " \t");
        const year = std.fmt.parseInt(u16, year_text, 10) catch return false;
        if (year == 0) return false;
        album.setTitle(title);
        album.setArtist(std.mem.trim(u8, model.edit_artist_buffer.text(), " \t"));
        album.setYear(year);
        model.cancelEditAlbum();
        return true;
    }

    pub fn cancelEditAlbum(model: *Model) void {
        model.editing_album = null;
        model.edit_title_buffer.clear();
        model.edit_artist_buffer.clear();
        model.edit_year_buffer.clear();
    }
};

pub const AlbumCell = struct {
    id: u8,
    title: []const u8,
    artist: []const u8,
    initials: []const u8,
    cover: canvas.ImageId,
    playing: bool,
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
    queued: bool,
    /// User-imported tracks can be removed from the library.
    removable: bool,
};

fn formatMs(arena: std.mem.Allocator, ms: u32) []const u8 {
    const total_seconds = ms / 1000;
    return std.fmt.allocPrint(arena, "{d}:{d:0>2}", .{ total_seconds / 60, total_seconds % 60 }) catch "";
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
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
        .single_loop => "single_loop",
        .shuffle => "shuffle",
        .sequential => "sequential",
    };
}

fn parsePlayMode(name: []const u8) ?PlayMode {
    if (std.mem.eql(u8, name, "list_loop")) return .list_loop;
    if (std.mem.eql(u8, name, "single_loop")) return .single_loop;
    if (std.mem.eql(u8, name, "shuffle")) return .shuffle;
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
    if (!model.addUserTrackToAlbum(album_id, dest)) {
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
    const services = fx.services orelse {
        model.library_notice = .failed;
        return;
    };
    var buffer: [native_sdk.platform.max_dialog_paths_bytes]u8 = undefined;
    const result = services.showOpenDialog(.{
        .title = "Add Music",
        .filters = &.{
            .{ .name = "Audio", .extensions = &.{ "mp3", "m4a", "wav", "aac", "flac", "ogg" } },
            .{ .name = "All files", .extensions = &.{ "*" } },
        },
        .allow_multiple = true,
    }, &buffer) catch {
        model.library_notice = .failed;
        return;
    };
    if (result.count == 0) {
        model.library_notice = .cancelled;
        return;
    }
    var added: u32 = 0;
    var hit_full = false;
    var paths = std.mem.splitScalar(u8, result.paths, '\n');
    while (paths.next()) |path| {
        const trimmed = std.mem.trim(u8, path, " \r");
        if (trimmed.len == 0) continue;
        if (model.user_track_count >= max_user_tracks) {
            hit_full = true;
            break;
        }
        if (importAudioFromSource(model, imported_album_id, trimmed)) added += 1;
    }
    if (added > 0) {
        model.library_notice = .added;
        model.library_notice_count = added;
        model.tab = .songs;
        persistLibrary(model, fx);
    } else if (hit_full) {
        model.library_notice = .full;
    } else {
        model.library_notice = .cancelled;
    }
}

fn pickAndImportAlbum(model: *Model, fx: *Effects) void {
    const services = fx.services orelse {
        model.library_notice = .failed;
        return;
    };
    var buffer: [native_sdk.platform.max_dialog_paths_bytes]u8 = undefined;
    const result = services.showOpenDialog(.{
        .title = "Import Album",
        .allow_directories = true,
        .allow_multiple = false,
    }, &buffer) catch {
        model.library_notice = .failed;
        return;
    };
    if (result.count == 0) {
        model.library_notice = .cancelled;
        return;
    }
    var paths = std.mem.splitScalar(u8, result.paths, '\n');
    const dir_path = while (paths.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \r");
        if (trimmed.len > 0) break trimmed;
    } else {
        model.library_notice = .cancelled;
        return;
    };
    if (dir_path.len > max_user_path) {
        model.library_notice = .failed;
        return;
    }

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch {
        model.library_notice = .failed;
        return;
    };
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

    if (audio_count == 0) {
        model.library_notice = .cancelled;
        return;
    }

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
    const album_id = model.addUserAlbum(title, artist) orelse {
        model.library_notice = .full;
        return;
    };

    var added: u32 = 0;
    var hit_full = false;
    for (order[0..audio_count]) |idx| {
        if (model.user_track_count >= max_user_tracks) {
            hit_full = true;
            break;
        }
        const path = audio_paths[idx][0..audio_lens[idx]];
        if (importAudioFromSource(model, album_id, path)) added += 1;
    }

    if (added == 0) {
        model.removeUserAlbum(album_id);
        model.library_notice = if (hit_full) .full else .cancelled;
        return;
    }

    if (cover_path_len > 0) {
        if (importCoverFromSource(model, album_id, cover_path_buf[0..cover_path_len])) {
            requestCoverLoad(model, fx, album_id);
        }
    }

    model.library_notice = .added;
    model.library_notice_count = added;
    model.tab = .albums;
    model.open_album = album_id;
    model.detail_scroll = 0;
    persistLibrary(model, fx);
}

fn pickAndSetCover(model: *Model, fx: *Effects, album_id: u8) void {
    if (model.userAlbumById(album_id) == null) {
        model.library_notice = .failed;
        return;
    }
    const services = fx.services orelse {
        model.library_notice = .failed;
        return;
    };
    var buffer: [native_sdk.platform.max_dialog_paths_bytes]u8 = undefined;
    const result = services.showOpenDialog(.{
        .title = "Choose Cover",
        .filters = &.{
            .{ .name = "Images", .extensions = &.{ "png", "jpg", "jpeg", "webp", "gif" } },
            .{ .name = "All files", .extensions = &.{ "*" } },
        },
        .allow_multiple = false,
    }, &buffer) catch {
        model.library_notice = .failed;
        return;
    };
    if (result.count == 0) {
        model.library_notice = .cancelled;
        return;
    }
    var paths = std.mem.splitScalar(u8, result.paths, '\n');
    const path = while (paths.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \r");
        if (trimmed.len > 0) break trimmed;
    } else {
        model.library_notice = .cancelled;
        return;
    };
    if (path.len > max_user_path) {
        model.library_notice = .failed;
        return;
    }
    if (!importCoverFromSource(model, album_id, path)) {
        model.library_notice = .failed;
        return;
    }
    persistLibrary(model, fx);
    requestCoverLoad(model, fx, album_id);
}

fn requestCoverLoad(model: *Model, fx: *Effects, album_id: u8) void {
    const album = model.userAlbumByIdMut(album_id) orelse return;
    if (album.cover_path_len == 0) {
        album.cover = 0;
        _ = fx.unregisterImage(album_id);
        return;
    }
    fx.readFile(.{
        .key = coverReadKey(album_id),
        .path = album.coverPath(),
        .on_result = Effects.fileMsg(.cover_done),
    });
}

fn requestAllCoverLoads(model: *Model, fx: *Effects) void {
    for (model.user_albums[0..model.user_album_count]) |*album| {
        if (album.cover_path_len > 0) requestCoverLoad(model, fx, album.id);
    }
}

fn applySessionResume(model: *Model, fx: *Effects) void {
    fx.setAudioVolume(model.volume);
    const id = model.session_resume_track orelse return;
    const elapsed = model.session_resume_elapsed_ms;
    const playing = model.session_resume_playing;
    model.session_resume_track = null;
    startTrack(model, fx, id);
    if (elapsed > 0) {
        model.elapsed_ms = elapsed;
        fx.seekAudio(elapsed);
    }
    if (!playing) setPlaying(model, fx, false);
}

fn applyCoverBytes(model: *Model, fx: *Effects, album_id: u8, bytes: []const u8) bool {
    const album = model.userAlbumByIdMut(album_id) orelse return false;
    _ = fx.registerImageBytes(album_id, bytes) catch {
        album.cover = 0;
        return false;
    };
    album.cover = album_id;
    return true;
}

// ------------------------------------------------------------------ update

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    defer syncScrubberTimer(model, fx);
    switch (msg) {
        .show_albums => {
            model.tab = .albums;
            model.add_menu_open = false;
        },
        .show_songs => {
            model.tab = .songs;
            model.add_menu_open = false;
        },
        .toggle_library_view => {
            model.tab = if (model.tab == .albums) .songs else .albums;
            model.add_menu_open = false;
        },
        .toggle_theme => {
            // Lock to the opposite of whatever is showing now (system-
            // follow included): first press leaves the OS and every
            // later press flips light ↔ dark.
            model.theme = switch (model.colorScheme()) {
                .light => .dark,
                .dark => .light,
            };
            persistSession(model, fx);
        },
        .toggle_add_menu => model.add_menu_open = !model.add_menu_open,
        .close_add_menu => model.add_menu_open = false,
        .set_appearance => |appearance| model.appearance = appearance,
        .chrome_changed => |chrome| {
            // Pad whichever edge the platform puts its window controls
            // on (macOS: traffic lights leading; Windows: min/max/close
            // trailing) — the unused edge arrives as an honest zero.
            model.chrome_leading = chrome.insets.left;
            model.chrome_trailing = chrome.insets.right;
            // The raw top/bottom bands, for the compact shell's
            // safe-area padding: on phones the same channel carries the
            // status bar / Dynamic Island above and the home indicator
            // below, and the compact shell pads exactly these.
            model.chrome_top = chrome.insets.top;
            model.chrome_bottom = chrome.insets.bottom;
            // Match the header to the titlebar band so its centered
            // controls share the traffic lights' centerline; the natural
            // height is the floor when no band overlays the content.
            model.header_height = @max(header_natural_height, chrome.insets.top);
            // Host-reported form factor: adopt when the host says one
            // (sticky — see the field), leave the width fallback in
            // charge when it never does.
            switch (chrome.form_factor) {
                .compact => model.host_form_factor = .compact,
                .regular => model.host_form_factor = .regular,
                .unknown => {},
            }
            // Whether a native bar owns the tab affordance right now:
            // the compact header's switcher yields exactly while it is
            // projected.
            model.native_tabs = chrome.tabs_projected;
        },
        .canvas_resized => |width| model.canvas_width = width,
        .search_edit => |edit| model.search_buffer.apply(edit),
        .grid_scrolled => |state| model.grid_scroll = state.offset,
        .detail_scrolled => |state| model.detail_scroll = state.offset,
        .songs_scrolled => |state| model.songs_scroll = state.offset,
        .open_album => |id| {
            model.open_album = id;
            model.tab = .albums;
            // A fresh record opens at its top.
            model.detail_scroll = 0;
        },
        .close_album => model.open_album = null,
        .play_album => |id| {
            const first = model.firstTrackIdInAlbum(id) orelse return;
            // Replace the playlist with the whole album so the panel shows
            // every track and list_loop / sequential / shuffle walk that
            // list instead of consuming a one-shot "up next" FIFO.
            model.queue_len = 0;
            model.queue_dropped = 0;
            const count = model.tracksInAlbum(id);
            var number: u8 = 1;
            while (number <= count) : (number += 1) {
                const track = model.userTrackInAlbumByNumber(id, number) orelse continue;
                model.pushQueue(track.id);
            }
            if (model.queue_len > 0) model.queue_open = true;
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
        .scrubber_tick => |timer| {
            if (timer.outcome == .rejected) {
                model.scrubber_timer_armed = false;
                model.scrubber_degraded = true;
                return;
            }
            if (timer.outcome != .fired) return;
            advanceRenderedClock(model, .{
                .timestamp_ns = timer.timestamp_ns,
                .interval_ns = scrubber_interval_ms * std.time.ns_per_ms,
            });
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
                .list_loop => .single_loop,
                .single_loop => .shuffle,
                .shuffle => .sequential,
                .sequential => .list_loop,
            };
            persistSession(model, fx);
        },
        .seeked => {
            if (model.now != null) {
                const duration: f32 = @floatFromInt(model.now_duration_ms);
                const target: u32 = @intFromFloat(std.math.clamp(model.seek_fraction, 0, 1) * duration);
                // Optimistic mirror for the labels; the platform seek has
                // no echo — the next position tick reports from there.
                model.elapsed_ms = target;
                fx.seekAudio(target);
                persistSession(model, fx);
            }
        },
        .volume_changed => {
            model.volume = std.math.clamp(model.volume, 0, 1);
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
        .copy_title => |id| {
            const title = if (model.resolveTrack(id)) |track| track.title else "";
            fx.spawn(.{
                .key = copy_key,
                .argv = &.{"/usr/bin/pbcopy"},
                .stdin = title,
                .on_exit = Effects.exitMsg(.copied),
            });
        },
        .copied => |exit| {
            if (exit.reason == .exited and exit.code == 0) {
                model.copies_done += 1;
                model.copy_failed = false;
            } else {
                model.copy_failed = true;
            }
        },
        .add_music => {
            model.add_menu_open = false;
            pickAndImportMusic(model, fx);
        },
        .import_album => {
            model.add_menu_open = false;
            pickAndImportAlbum(model, fx);
        },
        .remove_track => |id| {
            if (!isUserTrackId(id)) return;
            const was_playing = model.now == id;
            if (!model.removeUserTrack(id)) return;
            if (model.editing_track == id) model.cancelEditTrack();
            model.library_notice = .removed;
            model.library_notice_count = 1;
            if (was_playing) fx.stopAudio();
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
        .edit_year => |edit| model.edit_year_buffer.apply(edit),
        .save_edit_track => {
            if (!model.applyEditTrack()) return;
            model.library_notice = .updated;
            model.library_notice_count = 1;
            persistLibrary(model, fx);
        },
        .close_edit_track => model.cancelEditTrack(),
        .save_edit_album => {
            if (!model.applyEditAlbum()) return;
            model.library_notice = .updated;
            model.library_notice_count = 1;
            persistLibrary(model, fx);
        },
        .close_edit_album => model.cancelEditAlbum(),
        .change_cover => |album_id| pickAndSetCover(model, fx, album_id),
        .library_done => |result| switch (result.op) {
            .read => switch (result.outcome) {
                .ok => {
                    if (model.restoreLibrary(result.bytes)) {
                        if (migrateExternalMedia(model)) persistLibrary(model, fx);
                        requestAllCoverLoads(model, fx);
                        requestSessionLoad(model, fx);
                    } else {
                        model.library_notice = .failed;
                    }
                },
                .not_found => requestSessionLoad(model, fx),
                else => model.library_notice = .failed,
            },
            .write => {
                model.store_write_inflight = false;
                if (result.outcome == .ok and model.save_pending) {
                    model.save_pending = false;
                    persistLibrary(model, fx);
                } else if (result.outcome != .ok) {
                    model.library_notice = .failed;
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
            const album_id = albumIdFromCoverKey(result.key) orelse {
                model.library_notice = .failed;
                return;
            };
            switch (result.outcome) {
                .ok => {
                    if (!applyCoverBytes(model, fx, album_id, result.bytes)) {
                        model.library_notice = .failed;
                    }
                },
                else => {
                    if (model.userAlbumByIdMut(album_id)) |album| album.cover = 0;
                    model.library_notice = .failed;
                },
            }
        },
    }
}

/// Every playback report flows through here. The audio key is the track
/// id, so a straggler for a track the model no longer plays is dropped
/// by identity — never misattributed to the current one.
///
/// THE DURATION RULE. Events carry the platform player's own duration
/// readout, and for this catalog that number is an ESTIMATE, never the
/// truth: the prepare script strips the seek header from every prepared
/// file (nothing of the source encoder may survive the strip), so a
/// decoder can only extrapolate the length from the bitrate it has seen
/// — a progressive stream's early guess has measured minutes wrong, and
/// even a fully local file reads seconds long and wobbles between
/// ticks. The manifest duration was measured from the intact SOURCE
/// file and matches a full decode exactly, so `now_duration_ms` (the
/// displayed total, the scrubber's denominator, the seek target's
/// scale) keeps the manifest value and the platform's report only lands
/// in `platform_duration_ms` — adopted as the total solely when the
/// manifest carries no duration at all. Positions are different:
/// position ticks are the player's REAL clock and stay authoritative.
fn handleAudioEvent(model: *Model, fx: *Effects, event: native_sdk.EffectAudio) void {
    const now = model.now orelse return;
    if (event.key != now) return;
    switch (event.kind) {
        .loaded => {
            adoptPlatformDuration(model, fx, event.duration_ms);
            model.elapsed_ms = @intCast(event.position_ms);
            model.playing = event.playing;
            model.buffering = event.buffering;
        },
        .position => {
            const position: u32 = @intCast(event.position_ms);
            adoptPlatformDuration(model, fx, event.duration_ms);
            // The stream's honest stall flag rides every tick; local
            // files always report false.
            model.buffering = event.buffering;
            // The coarse tick CORRECTS the frame-advanced rendered
            // clock. In motion, forward corrections apply and small
            // backward ones hold flat — the bar must never visibly
            // rewind because our frames ran a few ms ahead of the
            // player — while a past-slack disagreement is a real
            // desync (an external seek, an unreported stall) and
            // snaps. With no motion (paused, buffering) the tick is
            // simply the truth.
            if (model.playing and !model.buffering) {
                if (position > model.elapsed_ms or model.elapsed_ms - position > position_snap_slack_ms) {
                    model.elapsed_ms = position;
                }
            } else {
                model.elapsed_ms = position;
            }
        },
        // Real band-magnitude reports from hosts that analyze their own
        // playback. WellMusic draws no analyzer — its identity is
        // the clean catalog, not phosphor glass — so the reports are
        // consciously ignored (the deck is the surface that adopts
        // them).
        .spectrum => {},
        .completed => onTrackCompleted(model, fx),
        .failed, .rejected => {
            // Playback could not run. With a URL base configured the
            // local-file miss would have streamed, so a failure here
            // means the NETWORK let the playback down (offline with a
            // cold cache, a dead host, a mid-flight drop); without one
            // it means the local file is gone/unreadable (or the host
            // has no audio playback). Two notices, two remedies — and
            // the catalog keeps browsing fine either way. Persist so a
            // later launch does not keep auto-resuming a dead path.
            if (model.streamingConfigured()) {
                model.stream_failed = true;
            } else {
                model.assets_missing = true;
            }
            model.now = null;
            model.playing = false;
            model.buffering = false;
            model.elapsed_ms = 0;
            model.now_duration_ms = 0;
            model.platform_duration_ms = 0;
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
/// the playing row is the current row.
fn playOrToggle(model: *Model, fx: *Effects, track_id: u8) void {
    model.selected = track_id;
    if (model.now == track_id) {
        setPlaying(model, fx, !model.playing);
    } else {
        startTrack(model, fx, track_id);
    }
}

const SelectionStep = enum { previous, next };

/// Whether a track sits in the track list currently on screen — the
/// domain the arrow-key selection walks. Songs tab: the search-filtered
/// library (the same predicate `visibleTracks` renders). Album detail:
/// the whole record, never filtered (matching `albumTrackRows`). The
/// album GRID shows no track list, so arrows move nothing there.
fn trackInCurrentList(model: *const Model, track: Track) bool {
    return switch (model.tab) {
        .songs => model.trackMatches(&track),
        .albums => if (model.open_album) |album_id| track.album == album_id else false,
    };
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

/// Arm or disarm the ~20 Hz scrubber timer so the seek bar advances
/// without a display-rate Metal loop. Idempotent: only start/cancel on
/// edge transitions (re-arming every update would starve fires). When
/// the host rejected the timer, stay disarmed for this play session
/// (`scrubber_degraded`) and clear that latch once `want` falls.
fn syncScrubberTimer(model: *Model, fx: *Effects) void {
    const want = model.playing and model.now != null and !model.buffering;
    if (!want) model.scrubber_degraded = false;
    const effective = want and !model.scrubber_degraded;
    if (effective == model.scrubber_timer_armed) return;
    model.scrubber_timer_armed = effective;
    if (effective) {
        fx.startTimer(.{
            .key = scrubber_timer_key,
            .interval_ms = scrubber_interval_ms,
            .mode = .repeating,
            .on_fire = Effects.timerMsg(.scrubber_tick),
        });
    } else {
        fx.cancelTimer(scrubber_timer_key);
    }
}

/// One presented frame while playing: advance the rendered clock by the
/// real frame delta, clamped to a few display intervals so a stale gap
/// (resume after pause, an occluded window, boot) steps gently instead
/// of lurching, and capped at the duration. Motion-gated twice — the
/// live timer / `on_frame` hook only emit while playing, and this
/// re-checks so a replayed journal straddling a pause boundary stays exact.
fn advanceRenderedClock(model: *Model, frame: FrameClock) void {
    const last = model.frame_ns;
    model.frame_ns = frame.timestamp_ns;
    if (!model.playing or model.now == null or model.buffering) return;
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
    // `elapsed_ms` restarts here and advances with frame-clock messages
    // corrected by position events — it is also the motion clock for
    // the now-playing slide-in window, so animation gating replays
    // deterministically (no live clock read anywhere).
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
    model.stream_failed = false;
    model.buffering = false;
    model.playing = true;
    // The source cascade rides ONE playAudio call: the prepared local
    // file first, then (URL base configured) the track's URL — where
    // the platform plays a verified cache entry locally or streams
    // progressively while filling the cache, keyed by the URL's hash
    // under the platform caches directory. `expected_bytes` is the
    // manifest's prepared size, the integrity gate that keeps partial
    // or stale cache entries from ever playing. The strings are copied
    // at call time, so stack buffers are fine here.
    // User imports are path-only (no streaming base for absolute files).
    var url_buffer: [max_url_base + 512]u8 = undefined;
    var url: []const u8 = "";
    if (track.file.len > 0 and model.streamingConfigured()) {
        url = std.fmt.bufPrint(&url_buffer, "{s}/{s}", .{ model.urlBase(), track.file }) catch "";
    }
    // Path-only imports store absolute filesystem paths. If the user
    // moved or deleted the file, fail before asking the host — and
    // persist so session resume does not keep retrying a dead path.
    // Fake-executor tests seed placeholder paths; skip the open check
    // there so playback logic stays unit-testable without real files.
    if (url.len == 0 and fx.executor != .fake and !localAudioReadable(track.path)) {
        model.assets_missing = true;
        model.now = null;
        model.playing = false;
        model.elapsed_ms = 0;
        model.now_duration_ms = 0;
        model.platform_duration_ms = 0;
        persistSession(model, fx);
        return;
    }
    var cache_buffer: [max_cache_dir + 128]u8 = undefined;
    var cache_path: []const u8 = "";
    if (url.len > 0 and model.cacheDir().len > 0) {
        cache_path = native_sdk.audioCachePath(&cache_buffer, model.cacheDir(), url) catch "";
    }
    // One player total: a new playAudio replaces whatever played before,
    // and the track id keys every event back to this playback.
    fx.playAudio(.{
        .key = track_id,
        .path = track.path,
        .url = url,
        .cache_path = cache_path,
        .expected_bytes = track.bytes,
        .on_event = Effects.audioMsg(.audio_event),
    });
    fx.setAudioVolume(model.volume);
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
    model.playing = playing;
    if (playing) {
        fx.resumeAudio();
    } else {
        fx.pauseAudio();
    }
    persistSession(model, fx);
}

/// A track finished: single-loop restarts it; every other mode asks the
/// same skip path the next button uses (playlist / play-next / album).
fn onTrackCompleted(model: *Model, fx: *Effects) void {
    if (model.play_mode == .single_loop) {
        if (model.now) |id| startTrack(model, fx, id);
        return;
    }
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
        .list_loop, .single_loop => {
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
        .shuffle => {
            const next_id = pickShuffledAlbumTrack(model, track) orelse return;
            startTrack(model, fx, next_id);
        },
    }
}

fn advanceWithinPlaylist(model: *Model, fx: *Effects, idx: usize, from_completion: bool) void {
    const len = model.queue_len;
    if (len == 0) return;
    switch (model.play_mode) {
        .list_loop, .single_loop => {
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
        .shuffle => {
            const next_id = pickShuffledPlaylistTrack(model, idx) orelse return;
            startTrack(model, fx, next_id);
        },
    }
}

fn stopAtEnd(model: *Model) void {
    model.playing = false;
    model.buffering = false;
    if (model.now_duration_ms > 0) model.elapsed_ms = model.now_duration_ms;
}

/// Another track in the playlist, never the current slot when there is
/// a choice. Uniform over the remaining indices.
fn pickShuffledPlaylistTrack(model: *Model, current_idx: usize) ?u8 {
    const len = model.queue_len;
    if (len == 0) return null;
    if (len == 1) return model.queue[0];
    model.shuffle_nonce +%= 1;
    var prng = std.Random.DefaultPrng.init(
        model.shuffle_nonce *% 0x9E3779B97F4A7C15 ^
            (@as(u64, model.queue[current_idx]) << 32) ^
            model.frame_ns ^
            (@as(u64, model.elapsed_ms) << 17),
    );
    const roll = prng.random().intRangeLessThan(usize, 0, len - 1);
    const next_idx = if (roll >= current_idx) roll + 1 else roll;
    return model.queue[next_idx];
}

/// Another track in the same album, never the current one when there is
/// a choice. Uniform over the remaining numbers.
fn pickShuffledAlbumTrack(model: *Model, current: Track) ?u8 {
    const count = model.tracksInAlbum(current.album);
    if (count == 0) return null;
    if (count == 1) return current.id;
    model.shuffle_nonce +%= 1;
    var prng = std.Random.DefaultPrng.init(
        model.shuffle_nonce *% 0x9E3779B97F4A7C15 ^
            (@as(u64, current.id) << 32) ^
            model.frame_ns ^
            (@as(u64, model.elapsed_ms) << 17),
    );
    const roll = prng.random().intRangeLessThan(usize, 0, count - 1);
    var number: u8 = @intCast(roll + 1);
    if (number >= current.number) number += 1;
    const next = model.userTrackInAlbumByNumber(current.album, number) orelse return null;
    return next.id;
}

/// Restart the current track when it is a few seconds in; otherwise the
/// previous track in the playlist (or album). Sequential mode does not
/// wrap past the first track; the looping modes (and shuffle) wrap.
fn previous(model: *Model, fx: *Effects) void {
    const track = model.nowTrack() orelse return;
    if (model.elapsed_ms > 3000) {
        model.elapsed_ms = 0;
        fx.seekAudio(0);
        return;
    }
    if (model.queueIndexOf(track.id)) |idx| {
        if (model.play_mode == .sequential and idx == 0) {
            model.elapsed_ms = 0;
            fx.seekAudio(0);
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
        return;
    }
    const prev_number: u8 = @intCast((@as(usize, track.number) + count - 2) % count + 1);
    const prev = model.userTrackInAlbumByNumber(track.album, prev_number) orelse return;
    startTrack(model, fx, prev.id);
}
