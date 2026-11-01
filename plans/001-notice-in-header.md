# 001 — Move the notice line into the header so the page never jumps

- **Status**: DONE (executed after bd23961; feel-checked with automation screenshots)
- **Commit**: bd23961
- **Severity**: MEDIUM
- **Category**: Missed opportunities (a layout jump that should not happen)
- **Estimated scope**: 1 file (`src/view.zig`), ~40 lines changed

## Problem

The notice line (import progress, "Added 3 songs · …", "Removed 2 songs · Undo",
"Couldn't play … — skipped") is inserted ABOVE the page content. When it appears
the whole album grid or album page shifts down by one row (~40pt); when it
auto-clears 4–6 seconds later (`notice_import_ms = 4000`, `notice_removed_ms =
6000` in `src/model.zig:2696-2697`) everything shifts back up. The user is often
mid-click when that happens — a track row can slide out from under the pointer
and the click lands on the neighbouring row.

The usual remedy is a short transition, but Native SDK 0.5.4 cannot animate this
reflow from a Zig view (its layout tweens only drive split-pane fractions). The
right fix is to make the change not move anything: the header band is 52pt tall
and empty between the traffic lights and the `⋯` button, so the notice can live
there.

Current code:

```zig
// src/view.zig:161 — current
fn desktopShell(ui: *Ui, model: *const Model) Ui.Node {
    return ui.column(.{ .grow = 1 }, .{
        chromeBand(ui, CompiledHeaderView.build(ui, model)),
        // Paint the middle with the page token — layout backgrounds do
        // not fill, and relying on GPU clear alone left the body one
        // frame (or one rebuild path) behind chrome after a theme flip.
        pageBand(ui, contentView(ui, model)),
        if (model.queue_open) queuePanel(ui, model) else ui.el(.stack, .{}, .{}),
        chromeBand(ui, CompiledNowPlayingView.build(ui, model)),
    });
}
```

```zig
// src/view.zig:260 — current
fn contentView(ui: *Ui, model: *const Model) Ui.Node {
    const content = if (model.open_album) |album_id|
        albumDetailView(ui, model, album_id)
    else
        albumGridView(ui, model);
    // Import progress / results and the removal Undo ride above the page,
    // so they show on the grid and on an album page alike.
    const status = model.noticeText(ui.arena);
    if (status.len == 0) return content;
    return ui.column(.{ .grow = 1 }, .{
        ui.row(.{ .padding = 8, .gap = 8, .cross = .center, .semantics = .{ .label = model.str(.import_progress) } }, .{
            ui.spacer(4),
            ui.text(.{ .size = .sm, .grow = 1, .style_tokens = .{ .foreground = .text_muted } }, status),
            if (model.noticeCanUndo())
                ui.button(.{ .variant = .ghost, .size = .sm, .on_press = .undo_remove }, model.str(.undo))
            else
                ui.el(.stack, .{}, .{}),
            if (model.import_total == 0)
                ui.button(.{ .variant = .ghost, .size = .sm, .icon = "x", .on_press = .dismiss_notice, .semantics = .{ .label = model.str(.dismiss) } }, "")
            else
                ui.el(.stack, .{}, .{}),
        }),
        content,
    });
}
```

## Target

- `contentView` returns only the page (no notice row) — the page never moves.
- The header band shows the notice centred in its empty middle, layered over the
  markup header with a `stack`, so the header's own layout is untouched.
- No motion is added. The notice still appears and clears instantly; it just no
  longer displaces anything.

