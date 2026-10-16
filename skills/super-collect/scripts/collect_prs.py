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


# ── gitea (tea api) ────────────────────────────────────────────────────────────
# Degradations vs the GraphQL search, documented in references/gitea.md:
# no reviewThreads (empty list), no merged_at (closed_at/updated_at is the
# merge-time approximation), author "bot" is a login heuristic, and the window
# filter rides pulls?state=closed&sort=recentupdate.

def forge_of(cfg):
    return (os.environ.get("SB_FORGE") or (cfg or {}).get("forge") or "github").strip().lower()


def tea_cmd():
    import shlex
    cmd = shlex.split(os.environ.get("SB_GITEA_TEA", "tea"))
    login = os.environ.get("SB_FORGE_LOGIN")
    if login:
        cmd += ["--login", login]
    return cmd


def tea_get(endpoint, run=subprocess.run):
    r = run(tea_cmd() + ["api", "-X", "GET", endpoint], capture_output=True,
            text=True, encoding="utf-8")
    if r.returncode != 0:
        raise RuntimeError(f"tea api GET {endpoint.split('?')[0]} failed: {(r.stderr or r.stdout).strip()[:300]}")
    return json.loads(r.stdout.strip() or "null")


def repo_slug(cfg, override=None, forge="github"):
    if override:
        return override
    remote = ((cfg or {}).get("repo") or {}).get("remote") or ""
    if forge == "github":
        m = re.search(r"github\.com[:/]([^/]+/[^/.]+)", remote)
        return m.group(1) if m else None
    m = (re.match(r'^(?:https?|ssh|git)://(?:[^@/]+@)?[^/]+/(.+?)(?:\.git)?/?$', remote)
         or re.match(r'^(?:[^@/\s]+@)?[^/:\s]+:(.+?)(?:\.git)?/?$', remote))
    if not m:
        return None
    parts = [p for p in m.group(1).strip("/").split("/") if p]
    return f"{parts[-2]}/{parts[-1]}" if len(parts) >= 2 else None


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


def shape_gitea(pr, repo, run):
    n = pr["number"]
    comments = []
    for page in range(1, 3):   # cap: the newest 100 comments, like the query's first:100
        batch = tea_get(f"repos/{repo}/issues/{n}/comments?page={page}&limit=50", run) or []
        comments += [note({"author": {"login": (c.get("user") or {}).get("login")},
                           "body": c.get("body")}) for c in batch if isinstance(c, dict) and c.get("body")]
        if len(batch) < 50:
            break
    reviews = []
    try:
        rvs = tea_get(f"repos/{repo}/pulls/{n}/reviews", run) or []
    except RuntimeError:
        rvs = []   # an unreadable review list must not lose the PR's comments
    for rv in rvs:
        if isinstance(rv, dict) and rv.get("body"):
            reviews.append(note({"author": {"login": (rv.get("user") or {}).get("login")},
                                 "body": rv.get("body")}, {"state": rv.get("state")}))
    return {"number": n, "title": pr.get("title", ""), "url": pr.get("html_url", ""),
            "mergedAt": pr.get("closed_at") or pr.get("updated_at"),
            "author": who({"login": (pr.get("user") or {}).get("login")}),
            "comments": comments, "reviews": reviews, "threads": []}


def list_prs_gitea(repo, since, max_prs=200, run=subprocess.run):
    cutoff = since.date().isoformat()
    prs = []
    for page in range(1, max_prs // 50 + 3):
        batch = tea_get(f"repos/{repo}/pulls?state=closed&sort=recentupdate&page={page}&limit=50", run)
        if not isinstance(batch, list) or not batch:
            break
        stop = False
        for p in batch:
            if not isinstance(p, dict) or not p.get("merged"):
                continue
            when = (p.get("closed_at") or p.get("updated_at") or "")[:10]
            if when and when < cutoff:
                stop = True   # recentupdate is newest-first: the window ended
                break
            prs.append(shape_gitea(p, repo, run))
            if len(prs) >= max_prs:
                return prs, True
        if stop or len(batch) < 50:
            break
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
    forge = forge_of(cfg)
    repo = repo_slug(cfg, a.repo, forge)
    if not repo:
        print(json.dumps({"source": "prs", "status": "unavailable", "error": "no repo.remote in config; pass --repo"}))
        return 2
    since = cc.since(a.since, cc.window_days(cfg))
    max_prs = a.max or int(cc.collect_block(cfg, "prs").get("max_prs", 200))
    try:
        if forge == "gitea":
            prs, truncated = list_prs_gitea(repo, since, max_prs)
        else:
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
