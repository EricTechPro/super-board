"""Build diagrams/pstack/index.html: python3 gen.py  (stdlib only; reads pstack-data.json, content*.py, template.html, overview.b64)."""
import json, html, textwrap, re
from pathlib import Path
import content3, content4 as C4, content5 as C5
D = Path(__file__).parent
d = json.load(open(D / 'pstack-data.json'))
E = html.escape
cats = d['categories']; skills = d['skills']
sk = [s for s in skills if s['kind'] == 'skill']; pr = [s for s in skills if s['kind'] == 'principle']
AV = {'both':'Claude Code and Cursor','claude':'Claude Code only','cursor':'Cursor only'}
SHORT = {'both':'both','claude':'Claude port','cursor':'Cursor only'}
W = 1470; X0 = 22; CW = 156; GAP = 24; X1 = 212; NH = 58; ST = 66
def wrapw(t, n): return textwrap.wrap(t, n, break_long_words=False) or ['']
def wrapname(name):
    if len(name) <= 19: return [name]
    parts = name.split('-'); best = None
    for i in range(1, len(parts)):
        a = '-'.join(parts[:i]) + '-'; b = '-'.join(parts[i:])
        sc = max(len(a), len(b))
        if best is None or sc < best[0]: best = (sc, a, b)
    return [best[1], best[2]]
CALLN = {k: sum(1 for t in sum([[x for x in f if isinstance(x, list)] for f in v], []) for _ in t) for k, v in C4.CALLS.items()}
def ncalls(k):
    ids = set()
    for f in C4.CALLS[k]:
        for tk in f:
            if isinstance(tk, list): ids.update(x[1:] for x in tk)
    return len(ids)
NC = {k: ncalls(k) for k in C4.CALLS}
def icons(src, x, y):
    o = ''
    if src in ('both', 'claude'): o += f'<use href="#ic-claude" x="{x}" y="{y}" width="12" height="12"/>'; x += 15
    if src in ('both', 'cursor'): o += f'<use class="ic-cur" href="#ic-cursor" x="{x}" y="{y}" width="12" height="12"/>'
    return o
def node(s, x, y, w):
    c = s['category']; L = wrapname(s['name'])
    ty = y + (17 if len(L) == 1 else 14)
    tx = ''.join(f'<text class="nn" x="{x+9}" y="{ty+i*12}">{E(l)}</text>' for i, l in enumerate(L))
    trig = f'<text class="nt" x="{x+9}" y="{y+(32 if len(L)==1 else 38)}">{E(s["trigger"])}</text>'
    cls = f'nd c-{c}' + (' dash' if s['source'] == 'claude' else '') + (' dot' if s['source'] == 'cursor' else '')
    badge = ''
    if s['id'] in NC:
        badge = f'<rect class="bg" x="{x+w-47}" y="{y+NH-17}" width="40" height="12" rx="6"/><text class="bt" x="{x+w-27}" y="{y+NH-8}" text-anchor="middle">calls {NC[s["id"]]}</text>'
    return (f'<g class="{cls}" data-id="{E(s["id"])}" tabindex="0" role="button" aria-label="{E(s["name"])}, {AV[s["source"]]}{" (calls "+str(NC[s["id"]])+")" if s["id"] in NC else ""}"><title>{E(s["name"])} ({AV[s["source"]]})</title>'
            f'<rect x="{x}" y="{y}" width="{w}" height="{NH}" rx="8"/>{tx}{trig}{icons(s["source"], x+9, y+NH-16)}{badge}</g>')
