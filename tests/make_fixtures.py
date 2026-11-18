#!/usr/bin/env python3
"""Regenerates fixtures/. All names are invented. Run: python3 tests/make_fixtures.py

fixtures/contract is the CLI contract's own example files, copied verbatim from
tests/contract-fixtures. The other scenarios use the same shapes with more data. Failures are
played like the real CLI: error-<command>.json is what it prints to stderr and
error-<command>.code the exit code (3 signed out, 6 rate limited, 7 unreachable, ...)."""
import datetime as dt, json, os, random, shutil, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "fixtures")
CONTRACT = os.path.join(HERE, "contract-fixtures")
NOW = "2026-11-17T15:00:00Z"
TODAY = dt.date(2026, 11, 17)
U = ["3f2a9c1e-5b7d-4e8a-9c21-0a1b2c3d4e5f", "7a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", "c0ffee00-1111-4222-8333-444455556666"]

WRAPPER = """#!/bin/sh
# Stand-in for the jobhunt command: answers from the JSON files beside it and makes no network
# call. It follows the plugin contract: success is JSON on stdout (exit 0); a scenario with an
# error-<command>.json prints that to stderr and exits with error-<command>.code instead.
# `auth login` (no flags allowed) flips the scenario to signed in, `auth logout` to signed out,
# by touching .signed-in / .signed-out here; delete those files to reset. A scenario with a
# login-fails file refuses to sign in, with the error code written in that file. Point the plugin's "JobHunt command path" setting at this
# file to see a scenario.
d=$(dirname "$0")
no_auth='{"error":{"code":"authentication_required","status":401}}'
if [ "$1" = auth ]; then
  case "$2" in
    login)
      [ "$#" -eq 2 ] || { echo '{"error":{"code":"invalid_input","status":0}}' >&2; exit 2; }
      if [ -e "$d/login-fails" ]; then c=$(cat "$d/login-fails"); printf '{"error":{"code":"%s","status":0}}\n' "${c:-access_denied}" >&2; exit 3; fi
      rm -f "$d/.signed-out"; touch "$d/.signed-in"; exit 0 ;;
    logout) rm -f "$d/.signed-in"; touch "$d/.signed-out"; exit 0 ;;
  esac
  exit 2
fi
case "$1" in
  status) k=status; f=status.json ;;
  overview) k=overview; f=overview.json ;;
  activity) k=activity; f=activity.json ;;
  jobs) k=save; f=jobs-save.json ;;
  *) echo '{"error":{"code":"invalid_input","status":0}}' >&2; exit 2 ;;
esac
in=1; grep -q '"signed_in": false' "$d/status.json" 2>/dev/null && in=0
[ -e "$d/.signed-in" ] && in=1
[ -e "$d/.signed-out" ] && in=0
if [ "$in" = 0 ]; then
  [ "$k" = status ] && { echo '{"signed_in":false}'; exit 0; }
  echo "$no_auth" >&2; exit 3
fi
src="$d"; [ -e "$d/$f" ] || src="$d/../busy-day"
[ "$k" = status ] && { echo '{"signed_in":true}'; exit 0; }
if [ -e "$d/error-$k.json" ]; then
  cat "$d/error-$k.json" >&2
  code=7; [ -e "$d/error-$k.code" ] && code=$(cat "$d/error-$k.code")
  exit "$code"
fi
cat "$src/$f" || exit 7
"""


def dump(path, value):
    with open(path, "w") as f:
        if isinstance(value, str):
            f.write(value)
        else:
            json.dump(value, f, indent=1)
            f.write("\n")


def put(name, files, now=NOW, wrapper=True, markers=()):
    d = os.path.join(ROOT, name)
    os.makedirs(d, exist_ok=True)
    dump(os.path.join(d, "now.txt"), now + "\n")
    for k, v in files.items():
        dump(os.path.join(d, k), v)
    if wrapper:
        w = os.path.join(d, "jobhunt")
        dump(w, WRAPPER)
        os.chmod(w, 0o755)
    for m in markers:  # a name, or (name, content)
        name, content = (m, "") if isinstance(m, str) else m
        with open(os.path.join(d, name), "w") as f:
            f.write(content + ("\n" if content else ""))


def contract(name):
    with open(os.path.join(CONTRACT, name)) as f:
        return json.load(f)


stages = [{"name": n, "type": t, "jobs": j, "final": fin} for n, t, j, fin in [
    ("To Apply", "saved", 6, False), ("Applied", "applied", 9, False), ("Interviewing", "interview", 2, False),
    ("Offer", "offer", 0, False), ("Closed", "closed", 4, True)]]


def overview(tasks_over, tasks_soon, rounds):
    base = contract("overview.json")
    base.update({"today": "2026-11-17", "stages": stages, "jobs_total": 21,
                 "tasks": {"overdue": tasks_over, "due_in_next_7_days": tasks_soon, "complete": True},
                 "interviews": {"rounds": rounds, "total": len(rounds)}})
    return base


