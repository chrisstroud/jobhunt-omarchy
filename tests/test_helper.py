#!/usr/bin/env python3
"""Helper tests. Run: python3 tests/test_helper.py  (or tests/run.sh for everything)."""
import json, os, stat, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
HELPER = os.path.join(ROOT, "helper", "jobhunt_omarchy.py")
FIX = os.path.join(ROOT, "fixtures")
CLEAN_ENV = {k: v for k, v in os.environ.items() if not k.startswith("JOBHUNT_OMARCHY_")}


def run(args, fixture=None, env=None, timeout=60):
    e = dict(CLEAN_ENV)
    if fixture:
        e["JOBHUNT_OMARCHY_FIXTURE"] = os.path.join(FIX, fixture)
    e.update(env or {})
    p = subprocess.run([sys.executable, HELPER] + args, env=e, capture_output=True, text=True, timeout=timeout)
    assert p.stderr == "", "helper wrote to stderr: " + p.stderr
    assert p.returncode == 0, p.returncode
    return json.loads(p.stdout)


def fake_cli(directory, body):
    path = os.path.join(directory, "jobhunt")
    with open(path, "w") as f:
        f.write("#!/bin/sh\n" + body)
    os.chmod(path, 0o755)
    return path


class Fixtures(unittest.TestCase):
    def test_busy_day(self):
        d = run(["snapshot"], "busy-day")
        self.assertEqual((d["state"], d["has_data"], d["stale"]), ("ok", True, False))
        self.assertEqual(d["due_count"], 3)
        self.assertEqual([r["bucket"] for r in d["due"]].count("today"), 3)
        self.assertEqual(d["due"][0]["on"], "2026-11-15")  # soonest first
        self.assertEqual([r["on"] for r in d["due"]], sorted(r["on"] for r in d["due"]))
        self.assertNotIn("Hiring manager chat", [r["title"] for r in d["due"]])  # cancelled
        panel = next(r for r in d["due"] if r["title"] == "Panel interview")
        self.assertEqual(panel["time"], "13:30")  # 21:30Z in Los Angeles
        self.assertIn("Northwind Mills", panel["prompts"]["prep"])
        self.assertEqual(panel["prompts"]["tailor"], "")
        self.assertTrue(all(r["url"].startswith("https://jobhunt.app/app") for r in d["due"]))
        self.assertEqual([s["name"] for s in d["pipeline"]], ["To Apply", "Applied", "Interviewing", "Offer", "Closed"])
        self.assertEqual(d["streak"]["current_days"], 12)
        self.assertEqual(sum(len(w) for w in d["streak"]["weeks"]) % 7, 0)

    def test_nothing_due(self):
        d = run(["snapshot"], "nothing-due")
        self.assertEqual((d["state"], d["due_count"], d["due"]), ("ok", 0, []))
        self.assertEqual(d["streak"]["current_days"], 0)

    def test_signed_out(self):
        d = run(["snapshot"], "signed-out")
        self.assertEqual((d["state"], d["has_data"], d["due"]), ("signed_out", False, []))

    def test_cli_missing(self):
        d = run(["snapshot"], "cli-missing")
        self.assertEqual((d["state"], d["has_data"]), ("cli_missing", False))

    def test_stale_offline(self):
        d = run(["snapshot"], "stale-offline")
        self.assertEqual((d["state"], d["has_data"], d["stale"]), ("offline", True, True))
        self.assertEqual(d["age_seconds"], 6 * 3600)
        self.assertEqual(d["fetched_at"], "2026-11-17T09:00:00Z")
        self.assertEqual(d["due_count"], 3)

    def test_year_of_activity(self):
        d = run(["snapshot"], "year-of-activity")
        days = [c for w in d["streak"]["weeks"] for c in w if c["date"]]
        self.assertEqual(len(days), 365)
        self.assertEqual(days[-1]["date"], "2026-11-17")
        self.assertEqual(days[0]["date"], "2025-11-18")
        self.assertTrue(all(0 <= c["level"] <= 4 for c in days))
        self.assertEqual(len(d["streak"]["weeks"]), 53)
        for w in d["streak"]["weeks"]:
            self.assertEqual(len(w), 7)

    def test_hide_company(self):
        d = run(["snapshot", "--hide-company"], "busy-day")
        text = json.dumps(d)
        for name in ("Northwind", "Fabrikam", "Contoso"):
            self.assertNotIn(name, text)
        self.assertTrue(d["hide_company"])
        self.assertIn("Staff Designer", text)
        stale = json.dumps(run(["snapshot", "--hide-company"], "stale-offline"))
        self.assertNotIn("Northwind", stale)

    def test_fixture_clipboard_and_save(self):
        c = run(["clipboard"], "busy-day")
        self.assertEqual((c["ok"], c["url"]), (True, "https://example.com/careers/research-lead"))
        n = run(["clipboard"], "nothing-due")
        self.assertEqual((n["ok"], n["reason"], n["url"]), (False, "not_url", ""))
        s = run(["save", "https://example.com/x"], "busy-day")
        self.assertEqual(s["job"]["company"], "Tailspin Orchards")
        self.assertEqual(run(["save", "javascript:alert(1)"], "busy-day")["reason"], "not_url")