rows = [cats[:7], cats[7:]]
colsk = lambda cid: [s for s in sk if s['category'] == cid and s['id'] != 'poteto-mode']
out = []; ytop = 46; y = ytop; rowinfo = []; centers = {}
for ri, row in enumerate(rows):
    hd = max(14 + len(wrapw(c['name'], 17)) * 15 + 12 for c in row)
    mx = max(len(colsk(c['id'])) for c in row)
    rh = hd + 6 + mx * ST + 4
    for i, c in enumerate(row):
        x = X1 + i * (CW + GAP); centers[c['id']] = x + CW / 2
        out.append(f'<g class="rg c-{c["id"]}" data-cat="{c["id"]}"><rect class="reg" x="{x}" y="{y}" width="{CW}" height="{rh}" rx="12"/></g>')
        out.append(f'<g class="hd c-{c["id"]}" data-id="grp:{c["id"]}" data-cat="{c["id"]}" tabindex="0" role="button" aria-label="Group: {E(c["name"])}"><title>Group: {E(c["name"])}. Tap for details.</title><rect x="{x+4}" y="{y+4}" width="{CW-8}" height="{hd-4}" rx="8"/>'
                   f'<line class="hdl" x1="{x+10}" y1="{y+hd-2}" x2="{x+CW-10}" y2="{y+hd-2}"/><text class="chev" x="{x+CW-18}" y="{y+22}">\u203a</text>')
        ty = y + 25
        for l in wrapw(c['name'], 17): out.append(f'<text class="rt" x="{x+11}" y="{ty}">{E(l)}</text>'); ty += 15
        out.append('</g>')
        for j, s in enumerate(colsk(c['id'])): out.append(node(s, x + 10, y + hd + 6 + j * ST, CW - 20))
        if i < len(row) - 1:
            ax = x + CW + 3
            out.append(f'<line class="arr" x1="{ax}" y1="{y+24}" x2="{ax+GAP-9}" y2="{y+24}" marker-end="url(#ah)"/>')
    rowinfo.append((y, rh, hd)); y += rh + 46
(y1, rh1, _), (y2, rh2, _) = rowinfo
# elbow
xe = X1 + 6 * (CW + GAP) + CW / 2; xs = X1 + CW / 2; ym = y1 + rh1 + 17
out.append(f'<path class="arr" d="M{xe} {y1+rh1+2} V{ym} H{xs-30} V{y2-6}" marker-end="url(#ah)"/>')
# router
rb = y2 + rh2
out.append(f'<g class="rg c-router" data-cat="router"><rect class="reg" x="{X0}" y="{ytop}" width="150" height="{rb-ytop}" rx="12"/></g>')
ry = ytop + 40; rs = [s for s in sk if s['id'] == 'poteto-mode'][0]
out.append(f'<g class="nd rt0 c-router" data-id="poteto-mode" tabindex="0" role="button" aria-label="poteto-mode router (calls {NC["poteto-mode"]})"><title>poteto-mode: the router</title>'
           f'<rect x="{X0+10}" y="{ry}" width="130" height="104" rx="10"/>'
           f'<rect class="tagbg" x="{X0+18}" y="{ry+9}" width="52" height="14" rx="7"/><text class="tagt" x="{X0+44}" y="{ry+19.5}" text-anchor="middle">ROUTER</text>'
           f'<text class="nn rn" x="{X0+18}" y="{ry+42}">poteto-mode</text><text class="bl rb" x="{X0+18}" y="{ry+58}">picks the right</text><text class="bl rb" x="{X0+18}" y="{ry+70}">playbook</text>'
           f'<rect class="bg" x="{X0+18}" y="{ry+82}" width="48" height="14" rx="7"/><text class="bt" x="{X0+42}" y="{ry+92}" text-anchor="middle">calls {NC["poteto-mode"]}</text></g>')
