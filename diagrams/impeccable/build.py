# usage: python3 build.py <out.html>   (needs commands.html from: archify finalize architecture commands.json commands.html --quality showcase)
import html,sys,json
from data import *
out=sys.argv[1]; e=html.escape
src=open("commands.html",encoding="utf-8").read()
gname={g[0]:g[1].split(" · ")[0] for g in GROUPS}
ORDER=["ctx","plan","diag","fix","style","motion","fin","sys","util"]
cards=""
for g in ORDER:
    items=[c for c in C if c[2]==g]
    cs=""
    for cid,lab,_,_t,steps,inp,outp,req,feeds,ref in items:
        st="".join(f"<li>{e(s)}</li>" for s in steps)
        name="/impeccable" if cid=="menu" else lab
        cs+=f'''<details class="c g-{g}"><summary><code>{e(name)}</code><span class="t">{e(TRIG[cid])}</span><span class="d">{e(DEF[cid])}</span></summary>
<div class="more"><p class="pair"><b>Use with</b> {e(PAIR[cid])}</p><ol>{st}</ol><p><b>In</b> {e(inp)}<br><b>Out</b> {e(outp)}</p><p class="ref">reference/{e(ref)}</p></div></details>'''
    cards+=f'<div class="grp"><h3 class="g-{g}">{e(gname[g])}</h3>{cs}</div>'