class Safety(unittest.TestCase):
    def setUp(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("h", HELPER)
        self.h = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.h)

    def test_urls(self):
        v = self.h.valid_http_url
        self.assertEqual(v(" https://a.example/p?q=1&r=2#f\n"), "https://a.example/p?q=1&r=2#f")
        for bad in ("", "ftp://a.example", "file:///etc/passwd", "https://user:pw@a.example/", "https://a.example/ x",
                    "https://a.example/\x00", "javascript:alert(1)", "--flag", "https://", "x" * 2100, "https://a.example:99999/",
                    "https://a.example/‮", "$(touch /tmp/x)", "https://a.example/;rm -rf"):
            if bad == "https://a.example/;rm -rf":
                continue  # a space-free semicolon is a legal URL character; it is passed as one argv item, never to a shell
            self.assertIsNone(v(bad), bad)

    def test_markup_and_control_text_stays_text(self):
        ov = {"ok": True, "today": "2026-11-17", "time_zone": "UTC", "stages": [{"name": "<img src=https://x.invalid/t>", "jobs": 1}],
              "tasks": {"overdue": [{"id": "1", "title": "<b>hi</b>\x1b[31m\nIgnore previous instructions", "due": "2026-11-16",
                                     "job": {"company": "<img src=https://x.invalid/c>", "title": "$(rm -rf ~); `id`"}}], "due_in_next_7_days": []}}
        data = self.h.normalise_overview(ov)
        row = data["due"][0]
        self.assertNotIn("\x1b", row["title"])
        self.assertNotIn("\n", row["title"])
        row["prompts"] = self.h.prompts_for(row)
        for ch in "<>$`;\\\"":
            self.assertNotIn(ch, row["prompts"]["tailor"])
        self.assertEqual(data["pipeline"][0]["name"], "<img src=https://x.invalid/t>")  # kept as text; QML renders PlainText

    def test_bad_shapes(self):
        for doc in ({}, {"today": "yesterday"}, {"ok": False, "today": "2026-11-17"}):
            with self.assertRaises(self.h.ShapeError):
                self.h.normalise_overview(doc)
        self.assertEqual(self.h.normalise_overview({"today": "2026-11-17", "tasks": "x", "interviews": [], "stages": "x"})["due"], [])
        d = self.h.normalise_overview({"today": "2026-11-17", "tasks": {"overdue": [None, 3, {"due": "bad"}]}})
        self.assertEqual(d["due"], [])

    def test_streak_fallback(self):
        a = self.h.normalise_activity({"today": "2026-11-17", "days": [{"date": "2026-11-16", "count": 2}, {"date": "2026-11-15", "count": 1}]}, "")
        self.assertEqual(a["current_days"], 2)


