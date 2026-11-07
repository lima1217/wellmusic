//! wellmusic theme: the Geist pack with the accent moved to the pack's
//! pink scale. The pack resolves the whole register (palette, control
//! tables, type scale, metrics) per scheme and contrast; the app layers
//! ONE brand decision on top through `DesignTokenOverrides` — it never
//! forks the pack. High-contrast requests skip the accent override and
//! take the pack's high-contrast register (accessibility beats brand),
//! but still adopt the CJK-capable UI face when one was loaded at boot.
//! Reduce-motion zeroes the motion tokens through the theme options.

const native_sdk = @import("native_sdk");
const ui_font = @import("ui_font.zig");

const canvas = native_sdk.canvas;
const Color = canvas.Color;

/// The accent, one hue (OKLCH h = 4°, a raspberry pink) at two
/// lightnesses. It is used as TEXT (the playing song's title) as well as
/// a fill, so each scheme takes the step that reads as text there — the
/// old single #cf2668 measured 4.46:1 on the light page and 3.74:1 on
/// the dark one, both under the 4.5:1 text bar. Numbers:
/// docs/review/scripts/color_audit.py.
///   light: oklch(0.50 0.20 4) = #b60356 — 5.9:1 on page, 6.7:1 under white
///   dark:  oklch(0.72 0.17 4) = #f87098 — 7.0:1 on page, 7.0:1 under ink
const pink_800 = Color.rgb8(182, 3, 86);
const pink_dark = Color.rgb8(248, 112, 152);

/// The ink on the accent fill: white on the deep light-scheme pink, the
/// warm near-black page on the light dark-scheme pink.
const pink_ink = Color.rgb8(255, 255, 255);
const pink_ink_dark = Color.rgb8(18, 16, 14);

/// Cover-art outline: pure black/white at ~10% alpha — never a tinted
/// neutral from the palette. A tinted hairline picks up the surface
/// underneath and reads as dirt on the image edge; neutral ink stays a
/// clean separator on every cover (grid tile, detail, now-playing).
const cover_outline_light = Color.rgba8(0, 0, 0, 26);
const cover_outline_dark = Color.rgba8(255, 255, 255, 26);

/// Quiet control hairline — softer than Geist's stock 8%/14% so menus
/// and any remaining dividers don't read as a cage of fine wires. Band
/// separation comes from page↔chrome fill lift, not from drawn rules.
const hairline_light = Color.rgba8(0, 0, 0, 12); // ~5%
const hairline_dark = Color.rgba8(255, 255, 255, 18); // ~7%

/// Slider thumb outline: Geist dark uses solid black (#000), which
/// reads as a hard wire on charcoal chrome. Match the cover-outline
/// language — pure ink at low alpha — in both schemes.
const slider_outline_light = Color.rgba8(0, 0, 0, 26);
const slider_outline_dark = Color.rgba8(255, 255, 255, 26);

/// Absolute knockout for inverted chips (button-group selected ink).
/// Must stay pure white/black — NOT the page `background` — because the
/// pack wires `active_foreground` to `colors.background`, and our page
/// is intentionally one step off pure so chrome can lift.
const knockout_light = Color.rgb8(255, 255, 255);
const knockout_dark = Color.rgb8(0, 0, 0);

/// Elevation neutrals: WARM grays. Same OKLCH lightness ladder as before,
/// now with a trace of chroma at a paper-like hue (C ≈ 0.006–0.007,
/// h = 75°) instead of C = 0. Pure-neutral grays read cold next to cover
/// art; this tint is below what reads as "beige" but enough to warm the
/// page. Equal L gaps keep page → chrome → wash → press one ladder.
///
/// Dark (charcoal, not OLED void), C = 0.006:
///   page    oklch(0.175) → #12100e
///   chrome  oklch(0.245) → #22201d
///   subtle  oklch(0.290) → #2d2b28
///   pressed oklch(0.330) → #373532   (selected row: the playing title's
///                                    pink still clears 4.5:1 on it)
const dark_page = Color.rgb8(18, 16, 14);
const dark_chrome = Color.rgb8(34, 32, 29);
const dark_subtle = Color.rgb8(45, 43, 40);
const dark_pressed = Color.rgb8(55, 53, 50);
/// Dark ink: muted lifted to L 0.76 so it clears 4.5:1 on a selected row
/// too (L 0.72 measured 4.36:1 there).
const dark_text = Color.rgb8(241, 238, 234); // oklch(0.950 0.006 75)
const dark_text_muted = Color.rgb8(179, 177, 173); // oklch(0.760 0.006 75)

