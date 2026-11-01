//! wellmusic views: a desktop catalog, album detail, and transport shell.
//!
//! Zig-only sections remain what markup cannot express: rounded-square
//! cover images (`ElementOptions.image` outside the avatar), the album
//! grid's width-derived column count, per-track native context menus,
//! and the desktop composition itself.

const std = @import("std");
const native_sdk = @import("native_sdk");
const model_mod = @import("model.zig");
const strings = @import("strings.zig");

const canvas = native_sdk.canvas;

pub const Model = model_mod.Model;
pub const Msg = model_mod.Msg;
pub const Ui = canvas.Ui(Msg);

pub const header_markup = @embedFile("header.native");
pub const nowplaying_markup = @embedFile("nowplaying.native");
pub const CompiledHeaderView = canvas.CompiledMarkupView(Model, Msg, header_markup);
pub const CompiledNowPlayingView = canvas.CompiledMarkupView(Model, Msg, nowplaying_markup);

// The album detail heading: a markup span paragraph (one bold 2.05x-scaled
// run bound to the open album's title), compiled like the other fragments.
// The tests hold it
// widget-for-widget equal to the builder paragraph it replaced.
pub const AlbumTitleView = canvas.CompiledMarkupView(Model, Msg, @embedFile("album_title.native"));

// The album grid is ADAPTIVE: the layout system's grid takes a fixed
// column count (rows and columns never flow-wrap children), so the
// column count is derived here, per rebuild, from the canvas width the
// model tracks (`canvas_resized`, mirrored from presented frames). The
// rule is the standard adaptive-grid register: as many min-width tiles
// as fit the row, the leftover split evenly — tiles grow modestly until
// one more column fits, then snap back toward the minimum.
/// The narrowest a DESKTOP album tile may get. Sized so the cover (tile
/// width minus the hover-wash inset on both sides) never drops below the
/// generous cover the fixed four-column grid established.
const min_tile_width: f32 = 232;
/// Gap between bare tiles. Tighter than the old carded grid on purpose:
/// with no card chrome the gap IS the whole separation between covers,
/// and the bare music-library register reads best with covers closer
/// together than boxed cards were.
const grid_gap: f32 = 10;
/// Inset between the tile's hover/press wash and the cover art: on a
/// bare tile the wash must show AROUND the art to read at all (the art
/// would paint over a same-sized wash), so each tile keeps a thin halo.
const tile_padding: f32 = 6;
/// Cover corner radius on album tiles. Soft enough to read as music
/// artwork (Apple Music ~10pt), not a sharp card. The tile's press/focus
/// wash uses `tile_radius` so the nested arcs stay concentric
/// (`outer = inner + padding`).
const cover_radius: f32 = 10;
const tile_radius: f32 = cover_radius + tile_padding;
/// Vertical gap between the cover and the title/artist block.
const cover_text_gap: f32 = 6;
/// The title + artist block's height (one body line over one small
/// line), used to derive the tile's total height from its width.
const tile_text_height: f32 = 36;
const detail_cover_size: f32 = 200;
const content_padding: f32 = 24;

/// The width→columns rule, answered for one canvas width.
pub const GridFit = struct {
    /// How many min-width tiles (plus gaps) fit the content row.
    columns: usize,
    /// The evenly-grown tile width at that column count.
    tile_width: f32,
};

/// Columns = how many minimum-width tiles fit the padded content row;
/// tile width = the row split evenly at that count. Never below one
/// column, and the floor guard keeps the math total for degenerate
/// widths (a zero-sized test surface).
fn fitColumns(canvas_width: f32, min_tile: f32, padding: f32) GridFit {
    const available = @max(min_tile, canvas_width - padding * 2);
    const fitting = @floor((available + grid_gap) / (min_tile + grid_gap));
    const columns: usize = @intFromFloat(@max(1, fitting));
    const gaps = grid_gap * @as(f32, @floatFromInt(columns - 1));
    const tile_width = (available - gaps) / @as(f32, @floatFromInt(columns));
    return .{ .columns = columns, .tile_width = tile_width };
}

/// The desktop shell's grid fit (232pt tile floor, 24pt padding).
pub fn gridFit(canvas_width: f32) GridFit {
    return fitColumns(canvas_width, min_tile_width, content_padding);
}

// ------------------------------------------------------------------ root

