# WellMusic review: first use, copy, numbers, visuals

Branch `review/novice-copy-visual`. Everything here was measured on the app, not assumed: screenshots come from the SDK's automation harness (`native automate screenshot`, deterministic CPU renderer), data checks from the app's own tag parser run over a 12-file test corpus, and colors from [scripts/color_audit.py](scripts/color_audit.py) reading `src/theme.zig`.

| file | what |
|---|---|
| [before-after.pdf](before-after.pdf) | 9 pages: same window, same data, before vs after, with what changed and why |
| [strings.csv](strings.csv) | every UI string, en + zh, length and display-width ratio, where used |
| [glossary.md](glossary.md) | one term per concept, with the source for each choice |
| [apple-terms.csv](apple-terms.csv) | Apple Music's own en / zh_CN strings for the same actions (primary source) |
| [color-audit.md](color-audit.md) | OKLCH of every theme color, WCAG contrast of every pair drawn — 0 failures |
| [tokens.md](tokens.md) | sizes, radii, type sizes per screen, shadows |
| [usability-test.md](usability-test.md) | the 5-task test for real first-time users — **yours to run** |

## Findings, by severity (Nielsen 0–4) and status

| sev | finding | status |
|---|---|---|
| 4 | MP3 lengths were never read: every MP3 showed 0:00 and album totals read "0 minutes". | Fixed — Xing/Info/VBRI frame count or CBR estimate; matches ffprobe to the ms on the corpus. |
| 4 | M4A title/artist/album were never read (tag atoms were walked as containers); files with `moov` at the end (ffmpeg default) lost even the duration. | Fixed. |
| 4 | Chinese ID3 tags in GBK (common on older rips) and Latin-1 names (Beyoncé) were stored as invalid UTF-8: garbled text. | Fixed — UTF-8 → GBK via CoreFoundation GB18030 → Latin-1. |
| 3 | Empty library: one full-width pink "+" with no words. Once the library had songs, adding more was hidden in ⋯. | Fixed — labelled buttons; header + always visible; Cmd+O. |
| 3 | Adds that skipped files were silent (unsupported formats, empty folders, album limit) or said "could not be copied" when the library was full. | Fixed — every reason counted and named; problem notices stay 12 s. |
| 3 | The loose-songs album was "Library / My Music" in English inside the Chinese UI. Folder albums got the parent folder as artist ("Downloads"). | Fixed — Singles / Various Artists (单曲 / 群星), renamed on load; place-names never become artists; tags win. |
| 3 | Album initials sliced CJK titles by byte → tofu placeholder. | Fixed — whole characters. |
| 3 | Accent text failed contrast: pink on light page 4.46:1, on dark page 3.74:1; dark secondary text on a selected row 4.36:1. | Fixed — per-scheme accent; all pairs ≥ 4.5:1. |
| 2 | Five pink areas on one screen (selected row fill, transport play, Play Album, repeat, volume). | Fixed — selection is a warm gray wash; play and volume are neutral; one accent fill per page. |
| 2 | Emoji in UTF-16 tags became two invalid sequences. | Fixed (renders correctly in the accessibility tree; the screenshot renderer has no emoji font). |
| 2 | Wording: track/song, Playlist/Queue, Add/Import mixed; lowercase errors mentioning "the path"; middle dots joining numbers. | Fixed — see glossary; tests reject `·`. |
| 2 | Undo for a removal lasted 6 s with no keyboard shortcut. | Fixed — 10 s and Cmd+Z. |
| 2 | Accessibility labels in English under the Chinese UI ("Now playing title" replaced the actual title for VoiceOver). | Fixed — localized; rows speak title + artist. |
| 1 | Edit dialog: placeholders repeated their labels ("Title" over a box saying "Song title"). | Fixed. |
| 1 | "Album" eyebrow over an album title; "Playlist · 1". | Fixed. |
| 1 | Grays were pure neutral (C = 0). | Fixed — warm (C ≈ 0.007, h 75°); a test rules out blue-leaning grays. |
| 1 | At the minimum window (1056×640) the album page shows only ~4 songs under a 200pt cover. | **Not fixed.** A layout decision (smaller cover at short heights, or a compact header). Worth a 3-option comparison if it bothers you. |
| 1 | Spacing values are scattered (gaps 1, 2, 4, 6, 8, 10, 12, 14, 16, 20, 24). | **Not fixed.** Collapsing to a 4-pt scale touches every view; separate pass. |
| 1 | Repeat defaults to "All" on first launch (Apple Music defaults to off). | **Not changed** — a product decision, not a defect. |
| 1 | An image dropped while no album is open is ignored silently. | **Not fixed.** |

## What this did not verify

- **Real first-time users and native readers.** My walkthrough is a hypothesis; run [usability-test.md](usability-test.md) and send [strings.csv](strings.csv) to native readers.
- **VoiceOver end to end, Accessibility Inspector.** I read the accessibility tree through automation (labels, roles, order) but did not drive VoiceOver.
- **Reduce Motion, Increase Contrast.** These need System Settings changes, which are yours to make. The theme already routes both (high contrast takes the pack's loud register).
- **On-screen rendering.** Screenshots use the SDK's reference renderer (no color emoji; CJK bold looks lighter than CoreText draws it). Check the real window once.
- **Window sizes** were tested at 1056×640 (the minimum), 1080×720, 1470×956, 1728×1117, 1920×1080.

## Rerun the measurements

```bash
python3 docs/review/scripts/color_audit.py
native test --yes
```
