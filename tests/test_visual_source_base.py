#!/usr/bin/env python3
"""visual.py render --source-base: in-root sources become hosted URLs, the rest stay text."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills" / "visual" / "scripts"))
import visual  # noqa: E402

repo = Path("/repo")
data = {
    "sourcesBase": "",
    "source": "pack/diagrams/map.json",
    "nodes": [
        {"id": "a", "source": "pack/skills/a/SKILL.md"},
        {"id": "b", "source": ["pack/scripts/run.sh:12-20", ".agents/skills/tdd/SKILL.md", "~/x.md"]},
        {"id": "c", "source": "https://example.com/y"},
    ],
    "views": [{"id": "detail", "nodes": [{"id": "step", "source": "pack/scripts/check.sh:7"}],
               "nodeOverrides": {"a": {"source": ["pack/skills/a/policy.md", ".agents/policy.md"]}}}],
    "meta": {"project": "repo"},
}
n = visual.link_sources(data, repo, repo / "pack", "https://github.com/o/r/blob/main")
base = "https://github.com/o/r/blob/main/"
assert n == 4, n
assert data["nodes"][0]["source"] == base + "skills/a/SKILL.md", data["nodes"][0]
assert data["nodes"][1]["source"] == [base + "scripts/run.sh#L12-L20", ".agents/skills/tdd/SKILL.md", "~/x.md"], data["nodes"][1]
assert data["nodes"][2]["source"] == "https://example.com/y"
assert data["views"][0]["nodes"][0]["source"] == base + "scripts/check.sh#L7", data["views"]
assert data["views"][0]["nodeOverrides"]["a"]["source"] == [base + "skills/a/policy.md", ".agents/policy.md"], data["views"]
assert data["source"] == "diagrams/map.json", data["source"]
assert data["meta"] == {"project": "pack", "sourceBase": base, "root": ""}, data["meta"]
print("PASS: test_visual_source_base.py")