pub fn rootView(ui: *Ui, model: *const Model) Ui.Node {
    const shell = desktopShell(ui, model);
    if (model.isEditingAlbum()) {
        return ui.el(.stack, .{ .grow = 1 }, .{
            shell,
            editDialog(ui, model, .album),
        });
    }
    if (!model.isEditingTrack()) return shell;
    // Modal edit dialog sits above the shell; Escape / click-outside
    // dismisses through `on_dismiss` without saving.
    return ui.el(.stack, .{ .grow = 1 }, .{
        shell,
        editDialog(ui, model, .track),
    });
}

const EditKind = enum { track, album };

/// The edit-song / edit-album dialog: one shape, two vocabularies.
fn editDialog(ui: *Ui, model: *const Model, kind: EditKind) Ui.Node {
    const save: Msg = if (kind == .track) .save_edit_track else .save_edit_album;
    const close: Msg = if (kind == .track) .close_edit_track else .close_edit_album;
    const heading = model.str(if (kind == .track) .edit_song else .edit_album);
    const title_hint = model.str(if (kind == .track) .song_title else .album_title);
    const artist_label = model.str(if (kind == .track) .song_artist else .album_artist);
    return ui.el(.dialog, .{
        .width = 420,
        .padding = 20,
        .on_dismiss = close,
        .semantics = .{ .label = heading },
    }, .{
        ui.column(.{ .gap = 14 }, .{
            ui.text(.{}, heading),
            ui.column(.{ .gap = 6 }, .{
                ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, model.str(.title)),
                ui.textField(.{
                    .text = model.editTitle(),
                    .placeholder = title_hint,
                    .on_input = Ui.inputMsg(.edit_title),
                    .on_submit = save,
                    .autofocus = true,
                    .grow = 1,
                    .semantics = .{ .label = title_hint },
                }),
            }),
            ui.column(.{ .gap = 6 }, .{
                ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, model.str(.artist)),
                ui.textField(.{
                    .text = model.editArtist(),
                    .placeholder = model.str(.artist_name),
                    .on_input = Ui.inputMsg(.edit_artist),
                    .on_submit = save,
                    .grow = 1,
                    .semantics = .{ .label = artist_label },
                }),
            }),
            ui.row(.{ .gap = 8, .main = .end }, .{
                ui.button(.{ .variant = .ghost, .on_press = close }, model.str(.cancel)),
                ui.button(.{ .variant = .primary, .on_press = save }, model.str(.save)),
            }),
        }),
    });
}

/// The desktop composition, exactly as the app has always shipped it:
/// the markup header bar (titlebar drag surface, chrome-inset padding),
/// the content switch, and the markup now-playing rail — with an
/// optional play-next queue panel above the transport.
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

fn desktopShell(ui: *Ui, model: *const Model) Ui.Node {
    return ui.column(.{ .grow = 1 }, .{
        chromeBand(ui, headerBand(ui, model)),
        // Paint the middle with the page token — layout backgrounds do
        // not fill, and relying on GPU clear alone left the body one
        // frame (or one rebuild path) behind chrome after a theme flip.
        pageBand(ui, contentView(ui, model)),
        if (model.queue_open) queuePanel(ui, model) else ui.el(.stack, .{}, .{}),
        chromeBand(ui, CompiledNowPlayingView.build(ui, model)),
    });
}

/// Full-bleed chrome over the page fill. Layout `row`/`column` backgrounds
/// do not paint — only surface widgets (panel, card, …) do — so the
/// header, queue, and now-playing band must be panels. Zero radius and
/// stroke keep them flush titlebar/transport strips rather than cards.
fn chromeBand(ui: *Ui, child: Ui.Node) Ui.Node {
    return ui.panel(.{
        .style = .{ .stroke_width = 0, .radius = 0 },
        .style_tokens = .{ .background = .surface },
    }, .{child});
}

/// Full-bleed library body: same panel trick as `chromeBand`, but filled
/// with the page token so the middle rebuilds its fill with the chrome
/// bands on every theme change (clear color alone is not enough).
fn pageBand(ui: *Ui, child: Ui.Node) Ui.Node {
    return ui.panel(.{
        .grow = 1,
        .style = .{ .stroke_width = 0, .radius = 0 },
        .style_tokens = .{ .background = .background },
    }, .{child});
}

