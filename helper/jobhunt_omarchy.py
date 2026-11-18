#!/usr/bin/env python3
"""Helper for the JobHunt Omarchy plugin (Python 3 standard library only).

The QML never talks to JobHunt. It runs this script, which runs the JobHunt
command line tool (`jobhunt`) with fixed arguments, checks and trims what comes
back, and prints one small JSON document. If the CLI's output shape changes,
only the normalise_* functions below change.

    jobhunt_omarchy.py snapshot [--hide-company] [--cli PATH]
    jobhunt_omarchy.py clipboard
    jobhunt_omarchy.py save URL [--cli PATH]

Rules this file keeps:
  * No shell. Every command is an argv list.
  * Remote text is cut to a length, stripped of control characters and only
    ever printed as JSON. Remote error text is never repeated.
  * Output from the CLI is capped at 1 MiB and every call has a timeout.
  * Nothing is written to stderr. Nothing personal is logged.
  * The only file written is a short-lived cache (see cache_path()).
  * Fixture mode (JOBHUNT_OMARCHY_FIXTURE=<dir>) reads the CLI outputs from
    files, writes nothing, and never starts a program.
"""
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import unicodedata
from urllib.parse import urlsplit
from zoneinfo import ZoneInfo

SCHEMA = 1
MAX_OUTPUT = 1024 * 1024
CLI_TIMEOUT = 20
CLIP_TIMEOUT = 3
CACHE_MAX_AGE = 24 * 3600
MAX_DUE = 40
MAX_STAGES = 30
MAX_URL = 2000
DAYS = 365
JOBHUNT_ORIGIN = "https://jobhunt.app"

UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
INSTANT_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$")
CLOSED_INTERVIEW = {"cancelled", "canceled", "completed", "done", "passed", "no_show"}
AUTH_CODES = {"authentication_required", "account_changed", "not_signed_in", "signed_out"}
EXTRA_CLI_DIRS = (
    "~/.local/bin",
    "~/.npm-global/bin",
    "~/.local/share/mise/shims",
    "~/.local/share/pnpm",
    "/usr/local/bin",
)


class ShapeError(Exception):
    """The CLI answered, but not in the shape the contract promises."""


# --------------------------------------------------------------------------
# small validators and cleaners


def clean(value, limit):
    """Plain single-line text, no control characters, at most `limit` characters."""
    if not isinstance(value, str):
        return ""
    out = "".join(" " if unicodedata.category(ch)[0] == "C" else ch for ch in value)
    out = " ".join(out.split())
    if len(out) > limit:
        out = out[: limit - 1].rstrip() + "…"
    return out


def prompt_name(value):
    """A name made safe to put inside a prompt for an agent: letters, digits and a few marks only."""
    if not isinstance(value, str):
        return ""
    out = "".join(ch if (ch.isalnum() or ch in " .,&'()/+#-") else " " for ch in value)
    out = " ".join(out.split())
    return out[:60].rstrip()


def to_day(value):
    if not isinstance(value, str) or not DAY_RE.match(value):
        return None
    try:
        return dt.date.fromisoformat(value)
    except ValueError:
        return None


def to_instant(value):
    if not isinstance(value, str) or not INSTANT_RE.match(value):
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def to_count(value, ceiling=1_000_000):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0
    return max(0, min(int(value), ceiling))


def zone_of(name):
    try:
        return ZoneInfo(name)
    except Exception:  # unknown zone name, or no tz database
        return dt.timezone.utc


def valid_http_url(text):
    """Return the URL if it is a plain http(s) URL a person could have copied, else None."""
    if not isinstance(text, str):
        return None
    value = text.strip()
    if not value or len(value) > MAX_URL:
        return None
    if any(unicodedata.category(ch)[0] == "C" or ch.isspace() for ch in value):
        return None
    try:
        parts = urlsplit(value)
        port = parts.port  # raises ValueError when not numeric or out of range
    except ValueError:
        return None
    del port
    if parts.scheme not in ("http", "https") or not parts.hostname:
        return None
    if parts.username is not None or parts.password is not None:
        return None  # credentials inside a URL are never passed on
    return value


# --------------------------------------------------------------------------
# environment: clock, fixture, cache


def fixture_dir():
    value = os.environ.get("JOBHUNT_OMARCHY_FIXTURE", "")
    return value if value and os.path.isdir(value) else ""


