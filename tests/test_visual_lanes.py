#!/usr/bin/env python3
"""visual.py render --map: a run-order view gets Ask → Check → Fix → Finish lanes and passes the check
(0 crossings, nothing outside its lane); a view whose parts name no phase stays a free graph.
Needs Chrome/Chromium; skips without it."""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills" / "visual" / "scripts"))
import visual  # noqa: E402

if not visual.find_chrome():
    print("SKIP: test_visual_lanes.py (no Chrome)")
    sys.exit(0)

steps = [("grill", "grilling", "grills the user"), ("brief", "taste file", "commits taste"),
         ("shoot", "shoot.mjs", "takes shots"), ("crit", "critique", "design review"),
         ("fix", "fix verbs", "routes fixes"), ("pol", "polish", "polish last"),
         ("pr", "draft PR", "opens draft PR")]
model = {
    "title": "lanes fixture",
    "nodes": [{"id": "loop", "label": "/loop", "kind": "public", "author": "nobody-x"}]
    + [{"id": i, "label": l, "kind": "verb" if i in ("crit", "fix", "pol") else "board"} for i, l, _ in steps]
    + [{"id": "a", "label": "alpha", "kind": "script"}, {"id": "b", "label": "beta", "kind": "script"},
       {"id": "c", "label": "gamma", "kind": "script"}, {"id": "d", "label": "delta", "kind": "script"}],
    "edges": [{"id": f"e{i}", "from": "loop", "to": t, "label": lbl} for i, (t, _, lbl) in enumerate(steps)]
    + [{"id": "x1", "from": "crit", "to": "fix", "label": "ranks"}, {"id": "x2", "from": "fix", "to": "pol", "label": "then"}]
    + [{"id": f"y{i}", "from": "a", "to": t, "label": "runs"} for i, t in enumerate("bcd")],
    "views": [
        {"id": "root", "parent": None, "title": "root", "nodeIds": ["loop", "a"]},
        {"id": "loop", "parent": "root", "title": "/loop · run", "render": "sequence",
         "nodeIds": ["loop"] + [i for i, _, _ in steps],
         "edges": [f"e{i}" for i in range(len(steps))] + ["x1", "x2"]},
        {"id": "plain", "parent": "root", "title": "plain", "render": "sequence", "nodeIds": ["a", "b", "c", "d"]},
    ],
}
with tempfile.TemporaryDirectory() as d:
    src, out = Path(d) / "map.json", Path(d) / "map.html"
    src.write_text(json.dumps(model))
    r = subprocess.run([sys.executable, str(Path(visual.__file__)), "render", "--map", str(src), "--out", str(out),
                        "--no-open", "--no-optimize", "--shots", str(Path(d) / "shots")], capture_output=True, text=True)
    res = json.loads(r.stdout)
    chk = res["check"]
    assert chk["lanes"] == {"loop": ["Ask", "Check", "Fix", "Finish"]}, chk["lanes"]
    assert not chk["overlaps"], chk["overlaps"]
    assert not chk["errors"], chk["errors"]
    assert r.returncode == 0, r.stderr
print("PASS: test_visual_lanes.py")
