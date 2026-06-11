---
name: super-board
description: GitHub-Project-driven autonomous pipeline. Five verbs — onboard, lint, status, run, stop — that take a Project board from empty to drained across Build → QA → Review → Done lanes, with graceful shutdown / resume. Use when the user says "super-board", "/super-board", "drain my GitHub project", "set up the autonomous loop", "kick off the headless build/QA pipeline", or "stop super-board".
---

# super-board — autonomous GitHub Project pipeline

Spec: `docs/superpowers/specs/2026-05-21-super-board-design.md`

## Five verbs

| Verb | Where | What it does |
|---|---|---|
| `super-board onboard` | interactive | one-time setup wizard; writes `.claude/super-board/configs/<slug>.json` |
| `super-board lint` | interactive | walks active-pipeline issues, flags vague ACs, runs pre-flight readiness |
| `super-board status` | interactive (read-only) | snapshot of active config, column counts, in-flight workers |
| `super-board run` | headless | the autonomous loop; spawned via `scripts/super-board-run.sh`. Also the resume command — state lives on the board, not in process memory. |
| `super-board stop` | interactive | graceful shutdown: posts "stopped mid-flight" comments on every in-flight issue + PR, releases assignee mutexes, kills workers + dispatcher. Next `super-board run` resumes. |

If invoked with no verb, ask which (see no-verb behavior in spec §8).

## Routing

| If user says | Load |
|---|---|
| `super-board onboard ...` | `references/onboard.md` |
| `super-board lint ...` | `references/lint.md` |
| `super-board status ...` | `references/status.md` |
| `super-board run ...` (default — `worker_backend` unset or `"workflow"`) | `references/run-workflow.md` (lane lifecycles still come from `references/run.md`) |
| `super-board run ...` with config `worker_backend: "claude-p"` (legacy, explicit opt-in) | `references/run.md` |
| `super-board stop ...` / "stop the run" / "pause the loop" / "kill super-board" | `references/stop.md` |
| "resume" / "pick up where I left off" / "restart after stop" | `references/stop.md` (resume = run; no separate verb) |
| Anything about Block/Skip exits | `references/block-template.md` |
| Config structure questions | `references/config-schema.json` |
| Worker gh-call discipline / rate-limit recovery | `references/rate-limit-etiquette.md` (+ `scripts/super-board-gh-guard.sh`) |

Replaces: `super-work-trader` (rename + extension). The 3-lane mechanics are inherited; the front door (onboard / lint / status / stop) is new.

## Orchestrator vs worker — the cardinal rule

super-board is an **autonomous trader**. The interactive Claude session that invokes any of the five verbs is an **orchestrator**, not a worker. The orchestrator:

- Validates preconditions, then dispatches per the config's `worker_backend`: `"workflow"` (default) → stay in-session and run the wave loop in `references/run-workflow.md` (launch workflow, reconcile, repeat); `"claude-p"` (legacy, explicit opt-in only) → `nohup ./scripts/super-board-run.sh`, report PID + log path, exit. In both backends the orchestrator never does product work itself.
- Delegates all build / QA / review work to workers — headless `claude -p` (claude-p backend) or workflow lane agents (workflow backend).
- Must NOT do product work itself, must NOT patch the dispatcher mid-run, must NOT wait for workers, must NOT hold context for multi-card progress.

If anything goes wrong during a run, the orchestrator captures the symptom and reports back — it does not silently expand the task into a fix. See `references/run.md` "Orchestrator delegation contract" for the full rule.
