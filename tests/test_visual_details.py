#!/usr/bin/env python3
"""Every real skill-map node derives 2–4 detail bullets without inventing text."""
import copy
import html
import json
import re
import sys
import tempfile
from pathlib import Path

pack = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(pack / "skills" / "visual" / "scripts"))
import visual  # noqa: E402

binary = visual.find_chrome()
if not binary:
    print("SKIP: test_visual_details.py (no Chrome)")
    sys.exit(0)

model = copy.deepcopy(json.loads((pack / "diagrams" / "skill-map.json").read_text()))
model["kind"] = "map"
nodes = [*model["nodes"], *(n for v in model["views"] for n in v.get("nodes", []))]
# The seam being tested is prose -> detail list. One edge-free probe view isolates it
# from route optimization and exposes every real node through the real click handler.
model["views"].insert(0, {"id": "detail-probe", "parent": None, "title": "All real detail text",
                            "nodeIds": [n["id"] for n in nodes], "edges": [],
                            "layout": {n["id"]: [i % 6, i // 6] for i, n in enumerate(nodes)}})
model["root"] = "detail-probe"
probe = r"""
<style>* { transition-duration: 0s !important; }</style>
<script>
setTimeout(() => {
  const failures = [], nodes = NODE_DATA;
  const click = el => el.dispatchEvent(new MouseEvent('click', {bubbles:true}));
  const lexical = text => text.toLowerCase().replace(/[^\p{L}\p{N}]/gu, '');
  for (const node of nodes) {
    const card = document.querySelector('.stage .node[data-id="'+CSS.escape(node.id)+'"]');
    if (!card) { failures.push(node.id+': missing card'); continue; }
    click(card);
    for (const key of ['what','when','how']) {
      click(document.querySelector('[data-tab="'+key+'"]'));
      const bullets = [...document.querySelectorAll('#m-pbody .detail-bullets > li')];
      if (bullets.length < 2 || bullets.length > 4) failures.push(node.id+'.'+key+': '+bullets.length+' bullets');
      const words = bullets.map(el => el.textContent).join(' ');
      // Ignoring presentation punctuation, every source word must survive derivation.
      if (lexical(words) !== lexical(node[key] || '')) failures.push(node.id+'.'+key+': changed or omitted source words');
    }
  }
  const pre=document.createElement('pre'); pre.id='details-report'; pre.textContent=JSON.stringify({nodes:nodes.length,failures}); document.body.appendChild(pre);
}, 100);
</script>
""".replace("NODE_DATA", json.dumps(nodes).replace("</", "<\\/"))
with tempfile.TemporaryDirectory() as directory:
    page = Path(directory) / "fixture.html"
    visual.write_page(page, model)
    page.write_text(page.read_text().replace("</body>", probe + "</body>"))
    dom = visual.chrome(binary, "--virtual-time-budget=10000", "--window-size=1440,1000", "--dump-dom",
                        page.as_uri() + "#shot=1", done=lambda s: 'id="details-report"' in s)
    match = re.search(r'<pre id="details-report"[^>]*>(.*?)</pre>', dom, re.S)
    assert match, "detail probe did not finish"
    report = json.loads(html.unescape(match[1]))
    assert not report["failures"], report
print(f"PASS: test_visual_details.py ({report['nodes']} nodes, 3 detail tabs each)")
