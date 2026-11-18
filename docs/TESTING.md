# First install and what to look for

Nothing in this plugin has been seen on screen yet: it was written and checked without opening the desktop. These steps are for the first install.

## 0. Before installing (no desktop needed)

```
cd ~/Developer/jobhunt-omarchy && tests/run.sh
```

Expect `ALL CHECKS PASSED`.

## 1. Install

```
omarchy plugin add ~/Developer/jobhunt-omarchy --enable
```

(Or the form `omarchy plugin add` accepts for a local folder.) The widget lands in the right section of the bar by default. If the bar shows nothing, run `omarchy-shell shell rescanPlugins` and check the shell's log for a QML error naming a JobHunt file.

## 2. What you should see in each state

| State | Bar | Panel |
| --- | --- | --- |
| CLI not installed | Dim JobHunt mark, no number. Tooltip: "JobHunt: command not installed". | "SET UP" with the install and sign-in commands, the optional Claude Code command, copy buttons, "Check again". |
| Not signed in | Dim mark, no number. Tooltip: "JobHunt: signed out". | "SET UP" with `jobhunt auth login`. |
| Signed in, nothing due | Bright mark, no number. | "Nothing due today.", streak, pipeline, actions. |
| Items due | Mark plus one number, in the bar's normal text colour (not the alarm colour). | Today rows soonest first, then "Later this week". Clicking a row opens jobhunt.app in the browser. |
| Offline after a good read | Dimmed mark and number. | A tinted note: could not reach JobHunt, with the age of the data shown; the data is still listed. |
| Unexpected answer | "!" beside the mark when there is no older data. | A tinted note: JobHunt returned something unexpected. |

## 3. Try the states without the real CLI

The helper reads fixtures when `JOBHUNT_OMARCHY_FIXTURE` is set, but the shell does not inherit variables set in a terminal, so for a look at the panel in each state use the real CLI where possible (sign out for the signed-out state, temporarily rename the `jobhunt` binary for the missing state, network off for offline). The fixtures `busy-day`, `nothing-due`, `signed-out`, `cli-missing`, `stale-offline` and `year-of-activity` are covered by `tests/run.sh`; they can also be read directly:

```
JOBHUNT_OMARCHY_FIXTURE=fixtures/busy-day python3 helper/jobhunt_omarchy.py snapshot | jq .
```

## 4. Check by eye

1. The mark is sharp at bar size, and the light and dark variants suit your theme.
2. With a number showing, the icon and number are centred together and the widget does not push neighbours oddly. Also with no number.
3. The panel opens under the icon, fits (scrolls if tall), closes with Escape and outside click, and `r` refreshes.
4. The activity graph: 53 columns fit the width, cell colours follow the theme accent, and hovering a cell shows a tooltip.
5. "Hide company names": toggle it in the panel; names disappear from rows (and, after the next read, from agent requests); the setting survives a shell reload.
6. "Save job from clipboard": copy a job link, press the button, check the link is shown and nothing is saved until "Save this job". With non-link text on the clipboard you should see the "does not hold a web link" message. (Saving needs the real CLI's `jobhunt jobs save`.)
7. "What should I do next?" and the per-row buttons open your default agent in a terminal with the request. Check the wording reads well.
8. Copy buttons put the exact command on the clipboard.
9. "Open links" in settings: Browser tab versus Web app window.
10. No emoji, score, rank or pressure wording anywhere; the streak reads "Current streak: N days".

## 5. Remove

```
omarchy plugin remove jobhunt.app
rm -rf ~/.cache/jobhunt-omarchy
```
