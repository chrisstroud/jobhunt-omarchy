# JobHunt for Omarchy

See what needs you today in your job search, and your recorded activity, right from the Omarchy bar.

JobHunt needs an account at jobhunt.app. This plugin reads your data through the JobHunt command line tool; it does not talk to JobHunt itself.

No partnership with or endorsement by Omarchy is implied.

Version 0.1.0 (first build, not yet listed anywhere).

## What it does

**Bar:** the JobHunt mark and one quiet number: how many things need you today (interviews and tasks due: tasks overdue or due today, interviews today or tomorrow). When nothing is due there is no number. The icon dims when it cannot show live data (not installed, signed out, offline). Right-click or middle-click refreshes.

**Panel (click the icon):** four tabs (Overview, Board, Docs, Page; keys 1 to 4), a permanent action row and an account footer.

- **Overview:** today in one line (click "+N today" for the rest, soonest first; click an item to open it on jobhunt.app; tasks tied to a job have a button that hands a request to your own terminal agent, "Tailor my resume for this job", whose exact text is shown first and which is sent only after you confirm). Then your **pipeline as columns** (the count for each active stage with the roles JobHunt already names under it; stage names are never built in), the **momentum** graph (a year of recorded activity in the Omarchy theme's accent colour, with month and weekday labels, a legend and the plain totals; JobHunt counts what was recorded and shows no scores or ranks), and one-line **Hunt Docs** and **Hunt Page** rows that open on jobhunt.app.
- **Board, Docs, Page:** these tabs arrive with the next update of the command line; until the installed command can serve them, each shows one quiet line, "Update the command line", with the command to copy, and a link to the same page on jobhunt.app. Nothing is half drawn.
- **Quick add:** saves a job from a web link on the clipboard. The link is shown first and nothing is saved until you press Save. In this version it saves jobs only; notes, tasks and contacts are shown as coming.
- **Footer:** your name, your plan as a plain fact (Trial with days left, Subscribed, or Read-only, in which saving is switched off), whether the plugin is connected and when it last read JobHunt, "Manage" (your plan on jobhunt.app) and "Sign out".
- **Hide company names:** the eye button beside the action row, for shared screens. Names are left out of the panel and the bar tooltip, everywhere. (Requests to your agent never contain names.)
- **Setup:** if the command is missing, the panel shows the install command to copy. If you are signed out, it offers one-click "Sign in to JobHunt" (with a Cancel while it waits for your approval in the browser), and the terminal command as a fallback.

The plugin never edits your agent's configuration. Requests to your agent go through `omarchy-agent --prompt "..."`, which starts your default agent, and Omarchy starts agents in their unattended modes. So no text that came from the network is ever put in a prompt: each request is fixed wording plus, at most, a job id that the plugin has checked is a UUID (for example "In JobHunt, tailor my resume for the job with id <uuid>. Show me the changes before saving."). No job title, company name or task text is included. The exact request is shown and needs your confirmation before anything launches.

## Install

```
omarchy plugin add https://github.com/chrisstroud/jobhunt-omarchy --enable
```

Then install the command and sign in:

```
npm i -g jobhunt@0.1.2
jobhunt auth login
```

The plugin works with this exact version of the command, never the moving `latest` tag. To check what you installed:

- **Version:** `0.1.2`.
- **Integrity:** `sha512-wkGWqX+liowxRpmKB1ZZE5+SwH9xpt8ORgTTehMOgTSY+UmpYOtLcc0zaGJoHx+VkusnI0ZSxkiOGevfeMuA6A==` (`npm view jobhunt@0.1.2 dist.integrity` must print this).
- **Source:** https://github.com/chrisstroud/jobhunt-cli, commit `37cde604af3c3487b07494fbe6d760d1c7664e57`. The package names this repository in its `repository` field.

You can also sign in from the panel: with the command installed, "Sign in to JobHunt" runs `jobhunt auth login` (no flags) and JobHunt opens in your browser for you to approve. The panel has "Sign out of JobHunt" too (it runs `jobhunt auth logout` after you confirm and clears the plugin's saved data). The plugin never sees or stores your sign-in; the command does. Optional, to let Claude Code use JobHunt too (this plugin does not run it for you):

```
claude mcp add --transport http jobhunt https://jobhunt.app/mcp
```

The plugin id is `jobhunt.app`.

## Remove

```
omarchy plugin remove jobhunt.app
```

This removes the plugin and its bar item. It does not sign you out or remove the command. To do that too:

```
jobhunt auth logout
npm rm -g jobhunt
```

Nothing in your JobHunt account is deleted by any of these.

## Upgrading from 0.1.0

Nothing to do: update the plugin and open the panel.

- **Your settings carry over.** Every setting 0.1.0 saved keeps its name and meaning. The plugin adds a `settingsVersion` key when it next saves one, and a missing key always means its default.
- **Your saved data carries over.** The 0.1.0 cache is read, filled in where 0.2.0 has more fields, and rewritten at the next read. A cache from a newer plugin, or one the plugin cannot read, is ignored and the data is simply read again.
- **The command line.** The plugin works with the command it already used (`jobhunt@0.1.2`): the Overview, the footer and Quick add (saving a job from a link) all run on it. The Board, Docs and Page tabs and role previews for stages the overview does not list need the updated command: those places show one quiet "Update the command line" line, with the command, never a broken view. The plugin reads the installed version with `jobhunt --version`; a version it cannot read counts as old.
- **What's new.** After the update the panel shows one small "New in 0.2.0" note with a "Got it" button, once.

## Settings

Open the widget's settings in Omarchy, or use the toggle in the panel.

| Setting | Default | Meaning |
| --- | --- | --- |
| Refresh in the background | on | When off, nothing runs in the background: data loads only when you open the panel or press refresh (the bar number may then be out of date). |
| Refresh interval | 900 s | How often the JobHunt command runs in the background (300 to 3600). It also runs when the panel opens. |
| Hide company names | off | For shared screens. |
| Open links | Browser tab | Or "Web app window" (needs a Chromium-based default browser). |
| JobHunt command path | empty | Only if `jobhunt` is not found on the shell's PATH. |

## Privacy

- The plugin itself makes no network requests. The `jobhunt` command contacts jobhunt.app each time it runs (every refresh interval while the bar is up, unless you turn background refresh off, and when you open the panel).
- Read: your overview (stage counts, tasks and interviews due in the next 7 days, with job and company names), and your activity counts for the last 365 days. Only fixed commands are run: `jobhunt --version` (to know what the installed command can do), `jobhunt status --json`, `jobhunt overview --json`, `jobhunt activity --json --days 365`, and, only after you confirm, `jobhunt jobs save <link> --json`. Your account name and plan state come from the same overview.
- The clipboard is read only when you press "Quick add". Its text is shown to you if it is a web link and is otherwise discarded; nothing is saved without a second click.
- Stored: a short-lived cache at `~/.cache/jobhunt-omarchy/snapshot.json` (permissions 0600), used to show the last good data when you are offline. It holds the items listed above (including your account name and plan state), is ignored after 24 hours, and is deleted when the plugin sees that you are signed out. Delete the file at any time. No passwords, tokens or keys are stored or handled; sign-in belongs to the `jobhunt` command.
- Text from JobHunt is shown as plain text only. The only pages the plugin opens are on https://jobhunt.app.

## Troubleshooting

- **Icon is dim, panel says the command is not installed:** run `npm i -g jobhunt@0.1.2`. If it is installed somewhere the shell does not see, set "JobHunt command path".
- **Signed out:** press "Sign in to JobHunt" in the panel (or run `jobhunt auth login`), then press "Check again".
- **Rate limited:** the panel says JobHunt asked for a short pause and keeps the last data; the plugin waits the time JobHunt gave before reading again. It never reads more than once a minute.
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

## Open questions

- The app paths used for row links (`/app/applications/id/<uuid>`, `/app/tasks`, `/app/interviews`) are unconfirmed: they were read from the product source, not tried against jobhunt.app.
- The overview does not report a job id on interview rounds, so interview rows have no agent button until it does.
- Strings are English only.

## Development

Python 3 standard library only. `tests/run.sh` runs the helper tests against every fixture in `fixtures/` (invented data), the Omarchy manifest validator, a check that every property used on an Omarchy component exists, qmllint, and a render of the real panel for several fixtures that fails on any QML warning. `tests/make_fixtures.py` regenerates the fixtures. To see the panel without your desktop (offscreen, under its own temporary HOME; it never touches your bar or your installed plugin): `tests/render_panel.sh busy-day "wait:3500,shot:/tmp/panel.png"`.
