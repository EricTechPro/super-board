# Section bar per mode

Adapted from BuilderIO/skills `visual-recap` and `visual-plan` (MIT): their section list and quality bar, without the hosted Plans app.

## Recap: a branch, PR, or diff

The page is built *from* a diff, at a higher altitude than line-by-line review, so a reviewer sees the shape before the lines.

1. `title` + `subtitle`: the outcome, not "Changes to X".
2. `summary`: what changed and why, the decisions visible in the diff, in 1–3 paragraphs.
3. `keyChanges`: 3–7 cards, each one a reviewer-meaningful change with its files. Next to them, the **Files** map is filled from git automatically. Add `fileNotes` for the 3–8 files that need a word.
4. `diagrams`: the architecture or flow of what changed, after-state with `change` flags. Add a Before/After pair when the structure moved.
5. `endpoints`: every added, changed, or removed route, command, or event, with real method, path, and shapes from the diff.
6. `hunks`: 3–8 key files, each with a one-line `summary` and 1–4 `notes` on the load-bearing lines. Use a brand-new file's most important block. Each excerpt stays under ~80 lines.
7. `risks`: compatibility, data, auth, and rollout, each marked high/med/low. Leave out generic risks.
8. `tests`: concrete checks a reviewer can run or click, with `cmd` where one exists.

Before writing, take a surface inventory: changed routes, commands, components, schemas, config, and docs. Each meaningful item lands in a block, or is skipped on purpose because it is tiny.

- **Good:** a 25-file change with a two-paragraph summary, five key-change cards, an after-state diagram flagging two new services and three new routes, endpoint cards, five annotated hunks, three specific risks, and six checks.
- **Bad:** one giant unannotated diff dump, or a three-block page for a 40-file change.

Skip /visual for a one-file, obvious diff; plain diff reviews faster.

## Plan: a plan file, PRD, issue, or plan text in chat

A serious technical plan that stands alone: someone opening the link with no chat history understands it.

1. `summary`: the objective, what "done" means, scope and non-goals, the approach and why. Put one concrete example near the top when the idea is abstract.
2. `keyChanges`: what will change, as decisions. Lead with what each step **reuses** (existing modules, actions, schema), then the new delta.
3. `diagrams`: the target design, with new pieces flagged `planned`. Draw a picture of new endpoints and their callers.
4. `files`: real paths to add, modify, or delete, each with a note. Read the codebase first; invented paths are the failure.
5. `steps`: ordered and each independently verifiable, naming real files and symbols. The last step is verification. A single-step plan is not a plan.
6. `endpoints` and `hunks`: contracts and code sketches only where shape matters.
7. `risks`: hard-to-reverse bets first (wire format, ids, data shape, auth boundaries).
8. `questions`: what you could not resolve from the code, each with a recommended `default`. Decide everything else in the plan.

Planning is read-only. When the plan came from chat or a file, rewrite it as a clean standalone proposal with no "as discussed" or "this revision" language.

## Explore: a folder, endpoint set, or architecture

Answers "what is this and how does it hang together".

1. `summary`: what it is, who calls it, the one idea that makes it make sense.
2. `diagrams`: an overview first (components and their flow), then one per important flow.
3. `keyChanges`, relabelled Highlights: the 3–6 things worth knowing (entry points, gotchas, conventions).
4. `files` as a Map: the important files grouped by area, with a note each. Leave out the exhaustive list.
5. `endpoints`: the full route, command, or event surface when one exists.
6. `hunks`: key code excerpts with notes, for the entry point and the core loop.
7. `tests`, relabelled Try it: commands to run it, or ways to poke it.
