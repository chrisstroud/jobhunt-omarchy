#!/usr/bin/env python3
"""The bar icon's figure, built from the brand emblem's own shapes (assets/jobhunt-emblem-on-dark.svg): head with the
face cut out, body, arm and laptop, without the emblem's dark field, grid or lime accents, and with the laptop's thin
parts thickened so they survive 16 px. Prints the SVG path Panel.qml's barFigure must hold; with --check, exits 1 if
Panel.qml differs, or if the bar icon is not that figure filled with the bar's foreground."""
import os, re, sys

X0, Y0, W = 164, 88, 532          # the figure's box in the emblem's coordinates
S = 24 / W                         # onto a 24-unit square, centred vertically
SHAPES = {
    "head": [(335, 141), (400, 88), (486, 141), (459, 183), (454, 217), (429, 252), (407, 251), (382, 214), (347, 224), (334, 212)],
    "face": [(399, 179), (459, 183), (454, 217), (429, 252), (407, 251), (382, 214)],  # a hole (odd-even fill)
    "body": [(164, 516), (218, 281), (337, 223), (427, 289), (466, 403), (435, 413), (375, 516)],
    "arm": [(336, 398), (429, 394), (478, 404), (509, 408), (540, 424), (550, 437), (507, 436), (478, 434), (426, 429), (337, 420)],
    "screen": [(616, 440), (664, 292), (696, 292), (648, 440)],
    "base": [(372, 430), (652, 430), (642, 458), (366, 458)],
}


def point(x, y):
    return round((x - X0) * S, 2), round((y - Y0) * S + (24 - 428 * S) / 2, 2)


def figure():
    return " ".join("M" + " L".join("%g %g" % point(*p) for p in shape) + " Z" for shape in SHAPES.values())


def main():
    if "--check" not in sys.argv:
        print(figure())
        return 0
    panel = open(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Panel.qml"), encoding="utf-8").read()
    found = re.search(r'readonly property string barFigure: "([^"]*)"', panel)
    bar = panel[panel.index("BarIconButton {"):panel.index("KeyboardPanel {")]
    problems = []
    if not found or found.group(1) != figure():
        problems.append("Panel.qml barFigure is not tests/bar_figure.py's figure")
    if "PathSvg { path: root.barFigure }" not in bar or "fillColor: root.foreground" not in bar:
        problems.append("the bar icon is not the figure filled with the bar's foreground")
    if re.search(r"\bImage\s*\{|Rectangle\s*\{|border\.", bar):
        problems.append("the bar icon has an image, plate or border")
    print("\n".join(problems) or "ok")
    return 1 if problems else 0


sys.exit(main())
