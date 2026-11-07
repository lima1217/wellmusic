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
const strings = @import("strings.zig");
pub const Lang = strings.Lang;
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
pub const max_user_tracks = 240;
pub const max_user_title = 128;
pub const max_user_path = 1024;
pub const max_library_store_bytes = 512 * 1024;

// `appendFmt` drops a line that does not fit, so the store ceiling must
// cover a library where every field is at its cap — otherwise a large
// library would silently persist truncated.
comptime {
    const id_field = 3 + 1; // "255" + tab
    const album_line = "album\t".len + id_field + (max_user_title + 1) * 2 + 6 + max_user_path + 1;
    const track_line = "track\t".len + id_field * 3 + (max_user_title + 1) * 2 + (max_user_path + 1) + 10 + 1;
    const worst = library_store_header.len + 1 + max_user_albums * album_line + max_user_tracks * track_line;
    if (worst > max_library_store_bytes) @compileError("max_library_store_bytes cannot hold a full library");
}
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
/// Background import: one `/bin/cp` at a time copies a picked file into
/// `media/`, so a large album never blocks the UI thread.
pub const import_spawn_key: u64 = 7;
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
    /// Up to two letters, or one CJK character, as UTF-8.
    initials_storage: [8]u8 = undefined,
    initials_len: usize = 0,
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
        return album.initials_storage[0..album.initials_len];
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
        const kept = metadata.utf8Prefix(value, max_user_title);
        @memcpy(album.title_storage[0..kept.len], kept);
        album.title_len = kept.len;
        scrubFieldSeparators(album.title_storage[0..kept.len]);
        album.refreshInitials();
    }

    pub fn setArtist(album: *UserAlbum, value: []const u8) void {
        const kept = metadata.utf8Prefix(value, max_user_title);
        @memcpy(album.artist_storage[0..kept.len], kept);
        album.artist_len = kept.len;
        scrubFieldSeparators(album.artist_storage[0..kept.len]);
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

    /// The placeholder on a cover-less album: the title's first letter
    /// plus the artist's ("AB" for "Abbey Road" by "Beatles"), or the
    /// title's first character alone when it is not Latin — one 晴 reads
    /// better than 晴 plus a stray letter. Whole UTF-8 sequences only: the
    /// old byte-wise version cut CJK titles into invalid bytes (tofu).
    fn refreshInitials(album: *UserAlbum) void {
        album.initials_len = initialsInto(&album.initials_storage, album.title(), album.artist());
    }
};

fn initialsInto(out: *[8]u8, title_text: []const u8, artist_text: []const u8) usize {
    const t = std.mem.trim(u8, title_text, " ");
    const a = std.mem.trim(u8, artist_text, " ");
    if (t.len == 0) return 0;
    const first_len = std.unicode.utf8ByteSequenceLength(t[0]) catch return 0;
    if (first_len > t.len) return 0;
    if (first_len > 1) {
        @memcpy(out[0..first_len], t[0..first_len]);
        return first_len;
    }
    out[0] = std.ascii.toUpper(t[0]);
    if (a.len > 0 and a[0] < 0x80 and std.ascii.isAlphanumeric(a[0])) {
        out[1] = std.ascii.toUpper(a[0]);
        return 2;
    }
    return 1;
}

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
        const kept = metadata.utf8Prefix(value, max_user_title);
        @memcpy(track.title_storage[0..kept.len], kept);
        track.title_len = kept.len;
        scrubFieldSeparators(track.title_storage[0..kept.len]);
    }

    pub fn setArtist(track: *UserTrack, value: []const u8) void {
        const kept = metadata.utf8Prefix(value, max_user_title);
        @memcpy(track.artist_storage[0..kept.len], kept);
        track.artist_len = kept.len;
        scrubFieldSeparators(track.artist_storage[0..kept.len]);
    }

    fn setPath(track: *UserTrack, value: []const u8) void {
        const len = @min(value.len, max_user_path);
        @memcpy(track.path_storage[0..len], value[0..len]);
        track.path_len = len;
    }
};

/// One picked file waiting for (or in) its background copy.
pub const ImportJob = struct {
    album_id: u8 = 0,
    source_storage: [max_user_path]u8 = undefined,
    source_len: usize = 0,

    pub fn source(job: *const ImportJob) []const u8 {
        return job.source_storage[0..job.source_len];
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


// ------------------------------------------------------------------- model

/// What happens at the end of the list (or the track). The list is the
/// playlist when the current track is in it; otherwise Play Next entries
/// are consumed FIFO, then album order. Independent of `shuffle`, which
/// only changes the ORDER the list plays in (Apple Music's two controls).
pub const Repeat = enum {
    /// Play the list once and stop after the last track.
    off,
    /// Wrap around the list.
    all,
    /// Replay the current track when it ends; Next / Previous still move
    /// through the list.
    one,
};

/// Shuffle remembers this many played tracks for Previous.
pub const shuffle_history_cap = 64;

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
/// One-shot follow-up poll aimed just past the track's expected end.
/// The 2 s cadence alone noticed a natural end up to 2 s late, which
/// was audible as silence between tracks; once a poll sees the end
/// inside the next interval, this lands a poll right after it.
pub const audio_end_timer_key: u64 = 44;
/// How far past the expected end the follow-up poll lands (the player
/// must already report stopped), and the retry step while it has not.
pub const audio_end_margin_ms: u64 = 40;

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
    /// Transport: shuffle on/off, and repeat off → all → one.
    toggle_shuffle,
    cycle_repeat,
    /// Speaker button: mute / restore the previous volume.
    toggle_mute,
    /// Cmd+Up / Cmd+Down.
    volume_step: enum { up, down },
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
    /// A transport command from the status-item menu, a media key, or the
    /// system's remote commands (Control Center, headphone buttons).
    /// `play` / `pause` are explicit so a repeated press never flips state.
    media_command: enum { toggle_play, play, pause, next, previous },
    /// Every audio playback report: the load acknowledgment, position
    /// ticks, the one completion, and failures. Tests and journals send
    /// these directly; the live player does not — see `audio_poll`.
    audio_event: native_sdk.EffectAudio,
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
    /// Probe one track's tags after launch (see `healNextTitle`).
    title_heal,
    /// One album cover decode after `library_hydrate` (or after import).
    /// Spread across presents so first paint stays light.
    cover_hydrate,
    /// The background `/bin/cp` for the head import job exited.
    import_copied: native_sdk.EffectExit,
    /// Files or folders dropped on the window (staged by main.zig).
    import_dropped,
    /// Album menu: remove the album and all its tracks (undoable).
    remove_album: u8,
    /// Notice bar: restore what the last removal took away.
    undo_remove,
    dismiss_notice,
    notice_expired: native_sdk.EffectTimer,
    /// Now-playing bar: open the playing album at the playing track.
    reveal_now_playing,
    /// Album page: turn shuffle on and play the album from a random track.
    shuffle_album: u8,
    /// Volume ramp step while pausing or resuming (see `Fade`).
    fade_tick: native_sdk.EffectTimer,
    /// Cmd+Backspace / Cmd+Shift+N on the selected track.
    remove_selected,
    queue_selected,
    /// Playlist row menu: reorder an entry.
    move_queued: struct { id: u8, move: QueueMove },
    /// Persist library writes (reads are sync at launch via `loadLibrarySync`).
    library_done: native_sdk.EffectFileResult,
    /// Persist / restore playback session (now, queue, mode, volume).
    session_done: native_sdk.EffectFileResult,
    /// The debounced session save after a volume drag or held volume key.
    session_save_due: native_sdk.EffectTimer,
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
        "audio_event",
        "queue_track",    "remove_track",   "edit_track",
        "edit_album",     "edit_title",     "edit_artist",
        "save_edit_track", "close_edit_track",
        "save_edit_album", "close_edit_album", "change_cover",
        "library_hydrate", "cover_hydrate", "title_heal",
        "import_copied",  "import_dropped", "remove_album",  "undo_remove",
        "notice_expired", "volume_step",    "dismiss_notice",
        "shuffle_album",  "fade_tick",      "remove_selected", "queue_selected",
        "move_queued",
        "library_done",   "cover_done",     "volume_changed",
        "toggle_queue",   "remove_queued",  "clear_queue",
        "media_command",
        "session_done",   "session_save_due",
        "toggle_add_menu", "close_add_menu",
    };
};

