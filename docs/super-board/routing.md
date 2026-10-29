# Which path do I take?

Pick the path by what you have. Every path ends in tickets. Then the number of tickets picks who builds them.

## 1. Plan: from what you have to tickets

| You have | Do this |
|---|---|
| A clear idea | `/grill-me` → `/to-spec` → `/to-tickets` |
| A big, foggy idea, too big for one session | `/wayfinder` → `/to-spec` → `/to-tickets` |
| Bugs and errors | `/super-collect` → findings doc → `/to-spec` → `/to-tickets` |

- `/grill-me` asks you hard questions until the idea is sharp.
- `/wayfinder` settles the big decisions over many sessions. When the way is clear, it hands off to `/to-spec`.
- `/super-collect` finds problems (Sentry, PostHog, issues, PRs, code shape), checks each one, and writes one findings doc.
- `/to-spec` writes the spec.
- `/to-tickets` cuts the spec into small tickets.

## 2. Build: count the tickets

| Tickets | Who builds | What it is like |
|---|---|---|
| 1–5 | `/implement-spec` | Fast. One session. No QA lane. |
| 6 or more, or you want to walk away | super-board | Build → QA (with the security check) → Review → merge gate |

On super-board, the tickets go to **Backlog**. Run `/super-board lint`, move the good ones to **Ready**, then `/super-board run`.

## 3. Deploy

super-deploy is planned. It is not built yet.
