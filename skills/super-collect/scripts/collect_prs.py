#!/usr/bin/env python3
"""super-collect source `prs`: merged PRs in the window with every comment, review and thread.

One GraphQL search through `gh api graphql`, paginated on the search cursor:
    is:pr is:merged merged:>=DATE repo:OWNER/REPO
Each PR comes back with its conversation comments, reviews and review threads, the
author kind (User / Bot) on each, and `superReview: true` on super-review reports
(marker `<!-- super-review:report -->`). Read-only; the agent reads the JSON for
recurring problems, not this script.

    collect_prs.py list [--since 14d|YYYY-MM-DD] [--repo owner/name] [--max 200] [--config cfg.json]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import collect_common as cc  # noqa: E402

MARKER = "<!-- super-review:report -->"
BODY_MAX = 4000

QUERY = """
query($q: String!, $cursor: String) {
  search(query: $q, type: ISSUE, first: 25, after: $cursor) {
    pageInfo { hasNextPage endCursor }
    nodes { ... on PullRequest {
      number title url mergedAt author { login __typename }
      comments(first: 100) { nodes { author { login __typename } body createdAt } }
      reviews(first: 50) { nodes { author { login __typename } state body submittedAt } }
      reviewThreads(first: 50) { nodes { path isResolved
        comments(first: 20) { nodes { author { login __typename } body } } } }
    } }
  }
}
"""


def gh_graphql(query, variables, run=subprocess.run):
    cmd = ["gh", "api", "graphql", "-f", f"query={query}"]
    for k, v in variables.items():
        if v is not None:
            cmd += ["-F", f"{k}={v}"]
    r = run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"gh api graphql failed: {r.stderr.strip()[:300]}")
    return json.loads(r.stdout)


def repo_slug(cfg, override=None):
    if override:
        return override
    remote = ((cfg or {}).get("repo") or {}).get("remote") or ""
    m = re.search(r"github\.com[:/]([^/]+/[^/.]+)", remote)
    return m.group(1) if m else None


def who(a):
    a = a or {}
    return {"login": a.get("login"), "bot": a.get("__typename") == "Bot" or str(a.get("login", "")).endswith("[bot]")}


def note(n, extra=None):
    body = n.get("body") or ""
    out = {"author": who(n.get("author")), "body": body[:BODY_MAX], "superReview": MARKER in body}
    out.update(extra or {})
    return out


def shape(pr):
    return {
        "number": pr["number"], "title": pr["title"], "url": pr["url"], "mergedAt": pr["mergedAt"],
        "author": who(pr.get("author")),
        "comments": [note(c) for c in pr["comments"]["nodes"] if c.get("body")],
        "reviews": [note(r, {"state": r.get("state")}) for r in pr["reviews"]["nodes"] if r.get("body")],
        "threads": [{"path": t.get("path"), "resolved": t.get("isResolved"),
                     "comments": [note(c) for c in t["comments"]["nodes"]]} for t in pr["reviewThreads"]["nodes"]],
    }


def list_prs(repo, since, max_prs=200, run=subprocess.run):
    q = f"repo:{repo} is:pr is:merged merged:>={since.date().isoformat()}"
    prs, cursor = [], None
    while len(prs) < max_prs:
        data = gh_graphql(QUERY, {"q": q, "cursor": cursor}, run)["data"]["search"]
        prs += [shape(n) for n in data["nodes"] if n]
        if not data["pageInfo"]["hasNextPage"]:
            break
        cursor = data["pageInfo"]["endCursor"]
    return prs[:max_prs], len(prs) >= max_prs


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--config")
    sub = p.add_subparsers(dest="cmd", required=True)
    lp = sub.add_parser("list")
    lp.add_argument("--since")
    lp.add_argument("--repo")
    lp.add_argument("--max", type=int)
    a = p.parse_args(argv)
    cfg, _ = cc.active_config(a.config)
    repo = repo_slug(cfg, a.repo)
    if not repo:
        print(json.dumps({"source": "prs", "status": "unavailable", "error": "no repo.remote in config; pass --repo"}))
        return 2
    since = cc.since(a.since, cc.window_days(cfg))
    max_prs = a.max or int(cc.collect_block(cfg, "prs").get("max_prs", 200))
    try:
        prs, truncated = list_prs(repo, since, max_prs)
    except RuntimeError as e:
        print(json.dumps({"source": "prs", "status": "unavailable", "error": str(e)}))
        return 2
    print(json.dumps({"source": "prs", "repo": repo, "since": since.isoformat(), "truncated": truncated,
                      "superReviewReports": sum(c["superReview"] for pr in prs for c in pr["comments"]),
                      "prs": prs}, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
