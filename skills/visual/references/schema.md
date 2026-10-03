# data.json contract

Every field is optional except `kind` and `title`. Text fields take light inline markdown: `` `code` ``, `**bold**`, `[link](https://…)`, blank-line paragraphs, `- ` bullets. Sections render only when their field is present, in this order.

```jsonc
{
  "kind": "recap",                       // recap | plan | explore
  "title": "Add /visual skill",          // ≤ ~70 chars
  "subtitle": "One command that turns a branch, plan, or folder into a visual page",
  "slug": "visual-skill",                // output filename stem; defaults to title
  "source": "docs/plan.md",              // plan/explore: what the page was built from
  "base": "main",                        // recap: diff base (default main/master)
  "summary": "1–3 paragraphs: outcome, why, key decisions.",

  "keyChanges": [                        // the left column; 3–7 items
    { "title": "Renderer draws archify-style SVG", "tag": "added",   // added|changed|removed|fix|refactor|docs|risk
      "detail": "Why it matters, one or two sentences.", "files": ["assets/template.html"] }
  ],

  // recap: OMIT `files` — render fills them from git (status, +/-, area).
  // plan/explore: list them by hand.
  "files": [ { "path": "src/api/users.ts", "status": "add", "note": "new route handlers" } ],
  "fileNotes": { "src/api/users.ts": "short note shown under the row (recap)" },
  "areas": { "src/api/": "API", ".agents/skills/visual/": "visual skill" },   // optional path-prefix → group label

  "diagrams": [ { "title": "…", "caption": "…", "nodes": [], "edges": [], "groups": [] } ],   // see Diagrams

  "endpoints": [
    { "method": "POST", "path": "/api/users", "summary": "Create a user", "change": "added",
      "auth": "session", "request": { "email": "a@b.co" }, "response": { "id": "usr_123" } }
  ],                                     // method also accepts WS, SSE, CLI, CMD, EVENT

  "steps": [ { "title": "Add the route", "detail": "Reuses `requireSession`; adds …", "files": ["src/api/users.ts"] } ],

  "hunks": [
    // recap: render pulls the real hunk from git. `contains` picks the hunk and centres the window.
    { "file": "src/api/users.ts", "contains": "export async function POST", "summary": "Validates then inserts",
      "maxLines": 60, "notes": [ { "match": "zod.parse", "text": "Rejects bad input before the DB call" } ] },
    // plan/explore: a sketch or real excerpt by hand.
    { "file": "src/api/users.ts", "lang": "ts", "code": "export async function POST(req) {\n  …\n}", "start": 1,
      "notes": [ { "line": 2, "text": "…" } ] }
  ],

  "risks": [ { "level": "high", "text": "Changes the session cookie name — logs everyone out" } ],   // high|med|low
  "tests": [ { "text": "Create a user with a bad email → 400", "cmd": "pnpm test users" } ],
  "questions": [ { "q": "Soft-delete or hard-delete?", "default": "Soft-delete", "why": "audit trail" } ],
  "sections": [ { "title": "Notes", "body": "free markdown, last resort" } ],
  "labels": { "key": "Override a section heading" }
}
```

## Diagrams

The renderer lays nodes on a grid and routes edges orthogonally, in the style of archify: a semantic colour per node kind, an opaque mask under a translucent fill, an icon per kind, a dot-grid canvas, and arrowheads.

- **Node:** `{ "id", "label", "sub", "kind", "col", "row", "change", "note", "w" }`.
  - `col` runs left → right in flow order; `row` stacks peers top → bottom. Halves are allowed (`row: 0.5` centres a node between two rows).
  - `kind` is one of `frontend`, `backend`, `database`, `cloud`, `security`, `queue`, `external`, `file`, `ai`, or an alias (`client`, `ui`, `api`, `service`, `route`, `script`, `cli`, `db`, `cache`, `auth`, `hook`, `event`, `webhook`, `cron`, `user`, `doc`, `config`, `skill`, `agent`, `llm`, …).
  - `change` is `added`, `modified`, `removed`, or `planned`; it draws a NEW / CHANGED / REMOVED / PLANNED badge, and `removed` also dashes the outline.
  - Keep `label` ≤ 22 chars and `sub` ≤ 26; set `w` (px, default 168) for a longer label.
