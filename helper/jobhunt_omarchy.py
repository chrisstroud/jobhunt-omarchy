#!/usr/bin/env python3
"""Helper for the JobHunt Omarchy plugin (Python 3 standard library only).

The QML never talks to JobHunt. It runs this script, which runs the JobHunt
command line tool (`jobhunt`) with fixed arguments, checks and trims what comes
back, and prints one small JSON document. If the CLI's output shape changes,
only the normalise_* functions below change.

    jobhunt_omarchy.py snapshot [--hide-company] [--cli PATH]
    jobhunt_omarchy.py clipboard
    jobhunt_omarchy.py save URL [--cli PATH]
    jobhunt_omarchy.py login|logout [--cli PATH]

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
import signal
import subprocess
import sys
import threading
import unicodedata
from urllib.parse import urlsplit
from zoneinfo import ZoneInfo

SCHEMA = 1
PLUGIN_VERSION = "0.2.0"
# The cache file's own version (separate from SCHEMA, which the QML checks). 1 = written by plugin 0.1.0.
CACHE_VERSION = 2
# The first command-line version with the commands the Board, Docs, Page, search and Quick Add views read.
# One place, so the check can change (a version number today; a capability answer from the command later).
CLI_FEATURE_MIN = (0, 2, 0)
CLI_FEATURES = ("board", "docs", "page", "find", "add")
CLI_VERSION_RE = re.compile(r"^v?(\d{1,4})\.(\d{1,4})\.(\d{1,4})(?:[-+][0-9A-Za-z.-]{0,40})?$")
CLI_VERSION_TIMEOUT = 5
ACCESS_KINDS = ("free", "trial", "subscribed", "read_only", "review")
MAX_ROLES = 6
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


def job_uuid(value):
    """A job id as a lower-case UUID, or "" when it is anything else. Ids are the only
    network-derived value that may appear in an agent prompt."""
    if isinstance(value, str) and UUID_RE.fullmatch(value):
        return value.lower()
    return ""


def to_day(value):
    if not isinstance(value, str) or not DAY_RE.fullmatch(value):
        return None
    try:
        return dt.date.fromisoformat(value)
    except ValueError:
        return None


def to_instant(value):
    if not isinstance(value, str) or not INSTANT_RE.fullmatch(value):
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
    version = doc.get("version")
    if isinstance(version, bool) or not isinstance(version, int):
        version = 1  # written by plugin 0.1.0
    if version > CACHE_VERSION:
        return None  # written by a newer plugin: ignore it rather than guess
    doc["data"] = with_defaults(doc["data"])
    return doc


def cache_written_by_older_plugin():
    """True when a cache file from plugin 0.1.0 is on disk, however old it is: the person has updated.
    Read by the first snapshot after the update; the panel keeps the "what's new" line until it is dismissed."""
    try:
        with open(cache_path(), encoding="utf-8") as handle:
            raw = handle.read(MAX_OUTPUT + 1)
        doc = json.loads(raw) if len(raw) <= MAX_OUTPUT else None
    except (OSError, ValueError):
        return False
    if not isinstance(doc, dict) or doc.get("schema") != SCHEMA:
        return False
    version = doc.get("version")
    return isinstance(version, bool) or not isinstance(version, int) or version < CACHE_VERSION


def write_cache(now, data, activity):
    if fixture_dir() and not os.environ.get("JOBHUNT_OMARCHY_CACHE"):
        return
    path = cache_path()
    try:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        tmp = path + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump({"schema": SCHEMA, "version": CACHE_VERSION, "fetched_at": iso(now), "data": data, "activity": activity}, handle)
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


def parse_cli_version(text):
    match = CLI_VERSION_RE.fullmatch((text or "").strip())
    return (int(match.group(1)), int(match.group(2)), int(match.group(3))) if match else None


def cli_info(cli):
    """The installed command's version and what it can do. A version that cannot be read counts as old:
    nothing then promises a view the command may not have. Fixture mode reads version.txt (default 0.1.2)."""
    if fixture_dir():
        text = read_small(os.path.join(fixture_dir(), "version.txt"))
        text = "0.1.2" if text is None else text
    elif cli:
        text = ""
        try:
            proc = subprocess.run([cli, "--version"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, timeout=CLI_VERSION_TIMEOUT, env=dict(os.environ, NO_COLOR="1"), close_fds=True)
            if proc.returncode == 0:
                text = proc.stdout[:64].decode("utf-8", "replace")
        except (OSError, subprocess.SubprocessError):
            text = ""
    else:
        text = ""
    parsed = parse_cli_version(text)
    new = parsed is not None and parsed >= CLI_FEATURE_MIN
    return {
        "version": ".".join(str(part) for part in parsed) if parsed else "",
        "features": {name: new for name in CLI_FEATURES},
    }


FIXTURE_FILES = {"status": "status.json", "overview": "overview.json", "activity": "activity.json", "save": "jobs-save.json"}


def read_small(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read(MAX_OUTPUT + 1)
    except OSError:
        return None


def run_fixture(kind):
    """Fixture mode. error-<kind>.json (+ optional error-<kind>.code) plays a failure like the real CLI."""
    fixture = fixture_dir()
    if os.path.exists(os.path.join(fixture, "cli-missing")):
        return "missing", None, 0
    failure = read_small(os.path.join(fixture, "error-%s.json" % kind))
    if failure is not None:
        code_text = (read_small(os.path.join(fixture, "error-%s.code" % kind)) or "7").strip()
        code = int(code_text) if code_text.isdigit() else 7
        status, doc = parse_output(failure)
        return "error", (doc if status == "ok" else None), code
    raw = read_small(os.path.join(fixture, FIXTURE_FILES[kind]))
    if raw is None:
        return "error", None, 7
    status, doc = parse_output(raw)
    return status, doc, 0


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


def drain(stream, limit, sink):
    """Read up to `limit` bytes into sink, then discard the rest so the child never blocks."""
    kept = 0
    while True:
        chunk = stream.read(4096)
        if not chunk:
            return
        if kept < limit:
            sink.append(chunk[: limit - kept])
            kept += len(chunk)


def run_cli(cli, kind, args):
    """Run one fixed CLI command under the contract: success is JSON on stdout with exit 0;
    failure is JSON on stderr with a non-zero exit. Returns (outcome, doc, exit_code) where
    outcome is ok, missing, toolarge, badjson or error (doc is then the parsed stderr, if any)."""
    if fixture_dir():
        return run_fixture(kind)
    if not cli:
        return "missing", None, 0
    env = dict(os.environ)
    env["NO_COLOR"] = "1"
    try:
        proc = subprocess.Popen(
            [cli] + args,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            close_fds=True,
        )
    except OSError:
        return "missing", None, 0
    err_chunks = []
    reader = threading.Thread(target=drain, args=(proc.stderr, 65536, err_chunks), daemon=True)
    reader.start()
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
    reader.join(2)
    code = proc.returncode
    if len(raw) > MAX_OUTPUT:
        return "toolarge", None, 0  # killed by us for sending too much; not a timeout
    if code != 0:
        # Killed (timeout) or any non-zero exit: classify by code; stderr JSON adds detail.
        try:
            status, doc = parse_output(b"".join(err_chunks).decode("utf-8"))
        except UnicodeDecodeError:
            status, doc = "badjson", None
        return "error", (doc if status == "ok" else None), code
    try:
        status, doc = parse_output(raw.decode("utf-8"))
    except UnicodeDecodeError:
        return "badjson", None, 0
    return status, doc, 0


def classify_failure(code):
    """The contract's exit codes, as the plugin's states."""
    if code == 3:
        return "signed_out"
    if code == 7 or code < 0:
        return "offline"  # unreachable, answered badly, or killed by the timeout
    if code == 6:
        return "rate_limited"
    if code == 4:
        return "permission"
    return "error"


def error_detail(doc):
    error = doc.get("error") if isinstance(doc, dict) else None
    return error if isinstance(error, dict) else {}


def retry_after(doc):
    value = error_detail(doc).get("retry_after_seconds")
    return to_count(value, 86400) if isinstance(value, (int, float)) and not isinstance(value, bool) else 0


# --------------------------------------------------------------------------
# normalising CLI output


def day_diff(later, earlier):
    return (later - earlier).days


def build_url(kind, job_id):
    if kind == "interview":
        return JOBHUNT_ORIGIN + "/app/interviews"
    if isinstance(job_id, str) and UUID_RE.fullmatch(job_id):
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
                "job_id": job_uuid(item.get("job_id")),
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
            "job_id": "",  # the contract gives rounds no id, so interviews carry no agent prompt
        })

    rows.sort(key=lambda row: (row["on"], row["time"] or "99:99", 0 if row["kind"] == "interview" else 1, row["title"]))
    rows = rows[:MAX_DUE]
    for row in rows:
        # What needs attention today: overdue or due today, and interviews today or tomorrow.
        limit = 1 if row["kind"] == "interview" else 0
        row["bucket"] = "today" if row["days"] <= limit else "later"
        row["url"] = build_url(row["kind"], row["job_id"])

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

    # Roles the overview already names: Applied jobs (longest in stage first) and the jobs with a
    # live interview round. Other stages need the command's `board` view (CLI 0.2.0).
    applied = []
    applied_doc = doc.get("applied") if isinstance(doc.get("applied"), dict) else {}
    for item in (applied_doc.get("jobs") or [])[:MAX_ROLES]:
        if isinstance(item, dict) and (clean(item.get("title"), 120) or clean(item.get("company"), 80)):
            applied.append({
                "company": clean(item.get("company"), 80),
                "title": clean(item.get("title"), 120),
                "days": to_count(item.get("stage_days"), 100000) if isinstance(item.get("stage_days"), (int, float)) else -1,
            })
    interviewing = []
    seen = set()
    for row in rows:
        if row["kind"] != "interview":
            continue
        key = (row["company"], row["job_title"])
        if key in seen or len(interviewing) >= MAX_ROLES:
            continue
        seen.add(key)
        interviewing.append({"company": row["company"], "title": row["job_title"], "round": row["title"], "on": row["on"], "days": row["days"], "time": row["time"]})

    account = doc.get("account") if isinstance(doc.get("account"), dict) else {}
    hunt = doc.get("hunt") if isinstance(doc.get("hunt"), dict) else {}
    resume = doc.get("resume") if isinstance(doc.get("resume"), dict) else {}
    return {
        "today": today.isoformat(),
        "time_zone": zone,
        "due": rows,
        "pipeline": pipeline,
        "jobs_total": jobs_total,
        "account": {"name": clean(account.get("name"), 80)},
        "access": normalise_access(doc.get("access")),
        "hunt": {"name": clean(hunt.get("name"), 80)},
        "resume": {"name": clean(resume.get("name"), 80)},
        "applied": applied,
        "interviewing": interviewing,
    }


def normalise_access(value):
    """overview.access -> what the footer needs. `next` is written for an assistant and never shown."""
    access = value if isinstance(value, dict) else {}
    kind = clean(access.get("kind"), 20).lower()
    if kind not in ACCESS_KINDS:
        kind = ""  # an unknown plan state shows no chip rather than a guess
    days = access.get("days_left")
    days_left = to_count(days, 100000) if kind == "trial" and isinstance(days, (int, float)) and not isinstance(days, bool) else None
    return {"kind": kind, "days_left": days_left}


def with_defaults(data):
    """A cache written by plugin 0.1.0 has none of the account fields: fill them, keep the rest."""
    out = dict(data)
    out.setdefault("account", {"name": ""})
    out.setdefault("access", {"kind": "", "days_left": None})
    out.setdefault("hunt", {"name": ""})
    out.setdefault("resume", {"name": ""})
    out.setdefault("applied", [])
    out.setdefault("interviewing", [])
    return out


def normalise_activity(doc, today_hint):
    """`jobhunt activity --json` -> totals and a week-column grid. Counts of recorded actions only:
    the contract defines counts only, and the plugin derives nothing from them."""
    today = to_day(doc.get("today")) or to_day(today_hint)
    if today is None:
        raise ShapeError("no today")
    counts = {}
    for item in (doc.get("days") or [])[:1100]:
        if not isinstance(item, dict):
            continue
        day = to_day(item.get("date"))
        if day is not None:
            counts[day] = counts.get(day, 0) + to_count(item.get("count"), 10_000)
    if not counts:
        raise ShapeError("no days")
    # The window ends today and is at most a year long; a shorter answer gives a shorter grid.
    start = max(today - dt.timedelta(days=DAYS - 1), min(counts))
    length = (today - start).days + 1
    series = [(start + dt.timedelta(days=i), counts.get(start + dt.timedelta(days=i), 0)) for i in range(length)]
    recorded = sum(count for _, count in series)
    active = sum(1 for _, count in series if count > 0)

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
    return {"window_days": length, "recorded_actions": recorded, "active_days": active, "weeks": weeks}


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
        "momentum": {"available": False, "window_days": 0, "recorded_actions": 0, "active_days": 0, "weeks": []},
        "retry_after_seconds": 0,
        "plugin_version": PLUGIN_VERSION,
        "upgraded_from": "",
        "cli": {"version": "", "features": {name: False for name in CLI_FEATURES}},
        "account": {"name": ""},
        "access": {"kind": "", "days_left": None},
        "hunt": {"name": ""},
        "resume": {"name": ""},
        "applied": [],
        "interviewing": [],
    }


def prompts_for(row):
    """Requests for the person's agent: fixed wording plus a validated UUID. Nothing else from
    the network (no title, no company, no task text) is ever put in a prompt, because
    omarchy-agent runs agents in auto-approve modes. Only tasks tied to a job carry an id."""
    ident = job_uuid(row.get("job_id"))
    if ident and row.get("kind") == "task":
        return {"tailor": "In JobHunt, tailor my resume for the job with id %s. Show me the changes before saving." % ident}
    return {"tailor": ""}


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
        "account": data["account"],
        "access": data["access"],
        "hunt": data["hunt"],
        "resume": data["resume"],
        # Company names never reach the screen when the person hides them.
        "applied": [dict(role, company="") if hide else role for role in data["applied"]],
        "interviewing": [dict(role, company="") if hide else role for role in data["interviewing"]],
    })
    if activity:
        doc["momentum"] = dict(activity, available=True)
    return doc


STATE_MESSAGES = {
    "offline": "Could not reach JobHunt.",
    "rate_limited": "JobHunt asked for a short pause.",
    "permission": "This connection lacks a permission JobHunt needs.",
    "error": "JobHunt returned something unexpected.",
    "signed_out": "You are signed out of JobHunt.",
}


def snapshot(hide, cli_arg):
    """The one document the panel reads, plus what the update needs: whether this is the first read after
    plugin 0.1.0, and what the installed command can do."""
    upgraded = cache_written_by_older_plugin()  # before this read replaces the cache
    doc = snapshot_state(hide, cli_arg)
    doc["upgraded_from"] = "0.1.0" if upgraded else ""
    if doc.get("state") != "cli_missing":
        doc["cli"] = cli_info("" if fixture_dir() else find_cli(cli_arg))
    return doc


def snapshot_state(hide, cli_arg):
    now = now_utc()
    cli = "" if fixture_dir() else find_cli(cli_arg)
    missing = empty_document("cli_missing", "The JobHunt command is not installed.", now)
    if not fixture_dir() and not cli:
        return missing

    cached = read_cache(now)

    def fallback(state, retry=0):
        # `permission` is shown as an error with its own sentence.
        shown = "error" if state == "permission" else state
        message = STATE_MESSAGES[state]
        if cached:
            doc = render(shown, message, cached["data"], cached.get("activity"), to_instant(cached["fetched_at"]), True, hide, now)
        else:
            doc = empty_document(shown, message, now)
        doc["retry_after_seconds"] = retry
        return doc

    def signed_out():
        drop_cache()
        return empty_document("signed_out", STATE_MESSAGES["signed_out"], now)

    outcome, doc, code = run_cli(cli, "status", ["status", "--json"])
    if outcome == "missing":
        return missing
    if outcome == "error":
        state = classify_failure(code)
        return signed_out() if state == "signed_out" else fallback(state, retry_after(doc))
    if outcome != "ok" or not isinstance(doc.get("signed_in"), bool):
        return fallback("error")
    if doc["signed_in"] is False:
        return signed_out()  # a normal answer from `status`, exit 0

    outcome, overview, code = run_cli(cli, "overview", ["overview", "--json"])
    if outcome == "missing":
        return missing
    if outcome == "error":
        state = classify_failure(code)
        return signed_out() if state == "signed_out" else fallback(state, retry_after(overview))
    if outcome != "ok":
        return fallback("error")
    try:
        data = normalise_overview(overview)
    except ShapeError:
        return fallback("error")

    activity = None
    outcome, act, code = run_cli(cli, "activity", ["activity", "--json", "--days", str(DAYS)])
    if outcome == "ok":
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
    def fail(reason, message=""):
        return {"ok": False, "reason": reason, "message": message, "job": None, "already_saved": False, "details_pending": False}

    checked = valid_http_url(url)
    if checked is None:
        return fail("not_url")
    cli = "" if fixture_dir() else find_cli(cli_arg)
    outcome, doc, code = run_cli(cli, "save", ["jobs", "save", checked, "--json"])
    if outcome == "missing":
        return fail("cli_missing")
    if outcome == "error":
        state = classify_failure(code)
        if state == "signed_out":
            return fail("signed_out")
        if state == "offline":
            return fail("unreachable")
        if state in ("rate_limited", "permission"):
            return fail(state)
        if code == 2:  # refused: the service explains in one sentence for a person; shown as plain text
            return fail("refused", clean(error_detail(doc).get("message"), 200))
        return fail("failed")
    if outcome != "ok" or doc.get("ok") is False or not isinstance(doc.get("job"), dict):
        return fail("unexpected")
    job = doc["job"]
    return {
        "ok": True,
        "reason": "",
        "message": "",
        # Title and company are null until the link has been read; the stage is a name JobHunt gave.
        "job": {"company": clean(job.get("company"), 80), "title": clean(job.get("title"), 120), "stage": clean(job.get("stage"), 40)},
        "already_saved": doc.get("already_saved") is True,
        "details_pending": doc.get("details_pending") is True,
    }


LOGIN_TIMEOUT = 300
LOGOUT_TIMEOUT = 30


# An error code from the CLI's contract: a short lower-case word. Nothing else from its output is kept.
AUTH_CODE = re.compile(r"^[a-z][a-z0-9_]{0,39}$")


def auth_error_code(stderr):
    """The `error.code` of the CLI's JSON error on stderr, if it has that shape; "" otherwise. Its
    stdout is never read (it may be a token or a link), and no other part of stderr is kept."""
    try:
        doc = json.loads((stderr or b"")[:4096].decode("utf-8", "replace"))
    except ValueError:
        return ""
    code = doc.get("error", {}).get("code") if isinstance(doc, dict) and isinstance(doc.get("error"), dict) else None
    return code if isinstance(code, str) and AUTH_CODE.match(code) else ""


def run_auth(cli, args, timeout):
    """Run `jobhunt auth ...` with no flags and no input. Its stdout is never read (it may be a token
    or a link), so it goes to /dev/null; from stderr only the contract's error code is kept. Returns
    (result, code): result is "ok", "failed", "timeout", "cancelled" or "cli_missing", and code is the
    error code for "failed" ("" when there is none). SIGTERM to this helper stops the child and
    answers "cancelled"."""
    if fixture_dir():
        if os.path.exists(os.path.join(fixture_dir(), "cli-missing")):
            return "cli_missing", ""
        marker = os.path.join(fixture_dir(), "login-fails")
        if os.path.exists(marker) and args[1] == "login":
            with open(marker) as f:
                code = f.read().strip()
            return "failed", code if AUTH_CODE.match(code) else ""
        return "ok", ""
    if not cli:
        return "cli_missing", ""
    try:
        proc = subprocess.Popen([cli] + args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.PIPE, close_fds=True)
    except OSError:
        return "cli_missing", ""
    cancelled = []

    def stop(_signum, _frame):
        cancelled.append(True)
        proc.kill()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        _, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
        return "timeout", ""
    if cancelled:
        return "cancelled", ""
    return ("ok", "") if proc.returncode == 0 else ("failed", auth_error_code(err))


def sign_in(cli_arg):
    cli = "" if fixture_dir() else find_cli(cli_arg)
    try:
        limit = float(os.environ.get("JOBHUNT_OMARCHY_LOGIN_TIMEOUT", LOGIN_TIMEOUT))
    except ValueError:
        limit = LOGIN_TIMEOUT
    result, code = run_auth(cli, ["auth", "login"], limit)
    out = {"ok": result == "ok", "reason": "" if result == "ok" else result}
    if result == "failed":
        out["code"] = code  # the panel shows one plain line per known code
    return out


def sign_out(cli_arg):
    cli = "" if fixture_dir() else find_cli(cli_arg)
    result, _ = run_auth(cli, ["auth", "logout"], LOGOUT_TIMEOUT)
    drop_cache()  # the plugin's copy of the person's data goes whatever the CLI said
    return {"ok": result == "ok", "reason": "" if result == "ok" else result}


def main(argv):
    args = argv[1:]
    if not args:
        sys.stderr.write("usage: jobhunt_omarchy.py snapshot|clipboard|save URL|login|logout\n")
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
    elif command == "login" and not positional:
        out = sign_in(cli_arg)
    elif command == "logout" and not positional:
        out = sign_out(cli_arg)
    elif command == "save" and len(positional) == 1:
        out = save_job(positional[0], cli_arg)
    else:
        sys.stderr.write("usage: jobhunt_omarchy.py snapshot|clipboard|save URL|login|logout\n")
        return 2
    sys.stdout.write(json.dumps(out, ensure_ascii=False, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
