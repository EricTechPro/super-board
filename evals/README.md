# Evals

Behavioural evals for the pack, run with `claude plugin eval`. Each case seeds a throwaway
repo, runs a real Claude agent with the plugin loaded, and grades what it did.

## Run

From the pack root (`_skills/vendor/super-board/`):

```bash
PATH=$PWD/evals/_stubs/bin:$PATH claude plugin eval . \
  --scaffold --allow-tools Bash --ablation none --runs 3 --max-cost-usd 5
```

- `evals/_stubs/bin` **must** be first on `PATH`. `seed.sh` copies it into the run's temp
  HOME and prepends it from the shell rc files there — the agent's Bash does not inherit the
  caller's `PATH`. It refuses to run without it.
- `--scaffold` runs `seed.sh` (bash we wrote); `--allow-tools Bash` lets the reviewer run
  `gh`/`git`/`python3`. Add `--runs 1 --keep-temp` to debug; the trace path is in the JSON.
- Results land in `evals/results/` (gitignored).

**Cost:** about $0.20 per run with the default model, so ~$0.60 for `--runs 3`.

## Stubs (`_stubs/bin/`)

- `gh` — offline. Serves `<repo>/.git/gh-fixture/pr.json` (honours `--json` and `--jq`) and
  `diff.patch`, logs every call to `<repo>/.gh-log`, answers writes with "ok". `pr merge` is a
  logged no-op, so a grader can tell whether the agent tried.
- `git`, `python3` → `_real` — macOS's `/usr/bin` copies are xcrun shims that need a cache
  file the eval sandbox forbids; this execs the real binary instead.

## Cases

| Case | What it proves | Graders |
|---|---|---|
| `review-remembers` | On a re-review super-review loads the last `<!-- super-review:report -->` comment, marks R1 fixed and R2 not fixed with file:line, bounces, and skips the merge. | `loaded-prior` (Bash ran `gh pr view … comments`), `verdict` (LLM judge, weight 2), `no-merge` (`.gh-log` has no `pr merge`) |
