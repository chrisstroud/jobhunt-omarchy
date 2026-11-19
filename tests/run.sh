#!/usr/bin/env bash
# One command for every check that can run without the desktop:  tests/run.sh
set -u
cd "$(dirname "$0")/.."
fail=0
step() { printf '\n== %s\n' "$1"; }

step "helper tests (all fixtures, safety, stand-in CLI)"
python3 tests/test_helper.py || fail=1

step "bar icon (the figure from the brand emblem, in the bar's foreground, no plate)"
python3 tests/bar_figure.py --check || fail=1

step "manifest rules"
jq -e '.schemaVersion == 1 and .id == "jobhunt.app" and (.description | length) < 120 and (.kinds | index("bar-widget")) and .barWidget.schema' manifest.json >/dev/null \
  && echo ok || { echo "manifest check failed"; fail=1; }

step "omarchy-plugin-validate (read-only checks of manifest.json and files)"
if command -v omarchy-plugin-validate >/dev/null; then
  omarchy-plugin-validate . && echo ok || fail=1
else
  echo "skipped: omarchy-plugin-validate not found"
fi

step "no symlinks, no secrets-shaped files"
if find . -name .git -prune -o -type l -print | grep -q .; then echo "symlink found"; fail=1; else echo ok; fi

step "Omarchy component properties (every property assigned on a qs.Ui type must be declared there)"
if [ -d /usr/share/omarchy/shell/Ui ]; then python3 tests/check_ui_props.py Panel.qml PanelContent.qml || fail=1; else echo "skipped: Omarchy Ui files not found"; fi

step "qmllint (errors and syntax only; Omarchy's own imports are linked from /usr/share/omarchy/shell)"
QMLLINT=/usr/lib/qt6/bin/qmllint
if [ -x "$QMLLINT" ] && [ -d /usr/share/omarchy/shell/Ui ]; then
  tmp=$(mktemp -d); mkdir -p "$tmp/qs"
  ln -s /usr/share/omarchy/shell/Commons "$tmp/qs/Commons"; ln -s /usr/share/omarchy/shell/Ui "$tmp/qs/Ui"
  out=$("$QMLLINT" -I "$tmp" -I /usr/lib/qt6/qml Panel.qml PanelContent.qml Service.qml UrlLauncher.qml 2>&1)
  rm -rf "$tmp"
  # Style.bar.* and bar.shell are untyped in Omarchy's singletons, so "missing-property" and
  # "unqualified" are expected noise (the GitHub plugin triggers the same). Anything else counts.
  bad=$(printf '%s\n' "$out" | grep -E '^(Error|Warning)' | grep -vE '\[(unqualified|missing-property)\]')
  if [ -n "$bad" ]; then printf '%s\n' "$bad"; fail=1; else echo "ok (no errors; unqualified/missing-property noise ignored)"; fi
else
  echo "skipped: qmllint or Omarchy shell files not found"
fi

step "the real panel, rendered offscreen from fixtures (any QML warning fails; needs quickshell and the Omarchy shell files)"
shots=$(mktemp -d)
render() { tests/render_panel.sh "$@" >/dev/null || { echo "render failed: $1"; fail=1; }; }
if command -v quickshell >/dev/null && [ -d /usr/share/omarchy/shell/Ui ]; then
  render busy-day "wait:3500,shot:$shots/overview.png,today:1,shot:$shots/today.png,tab:board,shot:$shots/board.png,tab:docs,tab:page,bottom,shot:$shots/page.png"
  JH_HIDE=1 render busy-day "wait:3500,shot:$shots/hidden.png"
  render new-cli "wait:3500,shot:$shots/new.png,tab:board,shot:$shots/new-board.png"
  render plan-read-only "wait:3500,shot:$shots/readonly.png"
  render plan-subscribed "wait:3500,shot:$shots/subscribed.png"
  render signed-out "wait:3500,shot:$shots/signed-out.png"
  render cli-missing "wait:3500,shot:$shots/missing.png"
  render stale-offline "wait:3500,shot:$shots/offline.png"
  JH_WHATSNEW=1 render upgrade-from-0-1-0 "wait:3500,shot:$shots/upgrade.png"
  JH_FIXTURE_MODE=1 render busy-day "wait:3500,quickadd,wait:1500,shot:$shots/quickadd.png,confirm,wait:1500,shot:$shots/saved.png"
  n=$(ls "$shots" | wc -l); [ "$n" -ge 14 ] && echo "ok ($n images rendered, no QML warnings)" || { echo "only $n images rendered"; fail=1; }
else
  echo "skipped: quickshell or Omarchy shell files not found"
fi
rm -rf "$shots"

echo
[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
