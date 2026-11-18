#!/usr/bin/env python3
"""Regenerates fixtures/. All names are invented. Run: python3 tests/make_fixtures.py"""
import datetime as dt, json, os, random

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fixtures")
NOW = "2026-11-17T15:00:00Z"
TODAY = dt.date(2026, 11, 17)
U = ["3f2a9c1e-5b7d-4e8a-9c21-0a1b2c3d4e5f", "7a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", "c0ffee00-1111-4222-8333-444455556666"]


WRAPPER = """#!/bin/sh
# Stand-in for the jobhunt command: answers from the JSON files beside it and makes no network
# call. Point the plugin's "JobHunt command path" setting at this file to see this scenario.
d=$(dirname "$0")
case "$1" in
  status) cat "$d/status.json" ;;
  overview|activity) [ -e "$d/offline" ] && exit 1; cat "$d/$1.json" ;;
  jobs) [ -e "$d/offline" ] && exit 1; cat "$d/jobs-save.json" ;;
  *) exit 2 ;;
esac
"""


def put(name, files, markers=()):
    d = os.path.join(ROOT, name)
    os.makedirs(d, exist_ok=True)
    files = dict(files, **{"now": None})
    with open(os.path.join(d, "now.txt"), "w") as f:
        f.write(NOW + "\n")
    for k, v in files.items():
        if k == "now":
            continue
        with open(os.path.join(d, k), "w") as f:
            if isinstance(v, str):
                f.write(v)
            else:
                json.dump(v, f, indent=1)
                f.write("\n")
    if name != "cli-missing":
        wrapper = os.path.join(d, "jobhunt")
        with open(wrapper, "w") as f:
            f.write(WRAPPER)
        os.chmod(wrapper, 0o755)
    for m in markers:
        open(os.path.join(d, m), "w").close()


stages = [{"name": n, "type": t, "jobs": j, "final": fin} for n, t, j, fin in [
    ("To Apply", "to_apply", 6, False), ("Applied", "applied", 9, False), ("Interviewing", "interviewing", 2, False),
    ("Offer", "offer", 0, False), ("Closed", "closed", 4, True)]]


def overview(tasks_over, tasks_soon, rounds):
    return {"ok": True, "today": "2026-11-17", "time_zone": "America/Los_Angeles", "time_zone_saved": True,
            "account": {"id": "x", "name": "Sample Person"}, "setup": [], "setup_complete": True, "access": None,
            "hunt": {"id": "h1", "name": "Spring search", "status": "active"}, "stages": stages,
            "jobs_total": 21, "tasks": {"overdue": tasks_over, "due_in_next_7_days": tasks_soon, "complete": True},
            "interviews": {"rounds": rounds, "total": len(rounds)} if rounds is not None else None,
            "applied": {"jobs": [], "total": 9}, "offers": {"jobs": [], "total": 0}, "reading_link": {"jobs": [], "total": 0},
            "covers": "Sample.", "not_included": {}, "resume": None, "missing": [], "website_url": "https://jobhunt.app/app"}


busy_over = [{"id": "t1", "title": "Send thank-you note", "due": "2026-11-15", "due_days": 2, "job_id": U[0], "job": {"company": "Northwind Mills", "title": "Staff Designer"}}]
busy_soon = [
    {"id": "t2", "title": "Follow up on application", "due": "2026-11-17", "due_in_days": 0, "job_id": U[1], "job": {"company": "Fabrikam Harbor", "title": "Product Lead"}},
    {"id": "t3", "title": "Submit application", "due": "2026-11-20", "due_in_days": 3, "job_id": U[2], "job": {"company": "Contoso Kites", "title": "Design Manager"}},
    {"id": "t4", "title": "Update portfolio", "due": "2026-11-18", "due_in_days": 1, "job_id": None}]
busy_rounds = [
    {"round": "Panel interview", "job_id": U[0], "scheduled_at": "2026-11-17T21:30:00Z", "on": "2026-11-17", "company": "Northwind Mills", "title": "Staff Designer"},
    {"round": "Phone screen", "scheduled_at": "2026-11-19T17:00:00Z", "on": "2026-11-19", "company": "Fabrikam Harbor", "title": "Product Lead"},
    {"round": "Hiring manager chat", "scheduled_at": "2026-11-18T18:00:00Z", "on": "2026-11-18", "company": "Contoso Kites", "title": "Design Manager", "status": "cancelled"}]


def activity(seed, density):
    rnd = random.Random(seed)
    days, streak_run = [], 0
    for i in range(365):
        d = TODAY - dt.timedelta(days=364 - i)
        n = rnd.choice([0, 0, 0, 1, 1, 2, 3, 5]) if rnd.random() < density else 0
        if i >= 365 - 12:
            n = max(n, 1)
        days.append({"date": d.isoformat(), "count": n})
    return {"today": "2026-11-17", "time_zone": "America/Los_Angeles", "current_streak_days": 12, "days": days}


ok_status = {"signed_in": True}
saved = {"ok": True, "job": {"id": U[0], "company": "Tailspin Orchards", "title": "Research Lead", "stage": "To Apply"}}

put("busy-day", {"status.json": ok_status, "overview.json": overview(busy_over, busy_soon, busy_rounds), "activity.json": activity(1, 0.6),
                 "jobs-save.json": saved, "clipboard.txt": "https://example.com/careers/research-lead\n"})
put("nothing-due", {"status.json": ok_status, "overview.json": overview([], [], []), "activity.json": {"today": "2026-11-17", "time_zone": "America/Los_Angeles", "current_streak_days": 0, "days": []},
                    "jobs-save.json": saved, "clipboard.txt": "not a link, just some words"})
put("signed-out", {"status.json": {"signed_in": False}})
put("cli-missing", {}, markers=["cli-missing"])
stale = {"schema": 1, "fetched_at": "2026-11-17T09:00:00Z"}
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "helper"))
import jobhunt_omarchy as h
data = h.normalise_overview(overview(busy_over, busy_soon, busy_rounds))
stale.update({"data": data, "activity": h.normalise_activity(activity(1, 0.6), "2026-11-17")})
put("stale-offline", {"status.json": ok_status, "cache.json": stale}, markers=["offline"])
put("year-of-activity", {"status.json": ok_status, "overview.json": overview([], busy_soon[:1], []), "activity.json": activity(7, 1.0)})
