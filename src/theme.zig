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

/// Brand pink solid fill. Authored in OKLCH so hue stays stable across
/// lightness (HSL's 336° drifts ~12° toward red here) and chroma stays
/// inside sRGB: oklch(0.565 0.205 4) = #cf2668. One constant serves
/// light and dark alike — only the quiet low steps flip per scheme.
const pink_800 = Color.rgb8(207, 38, 104);

/// The ink on the pink fill: the pack pairs every solid fill with white
/// knockout text. White clears ~5.1:1 on this pink — the honest
/// readable ink in both schemes, since the fill itself is the same
/// under both.
const pink_ink = Color.rgb8(255, 255, 255);

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

/// Elevation neutrals, authored as OKLCH lightness steps (C = 0) then
/// snapped to sRGB. Equal L gaps keep page → chrome → wash → press
/// reading as one ladder in both schemes (~0.05–0.07 between rungs).
///
/// Dark (music-library charcoal, not OLED void):
///   page    oklch(0.175 0 0) → #101010
///   chrome  oklch(0.245 0 0) → #202020
///   subtle  oklch(0.300 0 0) → #2e2e2e
///   pressed oklch(0.360 0 0) → #3d3d3d
const dark_page = Color.rgb8(16, 16, 16);
const dark_chrome = Color.rgb8(32, 32, 32);
const dark_subtle = Color.rgb8(46, 46, 46);
const dark_pressed = Color.rgb8(61, 61, 61);
/// Dark ink: body L≥0.75 on page L≈0.18; muted keeps secondary quieter.
const dark_text = Color.rgb8(238, 238, 238); // oklch(0.950 0 0)
const dark_text_muted = Color.rgb8(164, 164, 164); // oklch(0.720 0 0)

/// Light (soft gray page under white chrome — Apple Music / Finder):
///   page    oklch(0.955 0 0) → #f0f0f0
///   chrome  oklch(1.000 0 0) → #ffffff
///   subtle  oklch(0.920 0 0) → #e4e4e4
///   pressed oklch(0.880 0 0) → #d7d7d7
const light_page = Color.rgb8(240, 240, 240);
const light_chrome = Color.rgb8(255, 255, 255);
const light_subtle = Color.rgb8(228, 228, 228);
const light_pressed = Color.rgb8(215, 215, 215);
/// Light ink: body L≤0.45 on page L≈0.96.
const light_text = Color.rgb8(22, 22, 22); // oklch(0.200 0 0)
const light_text_muted = Color.rgb8(72, 72, 72); // oklch(0.400 0 0)

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
            .accent = pink_800,
            .accent_text = pink_ink,
            .focus_ring = canvas.accentFocusRing(pink_800, color_scheme),
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
                .active_background = pink_800,
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
