GUIDE='https://github.com/cursor/plugins/blob/main/pstack/docs/guide/'
CALLS = {
'poteto-mode': [
 [ "unfamiliar code or bug history", ["@how","@why"] ],
 [ "code crosses a function boundary", ["@architect"] ],
 [ "parallel fan-out", ["@swarm"], "design bake-off", ["@arena"], "contested design", ["@interrogate"] ],
 [ "any prose", ["@unslop"], "docs and PR text", ["@technical-writing"] ],
 [ "before commit", ["@deslop"], "before review", ["@no-comments"] ],
 [ "bug with a cheap test", ["@tdd"], "measured a number", ["@benchmark-checklist"] ],
 [ "long or unattended run", ["@show-me-your-work"] ],
 [ "no way to prove the app", ["@create-verification-skill"], "no playbook fits", ["@figure-it-out"] ],
],
'figure-it-out': [["big design choice", ["@architect"], ["@arena"]], ["every decision", ["@show-me-your-work"]]],
'teach': [["/teach", ["@how","@why"], "blend", ["@unslop"]]],
'recall': [["topic names a feature, file or bug", ["@why"], "source investigators"]],
'architect': [["ground", ["@how"], "ownership changes?", ["@why"], "sketch", ["@arena"]]],
'technical-writing': [["every doc it touches", ["@unslop"]]],
'no-comments': [["`comment-sicko` agent flags comments", "a fix needs a new shape?", ["@architect"]]],
'babysit': [["failing checks", ["@fix-ci"]], ["merge conflicts", ["@fix-merge-conflicts"]], ["review comments", ["@get-pr-comments"]], ["prose it writes", ["@unslop"]]],
'blast-radius': [["read the change", ["@why"], "big change", ["@arena"]]],
'thermo-nuclear-code-quality-review': [["review fans out in parallel", ["@swarm"]]],
'setup-pstack': [["no way to prove the app?", "offers once", ["@create-verification-skill"]]],
'automate-me': [["writing the skill", ["@unslop"], "also `plugin-dev:skill-development` (outside pstack)"]],
}
PICKS = [
 ["Your prompt", "/poteto-mode", "reads the Principles section", "matches the task"],
 ["**Read-only question**", "Investigation", ["@how","@why"], "verify and report"],
 ["**Defect**", "Bug fix", ["@how","@why"], "crosses a function boundary?", ["@architect"], "cheap test?", ["@tdd"], "verify and report"],
 ["**New behavior**", "Feature", ["@how"], ["@architect"], "verify and report"],
 ["**Structure only**", "Refactoring", ["@how"], "crosses a function boundary?", ["@architect"], "verify and report"],
 ["**Measured slowness**", "Perf issue", ["@benchmark-checklist"], ["@how"], "verify and report"],
 ["**Large work or no match**", ["@figure-it-out"], "verify and report"],
 ["Also in the skill file: hill-climbing a metric", "Hillclimb", ["@how"], ["@benchmark-checklist"]],
 ["Also: PR status", "Babysit playbook", "not the babysit skill"],
 ["Also: you step away", ["@show-me-your-work"]],
 ["Also: every playbook ends", "Opening a PR", ["@technical-writing","@unslop"], ["@no-comments","@deslop"]],
]
DIAGS = {
 'architect': ('04-design.md','guide ch. 4'), 'arena': ('04-design.md','guide ch. 4'), 'interrogate': ('04-design.md','guide ch. 4'),
 'show-me-your-work': ('07-overnight.md','guide ch. 7')}
DIAG_FLOWS = {
 '04-design.md': ("Design panel", [["One task","Configured panel",{'stack':["Candidate 1","Candidate 2","Candidate N"]},"Cross-judge","Pick a base","Graft the best parts","Verify"]]),
 '07-overnight.md': ("Overnight loop", [["Check the finish condition","Smallest justified change","Verify on the real artifact","Progress?",{'stack':["yes: commit","no: discard"]},"Log one decision row","back to the check"]]),
}
ROUTES = {
 'setup': "Partly. poteto-mode sends work that fits no playbook to figure-it-out. You run setup-pstack and poteto-help yourself.",
 'understand': "Yes. The Investigation and Bug fix playbooks start with how and why. recall and teach you type yourself.",
 'catchup': "No. You type these yourself when a chat gets long or a reply is too dense.",
 'design': "Yes. poteto-mode calls architect when code crosses a function boundary, and architect runs arena.",
 'fanout': "Yes. poteto-mode calls swarm for parallel fan-out and interrogate for a contested design.",
 'build': "Partly. The Bug fix playbook points to tdd. typescript-best-practices kicks in on its own for .ts files.",
 'write': "Yes. unslop on every reply and prose surface, technical-writing for docs and PR text.",
 'cleanup': "Yes. deslop before commit, no-comments before review.",
 'review': "Partly. benchmark-checklist before you report a measured number. blast-radius and the strict review you start yourself.",
 'prove': "Yes. show-me-your-work for long runs, create-verification-skill when the app has no way to prove behavior.",
 'pr': "No, not these skills. poteto-mode uses its own Babysit and Shipping playbooks for PR status and landing.",
 'improve': "Not in the router's main flow. You start these yourself.",
 'extras': "No. A Cursor-only helper outside the main workflow.",
}
REACHED1 = ['setup','understand','design','fanout','build','write']
REACHED2 = ['cleanup','review','prove']