/// Light (warm paper page under near-white chrome), C = 0.007:
///   page    oklch(0.955) → #f3efeb
///   chrome  oklch(1.000, C 0.003) → #fffffd
///   subtle  oklch(0.920) → #e7e4df
///   pressed oklch(0.880) → #dad7d2
const light_page = Color.rgb8(243, 239, 235);
const light_chrome = Color.rgb8(255, 255, 253);
const light_subtle = Color.rgb8(231, 228, 223);
const light_pressed = Color.rgb8(218, 215, 210);
/// Light ink.
const light_text = Color.rgb8(24, 22, 19); // oklch(0.200 0.007 75)
const light_text_muted = Color.rgb8(74, 71, 68); // oklch(0.400 0.007 75)

/// The app's one brand statement, layered over whichever scheme/contrast
/// register the pack resolves. Identity slots plus the fluid-feel pair:
///
/// - `colors.accent`/`accent_text`: the filled-primary pair — the
///   selected track row's inverted fill, the header switcher's active
///   segment, the loaded row's title ink, and every
///   control fill that derives from the accent channel (checkbox,
///   switch, progress).
/// - `colors.focus_ring`: the pack spends its identity hue on focus;
///   with the identity moved to pink, the ring follows so focus and
///   accent chrome read as one system (pink on the page clears the 3:1
///   non-text bar in both schemes). The ring is stated PER SCHEME: the
///   accent itself in light, `canvas.accentFocusRing`'s desaturated,
///   contrast-floored step in dark — full-chroma pink glares neon
///   against the dark palette, and the derivation is the same one the
///   manifest `theme_accent` channel applies, so both authoring tiers
///   land the identical ring.
/// - `controls.slider.active_background`: the pack's slider table states
///   its own hue for the filled range rather than deriving from the
///   accent channel, so the volume slider needs the same move stated
///   once more or it would keep the pack's stock hue.
/// - `controls.slider.border`: soft pure-ink outline (never Geist dark's
///   solid black thumb wire).
/// - `colors.border`: quieter than the pack hairline so control outlines
///   don't compete with cover art and fill elevation.
/// - `controls.avatar.border`: the cover-art outline above, per scheme.
/// - `controls.button_group.active_foreground`: pure knockout — the pack
///   would otherwise reuse page `background`, which is no longer pure.
/// - Both schemes: `colors.background`/`surface`/`surface_subtle`/
///   `surface_pressed` plus matched `text`/`text_muted` — page one
///   quiet step off the chrome so the header and now-playing bar read
///   as bands; body ink keeps an honest L gap on the lifted page.
/// - `shadow.sm` zeroed: full-bleed chrome/page panels must not cast a
///   settle shadow into the neighboring band (that smear is what made
///   the middle look "wrong" after a theme flip). Overlay `md` stays.
/// - `scroll.overscroll`: rubber-band at content edges — continuous
///   resistance past the bound instead of a hard stop (Apple §9).
///
/// No `motion` override: the pack's durations stand. An override here
/// lands AFTER ThemeOptions zeroes motion for Reduce Motion, so it
/// silently switched motion back on for exactly the users who asked
/// for none (and nothing in this UI animates on these tokens anyway).
fn accentOverridesFor(color_scheme: canvas.ColorScheme) canvas.DesignTokenOverrides {
    return .{
        .colors = .{
            .accent = switch (color_scheme) {
                .light => pink_800,
                .dark => pink_dark,
            },
            .accent_text = switch (color_scheme) {
                .light => pink_ink,
                .dark => pink_ink_dark,
            },
            .focus_ring = canvas.accentFocusRing(switch (color_scheme) {
                .light => pink_800,
                .dark => pink_dark,
            }, color_scheme),
            .background = switch (color_scheme) {
                .light => light_page,
                .dark => dark_page,
            },
            .surface = switch (color_scheme) {
                .light => light_chrome,
                .dark => dark_chrome,
            },
            .surface_subtle = switch (color_scheme) {
                .light => light_subtle,
                .dark => dark_subtle,
            },
            .surface_pressed = switch (color_scheme) {
                .light => light_pressed,
                .dark => dark_pressed,
            },
            .text = switch (color_scheme) {
                .light => light_text,
                .dark => dark_text,
            },
            .text_muted = switch (color_scheme) {
                .light => light_text_muted,
                .dark => dark_text_muted,
            },
            .border = switch (color_scheme) {
                .light => hairline_light,
                .dark => hairline_dark,
            },
        },
        .shadow = .{
            // Full-bleed bands (header / page / transport) are panels;
            // sm settle would paint a tinted smear across the middle.
            .sm = .{ .y = 0, .blur = 0, .spread = 0 },
        },
        .controls = .{
            .slider = .{
                // Volume is a level, not a state: a neutral fill keeps
                // the accent for what is ON (shuffle, repeat, playing).
                .active_background = switch (color_scheme) {
                    .light => light_text_muted,
                    .dark => dark_text_muted,
                },
                .border = switch (color_scheme) {
                    .light => slider_outline_light,
                    .dark => slider_outline_dark,
                },
            },
            .avatar = .{
                .border = switch (color_scheme) {
                    .light => cover_outline_light,
                    .dark => cover_outline_dark,
                },
            },
            .button_group = .{
                .active_foreground = switch (color_scheme) {
                    .light => knockout_light,
                    .dark => knockout_dark,
                },
            },
        },
        .scroll = .{ .overscroll = .rubber_band },
    };
}