fn queuePanel(ui: *Ui, model: *const Model) Ui.Node {
    const rows = model.queuedTracks(ui.arena);
    return chromeBand(ui, ui.column(.{
        .semantics = .{ .label = model.str(.playlist) },
    }, .{
        // No top hairline: chrome-vs-page fill separates the band.
        ui.row(.{ .padding = 12, .gap = 12, .cross = .center }, .{
            ui.text(.{ .grow = 1 }, strings.playlistHeading(ui.arena, model.lang, rows.len)),
            if (rows.len > 0)
                ui.button(.{ .variant = .ghost, .on_press = .clear_queue }, model.str(.playlist_clear))
            else
                ui.el(.stack, .{}, .{}),
        }),
        if (rows.len == 0)
            ui.column(.{ .padding = 12, .gap = 4 }, .{
                ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, model.str(.playlist_empty)),
                ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, model.str(.playlist_empty_hint)),
            })
        else
            ui.column(.{ .padding = 8, .gap = 0 }, .{
                ui.eachCtx(model, rows, queueRowKey, queueRow),
            }),
    }));
}

fn queueRowKey(row: *const model_mod.TrackRow) canvas.UiKey {
    return canvas.uiKey(row.id);
}

/// A pressable playlist row: a click plays that entry (or toggles pause
/// on the loaded one), the × removes it.
fn queueRow(ui: *Ui, model: *const Model, row: *const model_mod.TrackRow) Ui.Node {
    // No drag-to-reorder in this SDK's Zig views: the row menu moves it.
    const menu = ui.arena.dupe(Ui.ContextMenuItem, &.{
        .{ .label = model.str(.move_up), .msg = Msg{ .move_queued = .{ .id = row.id, .move = .up } } },
        .{ .label = model.str(.move_down), .msg = Msg{ .move_queued = .{ .id = row.id, .move = .down } } },
        .{ .label = model.str(.move_to_top), .msg = Msg{ .move_queued = .{ .id = row.id, .move = .top } } },
        .{ .label = model.str(.move_to_bottom), .msg = Msg{ .move_queued = .{ .id = row.id, .move = .bottom } } },
        .{ .label = model.str(.remove_from_playlist), .msg = Msg{ .remove_queued = row.id } },
    }) catch &.{};
    return ui.el(.list_item, .{
        // 40pt: the desktop hit-area floor, clearing the × button.
        .height = 40,
        .padding = 4,
        .gap = 10,
        .cross = .center,
        .on_press = Msg{ .play_track = row.id },
        .context_menu = menu,
        .semantics = .{ .role = .listitem, .label = strings.playlistRowLabel(ui.arena, model.lang, row.title) },
    }, .{
        trackIndicator(ui, row),
        ui.column(.{ .gap = 1, .grow = 1 }, .{
            ui.text(.{ .wrap = false, .style_tokens = if (row.now) .{ .foreground = .accent } else .{} }, row.title),
            ui.text(.{ .size = .sm, .wrap = false, .style_tokens = .{ .foreground = .text_muted } }, row.subtitle),
        }),
        ui.button(.{
            .variant = .ghost,
            .size = .sm,
            .icon = "x",
            .on_press = Msg{ .remove_queued = row.id },
            .semantics = .{ .label = model.str(.remove_from_playlist) },
        }, ""),
    });
}

fn contentView(ui: *Ui, model: *const Model) Ui.Node {
    return if (model.open_album) |album_id|
        albumDetailView(ui, model, album_id)
    else
        albumGridView(ui, model);
}

// ------------------------------------------------------------- album grid

fn albumGridView(ui: *Ui, model: *const Model) Ui.Node {
    const cells = model.visibleAlbums(ui.arena);
    // Controlled scroll: the model stores the applied offset
    // (`grid_scrolled`) and echoes it back, so a rebuild mid-gesture
    // can never reset the region.
    return ui.scroll(.{
        .grow = 1,
        .value = model.grid_scroll,
        .on_scroll = Ui.scrollMsg(.grid_scrolled),
        .semantics = .{ .label = model.str(.album_grid) },
    }, ui.column(.{ .padding = content_padding, .gap = 20 }, .{
        if (cells.len == 0) emptyState(ui, model) else albumGrid(ui, model, gridFit(model.canvas_width), cells),
    }));
}

/// The shared adaptive grid body: one bare tile per visible album, sized
/// by the caller's fit.
const TileCtx = struct { fit: GridFit, model: *const Model };

