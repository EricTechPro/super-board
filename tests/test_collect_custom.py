"""Unit tests for super-collect's `custom` source plug-in (collect_custom.py).

Covers onboard's "➕ Add another source": classify what the user typed, the read-only
ping, saving to collect.custom[], and collect → candidates that carry the
`custom|<name>|<key>` fingerprint the filer accepts. No network: urlopen is stubbed,
CLI sources run `printf`.

    python3 tests/test_collect_custom.py
"""
from __future__ import annotations

import contextlib
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
import collect_custom as cu  # noqa: E402


class Resp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()


def run(argv):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = cu.main(argv)
    return code, json.loads(buf.getvalue())


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.home = mock.patch.dict(os.environ, {"HOME": self.tmp})
        self.home.start()
        self.cwd = os.getcwd()
        os.chdir(self.tmp)
        self.cfg = os.path.join(self.tmp, "cfg.json")
        json.dump({"collect": {"sources": ["github"]}}, open(self.cfg, "w"))

    def tearDown(self):
        os.chdir(self.cwd)
        self.home.stop()


class Classify(Base):
    def test_url_is_http(self):
        r = cu.classify("https://status.example.com/api/v2/incidents.json")
        self.assertEqual((r["kind"], r["name"]), ("http", "example"))

    def test_known_app_is_mcp(self):
        self.assertEqual(cu.classify("Linear")["kind"], "mcp")
        self.assertEqual(cu.classify("linear")["target"], "linear")

    def test_known_app_cli_and_auth_env(self):
        self.assertEqual(cu.classify("vercel")["kind"], "cli")
        self.assertEqual(cu.classify("datadog")["auth_env"], "DD_API_KEY")

    def test_mcp_prefix_and_configured_server(self):
        self.assertEqual(cu.classify("mcp:my-tracker")["kind"], "mcp")
        json.dump({"mcpServers": {"bugbase": {"command": "x"}}}, open(os.path.join(self.tmp, ".mcp.json"), "w"))
        self.assertEqual(cu.classify("bugbase")["kind"], "mcp")

    def test_command_on_path_is_cli(self):
        r = cu.classify("printf hello")
        self.assertEqual((r["kind"], r["name"]), ("cli", "printf"))

    def test_builtin_and_unknown(self):
        self.assertEqual(cu.classify("sentry")["kind"], "builtin")
        code, r = run(["classify", "no such thing here"])
        self.assertEqual(code, 2)
        self.assertIn("couldn't read", r["error"])


class Ping(Base):
    def test_http_ok_counts_records(self):
        body = {"incidents": [{"id": "a1", "name": "API down"}, {"id": "a2", "name": "Slow"}]}
        with mock.patch("urllib.request.urlopen", return_value=Resp(json.dumps(body).encode())):
            code, r = run(["ping", "--kind", "http", "--target", "https://s.example.com/i.json", "--name", "status"])
        self.assertEqual((code, r["status"], r["count"]), (0, "ok", 2))
        self.assertIn("can read it (2 records)", r["message"])

    def test_http_401_says_token(self):
        err = urllib.error.HTTPError("u", 401, "no", {}, None)
        with mock.patch("urllib.request.urlopen", side_effect=err):
            code, r = run(["ping", "--kind", "http", "--target", "https://s.example.com/i.json"])
        self.assertEqual(code, 2)
        self.assertIn("needs a token", r["error"])

    def test_http_bearer_from_auth_env_and_missing_key(self):
        code, r = run(["ping", "--kind", "http", "--target", "https://x.io/a", "--auth-env", "X_TOKEN"])
        self.assertEqual(code, 2)
        self.assertIn("add X_TOKEN to .env", r["error"])
        seen = {}

        def fake(req, timeout=None):
            seen["auth"] = req.get_header("Authorization")
            return Resp(b"[]")
        with mock.patch.dict(os.environ, {"X_TOKEN": "t0k"}), mock.patch("urllib.request.urlopen", side_effect=fake):
            code, r = run(["ping", "--kind", "http", "--target", "https://x.io/a", "--auth-env", "X_TOKEN"])
        self.assertEqual((code, seen["auth"]), (0, "Bearer t0k"))
        self.assertNotIn("t0k", json.dumps(r))

    def test_cli_ok(self):
        code, r = run(["ping", "--kind", "cli", "--target", 'printf \'{"items":[{"id":1,"title":"boom"}]}\'', "--name", "logs"])
        self.assertEqual((code, r["status"], r["count"]), (0, "ok", 1))
        self.assertEqual(r["sample"][0]["title"], "boom")

    def test_cli_mutating_or_chained_refused(self):
        for cmd in ("vercel deploy --prod", "gh issue create -t x", "printf a; rm -rf x"):
            code, r = run(["ping", "--kind", "cli", "--target", cmd])
            self.assertEqual((code, r["status"]), (2, "refused"), cmd)

    def test_mcp_hands_the_read_to_the_agent(self):
        code, r = run(["ping", "--kind", "mcp", "--target", "linear", "--name", "linear"])
        self.assertEqual((code, r["status"], r["server"]), (0, "agent", "linear"))
        self.assertIn("normalize --name linear", r["how"])