```zig
// target
fn contentView(ui: *Ui, model: *const Model) Ui.Node {
    return if (model.open_album) |album_id|
        albumDetailView(ui, model, album_id)
    else
        albumGridView(ui, model);
}

/// Horizontal room the notice leaves on each side of the header band: the
/// traffic lights / chrome inset on the left, the `⋯` button on the right.
const notice_side_inset: f32 = 120;

/// The header band, carrying the notice line (import progress / results,
/// removal Undo, skipped track) in its otherwise empty middle. A notice
/// appearing or clearing therefore never shifts the page below — the page
/// used to jump a row under the pointer each time.
fn headerBand(ui: *Ui, model: *const Model) Ui.Node {
    const header = CompiledHeaderView.build(ui, model);
    const status = model.noticeText(ui.arena);
    if (status.len == 0) return header;
    return ui.el(.stack, .{}, .{
        header,
        ui.row(.{
            .height = model.header_height,
            .gap = 8,
            .cross = .center,
            .semantics = .{ .label = model.str(.import_progress) },
        }, .{
            // `ElementOptions` has only uniform `padding` in this SDK, so
            // the side room is a fixed-width empty stack each way.
            // (`ui.spacer(n)` is a GROW factor, not a width.)
            ui.el(.stack, .{ .width = notice_side_inset + model.chrome_leading }, .{}),
            ui.text(.{ .size = .sm, .grow = 1, .wrap = false, .text_alignment = .center, .style_tokens = .{ .foreground = .text_muted } }, status),
            if (model.noticeCanUndo())
                ui.button(.{ .variant = .ghost, .size = .sm, .on_press = .undo_remove }, model.str(.undo))
            else
                ui.el(.stack, .{}, .{}),
            if (model.import_total == 0)
                ui.button(.{ .variant = .ghost, .size = .sm, .icon = "x", .on_press = .dismiss_notice, .semantics = .{ .label = model.str(.dismiss) } }, "")
            else
                ui.el(.stack, .{}, .{}),
            ui.el(.stack, .{ .width = notice_side_inset + model.chrome_trailing }, .{}),
        }),
    });
}
```

A fixed-width empty `ui.el(.stack, .{ .width = … }, .{})` and
`.text_alignment = .center` are both already used in `src/view.zig`
(`trackIndicator`), so no new API is involved. Do NOT use `ui.spacer(n)` for
the side room: its argument is a grow factor (`ui.zig:1817`). The current
notice row's `ui.spacer(4)` is exactly that mistake — it was meant as a 4pt
indent but grows to most of the row and pushes the text right; this plan
deletes that row.

and in `desktopShell`, `chromeBand(ui, CompiledHeaderView.build(ui, model))` becomes
`chromeBand(ui, headerBand(ui, model))`.

## Repo conventions to follow

- Zig views compose markup fragments by calling `CompiledXView.build(ui, model)`
  and wrapping the result (`desktopShell`, `src/view.zig:161`).
- Every user-facing string goes through `model.str(.key)` or a
  `src/strings.zig` helper — reuse the existing keys `import_progress`, `undo`,
  `dismiss`; add no new strings.
- Muted secondary text is `.size = .sm, .style_tokens = .{ .foreground = .text_muted }`
  (exemplar: the removed notice row above).

## Steps

1. In `src/view.zig`, replace the body of `contentView` (line 260) with the
   three-line `return if … else …` from Target. Delete the comment
   "Import progress / results and the removal Undo ride above the page…".
2. Add `notice_side_inset` and `headerBand` from Target directly above
   `fn desktopShell` (line 161).
3. In `desktopShell`, change the first child to `chromeBand(ui, headerBand(ui, model)),`.
4. Run the mechanical checks below.

## Boundaries

- Do NOT touch `src/header.native`, `src/model.zig`, or `src/strings.zig`.
- Do NOT add any animation, timer, or new Msg.
- Do NOT change notice durations or wording.
- If `contentView` or `desktopShell` no longer match the excerpts above (drift
  since commit bd23961), STOP and report instead of improvising.

## Verification

- **Mechanical** (from the repo root, with `$(npm prefix -g)/bin` on `PATH`):
  - `native test --yes` → `Build Summary: … tests passed`, no failures.
  - `native check` → `checked 3 markup files against the model contract, app.zon`
    and no warnings.
- **Feel check**: `native build --yes -Dautomation=true`, run
  `./zig-out/bin/wellmusic`, import a song you already have (Add Song → pick a
  file already in the library) so the "skipped" notice appears, then:
  - `native automate screenshot wellmusic-canvas` while the notice shows and
    again after it clears: the album grid's first row is at the SAME y in both.
  - The notice text sits centred in the header band, clear of the traffic lights
    and of the `⋯` button; a long notice is clipped, never overlapping `⋯`.
  - Dragging the window by the header still works, including across the notice
    text (only the Undo / × buttons should take clicks).
  - The `⋯` menu still opens while a notice is showing.
  - Back up `~/Library/Application Support/wellmusic/library.txt` and
    `session.txt` before the feel check and restore them afterwards.
- **Done when**: the page never changes position when a notice appears or
  clears, and all existing tests pass.
