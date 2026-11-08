"""Builds the app icon sets from icon-template.svg, one per theme palette.

    python3 scripts/app-icon/make.py

Writes ConnectSphere/Assets.xcassets/AppIcon.appiconset (amber, the primary icon)
and AppIcon-<id>.appiconset for every other palette, each with a light (also used in dark mode) and a
tinted 1024×1024 PNG. The hex values are the palettes in
ConnectSphere/Core/Theme/ThemeManager.swift; keep the two in step.
Rendering needs only macOS (render.swift uses AppKit's SVG support).
"""
import json, pathlib, re, subprocess, tempfile

here = pathlib.Path(__file__).parent
assets = here.parent.parent / "ConnectSphere" / "Assets.xcassets"
tpl = (here / "icon-template.svg").read_text()

# id: (primary, secondary, accent), as in ThemeManager.swift. "amber" is the primary icon.
palettes = {
    "amber":       ("#F59E0B", "#D97706", "#FDE68A"),
    "sunset":      ("#FF6B6B", "#FF8E53", "#FFCA45"),
    "tropical":    ("#00C9A7", "#0096C7", "#90E0EF"),
    "candy":       ("#F72585", "#7209B7", "#C77DFF"),
    "blue":        ("#3B82F6", "#2563EB", "#93C5FD"),
    "rose":        ("#F43F5E", "#E11D48", "#FDA4AF"),
    "navy":        ("#1D4ED8", "#1E40AF", "#93C5FD"),
    "slate":       ("#475569", "#334155", "#94A3B8"),
    "forest":      ("#059669", "#047857", "#6EE7B7"),
    "charcoal":    ("#3A3A3C", "#1C1C1E", "#AEAEB2"),
    "deep-purple": ("#6D28D9", "#5B21B6", "#A78BFA"),
}


def darken(hex_color, factor=0.68):
    r, g, b = (int(hex_color[i:i + 2], 16) for i in (1, 3, 5))
    return "#%02X%02X%02X" % tuple(int(c * factor) for c in (r, g, b))


def variants(primary, secondary, accent):
    # The sea is two opaque shades of the palette's secondary colour: AppKit's SVG
    # renderer ignores fill-opacity, so a translucent overlay comes out solid black.
    # AppIconPicker.swift draws its tile wave with the same 0.70 factor.
    common = dict(WHALE="#FFFFFF", EYE="#1C1C1C", BLUSH="#FCA5A5", BUBBLE="#FFFFFF")
    return {
        # No separate dark variant: the icon keeps the same colours in dark mode.
        "light": dict(common, BG1=primary, BG2=secondary, BELLY=accent, DOTS=primary,
                      WAVE_BACK=darken(secondary, 0.84), WAVE_FRONT=darken(secondary, 0.70)),
        # Greyscale on transparent: iOS lays its own tint over it.
        "tinted": dict(BG1="#000000", BG2="#000000", WHALE="#FFFFFF", BELLY="#B4B4B4",
                       EYE="#2A2A2A", BLUSH="#9A9A9A", BUBBLE="#FFFFFF", DOTS="#7A7A7A",
                       WAVE_BACK="#6E6E6E", WAVE_FRONT="#4A4A4A"),
    }


def contents():
    def entry(appearance=None):
        e = {"idiom": "universal", "platform": "ios", "size": "1024x1024"}
        if appearance:
            e["appearances"] = [{"appearance": "luminosity", "value": appearance}]
            e["filename"] = f"AppIcon-{appearance}.png"
        else:
            e["filename"] = "AppIcon-light.png"
        return e
    return {"images": [entry(), entry("tinted")],
            "info": {"author": "xcode", "version": 1}}


with tempfile.TemporaryDirectory() as tmp:
    tmp = pathlib.Path(tmp)
    for pid, colors in palettes.items():
        out = assets / ("AppIcon.appiconset" if pid == "amber" else f"AppIcon-{pid}.appiconset")
        out.mkdir(exist_ok=True)
        svgs = []
        for name, fills in variants(*colors).items():
            svg = tpl
            if name == "tinted":
                svg = re.sub(r"<!--BG-START-->.*?<!--BG-END-->", "", svg, flags=re.S)
            for key, value in fills.items():
                svg = svg.replace(key, value)
            path = tmp / f"{pid}-{name}.svg"
            path.write_text(svg)
            svgs.append(path)
        subprocess.run(["swift", str(here / "render.swift"), *map(str, svgs)], check=True,
                       capture_output=True)
        for name in ("light", "tinted"):
            (tmp / f"{pid}-{name}.png").replace(out / f"AppIcon-{name}.png")
        (out / "AppIcon-dark.png").unlink(missing_ok=True)
        (out / "Contents.json").write_text(json.dumps(contents(), indent=2) + "\n")
        # A small copy of the light icon for the Settings › App icon tiles (alternate
        # icon sets can't be loaded as images at runtime), so the preview is the icon.
        preview = assets / f"AppIconPreview-{pid}.imageset"
        preview.mkdir(exist_ok=True)
        subprocess.run(["sips", "-Z", "240", str(out / "AppIcon-light.png"), "--out",
                        str(preview / "preview.png")], check=True, capture_output=True)
        (preview / "Contents.json").write_text(json.dumps({
            "images": [{"idiom": "universal", "filename": "preview.png"}],
            "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
        print("wrote", out.name, "+", preview.name)
