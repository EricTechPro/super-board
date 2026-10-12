# usage: python3 gen.py && python3 build.py index.html   (stdlib only; no Archify needed)
import html, json, sys
from pathlib import Path
from data import *
out = sys.argv[1]; e = html.escape
root = Path(__file__).resolve().parent
svg = (root / "diagram.svg").read_text(encoding="utf-8")
commands = {c[0]: c for c in C}
import re
def md(t):
    t = e(t)
    t = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", t)
    t = re.sub(r"==(.+?)==", r"<mark>\1</mark>", t)
    t = re.sub(r"\[\[(\w+)\]\]", lambda m: f'<button type="button" class="chip g-{commands[m.group(1)][2]}" data-go="{m.group(1)}">{"/impeccable" if m.group(1)=="menu" else commands[m.group(1)][1]}</button>', t)
    t = re.sub(r"`(.+?)`", r"<code>\1</code>", t)
    return t
def step(cid, t):
    h = HOWH.get(cid)
    out = e(t)
    if h and h in t:
        out = e(t).replace(e(h), "<mark>" + e(h) + "</mark>", 1)
    first = t.split(" ")[0]
    if not out.startswith("<mark>") and len(first) > 3:
        out = "<b>" + e(first) + "</b>" + out[len(e(first)):]
    return out
def flows(cid):
    rows = ""
    for fl in FLOWS[cid]:
        rows += '<div class="fl">' + '<i>→</i>'.join(f'<span class="pill{" cmd" if k == 0 and t.startswith("/") else ""}">{md(t)}</span>' for k, t in enumerate(fl)) + "</div>"
    return rows
def exh(cid):
    t, w, g = EX[cid]
    return f'<div class="exb"><div><b>You type</b> <code>{e(t)}</code></div><div><b>What happens</b> {e(w)}</div><div><b>You get</b> {e(g)}</div></div>'
INFO = {}
for cid, c in commands.items():
    INFO[cid] = {"name": "/impeccable" if cid == "menu" else c[1], "g": c[2], "tag": TRIG[cid], "when": md(WHEN[cid]),
                 "what": md(ONE[cid]), "how": [step(cid, t) for t in HOW[cid]], "flows": flows(cid),
                 "get": md(GET[cid]), "next": md(NEXT[cid]) if NEXT[cid] else None,
                 "ex": exh(cid),
                 "calls": ('<div class="fl"><span class="pill cmd">' + e("/impeccable" if cid == "menu" else c[1]) + '</span><i>→</i>' + " ".join(md(f"[[{k}]]") for k, _ in CALLS[cid]) + '</div>' + ("".join(f'<p class="why">{md(f"[[{k}]]")} {e(w)}</p>' for k, w in CALLS[cid] if w))) if cid in CALLS else None}
INFO["menu"]["router"] = True
INFO["menu"]["g"] = "rt"
INFO["menu"]["flows"] = "".join('<div class="fl">' + '<i>→</i>'.join(f'<span class="pill">{md(t)}</span>' for t in r) + "</div>" for r in ROUTE_PICKS)
INFO["menu"]["words"] = "".join('<div class="fl">' + '<i>→</i>'.join(f'<span class="pill">{md(t)}</span>' for t in r) + "</div>" for r in ROUTE_WORDS)
for group, title, subtitle, ids in STAGES:
    x = STAGEX[group]
    INFO["stage_" + group] = {"stage": True, "name": title, "g": group, "what": md(x["for"]),
        "pick": "".join(f'<div class="pk"><span>{e(t)}</span><i>→</i>{md("[[" + cid + "]]")}</div>' for cid, t in x["pick"]),
        "runT": x["runT"], "run": md(x["run"]),
        "ex": (lambda s: f'<div class="exb"><div><b>Situation</b> {e(s[0])}</div><div><b>You type</b> <code>{e(s[1].replace("Run ", ""))}</code></div><div><b>You get</b> {e(s[2])}</div></div>')(STAGE_EX[group])}
FLOW = [("1", "Setup", "init · document · extract", "ctx"), ("2", "Plan / build", "shape · craft", "plan"),
        ("3", "Diagnose", "critique + audit", "diag"), ("4", "Fix & style", "harden … bolder, animate", "fix"),
        ("5", "Finish", "polish, always last", "fin")]
