# Design-token inventory

Generated from `src/view.zig` and the `.native` markup: every literal size the UI states, and how often. Colors live in [color-audit.md](color-audit.md).

- **gap**: `8`×6, `4`×4, `6`×3, `1`×3, `12`×3, `10`×2, `20`×2, `2`×2, `14`×1, `0`×1, `24`×1, `16`×1
- **padding**: `12`×2, `20`×1, `8`×1, `4`×1, `24`×1, `10`×1, `14`×1
- **height**: `14`×2, `40`×1, `12`×1, `44`×1, `80`×1, `52`×1
- **width**: `0`×2, `24`×2, `14`×2, `420`×1, `12`×1, `16`×1, `2`×1, `56`×1, `52`×1, `88`×1, `8`×1
- **radius**: `0`×2

## Type sizes per screen (rule: ≤ 4)

| screen | sizes in use |
|---|---|
| Album grid | body (title), sm (artist, header notice) — **2** |
| Album page | 2.05× bold (album title), body (artist, rows), sm (count, row artist, number, duration) — **3** |
| Empty library | body bold (heading), body (buttons), sm (hint) — **2** |
| Queue panel | body bold (heading), body (titles), sm (count, artist) — **2** |
| Edit dialog | body bold (heading), body (fields, buttons), sm (labels) — **2** |
| Now-playing bar | body, sm — **2** |

Hierarchy comes from weight and the one display size; no screen exceeds three sizes.

## Radii (concentric rule: inner = outer − inset)

- Album tile wash `tile_radius = cover_radius + tile_padding` = 10 + 6 = 16 → concentric with the 10pt cover. ✔
- Detail cover 10pt = grid cover 10pt. ✔
- Now-playing cover `radius="md"`; it is not nested in a rounded parent. ✔

## Shadows / elevation

- `shadow.sm` zeroed in the theme: bands and the page are flat. Only overlays (menus, dialog, tooltips) keep the pack's `md` shadow — the things that really float.
- The empty-state card (a panel on the page) was removed; no card-in-card anywhere.

## Fonts

- No italic, no all-caps anywhere in `strings.zig` or the views.
- Monospace: only the pack's tabular figures for durations (a metric — allowed).