busy_over = [{"id": "t1", "title": "Send thank-you note", "due": "2026-11-15", "due_days": 2, "job_id": U[0], "job": {"company": "Northwind Mills", "title": "Staff Designer"}}]
busy_soon = [
    {"id": "t2", "title": "Follow up on application", "due": "2026-11-17", "due_in_days": 0, "job_id": U[1], "job": {"company": "Fabrikam Harbor", "title": "Product Lead"}},
    {"id": "t3", "title": "Submit application", "due": "2026-11-20", "due_in_days": 3, "job_id": U[2], "job": {"company": "Contoso Kites", "title": "Design Manager"}},
    {"id": "t4", "title": "Update portfolio", "due": "2026-11-18", "due_in_days": 1, "job_id": None}]
busy_rounds = [
    {"round": "Panel interview", "scheduled_at": "2026-11-17T21:30:00Z", "on": "2026-11-17", "company": "Northwind Mills", "title": "Staff Designer", "job_id": U[0], "application_url": "https://jobhunt.app/app/applications/id/" + U[0]},
    {"round": "Phone screen", "scheduled_at": "2026-11-19T17:00:00Z", "on": "2026-11-19", "company": "Fabrikam Harbor", "title": "Product Lead", "job_id": U[1], "application_url": "https://jobhunt.app/app/applications/id/" + U[1]},
    {"round": "Hiring manager chat", "scheduled_at": "2026-11-18T18:00:00Z", "on": "2026-11-18", "company": "Contoso Kites", "title": "Design Manager", "status": "cancelled", "job_id": U[2], "application_url": "https://jobhunt.app/app/applications/id/" + U[2]}]


def activity(seed, density, days=365):
    rnd = random.Random(seed)
    out = []
    for i in range(days):
        d = TODAY - dt.timedelta(days=days - 1 - i)
        n = rnd.choice([0, 1, 1, 2, 3, 5]) if rnd.random() < density else 0
        out.append({"date": d.isoformat(), "count": n})
    return {"today": "2026-11-17", "time_zone": "America/Los_Angeles", "from": out[0]["date"], "days": out,
            "active_days": sum(1 for x in out if x["count"] > 0), "recorded_actions": sum(x["count"] for x in out)}


ok_status = {"signed_in": True}
saved = contract("jobs-save.json")
err_out = contract("error-signed-out.json")

put("contract", {"status.json": contract("status-signed-in.json"), "overview.json": contract("overview.json"), "activity.json": contract("activity.json"),
                 "jobs-save.json": saved, "clipboard.txt": "https://jobs.example/postings/123\n"}, now="2026-11-18T15:00:00Z")
put("busy-day", {"status.json": ok_status, "overview.json": overview(busy_over, busy_soon, busy_rounds), "activity.json": activity(1, 0.6),
                 "jobs-save.json": saved, "clipboard.txt": "https://example.com/careers/research-lead\n"})
put("nothing-due", {"status.json": ok_status, "overview.json": overview([], [], []), "activity.json": activity(2, 0.0, 120),
                    "jobs-save.json": saved, "clipboard.txt": "not a link, just some words"})
put("signed-out", {"status.json": contract("status-signed-out.json")})
put("sign-in-fails", {"status.json": contract("status-signed-out.json")}, markers=[("login-fails", "access_denied")])
# A code the panel has no sentence for: it shows the general one.
put("sign-in-fails-other", {"status.json": contract("status-signed-out.json")}, markers=[("login-fails", "something_new")])
put("revoked", {"status.json": ok_status, "error-overview.json": err_out, "error-overview.code": "3\n", "error-save.json": err_out, "error-save.code": "3\n"})
put("cli-missing", {}, wrapper=False, markers=["cli-missing"])
put("year-of-activity", {"status.json": ok_status, "overview.json": overview([], busy_soon[:1], []), "activity.json": activity(7, 1.0)})
put("save-refused", {"status.json": ok_status, "error-save.json": contract("error-refused.json"), "error-save.code": "2\n"})

sys.path.insert(0, os.path.join(HERE, "..", "helper"))
import jobhunt_omarchy as h
cache = {"schema": 1, "fetched_at": "2026-11-17T09:00:00Z", "data": h.normalise_overview(overview(busy_over, busy_soon, busy_rounds)),
         "activity": h.normalise_activity(activity(1, 0.6), "2026-11-17")}
put("stale-offline", {"status.json": ok_status, "cache.json": cache, "error-overview.json": {"error": {"code": "unreachable", "status": 0}}, "error-overview.code": "7\n"})
put("rate-limited", {"status.json": ok_status, "cache.json": cache,
                     "error-overview.json": {"error": {"code": "rate_limited", "status": 429, "retry_after_seconds": 120}}, "error-overview.code": "6\n"})