fn albumGrid(ui: *Ui, model: *const Model, fit: GridFit, cells: []const model_mod.AlbumCell) Ui.Node {
    // The grid node is EXPLICITLY sized to its shown columns rather than
    // stretched to the row, because the engine divides the grid's width
    // evenly among its columns: an exact width makes each cell exactly
    // one tile wide, and a short result set keeps
    // tile-sized covers left-aligned instead of ballooning across the
    // row. The tail row left-aligns the same way — cells fill in row
    // order from the leading edge.
    const columns = @min(fit.columns, cells.len);
    const row_width = @as(f32, @floatFromInt(columns)) * (fit.tile_width + grid_gap) - grid_gap;
    return ui.el(.grid, .{
        .width = row_width,
        .columns = columns,
        .gap = grid_gap,
        .semantics = .{ .role = .list, .label = model.str(.albums) },
    }, ui.eachCtx(TileCtx{ .fit = fit, .model = model }, cells, albumKey, albumTile));
}

fn albumKey(cell: *const model_mod.AlbumCell) canvas.UiKey {
    return canvas.uiKey(cell.id);
}

/// One bare album tile: the cover IS the tile — no card fill, border, or
/// shadow around it (the flat `list_item` composite, the same chromeless
/// register the track rows use). Hover is QUIET: the pointer rests on
/// cover art, not a control register, so hovering changes nothing
/// visually (the pointer cursor is the whole hover affordance) — the
/// quiet-surface style knob below states exactly that. A press still
/// paints the standard pressed wash (the visible moment of commitment),
/// keyboard focus still draws the standard ring, and the whole tile —
/// art and text — stays one hit target with the album-by-artist
/// accessible label.
fn albumTile(ui: *Ui, ctx: TileCtx, cell: *const model_mod.AlbumCell) Ui.Node {
    const model = ctx.model;
    const cover = ctx.fit.tile_width - tile_padding * 2;
    const desktop_menu = [_]Ui.ContextMenuItem{
        .{ .label = model.str(.play_album), .msg = Msg{ .play_album = cell.id } },
        .{ .label = model.str(.open_album), .msg = Msg{ .open_album = cell.id } },
        .{ .label = model.str(.edit_info), .msg = Msg{ .edit_album = cell.id } },
        .{ .label = model.str(.change_cover), .msg = Msg{ .change_cover = cell.id } },
        .{ .label = model.str(.remove_album), .msg = Msg{ .remove_album = cell.id } },
    };
    return ui.el(.list_item, .{
        // Height derives from width: the square cover plus the text
        // block and paddings, so tiles stay uniform as they grow
        // between column-count breakpoints.
        .height = tile_padding * 2 + cover + cover_text_gap + tile_text_height,
        .padding = tile_padding,
        // Quiet hover + concentric radius: the wash arc is cover +
        // padding so the nested cover corner never fights the parent.
        .style = .{ .quiet_hover = true, .radius = tile_radius },
        .on_press = Msg{ .open_album = cell.id },
        .context_menu = &desktop_menu,
        .semantics = .{ .role = .listitem, .label = strings.albumByArtist(ui.arena, model.lang, cell.title, cell.artist) },
    }, .{
        // list_item flows children horizontally; the single grown column
        // carries the vertical cover-over-text stack.
        ui.column(.{ .gap = cover_text_gap, .grow = 1 }, .{
            ui.avatar(.{
                .image = cell.cover,
                .width = cover,
                .height = cover,
                .style = .{ .radius = cover_radius },
                .semantics = .{ .label = strings.coverLabel(ui.arena, model.lang, cell.title) },
            }, cell.initials),
            ui.column(.{ .gap = 1 }, .{
                // One-line title/artist by design: elide behind a
                // trailing ellipsis at the tile width, never wrap
                // over the line below.
                tileTitle(ui, cell),
                ui.text(.{ .size = .sm, .wrap = false, .style_tokens = .{ .foreground = .text_muted } }, cell.artist),
            }),
        }),
    });
}

