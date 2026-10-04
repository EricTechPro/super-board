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
  // publishing the page away from the checkout (GitHub Pages)? `render --map map.json --source-base
  // https://github.com/OWNER/REPO/blob/main/ [--source-root <pack dir>]` links each source under the
  // source root to that URL (`:12-20` → `#L12-L20`); sources outside it show as text, no link
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
      "lanes": [ { "title": "Ask", "nodeIds": ["grilling"] } ],   // optional swimlanes; false turns derived lanes off
      "layout": { "super-board": [0, 0] } }  // optional [col,row] per node; default = layered auto-layout
  ]
}
```

- **Main steps.** Set `mainSteps: true` (or `render: "process"`) to show a compact left-to-right process, with larger, bold, numbered cards and no inferred hub lanes. Keep it to roughly four to six columns. Give each step a short `sublabel` that says what it decides or does; place scripts, state, and policy details in a child view.
- **Nested families.** A view's `containers: [{"id": "board-family", "label": "/super-board", "nodeIds": ["super-board", "super-build", "super-qa", "super-review"], "parent": "intake-family"}]` draws enclosing boxes. `parent` names another container in that view; omit it for an outer box. Bounds include member cards and child boxes automatically. Keep sibling families in separate columns with a `layout`; the check covers containment, overlapping sibling boxes and wires crossing family headers. Cards inside a family retain their normal details and drill-down. For a process with visible nested tools, set `stepIds` to its four to six primary cards; other `nodeIds` render as ordinary tools.
- **Column browser.** Children normally follow view order. `browserOrder: ["super-collect", "super-board", "super-build", "super-qa", "super-review"]` puts these views first and can expose shortcuts to descendants; remaining direct children follow. The actual `parent` hierarchy still owns breadcrumbs. Columns scroll horizontally, labels wrap and every row is at least 34 px high.
- **View-local steps.** A view may define `nodes: [{"id", "label", "kind": "step", "what", "when", "how", "opensView"}]`. These join the page's node index without changing the shared captured nodes. IDs must be unique across both collections; list them in `nodeIds` as usual. Inline `edges` can link them to one another or to shared nodes. The check, search, details, source links, and drill-down use the same model.
- **Presentation overrides.** `nodeOverrides: {"node-id": {"label": "Short label", "sublabel": "One line", "opensView": "detail-view", "emphasis": true, "verbs": []}}` changes that card only in this view. Keep captured `what`, `when`, and `how` intact. An explicit empty `edges: []` hides all wires in that view.
- **Focus and details.** Clicking a card highlights its direct neighbors, its wires, and their attached ports; the rest dims. Selected wires flow automatically. A background click clears selection, and reduced motion keeps a static highlight. What, When, and How derive two to four one-line bullets from the node's captured text; the complete point remains in its tooltip. Links uses lists for relations, sources, and other views.
- **Kinds, as the legend says them:** public skill (you run it; bold outline, halo, PUBLIC tab), board lane (the board starts it; LANE tab), external skill (from another pack; dashed outline, EXTERNAL tab), impeccable verb (a design command; pill), script (code a skill runs; small and muted), hook / guard (fires on its own; hexagon), state (board, config, ledgers).
- **Authors.** A node with `author` (and every external skill) hangs a name tag under its card: a 26 px headshot and `@login`, or initials when the avatar could not be fetched. Ports and routes keep off the tag.
- **Swimlanes.** A `render: "sequence"` view is read step by step and each part is filed under the first workflow phase (Ask, Plan, Build, Check, Fix, Finish) that its label, its step's label, or its sub line names; phases only move forward. The run's driver (the view's subject, or the source of step 1 when it starts three or more steps) becomes a bar across the top, its own steps show as numbers on the parts, and the remaining wires route between lanes. Lanes are kept only with 3 to 6 phases, at least 60% of parts naming theirs, and a crossing-free route; otherwise the view stays a free graph. `lanes: [...]` sets them by hand, `lanes: false` turns them off. The check fails a part outside its lane, overlapping lanes, or a wire across a lane header.
- **Skills first.** A view shows the skills and verbs a node triggers. Scripts are small detail nodes or stay in `how`.
- **Routing.** Every edge gets its own port and its own orthogonal route. Routes never share a line and cross only when nothing else fits; `render` searches row orders for a crossing-free layout, bakes it into `layout`, and the check fails on any crossing that remains. ≋ in the control bar (or F) animates the flow direction.
- **Drill-down.** A node opens a view when `opensView` names one or a view shares its id. Such nodes draw as a stack with a `⤢ n` badge. A view that is about one node (same id) lays out around it: the node first, then what it calls.
- **Edges.** A→B plus B→A merge into one two-way edge, and parallel edges between one pair merge into one edge whose label ends in `+n`. A label with no clean spot is left off the canvas but stays in the tooltip and the panel.
- Keep labels to ≤ 28 chars and edge labels to a verb phrase; the panel carries the long text.
