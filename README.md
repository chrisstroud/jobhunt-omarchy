# JobHunt for Omarchy

See what needs you today in your job search, and your streak, right from the Omarchy bar.

JobHunt needs an account at jobhunt.app. This plugin reads your data through the JobHunt command line tool; it does not talk to JobHunt itself.

No partnership with or endorsement by Omarchy is implied.

Version 0.1.0 (first build, not yet listed anywhere).

## What it does

**Bar:** the JobHunt mark and one quiet number: how many things need you today (tasks overdue or due today, interviews today or tomorrow). When nothing is due there is no number. The icon dims when it cannot show live data (not installed, signed out, offline). Right-click or middle-click refreshes.

**Panel (click the icon):**

- **Today:** the due items, soonest first. Click one to open it on jobhunt.app. Interviews and tasks tied to a job have a button that hands a plain request to your own terminal agent ("Prep me for this interview", "Tailor my resume for this job"). A short "Later this week" list follows.
- **Streak:** your current streak in days and a year of activity, drawn in the Omarchy theme's accent colour.
- **Pipeline:** counts for each stage JobHunt reports. Stage names are never built in.
- **Actions:** "Save job from clipboard" (reads a web link from the clipboard, shows it, and saves only after you confirm), "What should I do next?" (a request to your agent), and "Open JobHunt".
- **Hide company names:** for shared screens. Names are left out of the panel, the bar tooltip and the requests sent to your agent.
- **Setup:** if the command is missing or you are signed out, the panel shows the commands to run, with copy buttons.

The plugin never edits your agent's configuration. Requests to your agent go through `omarchy-agent --prompt "..."`, which starts your default agent. Note that Omarchy starts agents in their unattended modes; the plugin therefore reduces job and company names to letters, digits and a few marks before putting them in a prompt.

## Install

```
omarchy plugin add <repository-url> --enable
```

(The repository URL is filled in when the plugin is published.) Then install the command and sign in:

```
npm i -g jobhunt
jobhunt auth login
```

Optional, to let Claude Code use JobHunt too (this plugin does not run it for you):

```
claude mcp add --transport http jobhunt https://jobhunt.app/mcp
```

The plugin id is `jobhunt.app`. It can change before the plugin is listed.

## Settings

Open the widget's settings in Omarchy, or use the toggle in the panel.

| Setting | Default | Meaning |
| --- | --- | --- |
| Refresh interval | 900 s | How often the JobHunt command runs in the background (300 to 3600). It also runs when the panel opens. |
| Hide company names | off | For shared screens. |
| Open links | Browser tab | Or "Web app window" (needs a Chromium-based default browser). |
| JobHunt command path | empty | Only if `jobhunt` is not found on the shell's PATH. |

## Privacy

- The plugin itself makes no network requests. The `jobhunt` command contacts jobhunt.app each time it runs (every refresh interval while the bar is up, and when you open the panel).
- Read: your overview (stage counts, tasks and interviews due in the next 7 days, with job and company names), and your activity counts for the last 365 days. Only fixed commands are run: `jobhunt status --json`, `jobhunt overview --json`, `jobhunt activity --json --days 365`, and, only after you confirm, `jobhunt jobs save <link> --json`.
- The clipboard is read only when you press "Save job from clipboard". Its text is shown to you if it is a web link and is otherwise discarded; nothing is saved without a second click.
- Stored: a short-lived cache at `~/.cache/jobhunt-omarchy/snapshot.json` (permissions 0600), used to show the last good data when you are offline. It holds the items listed above, is ignored after 24 hours, and is deleted when the plugin sees that you are signed out. Delete the file at any time. No passwords, tokens or keys are stored or handled; sign-in belongs to the `jobhunt` command.
- Text from JobHunt is shown as plain text only. The only pages the plugin opens are on https://jobhunt.app.

## Troubleshooting

- **Icon is dim, panel says the command is not installed:** run `npm i -g jobhunt`. If it is installed somewhere the shell does not see, set "JobHunt command path".
- **Signed out:** run `jobhunt auth login`, then press "Check again".
- **Offline:** the panel shows the last data it read and how old it is.
- **Something unexpected:** run `jobhunt overview --json` in a terminal. If that works, update the plugin; the helper may need to learn a changed output shape.
- **Try the helper without the real command:** `JOBHUNT_OMARCHY_FIXTURE=fixtures/busy-day python3 helper/jobhunt_omarchy.py snapshot`
- **Run the checks:** `tests/run.sh`

## Brand files

`assets/jobhunt-emblem-on-dark.svg` and `assets/jobhunt-emblem-on-light.svg` are JobHunt's own emblem, copied unmodified from the JobHunt web app at `web/public/brand/kit/` (product repository commit 0f0029db422bec96ecbe32181dc16b0d9cef8f5d).

| File | sha256 |
| --- | --- |
| `assets/jobhunt-emblem-on-dark.svg` | e452ceddb7dffdde9e5f1f473ac8fb782e343d93a45a1f5da8a04335bd36c007 |
| `assets/jobhunt-emblem-on-light.svg` | 25107b4814f3b4aa06d5c0ae94e670aa30687d49b8f212fc5f63c46c23d29fd7 |

The code is MIT licensed (see LICENSE). The emblem is JobHunt's mark and is included as supplied.

## Development

Python 3 standard library only. `tests/run.sh` runs the helper tests against every fixture in `fixtures/` (invented data), the Omarchy manifest validator and qmllint. `tests/make_fixtures.py` regenerates the fixtures.