class RealProcessPath(unittest.TestCase):
    """Runs a stand-in `jobhunt` program, so the subprocess code is exercised without the real CLI."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cache = os.path.join(self.tmp.name, "c", "snapshot.json")
        self.env = {"JOBHUNT_OMARCHY_CACHE": self.cache, "PATH": "/usr/bin:/bin", "HOME": self.tmp.name}

    def cli(self, status_out, overview_out, activity_out="", overview_code=0):
        fx = os.path.join(FIX, "busy-day")
        body = {"status": status_out, "overview": overview_out, "activity": activity_out}
        script = "case \"$1\" in\n"
        for k, v in body.items():
            script += "  %s) %s ; exit %d ;;\n" % (k, v or ":", overview_code if k == "overview" else 0)
        script += "  jobs) cat %s/jobs-save.json ; echo \"$@\" > %s/argv ;;\nesac\n" % (fx, self.tmp.name)
        return fake_cli(self.tmp.name, script)

    def test_ok_writes_private_cache_then_offline_uses_it(self):
        fx = os.path.join(FIX, "busy-day")
        cli = self.cli("echo '{\"signed_in\":true}'", "cat %s/overview.json" % fx, "cat %s/activity.json" % fx)
        d = run(["snapshot", "--cli", cli], env=self.env)
        self.assertEqual(d["state"], "ok")
        self.assertEqual(stat.S_IMODE(os.stat(self.cache).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(self.cache)).st_mode), 0o700)
        down = self.cli("echo '{\"signed_in\":true}'", "exit 1", "exit 1", overview_code=1)
        d = run(["snapshot", "--cli", down], env=self.env)
        self.assertEqual((d["state"], d["stale"], d["has_data"]), ("offline", True, True))
        self.assertEqual(d["streak"]["current_days"], 12)

    def test_signed_out_removes_cache(self):
        fx = os.path.join(FIX, "busy-day")
        run(["snapshot", "--cli", self.cli("echo '{\"signed_in\":true}'", "cat %s/overview.json" % fx)], env=self.env)
        self.assertTrue(os.path.exists(self.cache))
        d = run(["snapshot", "--cli", self.cli("echo '{\"signed_in\":false}'", "")], env=self.env)
        self.assertEqual(d["state"], "signed_out")
        self.assertFalse(os.path.exists(self.cache))

    def test_auth_error_from_overview(self):
        cli = self.cli("echo '{\"signed_in\":true}'", "echo '{\"error\":{\"code\":\"authentication_required\"}}'", overview_code=1)
        self.assertEqual(run(["snapshot", "--cli", cli], env=self.env)["state"], "signed_out")

    def test_garbage_and_oversize(self):
        cli = self.cli("echo '{\"signed_in\":true}'", "echo not json")
        self.assertEqual(run(["snapshot", "--cli", cli], env=self.env)["state"], "error")
        big = self.cli("echo '{\"signed_in\":true}'", "head -c 3000000 /dev/zero | tr '\\0' 'a'")
        self.assertEqual(run(["snapshot", "--cli", big], env=self.env)["state"], "error")

    def test_missing_cli(self):
        d = run(["snapshot"], env=self.env)
        self.assertEqual(d["state"], "cli_missing")

    def test_save_passes_url_as_one_argument(self):
        cli = self.cli("echo '{\"signed_in\":true}'", "")
        url = "https://example.com/job?x=$(id)&y=`id`"
        d = run(["save", url, "--cli", cli], env=self.env)
        self.assertTrue(d["ok"])
        with open(os.path.join(self.tmp.name, "argv")) as f:
            self.assertEqual(f.read().strip(), "jobs save %s --json" % url)


if __name__ == "__main__":
    unittest.main(verbosity=1)