/// The tile's title line. The album that is loaded in the transport
/// leads with a small speaker — accent while it plays, muted while
/// paused — so the grid answers "what's on?" at a glance.
fn tileTitle(ui: *Ui, cell: *const model_mod.AlbumCell) Ui.Node {
    if (!cell.now) return ui.text(.{ .wrap = false }, cell.title);
    return ui.row(.{ .gap = 4, .cross = .center }, .{
        ui.icon(.{
            .width = 12,
            .height = 12,
            .style_tokens = .{ .foreground = if (cell.playing) .accent else .text_muted },
        }, "volume"),
        ui.text(.{ .wrap = false, .grow = 1, .style_tokens = if (cell.playing) .{ .foreground = .accent } else .{} }, cell.title),
    });
}

/// Shared Add control: one button, secondary menu for song vs album.
/// Used by the empty state so the empty surface keeps a direct import
/// entry point (the header overflow also offers Add Song / Add Album).
fn addMenuControl(ui: *Ui, model: *const Model, size: canvas.WidgetSize, variant: canvas.WidgetVariant) Ui.Node {
    return ui.el(.stack, .{}, .{
        ui.button(.{
            .size = size,
            .variant = variant,
            .icon = "plus",
            .selected = model.add_menu_open,
            .on_press = .toggle_add_menu,
            .semantics = .{ .label = model.str(.add_to_library) },
        }, ""),
        if (model.add_menu_open)
            ui.el(.dropdown_menu, .{
                .anchor = .below,
                .anchor_alignment = .start,
                .anchor_offset = 4,
                .on_dismiss = .close_add_menu,
                .semantics = .{ .label = model.str(.add_menu) },
            }, .{
                ui.el(.menu_item, .{ .icon = "music", .on_press = .add_music, .text = model.str(.add_song) }, .{}),
                ui.el(.menu_item, .{ .icon = "folder", .on_press = .import_album, .text = model.str(.add_album) }, .{}),
            })
        else
            ui.el(.stack, .{}, .{}),
    });
}

fn emptyState(ui: *Ui, model: *const Model) Ui.Node {
    // Surface-on-page elevation, no hard border: the theme zeroes
    // panel sm shadows so full-bleed bands stay smear-free; the
    // chrome step alone lifts this card off the gray/charcoal page.
    return ui.panel(.{
        .padding = 24,
        .style = .{ .stroke_width = 0 },
        .style_tokens = .{ .background = .surface, .radius = .lg },
        .semantics = .{ .label = model.str(.library_empty) },
    }, ui.column(.{ .gap = 10 }, .{
        ui.text(.{}, model.str(.library_empty)),
        ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, model.str(.library_empty_hint)),
        addMenuControl(ui, model, .default, .primary),
    }));
}

// ----------------------------------------------------------- album detail

fn albumDetailView(ui: *Ui, model: *const Model, album_id: u8) Ui.Node {
    const album = model.albumById(album_id) orelse return emptyState(ui, model);
    const rows = model.albumTrackRows(ui.arena, album_id);
    return ui.scroll(.{
        .grow = 1,
        .value = model.detail_scroll,
        .on_scroll = Ui.scrollMsg(.detail_scrolled),
        .semantics = .{ .label = model.str(.album_detail) },
    }, ui.column(.{ .padding = content_padding, .gap = 20 }, .{
        ui.row(.{}, .{
            backButton(ui, model),
            ui.spacer(1),
        }),
        ui.row(.{ .gap = 24 }, .{
            detailCover(ui, model, album, detail_cover_size),
            detailHeading(ui, model, album, rows.len),
        }),
        trackList(ui, model, rows),
    }));
}

/// The album detail cover with its desktop context menu.
fn detailCover(ui: *Ui, model: *const Model, album: model_mod.Album, size: f32) Ui.Node {
    const desktop_menu = [_]Ui.ContextMenuItem{
        .{ .label = model.str(.edit_info), .msg = Msg{ .edit_album = album.id } },
        .{ .label = model.str(.change_cover), .msg = Msg{ .change_cover = album.id } },
        .{ .label = model.str(.remove_album), .msg = Msg{ .remove_album = album.id } },
    };
    return ui.avatar(.{
        .image = model.coverFor(album.id),
        .width = size,
        .height = size,
        // Same cover radius as the grid tiles so detail and browse
        // share one corner language (outline comes from the theme).
        .style = .{ .radius = cover_radius },
        .context_menu = &desktop_menu,
        .semantics = .{ .label = strings.coverLabel(ui.arena, model.lang, album.title) },
    }, album.initials);
}

