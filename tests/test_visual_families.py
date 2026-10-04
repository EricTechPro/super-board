#!/usr/bin/env python3
"""Owner acceptance: nested skill families and usable column navigation in Chrome."""
import copy
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

pack = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(pack / "skills/visual/scripts"))
import visual  # noqa: E402

binary = visual.find_chrome()
if not binary:
    print("SKIP: test_visual_families.py (no Chrome)")
    sys.exit(0)

model = json.loads((pack / "diagrams/skill-map.json").read_text())
model["kind"] = "map"
assert not visual.validate_map(model), visual.validate_map(model)
for field, value, message in (
    ("containers", [{"id": "a", "parent": "b"}, {"id": "b", "parent": "a"}], "cyclic container"),
    ("containers", [{"id": "a", "parent": "missing"}], "unknown parent"),
    ("containers", [{"id": "a", "nodeIds": ["sb-run"]}], "non-visible node"),
    ("containers", [{"id": "a"}, {"id": "a"}], "duplicate container"),
    ("browserOrder", ["missing"], "unknown view"),
    ("stepIds", ["sb-run"], "not in nodeIds"),
):
    invalid = copy.deepcopy(model)
    invalid["views"][0][field] = value
    assert any(message in error for error in visual.validate_map(invalid)), (field, value)
probe = r"""
(async () => {
  const failures = [], facts = {};
  const check = (ok, message) => { if (!ok) failures.push(message); };
  const $ = s => document.querySelector(s), all = s => [...document.querySelectorAll(s)];
  const diagnostic = () => {
    const el = $('.mit[data-v="super-board"]'), r = el?.getBoundingClientRect();
    return {hash:location.hash,ghosts:!!$('#m-ghosts'),fonts:document.fonts.status,columns:all('.mcol').length,
      rect:r?.toJSON(),scroll:$('.miller')?.scrollLeft,viewport:[innerWidth,innerHeight],
      target:r && document.elementFromPoint(r.left+r.width/2,r.top+r.height/2)?.outerHTML.slice(0,300)};
  };
  const waitFor = async (ready, name) => {
    const deadline = performance.now() + 6000;
    while (!ready()) {
      if (performance.now() >= deadline) throw Error('Timed out waiting for ' + name + ': ' + JSON.stringify(diagnostic()));
      await new Promise(r => setTimeout(r, 20));
    }
  };
  const viewReady = id => new URLSearchParams(location.hash.slice(1)).get('view') === id &&
    !!$('.mit[data-v="'+id+'"][aria-current="page"]');
  const click = el => { if (el) el.dispatchEvent(new MouseEvent('click', {bubbles:true})); };
  const box = el => { const b = el.getBBox(); return {x:b.x,y:b.y,w:b.width,h:b.height}; };
  const nodeBox = id => box($('.stage .node[data-id="'+id+'"] .n-body'));
  const frame = id => $('.stage .family[data-family="'+id+'"] .family-box');
  const contains = (a,b) => a.x < b.x && a.y < b.y && a.x+a.w > b.x+b.w && a.y+a.h > b.y+b.h;
  try {
    await waitFor(() => !$('#m-ghosts') && !!$('.mcol'), 'initial column browser');
    await waitFor(() => document.fonts.status === 'loaded', 'fonts');
    await document.fonts.ready;
    const collect = frame('collect-family'), board = frame('board-family');
    check(!!collect && !!board, 'root draws nested intake and board family boxes');
    if (collect && board) {
      check(contains(box(collect), box(board)), 'board container nests inside intake');
      for (const id of ['super-board','super-build','super-qa','super-review'])
        check(contains(box(board),nodeBox(id)), 'board contains '+id);
      for (const id of ['ui-refine-loop','visual'])
        check(!contains(box(collect),nodeBox(id)), id+' stays standalone');
      check(nodeBox('super-build').x < nodeBox('super-qa').x && nodeBox('super-qa').x < nodeBox('super-review').x, 'lanes read Build → QA → Review');
    }
    const column = all('.mcol').find(c => c.querySelector('[data-v="super-board"]'));
    check(!!column, 'browser exposes board family');
    if (column) {
      const buttons = [...column.querySelectorAll('.mit')];
      facts.rootOrder = buttons.map(b => b.dataset.v);
      check(facts.rootOrder.slice(0,7).join(',') === 'super-collect,super-board,super-build,super-qa,super-review,ui-refine-loop,visual', 'owner browser order');
      check(column.getBoundingClientRect().width >= 210, 'column has readable width');
      check(buttons.every(b => b.getBoundingClientRect().height >= 32), 'rows have >=32px click targets');
      check(buttons.every(b => getComputedStyle(b.querySelector('span')).whiteSpace !== 'nowrap'), 'labels wrap without truncation');
      const miller = $('.miller');
      check(getComputedStyle(miller).overflowX === 'auto', 'column browser scrolls horizontally');
      const button = column.querySelector('[data-v="super-board"]');
      // renderTree initially reveals the last column. Reveal this row synchronously,
      // then wait for the physical hit target, including the sidebar's initial layout.
      button.scrollIntoView({behavior:'instant',block:'nearest',inline:'nearest'});
      await waitFor(() => {
        const r = button.getBoundingClientRect();
        return document.elementFromPoint(r.left+r.width/2,r.top+r.height/2)?.closest('button') === button;
      }, 'physical board row');
      const r = button.getBoundingClientRect();
      const target = document.elementFromPoint(r.left+r.width/2,r.top+r.height/2);
      check(target && target.closest('button') === button, 'board row is physically clickable');
      click(target); await waitFor(() => viewReady('super-board'), 'board navigation');
      check(new URLSearchParams(location.hash.slice(1)).get('view') === 'super-board', 'board row opens its view');
      const childColumn = all('.mcol').find(c => c.querySelector('[data-v="sb-onboard"]'));
      facts.boardChildren = childColumn ? [...childColumn.querySelectorAll('.mit')].map(b => b.dataset.v) : [];
      check(facts.boardChildren.slice(0,3).join(',') === 'super-build,super-qa,super-review', 'board column lists its three lanes first');
      for (const id of ['sb-onboard','sb-lint','super-board-run','sb-status','sb-stop']) check(facts.boardChildren.includes(id), 'board column exposes '+id);
    }
    click($('.mit[data-v="ui-refine-loop"]')); await waitFor(() => viewReady('ui-refine-loop'), 'loop navigation');
    check(new URLSearchParams(location.hash.slice(1)).get('view') === 'ui-refine-loop', 'standalone loop is reachable');
    const loop = frame('refine-family');
    check(!!loop, 'loop has a family container');
    for (const [phase, child] of [['refine-brief','grilling'],['refine-check','impeccable'],['refine-fix','verbs-group'],['refine-review','humanizer']]) {
      const inner = frame(phase+'-family');
      check(!!inner, phase+' has a nested tools container');
      if (inner && loop) {
        check(contains(box(loop),box(inner)), phase+' nests in loop');
        check(contains(box(inner),nodeBox(child)), phase+' contains '+child);
      }
    }
    facts.mainSteps = all('.stage .node.main-step').map(n => n.dataset.id);
    check(facts.mainSteps.length === 6, 'loop preserves its six main steps');
    check($('#m-pillbtn .n').textContent === '6 steps', 'view counts primary steps separately from nested tools');
  } catch (e) { failures.push(e.stack || String(e)); }
  return {failures,facts};
})()
"""