# fan-out
trunk = 196; busA = 26; busB = y1 + rh1 + 38; ynm = ry + 52
d1 = [centers[c] for c in C4.REACHED1]; d2 = [centers[c] + 34 for c in C4.REACHED2]
out.append(f'<path class="fan" d="M{X0+140} {ynm} H{trunk} V{busA} H{max(d1)}"/>')
out.append(f'<path class="fan" d="M{trunk} {ynm} V{busB} H{max(d2)}"/>')
for x in d1: out.append(f'<path class="fan" d="M{x} {busA} V{ytop-3}" marker-end="url(#ah2)"/>')
for x in d2: out.append(f'<path class="fan" d="M{x} {busB} V{y2-3}" marker-end="url(#ah2)"/>')
# principles lane
y3 = rb + 36
groups = d['principleGroups']
gw = (W - 2 * X0 - 24) // 5
gh = 36
mxp = max(len([p for p in pr if p['principleGroup'] == g['id']]) for g in groups)
lh = 48 + gh + mxp * 38 + 12
out.append(f'<g class="rg c-principles" data-cat="principles"><rect class="reg" x="{X0}" y="{y3}" width="{W-2*X0}" height="{lh}" rx="12"/><text class="rt" x="{X0+12}" y="{y3+26}">PRINCIPLES · 24 ONE-RULE SKILLS, APPLIED BY NAME, SEPARATE FROM THE FLOW</text></g>')
out.append(f'<g class="nd hw c-principles" data-id="__how" tabindex="0" role="button" aria-label="How principles work"><rect x="{W-X0-12-196}" y="{y3+8}" width="196" height="32" rx="16"/><text class="nn hwt" x="{W-X0-12-98}" y="{y3+28}" text-anchor="middle">How principles work</text></g>')
for gi, g in enumerate(groups):
    x = X0 + 12 + gi * gw
    out.append(f'<g class="rg c-principles" data-cat="principles"><rect class="reg sub" x="{x}" y="{y3+48}" width="{gw-10}" height="{lh-48-10}" rx="9"/><text class="rt gt" x="{x+10}" y="{y3+68}">{E(g["name"])}</text>')
    out.append('</g>')
    for j, p in enumerate([p for p in pr if p['principleGroup'] == g['id']]):
        out.append(f'<g class="nd c-principles" data-id="{E(p["id"])}" tabindex="0" role="button" aria-label="{E(p["name"])}"><title>{E(p["name"])}</title><rect x="{x+8}" y="{y3+48+gh+j*38}" width="{gw-26}" height="32" rx="7"/><text class="nn pn" x="{x+17}" y="{y3+48+gh+j*38+20}">{E(p["name"])}</text></g>')
H = y3 + lh + 10
SVG = (f'<svg id="map" viewBox="0 0 {W} {H}" role="group" aria-label="pstack workflow diagram" xmlns="http://www.w3.org/2000/svg"><defs>'
       '<symbol id="ic-claude" viewBox="0 0 24 24"><g stroke="#d97757" stroke-width="3.2" stroke-linecap="round"><path d="M12 2.5v19M2.5 12h19M5.3 5.3l13.4 13.4M18.7 5.3L5.3 18.7"/></g></symbol>'
       '<symbol id="ic-cursor" viewBox="0 0 24 24"><path d="M12 2.2l8.5 4.9v9.8L12 21.8l-8.5-4.9V7.1z" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"/><path d="M12 12L3.8 7.2M12 12l8.2-4.8M12 12v9.5" stroke="currentColor" stroke-width="1.6" fill="none"/><path d="M12 12l4.2-2.4v4.8z" fill="currentColor"/></symbol>'
       '<marker id="ah" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0 0L10 5L0 10z" class="ahp"/></marker>'
       '<marker id="ah2" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0 0L10 5L0 10z" class="ahr"/></marker></defs>' + ''.join(out) + '</svg>')

# ---- data
def apply_b(txt, words):
    parts = re.split(r'(==.*?==)', txt)
    for w in words:
        for i, p in enumerate(parts):
            if not p.startswith('==') and w in p: parts[i] = p.replace(w, '**' + w + '**', 1); break
    return ''.join(parts)
for s in skills:
    if s['kind'] == 'skill':
        c = content3.SK[s['id']]
        s['when'] = c['when']; s['whatItIs'] = c['is_']; s['steps'] = c['steps']; s['flows'] = c['flows']; s['output'] = c['out']
        if s['id'] in C4.CALLS: s['calls'] = C4.CALLS[s['id']]; s['ncalls'] = NC[s['id']]
        if s['id'] in C4.DIAGS:
            f, lab = C4.DIAGS[s['id']]; t, fl = C4.DIAG_FLOWS[f]
            s['diag'] = {'title': t, 'flows': fl, 'url': 'https://github.com/cursor/plugins/blob/main/pstack/docs/guide/' + f, 'src': lab}
    else:
        w, i, bw, mk = content3.PR[s['id'][10:]]
        s['when'] = w; s['whatItIs'] = i
        s['inPractice'] = [apply_b(('==' + x + '==') if x == mk else x, bw) for x in s['inPractice']]
for s in skills:
    if s['kind'] == 'skill': s['ex'] = list(C5.EX[s['id']])
