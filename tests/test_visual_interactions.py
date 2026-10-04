#!/usr/bin/env python3
"""Exercise card focus, detail lists, drill-down and reduced motion in a real browser."""
import html
import json
import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills" / "visual" / "scripts"))
import visual  # noqa: E402

binary = visual.find_chrome()
if not binary:
    print("SKIP: test_visual_interactions.py (no Chrome)")
    sys.exit(0)

model = {
    "kind": "map", "title": "Card focus fixture",
    "nodes": [
        {"id": "caller", "label": "Trigger", "kind": "public"},
        {"id": "hub", "label": "Run work", "kind": "public", "opensView": "inside",
         "what": "Classifies incoming work. Selects a build, QA or review lane. Keeps unrelated cards waiting.",
         "when": "The owner starts a wave. A resumed board has ready work.",
         "how": "Check each card first; delegate approved cards; collect the outcome.",
         "source": ["https://example.com/skill.md", "https://example.com/policy.md"]},
        {"id": "worker", "label": "Worker", "kind": "public"},
        {"id": "unrelated", "label": "Other work", "kind": "public"},
        {"id": "detail", "label": "Worker script", "kind": "script"},
    ],
    "edges": [{"id": "incoming", "from": "caller", "to": "hub", "label": "starts"},
              {"id": "outgoing", "from": "hub", "to": "worker", "label": "delegates"},
              {"id": "detail-edge", "from": "hub", "to": "detail", "label": "runs"}],
    "views": [{"id": "root", "parent": None, "title": "Focus", "nodeIds": ["caller", "hub", "worker", "unrelated"],
               "edges": ["incoming", "outgoing"], "nodeOverrides": {"hub": {"emphasis": True}}},
              {"id": "inside", "parent": "root", "title": "Inside work", "nodeIds": ["hub", "detail"], "edges": ["detail-edge"]},
              {"id": "process", "parent": "root", "title": "Main steps", "mainSteps": True,
               "nodeIds": ["caller", "hub", "worker"], "edges": ["incoming", "outgoing"],
               "layout": {"caller": [0, 0], "hub": [1, 0], "worker": [2, 0]}}],
}

