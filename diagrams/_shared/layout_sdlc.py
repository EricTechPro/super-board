"""Layout `sdlc`: six stage layers (Plan > Design > Build > Test > Deploy > Maintain), categories side by side with chains of skills,
plus an Anytime band. build(data) -> dict for build_skillmap.py. Schema: see _shared/README.md and the map.json files."""
import html, json, math, re, textwrap
E = html.escape
STAGES = ["plan", "design", "build", "test", "deploy", "maintain"]
SNAME = dict(plan="Plan", design="Design", build="Build", test="Test", deploy="Deploy", maintain="Maintain")
LIGHT = dict(plan="#b45309", design="#7c3aed", build="#2563eb", test="#15803d", deploy="#c2410c", maintain="#0e7490", anytime="#475569")
DARK = dict(plan="#fbbf24", design="#a78bfa", build="#60a5fa", test="#34d399", deploy="#fb923c", maintain="#22d3ee", anytime="#94a3b8")
W = 1440; X0 = 16; NW = 132; NH = 64; GX = 30; GY = 26; PADX = 14; CW = 330

ICON_ALL = '<svg viewBox="0 0 24 24" aria-hidden="true" fill="currentColor"><rect x="3" y="3" width="7.5" height="7.5" rx="1.5"/><rect x="13.5" y="3" width="7.5" height="7.5" rx="1.5"/><rect x="3" y="13.5" width="7.5" height="7.5" rx="1.5"/><rect x="13.5" y="13.5" width="7.5" height="7.5" rx="1.5"/></svg>'
import platforms
ICON_CL = platforms.svg("claude-code")
ICON_CU = platforms.svg("cursor")
ICON_CODEX = platforms.svg("codex")

STAGE_ICON = dict(
 plan='<circle cx="12" cy="12" r="9"/><path d="M15.5 8.5l-2 5-5 2 2-5z"/>',
 design='<path d="M4 20l1-4L16 5l3 3L8 19z"/><path d="M14 7l3 3"/>',
 build='<path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/>',
 test='<path d="M10 2v7.5a2 2 0 0 1-.2.9L4.7 20.5a1 1 0 0 0 .9 1.5h12.8a1 1 0 0 0 .9-1.5l-5.1-10.1a2 2 0 0 1-.2-.9V2"/><path d="M8.5 2h7M7 16h10"/>',
 deploy='<path d="M4.5 16.5c-1.5 1.26-2 5-2 5s3.74-.5 5-2c.71-.84.7-2.13-.09-2.91a2.18 2.18 0 0 0-2.91-.09z"/><path d="m12 15-3-3a22 22 0 0 1 2-3.95A12.88 12.88 0 0 1 22 2c0 2.72-.78 7.5-6 11a22.35 22.35 0 0 1-4 2z"/><path d="M9 12H4s.55-3.03 2-4c1.62-1.08 5 0 5 0M12 15v5s3.03-.55 4-2c1.08-1.62 0-5 0-5"/>',
 maintain='<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/><path d="m9 12 2 2 4-4"/>',
 anytime='<path d="M6 16c5 0 7-8 12-8a4 4 0 0 1 0 8c-5 0-7-8-12-8a4 4 0 1 0 0 8"/>',
 crosshair='<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3"/><path d="M12 1v5M12 18v5M1 12h5M18 12h5"/>',
 braces='<path d="M8 3H7a2 2 0 0 0-2 2v5a2 2 0 0 1-2 2 2 2 0 0 1 2 2v5a2 2 0 0 0 2 2h1M16 3h1a2 2 0 0 1 2 2v5a2 2 0 0 0 2 2 2 2 0 0 0-2 2v5a2 2 0 0 1-2 2h-1"/>',
 filetext='<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6M8 13h8M8 17h8M8 9h2"/>')
# Optional per-map wording (meta.labels) and per-stage name/icon overrides; the defaults keep the SDLC maps unchanged.
LABELS = dict(stage="Stage", anytime="Anytime", item="skill", items="skills", stageNote="**This is a stage, not a skill.** You run the skills inside its categories.",
              anyNote="**Not tied to one stage.** Use these at any point.")

def wrapname(n, lim=17):
    if len(n) <= lim: return [n]
    parts = n.split('-'); best = None
    for i in range(1, len(parts)):
        a = '-'.join(parts[:i]) + '-'; b = '-'.join(parts[i:]); sc = max(len(a), len(b))
        if best is None or sc < best[0]: best = (sc, a, b)
    return list(best[1:]) if best else [n[:lim]]