ps = [s for s in skills if s['id'] == 'poteto-mode'][0]
ps['picks'] = C4.PICKS
ps['diag'] = {'title': 'Router flow', 'flows': [["Your prompt","poteto-mode","Read the Principles section",{'stack':["Read-only question: Investigation","Defect: Bug fix","New behavior: Feature","Structure only: Refactoring","Measured slowness: Perf issue","Large work or no match: figure-it-out"]},"Verify and report"]], 'url': C4.GUIDE + '02-poteto-mode.md', 'src': 'guide ch. 2'}
keep = ('ex','id','name','command','trigger','category','whatItIs','steps','output','claudeCode','codex','handsOffTo','source','url','claudeUrl','inPractice','principleGroup','note','kind','summary','when','flows','calls','ncalls','picks','diag')
ginfo = {}
for c in cats:
    items = [[s['trigger'], s['id']] for s in colsk(c['id'])]
    ginfo[c['id']] = {'name': c['name'], 'blurb': c['blurb'], 'routes': C4.ROUTES[c['id']], 'items': items, 'ex': list(C5.GEX[c['id']])}
DATA = {'skills': {s['id']: {k: s[k] for k in keep if k in s} for s in skills}, 'groupsInfo': ginfo,
        'cats': {c['id']: c['name'] for c in cats}, 'groups': {g['id']: g for g in groups}, 'how': d['principlesHowItWorks'], 'order': d['order'],
        'img': 'data:image/webp;base64,' + (D / 'overview.b64').read_text()}
js = json.dumps(DATA, ensure_ascii=False, separators=(',', ':')).replace('</', '<\\/')
catcss = ''.join(f'.c-{c["id"]}{{--c:var(--k-{c["color"]})}}' for c in cats) + '.c-principles{--c:var(--k-fuchsia)}.c-router{--c:var(--k-router)}'
L = dict(amber='#b45309',blue='#2563eb',slate='#475569',violet='#7c3aed',indigo='#4f46e5',green='#15803d',teal='#0f766e',lime='#4d7c0f',orange='#c2410c',cyan='#0e7490',red='#dc2626',pink='#be185d',gray='#6b7280',fuchsia='#a21caf',router='#7e22ce')
Dk = dict(amber='#fbbf24',blue='#60a5fa',slate='#94a3b8',violet='#a78bfa',indigo='#818cf8',green='#34d399',teal='#2dd4bf',lime='#a3e635',orange='#fb923c',cyan='#22d3ee',red='#f87171',pink='#f472b6',gray='#9ca3af',fuchsia='#e879f9',router='#c084fc')
lt = ''.join(f'--k-{k}:{v};' for k, v in L.items()); dk = ''.join(f'--k-{k}:{v};' for k, v in Dk.items())
order = ''.join(f'<div class="step"><i>{o["n"]}</i><span><b>{E(o["name"])}</b><small>{E(o["sub"])}</small></span></div>' for o in d['order'])
lab = {'https://flaviocopes.com/pstack/':'Flavio Copes','https://github.com/michael-denyer/pstack-claude':'Claude port repo','https://github.com/cursor/plugins/tree/main/pstack':'Cursor plugin','https://x.com/poteto/status/2094457600259842065':'poteto on X','https://cursor.com/marketplace/cursor/pstack':'Cursor marketplace','https://github.com/cursor/plugins/blob/main/pstack/docs/guide/README.md':'Official guide','https://github.com/michael-denyer/pstack-claude/blob/main/docs/reference.md':'Port reference'}
fl = ' · '.join(f'<a href="{E(u)}" target="_blank" rel="noopener">{lab[u]}</a>' for u in d['links'])
t = (D / 'template.html').read_text()
for k, v in {'%%SVG%%': SVG, '%%ORDER%%': order, '%%DATA%%': js, '%%CATCSS%%': catcss, '%%LT%%': lt, '%%DK%%': dk, '%%FLINKS%%': fl}.items(): t = t.replace(k, v)
# standalone page: <title> and <style> go in <head>; the rest is the body
head = re.match(r"\s*(<title>.*?</title>)\s*(<style>.*?</style>)", t, re.S)
body = t[head.end():]
doc = ('<!doctype html><html lang="en"><head><meta charset="utf-8">'
       '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">'
       + head.group(1) + head.group(2) + '</head><body>' + body + '</body></html>')
(D / 'index.html').write_text(doc, encoding='utf-8')
print('index.html', len(doc))