- **Edge:** `{ "from", "to", "label", "style", "change" }`.
  - `style` is `emphasis` (green), `added` (animated green), `dashed` or `async` (violet), `security` (rose dashed), or `removed`. Unstyled edges are grey.
  - Labels stay ≤ 18 chars: the verb or protocol, never a sentence.
- **Group:** `{ "label", "kind", "nodes": [ids] }` draws a dashed boundary around its members, for a service, package, or trust zone.

Layout that reads well:

- Put 3–5 columns of flow (caller → entry → logic → store); more than 7 columns turns into a strip, so wrap into groups instead.
- When **endpoints** are added, draw them as their own column of `route` nodes (`label` = `POST /users`) between the client and the services they call, flagged `added`. This is the "picture of the endpoints".
- For a **recap**, draw the after-state, flag what changed, and show touched-but-unchanged neighbours plain for context. A structural shift gets two diagrams, `Before` and `After`.
- For a **plan**, flag new pieces `planned` and existing ones plain, so the delta is visible.
- For **explore**, use one overview diagram, plus one per interesting flow.
- Edges run forward (higher `col`) wherever possible; back-edges route around the side and read worse.

Every document diagram also gets the camera: drag to pan, pinch or Ctrl/⌘ + scroll to zoom, `+ − 0` on the focused canvas, and ⛶ for full screen.

## Map model (`render --map`)

The drill-down map takes its own file: shared nodes and edges, plus views that each show a subset. `visual.py skillmap` writes a skeleton of it.

```jsonc
{
  "title": "super-board skill map",
  "root": "overview",                      // optional; default = the view with no parent
  "sourcesBase": "_skills/vendor/super-board/",   // optional prefix for node `source` paths (from the repo root)
  "authors": { "mattpocock": { "name": "Matt Pocock", "url": "https://github.com/mattpocock" } },  // avatars are fetched once and inlined by render
  "nodes": [
    { "id": "super-board", "label": "/super-board",
      "kind": "public",                    // public | lane | external | verb | script | hook | board
      "verbs": ["onboard", "run", "stop"], // chips on the node and in the panel
      "what": "One line: what it does.", "when": "What triggers it.", "how": "How it works (markdown).",
      "source": "skills/super-board/SKILL.md",      // string or array; `:line` suffixes are fine
      "sublabel": "optional line under the label",
      "opensView": "super-board",          // optional; otherwise a view with the node's id opens
      "author": "EricTechPro",             // optional GitHub login; external skills show the author's avatar
      "origin": "mattpocock-skills",       // optional: where an external skill comes from
      "credits": ["BuilderIO"] }           // optional: further authors listed in the panel
  ],
  "edges": [ { "id": "e1", "from": "super-board", "to": "super-build", "label": "dispatches", "when": "each wave" } ],
  "views": [
    { "id": "overview", "parent": null, "title": "super-board", "caption": "optional one line", "nodeIds": ["super-board", "super-build"] },
    { "id": "super-board", "parent": "overview", "title": "/super-board", "nodeIds": ["super-board", "..."],
      "edges": ["e1"],                     // optional: edge ids or edge objects; default = every model edge between its nodes
      "render": "sequence",                // optional: edges are the run order and get step numbers
      "layout": { "super-board": [0, 0] } }  // optional [col,row] per node; default = layered auto-layout
  ]
}
```

- **Kinds, as the legend says them:** public skill (you run it; bold outline, halo, PUBLIC tab), board lane (the board starts it), external skill (from another pack; dashed outline, EXTERNAL tab, author avatar or initials), impeccable verb (a design command; pill), script (code a skill runs; small and muted), hook / guard (fires on its own), state (board, config, ledgers).
- **Skills first.** A view shows the skills and verbs a node triggers. Scripts are small detail nodes or stay in `how`.
- **Routing.** Every edge gets its own port and its own orthogonal route. Routes never share a line and cross only when nothing else fits; `render` searches row orders for a crossing-free layout, bakes it into `layout`, and the check fails on any crossing that remains. ≋ in the control bar (or F) animates the flow direction.
- **Drill-down.** A node opens a view when `opensView` names one or a view shares its id. Such nodes draw as a stack with a `⤢ n` badge. A view that is about one node (same id) lays out around it: the node first, then what it calls.
- **Edges.** A→B plus B→A merge into one two-way edge, and parallel edges between one pair merge into one edge whose label ends in `+n`. A label with no clean spot is left off the canvas but stays in the tooltip and the panel.
- Keep labels to ≤ 28 chars and edge labels to a verb phrase; the panel carries the long text.