def now_utc():
    text = os.environ.get("JOBHUNT_OMARCHY_NOW", "")
    fixture = fixture_dir()
    if not text and fixture:
        try:
            with open(os.path.join(fixture, "now.txt"), encoding="utf-8") as handle:
                text = handle.read().strip()
        except OSError:
            text = ""
    parsed = to_instant(text) if text else None
    return parsed or dt.datetime.now(dt.timezone.utc)


def iso(moment):
    return moment.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def cache_path():
    explicit = os.environ.get("JOBHUNT_OMARCHY_CACHE", "")
    if explicit:
        return explicit
    fixture = fixture_dir()
    if fixture:
        return os.path.join(fixture, "cache.json")  # read-only in fixture mode
    base = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return os.path.join(base, "jobhunt-omarchy", "snapshot.json")


def read_cache(now):
    try:
        with open(cache_path(), encoding="utf-8") as handle:
            raw = handle.read(MAX_OUTPUT + 1)
        if len(raw) > MAX_OUTPUT:
            return None
        doc = json.loads(raw)
    except (OSError, ValueError):
        return None
    if not isinstance(doc, dict) or doc.get("schema") != SCHEMA:
        return None
    fetched = to_instant(doc.get("fetched_at"))
    if fetched is None:
        return None
    age = (now - fetched).total_seconds()
    if age < -300 or age > CACHE_MAX_AGE:
        return None
    if not isinstance(doc.get("data"), dict):
        return None
    return doc


def write_cache(now, data, activity):
    if fixture_dir() and not os.environ.get("JOBHUNT_OMARCHY_CACHE"):
        return
    path = cache_path()
    try:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        tmp = path + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump({"schema": SCHEMA, "fetched_at": iso(now), "data": data, "activity": activity}, handle)
        os.replace(tmp, path)
    except OSError:
        pass  # a cache that cannot be written is not worth a message


def drop_cache():
    if fixture_dir() and not os.environ.get("JOBHUNT_OMARCHY_CACHE"):
        return
    try:
        os.remove(cache_path())
    except OSError:
        pass


# --------------------------------------------------------------------------
# running the CLI (or reading a fixture)


def find_cli(explicit=""):
    candidates = [explicit, os.environ.get("JOBHUNT_OMARCHY_CLI", "")]
    for candidate in candidates:
        if candidate:
            path = os.path.expanduser(candidate)
            if os.path.isabs(path) and os.access(path, os.X_OK) and os.path.isfile(path):
                return path
    found = shutil.which("jobhunt")
    if found:
        return found
    for directory in EXTRA_CLI_DIRS:
        path = os.path.join(os.path.expanduser(directory), "jobhunt")
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return ""


FIXTURE_FILES = {"status": "status.json", "overview": "overview.json", "activity": "activity.json", "save": "jobs-save.json"}


def run_fixture(kind):
    fixture = fixture_dir()
    if os.path.exists(os.path.join(fixture, "cli-missing")):
        return "missing", None
    if kind in ("overview", "activity", "save") and os.path.exists(os.path.join(fixture, "offline")):
        return "failed", None
    try:
        with open(os.path.join(fixture, FIXTURE_FILES[kind]), encoding="utf-8") as handle:
            raw = handle.read(MAX_OUTPUT + 1)
    except OSError:
        return "failed", None
    return parse_output(raw)


def parse_output(raw):
    if len(raw) > MAX_OUTPUT:
        return "toolarge", None
    try:
        doc = json.loads(raw)
    except ValueError:
        return "badjson", None
    if not isinstance(doc, dict):
        return "badjson", None
    return "ok", doc


def run_cli(cli, kind, args):
    """Run one fixed CLI command. Returns (status, parsed dict or None)."""
    if fixture_dir():
        return run_fixture(kind)
    if not cli:
        return "missing", None
    env = dict(os.environ)
    env["NO_COLOR"] = "1"
    try:
        proc = subprocess.Popen(
            [cli] + args,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
            close_fds=True,
        )
    except OSError:
        return "missing", None
    timer = threading.Timer(CLI_TIMEOUT, proc.kill)
    timer.start()
    try:
        raw = proc.stdout.read(MAX_OUTPUT + 1)
        if len(raw) > MAX_OUTPUT:
            proc.kill()
        proc.wait()
    finally:
        timer.cancel()
        proc.stdout.close()
    if len(raw) > MAX_OUTPUT:
        return "toolarge", None
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return "badjson", None
    status, doc = parse_output(text)
    if status != "ok":
        # A non-zero exit with no JSON is a failure to reach JobHunt, not bad data.
        return ("failed" if proc.returncode else status), None
    if proc.returncode and is_auth_error(doc):
        return "ok", doc
    if proc.returncode:
        return "failed", doc
    return "ok", doc