/// Stamp the CJK-capable face onto resolved tokens at RUNTIME only.
/// `light_colors` / `dark_colors` stay comptime (palette assertions) and
/// must not touch the boot-loaded face.
///
/// Intentionally leaves `mono_font_id` alone: no CJK text currently
/// renders through the mono slot (timestamps / tabular numbers stay on
/// Geist Mono). Cover mono too if titles ever move there.
fn withUiFont(base: canvas.DesignTokens) canvas.DesignTokens {
    if (!ui_font.ready()) return base;
    return base.withOverrides(.{
        .typography = .{
            .font_id = ui_font.font_id,
            .button_font_id = ui_font.font_id,
            .font_family = .system_sans,
        },
    });
}

/// Pure standard-contrast Geist register + brand accents. Comptime-safe:
/// no runtime font state. Shared by `tokens` and the exported palettes so
/// pack / accent choices cannot drift apart.
fn standardTokens(scheme: canvas.ColorScheme) canvas.DesignTokens {
    return resolveGeist(scheme, .standard, false);
}

fn resolveGeist(scheme: canvas.ColorScheme, contrast: canvas.ColorContrast, reduce_motion: bool) canvas.DesignTokens {
    const options = canvas.ThemeOptions{
        .pack = .geist,
        .color_scheme = scheme,
        .contrast = contrast,
        .reduce_motion = reduce_motion,
    };
    // High contrast takes the pack's own loud register with no brand
    // layer: white on the pink fill sits at ~5.1:1, well under the
    // loud-contrast bar, so the accent honestly bows out.
    if (contrast == .high) return canvas.DesignTokens.theme(options);
    return canvas.DesignTokens.themeWithOverrides(options, accentOverridesFor(scheme));
}

pub fn tokens(scheme: native_sdk.ColorScheme, high_contrast: bool, reduce_motion: bool) canvas.DesignTokens {
    const color_scheme: canvas.ColorScheme = switch (scheme) {
        .light => .light,
        .dark => .dark,
    };
    // High contrast: pack loud register, still stamp the UI face —
    // readable CJK beats brand pink.
    if (high_contrast) return withUiFont(resolveGeist(color_scheme, .high, reduce_motion));
    // Standard contrast: share `standardTokens` when motion is live;
    // with reduce_motion, re-resolve so ThemeOptions still zeroes motion
    // through the pack before accent overrides layer on top (same order
    // as the pre-refactor themeWithOverrides path).
    const base = if (reduce_motion)
        resolveGeist(color_scheme, .standard, true)
    else
        standardTokens(color_scheme);
    return withUiFont(base);
}

/// The resolved standard-contrast palettes, exported for the suite's
/// theme assertions: the pack's scheme register with the accent
/// override already applied — exactly what `tokens` hands the runtime
/// before the optional UI-face stamp.
pub const light_colors = standardTokens(.light).colors;
pub const dark_colors = standardTokens(.dark).colors;
