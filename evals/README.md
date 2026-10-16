# Evals

Behavioural evals for the pack, run with `claude plugin eval`. Each case seeds a throwaway
repo, runs a real Claude agent with the plugin loaded, and grades what it did.

## Run

From the pack root (`_skills/vendor/super-board/`):

```bash
PATH=$PWD/evals/_stubs/bin:$PATH claude plugin eval . \
  --scaffold --allow-tools Bash Write Edit --ablation none --runs 3 --max-cost-usd 5
```

`--case <name>` runs one case. `test-gap` needs `Write Edit` (the Tester writes the missing test);
the review cases only need `Bash`; the `collect-*` cases need `Bash Write Agent` (body files and
one verifier sub-agent per candidate) — `--case 'collect-*'` runs just those.

- `evals/_stubs/bin` **must** be first on `PATH`. `seed.sh` copies it into the run's temp
  HOME and prepends it from the shell rc files there — the agent's Bash does not inherit the
  caller's `PATH`. It refuses to run without it.
- `--scaffold` runs `seed.sh` (bash we wrote); `--allow-tools Bash` lets the agent run
  `gh`/`git`/`python3`. Add `--runs 1 --keep-temp` to debug; the trace path is in the JSON.
- Results land in `evals/results/` (gitignored).

Offline regression tests for the same skill (no model, no cost) run in `tests/run-safety.sh`:
`tests/test_collect_baseline.py` and `tests/test-collect-baseline.sh`.

**Cost:** about $0.25-0.45 per run with the default model, so roughly $3 for all three cases at
`--runs 3`.

## Stubs (`_stubs/bin/`)

- `gh` — offline. Serves `<repo>/.git/gh-fixture/pr.json` (honours `--json` and `--jq`),
  `diff.patch` and, when a case writes one, `issue.json` for `gh issue view`, logs every call to `<repo>/.gh-log`, answers writes with "ok". `pr merge` is a
  logged no-op, so a grader can tell whether the agent tried.
- `gh` list reads honour `--state`, `--label` and `--search`; the super-collect cases add
  `issues.json`, `prs-merged.json`, `project-items.json`, `fields.json` and `graphql.json`.
  Writes are recorded, never sent: `issue create` bodies go to `.git/gh-created.md`, comments
  to `.git/gh-comments.md`, and every call to `.git/gh-calls.log` (plain text, for graders).
- `tea` — offline, STATEFUL. Serves the gitea twin of the gh stub for boards with
  `"forge": "gitea"`: first call seeds `.git/tea-state.json` from `.git/tea-fixture/`
  (`issues.json` `pulls.json` `labels.json` `projects.json` `columns.json`
  `board.json` = [{column, numbers}] placements, `pull-<n>-files.json`, `pull-<n>.diff`,
  `version.json`, `user.json`, `repo.json`, `no-ratelimit`, `ratelimit-remaining`), then
  reads AND writes go through that state (create/comment/label/move/merge all mutate it, so
  a grader can assert the final board). Calls log to `.git/tea-calls.log`, writes to
  `.git/tea-writes.log`. Only `tea api` (+ `--version`, `login ls`) is implemented — the
  gitea adapter never calls anything else. `{owner}/{repo}` placeholders expand from
  `GITEA_REPO`, like the real CLI.
- `py/sitecustomize.py` — offline Sentry and PostHog. `collect-seed.sh` puts it on `PYTHONPATH`
  with `SC_FIXTURES` pointing at a rendered copy of `tests/fixtures/collect/`, so the real
  `collect_sentry.py` / `collect_posthog.py` read canned payloads through
  `tests/fixtures/collect/fixture_http.py`; any URL without a fixture fails, nothing leaves the
  machine. The same payloads drive `tests/test_collect_baseline.py`.
- `collect-seed.sh` — the shared scaffold for the `collect-*` cases: a small shop app repo,
  a super-board config with a `collect` block, the pack's scripts in `.claude/`, fake tokens.
- `git`, `python3` → `_real` — macOS's `/usr/bin` copies are xcrun shims that need a cache
  file the eval sandbox forbids; this execs the real binary instead.

## Cases

| Case | What it proves | Graders |
|---|---|---|
| `review-remembers` | On a re-review super-review loads the last `<!-- super-review:report -->` comment, marks R1 fixed and R2 not fixed with file:line, bounces, and skips the merge. | `loaded-prior` (Bash ran `gh pr view … comments`), `verdict` (LLM judge, weight 2), `no-merge` (`.gh-log` has no `pr merge`) |
| `ponytail-overengineering` | On a correct, tested PR that wraps a one-line formatter in a strategy class, registry, factory and JSON config, super-review reports an Over-engineering finding routed to Super Build and still calls the PR merge-ready. | `verdict` (LLM judge, weight 2), `reran-tests` (Bash ran the `Local tests:` command), `no-merge` |
| `collect-sentry-verdicts` | super-collect `sentry --yes`: a live checkout crash (WEB-4411) is verified and filed in the ticket format; an avatar crash fixed by merged PR #377 (WEB-4490) is dropped `drop-fixed`. | `filed-4411`, `ticket-format` (Problem → Risk in `.git/gh-created.md`), `not-filed-4490`, `never-ready`, `verdict` (LLM judge, weight 2) |
| `collect-duplicate` | super-collect `sentry --yes` when WEB-4411 is already open as #301 with the same fingerprint: a "Seen again" comment on #301, no new issue. | `commented`, `seen-again`, `no-new-issue`, `verdict` (LLM judge, weight 2) |
| `collect-posthog-gap` | super-collect `posthog` dry-run: no signal clears a threshold; the un-instrumented receipt-upload workflow gets exactly one `analytics` feature ticket (`gap|…`), signup none, no code edited. | `read-events`, `planned-gap`, `no-signup-gap`, `no-code-edit`, `verdict` (LLM judge, weight 2) |
| `collect-prs-pattern` | super-collect `prs` dry-run: two merged PRs with one root cause (date-only strings read with local getters) become one pattern ticket; a one-off fixed in a single PR becomes nothing. | `read-prs`, `planned-pattern`, `verdict` (LLM judge, weight 2) |
| `test-gap` | super-qa's test-gap check flags an AC with no test (slug ≤ 50 chars) as High and acts on it: writes the test red-first, or bounces to Build. | `verdict` (LLM judge, weight 2), `ran-tests`, `no-merge` |
