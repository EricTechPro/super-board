#!/usr/bin/env python3
"""Write the release version into the assembled Pages site.

Pages carry `<span data-sb-version>dev</span>` (or `data-sb-version="v"` for a v-prefixed
label), so a page opened from disk reads "dev". The pages workflow runs
`python3 diagrams/_shared/stamp_version.py _site "$(cat VERSION)"` after assembling _site.
Fails on a malformed version or when no placeholder is found. Stdlib only.
"""

import re
import sys
from pathlib import Path

SPAN = re.compile(r'<span data-sb-version(="v")?>[^<]*</span>')


def main(argv):
    if len(argv) != 3:
        print("usage: stamp_version.py <site-dir> <MAJOR.MINOR.PATCH>", file=sys.stderr)
        return 64
    site, version = Path(argv[1]), argv[2]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        print(f"version must be MAJOR.MINOR.PATCH (got: {version!r})", file=sys.stderr)
        return 64
    stamped = 0
    for page in sorted(site.rglob("*.html")):
        text = page.read_text(encoding="utf-8")
        new, n = SPAN.subn(
            lambda m: f'<span data-sb-version{m.group(1) or ""}>{"v" if m.group(1) else ""}{version}</span>', text
        )
        if n:
            page.write_text(new, encoding="utf-8")
            stamped += n
            print(f"stamped {n} × {version} in {page}")
    if not stamped:
        print(f"no data-sb-version placeholder under {site}", file=sys.stderr)
        return 65
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
