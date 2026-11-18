#!/usr/bin/env python3
"""Checks that every property this plugin assigns on an Omarchy qs.Ui component is declared by
that component's file or its base types under /usr/share/omarchy/shell/Ui. qmllint does not
catch this (a bad name inside a Component{} was missed once: iconSpinning on PanelActionButton)."""
import os, re, sys

UI = os.environ.get("OMARCHY_UI_DIR", "/usr/share/omarchy/shell/Ui")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = sys.argv[1:] or ["Panel.qml"]
# Plain QtQuick members the Ui types inherit from Item / Rectangle / Text / Column.
BUILTIN = set("""id width height x y z visible opacity enabled focus clip scale rotation transform transformOrigin parent
objectName anchors implicitWidth implicitHeight spacing color radius border antialiasing smooth layer activeFocus
leftPadding rightPadding topPadding bottomPadding padding children data resources states transitions state baselineOffset
text textFormat font wrapMode elide horizontalAlignment verticalAlignment maximumLineCount
containmentMask focusPolicy activeFocusOnTab Keys Layout LayoutMirroring QsWindow""".split())


def declared(name, seen=None):
    seen = seen or set()
    path = os.path.join(UI, name + ".qml")
    if name in seen or not os.path.isfile(path):
        return None  # a QtQuick type, covered by BUILTIN
    seen.add(name)
    text = open(path, encoding="utf-8").read()
    names = set(re.findall(r"(?:property|alias)\s+(?:[\w.<>]+\s+)?(\w+)\s*[:\n]", text))
    names |= set(re.findall(r"property\s+(?:var|real|int|string|bool|color|url|point|rect|list<\w+>|\w+)\s+(\w+)", text))
    names |= set(re.findall(r"signal\s+(\w+)", text)) | set(re.findall(r"function\s+(\w+)", text))
    names |= set(re.findall(r"^\s*(?:id|property alias)\s+(\w+)", text, re.M))
    base = re.search(r"^([A-Z]\w*)\s*\{", text, re.M)
    if base:
        parent = declared(base.group(1), seen)
        if parent:
            names |= parent
    return names


def main():
    ui_types = {f[:-4] for f in os.listdir(UI) if f.endswith(".qml")}
    bad = 0
    for fname in FILES:
        lines = open(os.path.join(ROOT, fname) if not os.path.isabs(fname) else fname, encoding="utf-8").read().split("\n")
        for i, line in enumerate(lines):
            m = re.match(r"^\s*(?:[\w.]+:\s*)?([A-Z]\w*)\s*\{\s*$", line) or re.match(r"^\s*(?:component\s+\w+:\s*)?([A-Z]\w*)\s*\{", line)
            if not m or m.group(1) not in ui_types:
                continue
            kind, allowed, depth, j = m.group(1), declared(m.group(1)) or set(), 0, i
            while j < len(lines):
                depth += lines[j].count("{") - lines[j].count("}")
                if j > i and depth == 1:
                    key = re.match(r"^\s*([A-Za-z_][\w.]*)\s*:", lines[j])
                    if key:
                        head = key.group(1).split(".")[0]
                        if head.startswith("on") and head[2:3].isupper():
                            sig = head[2].lower() + head[3:]
                            if sig not in allowed and not sig.endswith("Changed") and sig not in ("clicked", "pressed", "released", "entered", "exited"):
                                print("%s:%d: %s has no signal '%s'" % (fname, j + 1, kind, sig))
                                bad += 1
                        elif head not in allowed and head not in BUILTIN:
                            print("%s:%d: %s has no property '%s'" % (fname, j + 1, kind, key.group(1)))
                            bad += 1
                if depth <= 0 and j > i or (j == i and depth == 0):
                    break
                j += 1
    print("ok" if not bad else "%d unknown propert%s" % (bad, "y" if bad == 1 else "ies"))
    return 1 if bad else 0


sys.exit(main())