/// The album detail heading block: the "Album" eyebrow, the markup title
/// fragment, the artist/track-count line,
/// and the play control. Edit info / change cover live on the cover's
/// context menu, so the heading only mounts Play. The desktop shell
/// grows it beside the cover and bottom-aligns (main .end).
fn detailHeading(ui: *Ui, model: *const Model, album: model_mod.Album, track_count: usize) Ui.Node {
    return ui.column(.{
        .gap = 10,
        .grow = 1,
        .main = .end,
    }, .{
        ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, model.str(.album_eyebrow)),
        AlbumTitleView.build(ui, model),
        ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, strings.trackSummary(ui.arena, model.lang, album.artist, track_count, model.albumDurationMs(album.id))),
        ui.row(.{ .gap = 8, .cross = .center }, .{
            playAlbumButton(ui, model, album.id),
            ui.button(.{
                .variant = .ghost,
                .size = .default,
                .icon = "shuffle",
                .on_press = Msg{ .shuffle_album = album.id },
                .semantics = .{ .label = model.str(.shuffle_album) },
            }, ""),
            ui.spacer(1),
        }),
    });
}

/// Icon+text buttons via `ElementOptions.icon`: the icon is part of the
/// button's own rendering, so each control is one widget — one hit
/// target, no duplicated on_press, and the icon follows the button's
/// enabled/disabled tint for free. (These replaced the old overlay-stack
/// idiom the moment icon-in-button landed.) Both shells share the
/// control.
fn backButton(ui: *Ui, model: *const Model) Ui.Node {
    // Icon-only chevron: visible label is empty; VoiceOver still gets
    // "Back to albums". `.default` size keeps the 40pt desktop hit-area
    // floor once the text no longer widens the control.
    return ui.button(.{
        .variant = .ghost,
        .size = .default,
        .icon = "chevron-left",
        .on_press = .close_album,
        .semantics = .{ .label = model.str(.back_to_albums) },
    }, "");
}

fn playAlbumButton(ui: *Ui, model: *const Model, album_id: u8) Ui.Node {
    // Icon-only: visible label is empty; VoiceOver still gets "Play album".
    return ui.button(.{
        .variant = .primary,
        .size = .default,
        .icon = "play",
        .on_press = Msg{ .play_album = album_id },
        .semantics = .{ .label = model.str(.play_album) },
    }, "");
}

// ------------------------------------------------------------- track rows

/// Flat track rows with no inter-row gaps — the rows' washes are the
/// only separation.
fn trackList(ui: *Ui, model: *const Model, rows: []const model_mod.TrackRow) Ui.Node {
    return ui.el(.list, .{
        .semantics = .{ .role = .list, .label = model.str(.album_tracks) },
    }, ui.eachCtx(model, rows, trackKey, trackRowView));
}

fn trackKey(row: *const model_mod.TrackRow) canvas.UiKey {
    return canvas.uiKey(row.id);
}

/// One pressable track row: a FLAT list row (the list_item composite —
/// no border, no card chrome; hover is a full-width wash), with custom
/// children flowing horizontally inside it. A click selects; a double
/// click or Enter plays. The selection wears the inverted accent fill
/// under its knockout ink (`accent_text`, the same token
/// the filled Play Album button pairs with the accent, white under this
/// theme in both schemes), stated per-widget through style tokens so
/// the unselected rows keep their neutral hover/press washes.
fn trackRowView(ui: *Ui, model: *const Model, row: *const model_mod.TrackRow) Ui.Node {
    // Context menus are copied into the tree during build; allocate the
    // item slice in the build arena so removable rows can carry a third
    // action without fighting fixed-size array types.
    const desktop_menu: []const Ui.ContextMenuItem = blk: {
        if (row.removable) {
            break :blk ui.arena.dupe(Ui.ContextMenuItem, &.{
                .{ .label = model.str(.play_next), .msg = Msg{ .queue_track = row.id } },
                .{ .label = model.str(.edit_info), .msg = Msg{ .edit_track = row.id } },
                .{ .label = model.str(.remove_from_library), .msg = Msg{ .remove_track = row.id } },
            }) catch &.{};
        }
        break :blk ui.arena.dupe(Ui.ContextMenuItem, &.{
            .{ .label = model.str(.play_next), .msg = Msg{ .queue_track = row.id } },
        }) catch &.{};
    };
    return ui.el(.list_item, .{
        .global_key = canvas.uiKey(@as(u32, row.id)),
        .height = 44,
        .padding = 10,
        .gap = 12,
        .cross = .center,
        .selected = row.selected,
        .style_tokens = if (row.selected) .{ .background = .accent } else .{},
        .on_press = Msg{ .select_track = row.id },
        .on_double_press = Msg{ .play_track = row.id },
        .on_submit = Msg{ .play_track = row.id },
        .context_menu = desktop_menu,
        .semantics = .{ .role = .listitem, .label = row.title },
    }, .{
        trackIndicator(ui, row),
        if (row.subtitle.len == 0)
            ui.text(.{ .grow = 1, .style_tokens = rowTitleTokens(row) }, row.title)
        else
            ui.column(.{ .gap = 1, .grow = 1 }, .{
                ui.text(.{ .style_tokens = rowTitleTokens(row) }, row.title),
                ui.text(.{ .size = .sm, .style_tokens = rowMutedTokens(row) }, row.subtitle),
            }),
        durationText(ui, row),
    });
}