pub const Model = struct {
    // Source-of-truth state only; everything else is derived per rebuild.
    appearance: native_sdk.Appearance = .{},
    /// Light/dark preference for tokens. Defaults to system-follow so a
    /// fresh install matches the OS; `toggle_theme` locks light or dark.
    theme: ThemePreference = .system,
    open_album: ?u8 = null,
    /// SOURCE scroll offsets (album grid and album detail). The runtime
    /// owns the live offset while the user scrolls; these apply only when
    /// they change, and main.zig's HostShim copies the runtime offset back
    /// before navigation and on quit (`adoptRuntimeScroll`).
    grid_scroll: f32 = 0,
    detail_scroll: f32 = 0,
    /// Bumped on every album open / reveal: part of the detail scroll
    /// region's key, so each gets a fresh runtime offset.
    detail_scroll_epoch: u16 = 0,
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
    /// Transport: end-of-list behaviour and play order (see `Repeat`).
    /// Repeat-all matches the historic wrap-within-album advance.
    repeat: Repeat = .all,
    shuffle: bool = false,
    /// Mute keeps `volume` so unmuting restores it.
    muted: bool = false,
    /// UI language, picked from the system's preferred languages at
    /// launch (main.zig); English in tests.
    lang: Lang = .en,
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
    /// Shuffle: ids already played in the current pass, so every track
    /// plays once before any repeats.
    shuffle_played: std.StaticBitSet(256) = std.StaticBitSet(256).initEmpty(),
    /// Shuffle: ids in the order they played, for Previous.
    shuffle_history: [shuffle_history_cap]u8 = @splat(0),
    shuffle_history_len: usize = 0,
    /// Shuffle PRNG state. Model-owned so `update` stays a pure function
    /// of the model (replays pick the same order); main seeds it per launch.
    shuffle_rng: u64 = 0x9E3779B97F4A7C15,
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
    /// User-imported tracks across all albums. Cap is loud by design.
    user_tracks: [max_user_tracks]UserTrack = undefined,
    user_track_count: usize = 0,
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
    /// Bumped on every catalog change (`persistLibrary`), so platform
    /// glue can re-check derived needs — the CJK face — only when the
    /// catalog actually moved.
    library_revision: u32 = 0,
    /// Launch-time title heal, one track per present after covers.
    title_heal_pending: bool = false,
    title_heal_index: usize = 0,
    /// Background import queue: jobs `[import_head, import_len)` are
    /// waiting; while `import_inflight_id` is set, the head job is
    /// copying under that reserved track id.
    import_jobs: [max_user_tracks]ImportJob = undefined,
    import_head: usize = 0,
    import_len: usize = 0,
    import_inflight_id: ?u8 = null,
    /// Progress for the "Importing n / total" line; reset when drained.
    import_total: usize = 0,
    import_done: usize = 0,
    /// Tracks imported since the last library write (see
    /// `import_save_every`).
    import_unsaved: usize = 0,
    /// Outcome of the current import batch, reported when it drains.
    import_added: usize = 0,
    import_skipped: usize = 0,
    import_failed: usize = 0,
    /// Dropped or picked files that are not audio WellMusic plays.
    import_unsupported: usize = 0,
    /// Songs turned away because the library was at `max_user_tracks`.
    import_full: usize = 0,
    /// The notice line under the header (see `Notice`).
    notice: Notice = .none,
    notice_added: usize = 0,
    notice_skipped: usize = 0,
    notice_failed: usize = 0,
    notice_unsupported: usize = 0,
    notice_full: usize = 0,
    notice_removed: usize = 0,
    /// Serialized catalog from before the last removal (page_allocator);
    /// empty when there is nothing to undo.
    undo_snapshot: []u8 = &.{},
    /// `library_revision` right after that removal — undo only while it
    /// still matches.
    undo_revision: u32 = 0,
    /// Set while an undoable removal runs: keep media files on disk.
    defer_media_delete: bool = false,
    /// Consecutive tracks that failed to play (auto-skip bound).
    skip_streak: usize = 0,
    /// Title of the last track auto-skipped, for its notice.
    skipped_title_storage: [max_user_title]u8 = undefined,
    skipped_title_len: usize = 0,
    /// Pause / resume volume ramp in progress.
    fade: Fade = .none,
    fade_step: u8 = 0,

    /// Read by the ZIG-BUILT views (grid, detail, track rows), update
    /// logic, or main's launch wiring — never bound in markup — so
    /// opting them out keeps `native check`'s dead-state lint quiet
    /// without weakening it for real drift. The markup fragments bind
    /// the derived fns (`nowPlayingTitle`, `playPauseIcon`, ...) instead
    /// of these backing stores.
    pub const view_unbound = .{
        "open_album",      "grid_scroll",
        "detail_scroll",   "canvas_width",   "detail_scroll_epoch",
        "now",             "selected",       "playing",
        "repeat",          "shuffle",        "muted",          "lang",
        "elapsed_ms",      "frame_ns",       "now_duration_ms",
        "platform_duration_ms",
        "assets_missing",
        "audio_poll_armed",
        "queue_dropped",
        "shuffle_played",  "shuffle_history", "shuffle_history_len",
        "shuffle_rng",
        "volume",
        "appearance",      "theme",          "queue",          "queue_len",
        "editing_track",   "editing_album",  "edit_title_buffer",
        "edit_artist_buffer",
        "colorScheme",     "hasNowPlaying",
        "visibleAlbums",
        "albumCount",
        "user_albums",     "user_album_count",
        "user_tracks",     "user_track_count",
        "store_path_buffer", "store_path_len", "store_write_inflight",
        "session_path_buffer", "session_path_len",
        "media_dir_buffer", "media_dir_len",
        "session_write_inflight", "session_save_pending",
        "session_resume_track", "session_resume_elapsed_ms",
        "session_resume_playing",
        "audio_deferred",
        "library_hydrate_pending",
        "cover_hydrate_pending", "cover_hydrate_index",
        "library_revision", "title_heal_pending", "title_heal_index",
        "add_menu_open",
        "import_jobs",     "import_head",    "import_len",
        "import_inflight_id", "import_total", "import_done", "import_unsaved",
        "import_added",    "import_skipped", "import_failed",
        "import_unsupported", "import_full",
        "notice",          "notice_added",   "notice_skipped", "notice_failed",
        "notice_unsupported", "notice_full",
        "notice_removed",  "undo_snapshot",  "undo_revision",  "defer_media_delete",
        "skip_streak",     "skipped_title_storage", "skipped_title_len", "skippedTitle",
        "fade",            "fade_step",
        "noticeText",      "noticeCanUndo",  "effectiveVolume",
        "importStatus",
        "save_pending",
        "storePath",       "sessionPath",    "mediaDir",
        "editTitle",
        "albumDurationsKnown", "localizeDefaultNames",
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
        return model.str(switch (model.colorScheme()) {
            .light => .dark_mode,
            .dark => .light_mode,
        });
    }

    // Markup binds zero-argument fns, so each string the .native views
    // show gets a one-line accessor.
    pub fn strAddMusic(model: *const Model) []const u8 {
        return model.str(.add_music);
    }
    pub fn strNowPlaying(model: *const Model) []const u8 {
        return model.str(.now_playing);
    }
    pub fn strPlaybackControls(model: *const Model) []const u8 {
        return model.str(.playback_controls);
    }
    pub fn strPlaybackOptions(model: *const Model) []const u8 {
        return model.str(.playback_options);
    }
    pub fn strAddSong(model: *const Model) []const u8 {
        return model.str(.add_song);
    }
    pub fn strAddAlbum(model: *const Model) []const u8 {
        return model.str(.add_album);
    }
    pub fn strPreviousTrack(model: *const Model) []const u8 {
        return model.str(.previous_track);
    }
    pub fn strNextTrack(model: *const Model) []const u8 {
        return model.str(.next_track);
    }
    pub fn strPlayOrPause(model: *const Model) []const u8 {
        return model.str(.play_or_pause);
    }
    pub fn strShowNowPlaying(model: *const Model) []const u8 {
        return model.str(.show_now_playing);
    }
    pub fn strVolume(model: *const Model) []const u8 {
        return model.str(.volume);
    }
    pub fn strToggleQueue(model: *const Model) []const u8 {
        return model.str(.toggle_queue);
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

    /// Slider position: zero while muted, so the control tells the truth.
    pub fn volumeFraction(model: *const Model) f32 {
        return model.effectiveVolume();
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

    /// Sum of the album's known track durations (0 when none are known).
    pub fn albumDurationMs(model: *const Model, album_id: u8) u64 {
        var total: u64 = 0;
        for (model.user_tracks[0..model.user_track_count]) |*track| {
            if (track.album == album_id) total += track.duration_ms;
        }
        return total;
    }

    /// True when every song in the album has a known length, so the sum
    /// above is the album's real running time and not an undercount.
    pub fn albumDurationsKnown(model: *const Model, album_id: u8) bool {
        for (model.user_tracks[0..model.user_track_count]) |*track| {
            if (track.album == album_id and track.duration_ms == 0) return false;
        }
        return true;
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

    /// "Importing 3 / 12…" while the background import runs, else "".
    pub fn importStatus(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (model.import_total == 0) return "";
        return strings.importing(arena, model.lang, @min(model.import_done + 1, model.import_total), model.import_total);
    }

    /// The notice line: import progress first, else the current notice.
    pub fn noticeText(model: *const Model, arena: std.mem.Allocator) []const u8 {
        const progress = model.importStatus(arena);
        if (progress.len > 0) return progress;
        return switch (model.notice) {
            .none => "",
            .import_result => strings.importResult(arena, model.lang, .{
                .added = model.notice_added,
                .duplicate = model.notice_skipped,
                .failed = model.notice_failed,
                .unsupported = model.notice_unsupported,
                .full = model.notice_full,
                .capacity = max_user_tracks,
            }),
            .albums_full => strings.albumsFull(arena, model.lang, max_user_albums),
            .removed => strings.removedTracks(arena, model.lang, model.notice_removed),
            .skipped => strings.skippedTrack(arena, model.lang, model.skippedTitle()),
        };
    }

    pub fn skippedTitle(model: *const Model) []const u8 {
        return model.skipped_title_storage[0..model.skipped_title_len];
    }

    fn setSkippedTitle(model: *Model, title_text: []const u8) void {
        const kept = metadata.utf8Prefix(title_text, max_user_title);
        @memcpy(model.skipped_title_storage[0..kept.len], kept);
        model.skipped_title_len = kept.len;
    }

    pub fn noticeCanUndo(model: *const Model) bool {
        return model.import_total == 0 and canUndoRemoval(model);
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

    pub fn str(model: *const Model, key: strings.Key) []const u8 {
        return strings.text(model.lang, key);
    }

    /// Repeat button glyph: the one-track variant only for `.one`; `.off`
    /// shows the plain glyph unselected.
    pub fn repeatIcon(model: *const Model) []const u8 {
        return if (model.repeat == .one) "app:repeat-one" else "repeat";
    }

    pub fn repeatActive(model: *const Model) bool {
        return model.repeat != .off;
    }

    pub fn repeatOff(model: *const Model) bool {
        return model.repeat == .off;
    }

    pub fn shuffleOff(model: *const Model) bool {
        return !model.shuffle;
    }

    pub fn repeatLabel(model: *const Model) []const u8 {
        return model.str(switch (model.repeat) {
            .off => .mode_repeat_off,
            .all => .mode_repeat_all,
            .one => .mode_repeat_one,
        });
    }

    pub fn shuffleLabel(model: *const Model) []const u8 {
        return model.str(if (model.shuffle) .mode_shuffle_on else .mode_shuffle_off);
    }

    /// The level the player actually runs at.
    pub fn effectiveVolume(model: *const Model) f32 {
        return if (model.muted) 0 else std.math.clamp(model.volume, 0, 1);
    }

    pub fn volumeIcon(model: *const Model) []const u8 {
        return if (model.effectiveVolume() == 0) "app:volume-mute" else "volume";
    }

    pub fn muteLabel(model: *const Model) []const u8 {
        return model.str(if (model.muted) .unmute else .mute);
    }

    pub fn nowPlayingCover(model: *const Model) canvas.ImageId {
        const track = model.nowTrack() orelse return 0;
        return model.coverFor(track.album);
    }

    pub fn nowPlayingInitials(model: *const Model) []const u8 {
        const track = model.nowTrack() orelse return "";
        const album = model.userAlbumById(track.album) orelse return "";
        return album.initials();
    }

    /// The bar's first line doubles as the status line: the honest
    /// assets-not-prepared notice replaces the track title after a load
    /// failure, so the user is told what to run instead of hearing
    /// nothing.
    pub fn nowPlayingTitle(model: *const Model) []const u8 {
        if (model.assets_missing) return model.str(.cannot_play);
        const track = model.nowTrack() orelse return model.str(.nothing_playing);
        return track.title;
    }

    pub fn nowPlayingArtist(model: *const Model) []const u8 {
        if (model.assets_missing) return model.str(.cannot_play_hint);
        const track = model.nowTrack() orelse return model.str(.pick_to_start);
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
        const now_album: ?u8 = if (model.nowTrack()) |track| track.album else null;
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
                .now = now_album == album.id,
                .playing = now_album == album.id and model.playing,
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
            .artist = artist,
            .subtitle = switch (style) {
                .with_album => if (artist.len == 0)
                    album_title
                else
                    std.fmt.allocPrint(arena, "{s} — {s}", .{ artist, album_title }) catch "",
                .number_only => if (track.artist.len > 0) track.artist else "",
            },
            .duration = strings.songLength(arena, track.duration_ms),
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

    /// Lowest unused track id. Ids recycle after removal: a monotonic u8
    /// counter overflowed (a safety panic) on the 255th cumulative import
    /// and, restored from a library whose top id was 255, wrapped to 0 and
    /// refused every later import.
    fn freeTrackId(model: *const Model) ?u8 {
        var used = std.StaticBitSet(256).initEmpty();
        for (model.user_tracks[0..model.user_track_count]) |*track| used.set(track.id);
        return lowestFreeId(&used, first_user_track_id);
    }

    /// Lowest unused folder-album id. The Library id is reserved even
    /// while that album does not exist, so loose imports never land in a
    /// folder album. Low ids also keep cover image slots (ImageId ==
    /// album id) dense.
    fn freeAlbumId(model: *const Model) ?u8 {
        var used = std.StaticBitSet(256).initEmpty();
        used.set(imported_album_id);
        for (model.user_albums[0..model.user_album_count]) |*album| used.set(album.id);
        return lowestFreeId(&used, first_user_album_id);
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
        album.setTitle(model.str(.loose_album_title));
        album.setArtist(model.str(.loose_album_artist));
        album.year = 2026;
        model.user_albums[model.user_album_count] = album;
        model.user_album_count += 1;
        return true;
    }

    /// Libraries saved before the names were localized carry the English
    /// placeholders: the loose-songs album was "Library" by "My Music",
    /// and folder albums without a tag artist got "My Music" too. Swap in
    /// the current language's names (persisted with the next save).
    pub fn localizeDefaultNames(model: *Model) void {
        for (model.user_albums[0..model.user_album_count]) |*album| {
            if (album.id == imported_album_id and std.mem.eql(u8, album.title(), "Library")) {
                album.setTitle(model.str(.loose_album_title));
            }
            if (std.mem.eql(u8, album.artist(), "My Music")) {
                album.setArtist(if (album.id == imported_album_id) model.str(.loose_album_artist) else "");
            }
        }
    }

    /// Create a user album. Returns the new album id, or null when full.
    pub fn addUserAlbum(model: *Model, title: []const u8, artist: []const u8) ?u8 {
        if (model.user_album_count >= max_user_albums) return null;
        var album: UserAlbum = .{};
        album.id = model.freeAlbumId() orelse return null;
        album.setTitle(if (title.len > 0) title else "Album");
        album.setArtist(artist);
        album.year = 2026;
        model.user_albums[model.user_album_count] = album;
        model.user_album_count += 1;
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
        // An undoable removal keeps the files until it is committed.
        if (model.defer_media_delete) return;
        if (cover_len > 0) deleteManagedMediaFile(model, cover_buf[0..cover_len]);
        // Album ids recycle: the next album must not inherit this thumb.
        deleteCoverThumb(model, id);
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
        const id = model.freeTrackId() orelse return false;
        return model.insertUserTrack(id, album_id, path, name_path);
    }

    /// Insert under a caller-chosen free `id` — `importAudioFromSource`
    /// names the managed copy (`t{id}`) before the track exists.
    fn insertUserTrack(
        model: *Model,
        id: u8,
        album_id: u8,
        path: []const u8,
        name_path: []const u8,
    ) bool {
        if (path.len == 0 or path.len > max_user_path) return false;
        if (model.user_track_count >= max_user_tracks) return false;
        if (model.pathAlreadyImported(path)) return false;
        if (album_id == imported_album_id) {
            if (!model.ensureLibraryAlbum()) return false;
        } else if (model.userAlbumById(album_id) == null) {
            return false;
        }
        var track: UserTrack = .{};
        track.id = id;
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
        // First track in a folder album can rename a generic album from tags.
        if (album_id != imported_album_id and track.number == 1) {
            if (model.userAlbumByIdMut(album_id)) |album| {
                if (meta.album_len > 0) album.setTitle(meta.album[0..meta.album_len]);
                // The tag knows the artist; the parent-folder guess only
                // stands in when the files carry none.
                if (meta.artist_len > 0) album.setArtist(meta.artist[0..meta.artist_len]);
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
            if (healTrackTitle(track)) changed = true;
        }
        return changed;
    }

    /// One step of the launch-time heal: probe the next track that still
    /// needs it. Spread one per presented frame (`title_heal`) because
    /// tagless tracks never stop qualifying, so a single pass re-read
    /// every one of them inside the first frame on every launch.
    fn healNextTitle(model: *Model) bool {
        while (model.title_heal_index < model.user_track_count) {
            const track = &model.user_tracks[model.title_heal_index];
            model.title_heal_index += 1;
            if (!trackTitleIsFallback(track)) continue;
            return healTrackTitle(track);
        }
        model.title_heal_pending = false;
        return false;
    }

    fn trackTitleIsFallback(track: *const UserTrack) bool {
        const current = track.title();
        return current.len == 0 or std.mem.eql(u8, current, titleFromPath(track.path()));
    }

    fn healTrackTitle(track: *UserTrack) bool {
        if (!trackTitleIsFallback(track)) return false;
        const meta = metadata.probeFile(track.path());
        var changed = false;
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
        // Ids recycle: a later import must not inherit "already played".
        model.shuffle_played.unset(id);
        if (path_len > 0 and !model.defer_media_delete) deleteManagedMediaFile(model, path_buf[0..path_len]);
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
        appendFmt(buffer, &len, "repeat\t{s}\n", .{@tagName(model.repeat)});
        appendFmt(buffer, &len, "shuffle\t{d}\n", .{@as(u8, if (model.shuffle) 1 else 0)});
        appendFmt(buffer, &len, "muted\t{d}\n", .{@as(u8, if (model.muted) 1 else 0)});
        appendFmt(buffer, &len, "theme\t{s}\n", .{themePreferenceName(model.theme)});
        appendFmt(buffer, &len, "volume\t{d:.4}\n", .{std.math.clamp(model.volume, 0, 1)});
        appendFmt(buffer, &len, "queue_open\t{d}\n", .{@as(u8, if (model.queue_open) 1 else 0)});
        appendFmt(buffer, &len, "open_album\t{d}\n", .{model.open_album orelse 0});
        appendFmt(buffer, &len, "grid_scroll\t{d:.1}\n", .{model.grid_scroll});
        appendFmt(buffer, &len, "detail_scroll\t{d:.1}\n", .{model.detail_scroll});
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
        var repeat: Repeat = .all;
        var shuffle = false;
        var muted = false;
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
                // Sessions from the single play-mode button.
                const text = parts.next() orelse return false;
                const legacy = parseLegacyPlayMode(text) orelse return false;
                repeat = legacy.repeat;
                shuffle = legacy.shuffle;
            } else if (std.mem.eql(u8, key, "repeat")) {
                const text = parts.next() orelse return false;
                repeat = std.meta.stringToEnum(Repeat, text) orelse return false;
            } else if (std.mem.eql(u8, key, "shuffle")) {
                const text = parts.next() orelse return false;
                shuffle = (std.fmt.parseInt(u8, text, 10) catch return false) != 0;
            } else if (std.mem.eql(u8, key, "muted")) {
                const text = parts.next() orelse return false;
                muted = (std.fmt.parseInt(u8, text, 10) catch return false) != 0;
            } else if (std.mem.eql(u8, key, "theme")) {
                const text = parts.next() orelse return false;
                theme = parseThemePreference(text) orelse return false;
            } else if (std.mem.eql(u8, key, "volume")) {
                const text = parts.next() orelse return false;
                volume = std.fmt.parseFloat(f32, text) catch return false;
            } else if (std.mem.eql(u8, key, "queue_open")) {
                const text = parts.next() orelse return false;
                queue_open = (std.fmt.parseInt(u8, text, 10) catch return false) != 0;
            } else if (std.mem.eql(u8, key, "open_album") or std.mem.eql(u8, key, "grid_scroll") or std.mem.eql(u8, key, "detail_scroll")) {
                // View keys apply before the first frame (`applySessionView`).
                continue;
            } else if (std.mem.eql(u8, key, "queue")) {
                while (parts.next()) |id_text| {
                    if (id_text.len == 0) continue;
                    if (queue_len >= max_queue) break;
                    queue_buf[queue_len] = std.fmt.parseInt(u8, id_text, 10) catch return false;
                    queue_len += 1;
                }
            } else return false;
        }
        model.repeat = repeat;
        model.shuffle = shuffle;
        model.muted = muted;
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

    /// The page the user left: the open album (if it still exists) and
    /// both scroll offsets. Unknown or malformed lines are ignored.
    /// Copy the runtime-owned scroll offsets into the model. Writing the
    /// value the runtime already shows changes nothing on screen, but it
    /// makes the model the truth again for session save and for the
    /// grid region that is rebuilt after leaving an album page.
    pub fn adoptRuntimeScroll(model: *Model, grid: ?f32, detail: ?f32) void {
        if (grid) |offset| model.grid_scroll = @max(0, offset);
        if (detail) |offset| model.detail_scroll = @max(0, offset);
    }

    pub fn applySessionView(model: *Model, bytes: []const u8) void {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        const header = lines.next() orelse return;
        if (!std.mem.eql(u8, std.mem.trim(u8, header, " \r"), session_store_header)) return;
        while (lines.next()) |raw| {
            var parts = std.mem.splitScalar(u8, std.mem.trim(u8, raw, " \r"), '\t');
            const key = parts.next() orelse continue;
            const value = parts.next() orelse continue;
            if (std.mem.eql(u8, key, "open_album")) {
                const id = std.fmt.parseInt(u8, value, 10) catch continue;
                if (id != 0 and model.userAlbumById(id) != null) model.open_album = id;
            } else if (std.mem.eql(u8, key, "grid_scroll")) {
                model.grid_scroll = @max(0, std.fmt.parseFloat(f32, value) catch continue);
            } else if (std.mem.eql(u8, key, "detail_scroll")) {
                model.detail_scroll = @max(0, std.fmt.parseFloat(f32, value) catch continue);
            }
        }
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
        var legacy_cover: ?[]const u8 = null;
        var skipped: usize = 0;
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \r");
            if (line.len == 0) continue;
            // One malformed record (hand edit, truncated write) drops that
            // record, not the library: failing here left a partial model
            // that the next save would persist over the good file.
            if (!model.restoreRecord(version, line, &legacy_cover)) skipped += 1;
        }
        // A skipped track leaves a hole in its album's numbering, and the
        // detail view walks numbers 1..count.
        if (skipped > 0) {
            for (model.user_albums[0..model.user_album_count]) |*album| model.renumberAlbumTracks(album.id);
        }
        model.localizeDefaultNames();
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

    /// Parse one library record into the model. False means the record
    /// was malformed or conflicts with one already restored, and is skipped.
    fn restoreRecord(model: *Model, version: u8, line: []const u8, legacy_cover: *?[]const u8) bool {
        var parts = std.mem.splitScalar(u8, line, '\t');
        const kind = parts.next() orelse return false;
        if (std.mem.eql(u8, kind, "cover")) {
            // v1/v2 Library cover line.
            const path = parts.next() orelse return false;
            if (parts.next() != null) return false;
            if (path.len == 0 or path.len > max_user_path) return false;
            legacy_cover.* = path;
            return true;
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
            if (model.userAlbumById(id) != null) return false;
            var album: UserAlbum = .{};
            album.id = id;
            album.year = year;
            album.setTitle(title);
            album.setArtist(artist);
            if (cover_path.len > 0) album.setCoverPath(cover_path);
            model.user_albums[model.user_album_count] = album;
            model.user_album_count += 1;
            return true;
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
        if (model.userTrackById(id) != null) return false;
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
    /// The loaded track belongs to this album (playing or paused).
    now: bool = false,
    playing: bool = false,
};

pub const TrackRow = struct {
    id: u8,
    number: []const u8,
    title: []const u8,
    subtitle: []const u8,
    /// The song's own artist, else its album's (for spoken labels).
    artist: []const u8 = "",
    duration: []const u8,
    /// This track is loaded in the now-playing bar (playing or paused).
    now: bool,
    playing: bool,
    /// This track is the SELECTION (accent row) — see `Model.selected`.
    selected: bool,
    /// User-imported tracks can be removed from the library.
    removable: bool,
};

/// The library store is tab/newline delimited: a tag or edit carrying
/// either would split its record on the next restore.
fn scrubFieldSeparators(bytes: []u8) void {
    for (bytes) |*byte| {
        if (byte.* == '\t' or byte.* == '\n' or byte.* == '\r') byte.* = ' ';
    }
}

fn lowestFreeId(used: *const std.StaticBitSet(256), first: u8) ?u8 {
    var id: usize = first;
    while (id < 256) : (id += 1) {
        if (!used.isSet(id)) return @intCast(id);
    }
    return null;
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

/// "Artist/Album/" is the common rip layout, so the parent folder is a
/// fair first guess at the artist — unless it is a place, not a person.
/// "" (no artist) beats a wrong one; the first song's tag overrides this.
fn albumArtistFromDir(dir_path: []const u8) []const u8 {
    const parent = std.fs.path.dirname(dir_path) orelse return "";
    const name = std.fs.path.basename(parent);
    const places = [_][]const u8{
        "/",        "Volumes",   "Users",  "home",   "Music",   "iTunes",
        "Media",    "Desktop",   "Downloads", "Documents", "Movies", "tmp",
        "音乐",     "下载",      "桌面",   "文稿",   "Music Library",
    };
    if (name.len == 0) return "";
    for (places) |place| {
        if (std.ascii.eqlIgnoreCase(name, place)) return "";
    }
    // A user's home folder (/Users/<name>) is a person, but not the artist.
    if (std.fs.path.dirname(parent)) |grand| {
        if (std.mem.eql(u8, std.fs.path.basename(grand), "Users")) return "";
    }
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
    model.library_revision +%= 1;
    writeLibrary(model, fx);
}

/// Write the catalog as it is now. Separate from `persistLibrary` so the
/// flush of a save queued behind an in-flight write is not counted as a
/// second catalog change — that bump withdrew Undo after two quick
/// removals.
fn writeLibrary(model: *Model, fx: *Effects) void {
    if (model.store_path_len == 0) return;
    if (model.store_write_inflight) {
        model.save_pending = true;
        return;
    }
    // Heap scratch: a full-capacity store is too large for the update
    // stack. `writeFile` copies the bytes before returning.
    const buffer = std.heap.page_allocator.alloc(u8, max_library_store_bytes) catch return;
    defer std.heap.page_allocator.free(buffer);
    fx.writeFile(.{
        .key = library_write_key,
        .path = model.storePath(),
        .bytes = model.serializeLibrary(buffer),
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
    const len: usize = @intCast(size);
    const buffer = std.heap.page_allocator.alloc(u8, len) catch return;
    defer std.heap.page_allocator.free(buffer);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const n = reader.interface.readSliceShort(buffer) catch return;
    if (n != len) return;
    _ = model.restoreLibrary(buffer);
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
    if (migrateExternalMedia(model)) persistLibrary(model, fx);
    model.title_heal_index = 0;
    model.title_heal_pending = model.user_track_count > 0;
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

/// Volume drags and held volume keys change the session many times a
/// second; serializing and writing it on each step bought nothing. Every
/// call restarts this one-shot (same key replaces), so the save lands once
/// the input settles. A quit inside the window is covered by
/// `saveSessionNow`.
pub const session_save_timer_key: u64 = 47;
const session_save_settle_ms: u64 = 400;

fn persistSessionSoon(fx: *Effects) void {
    fx.startTimer(.{
        .key = session_save_timer_key,
        .interval_ms = session_save_settle_ms,
        .mode = .one_shot,
        .on_fire = Effects.timerMsg(.session_save_due),
    });
}

fn requestSessionLoad(model: *Model, fx: *Effects) void {
    if (model.session_path_len == 0) return;
    fx.readFile(.{
        .key = session_read_key,
        .path = model.sessionPath(),
        .on_result = Effects.fileMsg(.session_done),
    });
}

const LegacyPlayMode = struct { repeat: Repeat, shuffle: bool };

fn parseLegacyPlayMode(name: []const u8) ?LegacyPlayMode {
    if (std.mem.eql(u8, name, "list_loop")) return .{ .repeat = .all, .shuffle = false };
    if (std.mem.eql(u8, name, "single_loop")) return .{ .repeat = .one, .shuffle = false };
    if (std.mem.eql(u8, name, "shuffle")) return .{ .repeat = .all, .shuffle = true };
    if (std.mem.eql(u8, name, "sequential")) return .{ .repeat = .off, .shuffle = false };
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
    if (libraryHasFile(model, source)) return false;
    if (model.user_track_count >= max_user_tracks) return false;
    if (album_id == imported_album_id) {
        if (!model.ensureLibraryAlbum()) return false;
    } else if (model.userAlbumById(album_id) == null) {
        return false;
    }
    const id = model.freeTrackId() orelse return false;
    var dest_buf: [max_user_path]u8 = undefined;
    const dest = mediaDestPath(model, 't', id, source, &dest_buf) orelse return false;
    if (model.pathAlreadyImported(dest)) return false;
    if (!copySourceToManagedPath(source, dest)) return false;
    // Title fallback must use the original source basename ("Song.mp3"),
    // never the managed copy ("t1.mp3").
    if (!model.insertUserTrack(id, album_id, dest, source)) {
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
    deleteCoverThumb(model, album_id);
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

/// True when `source` is already in the library: the same path, or the
/// same bytes as a managed copy. Managed copies are renamed `t{id}`, so
/// comparing paths alone let the same file be imported again and again.
fn libraryHasFile(model: *const Model, source: []const u8) bool {
    if (model.pathAlreadyImported(source)) return true;
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const size = fileSizeAt(io, source) orelse return false;
    for (model.user_tracks[0..model.user_track_count]) |*track| {
        const other = fileSizeAt(io, track.path()) orelse continue;
        if (other != size) continue;
        if (sameFileContents(io, source, track.path())) return true;
    }
    return false;
}

fn fileSizeAt(io: std.Io, path: []const u8) ?u64 {
    if (!std.fs.path.isAbsolute(path)) return null;
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    return stat.size;
}

fn sameFileContents(io: std.Io, a_path: []const u8, b_path: []const u8) bool {
    var a = std.Io.Dir.openFileAbsolute(io, a_path, .{}) catch return false;
    defer a.close(io);
    var b = std.Io.Dir.openFileAbsolute(io, b_path, .{}) catch return false;
    defer b.close(io);
    var a_buffer: [4096]u8 = undefined;
    var b_buffer: [4096]u8 = undefined;
    var a_reader = a.reader(io, &a_buffer);
    var b_reader = b.reader(io, &b_buffer);
    var a_chunk: [16 * 1024]u8 = undefined;
    var b_chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const a_len = a_reader.interface.readSliceShort(&a_chunk) catch return false;
        const b_len = b_reader.interface.readSliceShort(&b_chunk) catch return false;
        if (a_len != b_len) return false;
        if (!std.mem.eql(u8, a_chunk[0..a_len], b_chunk[0..b_len])) return false;
        if (a_len < a_chunk.len) return true;
    }
}

/// Add a picked file to the library. Without a media dir (unit tests)
/// it registers in place, synchronously; otherwise it queues a
/// background copy. False when it is a duplicate or the library (plus
/// the queue) is full.
pub fn queueImport(model: *Model, album_id: u8, source: []const u8) bool {
    if (model.mediaDir().len == 0) {
        const added = importAudioFromSource(model, album_id, source);
        if (added) model.import_added += 1 else model.import_skipped += 1;
        return added;
    }
    if (source.len == 0 or source.len > max_user_path) {
        model.import_failed += 1;
        return false;
    }
    const waiting = model.import_len - model.import_head;
    if (model.user_track_count + waiting >= max_user_tracks or model.import_len >= max_user_tracks) {
        model.import_full += 1;
        return false;
    }
    for (model.import_jobs[model.import_head..model.import_len]) |*job| {
        if (std.mem.eql(u8, job.source(), source)) {
            model.import_skipped += 1;
            return false;
        }
    }
    if (libraryHasFile(model, source)) {
        model.import_skipped += 1;
        return false;
    }
    const job = &model.import_jobs[model.import_len];
    job.* = .{ .album_id = album_id };
    @memcpy(job.source_storage[0..source.len], source);
    job.source_len = source.len;
    model.import_len += 1;
    model.import_total += 1;
    return true;
}

/// Start the next background copy when none is running; when the queue
/// has drained, tidy up and reset progress.
pub fn pumpImport(model: *Model, fx: *Effects) void {
    while (model.import_inflight_id == null and model.import_head < model.import_len) {
        if (startImportCopy(model, fx, &model.import_jobs[model.import_head])) return;
        model.import_head += 1;
        model.import_done += 1;
        model.import_failed += 1;
    }
    if (model.import_inflight_id == null) finishImport(model, fx);
}

fn startImportCopy(model: *Model, fx: *Effects, job: *const ImportJob) bool {
    if (model.user_track_count >= max_user_tracks) return false;
    if (job.album_id == imported_album_id) {
        if (!model.ensureLibraryAlbum()) return false;
    } else if (model.userAlbumById(job.album_id) == null) {
        return false;
    }
    const id = model.freeTrackId() orelse return false;
    var dest_buf: [max_user_path]u8 = undefined;
    const dest = mediaDestPath(model, 't', id, job.source(), &dest_buf) orelse return false;
    if (!ensureMediaDir(model)) return false;
    fx.spawn(.{
        .key = import_spawn_key,
        .argv = &.{ "/bin/cp", "-f", "--", job.source(), dest },
        .output = .collect,
        .on_exit = Effects.exitMsg(.import_copied),
    });
    model.import_inflight_id = id;
    return true;
}

fn ensureMediaDir(model: *const Model) bool {
    const root = model.mediaDir();
    if (!std.fs.path.isAbsolute(root)) return false;
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().createDirPath(threaded.io(), root) catch return false;
    return true;
}

/// The head job's copy exited: register the track on success, discard
/// the partial copy otherwise, then move on to the next job.
fn finishImportCopy(model: *Model, fx: *Effects, exit: native_sdk.EffectExit) void {
    if (exit.key != import_spawn_key) return;
    const id = model.import_inflight_id orelse return;
    model.import_inflight_id = null;
    const job = &model.import_jobs[model.import_head];
    model.import_head += 1;
    model.import_done += 1;
    var dest_buf: [max_user_path]u8 = undefined;
    if (mediaDestPath(model, 't', id, job.source(), &dest_buf)) |dest| {
        const copied = exit.reason == .exited and exit.code == 0;
        if (copied and model.insertUserTrack(id, job.album_id, dest, job.source())) {
            model.import_added += 1;
            // The catalog changed now (Undo / CJK-face checks read the
            // revision), but the write is batched: re-serializing the
            // whole library per copied file was ~350 KB of work each at
            // capacity. A quit mid-batch is flushed by `saveLibraryNow`.
            model.library_revision +%= 1;
            model.import_unsaved += 1;
            if (model.import_unsaved >= import_save_every) {
                model.import_unsaved = 0;
                writeLibrary(model, fx);
            }
        } else {
            model.import_failed += 1;
            deleteManagedMediaFile(model, dest);
        }
    }
    pumpImport(model, fx);
}

/// Library writes during a background import: one per this many copied
/// files, plus one when the queue drains.
const import_save_every: usize = 8;

fn finishImport(model: *Model, fx: *Effects) void {
    if (model.import_unsaved > 0) {
        model.import_unsaved = 0;
        writeLibrary(model, fx);
    }
    // Report the batch, including one where every file was a duplicate.
    const problems = model.import_skipped + model.import_failed + model.import_unsupported + model.import_full;
    if (model.import_added + problems > 0) {
        if (model.notice == .removed) commitRemoval(model);
        model.notice_added = model.import_added;
        model.notice_skipped = model.import_skipped;
        model.notice_failed = model.import_failed;
        model.notice_unsupported = model.import_unsupported;
        model.notice_full = model.import_full;
        model.import_added = 0;
        model.import_skipped = 0;
        model.import_failed = 0;
        model.import_unsupported = 0;
        model.import_full = 0;
        showNotice(model, fx, .import_result, if (problems > 0) notice_import_problem_ms else notice_import_ms);
    }
    if (model.import_total == 0) return;
    // An album whose every copy failed (or a Library album created for a
    // batch that never landed) would sit hidden and hold a slot.
    var removed = false;
    var i: usize = 0;
    while (i < model.user_album_count) {
        const id = model.user_albums[i].id;
        if (model.tracksInAlbum(id) == 0) {
            model.removeUserAlbum(id);
            removed = true;
        } else {
            i += 1;
        }
    }
    if (removed) persistLibrary(model, fx);
    model.import_head = 0;
    model.import_len = 0;
    model.import_total = 0;
    model.import_done = 0;
}

fn pickAndImportMusic(model: *Model, fx: *Effects) void {
    const services = fx.services orelse return;
    var buffer: [native_sdk.platform.max_dialog_paths_bytes]u8 = undefined;
    const result = services.showOpenDialog(.{
        .title = model.str(.dialog_add_music),
        .filters = &.{
            .{ .name = model.str(.dialog_audio), .extensions = &.{ "mp3", "m4a", "wav", "aac", "flac", "ogg" } },
            .{ .name = model.str(.dialog_all_files), .extensions = &.{ "*" } },
        },
        .allow_multiple = true,
    }, &buffer) catch return;
    if (result.count == 0) return;
    var added: u32 = 0;
    var paths = std.mem.splitScalar(u8, result.paths, '\n');
    while (paths.next()) |path| {
        const trimmed = std.mem.trim(u8, path, " \r");
        if (trimmed.len == 0) continue;
        if (!isAudioPath(trimmed)) {
            model.import_unsupported += 1;
            continue;
        }
        if (queueImport(model, imported_album_id, trimmed)) added += 1;
    }
    if (added > 0) persistLibrary(model, fx);
    pumpImport(model, fx);
}

fn pickAndImportAlbum(model: *Model, fx: *Effects) void {
    const services = fx.services orelse return;
    var buffer: [native_sdk.platform.max_dialog_paths_bytes]u8 = undefined;
    const result = services.showOpenDialog(.{
        .title = model.str(.dialog_import_album),
        .allow_directories = true,
        .allow_multiple = false,
    }, &buffer) catch return;
    if (result.count == 0) return;
    var paths = std.mem.splitScalar(u8, result.paths, '\n');
    const dir_path = while (paths.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \r");
        if (trimmed.len > 0) break trimmed;
    } else return;
    importAlbumDir(model, fx, dir_path);
}

/// Import a folder as a new album (dialog pick or window drop).
fn importAlbumDir(model: *Model, fx: *Effects, dir_path: []const u8) void {
    if (dir_path.len > max_user_path) return;

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    // ~240 KiB at full capacity: heap, not the update stack.
    const audio_paths = std.heap.page_allocator.alloc([max_user_path]u8, max_user_tracks) catch return;
    defer std.heap.page_allocator.free(audio_paths);
    var audio_lens: [max_user_tracks]usize = undefined;
    var audio_count: usize = 0;
    var cover_path_buf: [max_user_path]u8 = undefined;
    var cover_path_len: usize = 0;
    var other_count: usize = 0;

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
        if (!isAudioExtension(ext_body)) {
            // Hidden files (.DS_Store) and images are not songs anyone
            // expected to add; anything else is worth saying no to.
            if (entry.name.len > 0 and entry.name[0] != '.' and !isImageExtension(ext_body)) other_count += 1;
            continue;
        }
        if (audio_count >= max_user_tracks) {
            model.import_full += 1;
            continue;
        }
        var joined_buf: [max_user_path]u8 = undefined;
        const joined = std.fmt.bufPrint(&joined_buf, "{s}{c}{s}", .{ dir_path, std.fs.path.sep, entry.name }) catch continue;
        @memcpy(audio_paths[audio_count][0..joined.len], joined);
        audio_lens[audio_count] = joined.len;
        audio_count += 1;
    }

    if (audio_count == 0) {
        // A folder with no songs in it used to do nothing at all. Say so:
        // "No songs added: 3 unsupported files" (or just "No songs added").
        model.import_unsupported += other_count;
        if (other_count == 0) {
            showNotice(model, fx, .import_result, notice_import_problem_ms);
            model.notice_added = 0;
            model.notice_skipped = 0;
            model.notice_failed = 0;
            model.notice_unsupported = 0;
            model.notice_full = 0;
        }
        pumpImport(model, fx);
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
        showNotice(model, fx, .albums_full, notice_import_problem_ms);
        return;
    };

    var added: u32 = 0;
    for (order[0..audio_count]) |idx| {
        const path = audio_paths[idx][0..audio_lens[idx]];
        if (queueImport(model, album_id, path)) added += 1;
    }

    if (added == 0) {
        model.removeUserAlbum(album_id);
        // Still report it: "skipped 12 already in the library".
        pumpImport(model, fx);
        return;
    }

    if (cover_path_len > 0) {
        if (importCoverFromSource(model, album_id, cover_path_buf[0..cover_path_len])) {
            requestCoverLoad(model, fx, album_id);
        }
    }

    // Rows appear as their copies land; an album whose every copy fails
    // is dropped when the queue drains.
    model.open_album = album_id;
    model.detail_scroll = 0;
    persistLibrary(model, fx);
    pumpImport(model, fx);
}

fn pickAndSetCover(model: *Model, fx: *Effects, album_id: u8) void {
    if (model.userAlbumById(album_id) == null) return;
    const services = fx.services orelse return;
    var buffer: [native_sdk.platform.max_dialog_paths_bytes]u8 = undefined;
    const result = services.showOpenDialog(.{
        .title = model.str(.dialog_choose_cover),
        .filters = &.{
            .{ .name = model.str(.dialog_images), .extensions = &.{ "png", "jpg", "jpeg", "webp", "gif" } },
            .{ .name = model.str(.dialog_all_files), .extensions = &.{ "*" } },
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

/// Load an album's cover unless it is already registered. Every track
/// start asks, so without this check each song change re-read (and,
/// before thumbs, re-decoded) the cover on the UI thread. An explicit
/// cover change goes through `loadCoverFromPath` directly.
fn requestCoverLoad(model: *Model, fx: *Effects, album_id: u8) void {
    if (model.coverFor(album_id) != 0) return;
    _ = loadCoverFromPath(model, fx, album_id);
}

/// True when any catalog string needs a CJK-capable face. Used at boot
/// to skip the system CJK face for Latin-only libraries, and after
/// each catalog change to register it late (main.zig `HostShim`).
/// The CJK face is needed when the UI itself speaks Chinese, or when any
/// catalog string is CJK. Checking the catalog alone left a Chinese UI over
/// a Latin-only library rendering every label as tofu.
pub fn needsCjkFont(model: *const Model) bool {
    return model.lang == .zh or libraryNeedsCjkFont(model);
}

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

fn releaseCoverDecodeScratch() void {
    if (cover_decode_scratch.len == 0) return;
    std.heap.page_allocator.free(cover_decode_scratch);
    cover_decode_scratch = &.{};
}

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
    fx.setAudioVolume(model.effectiveVolume());
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
    fx.setAudioVolume(model.effectiveVolume());
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
    // A valid thumb needs only the cover's size, not its (up to 32 MiB)
    // bytes.
    if (coverFileSize(album.coverPath())) |size| {
        if (registerCoverThumb(model, fx, album_id, size)) return true;
    }
    const encoded = readCoverFileBytes(album.coverPath()) orelse {
        album.cover = 0;
        return false;
    };
    defer std.heap.page_allocator.free(encoded);
    return registerCoverEncoded(model, fx, album_id, encoded);
}

// ---------------------------------------------------------------- notices

/// The one-line notice under the header: an import's result, or a
/// removal with Undo. Clears itself after a few seconds.
pub const Notice = enum { none, import_result, removed, skipped, albums_full };
pub const notice_timer_key: u64 = 45;
/// A clean add reads at a glance; one that left songs out carries reasons
/// and needs time to read (WCAG 2.2.1: give people enough time). Undo gets
/// ten seconds — long enough to notice a slip, short enough that the
/// removal does not linger. Every notice can also be dismissed.
const notice_import_ms: u64 = 5000;
const notice_import_problem_ms: u64 = 12000;
const notice_removed_ms: u64 = 10000;

fn showNotice(model: *Model, fx: *Effects, kind: Notice, duration_ms: u64) void {
    // A notice replacing the removal's Undo makes that removal final.
    if (model.notice == .removed and kind != .removed) commitRemoval(model);
    model.notice = kind;
    fx.startTimer(.{
        .key = notice_timer_key,
        .interval_ms = duration_ms,
        .mode = .one_shot,
        .on_fire = Effects.timerMsg(.notice_expired),
    });
}

fn clearNotice(model: *Model, fx: *Effects) void {
    if (model.notice == .removed) commitRemoval(model);
    model.notice = .none;
    fx.cancelTimer(notice_timer_key);
}

// ------------------------------------------------------------ undo remove

/// Snapshot the catalog before a removal so Undo can restore it. Media
/// files stay on disk until the removal is committed.
fn beginUndoableRemoval(model: *Model) void {
    commitRemoval(model);
    const scratch = std.heap.page_allocator.alloc(u8, max_library_store_bytes) catch return;
    defer std.heap.page_allocator.free(scratch);
    const bytes = model.serializeLibrary(scratch);
    model.undo_snapshot = std.heap.page_allocator.dupe(u8, bytes) catch &.{};
    model.defer_media_delete = true;
}

fn endUndoableRemoval(model: *Model, fx: *Effects, removed: usize) void {
    model.defer_media_delete = false;
    persistLibrary(model, fx);
    model.undo_revision = model.library_revision;
    model.notice_removed = removed;
    showNotice(model, fx, .removed, notice_removed_ms);
}

/// Make the last removal final: delete the media it left behind. Only
/// files the snapshot referenced and the live catalog no longer does are
/// touched — never a sweep of the media directory.
pub fn commitRemoval(model: *Model) void {
    if (model.undo_snapshot.len == 0) return;
    const snapshot = model.undo_snapshot;
    model.undo_snapshot = &.{};
    defer std.heap.page_allocator.free(snapshot);
    const before = std.heap.page_allocator.create(Model) catch return;
    defer std.heap.page_allocator.destroy(before);
    before.* = .{};
    before.setMediaDir(model.mediaDir());
    if (!before.restoreLibrary(snapshot)) return;
    for (before.user_tracks[0..before.user_track_count]) |*track| {
        if (model.pathAlreadyImported(track.path())) continue;
        deleteManagedMediaFile(model, track.path());
    }
    for (before.user_albums[0..before.user_album_count]) |*album| {
        if (model.userAlbumById(album.id)) |live| {
            if (std.mem.eql(u8, live.coverPath(), album.coverPath())) continue;
        } else {
            deleteCoverThumb(model, album.id);
        }
        if (album.cover_path_len > 0) deleteManagedMediaFile(model, album.coverPath());
    }
}

/// Undo is offered only while nothing else changed the catalog since the
/// removal; restoring the snapshot then loses nothing.
pub fn canUndoRemoval(model: *const Model) bool {
    return model.notice == .removed and model.undo_snapshot.len > 0 and model.library_revision == model.undo_revision;
}

fn undoRemoval(model: *Model, fx: *Effects) void {
    if (!canUndoRemoval(model)) return;
    const snapshot = model.undo_snapshot;
    model.undo_snapshot = &.{};
    defer std.heap.page_allocator.free(snapshot);
    _ = model.restoreLibrary(snapshot);
    persistLibrary(model, fx);
    // Restored albums come back with `cover = 0`; their thumbs are still
    // on disk, so the trickle re-registers them cheaply.
    armCoverHydrate(model);
    model.notice = .none;
    fx.cancelTimer(notice_timer_key);
}

const RemovalEffects = struct { stopped: bool = false, queue_changed: bool = false };

fn removeTrackTracked(model: *Model, id: u8, effects: *RemovalEffects) bool {
    if (model.now == id) effects.stopped = true;
    if (model.queueIndexOf(id) != null) effects.queue_changed = true;
    if (!model.removeUserTrack(id)) return false;
    if (model.editing_track == id) model.cancelEditTrack();
    return true;
}

fn finishRemoval(model: *Model, fx: *Effects, effects: RemovalEffects, removed: usize) void {
    if (effects.stopped) {
        fx.stopAudio();
        syncNowPlaying(model);
    }
    // Ids recycle, so a stale queue entry in session.txt would resurrect
    // as whichever track next takes this id.
    if (effects.stopped or effects.queue_changed) persistSession(model, fx);
    endUndoableRemoval(model, fx, removed);
}

fn removeAlbum(model: *Model, fx: *Effects, album_id: u8) void {
    if (model.userAlbumById(album_id) == null) return;
    beginUndoableRemoval(model);
    var effects: RemovalEffects = .{};
    var removed: usize = 0;
    while (true) {
        const id = for (model.user_tracks[0..model.user_track_count]) |*track| {
            if (track.album == album_id) break track.id;
        } else break;
        if (!removeTrackTracked(model, id, &effects)) break;
        removed += 1;
    }
    // An album with no tracks left was already dropped by the last
    // removal; an empty one is dropped here.
    model.removeUserAlbum(album_id);
    if (model.editing_album == album_id) model.cancelEditAlbum();
    finishRemoval(model, fx, effects, removed);
}

// ------------------------------------------------------------ now playing

/// Rough offset of the first track row in the album detail page (content
/// padding + back row + gaps + the 200pt cover block) and the row height,
/// so "show the playing album" can scroll its row into view.
const detail_list_top: f32 = 304;
const detail_row_height: f32 = 44;
/// The smallest album-page viewport the window allows (600pt min height
/// minus header and transport). The model does not track the canvas
/// height, so scrolling is clamped against this floor: a short album
/// never scrolls (the scroll view does not clamp a controlled offset),
/// and a long one never scrolls past its last row.
const detail_min_viewport: f32 = 600 - header_natural_height - 80;

fn revealNowPlaying(model: *Model) void {
    const track = model.nowTrack() orelse return;
    model.open_album = track.album;
    // A fresh scroll region, so the offset below applies even when it
    // equals the last one the view declared.
    model.detail_scroll_epoch +%= 1;
    model.selected = track.id;
    closeHeaderMenus(model);
    const row_top = detail_list_top + @as(f32, @floatFromInt(@max(track.number, 1) - 1)) * detail_row_height;
    const content = detail_list_top + @as(f32, @floatFromInt(model.tracksInAlbum(track.album))) * detail_row_height + 24;
    const max_scroll = @max(0, content - detail_min_viewport);
    // Already visible without scrolling: stay at the top.
    if (row_top + detail_row_height <= detail_min_viewport) {
        model.detail_scroll = 0;
        return;
    }
    // Leave some context above the row instead of pinning it to the top.
    model.detail_scroll = std.math.clamp(row_top - 160, 0, max_scroll);
}

// ------------------------------------------------------------ drag & drop

/// Paths from a window drop, staged by main.zig's HostShim — platform
/// glue, not Model state — and drained by `.import_dropped`.
var drop_inbox: [16 * 1024]u8 = undefined;
var drop_inbox_len: usize = 0;

/// Stage dropped paths ('\n'-joined). Returns false when nothing fit.
pub fn stageDroppedPaths(paths: []const []const u8) bool {
    for (paths) |path| {
        if (path.len == 0 or path.len > max_user_path) continue;
        if (drop_inbox_len + path.len + 1 > drop_inbox.len) break;
        @memcpy(drop_inbox[drop_inbox_len..][0..path.len], path);
        drop_inbox_len += path.len;
        drop_inbox[drop_inbox_len] = '\n';
        drop_inbox_len += 1;
    }
    return drop_inbox_len > 0;
}

fn isDirectory(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn isAudioPath(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return ext.len > 1 and isAudioExtension(ext[1..]);
}

/// Folders become albums, audio files land in Library; anything else is
/// ignored.
fn importDropped(model: *Model, fx: *Effects) void {
    var staged: [16 * 1024]u8 = undefined;
    const len = drop_inbox_len;
    @memcpy(staged[0..len], drop_inbox[0..len]);
    drop_inbox_len = 0;
    var lines = std.mem.splitScalar(u8, staged[0..len], '\n');
    var queued_loose = false;
    var cover_set = false;
    while (lines.next()) |path| {
        if (path.len == 0) continue;
        if (isImagePath(path)) {
            if (!cover_set) {
                if (model.open_album) |album_id| {
                    setCoverFromDrop(model, fx, album_id, path);
                    cover_set = true;
                }
            }
        } else if (isDirectory(path)) {
            importAlbumDir(model, fx, path);
        } else if (isAudioPath(path)) {
            if (queueImport(model, imported_album_id, path)) queued_loose = true;
        } else {
            model.import_unsupported += 1;
        }
    }
    if (queued_loose) persistLibrary(model, fx);
    pumpImport(model, fx);
}

// ------------------------------------------------------------- auto-skip

/// A track that cannot play moves on to the next one instead of ending
/// playback. `skip_streak` counts consecutive failures; once it reaches
/// the list's length (or the next pick is the same broken track) the
/// transport gives up with the honest "couldn't play" notice in the bar.
fn failCurrentTrack(model: *Model, fx: *Effects) void {
    const failed = model.now orelse return;
    fx.cancelTimer(fade_timer_key);
    model.fade = .none;
    model.skip_streak += 1;
    var buf: [max_queue]u8 = undefined;
    const list_len = @max(1, @min(shuffleCandidates(model, &buf).len, 64));
    if (model.skip_streak <= list_len) {
        if (model.userTrackById(failed)) |track| model.setSkippedTitle(track.title());
        // Repeat-one would retry the same file forever: advance as if
        // repeating the list.
        const repeat = model.repeat;
        if (repeat == .one) model.repeat = .all;
        skipForward(model, fx, true);
        model.repeat = repeat;
        if (model.now != null and model.now.? != failed and model.playing) {
            showNotice(model, fx, .skipped, notice_import_ms);
            return;
        }
    }
    model.skip_streak = 0;
    // A retry above may have reloaded the same file; nothing should keep
    // playing behind the "couldn't play" notice.
    fx.stopAudio();
    model.assets_missing = true;
    model.now = null;
    model.playing = false;
    model.elapsed_ms = 0;
    model.now_duration_ms = 0;
    model.platform_duration_ms = 0;
    syncNowPlaying(model);
    persistSession(model, fx);
}

// ------------------------------------------------------------------ fade

/// Pause and resume ramp the volume over `fade_steps` × `fade_step_ms`
/// instead of cutting the waveform mid-cycle (an audible click). The
/// transport flips `playing` at once; the player pauses when the ramp
/// ends. Muted playback has nothing to ramp.
pub const fade_timer_key: u64 = 46;
const fade_step_ms: u64 = 25;
pub const fade_steps: u8 = 6;
pub const Fade = enum { none, out, in };

pub fn fadeLevel(model: *const Model) f32 {
    const fraction = @as(f32, @floatFromInt(model.fade_step)) / @as(f32, @floatFromInt(fade_steps));
    // Raised cosine: flat at both ends, so neither the start of the ramp
    // nor its arrival at silence leaves a corner in the waveform. The two
    // directions mirror each other exactly — out(k) == in(fade_steps - k) —
    // which keeps a mid-ramp reversal (startFade) continuous.
    const rising = 0.5 - 0.5 * @cos(std.math.pi * fraction);
    return model.effectiveVolume() * switch (model.fade) {
        .none => 1,
        .out => 1 - rising,
        .in => rising,
    };
}

fn startFade(model: *Model, fx: *Effects, direction: Fade) void {
    // Reversing mid-ramp starts from the level already reached.
    const reached: u8 = if (model.fade != .none and model.fade != direction) fade_steps - model.fade_step else 0;
    model.fade = direction;
    model.fade_step = reached;
    fx.setAudioVolume(fadeLevel(model));
    fx.startTimer(.{
        .key = fade_timer_key,
        .interval_ms = fade_step_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.fade_tick),
    });
}

fn fadeTick(model: *Model, fx: *Effects) void {
    if (model.fade == .none) return;
    model.fade_step += 1;
    if (model.fade_step < fade_steps) {
        fx.setAudioVolume(fadeLevel(model));
        return;
    }
    fx.cancelTimer(fade_timer_key);
    const finished = model.fade;
    model.fade = .none;
    model.fade_step = 0;
    if (finished == .out) {
        fx.pauseAudio();
        // Leave the player at the real level for whatever plays next.
        fx.setAudioVolume(model.effectiveVolume());
    } else {
        fx.setAudioVolume(model.effectiveVolume());
    }
}

fn stopFade(model: *Model, fx: *Effects) void {
    if (model.fade == .none) return;
    fx.cancelTimer(fade_timer_key);
    model.fade = .none;
    model.fade_step = 0;
    fx.setAudioVolume(model.effectiveVolume());
}

// ------------------------------------------------------------- playlist

pub const QueueMove = enum { up, down, top, bottom };

fn moveQueued(model: *Model, id: u8, move: QueueMove) void {
    const from = model.queueIndexOf(id) orelse return;
    const last = model.queue_len - 1;
    const to: usize = switch (move) {
        .up => if (from == 0) return else from - 1,
        .down => if (from == last) return else from + 1,
        .top => 0,
        .bottom => last,
    };
    if (to == from) return;
    if (to < from) {
        std.mem.copyBackwards(u8, model.queue[to + 1 .. from + 1], model.queue[to..from]);
    } else {
        std.mem.copyForwards(u8, model.queue[from..to], model.queue[from + 1 .. to + 1]);
    }
    model.queue[to] = id;
}

// --------------------------------------------------------- remembered view

/// Write the session file synchronously — main.zig calls this on quit so
/// the last page and scroll survive even when no async save was pending.
pub fn saveSessionNow(model: *const Model) void {
    var buffer: [max_session_store_bytes]u8 = undefined;
    writeFileAtomically(model.sessionPath(), model.serializeSession(&buffer));
}

/// Quit-time flush of catalog changes not yet on disk: an import batch
/// below `import_save_every`, or a save queued behind a write that was
/// still in flight (`save_pending`).
pub fn saveLibraryNow(model: *Model) void {
    if (model.import_unsaved == 0 and !model.save_pending) return;
    const buffer = std.heap.page_allocator.alloc(u8, max_library_store_bytes) catch return;
    defer std.heap.page_allocator.free(buffer);
    writeFileAtomically(model.storePath(), model.serializeLibrary(buffer));
    model.import_unsaved = 0;
    model.save_pending = false;
}

/// Write `bytes` to a sibling temp file, then rename it over `path`: a
/// quit (or crash) mid-write leaves the old file intact rather than a
/// truncated one the next launch would read as a smaller library.
fn writeFileAtomically(path: []const u8, bytes: []const u8) void {
    if (path.len == 0 or !std.fs.path.isAbsolute(path)) return;
    var tmp_buffer: [max_store_path + 8]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buffer, "{s}.tmp", .{path}) catch return;
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    {
        var file = std.Io.Dir.createFileAbsolute(io, tmp, .{}) catch return;
        defer file.close(io);
        file.writeStreamingAll(io, bytes) catch return;
    }
    std.Io.Dir.renameAbsolute(tmp, path, io) catch {
        std.Io.Dir.deleteFileAbsolute(io, tmp) catch {};
    };
}

/// Read just the view keys (open album, scroll offsets) before the first
/// frame, so launch paints the page the user left instead of flashing the
/// grid first. The rest of the session still restores asynchronously.
pub fn loadSessionViewSync(model: *Model) void {
    const path = model.sessionPath();
    if (path.len == 0 or !std.fs.path.isAbsolute(path)) return;
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return;
    defer file.close(io);
    var buffer: [max_session_store_bytes]u8 = undefined;
    var read_buffer: [1024]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const len = reader.interface.readSliceShort(&buffer) catch return;
    model.applySessionView(buffer[0..len]);
}

fn isImagePath(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    if (ext.len < 2) return false;
    return isImageExtension(ext[1..]);
}

fn isImageExtension(body: []const u8) bool {
    return std.ascii.eqlIgnoreCase(body, "png") or std.ascii.eqlIgnoreCase(body, "jpg") or
        std.ascii.eqlIgnoreCase(body, "jpeg") or std.ascii.eqlIgnoreCase(body, "webp") or
        std.ascii.eqlIgnoreCase(body, "gif");
}

/// An image dropped on an album page becomes that album's cover.
fn setCoverFromDrop(model: *Model, fx: *Effects, album_id: u8, path: []const u8) void {
    if (!importCoverFromSource(model, album_id, path)) return;
    persistLibrary(model, fx);
    _ = loadCoverFromPath(model, fx, album_id);
}

// ------------------------------------------------------------ cover thumbs

/// Downscaled cover pixels cached beside the managed cover as
/// `media/c{id}.thumb`, so launches register ready RGBA instead of
/// decoding the original (a phone photo cost tens of MB of decoder
/// memory and a visible hitch per album). Layout: magic, u16 width,
/// u16 height, u64 source size, then width*height*4 RGBA bytes. The
/// source size is the staleness check; replacing a cover also deletes
/// the thumb.
const cover_thumb_magic = "WMT1";
const cover_thumb_header_len = cover_thumb_magic.len + 2 + 2 + 8;

fn coverThumbPath(model: *const Model, album_id: u8, buffer: *[max_user_path]u8) ?[]const u8 {
    const root = model.mediaDir();
    if (root.len == 0) return null;
    return std.fmt.bufPrint(buffer, "{s}{c}c{d}.thumb", .{ root, std.fs.path.sep, album_id }) catch null;
}

fn deleteCoverThumb(model: *const Model, album_id: u8) void {
    var buffer: [max_user_path]u8 = undefined;
    const path = coverThumbPath(model, album_id, &buffer) orelse return;
    deleteManagedMediaFile(model, path);
}

fn writeCoverThumb(model: *const Model, album_id: u8, source_size: u64, width: usize, height: usize, rgba: []const u8) void {
    var path_buffer: [max_user_path]u8 = undefined;
    const path = coverThumbPath(model, album_id, &path_buffer) orelse return;
    var header: [cover_thumb_header_len]u8 = undefined;
    @memcpy(header[0..4], cover_thumb_magic);
    std.mem.writeInt(u16, header[4..6], @intCast(width), .little);
    std.mem.writeInt(u16, header[6..8], @intCast(height), .little);
    std.mem.writeInt(u64, header[8..16], source_size, .little);
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var file = std.Io.Dir.createFileAbsolute(io, path, .{}) catch return;
    defer file.close(io);
    file.writeStreamingAll(io, &header) catch return;
    file.writeStreamingAll(io, rgba) catch return;
}

/// Register the cached thumb when it matches the current cover file.
fn registerCoverThumb(model: *Model, fx: *Effects, album_id: u8, source_size: u64) bool {
    var path_buffer: [max_user_path]u8 = undefined;
    const path = coverThumbPath(model, album_id, &path_buffer) orelse return false;
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    var header: [cover_thumb_header_len]u8 = undefined;
    const header_len = reader.interface.readSliceShort(&header) catch return false;
    if (header_len != header.len or !std.mem.eql(u8, header[0..4], cover_thumb_magic)) return false;
    const width: usize = std.mem.readInt(u16, header[4..6], .little);
    const height: usize = std.mem.readInt(u16, header[6..8], .little);
    if (std.mem.readInt(u64, header[8..16], .little) != source_size) return false;
    if (width == 0 or height == 0 or width > max_cover_register_edge or height > max_cover_register_edge) return false;
    var pixels: [max_cover_register_edge * max_cover_register_edge * 4]u8 = undefined;
    const need = width * height * 4;
    const got = reader.interface.readSliceShort(pixels[0..need]) catch return false;
    if (got != need) return false;
    fx.registerImage(album_id, width, height, pixels[0..need]) catch return false;
    const album = model.userAlbumByIdMut(album_id) orelse return false;
    album.cover = album_id;
    return true;
}

fn coverFileSize(path: []const u8) ?u64 {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    return fileSizeAt(threaded.io(), path);
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

/// Samples per axis inside each destination pixel's source box (see
/// `downscaleRgba`).
const max_box_samples: usize = 4;

pub const downscaleRgbaForTest = downscaleRgba;

fn downscaleRgba(
    src: []const u8,
    src_w: usize,
    src_h: usize,
    dst: []u8,
    dst_w: usize,
    dst_h: usize,
) void {
    // Area average over a bounded sample grid: each destination pixel
    // averages at most `max_box_samples`² evenly spaced source pixels
    // from its box. Averaging EVERY source pixel took ~12 ms for a
    // 4000 px photo on the UI thread (over a 120 Hz frame); this takes
    // ~0.8 ms and differs by under 1% on average. Nearest-neighbour (one
    // sample) aliased fine detail into jagged edges and moiré.
    var y: usize = 0;
    while (y < dst_h) : (y += 1) {
        const y0 = y * src_h / dst_h;
        const y1 = @max(y0 + 1, (y + 1) * src_h / dst_h);
        // Typed: `@min` against a comptime bound would narrow to u3, and
        // `2 * n` below would overflow it.
        const sy_n: usize = @min(y1 - y0, max_box_samples);
        var x: usize = 0;
        while (x < dst_w) : (x += 1) {
            const x0 = x * src_w / dst_w;
            const x1 = @max(x0 + 1, (x + 1) * src_w / dst_w);
            const sx_n: usize = @min(x1 - x0, max_box_samples);
            var sum: [4]u32 = .{ 0, 0, 0, 0 };
            var iy: usize = 0;
            while (iy < sy_n) : (iy += 1) {
                const sy = y0 + ((y1 - y0) * (2 * iy + 1)) / (2 * sy_n);
                var ix: usize = 0;
                while (ix < sx_n) : (ix += 1) {
                    const sx = x0 + ((x1 - x0) * (2 * ix + 1)) / (2 * sx_n);
                    const si = (sy * src_w + sx) * 4;
                    inline for (0..4) |c| sum[c] += src[si + c];
                }
            }
            const n: u32 = @intCast(sy_n * sx_n);
            const di = (y * dst_w + x) * 4;
            inline for (0..4) |c| dst[di + c] = @intCast((sum[c] + n / 2) / n);
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

        // The scratch is sized for a 4096² decode; hand it back as soon
        // as this cover is registered rather than keeping it resident.
        defer releaseCoverDecodeScratch();
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
        writeCoverThumb(model, album_id, encoded.len, fitted.w, fitted.h, rgba);
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
        .open_album => |id| {
            model.open_album = id;
            // A fresh record opens at its top, in a fresh scroll region.
            model.detail_scroll = 0;
            model.detail_scroll_epoch +%= 1;
            // Detail cover should not wait on the staggered hydrate walk.
            requestCoverLoad(model, fx, id);
            persistSession(model, fx);
        },
        .close_album => {
            if (model.open_album == null) return;
            model.open_album = null;
            persistSession(model, fx);
        },
        .play_album => |id| {
            const first = model.firstTrackIdInAlbum(id) orelse return;
            // Replace the playlist with the whole album so repeat and
            // shuffle walk that list instead of consuming a
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
            if (model.shuffle) {
                // A new list starts a new pass at a random track.
                resetShuffle(model);
                const ids = model.queue[0..model.queue_len];
                if (pickUnplayed(model, ids, null)) |pick| {
                    startTrack(model, fx, pick);
                    return;
                }
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
        .toggle_shuffle => {
            model.shuffle = !model.shuffle;
            if (model.shuffle) resetShuffle(model);
            persistSession(model, fx);
        },
        .cycle_repeat => {
            model.repeat = switch (model.repeat) {
                .off => .all,
                .all => .one,
                .one => .off,
            };
            persistSession(model, fx);
        },
        .volume_changed => |value| {
            model.volume = std.math.clamp(value, 0, 1);
            // Dragging the slider is an explicit level: it unmutes.
            model.muted = false;
            fx.setAudioVolume(model.effectiveVolume());
            // A drag reports every step; save once it settles.
            persistSessionSoon(fx);
        },
        .toggle_mute => {
            // Muting at zero would leave nothing to restore; nudge up.
            if (model.muted or model.volume > 0) {
                model.muted = !model.muted;
            } else {
                model.volume = 0.5;
            }
            fx.setAudioVolume(model.effectiveVolume());
            persistSession(model, fx);
        },
        .volume_step => |dir| {
            const step: f32 = 0.1;
            const base = model.effectiveVolume();
            model.volume = std.math.clamp(if (dir == .up) base + step else base - step, 0, 1);
            model.muted = false;
            fx.setAudioVolume(model.effectiveVolume());
            // Held Cmd+Up / Cmd+Down repeats: save once it settles.
            persistSessionSoon(fx);
        },
        .session_save_due => |timer| {
            if (timer.outcome != .fired) return;
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
            .play => if (!model.playing) update(model, .toggle_play, fx),
            .pause => if (model.playing) update(model, .toggle_play, fx),
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
            if (model.userTrackById(id) == null) return;
            beginUndoableRemoval(model);
            var effects: RemovalEffects = .{};
            const removed: usize = if (removeTrackTracked(model, id, &effects)) 1 else 0;
            finishRemoval(model, fx, effects, removed);
        },
        .remove_album => |id| removeAlbum(model, fx, id),
        .undo_remove => undoRemoval(model, fx),
        .dismiss_notice => clearNotice(model, fx),
        .notice_expired => |timer| {
            if (timer.outcome != .fired) return;
            clearNotice(model, fx);
        },
        .reveal_now_playing => revealNowPlaying(model),
        .shuffle_album => |id| {
            if (!model.shuffle) {
                model.shuffle = true;
                persistSession(model, fx);
            }
            update(model, .{ .play_album = id }, fx);
        },
        .fade_tick => |timer| {
            if (timer.outcome != .fired) return;
            fadeTick(model, fx);
        },
        .remove_selected => if (model.selected) |id| update(model, .{ .remove_track = id }, fx),
        .queue_selected => if (model.selected) |id| update(model, .{ .queue_track = id }, fx),
        .move_queued => |move| {
            moveQueued(model, move.id, move.move);
            persistSession(model, fx);
        },
        .import_dropped => {
            closeHeaderMenus(model);
            importDropped(model, fx);
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
        .title_heal => {
            if (!model.title_heal_pending) return;
            if (model.healNextTitle()) persistLibrary(model, fx);
        },
        .import_copied => |exit| finishImportCopy(model, fx, exit),
        .library_done => |result| switch (result.op) {
            // Launch loads the library sync; async reads are unused.
            .read => {},
            .write => {
                model.store_write_inflight = false;
                if (result.outcome == .ok and model.save_pending) {
                    model.save_pending = false;
                    writeLibrary(model, fx);
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
        // The file is unreadable or the host cannot decode it: move on
        // to the next track (see `failCurrentTrack`).
        .failed, .rejected => failCurrentTrack(model, fx),
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
        fx.cancelTimer(audio_end_timer_key);
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
        failCurrentTrack(model, fx);
        return;
    }
    // Audio is really moving: the failure streak is over.
    if (snap.playing and snap.position_ms > 0) model.skip_streak = 0;

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
        armEndPoll(model, fx, position);
    } else {
        model.elapsed_ms = position;
    }
    syncNowPlaying(model);
}

/// When the track ends before the next regular poll, schedule a one-shot
/// poll just past the end so the next track starts without a gap.
fn armEndPoll(model: *const Model, fx: *Effects, position_ms: u32) void {
    const duration = model.now_duration_ms;
    if (duration == 0) return;
    const remaining: u64 = if (duration > position_ms) duration - position_ms else 0;
    if (remaining >= audio_poll_interval_ms) return;
    fx.startTimer(.{
        .key = audio_end_timer_key,
        .interval_ms = remaining + audio_end_margin_ms,
        .mode = .one_shot,
        .on_fire = Effects.timerMsg(.audio_poll),
    });
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
    // The previous track's end poll would only land a wasted poll, and a
    // pause ramp belongs to the old track.
    fx.cancelTimer(audio_end_timer_key);
    stopFade(model, fx);
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
        failCurrentTrack(model, fx);
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
    fx.setAudioVolume(model.effectiveVolume());
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
    if (model.effectiveVolume() == 0) {
        stopFade(model, fx);
        if (playing) fx.resumeAudio() else fx.pauseAudio();
    } else if (playing) {
        // Resume from silence (or from wherever a pause ramp got to).
        if (model.fade == .none) fx.setAudioVolume(0);
        fx.resumeAudio();
        startFade(model, fx, .in);
    } else {
        startFade(model, fx, .out);
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
/// the end of a repeat-off list (stop) from a mid-track skip on the last
/// song (no-op).
fn skipForward(model: *Model, fx: *Effects, from_completion: bool) void {
    if (from_completion and model.repeat == .one) {
        if (model.now) |now_id| {
            startTrack(model, fx, now_id);
            return;
        }
    }
    if (model.shuffle) {
        shuffleForward(model, fx, from_completion);
        return;
    }
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

    switch (model.repeat) {
        .all, .one => {
            const next_number: u8 = @intCast((@as(usize, track.number) % count) + 1);
            const next = model.userTrackInAlbumByNumber(track.album, next_number) orelse return;
            startTrack(model, fx, next.id);
        },
        .off => {
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
    switch (model.repeat) {
        .all, .one => {
            const next = (idx + 1) % len;
            startTrack(model, fx, model.queue[next]);
        },
        .off => {
            if (idx + 1 >= len) {
                if (from_completion) stopAtEnd(model);
                return;
            }
            startTrack(model, fx, model.queue[idx + 1]);
        },
    }
}

/// The list shuffle draws from: the playlist when the current track is in
/// it (or nothing is loaded), else the current track's album in order.
fn shuffleCandidates(model: *const Model, out: *[max_queue]u8) []const u8 {
    const now_id = model.now orelse return model.queue[0..model.queue_len];
    if (model.queueIndexOf(now_id) != null) return model.queue[0..model.queue_len];
    const track = model.userTrackById(now_id) orelse return model.queue[0..model.queue_len];
    var len: usize = 0;
    var number: u8 = 1;
    const count = model.tracksInAlbum(track.album);
    while (number <= count) : (number += 1) {
        const user = model.userTrackInAlbumByNumber(track.album, number) orelse continue;
        out[len] = user.id;
        len += 1;
    }
    return out[0..len];
}

fn resetShuffle(model: *Model) void {
    model.shuffle_played = std.StaticBitSet(256).initEmpty();
    model.shuffle_history_len = 0;
}

/// splitmix64: tiny, well-distributed, and fully determined by the model.
fn nextRandom(model: *Model) u64 {
    model.shuffle_rng +%= 0x9E3779B97F4A7C15;
    var z = model.shuffle_rng;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

/// A uniformly random id from `ids` not yet played this pass and not
/// `exclude`; null when none is left.
fn pickUnplayed(model: *Model, ids: []const u8, exclude: ?u8) ?u8 {
    var count: usize = 0;
    for (ids) |id| {
        if (exclude != null and exclude.? == id) continue;
        if (!model.shuffle_played.isSet(id)) count += 1;
    }
    if (count == 0) return null;
    var target = nextRandom(model) % count;
    for (ids) |id| {
        if (exclude != null and exclude.? == id) continue;
        if (model.shuffle_played.isSet(id)) continue;
        if (target == 0) return id;
        target -= 1;
    }
    return null;
}

fn pushShuffleHistory(model: *Model, id: u8) void {
    if (model.shuffle_history_len == shuffle_history_cap) {
        std.mem.copyForwards(u8, model.shuffle_history[0 .. shuffle_history_cap - 1], model.shuffle_history[1..]);
        model.shuffle_history_len -= 1;
    }
    model.shuffle_history[model.shuffle_history_len] = id;
    model.shuffle_history_len += 1;
}

/// Shuffle's Next and natural advance. Play Next entries outside the
/// playlist still go first; otherwise a random unplayed track from the
/// current list, starting a new pass (never the same track twice in a
/// row when there is a choice) once every track has played.
fn shuffleForward(model: *Model, fx: *Effects, from_completion: bool) void {
    const now_in_playlist = if (model.now) |id| model.queueIndexOf(id) != null else false;
    if (!now_in_playlist and model.now != null) {
        if (model.popQueue()) |queued| {
            if (model.now) |id| pushShuffleHistory(model, id);
            startTrack(model, fx, queued);
            return;
        }
    }
    var buf: [max_queue]u8 = undefined;
    const ids = shuffleCandidates(model, &buf);
    if (ids.len == 0) return;
    if (model.now) |id| model.shuffle_played.set(id);
    var pick = pickUnplayed(model, ids, model.now);
    if (pick == null) {
        // Every track has played: Repeat off ends here, like the last
        // track of an in-order list.
        if (model.repeat == .off) {
            if (from_completion) stopAtEnd(model);
            return;
        }
        for (ids) |id| model.shuffle_played.unset(id);
        if (model.now) |id| model.shuffle_played.set(id);
        pick = pickUnplayed(model, ids, model.now) orelse model.now;
    }
    const next = pick orelse return;
    if (model.now) |id| pushShuffleHistory(model, id);
    startTrack(model, fx, next);
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
    if (model.shuffle) {
        while (model.shuffle_history_len > 0) {
            model.shuffle_history_len -= 1;
            const id = model.shuffle_history[model.shuffle_history_len];
            if (model.userTrackById(id) == null) continue;
            startTrack(model, fx, id);
            return;
        }
    }
    if (model.queueIndexOf(track.id)) |idx| {
        if (model.repeat == .off and idx == 0) {
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
    if (model.repeat == .off and track.number <= 1) {
        model.elapsed_ms = 0;
        fx.seekAudio(0);
        syncNowPlaying(model);
        return;
    }
    const prev_number: u8 = @intCast((@as(usize, track.number) + count - 2) % count + 1);
    const prev = model.userTrackInAlbumByNumber(track.album, prev_number) orelse return;
    startTrack(model, fx, prev.id);
}
