"""Generate a grouped left-to-right map; all command detail stays in data.py."""
import json
from pathlib import Path
from data import *

WIDTH, HEIGHT = 136, 54
GAP_X, GAP_Y = 206, 80
TOP, COMMAND_TOP = 72, 172
types = {g[0]: g[2] for g in GROUPS}
commands = {c[0]: c for c in C}
components, boundaries, connections = [], [], []
for col, (group, title, subtitle, ids) in enumerate(STAGES):
    x = 40 + col * GAP_X
    anchor = "stage_" + group
    components.append({"id": anchor, "type": types[group], "label": title,
                       "sublabel": subtitle, "pos": [x, TOP], "size": [WIDTH, HEIGHT]})
    for row, cid in enumerate(ids):
        command = commands[cid]
        components.append({"id": cid, "type": types[group], "label": command[1],
                           "sublabel": TRIG[cid], "pos": [x, COMMAND_TOP + row * GAP_Y],
                           "size": [WIDTH, HEIGHT]})
    boundaries.append({"kind": "region", "label": GROUPS[col][1],
                       "wraps": [anchor] + ids, "pad": 16})
    if col:
        connections.append({"id": "order_" + group, "from": "stage_" + STAGES[col-1][0],
                            "to": anchor, "fromSide": "right", "toSide": "left", "route": "straight"})
for col, cid in enumerate(UTILITIES):
    command = commands[cid]
    components.append({"id": cid, "type": types["util"], "label": command[1],
                       "sublabel": TRIG[cid], "pos": [40 + col * GAP_X, 744],
                       "size": [WIDTH, HEIGHT]})
boundaries.append({"kind": "region", "label": "Utilities · independent of the main flow",
                   "wraps": UTILITIES, "pad": 16})
legend = {g[2]: {"label": g[3]} for g in GROUPS if g[3]}
spec = {"schema_version": 1, "diagram_type": "architecture",
        "meta": {"title": "impeccable · left-to-right order of use", "output": "commands.html",
                 "quality_profile": "showcase", "locale": "en",
                 "legend": {"mode": "all", "entries": legend}},
        "components": components, "boundaries": boundaries, "connections": connections,
        "cards": [{"dot": "violet", "title": "Read left to right", "items": [
            "Setup → plan / build → diagnose → choose fixes and styling → polish last",
            "Fix, Style and Motion are optional groups; choose only what the findings need."]},
            {"dot": "rose", "title": "Command details", "items": [
            "Click a command for its definition and Use with. Group arrows show order, not prerequisites.",
            "Hooks, doctor, pin and live stay in a separate utility lane."]}]}
Path(__file__).with_name("commands.json").write_text(json.dumps(spec, indent=2) + "\n")
print("ok", len(components), "nodes,", len(connections), "group connectors")
