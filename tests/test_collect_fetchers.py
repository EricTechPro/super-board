"""Unit tests for super-collect's fetchers: collect_sentry.py, collect_posthog.py, collect_prs.py.

Stdlib unittest, no network: urllib.request.urlopen is replaced by a router that
answers by URL substring and records every request; `gh` is a fake runner.

    python3 tests/test_collect_fetchers.py
"""
from __future__ import annotations

import contextlib
import datetime as dt
import io
import json
import os
import sys
import tempfile
import unittest
import urllib.error
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "skills", "super-collect", "scripts"))
import collect_common as cc  # noqa: E402
import collect_posthog as ph  # noqa: E402
import collect_prs as prs  # noqa: E402
import collect_sentry as sn  # noqa: E402

UTC = dt.timezone.utc
NOW = dt.datetime(2026, 10, 2, 12, tzinfo=UTC)


class Resp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()


class Router:
    """routes: list of (url substring, payload or callable(req) or Exception)."""

    def __init__(self, routes):
        self.routes, self.calls = list(routes), []

    def __call__(self, req, timeout=None):
        self.calls.append(req)
        url = req.full_url
        for i, (needle, payload) in enumerate(self.routes):
            if needle in url:
                if isinstance(payload, list) and payload and isinstance(payload[0], Exception):
                    exc = payload.pop(0)  # one-shot error, then fall through to next match
                    if not payload:
                        self.routes.pop(i)
                    raise exc
                if callable(payload):
                    payload = payload(req)
                return Resp(json.dumps(payload).encode())
        raise AssertionError(f"unexpected URL {url}")


def http_error(code, headers=None):
    return urllib.error.HTTPError("u", code, "x", headers or {}, io.BytesIO(b"{}"))


@contextlib.contextmanager
def in_dir(files):
    old = os.getcwd()
    with tempfile.TemporaryDirectory() as d:
        for name, body in files.items():
            p = os.path.join(d, name)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w") as f:
                f.write(body)
        os.chdir(d)
        try:
            yield d
        finally:
            os.chdir(old)


CLEAN_ENV = {k: v for k, v in os.environ.items() if not k.startswith(("SENTRY_", "POSTHOG_"))}


class Common(unittest.TestCase):
    def test_since_relative_and_absolute(self):
        self.assertEqual(cc.since("30d", now=NOW), NOW - dt.timedelta(days=30))
        self.assertEqual(cc.since(None, 14, now=NOW), NOW - dt.timedelta(days=14))
        self.assertEqual(cc.since("2026-09-01", now=NOW), dt.datetime(2026, 9, 1, tzinfo=UTC))

    def test_fingerprint_hashes_free_text_stably(self):
        a = cc.fingerprint("posthog", "exception", "TypeError: x is undefined at 0x1f3a line 42")
        b = cc.fingerprint("posthog", "exception", "TypeError: x is undefined at 0x99ff line 7")
        self.assertEqual(a, b)
        self.assertRegex(a, r"^posthog\|exception\|[0-9a-f]{12}$")
        self.assertEqual(cc.fingerprint("posthog", "exception", "0193ab-issue"), "posthog|exception|0193ab-issue")

    @mock.patch.dict(os.environ, CLEAN_ENV, clear=True)
    def test_secret_walks_up_to_parent_env(self):
        with in_dir({".env": "SENTRY_AUTH_TOKEN='tok'\nOTHER=1\n", "app/x": ""}) as d:
            os.chdir(os.path.join(d, "app"))
            self.assertEqual(cc.secret("SENTRY_AUTH_TOKEN"), "tok")
            self.assertEqual(cc.secret("MISSING"), "")

    def test_active_config_follows_pointer(self):
        files = {".claude/super-board/active": "app\n",
                 ".claude/super-board/configs/app.json": json.dumps({"collect": {"window_days": 30}})}
        with in_dir(files):
            cfg, path = cc.active_config()
            self.assertEqual(cc.window_days(cfg), 30)
            self.assertTrue(path.endswith("app.json"))


SENTRY_CFG = {"collect": {"sentry": {"org": "acme", "project": "web", "host": "https://us.sentry.io/",
                                     "min_events": 5}}}


def sentry_issue(i, events, users, last="2026-10-02T10:00:00Z", **kw):
    d = {"id": str(i), "shortId": f"WEB-{i}", "title": f"Err {i}", "count": str(events), "userCount": users,
         "lastSeen": last, "firstSeen": "2026-09-20T00:00:00Z", "stats": {"24h": [[0, 3]]},
         "permalink": f"https://sentry/{i}"}
    d.update(kw)
    return d


