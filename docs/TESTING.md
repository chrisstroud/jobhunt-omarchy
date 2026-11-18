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
| CLI not installed | Dim JobHunt mark, no number. Tooltip: "JobHunt: command not installed". | "SET UP": one sentence, the install command and the sign-in command as copyable text, then quiet "More ways to connect" (the Claude Code command) and "Check again". |
| Not signed in | Dim mark, no number. Tooltip: "JobHunt: signed out". | "SIGN IN": one sentence and the "Sign in to JobHunt" button (while waiting: "Waiting for you to approve in your browser…" and a quiet Cancel). "More ways to connect" opens `jobhunt auth login` and the Claude Code command, each with Copy. |
| Signed in, nothing due | Bright mark, no number. | "Nothing due today.", momentum, pipeline, actions. |
| Items due | Mark plus one number, in the bar's normal text colour (not the alarm colour). | Today rows soonest first, then "Later this week". Clicking a row opens jobhunt.app in the browser. |
| Offline after a good read | Dimmed mark and number. | A tinted note: could not reach JobHunt, with the age of the data shown; the data is still listed. |
| Unexpected answer | "!" beside the mark when there is no older data. | A tinted note: JobHunt returned something unexpected. |

## 3. See every state with the shipped fixtures and no real CLI

Each scenario folder in `fixtures/` holds a stand-in `jobhunt` program that answers from the JSON files beside it. It makes no network call and saves nothing. The plugin's setting "JobHunt command path" points at it, so no environment variables and no real CLI are needed. In Omarchy's widget settings for JobHunt, set the path to one of these (use your real home folder path), then press refresh in the panel:

| State | Set "JobHunt command path" to |
| --- | --- |
| Items due, momentum, pipeline | `/path/to/jobhunt-omarchy/fixtures/busy-day/jobhunt` (the full path to your copy of this repository) |
| Nothing due (no number) | `.../fixtures/nothing-due/jobhunt` |
| A full year of activity | `.../fixtures/year-of-activity/jobhunt` |
| Signed out, then one-click sign-in | `.../fixtures/signed-out/jobhunt`: press "Sign in to JobHunt"; the stand-in signs in at once (no browser) and the panel shows busy-day data. "Sign out of JobHunt" in the panel flips it back. Reset with `rm fixtures/*/.signed-in fixtures/*/.signed-out` |
| Sign-in that fails, known reason | `.../fixtures/sign-in-fails/jobhunt`: "Access was not approved in the browser. You can try again." and the button again |
| Sign-in that fails, unknown reason | `.../fixtures/sign-in-fails-other/jobhunt`: "Sign-in did not finish. You can try again." |
| The CLI's own example files, verbatim | `.../fixtures/contract/jobhunt` |
| Signed out by a revoked connection (exit 3) | `.../fixtures/revoked/jobhunt` |
| Rate limited, older data kept | busy-day once, then `.../fixtures/rate-limited/jobhunt` (a pause note; no new read for 2 minutes) |
| Offline with older data | first use busy-day and let it load once, then switch to `.../fixtures/stale-offline/jobhunt` (it fails like a lost connection; the cache from the first read is shown with its age) |
| CLI not installed | clear the setting while no real `jobhunt` is installed (the usual state at first install); if one is installed, temporarily rename it |

Reads are limited to one a minute (the CLI contract's request), so pressing refresh again straight away does nothing; changing the path always reads. When you are done, clear the setting and delete `~/.cache/jobhunt-omarchy` (the fixture reads are cached like real ones). The fixture data is invented and fixed to 17 November 2026, so "today" in the panel is that day, whatever the real date. Tasks with a job id (busy-day) have a "Tailor my resume" button; interviews have none, because the contract gives them no id.

The same data can be read in a terminal: `JOBHUNT_OMARCHY_FIXTURE=fixtures/busy-day python3 helper/jobhunt_omarchy.py snapshot | jq .` and `tests/run.sh` covers every scenario.

## 4. Check by eye

1. The bar shows the JobHunt figure alone, with no box, in the same colour as the neighbouring bar icons, and it follows a theme change. It is sharp at bar size; `docs/bar-icon-preview.png` shows it at 16 and 20 px on a dark and a light bar, with a count.
2. With a number showing, the icon and number are centred together and the widget does not push neighbours oddly. Also with no number.
3. The panel opens under the icon, fits (scrolls if tall), closes with Escape and outside click, and `r` refreshes.
4. The activity graph: 53 columns fit the width, cell colours follow the theme accent, and hovering a cell shows a tooltip.
5. "Hide company names": toggle it in the panel; names disappear from rows ; the setting survives a shell reload.
6. "Save job from clipboard": copy a job link, press the button, check the link is shown and nothing is saved until "Save this job". With non-link text on the clipboard you should see the "does not hold a web link" message. (Saving needs the real CLI's `jobhunt jobs save`.)
7. "What should I do next?" and the per-row buttons first show the exact request at the top of the panel with "Send to my agent" and "Cancel"; only after Send does your default agent open in a terminal. Check that the request contains no job title or company name, only a job id.
8. Copy buttons put the exact command on the clipboard.
9. "Open links" in settings: Browser tab versus Web app window.
10. Turn off "Refresh in the background" in settings: the bar number should then change only after you open the panel or press refresh.
11. No emoji, score, rank or pressure wording anywhere; the Momentum section only states counts: "N recorded actions on M days, in the last N days.".

## 5. Remove

```
omarchy plugin remove jobhunt.app
rm -rf ~/.cache/jobhunt-omarchy
```
