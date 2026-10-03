#!/usr/bin/env python3
"""cleanup-wt -- remove worktrees and branches whose work is already on a base branch.

A hook, not a user skill: installed at .claude/hooks/cleanup-wt.py, run by
super-board-merge-gate.sh after each merge (--post-merge) and by the default SessionStart
hook (--auto). A manual dry run (no flags) still works for a one-off look.

Usage (from the repo root or any of its worktrees):
  cleanup-wt.py                 dry run: print the plan, write the recovery TSV
  cleanup-wt.py --apply         act on the plan
    --base <name>     a base branch; repeatable. Default: detected (see below)
    --force           also remove locked, fresh, open-PR and unmerged *worktrees*.
                      Their branches are always kept: unmerged work is never deleted.
    --local-only      skip remote branches       --remote-only   skip worktrees and local branches
    --no-fetch        use refs as they are       --tsv <file>    where the recovery TSV goes
    --post-merge      merge-gate mode: --apply --local-only, never wip-commit, never force,
                      silent unless it acted
    --auto            SessionStart mode: --post-merge, but only when a base tip moved
                      since the last --auto run (the first run only records the tips)

Bases, when no --base is given: the remote default branch (origin/HEAD), else
init.defaultBranch, else main/master -- plus staging, develop and dev when they exist.
CLEANUP_WT_BASES="a,b" overrides detection like repeated --base.

A branch is merged when its tip is an ancestor of a base, every patch is already in a
base (git cherry), one commit equal to the whole branch is in a base (squash probe), or
gh reports a merged PR at that tip. Bases, master/main and the branch checked out in the
main checkout are never touched, nor is the worktree this runs in.

Every run writes <git-common-dir>/cleanup-wt/<timestamp>.tsv before acting:
when, kind, name, sha, path, action, reason. Restore with
  git branch <name> <sha>   |   git push origin <sha>:refs/heads/<name>

Adapted from BookKeepingApp's cleanup-wt (Eric Tech), generalised for any repo.
"""
import datetime
import json
import os
import subprocess
import sys
import time

KEEP, REMOVE, REVIEW = "KEEP", "REMOVE", "REVIEW"
ALLOWED_DIR = os.path.join(".claude", "worktrees")
FRESH_SECS = 24 * 3600
ALWAYS_PROTECTED = {"main", "master", "HEAD"}
EXTRA_BASES = ["staging", "develop", "dev"]

# Drop GIT_DIR and friends (inherited from a git hook they would redirect every
# `git -C`), never prompt, and give the squash probe's commit-tree an identity.
GIT_ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
GIT_ENV.update(
    GIT_TERMINAL_PROMPT="0",
    GIT_OPTIONAL_LOCKS="0",
    GIT_AUTHOR_NAME="cleanup-wt",
    GIT_AUTHOR_EMAIL="cleanup-wt@localhost",
    GIT_COMMITTER_NAME="cleanup-wt",
    GIT_COMMITTER_EMAIL="cleanup-wt@localhost",
)


def git(cwd, *args, timeout=60):
    try:
        r = subprocess.run(["git", "-C", cwd] + list(args), capture_output=True, text=True,
                           env=GIT_ENV, timeout=timeout)
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except (subprocess.TimeoutExpired, OSError) as e:
        return 1, "", str(e)


def git_out(cwd, *args):
    code, out, _ = git(cwd, *args)
    return out if code == 0 else None


def real(p):
    return os.path.realpath(p) if os.path.exists(p) else p


# ---- facts ------------------------------------------------------------------

