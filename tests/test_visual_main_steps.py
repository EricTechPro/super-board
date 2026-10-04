#!/usr/bin/env python3
"""The actual skill pack exposes compact main steps and preserves access to all detail."""
import json
import sys
from pathlib import Path

pack = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(pack / "skills" / "visual" / "scripts"))
import visual  # noqa: E402

model = json.loads((pack / "diagrams" / "skill-map.json").read_text())
views = {v["id"]: v for v in model["views"]}
nodes = {n["id"]: n for n in model["nodes"]}
nodes.update({n["id"]: n for v in model["views"] for n in v.get("nodes", [])})
assert not visual.validate_map(model), visual.validate_map(model)

# Navigation through the view browser must reach every view, including scripts/policies.
for view in views.values():
    trail = set()
    cursor = view
    while cursor.get("parent"):
        assert cursor["id"] not in trail, f"cyclic navigation: {trail}"
        trail.add(cursor["id"])
        assert cursor["parent"] in views, f"view has no navigable parent: {cursor['id']}"
        cursor = views[cursor["parent"]]
    assert cursor["id"] == "root", f"view is outside the root hierarchy: {view['id']}"

visible = {nid for v in views.values() for nid in v.get("nodeIds", [])}
missing = set(nodes) - visible
assert not missing, f"nodes lost from all views: {sorted(missing)}"

main_views = ("super-board-run", "sb-onboard", "super-collect", "ui-refine-loop")
for vid in main_views:
    view = views[vid]
    step_ids = view.get("stepIds", view["nodeIds"])
    assert view.get("mainSteps") or view.get("render") == "process", f"{vid}: not a main-step view"
    assert 4 <= len(step_ids) <= 6, f"{vid}: too many/few steps"
    for nid in step_ids:
        node = {**nodes[nid], **view.get("nodeOverrides", {}).get(nid, {})}
        assert node["kind"] in {"public", "verb", "step"}, f"{vid}: low-level clutter {nid}"
    columns = {pos[0] if isinstance(pos, list) else pos["col"] for pos in view.get("layout", {}).values()}
    assert len(columns) <= 6, f"{vid}: more than six columns"
    # Each implementation step opens a smaller view; terminal steps can simply show details.
    for nid in step_ids[1:-1]:
        node = {**nodes[nid], **view.get("nodeOverrides", {}).get(nid, {})}
        assert node.get("opensView") in views, f"{vid}: {nid} hides detail without a sub-view"

run = views["super-board-run"]
assert run["nodeIds"][0] == "sb-run", "run must start with its trigger"
assert "5" in run.get("caption", "") and any(word in run["caption"].lower() for word in ("parallel", "once", "batch", "concurrent")), "run must explain card concurrency"

# Policy exceptions sit under the step that applies them, rather than extending the main row.
for vid in ("merge-policy", "size-cap", "needs-you", "usage-pause", "guard-protected-push"):
    policy = views[vid]
    assert len(policy["nodeIds"]) <= 4, f"{vid}: policy sub-view is not small"
    cursor = policy
    while cursor.get("parent") and cursor["id"] != "super-board-run":
        cursor = views[cursor["parent"]]
    assert cursor["id"] == "super-board-run", f"{vid}: policy is detached from the run"

# Root and verb chooser offer public decisions rather than state/scripts.
for vid, limit in (("root", 8), ("super-board", 6)):
    view = views[vid]
    assert len(view["nodeIds"]) <= limit, f"{vid}: overly wide summary"
    assert all(nodes[nid]["kind"] in {"public", "lane", "verb", "step"} for nid in view["nodeIds"]), f"{vid}: implementation clutter"
print(f"PASS: test_visual_main_steps.py ({len(nodes)} reachable nodes, {len(views)} views)")