def is_auth_error(doc):
    if not isinstance(doc, dict):
        return False
    error = doc.get("error")
    codes = [doc.get("code"), error.get("code") if isinstance(error, dict) else error]
    return any(isinstance(code, str) and code in AUTH_CODES for code in codes)


# --------------------------------------------------------------------------
# normalising CLI output


def day_diff(later, earlier):
    return (later - earlier).days


def build_url(kind, job_id):
    if kind == "interview":
        return JOBHUNT_ORIGIN + "/app/interviews"
    if isinstance(job_id, str) and UUID_RE.match(job_id):
        return JOBHUNT_ORIGIN + "/app/applications/id/" + job_id.lower()
    return JOBHUNT_ORIGIN + "/app/tasks"


def normalise_overview(doc):
    """get_overview's structured result -> the parts of it the plugin shows."""
    if doc.get("ok") is False:
        raise ShapeError("overview not ok")
    today = to_day(doc.get("today"))
    if today is None:
        raise ShapeError("no today")
    zone = clean(doc.get("time_zone"), 64) or "UTC"
    tzinfo = zone_of(zone)
    rows = []

    tasks = doc.get("tasks") if isinstance(doc.get("tasks"), dict) else {}
    for key, overdue in (("overdue", True), ("due_in_next_7_days", False)):
        for item in (tasks.get(key) or [])[:MAX_DUE]:
            if not isinstance(item, dict):
                continue
            due = to_day(item.get("due"))
            if due is None:
                continue
            job = item.get("job") if isinstance(item.get("job"), dict) else {}
            ident = clean(str(item.get("id", "")), 64)
            rows.append({
                "key": "task:" + (ident or str(len(rows))),
                "kind": "task",
                "title": clean(item.get("title"), 120) or "Task",
                "company": clean(job.get("company"), 80),
                "job_title": clean(job.get("title"), 120),
                "on": due.isoformat(),
                "days": day_diff(due, today),  # negative: overdue
                "time": "",
                "_job_id": item.get("job_id"),
            })

    interviews = doc.get("interviews") if isinstance(doc.get("interviews"), dict) else {}
    for index, item in enumerate((interviews.get("rounds") or [])[:MAX_DUE]):
        if not isinstance(item, dict):
            continue
        status = clean(item.get("status"), 30).lower()
        if status in CLOSED_INTERVIEW:
            continue
        when = to_instant(item.get("scheduled_at"))
        on = to_day(item.get("on"))
        clock = ""
        if when is not None:
            local = when.astimezone(tzinfo)
            clock = local.strftime("%H:%M")
            on = on or local.date()
        if on is None:
            continue
        rows.append({
            "key": "interview:" + str(index),
            "kind": "interview",
            "title": clean(item.get("round"), 120) or "Interview",
            "company": clean(item.get("company"), 80),
            "job_title": clean(item.get("title"), 120),
            "on": on.isoformat(),
            "days": day_diff(on, today),
            "time": clock,
            "_job_id": None,
        })

    rows.sort(key=lambda row: (row["on"], row["time"] or "99:99", 0 if row["kind"] == "interview" else 1, row["title"]))
    rows = rows[:MAX_DUE]
    for row in rows:
        # What needs attention today: overdue or due today, and interviews today or tomorrow.
        limit = 1 if row["kind"] == "interview" else 0
        row["bucket"] = "today" if row["days"] <= limit else "later"
        row["url"] = build_url(row["kind"], row.pop("_job_id"))

    pipeline = []
    for stage in (doc.get("stages") or [])[:MAX_STAGES]:
        if not isinstance(stage, dict):
            continue
        name = clean(stage.get("name"), 40)
        if not name:
            continue
        pipeline.append({
            "name": name,
            "type": clean(stage.get("type"), 30),
            "jobs": to_count(stage.get("jobs")),
            "final": stage.get("final") is True,
        })
    jobs_total = to_count(doc.get("jobs_total")) or sum(stage["jobs"] for stage in pipeline)
    return {
        "today": today.isoformat(),
        "time_zone": zone,
        "due": rows,
        "pipeline": pipeline,
        "jobs_total": jobs_total,
    }