def context(cwd):
    top = git_out(cwd, "rev-parse", "--show-toplevel")
    if not top:
        return None
    common = git_out(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir")
    wts = list_worktrees(top)
    root = real(wts[0]["path"]) if wts else real(top)
    return {"cwd": top, "top": real(top), "root": root, "common": common}


def list_worktrees(cwd):
    out = git_out(cwd, "worktree", "list", "--porcelain") or ""
    wts = []
    for block in out.split("\n\n"):
        wt = {"path": "", "head": "", "branch": None, "locked": False, "prunable": False, "bare": False}
        for line in block.splitlines():
            key, _, val = line.partition(" ")
            if key == "worktree":
                wt["path"] = val
            elif key == "HEAD":
                wt["head"] = val
            elif key == "branch":
                wt["branch"] = val[len("refs/heads/"):] if val.startswith("refs/heads/") else val
            elif key in ("locked", "prunable", "bare"):
                wt[key] = True
        if wt["path"]:
            wts.append(wt)
    return wts


def ref_exists(cwd, ref):
    return git_out(cwd, "rev-parse", "-q", "--verify", ref) is not None


def base_names(cwd, given):
    """The base branch names: given ones, else the detected default plus common integration branches."""
    if not given and os.environ.get("CLEANUP_WT_BASES"):
        given = [b.strip() for b in os.environ["CLEANUP_WT_BASES"].split(",") if b.strip()]
    if given:
        return list(dict.fromkeys(given))
    names = []
    head = git_out(cwd, "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD")
    if head and head.startswith("origin/"):
        names.append(head[len("origin/"):])
    else:
        init = git_out(cwd, "config", "--get", "init.defaultBranch")
        for n in ([init] if init else []) + ["main", "master"]:
            if ref_exists(cwd, "refs/remotes/origin/" + n) or ref_exists(cwd, "refs/heads/" + n):
                names.append(n)
                break
    for n in EXTRA_BASES:
        if ref_exists(cwd, "refs/remotes/origin/" + n) or ref_exists(cwd, "refs/heads/" + n):
            names.append(n)
    return list(dict.fromkeys(names))


def base_refs(cwd, names):
    """Existing base refs, origin first, deduplicated by SHA."""
    seen, found = set(), []
    for n in names:
        for ref in ("refs/remotes/origin/" + n, "refs/heads/" + n):
            sha = git_out(cwd, "rev-parse", "-q", "--verify", ref)
            if sha and sha not in seen:
                seen.add(sha)
                found.append({"ref": ref, "name": ref.split("/", 2)[2], "sha": sha})
    return found


def merged_state(cwd, tip, bases, merged_pr_oids=()):
    """How tip reached a base, cheapest check first; None when it did not."""
    for b in bases:
        if git(cwd, "merge-base", "--is-ancestor", tip, b["sha"])[0] == 0:
            return "ancestor of " + b["name"]
    for b in bases:
        lines = [l for l in (git_out(cwd, "cherry", b["sha"], tip) or "").splitlines() if l]
        if lines and all(l.startswith("-") for l in lines):
            return "every patch already in " + b["name"]
    for b in bases:
        mb = git_out(cwd, "merge-base", b["sha"], tip)
        if not mb:
            continue
        probe = git_out(cwd, "commit-tree", tip + "^{tree}", "-p", mb, "-m", "cleanup-wt squash probe")
        if probe and (git_out(cwd, "cherry", b["sha"], probe) or "").startswith("-"):
            return "squash-merged into " + b["name"]
    for oid in merged_pr_oids:
        if oid == tip or git(cwd, "merge-base", "--is-ancestor", tip, oid)[0] == 0:
            return "PR merged on GitHub"
    return None


def pull_requests(cwd):
    """{open: {branch: number}, merged: {branch: [oid]}}, or None when gh is unavailable."""
    exe = os.environ.get("CLEANUP_WT_GH", "gh")
    env = dict(os.environ, GH_PROMPT_DISABLED="1", GH_NO_UPDATE_NOTIFIER="1", GH_PAGER="cat")

    def gh(*args):
        try:
            r = subprocess.run([exe] + list(args), cwd=cwd, capture_output=True, text=True, env=env, timeout=15)
            return json.loads(r.stdout or "[]") if r.returncode == 0 else None
        except (OSError, ValueError, subprocess.TimeoutExpired):
            return None

    opened = gh("pr", "list", "--state", "open", "--limit", "200", "--json", "number,headRefName,baseRefName")
    if not isinstance(opened, list):
        return None
    merged = gh("pr", "list", "--state", "merged", "--limit", "300", "--json", "headRefName,headRefOid") or []
    open_by = {}
    for pr in opened:  # in use while any open PR names it, as head or as base
        open_by.setdefault(pr.get("headRefName"), pr.get("number"))
        open_by.setdefault(pr.get("baseRefName"), pr.get("number"))
    merged_by = {}
    for pr in merged if isinstance(merged, list) else []:
        merged_by.setdefault(pr.get("headRefName"), []).append(pr.get("headRefOid"))
    return {"open": open_by, "merged": merged_by}


def refs(cwd, prefix):
    out = git_out(cwd, "for-each-ref", prefix, "--format=%(refname:short)\t%(objectname)\t%(committerdate:unix)") or ""
    rows = []
    for line in out.splitlines():
        name, sha, ts = (line.split("\t") + ["", "", ""])[:3]
        rows.append({"name": name, "sha": sha, "ts": int(ts or 0)})
    return rows


def is_today(ts):
    return datetime.date.fromtimestamp(ts) == datetime.date.today()


def worktree_facts(ctx, wt):
    path = real(wt["path"])
    status = git_out(wt["path"], "status", "--porcelain")
    fresh = False
    gd = git_out(wt["path"], "rev-parse", "--path-format=absolute", "--git-dir")
    if gd:
        stamps = [os.stat(os.path.join(gd, f)).st_mtime for f in ("commondir", "gitdir")
                  if os.path.exists(os.path.join(gd, f))]
        head_ts = int(git_out(ctx["cwd"], "log", "-1", "--format=%ct", wt["head"]) or 0)
        if stamps:
            created = max(stamps)
            fresh = time.time() - created < FRESH_SECS and head_ts <= created
    return {
        "path": wt["path"],
        "current": path == ctx["top"],
        "locked": wt["locked"],
        "dirty": True if status is None else bool(status),
        "fresh": fresh,
        "stray": not path.startswith(os.path.join(ctx["root"], ALLOWED_DIR) + os.sep),
    }


# ---- policy (pure) ----------------------------------------------------------

def keep(reason, bucket=KEEP):
    return {"bucket": bucket, "reason": reason, "remove_worktree": False, "wip": False, "delete_branch": False}


def classify_local(f, protected, force=False, auto=False):
    """First match wins. A branch is deleted only when merged and clean: unmerged work always keeps a ref."""
    wt = f.get("worktree")
    if f["branch"] and f["branch"] in protected:
        return keep("protected branch " + f["branch"])
    if wt and wt["current"]:
        return keep("the worktree this command runs in")
    if wt and wt["locked"] and not force:
        return keep("locked worktree (a live agent)")
    if f.get("open_pr") is not None and not force:
        return keep("open PR #%s" % f["open_pr"])
    if wt and wt["fresh"] and not force:
        return keep("worktree added <24h ago, no commits yet")
    dirty = bool(wt and wt["dirty"])
    if dirty and auto:
        return keep("uncommitted changes (hook mode never wip-commits)")
    if f.get("merged"):
        if dirty:  # the wip commit is new work, so the branch stops being merged: keep it
            return {"bucket": REMOVE, "reason": "merged: %s; dirty -> wip-commit, keep branch" % f["merged"],
                    "remove_worktree": bool(wt), "wip": True, "delete_branch": False}
        return {"bucket": REMOVE, "reason": "merged: " + f["merged"], "remove_worktree": bool(wt),
                "wip": False, "delete_branch": bool(f["branch"])}
    if wt and (wt["stray"] or force):
        why = "outside .claude/worktrees/" if wt["stray"] else "unmerged, --force"
        save = dirty or not f["branch"]  # a detached HEAD gets a branch so its commits stay reachable
        return {"bucket": REMOVE, "reason": "%s -- remove folder, keep branch%s" % (why, " (wip-commit first)" if dirty else ""),
                "remove_worktree": True, "wip": save, "delete_branch": False}
    if f.get("today"):
        return keep("unmerged, committed today")
    return keep("unmerged -- review it", REVIEW)


def classify_remote(f, protected):
    if f["branch"] in protected:
        return keep("protected branch " + f["branch"])
    if f.get("open_pr") is not None:
        return keep("open PR #%s" % f["open_pr"])
    if not f.get("gh"):
        return keep("gh unavailable -- cannot rule out an open PR")
    if f.get("merged"):
        return {"bucket": REMOVE, "reason": "merged: " + f["merged"], "delete_branch": True}
    if f.get("today"):
        return keep("unmerged, committed today")
    return keep("unmerged -- review it", REVIEW)


# ---- plan and act -----------------------------------------------------------

def plan(ctx, args):
    names = base_names(ctx["cwd"], args["bases"])
    bases = base_refs(ctx["cwd"], names)
    if not bases:
        raise RuntimeError("no base branch found -- pass --base <name> or fetch origin first")
    wts = [w for w in list_worktrees(ctx["cwd"]) if not w["bare"]]
    main = wts[0] if wts else None
    protected = set(ALWAYS_PROTECTED) | set(names)
    if main and main["branch"]:
        protected.add(main["branch"])
    prs = pull_requests(ctx["cwd"])
    rows, prunable = [], []

    def merged_for(name, sha, skip):
        return None if skip else merged_state(ctx["cwd"], sha, bases, (prs or {}).get("merged", {}).get(name, []))

    if args["local"]:
        linked = wts[1:]
        prunable = [w for w in linked if w["prunable"] or not os.path.exists(w["path"])]
        live = [w for w in linked if w not in prunable]
        by_branch = {w["branch"]: w for w in live if w["branch"]}
        entries = [(b["name"], b["sha"], b["ts"], by_branch.get(b["name"])) for b in refs(ctx["cwd"], "refs/heads")]
        for w in live:
            if not w["branch"]:
                ts = int(git_out(ctx["cwd"], "log", "-1", "--format=%ct", w["head"]) or 0)
                entries.append((None, w["head"], ts, w))
        for name, sha, ts, w in entries:
            open_pr = (prs or {}).get("open", {}).get(name) if name else None
            skip = (name in protected) or (open_pr is not None and not args["force"])
            f = {"branch": name, "sha": sha, "open_pr": open_pr, "today": is_today(ts),
                 "merged": merged_for(name, sha, skip), "worktree": worktree_facts(ctx, w) if w else None}
            v = classify_local(f, protected, args["force"], args["auto"])
            kind = ("worktree+branch" if name else "worktree") if w else "branch"
            rows.append(dict(v, kind=kind, name=name or "(detached %s)" % sha[:8], sha=sha,
                             path=w["path"] if w else "", facts=f, quiet=v["reason"].startswith("protected")))
    if args["remote"]:
        for r in refs(ctx["cwd"], "refs/remotes/origin"):
            if r["name"] in ("origin", "origin/HEAD"):
                continue
            branch = r["name"][len("origin/"):]
            open_pr = (prs or {}).get("open", {}).get(branch)
            skip = branch in protected or open_pr is not None or prs is None
            f = {"branch": branch, "open_pr": open_pr, "gh": prs is not None, "today": is_today(r["ts"]),
                 "merged": merged_for(branch, r["sha"], skip)}
            v = classify_remote(f, protected)
            rows.append(dict(v, kind="remote", name=r["name"], branch=branch, sha=r["sha"], path="",
                             quiet=v["reason"].startswith("protected")))
    return rows, prunable, prs is not None, names


def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def write_tsv(path, log):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write("when\tkind\tname\tsha\tpath\taction\treason\n")
        for r in log:
            fh.write("\t".join(str(r[k]) for k in ("when", "kind", "name", "sha", "path", "action", "reason")) + "\n")


def wip_commit(row, log):
    wt = row["path"]
    if not row["facts"]["branch"]:
        branch = "cleanup-wt/wip-" + os.path.basename(wt)
        if git(wt, "switch", "-c", branch)[0] != 0:
            return False
        row["facts"]["branch"] = branch
        log.append({"when": now_iso(), "kind": "branch", "name": branch, "sha": row["sha"], "path": wt,
                    "action": "save-branch", "reason": "detached worktree: branch created so its commits stay reachable"})
    if not git_out(wt, "status", "--porcelain"):
        return True  # nothing to snapshot; the branch alone keeps the commits reachable
    git(wt, "add", "-A")
    if git(wt, "commit", "--no-verify", "-m", "🚧 [wip] cleanup-wt: snapshot " + now_iso())[0] != 0:
        return False
    log.append({"when": now_iso(), "kind": "wip", "name": row["facts"]["branch"], "sha": git_out(wt, "rev-parse", "HEAD"),
                "path": wt, "action": "wip-commit", "reason": "dirty state saved before removing the worktree"})
    return True


def apply(ctx, rows, prunable, args, log):
    done = []
    for row in [r for r in rows if r["bucket"] == REMOVE and r["kind"] != "remote"]:
        if row["wip"] and not wip_commit(row, log):
            done.append("skipped %s: wip commit failed" % row["path"])
            continue
        if row["remove_worktree"]:
            if row["facts"]["worktree"]["locked"]:
                git(ctx["cwd"], "worktree", "unlock", row["path"])
            code, _, err = git(ctx["cwd"], "worktree", "remove", *(["--force"] if args["force"] else []), row["path"])
            if code != 0:
                done.append("skipped %s: %s" % (row["path"], err.splitlines()[0] if err else "remove failed"))
                continue
            done.append("removed worktree " + row["path"])
            parent = os.path.dirname(row["path"])
            if not real(parent).startswith(ctx["root"]):
                try:
                    os.rmdir(parent)  # only succeeds when empty
                except OSError:
                    pass
        if row["delete_branch"] and row["facts"]["branch"]:
            code, _, err = git(ctx["cwd"], "branch", "-D", row["facts"]["branch"])
            done.append(("deleted branch " if code == 0 else "kept branch ") + row["facts"]["branch"]
                        + ("" if code == 0 else ": " + err.splitlines()[0]))
    remote = [r["branch"] for r in rows if r["bucket"] == REMOVE and r["kind"] == "remote"]
    for i in range(0, len(remote), 20):
        chunk = remote[i:i + 20]
        code, _, err = git(ctx["cwd"], "push", "origin", "--delete", *chunk, timeout=120)
        done.append("deleted remote " + ", ".join(chunk) if code == 0 else "remote delete failed: " + (err.splitlines() or [""])[-1])
    if prunable or done:
        git(ctx["cwd"], "worktree", "prune")
    if prunable:
        done.append("pruned %d missing worktree(s)" % len(prunable))
    return done


def print_table(rows, dry):
    shown = [r for r in rows if not r.get("quiet")]
    if not shown:
        print("cleanup-wt: nothing besides the protected branches.")
        return
    order = {REMOVE: 0, REVIEW: 1, KEEP: 2}
    shown.sort(key=lambda r: (order[r["bucket"]], r["name"]))
    label = lambda r: "WOULD" if (r["bucket"] == REMOVE and dry) else r["bucket"]
    wb = max(len(label(r)) for r in shown)
    wk = max(len(r["kind"]) for r in shown)
    wn = max(len(r["name"]) for r in shown)
    for r in shown:
        print("%s  %s  %s  %s%s" % (label(r).ljust(wb), r["kind"].ljust(wk), r["name"].ljust(wn), r["reason"],
                                    "  [%s]" % r["path"] if r["path"] else ""))


def parse_args(argv):
    a = {"apply": False, "force": False, "auto": False, "post_merge": False, "fetch": None,
         "local": True, "remote": True, "tsv": None, "bases": [], "help": False}
    it = iter(argv)
    for arg in it:
        if arg == "--apply":
            a["apply"] = True
        elif arg == "--force":
            a["force"] = True
        elif arg == "--auto":
            a["auto"] = True
        elif arg == "--post-merge":
            a["post_merge"] = True
        elif arg == "--fetch":
            a["fetch"] = True
        elif arg == "--no-fetch":
            a["fetch"] = False
        elif arg == "--local-only":
            a["remote"] = False
        elif arg == "--remote-only":
            a["local"] = False
        elif arg == "--tsv":
            a["tsv"] = next(it)
        elif arg == "--base":
            a["bases"].append(next(it))
        elif arg in ("-h", "--help"):
            a["help"] = True
        else:
            raise RuntimeError("unknown argument: " + arg)
    if a["auto"] or a["post_merge"]:
        a.update(apply=True, force=False, remote=False, fetch=bool(a["fetch"]), quiet=True)
        a["auto_gate"] = a["auto"]
        a["auto"] = True  # never wip-commit in hook modes
    elif a["fetch"] is None:
        a["fetch"] = True
    return a


def bases_moved(ctx, names):
    """Hook gate: True when any base tip changed since the last gated run. The first run only records."""
    path = os.path.join(ctx["common"], "cleanup-wt", "last-bases")
    tips = " ".join(b["sha"] for b in base_refs(ctx["cwd"], names))
    if not os.path.exists(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(tips + "\n")
        return False, path, tips
    with open(path) as fh:
        return fh.read().strip() != tips, path, tips


def hook_event():
    """The hook event this run serves, from Claude Code's stdin JSON; None when run by hand."""
    if sys.stdin.isatty():
        return None
    try:
        ev = json.loads(sys.stdin.read() or "{}").get("hook_event_name")
        return ev if ev in ("SessionStart", "PostToolUse") else None
    except ValueError:
        return None


def run(argv):
    args = parse_args(argv)
    if args["help"]:
        print(__doc__)
        return 0
    ctx = context(os.getcwd())
    if not ctx:
        raise RuntimeError("not inside a git repository")
    if args["fetch"]:
        code, _, err = git(ctx["cwd"], "fetch", "--prune", "--quiet", "origin", timeout=20 if args.get("quiet") else 120)
        if code != 0 and not args.get("quiet"):
            print("note: fetch failed (%s) -- using refs as of the last fetch" % (err.splitlines() or ["?"])[0])
    gate = None
    if args.get("auto_gate"):
        moved, gate_file, tips = bases_moved(ctx, base_names(ctx["cwd"], args["bases"]))
        if not moved:
            return 0
        gate = (gate_file, tips)

    rows, prunable, gh, names = plan(ctx, args)
    stamp = datetime.datetime.now().strftime("%Y-%m-%d-%H-%M-%S")
    tsv = args["tsv"] or os.path.join(ctx["common"], "cleanup-wt", stamp + ".tsv")
    when = now_iso()
    log = [{"when": when, "kind": r["kind"], "name": r["name"], "sha": r["sha"], "path": r["path"],
            "action": ("remove" if args["apply"] else "would-remove") if r["bucket"] == REMOVE else r["bucket"].lower(),
            "reason": r["reason"]} for r in rows if not r.get("quiet")]
    write_tsv(tsv, log)  # before acting, so a crash mid-apply still leaves the SHAs
    done = []
    if args["apply"]:
        done = apply(ctx, rows, prunable, args, log)
        write_tsv(tsv, log)

    if args.get("quiet"):
        if gate:
            with open(gate[0], "w") as fh:
                fh.write(gate[1] + "\n")
        acted = [d for d in done if d.startswith(("removed", "deleted", "pruned"))]
        if acted:
            msg = "cleanup-wt: %d cleanup action(s): %s. Recovery TSV: %s" % (len(acted), "; ".join(acted), tsv)
            ev = hook_event()
            print(json.dumps({"hookSpecificOutput": {"hookEventName": ev, "additionalContext": msg}}) if ev else msg)
        return 0

    print("bases: " + ", ".join(names))
    print_table(rows, not args["apply"])
    if not gh and args["remote"]:
        print("note: gh unavailable -- open PRs unknown; remote branches are kept")
    if done:
        print("\napplied:\n  " + "\n  ".join(done))
    elif not args["apply"] and any(r["bucket"] == REMOVE for r in rows):
        print("\n(dry run -- re-run with --apply to act)")
    print("recovery TSV: %s  (restore: git branch <name> <sha>; git push origin <sha>:refs/heads/<name>)" % tsv)
    return 0


def main():
    hook = "--auto" in sys.argv or "--post-merge" in sys.argv
    try:
        sys.exit(run(sys.argv[1:]))
    except Exception as e:  # a hook must never fail a session; by hand, say what broke
        if not hook:
            print("cleanup-wt: %s" % e, file=sys.stderr)
            sys.exit(1)
        sys.exit(0)


if __name__ == "__main__":
    main()