@mock.patch.dict(os.environ, dict(CLEAN_ENV, SENTRY_AUTH_TOKEN="secret-token"), clear=True)
class Sentry(unittest.TestCase):
    def st(self):
        return sn.settings(SENTRY_CFG)

    def test_settings_from_config_and_env(self):
        st = self.st()
        self.assertEqual((st["org"], st["project"], st["base"], st["env"]), ("acme", "web", "https://us.sentry.io", "production"))

    def test_missing_token_raises(self):
        with mock.patch.dict(os.environ, CLEAN_ENV, clear=True), in_dir({}):
            with self.assertRaises(sn.SentryError):
                sn.settings(SENTRY_CFG)

    def test_list_filters_thresholds_scores_and_fingerprints(self):
        r = Router([("/projects/acme/web/", {"id": "42"}),
                    ("/organizations/acme/issues/", [sentry_issue(1, 3, 9), sentry_issue(2, 50, 2),
                                                     sentry_issue(3, 80, 30, substatus="regressed")])])
        with mock.patch.object(sn.urllib.request, "urlopen", r):
            out = sn.list_issues(self.st(), NOW - dt.timedelta(days=14), now=NOW)
        self.assertEqual([c["id"] for c in out], ["3", "2"])  # #1 under min_events, sorted by score
        self.assertEqual(out[0]["fingerprint"], "err|sentry|3")
        self.assertTrue(out[0]["stillHappening"])
        req = r.calls[-1]
        self.assertEqual(req.get_header("Authorization"), "Bearer secret-token")
        self.assertIn("project=42", req.full_url)
        self.assertIn("environment=production", req.full_url)
        self.assertIn("statsPeriod=14d", req.full_url)
        self.assertIn("query=is%3Aunresolved", req.full_url)

    def test_429_is_retried(self):
        r = Router([("/organizations/acme/issues/7/", [http_error(429, {"Retry-After": "0"})]),
                    ("/organizations/acme/issues/7/", {"id": "7", "status": "unresolved",
                                                        "lastSeen": "2026-10-01T00:00:00Z", "count": "4"})])
        with mock.patch.object(sn.urllib.request, "urlopen", r), mock.patch.object(sn.time, "sleep"):
            out = sn.check(self.st(), "7", dt.datetime(2026, 9, 25, tzinfo=UTC))
        self.assertEqual(len(r.calls), 2)
        self.assertTrue(out["seenAfter"])

    def test_check_resolved_in_release_not_seen_since(self):
        r = Router([("/releases/web%401.4.0/", {"dateReleased": "2026-09-28T00:00:00Z"}),
                    ("/organizations/acme/issues/9/", {"id": "9", "status": "resolved",
                                                        "statusDetails": {"inRelease": "web@1.4.0"},
                                                        "lastSeen": "2026-09-27T00:00:00Z", "count": "12"})])
        with mock.patch.object(sn.urllib.request, "urlopen", r):
            out = sn.check(self.st(), "9")
        self.assertEqual(out["status"], "resolved")
        self.assertEqual(out["resolvedIn"], "web@1.4.0")
        self.assertIs(out["seenAfterRelease"], False)

    def test_http_error_becomes_unavailable(self):
        r = Router([("/projects/acme/web/", [http_error(403)])])
        with mock.patch.object(sn.urllib.request, "urlopen", r), \
                mock.patch.object(sn.cc, "active_config", return_value=(SENTRY_CFG, None)), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            rc = sn.main(["ping"])
        self.assertEqual(rc, 2)
        self.assertEqual(json.loads(out.getvalue())["status"], "unavailable")
        self.assertNotIn("secret-token", out.getvalue())


PH_CFG = {"collect": {"posthog": {"host": "https://us.i.posthog.com", "project_id": 123,
                                  "failure_events": [{"event": "push_completed", "fail": "properties.status = 'failed'"}]}}}


def hog_router(answer):
    """answer(query) -> results rows. Records queries."""
    queries = []

    def handle(req):
        if "/query/" not in req.full_url:
            return {}
        body = json.loads(req.data)
        assert body["query"]["kind"] == "HogQLQuery"
        queries.append(body["query"]["query"])
        return {"results": answer(body["query"]["query"])}
    return handle, queries