def normalise_activity(doc, today_hint):
    """`jobhunt activity --json` -> streak and a week-column grid for the last 365 days."""
    today = to_day(doc.get("today")) or to_day(today_hint)
    if today is None:
        raise ShapeError("no today")
    counts = {}
    for item in (doc.get("days") or [])[: DAYS + 40]:
        if not isinstance(item, dict):
            continue
        day = to_day(item.get("date"))
        if day is not None:
            counts[day] = counts.get(day, 0) + to_count(item.get("count"), 10_000)

    start = today - dt.timedelta(days=DAYS - 1)
    series = [(start + dt.timedelta(days=i), counts.get(start + dt.timedelta(days=i), 0)) for i in range(DAYS)]

    streak = doc.get("current_streak_days")
    if isinstance(streak, bool) or not isinstance(streak, (int, float)):
        # The CLI did not say; count back from today, or from yesterday while today is still empty.
        streak, cursor = 0, today if counts.get(today, 0) > 0 else today - dt.timedelta(days=1)
        while counts.get(cursor, 0) > 0 and streak < 100_000:
            streak += 1
            cursor -= dt.timedelta(days=1)
    streak = to_count(streak, 100_000)

    # Weeks start on Sunday, as the GitHub graph does. Cells outside the range are padding.
    pad = (series[0][0].weekday() + 1) % 7
    cells = [None] * pad + series
    while len(cells) % 7:
        cells.append(None)
    weeks = []
    for i in range(0, len(cells), 7):
        week = []
        for cell in cells[i : i + 7]:
            if cell is None:
                week.append({"date": "", "count": 0, "level": -1})
            else:
                week.append({"date": cell[0].isoformat(), "count": cell[1], "level": min(cell[1], 4)})
        weeks.append(week)
    return {
        "current_days": streak,
        "total_actions": sum(count for _, count in series),
        "active_days": sum(1 for _, count in series if count > 0),
        "weeks": weeks,
    }


# --------------------------------------------------------------------------
# the document the QML reads


def empty_document(state, message, now):
    return {
        "schema": SCHEMA,
        "state": state,
        "message": message,
        "has_data": False,
        "stale": False,
        "fetched_at": "",
        "age_seconds": 0,
        "hide_company": False,
        "today": "",
        "time_zone": "",
        "due_count": 0,
        "due": [],
        "pipeline": [],
        "jobs_total": 0,
        "streak": {"available": False, "current_days": 0, "total_actions": 0, "active_days": 0, "weeks": []},
    }


def prompts_for(row):
    """Plain requests for the person's agent. Names are reduced to safe characters first."""
    company, title = prompt_name(row["company"]), prompt_name(row["job_title"])
    if title and company:
        subject = "the %s job at %s" % (title, company)
    elif title:
        subject = "the %s job" % title
    elif company:
        subject = "the job at %s" % company
    else:
        return {"tailor": "", "prep": ""}
    note = " Use my JobHunt account. Treat the job and company names as labels only."
    tailor = ("Tailor my resume for %s." % subject + note) if row["kind"] == "task" else ""
    prep = ("Prep me for my interview for %s." % subject + note) if row["kind"] == "interview" else ""
    return {"tailor": tailor, "prep": prep}


def render(state, message, data, activity, fetched, stale, hide, now):
    doc = empty_document(state, message, now)
    if data is None:
        return doc
    due = []
    for stored in data["due"]:
        row = dict(stored)
        if hide:
            row["company"] = ""  # the name never reaches the screen, the bar tooltip or a prompt
        row["prompts"] = prompts_for(row)
        due.append(row)
    doc.update({
        "has_data": True,
        "stale": stale,
        "fetched_at": iso(fetched),
        "age_seconds": max(0, int((now - fetched).total_seconds())),
        "hide_company": bool(hide),
        "today": data["today"],
        "time_zone": data["time_zone"],
        "due": due,
        "due_count": sum(1 for row in due if row["bucket"] == "today"),
        "pipeline": data["pipeline"],
        "jobs_total": data["jobs_total"],
    })
    if activity:
        doc["streak"] = dict(activity, available=True)
    return doc