FLOW=[("1","Context","init · document","ctx"),("2","Plan / build","shape · craft","plan"),("3","Diagnose","critique + audit","diag"),("4","Fix & style","harden … bolder, animate","fix"),("5","Finish","polish, always last","fin")]
flow="".join(f'<div class="step g-{g}"><span class="n">{n}</span><b>{e(t)}</b><small>{e(s)}</small></div>' for n,t,s,g in FLOW)
INFO={cid:{"def":DEF[cid],"pair":PAIR[cid]} for cid in DEF}
page=f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>impeccable commands map</title>
<style>
:root{{--bg:#f4f5f7;--fg:#0f172a;--muted:#64748b;--card:#fff;--line:#e2e8f0;
--ctx:#ea580c;--plan:#c2410c;--diag:#e11d48;--fix:#059669;--style:#0891b2;--motion:#0e7490;--fin:#475569;--sys:#7c3aed;--util:#d97706}}
@media (prefers-color-scheme:dark){{:root:not([data-theme="light"]){{--bg:#0b1020;--fg:#e2e8f0;--muted:#94a3b8;--card:#111827;--line:#1f2937;--fin:#94a3b8}}}}
:root[data-theme="dark"]{{--bg:#0b1020;--fg:#e2e8f0;--muted:#94a3b8;--card:#111827;--line:#1f2937;--fin:#94a3b8}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,sans-serif}}
main{{max-width:1440px;margin:0 auto;padding:24px 16px 48px}}
h1{{font-size:24px;margin:0 0 2px}} .sub{{color:var(--muted);margin:0 0 14px}}
h2{{font-size:16px;margin:26px 0 10px}}
iframe.d{{width:100%;border:0;display:block;height:1100px;border-radius:14px;background:var(--card)}}
{"".join(f".g-{g[0]}{{--c:var(--{g[0]})}}" for g in GROUPS)}
.flow{{display:grid;grid-template-columns:repeat(5,1fr);gap:8px}}
.step{{background:var(--card);border:1px solid var(--line);border-left:4px solid var(--c);border-radius:10px;padding:8px 12px;display:grid;grid-template-columns:auto 1fr;column-gap:8px}}
.step .n{{grid-row:span 2;font:700 20px/1 ui-monospace,Menlo,monospace;color:var(--c);align-self:center}} .step small{{color:var(--muted)}}
.grid{{columns:3 380px;column-gap:14px}} .grp{{break-inside:avoid;margin-bottom:12px}}
h3{{font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:var(--c);margin:0 0 4px}}
details.c{{background:var(--card);border:1px solid var(--line);border-left:3px solid var(--c);border-radius:8px;margin:0 0 4px}}
summary{{list-style:none;cursor:pointer;padding:6px 10px;display:grid;grid-template-columns:96px 1fr;column-gap:8px;align-items:baseline}}
summary::-webkit-details-marker{{display:none}}
summary code{{font:600 13px ui-monospace,Menlo,monospace}} summary .t{{font-size:11.5px;color:var(--c);font-weight:600;text-align:right;grid-column:2;grid-row:1}}
summary .d{{grid-column:1/3;color:var(--muted);font-size:12.5px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}}
details[open] summary .d{{white-space:normal;color:var(--fg)}}
.more{{padding:0 10px 8px;font-size:12.5px}} .more ol{{margin:4px 0;padding-left:18px}} .more p{{margin:4px 0}} .ref{{color:var(--muted);font:11px ui-monospace,Menlo,monospace}}
.pair b,.more p b{{color:var(--c)}}
.note{{color:var(--muted);font-size:12.5px;margin-top:18px;max-width:1100px}} code{{font:12.5px ui-monospace,Menlo,monospace}}
@media (max-width:760px){{.flow{{grid-template-columns:1fr}}}}
</style></head><body><main>
<h1>impeccable · slash commands</h1>
<p class="sub">v4.0.4 · {len(C)} commands · click a node for what it does and what to use it with.</p>
<iframe class="d" title="impeccable command map" srcdoc="{e(src,quote=True)}"></iframe>
<h2>Best-practice order</h2><div class="flow">{flow}</div>
<h2>Commands <small style="color:var(--muted);font-weight:400">· click to expand steps</small></h2>
<div class="grid">{cards}</div>
<p class="note">Mapped from <code>.agents/skills/impeccable</code> v4.0.4. BookKeepingApp's v4.4.0 adds <code>generate</code> (named-element variants in the live browser) and a single <code>scripts/impeccable</code> launcher; otherwise the same commands. <code>teach</code> = init; <code>craft</code> is deprecated (plain build requests run the same flow); audit and adapt use <code>*.native.md</code> on iOS/Android.</p>
</main>
<script>
var INFO={json.dumps(INFO)};
var CSS='.imp-def{{display:block;margin:.3rem 0 .2rem;font-size:.72rem;line-height:1.45;color:var(--text,inherit);white-space:normal;max-width:22rem}}.imp-def b{{display:block;margin-top:.25rem;font-size:.62rem;text-transform:uppercase;letter-spacing:.05em;opacity:.65}}';
function wire(f){{try{{var d=f.contentDocument;if(!d||d.__imp)return;var id=d.getElementById('focus-id'),det=d.getElementById('focus-detail');if(!id||!det)return;d.__imp=1;
var st=d.createElement('style');st.textContent=CSS;d.head.appendChild(st);
var box=d.createElement('span');box.className='imp-def';box.id='focus-def';det.parentNode.insertBefore(box,det.nextSibling);
function upd(){{var i=INFO[(id.textContent||'').trim()];box.hidden=!i;if(i){{box.innerHTML='';box.appendChild(d.createTextNode(i.def));var b=d.createElement('b');b.textContent='Use with';box.appendChild(b);box.appendChild(d.createTextNode(i.pair));}}}}
new MutationObserver(upd).observe(id,{{childList:true,characterData:true,subtree:true}});upd();}}catch(err){{}}}}
function fit(f){{try{{var d=f.contentDocument;if(!d||!d.body)return;var h=Math.max(d.documentElement.scrollHeight,d.body.scrollHeight);if(h>200)f.style.height=(h+4)+'px';}}catch(e){{}}}}
document.querySelectorAll('iframe.d').forEach(function(f){{f.addEventListener('load',function(){{wire(f);fit(f);setTimeout(function(){{wire(f);fit(f)}},600);setTimeout(function(){{fit(f)}},2000);}});}});
window.addEventListener('resize',function(){{document.querySelectorAll('iframe.d').forEach(fit)}});
</script></body></html>'''
open(out,"w",encoding="utf-8").write(page);print(out,len(page))
