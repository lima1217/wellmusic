# Design-token inventory

Generated from `src/view.zig` and the `.native` markup: every literal size the UI states, and how often. Colors live in [color-audit.md](color-audit.md).

**Spacing scale** (`src/view.zig`, `src/*.native`): every gap and padding is one of **2** (between two lines of one text block), **4, 8, 12, 16, 24** (24 = page inset). Before this pass the views used eleven values: 1, 2, 4, 6, 8, 10, 12, 14, 16, 20, 24.

Fixed sizes that are not spacing: row heights 40 (queue) / 44 (songs) / 80 (now-playing bar), cover 200 (album page) / 48 (bar), dialog width 420, volume slider 88, duration column 56, number column 24.

## Type sizes per screen (rule: ≤ 4)

| screen | sizes in use |
|---|---|
| Album grid | body (title), sm (artist, header notice) — **2** |
| Album page | 1.6× bold (album title, sized for the 200pt side column), body (artist, rows), sm (count, row artist, number, duration) — **3** |
| Empty library | body bold (heading), body (buttons), sm (hint) — **2** |
| Queue panel | body bold (heading), body (titles), sm (count, artist) — **2** |
| Edit dialog | body bold (heading), body (fields, buttons), sm (labels) — **2** |
| Now-playing bar | body, sm — **2** |

Hierarchy comes from weight and the one display size; no screen exceeds three sizes.

## Radii (concentric rule: inner = outer − inset)

- Album tile wash `tile_radius = cover_radius + tile_padding` = 10 + 8 = 18 → concentric with the 10pt cover. ✔
- Detail cover 10pt = grid cover 10pt. ✔
- Now-playing cover `radius="md"`; it is not nested in a rounded parent. ✔

## Shadows / elevation

- `shadow.sm` zeroed in the theme: bands and the page are flat. Only overlays (menus, dialog, tooltips) keep the pack's `md` shadow — the things that really float.
- The empty-state card (a panel on the page) was removed; no card-in-card anywhere.

## Fonts

- No italic, no all-caps anywhere in `strings.zig` or the views.
- Monospace: only the pack's tabular figures for durations (a metric — allowed).

