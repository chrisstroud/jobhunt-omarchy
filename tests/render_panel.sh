#!/usr/bin/env bash
# Renders the real panel (PanelContent.qml, Service.qml and the helper) offscreen from one fixture and saves PNGs.
# No desktop, no bar, no network, and nothing from your session is touched: it runs under its own HOME in a temp dir.
#   tests/render_panel.sh FIXTURE "wait:3500,shot:/path/a.png,tab:board,shot:/path/b.png"
# Steps: wait:MS  tab:overview|board|docs|page  today:0|1  bottom (scroll to the end)  quickadd  confirm  hide:0|1  shot:PATH
# Environment: JH_THEME_DIR (a folder with colors.toml and shell.toml to draw in; default: the shell's own defaults),
#   JH_HIDE=1 (company names hidden), JH_WHATSNEW=1 (the one-time note), JH_FIXTURE_MODE=1 (read the fixture's files
#   instead of running its stand-in command; needed for Quick add, which reads clipboard.txt), JH_SCALE=2 (sharper images).
# Exit status 1 when QML printed a warning or error: a binding that failed shows up here, not on someone's screen.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
fixture=${1:?fixture name}; steps=${2:-wait:3500}
shell=/usr/share/omarchy/shell
[ -d "$shell/Ui" ] && command -v quickshell >/dev/null || { echo "skipped: quickshell or the Omarchy shell files are not here"; exit 0; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/harness" "$tmp/home/.config/omarchy" "$tmp/home/.local/state/omarchy/current" "$tmp/home/.cache" "$tmp/run"
chmod 700 "$tmp/run"
for d in Commons Ui services; do ln -s "$shell/$d" "$tmp/harness/$d"; done
ln -s "$here" "$tmp/harness/plugin"
cp "$here/tests/panel_harness/shell.qml" "$tmp/harness/shell.qml"
[ -n "${JH_THEME_DIR:-}" ] && cp -r "$JH_THEME_DIR" "$tmp/home/.local/state/omarchy/current/theme"
[ -f "${JH_SHELL_TOML:-/nonexistent}" ] && cp "$JH_SHELL_TOML" "$tmp/home/.config/omarchy/shell.toml"
fixenv=()
[ "${JH_FIXTURE_MODE:-0}" = 1 ] && fixenv=(JOBHUNT_OMARCHY_FIXTURE="$here/fixtures/$fixture")
out=$(cd "$tmp/harness" && timeout 90 env -i PATH="/usr/local/bin:/usr/bin:/bin" HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" \
  XDG_CACHE_HOME="$tmp/home/.cache" XDG_STATE_HOME="$tmp/home/.local/state" XDG_DATA_HOME="$tmp/home/.local/share" XDG_RUNTIME_DIR="$tmp/run" \
  LANG=en_US.UTF-8 OMARCHY_PATH=/usr/share/omarchy QT_QPA_PLATFORM=offscreen JH_SCALE="${JH_SCALE:-1}" "${fixenv[@]}" \
  JH_CLI="$here/fixtures/$fixture/jobhunt" JH_STEPS="$steps" JH_HIDE="${JH_HIDE:-0}" JH_WHATSNEW="${JH_WHATSNEW:-0}" \
  quickshell -n -p "$tmp/harness" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
printf '%s\n' "$out" | grep -E "SHOT|OPEN|COPY|PERSIST|AGENT"
bad=$(printf '%s\n' "$out" | grep -E "WARN scene|ERROR|TypeError|ReferenceError|Unable to assign|is not a type|Cannot read|Cannot assign|Cannot call" | head -10)
[ -n "$bad" ] && { echo "QML problems:"; printf '%s\n' "$bad"; exit 1; }
exit 0