flow = "".join(f'<div class="step g-{g}"><span class="n">{n}</span><b>{e(t)}</b><small>{e(s)}</small></div>' for n, t, s, g in FLOW)
colors = "".join(f".g-{g[0]}{{--c:var(--{g[0]})}}" for g in GROUPS) + ".g-rt{--c:var(--rt)}"
page = f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>impeccable commands map</title>
<style>
:root{{--bg:#f4f5f7;--fg:#0f172a;--muted:#64748b;--card:#fff;--line:#e2e8f0;
--ctx:#ea580c;--plan:#c2410c;--diag:#e11d48;--fix:#059669;--style:#0891b2;--motion:#0e7490;--fin:#475569;--sys:#7c3aed;--rt:#7c3aed;--util:#d97706;--mkb:#fde68a;--mkf:#1f2937}}
@media (prefers-color-scheme:dark){{:root:not([data-theme="light"]){{--bg:#0b1020;--fg:#e2e8f0;--muted:#94a3b8;--card:#111827;--line:#1f2937;--ctx:#fbbf24;--plan:#fb923c;--diag:#fb7185;--fix:#34d399;--style:#22d3ee;--motion:#22d3ee;--fin:#94a3b8;--util:#a78bfa;--rt:#a78bfa;--mkb:rgba(251,191,36,.32);--mkf:#fef3c7}}}}
:root[data-theme="dark"]{{--bg:#0b1020;--fg:#e2e8f0;--muted:#94a3b8;--card:#111827;--line:#1f2937;--ctx:#fbbf24;--plan:#fb923c;--diag:#fb7185;--fix:#34d399;--style:#22d3ee;--motion:#22d3ee;--fin:#94a3b8;--util:#a78bfa;--rt:#a78bfa;--mkb:rgba(251,191,36,.32);--mkf:#fef3c7}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,sans-serif}}
main{{max-width:1440px;margin:0 auto;padding:24px 16px 32px}}
h1{{font-size:24px;margin:0 0 2px}} .sub{{color:var(--muted);margin:0 0 14px}}
{colors}
.canvas{{position:relative;background:var(--card);border:1px solid var(--line);border-radius:14px;padding:8px}}
.tools{{display:flex;justify-content:space-between;align-items:center;gap:8px;padding:2px 4px 6px;color:var(--muted);font-size:12.5px}}
.tools button{{white-space:nowrap;font:inherit;color:var(--fg);background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:3px 10px;cursor:pointer}}
.scroll{{overflow-x:auto}}
svg.map{{display:block;width:100%;min-width:1000px;height:auto}}
svg.map text{{font-family:inherit;fill:var(--fg)}}
.r rect{{fill:none;stroke:var(--c);stroke-opacity:.55;stroke-dasharray:5 5}}
.r text{{font-size:12px;font-weight:700;fill:var(--c);text-transform:uppercase;letter-spacing:.04em}}
.n{{cursor:pointer;outline:none}}
.n rect{{fill:color-mix(in srgb,var(--c) 13%,var(--card));stroke:var(--c);stroke-width:1.5}}
.n.stage rect{{fill:color-mix(in srgb,var(--c) 24%,var(--card));stroke-width:2}}
.n:hover rect,.n:focus-visible rect{{stroke-width:3}} .n.on rect{{stroke-width:3.5;fill:color-mix(in srgb,var(--c) 30%,var(--card))}}
.t1{{font:600 14px ui-monospace,Menlo,monospace}} .t2{{font-size:11px;fill:var(--muted)!important}}
.arrow{{stroke:var(--muted);stroke-width:1.6;fill:none}} .ahead{{fill:var(--muted)}}
dialog.pop{{position:fixed;inset:0;margin:auto;width:min(760px,calc(100vw - 32px));max-width:none;max-height:88vh;overflow:auto;overscroll-behavior:contain;background:var(--card);color:var(--fg);border:1px solid var(--line);border-top:5px solid var(--c);border-radius:16px;padding:0;box-shadow:0 30px 90px rgba(0,0,0,.45),0 6px 18px rgba(0,0,0,.25);font-size:15.5px;line-height:1.5}}
dialog.pop::backdrop{{background:rgba(2,6,23,.6);backdrop-filter:blur(4px);-webkit-backdrop-filter:blur(4px)}}
.pb{{padding:20px 26px 26px}}

.pop .gt{{display:block;font:700 11px -apple-system,sans-serif;letter-spacing:.08em;color:var(--muted)}} .pop h2{{font:700 22px ui-monospace,Menlo,monospace;margin:0 40px 8px 0;color:var(--c)}}
.pop .x{{position:sticky;top:0;float:right;width:38px;height:38px;margin:-6px -10px 0 0;border:0;border-radius:10px;background:var(--card);color:var(--muted);font-size:28px;line-height:1;cursor:pointer;z-index:2}}
.pop .x:hover{{background:var(--bg)}}
.pop h3{{font-size:12px;text-transform:uppercase;letter-spacing:.07em;color:var(--c);margin:16px 0 5px}}
.pop p{{margin:0}} .pop ul{{margin:0;padding-left:20px}} .pop li{{margin:3px 0}}
.pop .tag{{display:inline-block;background:color-mix(in srgb,var(--c) 16%,var(--card));color:var(--c);font-weight:600;border-radius:99px;padding:1px 10px}}
.pop .nx{{margin-top:10px;padding-top:8px;border-top:1px solid var(--line)}} .pop .nx b{{color:var(--c)}}
mark{{background:var(--mkb);color:var(--mkf);border-radius:3px;padding:0 3px}}
.pop ol{{margin:0;padding-left:20px}} .pop ol li{{margin:3px 0;padding-left:2px}} .pop ol li::marker{{color:var(--c);font-weight:700}}
.pop code{{font:13.5px ui-monospace,Menlo,monospace;background:var(--bg);border:1px solid var(--line);border-radius:5px;padding:0 5px}}
.exb{{background:var(--bg);border:1px dashed var(--c);border-radius:10px;padding:10px 14px}} .exb div{{margin:4px 0;display:grid;grid-template-columns:104px 1fr;gap:8px}} .exb code{{justify-self:start;overflow-wrap:anywhere}} .exb b{{color:var(--c);font-size:12.5px}} .pop h3 .exm{{font-size:10.5px;font-weight:700;letter-spacing:.05em;background:var(--c);color:var(--card);border-radius:99px;padding:1px 8px;margin-left:6px;vertical-align:1px}}
.fl{{display:flex;flex-wrap:wrap;align-items:center;gap:4px 3px;margin:0 0 8px}} .fl i{{font-style:normal;color:var(--muted);font-weight:700}}
.pill{{background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:2px 8px;font-size:12px}}
.pill.cmd{{background:color-mix(in srgb,var(--c) 16%,var(--card));border-color:var(--c);color:var(--c);font:700 12px ui-monospace,Menlo,monospace}}
.chip{{font:600 12px ui-monospace,Menlo,monospace;color:var(--c);background:color-mix(in srgb,var(--c) 12%,var(--card));border:1px solid var(--c);border-radius:99px;padding:2px 9px;margin:1px 2px;cursor:pointer;min-height:26px}}
.chip:hover{{background:color-mix(in srgb,var(--c) 26%,var(--card))}}
.stagehead{{cursor:pointer;outline:none}} .stagehead .s1{{font-size:9.5px;letter-spacing:.08em;font-weight:700;fill:var(--muted)!important}}
.stagehead .s2{{font-size:17px;font-weight:800;fill:var(--c)!important}} .stagehead .s3{{font-size:11px;fill:var(--muted)!important;font-weight:400}}
.stagehead .bar{{fill:var(--c);opacity:.8}} .stagehead:hover .s2,.stagehead:focus-visible .s2,.stagehead.on .s2{{text-decoration:underline}}
.router{{cursor:pointer;outline:none}} .router rect{{fill:color-mix(in srgb,var(--rt) 18%,var(--card));stroke:var(--rt);stroke-width:3}} .router .s1{{font-size:10px;letter-spacing:.1em;font-weight:800;fill:var(--rt)!important}}
.router:hover rect,.router:focus-visible rect,.router.on rect{{stroke-width:4.5}} .bus{{stroke:var(--rt);stroke-width:1.6;fill:none;stroke-dasharray:4 3;opacity:.8}}
.pk i{{font-style:normal;color:var(--muted);font-weight:700}}
.badge rect{{fill:var(--c)}} .badge text{{font-size:10px;font-weight:700;fill:var(--card)!important}}
.pk{{display:flex;align-items:center;flex-wrap:wrap;gap:2px 6px;margin:2px 0}} .pk span{{font-size:12.5px}}
.pop .why{{font-size:13.5px;color:var(--muted);margin:2px 0}}
.flow{{display:grid;grid-template-columns:repeat(5,1fr);gap:8px;margin-top:8px}}
.step{{background:var(--bg);border:1px solid var(--line);border-left:4px solid var(--c);border-radius:10px;padding:6px 10px;display:grid;grid-template-columns:auto 1fr;column-gap:8px}}
.step .n{{grid-row:span 2;font:700 18px/1 ui-monospace,Menlo,monospace;color:var(--c);align-self:center}} .step small{{color:var(--muted)}}
@media (max-width:760px){{
 main{{padding:16px 12px 24px}} h1{{font-size:20px}}
 .flow{{grid-template-columns:1fr 1fr}}
 dialog.pop{{width:100vw;max-width:100vw;height:100dvh;max-height:100dvh;border-radius:0;border-width:5px 0 0}} .pb{{padding:16px 16px 28px}} .pop h2{{font-size:20px}}
}}
</style></head><body><main>
<h1>impeccable · slash commands</h1>
<p class="sub">v{VERSION} · {len(C) - 1} commands + the /impeccable router · read left to right, then tap anything to see how it works.</p>
<div class="canvas" id="canvas">
<div class="tools"><span>Setup → plan / build → diagnose → fix &amp; style → polish last</span><button id="theme" type="button" aria-label="Toggle light or dark">Light / dark</button></div>
<div class="scroll">{svg}</div>
<div class="flow" aria-label="Best-practice order">{flow}</div>
<dialog class="pop" id="pop" aria-labelledby="pt"></dialog>
</div>
</main>
<script>
var INFO={json.dumps(INFO)};
var canvas=document.getElementById('canvas'),pop=document.getElementById('pop'),cur=null,lastNode=null;
function esc(s){{var d=document.createElement('div');d.textContent=s;return d.innerHTML}}
function close(){{if(pop.open)pop.close()}}
pop.addEventListener('close',function(){{if(cur)cur.classList.remove('on');cur=null;if(lastNode&&lastNode.focus)lastNode.focus({{preventScroll:true}})}});
function open(n){{var i=INFO[n.dataset.id];if(!i)return;if(cur)cur.classList.remove('on');cur=n;lastNode=n;n.classList.add('on');
 pop.className='pop g-'+i.g;
 var h='<button class="x" type="button" aria-label="Close">×</button><h2 id="pt">'+(i.stage?'<small class="gt">STAGE · GROUP</small>':'')+esc(i.name)+'</h2>';
 if(i.stage){{h+='<h3>What this stage is for</h3><p>'+i.what+'</p><h3>Not a command</h3><p><mark>You cannot run "'+esc(i.name)+'".</mark> It is a <b>group label</b>. You run the <b>commands inside it</b>.</p><h3>Which one to pick</h3><p><b>No router for this stage yet.</b> Pick by symptom:</p>'+i.pick+'<h3>'+i.runT+'</h3><p>'+i.run+'</p><h3>Example<span class="exm">EXAMPLE</span></h3>'+i.ex;}}else{{
 if(i.when)h+='<h3>When to use it</h3><p>'+i.when+' <span class="tag">'+esc(i.tag)+'</span></p>';
 h+='<h3>What it is</h3><p>'+i.what+'</p>';
 if(i.chips)h+='<h3>Commands in this stage</h3><p>'+i.chips+'</p>';
 if(i.how)h+='<h3>How it works</h3><ol>'+i.how.map(function(s){{return'<li>'+s+'</li>'}}).join('')+'</ol>';
 if(i.ex&&!i.stage)h+='<h3>Example<span class="exm">EXAMPLE</span></h3>'+i.ex;
 if(i.router){{h+='<h3>How it picks</h3><p class="why">It reads your project, then follows the first match:</p>'+i.flows+'<h3>Or just say it in words</h3>'+i.words}}else if(i.flows)h+='<h3>Behind the scenes</h3>'+i.flows;
 if(i.calls)h+='<h3>Calls these</h3>'+i.calls;
 if(i.get)h+='<h3>What you get</h3><p>'+i.get+'</p>';
 if(i.next)h+='<p class="nx"><b>Next:</b> '+i.next+'</p>';}}
 pop.innerHTML='<div class="pb">'+h+'</div>';if(!pop.open)pop.showModal();pop.scrollTop=0;pop.querySelector('.x').onclick=close}}
pop.addEventListener('click',function(ev){{if(ev.target===pop){{close();return}}var g=ev.target.closest('[data-go]');if(g){{var t=canvas.querySelector('svg [data-id="'+g.dataset.go+'"]');if(t)open(t)}}}});
canvas.addEventListener('click',function(ev){{var n=ev.target.closest('[data-id]');if(n)open(n)}});
canvas.addEventListener('keydown',function(ev){{var n=ev.target.closest&&ev.target.closest('[data-id]');if(n&&(ev.key==='Enter'||ev.key===' ')){{ev.preventDefault();open(n)}}}});



document.getElementById('theme').onclick=function(){{var r=document.documentElement,d=r.getAttribute('data-theme')||(matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light');r.setAttribute('data-theme',d==='dark'?'light':'dark')}};
</script></body></html>'''
Path(out).write_text(page, encoding="utf-8"); print(out, len(page))
