"""Pages version tests: the public site shows the repo VERSION, never a hardcoded release.

The pages carry `<span data-sb-version>dev</span>` placeholders (readable when the file is
opened locally); `diagrams/_shared/stamp_version.py` writes VERSION into them at deploy.

Run directly:  python3 tests/test_pages_version.py
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STAMP = ROOT / "diagrams" / "_shared" / "stamp_version.py"
PAGES = ["diagrams/index.html", "diagrams/onboarding/index.html", "diagrams/writing-standard/reference.html"]
HARDCODED = re.compile(
    r"super-board[ @]v?\d+\.\d+\.\d+|releases/tag/v\d|class=\"vpill\">v?\d+\.\d+\.\d+"
)
VERSION = (ROOT / "VERSION").read_text().strip()


def stamp(site: Path, version: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(STAMP), str(site), version], capture_output=True, text=True)


def test_pages_hold_no_hardcoded_release():
    for page in PAGES:
        hits = HARDCODED.findall((ROOT / page).read_text(encoding="utf-8"))
        assert not hits, f"{page} hardcodes a release: {hits}"


def test_pages_carry_a_readable_placeholder():
    for page in PAGES:
        text = (ROOT / page).read_text(encoding="utf-8")
        assert re.search(r"<span data-sb-version(=\"v\")?>dev</span>", text), f"{page} has no version placeholder"


def test_stamp_writes_version_into_every_placeholder():
    with tempfile.TemporaryDirectory() as tmp:
        site = Path(tmp)
        for i, page in enumerate(PAGES):
            shutil.copy(ROOT / page, site / f"p{i}.html")
        result = stamp(site, VERSION)
        assert result.returncode == 0, result.stderr
        for i, page in enumerate(PAGES):
            text = (site / f"p{i}.html").read_text(encoding="utf-8")
            assert ">dev</span>" not in text, f"{page} still shows dev after stamping"
            assert f">{VERSION}</span>" in text or f">v{VERSION}</span>" in text, page
        onboarding = (site / "p1.html").read_text(encoding="utf-8")
        assert f"super-board@<span data-sb-version=\"v\">v{VERSION}</span>" in onboarding


def test_stamp_refuses_a_malformed_version():
    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / "a.html").write_text("<span data-sb-version>dev</span>")
        for bad in ["", "v3.3.0", "3.3", "3.3.0; rm -rf /"]:
            assert stamp(Path(tmp), bad).returncode != 0, bad


def test_stamp_fails_when_no_placeholder_is_found():
    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / "a.html").write_text("<p>no version here</p>")
        assert stamp(Path(tmp), "1.2.3").returncode != 0


def test_pages_workflow_stamps_the_site_and_redeploys_on_version_bump():
    workflow = (ROOT / ".github" / "workflows" / "pages.yml").read_text(encoding="utf-8")
    assert re.search(r"python3 diagrams/_shared/stamp_version\.py _site \"\$\(cat VERSION\)\"", workflow)
    assert '"VERSION"' in workflow.split("paths:", 1)[1].split("\n", 1)[0]


if __name__ == "__main__":
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print(f"  ✅ {name}")
        except AssertionError as exc:
            failed += 1
            print(f"  ❌ {name}: {exc}")
    print(f"passed: {len(tests) - failed}  failed: {failed}")
    sys.exit(1 if failed else 0)