def build(data, mdir):
    meta = data["meta"]; skills = data["skills"]; cats = data["categories"]; stages = {s["id"]: s for s in data["stages"]}
    SN = {k: stages.get(k, {}).get("name") or v for k, v in SNAME.items()}; LB = {**LABELS, **meta.get("labels", {})}
    skill_stage = {}
    for c in cats:
        for sid in c["chain"]: skill_stage.setdefault(sid, c["stage"])
    for g in data.get("anytime", []):
        for sid in g["items"]: skill_stage.setdefault(sid, "anytime")
    out = []; Y0 = 16

    def node(sid, x, yy, grp, start=False):
        s = skills[sid]; L = wrapname(s["name"]); nst = skill_stage.get(sid, "anytime")
        ty = yy + (19 if len(L) == 1 else 15)
        fs = ' style="font-size:%.1fpx"' % max(7.5, 11 * 15.5 / max(len(l) for l in L)) if max(len(l) for l in L) > 15 else ""
        tx = "".join(f'<text class="nn" x="{x+9}" y="{ty+i*12}"{fs}>{E(l)}</text>' for i, l in enumerate(L))
        t0 = yy + (34 if len(L) == 1 else 41)
        tr = "".join(f'<text class="nt" x="{x+9}" y="{t0+i*11}">{E(l)}</text>' for i, l in enumerate(textwrap.wrap(s.get("trigger", ""), 23)[:2]))
        sb = f'<rect class="stbg" x="{x+NW-44}" y="{yy-7}" width="40" height="13" rx="6.5"/><text class="stt" x="{x+NW-24}" y="{yy+3}" text-anchor="middle">START</text>' if start else ""
        return (f'<g class="nd st-{nst}" data-id="{E(sid)}" data-grp="{grp}" tabindex="0" role="button" aria-label="{E(s["name"])}: {E(s.get("trigger",""))}">'
                f'<title>{E(s["name"])}</title><rect x="{x}" y="{yy}" width="{NW}" height="{NH}" rx="8"/>{tx}{tr}{sb}</g>')

    def head(grp, num, name, x, yy, kind, n):
        ikey = stages.get(grp, {}).get("icon") or meta.get("anytimeIcon" if grp == "anytime" else "", "") or grp
        ic = f'<g class="sic" transform="translate({x},{yy+2}) scale(1.05)" fill="none" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">{STAGE_ICON.get(ikey, STAGE_ICON.get(grp, STAGE_ICON["anytime"]))}</g>'
        return (f'<g class="sh st-{grp}" data-id="{kind}:{grp}" data-grp="{grp}" data-head="1" tabindex="0" role="button" aria-label="{E(name)} ({"a stage" if num else "a band"}, not a skill)">'
                f'<rect class="hit" x="{x-4}" y="{yy-4}" width="168" height="36" fill="transparent"/>{ic}'
                f'<text class="stn" x="{x+32}" y="{yy+13}">{E(name)}</text>'
                f'<text class="stc" x="{x+32}" y="{yy+28}">{("%s %d" % (LB["stage"], num)) if num else ""}</text></g>')

    per = 2
    colx = lambda i: X0 + i * CW
    # heights
    def nrows(c): return 1 if len(c["chain"]) <= 2 else len(c["chain"])
    def cat_h(c): return 24 + 14 + nrows(c) * (NH + GY) - GY + 30
    cols = {sid: [c for c in cats if c["stage"] == sid] for sid in STAGES}
    body_h = max([sum(cat_h(c) for c in cs) for cs in cols.values() if cs] + [120])
    GAPH = 62 if any(stages.get(k, {}).get('gap') for k in STAGES if cols[k]) else 0
    H_COL = 76 + body_h + GAPH
    for i, sid in enumerate(STAGES):
        x = colx(i); cs = cols[sid]; st = stages.get(sid, {})
        out.append(f'<g class="rg{" empty" if not cs else ""}" data-region="{sid}"><rect class="col" x="{x}" y="{Y0}" width="{CW}" height="{H_COL}"/></g>')
        nsk = sum(len(c["chain"]) for c in cs)
        out.append(head(sid, i + 1, SN[sid], x + 18, Y0 + 14, "stage", ""))
        if i: out.append(f'<line class="div" data-grp="{sid}" x1="{x}" y1="{Y0+4}" x2="{x}" y2="{Y0+H_COL-4}"/>')
        if not cs:
            out.append(f'<text class="emp" data-grp="{sid}" x="{x+18}" y="{Y0+92}">No {E(LB["items"])} for this {E(LB["stage"].lower())}</text><text class="emp" data-grp="{sid}" x="{x+18}" y="{Y0+110}">in {E(meta["name"])}</text>')
            continue
        ty = Y0 + 76
        for c in cs:
            out.append(f'<g class="ch st-{sid}" data-id="cat:{E(c["id"])}" data-grp="{sid}" tabindex="0" role="button" aria-label="{E(c["name"])} (a category)"><title>Category: {E(c["name"])}. Tap for details.</title>'
                       f'<rect class="chb" x="{x+14}" y="{ty-3}" width="{CW-28}" height="24" rx="6"/><text class="cht" x="{x+20}" y="{ty+14}">{E(c["name"])}</text></g>')
            ny = ty + 24 + 14; pos = []
            horiz = len(c["chain"]) <= 2
            for j, sk in enumerate(c["chain"]):
                px = x + 18 + (j * (NW + GX) if horiz else 0); py = ny + (0 if horiz else j * (NH + GY)); pos.append((px, py))
                out.append(node(sk, px, py, sid, j == 0 and not c.get("parallel")))
            for j in range(0 if c.get("parallel") else len(pos) - 1):
                (ax, ay), (bx, by) = pos[j], pos[j + 1]
                if horiz: out.append(f'<path class="arr" data-grp="{sid}" d="M{ax+NW} {ay+NH/2} H{bx-2}" marker-end="url(#ah)"/>')
                else: out.append(f'<path class="arr" data-grp="{sid}" d="M{ax+NW/2} {ay+NH} V{by-2}" marker-end="url(#ah)"/>')
            ty += cat_h(c)
        gp = st.get('gap')
        if gp:
            for li, ln in enumerate(textwrap.wrap(gp, 44)[:4]): out.append(f'<text class="gap" data-grp="{sid}" x="{x+18}" y="{Y0+H_COL-50+li*13}">{("Not covered: " if li == 0 else "") + E(ln)}</text>')
    TW = X0 * 2 + CW * len(STAGES)
    out.append(f'<path class="strip" d="M{X0+18} {Y0+54} H{TW-X0-14}" marker-end="url(#ah)"/>')
    y = Y0 + H_COL + 36
    ag = data.get("anytime", [])
    if ag:
        AW = TW - 2 * X0 - 36; blocks = []
        for g in ag:
            cols_ = 1 if len(g["items"]) == 1 else 2; blocks.append((g, cols_, cols_ * (NW + 20) - 20 + 24))
        rowsl = [[]]; cur = 0
        for bl in blocks:
            if cur + bl[2] > AW and rowsl[-1]: rowsl.append([]); cur = 0
            rowsl[-1].append(bl); cur += bl[2] + 24
        rh = [24 + 14 + max(math.ceil(len(g["items"]) / c_) for g, c_, _ in r) * (NH + 18) + 14 for r in rowsl]
        h = 68 + sum(rh)
        out.append(f'<g class="rg" data-region="anytime"><rect class="col top" x="{X0}" y="{y}" width="{TW-2*X0}" height="{h}"/></g>')
        out.append(head("anytime", 0, LB["anytime"], X0 + 18, y + 14, "stage", ""))
        ry = y + 62
        for ri, r in enumerate(rowsl):
            x = X0 + 18
            if ri: out.append(f'<line class="hdiv" data-grp="anytime" x1="{X0+18}" y1="{ry-8}" x2="{TW-X0-18}" y2="{ry-8}"/>')
            for k, (g, c_, w_) in enumerate(r):
                if k: out.append(f'<line class="div" data-grp="anytime" x1="{x-12}" y1="{ry-2}" x2="{x-12}" y2="{ry+rh[ri]-14}"/>')
                out.append(f'<g class="ch st-anytime" data-id="any:{E(g["id"])}" data-grp="anytime" tabindex="0" role="button" aria-label="{E(g["name"])} (a group)"><title>Group: {E(g["name"])}</title>'
                           f'<rect class="chb" x="{x-4}" y="{ry}" width="{w_-12}" height="24" rx="6"/><text class="cht" x="{x+2}" y="{ry+17}">{E(g["name"])}</text></g>')
                for j, sk in enumerate(g["items"]):
                    rr, cc = divmod(j, c_); out.append(node(sk, x + cc * (NW + 20), ry + 38 + rr * (NH + 18), "anytime"))
                x += w_ + 24
            ry += rh[ri]
        y += h
    VH = y + 16
    svg = (f'<svg class="map" id="map" viewBox="0 0 {TW} {VH}" role="group" aria-label="{E(meta["name"])} diagram"><defs>'
           '<marker id="ah" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0 0L10 5L0 10z" class="ahp"/></marker></defs>' + "".join(out) + "</svg>")
    css = (":root{" + "".join(f"--st-{k}:{v};" for k, v in LIGHT.items()) + "}\n@media (prefers-color-scheme:dark){:root:not([data-theme=\"light\"]){" + "".join(f"--st-{k}:{v};" for k, v in DARK.items()) + "}}\n:root[data-theme=\"dark\"]{" + "".join(f"--st-{k}:{v};" for k, v in DARK.items()) + "}\n" + "".join(f".st-{k}{{--c:var(--st-{k})}}" for k in LIGHT) + r'''
.col{fill:none;stroke:none}.empty .stn,.empty .stc,.empty .sbn{opacity:.55}
.sh{cursor:pointer;outline:none}.stn{fill:var(--c);font:800 16px var(--sans)}.stc{fill:var(--muted);font:11px var(--sans)}
.sic{stroke:var(--c)}.empty .sic{stroke:var(--muted)}.hdiv{stroke:var(--border);stroke-width:1;stroke-dasharray:4 4}
.sh:hover .stn,.sh:focus-visible .stn,.sh.sel .stn{fill:var(--c);text-decoration:underline}
.gap{fill:var(--muted);font:italic 10.5px var(--sans)}.div{stroke:var(--border);stroke-width:1.5}.emp{fill:var(--muted);font:600 13px var(--sans)}
.ch{cursor:pointer;outline:none}.chb{fill:none;stroke:none}.ch:hover .chb,.ch:focus-visible .chb,.ch.sel .chb{fill:color-mix(in srgb,var(--c) 12%,transparent)}
.cht{fill:var(--c);font:800 13px var(--sans)}.chn{fill:var(--muted);font:600 11px var(--sans)}
.nd{cursor:pointer;outline:none}.nd rect{fill:var(--bg);stroke:var(--c);stroke-width:1.4}
.nd:hover rect,.nd:focus-visible rect{stroke:var(--c);stroke-width:2.4}.nd.sel rect{fill:color-mix(in srgb,var(--c) 14%,var(--bg));stroke:var(--c);stroke-width:2.6}
.nn{fill:var(--fg);font:600 11px var(--mono)}.nt{fill:var(--muted);font:10px var(--sans)}
.stbg{fill:var(--c)!important;stroke:none!important}.stt{fill:var(--bg);font:800 8px var(--sans);letter-spacing:.06em}
.strip{stroke:var(--muted);stroke-width:1.2;fill:none;opacity:.7}.arr{stroke:var(--muted);stroke-width:1.2;fill:none}.ahp{fill:var(--muted)}.flowdn{stroke-width:2}
.sm.calm h4,.sm.calm details.sec{--l:var(--c)}
.sm.calm h4,.sm.calm details.sec .sl{color:var(--c);background:color-mix(in srgb,var(--c) 10%,transparent);border-color:color-mix(in srgb,var(--c) 35%,transparent)}
.sm.calm ul.wl li{border-left-color:var(--c)}.sm.calm .chip{border-color:var(--c);color:var(--c)}
.sm.calm .ex{background:var(--bg2);border-color:var(--border)}.sm.calm .exr>b{color:var(--muted)}
''')
    # ---- page js: models built from the same json
    pack = {"stages": stages, "cats": {c["id"]: c for c in cats}, "any": {g["id"]: g for g in ag}, "skills": skills, "order": STAGES,
            "skillStage": skill_stage, "meta": meta, "SN": SN, "L": LB}
    js = "window.SMPLAT=" + json.dumps({k: platforms.svg(k) for k in platforms.FILES}) + ";window.SMCANVAS='always';window.SMNOCOLLAPSE=true;var PACK=" + json.dumps(pack, ensure_ascii=False).replace("</", "<\\/") + ";\n" + (open(__file__.replace("layout_sdlc.py", "layout_sdlc.js"), encoding="utf-8").read())
    plats = sorted({p for s in skills.values() for p in s.get("platforms", [])})
    PL = dict(zip(["claude-code", "cursor", "codex"], ["Claude Code", "Cursor", "Codex"]))
    ICON = {"all": ICON_ALL, "claude-code": ICON_CL, "cursor": ICON_CU, "codex": ICON_CODEX}
    flt = dict(label="Show skills for", options=[("all", "All", ICON_ALL)] + [(p, PL.get(p, p), ICON.get(p, PL.get(p, p))) for p in plats]) if plats else None
    src = "".join(f'<a href="{E(s["url"])}" target="_blank" rel="noopener">{E(s["label"])}</a> · ' for s in meta.get("sources", []))[:-3]
    order = [(str(i + 1), SN[s], re.sub(r"\*\*|==", "", stages.get(s, {}).get("principle") or "No skills in this pack")[:46], f"st-{s}") for i, s in enumerate(STAGES)]
    return dict(key=meta.get("nav", ""), title=meta["name"], version=meta.get("version", "") or "template", subtitle=E(meta.get("tagline", "")),
                svg=svg, mapw=2012, css=css, js=js, order=order, filter=flt, legend="", footer=("Sources: " + src) if src else "", out=meta.get("out"), logo=meta.get("logo"))
