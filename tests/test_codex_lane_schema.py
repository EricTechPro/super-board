#!/usr/bin/env python3
"""Pin the Codex lane's --output-schema to STAGE_SCHEMA in workflows/super-board-wave.js.

Two hosts, one lane-result contract: the status enum and field names must match.
Offline; reads both sources, runs nothing but node on the extracted object literal.
"""
import ast
import json
from pathlib import Path
import re
import subprocess

KIT = Path(__file__).resolve().parent.parent


def lane_schema():
    text = (KIT / 'scripts/super-board-lane.sh').read_text()
    source = text.split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
    wanted = {'counts', 'properties', 'schema'}
    nodes = [node for node in ast.parse(source).body if isinstance(node, ast.Assign)
             and any(isinstance(t, ast.Name) and t.id in wanted for t in node.targets)]
    namespace = {}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), 'lane', 'exec'), namespace)
    return namespace['schema']


def stage_schema():
    text = (KIT / 'workflows/super-board-wave.js').read_text()
    match = re.search(r'^const STAGE_SCHEMA = (\{.*?^\})$', text, re.S | re.M)
    assert match, 'STAGE_SCHEMA not found in workflows/super-board-wave.js'
    out = subprocess.check_output(['node', '-e', 'process.stdout.write(JSON.stringify(' + match.group(1) + '))'],
                                  text=True)
    return json.loads(out)


def main():
    lane, stage = lane_schema(), stage_schema()
    lane_props, stage_props = lane['properties'], stage['properties']
    assert lane_props['status']['enum'] == stage_props['status']['enum'], (
        lane_props['status']['enum'], stage_props['status']['enum'])
    assert sorted(lane_props) == sorted(stage_props), (sorted(lane_props), sorted(stage_props))
    findings = next(option for option in lane_props['priorFindings']['anyOf'] if option['type'] == 'object')
    assert sorted(findings['properties']) == sorted(stage_props['priorFindings']['properties'])
    assert set(stage['required']) <= set(lane['required'])
    print('PASS: test_codex_lane_schema.py (status enum and field names match STAGE_SCHEMA)')


if __name__ == '__main__':
    main()
