import json,sys
from data import *
W,H=128,54
X=lambda c:40+(c-1)*196
Y=lambda r:60+(r-1)*140
POS={"menu":(1,1),"init":(1,2),"document":(1,3),"doctor":(1,5),"hooks":(1,6),"pin":(1,7),
"shape":(2,1),"craft":(2,2),"critique":(2,4),"audit":(2,5),"extract":(2,6),"live":(2,7),
"harden":(3,1),"clarify":(3,2),"adapt":(3,3),"optimize":(3,4),"onboard":(3,5),"distill":(3,6),
"layout":(4,1),"typeset":(4,2),"colorize":(4,3),"quieter":(4,4),"bolder":(4,5),"polish":(4,7),
"overdrive":(5,4),"animate":(5,5),"delight":(5,6)}
gt={g[0]:g[2] for g in GROUPS}
comps=[]
for cid,lab,g,_t,*_ in C:
    trig=TRIG[cid]
    r,c=POS[cid]; comps.append({"id":cid,"type":gt[g],"label":lab,"sublabel":trig,"pos":[X(c),Y(r)],"size":[W,H]})
bnd=[{"kind":"region","label":gl,"wraps":[x[0] for x in C if x[2]==g]} for g,gl,_,_ in GROUPS]
conns=[]
for i,(f,t,l,v) in enumerate(E):
    d={"id":f"e{i}","from":f,"to":t,"label":l}
    if v:d["variant"]=v
    conns.append(d)
mode=sys.argv[1] if len(sys.argv)>1 else "all"
hand=POLISH_HANDOFF if mode=="all" else ["distill","bolder","delight"]
for h in hand:
    conns.append({"id":f"p_{h}","from":h,"to":"polish","label":"then","variant":"dashed"})
leg={g[2]:{"label":g[3]} for g in GROUPS if g[3]}
spec={"schema_version":1,"diagram_type":"architecture",
"meta":{"title":"impeccable v4.0.4 · slash commands and how they connect","output":"commands.html","quality_profile":"showcase","locale":"en",
 "legend":{"mode":"all","entries":leg}},
"components":comps,"boundaries":bnd,"connections":conns,
"cards":[
 {"dot":"violet","title":"Best practice","items":["init once → shape / build → critique + audit → fix & style commands → polish last","Click any command for what it does and what to pair it with"]},
 {"dot":"rose","title":"Edges","items":["read FROM, label, TO · bold = requires · dashed = suggests / then","Group label \"then polish\" = every command in it hands off to polish"]}]}
json.dump(spec,open("commands.json","w"),indent=1);print("ok",len(comps),len(conns))
