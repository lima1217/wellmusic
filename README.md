# WellMusic

A native macOS music library built on the Native SDK. Add local audio files, browse them as albums, play them, edit song and album info and covers, and remove what you no longer want. There is no built-in sample catalog.

The interface follows the system language: Chinese when your preferred language in System Settings → Language & Region is Chinese, English otherwise.

## Build and run

Requires Zig 0.16 and Native SDK **0.5.4** (`npm i -g @native-sdk/cli@0.5.4`). SDK 0.11.0's npm package is missing a file its `build.zig` embeds, so no app builds with it.

```sh
# First run after an SDK install: builds once and creates .native/build
native test --yes

# Then re-apply the SDK patches (spectrum FFT off, menu icon alignment)
./scripts/apply-sdk-patches.sh

native dev          # debug build, runs the app
native test --yes   # the test suite
native check        # markup and manifest checks
```

Production app bundle (ad-hoc signed, for this Mac):

```sh
native build --yes
native package --target macos --binary zig-out/bin/wellmusic --signing adhoc --output WellMusic.app
```

## Adding music

- Header **⋯** menu → **Add Song** (mp3, m4a, wav, aac, flac, ogg; multiple files at once) or **Add Album** (pick a folder). The empty library also shows an Add button.
- **Drag and drop**: drop audio files or folders onto the window. Loose files go to the **Library** album; each folder becomes an album named after the folder (a `cover.jpg` / `folder.jpg` / `front.png` … inside is picked up as the cover).
- Tags in the files (title, artist, album, duration) are read on import. Imported audio and covers are **copied** into `~/Library/Application Support/wellmusic/media/`, so moving or deleting the originals never breaks playback.
- Copies run in the background, one file at a time, with progress in the header. Each song appears as soon as its copy lands; the header then shows a summary such as "Added 10 songs · skipped 2 already in the library".
- Duplicates are detected by file content, not just path: the same song imported twice, or under another name, is skipped.
- Capacity: **240 tracks** and **32 albums**.

## Removing music

- Right-click a track → **Remove from Library**, or select it and press **Cmd+Backspace**.
- Right-click an album tile or the album page cover → **Remove Album from Library** removes the album and all its tracks.
- After a removal the header shows **Undo** for 6 seconds. The copied files are deleted only once the removal is final (the notice expires, you remove something else, or you quit).

## Playback

- Double-click a track (or press Enter on the selection) to play it; it is also appended to the playlist.
- **Play Album** replaces the playlist with the album and starts from the first track; the **shuffle** button next to it plays the album in random order.
- The now-playing bar has previous / play-pause / next, **shuffle** (on/off) and **repeat** (off → all → one), a speaker button that mutes and restores, the volume slider, and the playlist toggle. Shuffle and repeat icons turn accent-coloured when on.
  - Shuffle plays every track in the list once before any repeats; **Previous** walks back through what actually played.
  - Repeat one replays the current track when it ends; Next and Previous still move through the list.
- Click the cover or title in the now-playing bar to open the playing album at the playing track.
- A track that cannot be read or decoded is skipped, with a notice naming it; playback stops only if the whole list fails.
- Pause and resume fade the volume over 150 ms instead of cutting the sound.

## Playlist

- Toggle it from the list icon at the right of the now-playing bar (or the menu bar ♪ item).
- Click a row to play it; the × removes it. Right-click a row → **Move Up / Move Down / Move to Top / Move to Bottom**.
- Right-click a track → **Play Next** (or **Cmd+Shift+N** on the selection) adds it to the playlist without starting it.

## Control from outside the window

- **Control Center**, headphone buttons, and keyboard media keys control playback even when another app is in front. Song title and artist are published to Now Playing.
- Menu bar **♪** item: Play/Pause, Next, Previous, Show/Hide Queue.

## Keyboard shortcuts

| Keys | Action |
| --- | --- |
| Space | Play / pause |
| ↑ / ↓ | Move the selection |
| Enter | Play the selected track |
| Cmd+→ / Cmd+← | Next / previous track |
| Cmd+↑ / Cmd+↓ | Volume up / down |
| Cmd+L | Show the playing album |
| Cmd+Backspace | Remove the selected track (undoable) |
| Cmd+Shift+N | Play the selected track next |
| Esc or Cmd+[ | Back from an album page to the albums |
| F7 / F8 / F9, media keys | Previous / play-pause / next |

## Editing

- **Song info**: right-click a track → **Edit Info…**, change title and artist, **Save** (Escape or Cancel discards).
- **Album info**: right-click the album tile or the album page cover → **Edit Info…**.
- **Cover**: right-click the album tile or cover → **Change Cover…** and pick a PNG / JPEG / WebP / GIF (not HEIC), or drop an image onto an open album page. Large photos are scaled down once and cached as a small thumbnail, so later launches load covers without decoding them again.

## What is remembered

Everything lives in `~/Library/Application Support/wellmusic/`:

- `library.txt` — albums and tracks.
- `session.txt` — the current track and position, playlist, shuffle / repeat, volume and mute, theme, and the page you were on (open album and scroll position). The app reopens there, paused; it never auto-plays.
- `media/` — the copied audio (`t<n>.<ext>`), covers (`c<n>.<ext>`), and cover thumbnails (`c<n>.thumb`).

Saves on quit go through a temporary file and a rename, so an interrupted write never leaves a truncated library.

## Appearance

- Light / dark follows the system; **⋯ → Dark mode / Light mode** locks one in and remembers it.
- System **Reduce Motion** is honored.
- Chinese, Japanese, and Korean titles use a system font loaded on demand (when the UI is Chinese or the library contains CJK text).

## Repository notes

- `plans/` — animation plans from the improve-animations audit, with their status.
- `docs/` — earlier code-review notes and tickets.
- `patches/`, `scripts/` — the SDK patches and the script that applies them.
