#!/usr/bin/env python3
"""Generates the Icon Composer documents (.icon) for Super Gloss's app icon candidates.

The glyph comes from Crimson Text (SIL Open Font License) and is converted to
outlines, so the documents don't depend on any installed font.

usage: make-icons.py <out-dir> [font.ttf]
"""
import json
import os
import shutil
import sys

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

OUT = sys.argv[1]
FONT = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser("~/Library/Fonts/CrimsonText-SemiBold.ttf")

INK = "#1d1d1f"
VERMILLION = "#c4471b"
PAPER = "#fbf8f2"


def color(hex_, a=1.0):
    h = hex_.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},{a:.5f}"


def glyph(ch, height, cx, cy, font=FONT):
    """SVG path data for `ch`, scaled so its ink box is `height` tall, centred on (cx, cy)."""
    f = TTFont(font)
    gs = f.getGlyphSet()
    name = f.getBestCmap()[ord(ch)]
    bp = BoundsPen(gs)
    gs[name].draw(bp)
    x0, y0, x1, y1 = bp.bounds
    s = height / (y1 - y0)
    w = (x1 - x0) * s
    # font units are y-up; SVG is y-down
    tx = cx - w / 2 - x0 * s
    ty = cy + height / 2 + y0 * s
    pen = SVGPathPen(gs)
    gs[name].draw(TransformPen(pen, (s, 0, 0, -s, tx, ty)))
    return pen.getCommands()


def svg(body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">{body}</svg>\n'


def write_icon(name, fill, groups, assets):
    d = os.path.join(OUT, f"{name}.icon")
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(os.path.join(d, "Assets"))
    for fname, body in assets.items():
        with open(os.path.join(d, "Assets", fname), "w") as fh:
            fh.write(svg(body))
    doc = {"fill": fill, "groups": groups, "supported-platforms": {"squares": ["macOS"]}}
    with open(os.path.join(d, "icon.json"), "w") as fh:
        json.dump(doc, fh, indent=2)
    return d


def layer(image, name, glass=True, opacity=None, dark=None):
    """`dark`: solid colour the layer takes in the dark appearance."""
    l = {"image-name": image, "name": name, "glass": glass}
    if opacity is not None:
        l["opacity"] = opacity
    if dark is not None:
        l["fill-specializations"] = [{"appearance": "dark", "value": {"solid": color(dark)}}]
    return l


def group(layers, shadow=0.5, translucency=None, specular=True):
    g = {"layers": layers, "shadow": {"kind": "neutral", "opacity": shadow}, "specular": specular}
    if translucency is not None:
        g["translucency"] = {"enabled": True, "value": translucency}
    return g


# 1 — Gloss: the double-story serif "g" with the vermillion margin rule from the app.
write_icon(
    "Gloss",
    {"automatic-gradient": color(PAPER)},
    [
        group([layer("g.svg", "g", dark="#f2eee6")], shadow=0.45),
        group([layer("rule.svg", "rule", dark="#ff7a45")], shadow=0.35),
    ],
    {
        "g.svg": f'<path d="{glyph("g", 600, 560, 520)}" fill="{INK}"/>',
        "rule.svg": f'<rect x="262" y="262" width="40" height="500" rx="20" fill="{VERMILLION}"/>',
    },
)

# 2 — Margin: the app's own page — a sheet of text with the gloss mark in its margin.
lines = "".join(
    f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{h/2}" fill="{INK}" fill-opacity="{o}"/>'
    for x, y, w, h, o in [
        (392, 330, 250, 46, 0.92),
        (392, 432, 340, 24, 0.30),
        (392, 492, 300, 24, 0.30),
        (392, 552, 330, 24, 0.30),
        (392, 652, 260, 24, 0.30),
        (392, 712, 310, 24, 0.30),
    ]
)
write_icon(
    "Margin",
    {"automatic-gradient": color(VERMILLION)},
    [
        group([layer("text.svg", "text", glass=False, dark="#f2eee6")], shadow=0.0, specular=False),
        group([layer("gloss.svg", "gloss", dark="#ff7a45")], shadow=0.3),
        group([layer("page.svg", "page", dark="#3a3a3d")], shadow=0.6, translucency=0.15),
    ],
    {
        "page.svg": f'<rect x="232" y="212" width="560" height="600" rx="64" fill="{PAPER}"/>',
        "gloss.svg": f'<rect x="300" y="330" width="40" height="160" rx="20" fill="{VERMILLION}"/>',
        "text.svg": lines,
    },
)

# 3 — Stack: every dictionary in one place — glass leaves fanned behind a vermillion
# front leaf that carries the "g".
write_icon(
    "Stack",
    {"automatic-gradient": color("#23262d")},
    [
        group([layer("g.svg", "g")], shadow=0.35),
        group([layer("front.svg", "front")], shadow=0.55, translucency=0.1),
        group([layer("middle.svg", "middle")], shadow=0.4, translucency=0.35),
        group([layer("back.svg", "back")], shadow=0.3, translucency=0.5),
    ],
    {
        "back.svg": f'<rect x="300" y="170" width="424" height="520" rx="70" fill="#e8b04a" transform="rotate(-14 512 512)"/>',
        "middle.svg": f'<rect x="300" y="200" width="424" height="540" rx="70" fill="{PAPER}" transform="rotate(-6 512 512)"/>',
        "front.svg": f'<rect x="300" y="240" width="424" height="560" rx="70" fill="{VERMILLION}" transform="rotate(4 512 512)"/>',
        "g.svg": f'<path d="{glyph("g", 380, 520, 540)}" fill="{PAPER}" transform="rotate(4 512 512)"/>',
    },
)

print("\n".join(sorted(os.path.join(OUT, n) for n in os.listdir(OUT) if n.endswith(".icon"))))