# Virtual time advances timers before scrolling/layout is painted. Use CDP real time
# for physical family hits and the normal-motion production resize/animation path.
motion_probe = r"""
import {spawn} from 'node:child_process';
import {mkdtemp,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
const [binary,url,familyProbe]=process.argv.slice(1), delay=ms=>new Promise(r=>setTimeout(r,ms));
const profile=await mkdtemp(tmpdir()+'/visual-navigation-');
// Test normal motion explicitly: macOS CI can default to reduced motion.
const browser=spawn(binary,['--headless','--disable-gpu','--force-prefers-no-reduced-motion','--remote-debugging-port=0','--no-first-run','--no-default-browser-check','--user-data-dir='+profile,'about:blank'],{stdio:'ignore'});
const failures=[],facts={}; let ws;
const check=(ok,message)=>{if(!ok)failures.push(message);};
try {
  let port;
  for(let i=0;i<100;i++){try{port=(await readFile(profile+'/DevToolsActivePort','utf8')).split('\n')[0];break;}catch{}await delay(50);}
  if(!port)throw Error('Chrome debugger did not start');
  const tabs=await(await fetch('http://127.0.0.1:'+port+'/json')).json();
  ws=new WebSocket(tabs.find(t=>t.type==='page').webSocketDebuggerUrl);
  await new Promise(r=>ws.addEventListener('open',r,{once:true}));
  let next=0; const pending=new Map();
  ws.addEventListener('message',e=>{const d=JSON.parse(e.data);if(d.id){const p=pending.get(d.id);pending.delete(d.id);d.error?p.reject(Error(JSON.stringify(d.error))):p.resolve(d.result);}});
  const cdp=(method,params={})=>new Promise((resolve,reject)=>{const id=++next;pending.set(id,{resolve,reject});ws.send(JSON.stringify({id,method,params}));});
  const evaluate=async expression=>{const r=await cdp('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(r.exceptionDetails)throw Error(JSON.stringify(r.exceptionDetails));return r.result.value;};
  await cdp('Page.enable'); await cdp('Emulation.setDeviceMetricsOverride',{width:1440,height:1000,deviceScaleFactor:1,mobile:false});
  const diagnostic=()=>evaluate(`(()=>{const el=document.querySelector('.mit[data-v="super-board"]'),r=el?.getBoundingClientRect();return {hash:location.hash,ghosts:!!document.querySelector("#m-ghosts"),fonts:document.fonts.status,columns:document.querySelectorAll(".mcol").length,rect:r?.toJSON(),scroll:document.querySelector('.miller')?.scrollLeft,viewport:[innerWidth,innerHeight],target:r && document.elementFromPoint(r.left+r.width/2,r.top+r.height/2)?.outerHTML.slice(0,300)};})()`);
  const waitFor=async (expression,name)=>{const end=performance.now()+10000;while(!await evaluate(expression)){if(performance.now()>end)throw Error('Timed out waiting for '+name+': '+JSON.stringify(await diagnostic()));await delay(20);}};
  await cdp('Page.navigate',{url:url+'#shot=1'});
  await waitFor('window.__instant && !!document.querySelector(".mcol") && !document.querySelector("#m-ghosts")','family initial column browser');
  const family=await evaluate(familyProbe);
  failures.push(...family.failures); Object.assign(facts,family.facts);
  await cdp('Page.navigate',{url});
  await waitFor('!window.__instant && !!document.querySelector(".mcol") && !document.querySelector("#m-ghosts")','initial column browser');
  await waitFor('document.fonts.status === "loaded"','fonts');
  await evaluate('document.fonts.ready.then(()=>true)');
  check(await evaluate('!window.__instant && !matchMedia("(prefers-reduced-motion: reduce)").matches'),'normal motion is enabled without screenshot flags');
  const sidebarReady='Math.abs(document.querySelector("#m-tree").getBoundingClientRect().width-Math.min(parseFloat(document.body.style.getPropertyValue("--browser-width")),innerWidth*.38))<1';
  await waitFor(sidebarReady,'initial sidebar width');
  facts.beforeWidth=await evaluate('document.querySelector("#m-tree").getBoundingClientRect().width');
  const click=async id=>{
    await evaluate(`document.querySelector('.mit[data-v="${id}"]').scrollIntoView({behavior:'instant',block:'nearest',inline:'nearest'})`);
    await waitFor(`(()=>{const el=document.querySelector('.mit[data-v="${id}"]');const r=el.getBoundingClientRect();return document.elementFromPoint(r.left+r.width/2,r.top+r.height/2)?.closest('button')===el;})()`,'hittable '+id);
    const p=await evaluate(`(()=>{const r=document.querySelector('.mit[data-v="${id}"]').getBoundingClientRect();return{x:r.left+r.width/2,y:r.top+r.height/2};})()`);
    await cdp('Input.dispatchMouseEvent',{type:'mousePressed',...p,button:'left',clickCount:1});
    await cdp('Input.dispatchMouseEvent',{type:'mouseReleased',...p,button:'left',clickCount:1});
    await waitFor(`new URLSearchParams(location.hash.slice(1)).get('view')==='${id}' && !!document.querySelector('.mit[data-v="${id}"][aria-current="page"]')`,'completed '+id+' navigation');
    await waitFor(sidebarReady,'completed '+id+' sidebar width');
  };
  await click('super-board');
  facts.boardView=await evaluate('new URLSearchParams(location.hash.slice(1)).get("view")');
  facts.afterWidth=await evaluate('document.querySelector("#m-tree").getBoundingClientRect().width');
  check(facts.afterWidth>facts.beforeWidth,'board navigation triggers sidebar resizing');
  check(facts.boardView==='super-board','animated board navigation finishes its hash update');
  await click('ui-refine-loop');
  facts.nextView=await evaluate('new URLSearchParams(location.hash.slice(1)).get("view")');
  check(facts.nextView==='ui-refine-loop','resizing does not lock subsequent navigation');
  check(await evaluate('!!document.querySelector(".stage .node[data-id=refine-brief]")'),'second navigation mounts the requested view');
} catch(e) {failures.push(e.stack || String(e));}
finally {ws?.close();browser.kill('SIGKILL');await rm(profile,{recursive:true,force:true,maxRetries:5,retryDelay:100});}
console.log(JSON.stringify({failures,facts}));
"""

with tempfile.TemporaryDirectory() as directory:
    page = Path(directory) / "fixture.html"
    visual.write_page(page, model)
    node = shutil.which("node")
    if node and subprocess.run([node, "-e", "process.exit(typeof WebSocket === 'function' ? 0 : 1)"], capture_output=True).returncode == 0:
        result = subprocess.run([node, "--input-type=module", "-e", motion_probe, binary, page.as_uri(), probe],
                                capture_output=True, text=True, timeout=45)
        assert result.returncode == 0, result.stderr
        report = json.loads(result.stdout)
        assert not report["failures"], report
    else:
        print("SKIP: test_visual_families.py (needs Node with built-in WebSocket)")
        sys.exit(0)
print("PASS: test_visual_families.py (nested boxes, physical clicks, readable rows, animated navigation)")