@mock.patch.dict(os.environ, dict(CLEAN_ENV, POSTHOG_PERSONAL_API_KEY="phx_secret"), clear=True)
class PostHog(unittest.TestCase):
    def st(self, cfg=PH_CFG):
        return ph.settings(cfg)

    def test_settings_normalise_ingest_host(self):
        st = self.st()
        self.assertEqual(st["host"], "https://us.posthog.com")
        self.assertEqual(st["pid"], "123")

    def test_unknown_signal_rejected(self):
        with self.assertRaises(ph.PostHogError):
            ph.settings({"collect": {"posthog": {"project_id": 1, "signals": ["nope"]}}})

    def test_list_groups_thresholds_labels_and_replay(self):
        def answer(q):
            if "'$exception'" in q:
                return [["0193-issue", "TypeError: boom", 40, 12, "2026-09-20", "2026-10-01", "sess-1"]]
            if "'$dead_click'" in q:
                return [["https://app/x div.btn", "https://app/x", 30, 6, None, None, "sess-2"]]
            if "'$web_vitals'" in q:
                return [["/slow", 120, 60, 5200.0, 300.0, 0.05, "sess-3"],
                        ["/fast", 400, 200, 1200.0, 100.0, 0.01, "sess-4"]]
            if "'push_completed'" in q:
                return [[9, 3, 20, "2026-09-21", "2026-10-01", "sess-5"]]  # 3 users but 15% rate
            return []
        handle, queries = hog_router(answer)
        r = Router([("us.posthog.com", handle)])
        with mock.patch.object(ph.urllib.request, "urlopen", r):
            cands, extra = ph.list_signals(self.st(), NOW - dt.timedelta(days=14))
        by = {c["signal"]: c for c in cands}
        self.assertEqual(set(by), {"exception", "dead_click", "web_vitals", "failure"})
        self.assertEqual(by["exception"]["fingerprint"], "posthog|exception|0193-issue")
        self.assertEqual(by["exception"]["replay"], "https://us.posthog.com/project/123/replay/sess-1")
        self.assertIn("needs-triage", by["dead_click"]["labels"])
        self.assertEqual(by["web_vitals"]["key"], "/slow")
        self.assertIn("LCP 5200", by["web_vitals"]["title"])
        self.assertEqual(by["failure"]["failureRate"], 0.15)
        self.assertEqual(extra, {})
        exc_q = next(q for q in queries if "'$exception'" in q)
        self.assertIn("having users >= 5", exc_q)
        self.assertIn("issue_id", exc_q)
        self.assertIn("limit 1000", exc_q)
        self.assertNotIn("offset", " ".join(queries).lower())
        self.assertEqual(r.calls[0].get_header("Authorization"), "Bearer phx_secret")
        self.assertIn("/api/projects/123/query/", r.calls[0].full_url)

    def test_failure_below_users_and_rate_is_dropped(self):
        handle, _ = hog_router(lambda q: [[2, 2, 100, None, None, None]] if "push_completed" in q else [])
        with mock.patch.object(ph.urllib.request, "urlopen", Router([("posthog.com", handle)])):
            cands, _ = ph.list_signals(self.st(), NOW - dt.timedelta(days=14))
        self.assertEqual(cands, [])

    def test_check_needs_three_quiet_days_and_reads_issue_status(self):
        handle, queries = hog_router(lambda q: [[0, 0, None]])
        r = Router([("/error_tracking/issues/0193-issue/", {"status": "resolved"}), ("/query/", handle)])
        with mock.patch.object(ph.urllib.request, "urlopen", r):
            quiet = ph.check(self.st(), "exception", "0193-issue", NOW - dt.timedelta(days=5), now=NOW)
            fresh = ph.check(self.st(), "exception", "0193-issue", NOW - dt.timedelta(days=1), now=NOW)
        self.assertTrue(quiet["stopped"])
        self.assertFalse(fresh["stopped"])
        self.assertEqual(quiet["issueStatus"], "resolved")
        self.assertIn("/api/environments/123/error_tracking/issues/0193-issue/",
                      [c.full_url for c in r.calls if "error_tracking" in c.full_url][0])
        self.assertIn("toString(issue_id) = '0193-issue'", queries[0])

    def test_quotes_in_keys_are_escaped(self):
        self.assertEqual(ph.lit("it's \\ fine"), "'it\\'s \\\\ fine'")

    def test_ping_reports_silent_signals_with_suggestions(self):
        def answer(q):
            return [["$exception", 10], ["push_completed", 4]] if "group by event" in q else [[1]]
        handle, _ = hog_router(answer)
        with mock.patch.object(ph.urllib.request, "urlopen", Router([("posthog.com", handle)])):
            out = ph.ping(self.st(), NOW - dt.timedelta(days=14))
        silent = {s["signal"]: s["suggestion"] for s in out["silent"]}
        self.assertIn("rageclick", silent)
        self.assertIn("autocapture", silent["rageclick"])
        self.assertNotIn("exception", silent)

    def test_events_inventory_lists_names_and_silent_signals(self):
        def answer(q):
            if "group by event order by" in q:
                return [["$pageview", 900, 80, "2026-10-01"], ["receipt_uploaded", 40, 12, "2026-10-01"]]
            return [["$pageview", 900]] if "group by event" in q else [[1]]
        handle, _ = hog_router(answer)
        with mock.patch.object(ph.urllib.request, "urlopen", Router([("posthog.com", handle)])):
            out = ph.events(self.st(), NOW - dt.timedelta(days=14))
        self.assertEqual([e["event"] for e in out["events"]], ["$pageview", "receipt_uploaded"])
        self.assertIn("exception", out["silentSignals"])
        self.assertIn("failure", out["silentSignals"])

    def test_funnel_is_a_report(self):
        cfg = {"collect": {"posthog": {"project_id": 1, "funnel": ["$pageview", "signup_started"]}}}
        handle, _ = hog_router(lambda q: [[200, 50]])
        with mock.patch.object(ph.urllib.request, "urlopen", Router([("posthog.com", handle)])):
            md = ph.funnel(self.st(cfg), NOW - dt.timedelta(days=14))
        self.assertIn("| `signup_started` | 50 | 25% |", md)
        self.assertIn("files no tickets", md)


