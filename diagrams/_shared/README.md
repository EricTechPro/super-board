# Shared skill-map shell

Every skill-map page (`impeccable`, `pstack`, ...) renders through one shell, so nav bar, header, toolbar, dialog, order strip and footer look and behave the same.

Build one page: `python3 diagrams/_shared/build_skillmap.py <map>` writes `diagrams/<map>/index.html` (single self-contained file, stdlib only).

Files: `sitenav.html` (site nav, same markup as /onboarding/), `shell.css` + `shell.html` + `shell.js` (page frame, search/filter, full screen, theme, dialog glue), `skillmap.css` + `skillmap.js` (dialog component).

## Add a map
1. Create `diagrams/<map>/map.py` with `build()` returning a dict:
   `key` (nav entry: `impeccable`, `pstack` or a new one you add to `sitenav.html`), `title`, `version`, `subtitle` (html), `svg` (inline `<svg class="map" id="map" viewBox=...>`, every clickable node/group has `data-id`), `mapw` (svg width in px), `css` (your palette + svg styles; set `--c` per node class), `js`, `order` (list of `(n, title, sub, css_class)`), `footer` (html), optional `filter` (`label`, `options=[(value,label,icon_svg)]`) and `legend` (html).
2. `js` must set `SMPAGE={model:function(id){...}, label:function(id){...}}` and `window.SMDATA={search:{id:text}, filt:{id:[values]}}`. `model(id)` returns `{accent, title, tags, blocks}` (see `skillmap.js` `render`).
3. Add the page to `.github/workflows/pages.yml` and a card to `diagrams/index.html`.

## Canvas mode and collapsible groups
`canvas.js` adds a Canvas toggle (pan, wheel/pinch zoom, +/−/Fit, drag a group or node, Reset layout) and a chevron per group. Layout, collapse state and zoom are saved per page in localStorage. To support it, mark up the svg:
- `data-region="gid"` on the group's box `<g>` (its first `<rect>` is the box),
- `data-grp="gid"` on each member node; add `data-head="1"` on the group's title node,
- `data-edge="fromGid toGid"` on each arrow path/line (redrawn as an elbow once an end moves or collapses),
- `data-trunk="gid"` on a shared trunk line that should hide once that group moves.

## Layout `sdlc` (data-only maps)
A map directory with `map.json` (no `map.py`) renders through `layout_sdlc.py`: six stage layers (Plan, Design, Build, Test, Deploy, Maintain) as straight-line bands with a corner tag, categories side by side with dividers, each a chain of skills in trigger order, an optional Anytime band, empty stages greyed. Click a stage tag, category header or skill for its dialog. Build: `python3 diagrams/_shared/build_skillmap.py <dir>`; `meta.out` redirects the output folder. Sample data: `diagrams/_sample-sdlc/map.json` (preview at `/sdlc-template/`). Schema: stages, categories (stage, chain, principle, when, chainWhy, sources), anytime, skills (when, whatItIs, howItWorks, example, behindTheScenes, calls, next, sources).

## Registry
`maps.json` drives the site nav (entries with `nav: true`) and the landing page's Explore cards (`sync_explore.py`). Every map page must have an entry; `build_skillmap.py` and `sync_explore.py --check` fail otherwise.

## Version label
Pages show `<span data-sb-version>dev</span>` (or `data-sb-version="v"`) when opened from disk. The pages workflow runs `stamp_version.py _site "$(cat VERSION)"`, so the live site always shows the repo VERSION. Never type a release number into a page.
