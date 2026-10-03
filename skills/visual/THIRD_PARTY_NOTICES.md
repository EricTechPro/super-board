# Third-party notices

`/visual` adapts ideas from two MIT-licensed projects. No source file is copied
whole; the borrowed parts are named below so the attribution is precise.

## BuilderIO/skills (visual-recap, visual-plan)

Adapted from BuilderIO/skills (MIT): the per-mode section list, the recap and
plan quality bar, the grounding and secret-redaction rules, and the
"Key changes" + file-tree layout. `references/sections.md` carries them. The
hosted Agent-Native Plans app, MDX blocks, MCP connector, and `npx` tooling are
not used.

Source: https://github.com/BuilderIO/skills

MIT License

Copyright (c) 2026 Builder.io

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## tt-a1i/archify

Diagram style adapted from Archify (MIT): the semantic node palette (dark and
light values), the opaque-mask-under-translucent-fill node construction, the
40px grid canvas, orthogonal rounded routes with arrowhead markers, and
per-kind icons (the cloud, shield, and external-link icon paths follow
Archify's semantic sigils). `assets/template.html` re-implements these as a small inline
renderer.

Viewer UX adapted from Archify's viewer (`viewer/viewer-camera.js`, `semantic-radar.js`,
`focus.js`, `node-finder.js`, `export.js`): camera zoom and pan with fit and 100% presets
and keyboard steps, reading depths that hide detail when zoomed out (map / read / full),
a minimap with a draggable viewport, a node focus panel with upstream and downstream reach
(Archify's "Semantic Passport"), dimming of unrelated nodes on focus, a node finder, SVG and
PNG export, and the floating control-pill and toolbar look. These are re-implemented from
scratch in `assets/template.html`; no Archify source file is copied. The edge router follows
the approach of Archify's `renderers/shared/route-quality.mjs` (`shortestOrthogonalGridRoute`)
and `renderers/architecture/routing.mjs`: one port per edge spread along the node side in the
order of the far ends, a sparse orthogonal visibility grid built from node edges plus clearance
and earlier routes plus separation, Dijkstra with a bend penalty over (cell, direction) states,
no collinear reuse of earlier routes, and labels reserved as obstacles for later routes.
Re-implemented, not copied. Drill-down views,
breadcrumbs, deep links, and the overlap check are /visual's own. Archify's JSON-IR CLI,
validators, viewer runtime, and embedded font are not bundled.

Source: https://github.com/tt-a1i/archify

MIT License

Copyright (c) 2026 tt-a1i (Archify)
Copyright (c) 2025 Cocoon AI

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
