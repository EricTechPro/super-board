#!/usr/bin/env python3
"""Install readable fixture-only worker instructions, never user's home skills."""
from pathlib import Path
import sys
NAMES = ['super-board','super-build','super-qa','super-review','super-collect','visual','git-sync','ui-refine-loop',
         'tdd','implement','codebase-design','code-review','diagnosing-bugs','verification-before-completion','testing-strategy']
for root in sys.argv[1:]:
    for surface in ['.agents/skills', '.claude/skills']:
        for name in NAMES:
            path = Path(root) / surface / name / 'SKILL.md'
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('Fixture-only worker instructions.\n')