class AddAndCollect(Base):
    def test_add_saves_entry_and_source_once(self):
        for _ in range(2):
            code, _r = run(["add", "--name", "logs", "--kind", "cli", "--target", "printf x", "--config", self.cfg])
            self.assertEqual(code, 0)
        cfg = json.load(open(self.cfg))
        self.assertEqual(cfg["collect"]["sources"], ["github", "logs"])
        self.assertEqual(cfg["collect"]["custom"], [{"name": "logs", "kind": "cli", "target": "printf x"}])

    def test_list_turns_output_into_fingerprinted_candidates(self):
        json.dump({"collect": {"sources": ["status"], "custom": [
            {"name": "status", "kind": "cli",
             "target": 'printf \'{"data":{"rows":[{"ref":"E1","msg":"API down","n":7},{"ref":"E1","msg":"API down","n":3},{"ref":"E2","msg":"Slow"}]}}\'',
             "map": {"items": "data.rows", "id": "ref", "title": "msg", "count": "n"}}]}}, open(self.cfg, "w"))
        code, r = run(["list", "--config", self.cfg])
        self.assertEqual(code, 0)
        row = r["sources"][0]
        self.assertEqual(row["status"], "read")
        by = {c["key"]: c for c in row["candidates"]}
        self.assertEqual(set(by), {"E1", "E2"})
        self.assertEqual(by["E1"]["count"], 10)
        self.assertEqual(by["E1"]["fingerprint"], "custom|status|E1")
        self.assertEqual(by["E1"]["title"], "API down")

    def test_plain_lines_group_by_normalised_text(self):
        cands, _ = cu.normalize("logs", "err 500 req 1234\nerr 500 req 9876\nother\n")
        self.assertEqual(len(cands), 2)
        self.assertEqual(sorted(c["count"] for c in cands), [1, 2])
        self.assertTrue(all(c["fingerprint"].startswith("custom|logs|") for c in cands))

    def test_normalize_mcp_output_from_stdin(self):
        json.dump({"collect": {"custom": [{"name": "linear", "kind": "mcp", "target": "linear",
                                           "map": {"items": "issues"}}]}}, open(self.cfg, "w"))
        raw = json.dumps({"issues": [{"identifier": "ENG-42", "title": "Export hangs", "url": "https://l/ENG-42"}]})
        with mock.patch("sys.stdin", io.StringIO(raw)):
            code, r = run(["normalize", "--name", "linear", "--config", self.cfg])
        self.assertEqual(code, 0)
        c = r["candidates"][0]
        self.assertEqual((c["fingerprint"], c["url"]), ("custom|linear|ENG-42", "https://l/ENG-42"))

    def test_unreachable_source_is_unavailable_not_empty(self):
        json.dump({"collect": {"custom": [{"name": "gone", "kind": "cli", "target": "no-such-binary-xyz --json"}]}},
                  open(self.cfg, "w"))
        code, r = run(["list", "--config", self.cfg])
        self.assertEqual((code, r["sources"][0]["status"]), (2, "unavailable"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
