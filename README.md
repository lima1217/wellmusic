# WellMusic

A native music library built on the Native SDK. Add local audio files, browse them, play, edit song and album info and covers, and remove tracks you no longer want. There is no built-in sample catalog.

## Run

```sh
# Once per Native SDK install/upgrade: kill macOS spectrum FFT (saves CPU while playing)
./scripts/disable-native-spectrum.sh

native dev
```

## Add / remove music

- Open the header **⋯** menu and choose **Add Song** (native file dialog: mp3, m4a, wav, aac, flac, ogg) or **Add Album** (pick a folder). Loose files land in the **Library** album; a folder becomes a new album named after the folder (optional `cover.jpg` / `folder.jpg` is picked up automatically). Tags in the files (title, artist, album, duration) are read on import when present. Imported audio and covers are **copied** into `~/Library/Application Support/wellmusic/media/` so later moves or deletes of the originals do not break playback.
- The header **⋯** menu holds **Add Song** / **Add Album** and the light/dark theme toggle. The empty-library card still exposes a direct Add control.
- Right-click a track → **Remove from Library** (also deletes the managed copy under `media/`).
- The library persists at `~/Library/Application Support/wellmusic/library.txt` (macOS). Playback session (current track, queue, play mode, volume, theme) persists beside it as `session.txt`. Opening the app restores that session paused — it does not auto-play.
- Theme: follows the system by default. The moon/sun button in the header toggles light ↔ dark in-app and remembers the choice.

## Playback

- Double-click a track (or Enter on the selection) to play. Transport: previous / play-pause / next / play-mode cycle, and volume.
- **Play Album** starts the first track and replaces the playlist with every track on the album. In list-loop mode the playlist wraps; sequential stops after the last track.
- Right-click → **Play Next** appends to the playlist; the list icon at the trailing edge of the now-playing bar toggles the playlist panel (also in the menu-bar ♪ status item).
- Menu bar ♪ status item: Play/Pause, Next, Previous, Show/Hide Queue.
- Media keys / F7–F9 when the window is focused. Now Playing metadata is published to the system when possible.

## Edit song info

- Right-click a track → **Edit Info…**.
- Change the title and artist in the dialog, then **Save** (or Escape / Cancel to discard).

## Edit album info

- On any album: right-click the album tile or the detail cover → **Edit Info…**.
- Change the title and artist, then **Save** (or Escape / Cancel to discard).

## Change cover

- On any album: right-click the album tile or the detail cover → **Change Cover…**, or click **Change cover** on the album detail page.
- Pick a PNG / JPEG / WebP / GIF; the cover is stored with the library and shown on the album tile, detail page, and now-playing bar.
