#!/usr/bin/env python3
"""WellMusic color audit: OKLCH of every theme color and WCAG 2.x contrast
of every text/background pair the UI draws. Reads src/theme.zig directly
(Color.rgb8 literals) so the numbers always describe the code as it is.

    python3 docs/review/scripts/color_audit.py            # report
    python3 docs/review/scripts/color_audit.py --warm L C H  # sRGB for an OKLCH
"""
import math, re, sys, pathlib

def srgb_to_linear(c):
    c /= 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

def linear_to_srgb(c):
    c = max(0.0, min(1.0, c))
    v = 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055
    return round(v * 255)

def oklch(rgb):
    r, g, b = (srgb_to_linear(v) for v in rgb)
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l, m, s = (math.copysign(abs(x) ** (1 / 3), x) for x in (l, m, s))
    L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
    A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    C = math.hypot(A, B)
    H = math.degrees(math.atan2(B, A)) % 360
    return L, C, H

def from_oklch(L, C, H):
    A, B = C * math.cos(math.radians(H)), C * math.sin(math.radians(H))
    l = (L + 0.3963377774 * A + 0.2158037573 * B) ** 3
    m = (L - 0.1055613458 * A - 0.0638541728 * B) ** 3
    s = (L - 0.0894841775 * A - 1.2914855480 * B) ** 3
    r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    return tuple(linear_to_srgb(v) for v in (r, g, b))

def luminance(rgb):
    r, g, b = (srgb_to_linear(v) for v in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b

def contrast(a, b):
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)

def theme_colors(path):
    src = pathlib.Path(path).read_text()
    out = {}
    for name, r, g, b in re.findall(r"const (\w+) = Color\.rgb8\((\d+), (\d+), (\d+)\)", src):
        out[name] = (int(r), int(g), int(b))
    return out

# The pairs the UI actually draws: (ink, ground, minimum, what).
PAIRS = [
    ("light_text", "light_page", 4.5, "body text on page"),
    ("light_text", "light_chrome", 4.5, "body text on header / bar / queue"),
    ("light_text_muted", "light_page", 4.5, "secondary text on page"),
    ("light_text_muted", "light_chrome", 4.5, "secondary text on chrome"),
    ("light_text", "light_pressed", 4.5, "text on selected row"),
    ("light_text_muted", "light_pressed", 4.5, "secondary text on selected row"),
    ("light_text", "light_subtle", 4.5, "text on secondary button"),
    ("pink_800", "light_page", 4.5, "accent text (playing title) on page"),
    ("pink_800", "light_pressed", 4.5, "accent text on selected playing row"),
    ("pink_800", "light_chrome", 3.0, "accent icon on chrome (non-text)"),
    ("pink_ink", "pink_800", 4.5, "white on accent button"),
    ("dark_text", "dark_page", 4.5, "body text on page"),
    ("dark_text", "dark_chrome", 4.5, "body text on chrome"),
    ("dark_text_muted", "dark_page", 4.5, "secondary text on page"),
    ("dark_text_muted", "dark_chrome", 4.5, "secondary text on chrome"),
    ("dark_text", "dark_pressed", 4.5, "text on selected row"),
    ("dark_text_muted", "dark_pressed", 4.5, "secondary text on selected row"),
    ("dark_text", "dark_subtle", 4.5, "text on secondary button"),
    ("pink_dark", "dark_page", 4.5, "accent text on page"),
    ("pink_dark", "dark_pressed", 4.5, "accent text on selected playing row"),
    ("pink_dark", "dark_chrome", 4.5, "accent text in queue / bar"),
    ("pink_ink_dark", "pink_dark", 4.5, "ink on accent button"),
    ("pink_800", "light_subtle", 3.0, "accent icon on hover wash (non-text)"),
]

def main():
    if len(sys.argv) == 5 and sys.argv[1] == "--warm":
        L, C, H = map(float, sys.argv[2:])
        print("#%02x%02x%02x" % from_oklch(L, C, H), from_oklch(L, C, H))
        return
    root = pathlib.Path(__file__).resolve().parents[3]
    colors = theme_colors(root / "src" / "theme.zig")
    print("## Theme colors (OKLCH)\n")
    print("| name | hex | L | C | h | warm gray? |")
    print("|---|---|---|---|---|---|")
    for name, rgb in colors.items():
        L, C, H = oklch(rgb)
        gray = C < 0.03
        warm = "yes" if gray and C >= 0.003 and 40 <= H <= 100 else ("neutral" if gray and C < 0.003 else ("" if not gray else "COOL"))
        print(f"| {name} | #{'%02x%02x%02x' % rgb} | {L:.3f} | {C:.4f} | {H:.0f}° | {warm} |")
    print("\n## Contrast (WCAG 2.x)\n")
    print("| ink | ground | ratio | needs | result | where |")
    print("|---|---|---|---|---|---|")
    failures = 0
    for ink, ground, need, what in PAIRS:
        if ink not in colors or ground not in colors:
            continue
        r = contrast(colors[ink], colors[ground])
        ok = r >= need
        failures += not ok
        print(f"| {ink} | {ground} | {r:.2f}:1 | {need}:1 | {'pass' if ok else 'FAIL'} | {what} |")
    print(f"\n{failures} failing pair(s).")
    sys.exit(1 if failures else 0)

if __name__ == "__main__":
    main()