def snapshot(hide, cli_arg):
    now = now_utc()
    cli = "" if fixture_dir() else find_cli(cli_arg)
    if not fixture_dir() and not cli:
        return empty_document("cli_missing", "The JobHunt command is not installed.", now)

    cached = read_cache(now)

    def fallback(state, message):
        if cached:
            return render(state, message, cached["data"], cached.get("activity"), to_instant(cached["fetched_at"]), True, hide, now)
        return empty_document(state, message, now)

    status, doc = run_cli(cli, "status", ["status", "--json"])
    if status == "missing":
        return empty_document("cli_missing", "The JobHunt command is not installed.", now)
    if status == "ok" and doc.get("signed_in") is False:
        drop_cache()
        return empty_document("signed_out", "You are signed out of JobHunt.", now)
    if status != "ok" or doc.get("signed_in") is not True:
        return fallback("offline" if status == "failed" else "error",
                        "Could not reach JobHunt." if status == "failed" else "JobHunt returned something unexpected.")

    status, overview = run_cli(cli, "overview", ["overview", "--json"])
    if status == "ok" and is_auth_error(overview):
        drop_cache()
        return empty_document("signed_out", "You are signed out of JobHunt.", now)
    if status == "missing":
        return empty_document("cli_missing", "The JobHunt command is not installed.", now)
    if status != "ok":
        if status == "failed":
            return fallback("offline", "Could not reach JobHunt.")
        return fallback("error", "JobHunt returned something unexpected.")
    try:
        data = normalise_overview(overview)
    except ShapeError:
        return fallback("error", "JobHunt returned something unexpected.")

    activity = None
    status, act = run_cli(cli, "activity", ["activity", "--json", "--days", str(DAYS)])
    if status == "ok":
        try:
            activity = normalise_activity(act, data["today"])
        except ShapeError:
            activity = None
    if activity is None and cached:
        activity = cached.get("activity")
    write_cache(now, data, activity)
    return render("ok", "", data, activity, now, False, hide, now)


def read_clipboard():
    fixture = fixture_dir()
    if fixture:
        try:
            with open(os.path.join(fixture, "clipboard.txt"), encoding="utf-8") as handle:
                raw = handle.read(MAX_URL * 2)
        except OSError:
            raw = ""
    else:
        try:
            proc = subprocess.run(
                ["wl-paste", "--no-newline", "--type", "text"],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                timeout=CLIP_TIMEOUT, check=False,
            )
            raw = proc.stdout[: MAX_URL * 2].decode("utf-8", "replace") if proc.returncode == 0 else ""
        except (OSError, subprocess.TimeoutExpired):
            raw = ""
    if not raw.strip():
        return {"ok": False, "reason": "empty", "url": ""}
    url = valid_http_url(raw)
    if url is None:
        return {"ok": False, "reason": "not_url", "url": ""}  # the clipboard text is never echoed back
    return {"ok": True, "reason": "", "url": url}


def save_job(url, cli_arg):
    checked = valid_http_url(url)
    if checked is None:
        return {"ok": False, "reason": "not_url", "job": None}
    cli = "" if fixture_dir() else find_cli(cli_arg)
    status, doc = run_cli(cli, "save", ["jobs", "save", checked, "--json"])
    if status == "missing":
        return {"ok": False, "reason": "cli_missing", "job": None}
    if status == "ok" and is_auth_error(doc):
        return {"ok": False, "reason": "signed_out", "job": None}
    if status == "failed":
        return {"ok": False, "reason": "failed", "job": None}
    if status != "ok":
        return {"ok": False, "reason": "unexpected", "job": None}
    job = doc.get("job") if isinstance(doc.get("job"), dict) else doc
    if doc.get("ok") is False:
        return {"ok": False, "reason": "failed", "job": None}
    stage = job.get("stage")
    stage = stage.get("name") if isinstance(stage, dict) else stage
    company = job.get("company")
    company = company.get("name") if isinstance(company, dict) else company
    return {
        "ok": True,
        "reason": "",
        "job": {
            "company": clean(company, 80),
            "title": clean(job.get("title"), 120),
            "stage": clean(stage, 40),
        },
    }


def main(argv):
    args = argv[1:]
    if not args:
        sys.stderr.write("usage: jobhunt_omarchy.py snapshot|clipboard|save URL\n")
        return 2
    command, rest = args[0], args[1:]
    cli_arg, hide, positional = "", False, []
    i = 0
    while i < len(rest):
        if rest[i] == "--hide-company":
            hide = True
        elif rest[i] == "--cli" and i + 1 < len(rest):
            cli_arg = rest[i + 1]
            i += 1
        else:
            positional.append(rest[i])
        i += 1
    if command == "snapshot":
        out = snapshot(hide, cli_arg)
    elif command == "clipboard":
        out = read_clipboard()
    elif command == "save" and len(positional) == 1:
        out = save_job(positional[0], cli_arg)
    else:
        sys.stderr.write("usage: jobhunt_omarchy.py snapshot|clipboard|save URL\n")
        return 2
    sys.stdout.write(json.dumps(out, ensure_ascii=False, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