class PRs(unittest.TestCase):
    def page(self, nodes, has_next, cursor=None):
        return {"data": {"search": {"pageInfo": {"hasNextPage": has_next, "endCursor": cursor}, "nodes": nodes}}}

    def pr(self, n, comments=()):
        return {"number": n, "title": f"PR {n}", "url": f"u/{n}", "mergedAt": "2026-09-30T00:00:00Z",
                "author": {"login": "eric", "__typename": "User"},
                "comments": {"nodes": list(comments)},
                "reviews": {"nodes": [{"author": {"login": "coderabbitai", "__typename": "Bot"},
                                       "state": "COMMENTED", "body": "nit"}]},
                "reviewThreads": {"nodes": [{"path": "a.ts", "isResolved": False,
                                             "comments": {"nodes": [{"author": {"login": "eric"}, "body": "why?"}]}}]}}

    def test_paginates_and_marks_super_review_and_bots(self):
        pages = [self.page([self.pr(1, [{"author": {"login": "sb[bot]", "__typename": "Bot"},
                                         "body": "<!-- super-review:report -->\nR1 fixed"}])], True, "C1"),
                 self.page([self.pr(2), None], False)]
        calls = []

        def run(cmd, **kw):
            calls.append(cmd)
            return mock.Mock(returncode=0, stdout=json.dumps(pages[len(calls) - 1]), stderr="")
        out, truncated = prs.list_prs("acme/app", dt.datetime(2026, 9, 18, tzinfo=UTC), run=run)
        self.assertEqual([p["number"] for p in out], [1, 2])
        self.assertFalse(truncated)
        self.assertTrue(out[0]["comments"][0]["superReview"])
        self.assertTrue(out[0]["comments"][0]["author"]["bot"])
        self.assertTrue(out[0]["reviews"][0]["author"]["bot"])
        self.assertEqual(out[0]["threads"][0]["path"], "a.ts")
        self.assertIn("q=repo:acme/app is:pr is:merged merged:>=2026-09-18", calls[0])
        self.assertIn("cursor=C1", calls[1])

    def test_repo_slug_from_remote(self):
        self.assertEqual(prs.repo_slug({"repo": {"remote": "git@github.com:acme/app.git"}}), "acme/app")
        self.assertEqual(prs.repo_slug({"repo": {"remote": "https://github.com/acme/app"}}), "acme/app")

    def test_gh_failure_raises(self):
        run = lambda cmd, **kw: mock.Mock(returncode=1, stdout="", stderr="HTTP 401")
        with self.assertRaises(RuntimeError):
            prs.list_prs("acme/app", NOW, run=run)


if __name__ == "__main__":
    unittest.main(verbosity=1)