probe = r"""
<style>* { transition-duration: 0s !important; }</style>
<script>
setTimeout(async () => {
  const failures = [], facts = {};
  const check = (ok, message) => { if (!ok) failures.push(message); };
  const $ = s => document.querySelector(s);
  const all = s => [...document.querySelectorAll(s)];
  const click = el => el.dispatchEvent(new MouseEvent('click', {bubbles:true}));
  const settle = () => new Promise(r => setTimeout(r, 350));
  try {
    const hub = $('.stage .node[data-id="hub"]');
    check(!!hub, 'fixture card mounted');
    check(hub.classList.contains('main-step'), 'explicit card emphasis survives normal flow layout');
    check(+getComputedStyle(hub.querySelector('.n-label')).fontWeight >= 700, 'emphasized card label is bolder');
    // Selection must animate its own edges even after the user turned global flow off.
    if ($('#m-stage').classList.contains('flowing')) click($('#m-flow'));
    click(hub); await settle();
    check(!$('#m-panel').hidden, 'click opens details');
    check(hub.classList.contains('sel'), 'clicked card is selected');
    check($('.stage .node[data-id="caller"]').classList.contains('nb'), 'incoming neighbor highlighted');
    check($('.stage .node[data-id="worker"]').classList.contains('nb'), 'outgoing neighbor highlighted');
    check(!$('.stage .node[data-id="unrelated"]').classList.contains('nb'), 'unrelated card stays outside focus');
    const dim = getComputedStyle($('.stage .node[data-id="unrelated"]')).opacity;
    check(+dim < .5, 'unrelated card is visibly dimmed');
    check(all('.stage .edge-g.hot').length === 2, 'both incident edges highlighted');
    const line = $('.stage .edge-g.hot .flowline');
    const motion = getComputedStyle(line);
    const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
    facts.reducedMotion = reduced; facts.flowAnimation = motion.animationName;
    check(reduced ? motion.animationName === 'none' : motion.animationName !== 'none', 'selected edge respects motion preference');
    check(reduced || +motion.opacity > 0, 'selected flowing dashes are visible with global flow off');
    const ports = all('.stage .n-port');
    check(ports.length >= 4, 'connections expose ports on their endpoint cards');
    facts.ports = ports.length;
    check(ports.every(p => !!p.closest('.node')), 'ports are owned by their endpoint cards');
    check(ports.filter(p => p.closest('.node').dataset.id === 'hub').length === 2, 'selected card owns each incident port');
    check(ports.filter(p => p.closest('.node').dataset.id === 'hub').every(p => p.classList.contains('hot')), 'selected ports visibly share edge focus');
    for (const key of ['what','when','how']) {
      click($('[data-tab="'+key+'"]'));
      const bullets = all('#m-pbody ul li');
      facts[key] = bullets.map(x => x.textContent);
      check(bullets.length >= 2 && bullets.length <= 4, key+' has 2–4 bullets');
      check(bullets.every(x => !x.textContent.includes('\n')), key+' bullets are one-line text');
      check(bullets.every(x => x.textContent.trim().length > 0), key+' has no empty bullets');
    }
    click($('[data-tab="links"]'));
    check(all('#m-pbody li').length >= 4, 'Links uses a list for sources and relationships');
    check(all('#m-pbody a').some(a => a.href === 'https://example.com/skill.md'), 'source remains a working link');
    click($('#m-stage')); await settle();
    check($('#m-panel').hidden, 'background click closes details');
    check(!$('#m-stage').classList.contains('focusing'), 'background click clears dimming');
    check(all('.stage .sel,.stage .nb,.stage .hot').length === 0, 'background click clears focus classes');
    hub.dispatchEvent(new MouseEvent('dblclick', {bubbles:true})); await settle();
    check(new URLSearchParams(location.hash.slice(1)).get('view') === 'inside', 'double click drills into child view');
    check(!!$('.stage .node[data-id="detail"]'), 'hidden script is reachable inside its step');
    click($('.mit[data-v="process"]')); await settle();
    check(new URLSearchParams(location.hash.slice(1)).get('view') === 'process', 'main-step view mounted');
    for (const edge of all('.stage .edge-g .edge')) {
      const length = edge.getTotalLength(), a = edge.getPointAtLength(0), b = edge.getPointAtLength(length);
      check(length <= Math.hypot(b.x-a.x,b.y-a.y) + .1, 'adjacent main-step connector is straight');
    }
  } catch (e) { failures.push(e.stack || String(e)); }
  const pre=document.createElement('pre'); pre.id='interaction-report'; pre.textContent=JSON.stringify({failures,facts}); document.body.appendChild(pre);
}, 150);
</script>
"""

with tempfile.TemporaryDirectory() as directory:
    page = Path(directory) / "fixture.html"
    visual.write_page(page, model)
    page.write_text(page.read_text().replace("</body>", probe + "</body>"))
    for reduced in (False, True):
        args = ["--virtual-time-budget=5000", "--window-size=1440,1000", "--dump-dom"]
        # Select both fixture preferences explicitly instead of inheriting the host OS.
        args.append("--force-prefers-reduced-motion" if reduced else "--force-prefers-no-reduced-motion")
        dom = visual.chrome(binary, *args, page.as_uri() + "#shot=1", done=lambda s: 'id="interaction-report"' in s)
        match = re.search(r'<pre id="interaction-report"[^>]*>(.*?)</pre>', dom, re.S)
        assert match, "interaction probe did not finish"
        report = json.loads(html.unescape(match[1]))
        assert report["facts"].get("reducedMotion") is reduced, report
        assert not report["failures"], report
print("PASS: test_visual_interactions.py (normal and reduced motion)")