/// Row title ink: the accent's knockout ink (`accent_text`) on the
/// selected (accent) row — the inverted register. The window-background
/// token this used to take is only light-scheme white; in dark mode it
/// resolves near-black and vanished into the accent fill, while
/// `accent_text` is the ink the theme pairs with the accent in BOTH
/// schemes (the filled Play Album button's white). Accent on the loaded
/// track's row, default otherwise.
fn rowTitleTokens(row: *const model_mod.TrackRow) canvas.StyleTokenRefs {
    if (row.selected) return .{ .foreground = .accent_text };
    if (row.now) return .{ .foreground = .accent };
    return .{};
}

/// Row secondary ink (subtitle, duration, track number): muted at rest,
/// the accent's knockout ink on the selected row — muted gray on the
/// accent fill would fail the contrast the inverted register exists to
/// keep, and only `accent_text` keeps that promise in both schemes.
fn rowMutedTokens(row: *const model_mod.TrackRow) canvas.StyleTokenRefs {
    if (row.selected) return .{ .foreground = .accent_text };
    return .{ .foreground = .text_muted };
}

/// The leading track-row slot: a STATE icon on the loaded track's row —
/// the pause glyph while audio is playing, the play glyph while it is
/// paused (the icon names the state, matching the transport button's
/// convention) — and the track number everywhere else. Icons are
/// decoration (never hit-tested), so the row's press handling is
/// untouched; the fixed 24px slot is a shared column — numbers are
/// center-aligned so their glyph axis matches the centered icons.
/// On the selected row the icon takes the inverted ink like the text —
/// an accent glyph would vanish into the accent fill.
fn trackIndicator(ui: *Ui, row: *const model_mod.TrackRow) Ui.Node {
    if (!row.now) {
        return ui.text(.{
            .width = 24,
            .size = .sm,
            .text_alignment = .center,
            .style_tokens = rowMutedTokens(row),
        }, row.number);
    }
    const icon_tokens: canvas.StyleTokenRefs = if (row.selected)
        .{ .foreground = .accent_text }
    else if (row.playing)
        .{ .foreground = .accent }
    else
        .{ .foreground = .text_muted };
    // Play triangles are optically heavy on the left — a 2px lead inset
    // centers the glyph by eye inside the fixed 24px number column.
    // Pause is symmetric and stays geometrically centered.
    return ui.row(.{ .width = 24, .cross = .center, .main = .center }, .{
        if (row.playing)
            ui.icon(.{ .width = 14, .height = 14, .style_tokens = icon_tokens }, "pause")
        else
            ui.row(.{ .width = 16, .cross = .center }, .{
                ui.el(.stack, .{ .width = 2 }, .{}),
                ui.icon(.{ .width = 14, .height = 14, .style_tokens = icon_tokens }, "play"),
            }),
    });
}

/// Right-aligned fixed-width duration. The fixed width is a column: it
/// keeps every row's duration right edge aligned regardless of digit
/// count ("8:05" vs "12:41"), sized for the widest plausible value.
fn durationText(ui: *Ui, row: *const model_mod.TrackRow) Ui.Node {
    // 56pt fits "h:mm:ss" for the hour-long recordings ambient albums carry.
    var node = ui.text(.{ .width = 56, .size = .sm, .style_tokens = rowMutedTokens(row) }, row.duration);
    node.widget.text_alignment = .end;
    return node;
}

// ---------------------------------------------------------------- shared
