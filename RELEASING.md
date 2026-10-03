# Releasing super-board

Push a version tag to run the release workflow. GitHub creates the release only after
all safety suites pass on Linux and macOS, and the status-reader checks pass on Windows,
Linux and macOS. Failed, cancelled or skipped checks prevent the publish job from running.
No release is created on pull requests or ordinary branch pushes.

1. Update `VERSION` and `RELEASE-NOTES.md` in a reviewed commit.
2. Run `bash tests/run-safety.sh` locally and merge the commit after CI passes.
3. Tag that exact commit with `vMAJOR.MINOR.PATCH`, matching `VERSION`, and push the tag.
4. Open the **release** Actions run. Only its **publish** job creates the GitHub release.

The release run checks the tag event's commit, not the current tip of `main`. Publication
also checks that the checkout and remote tag still match that tested commit. Missing,
moved or unreadable tags, and version mismatches, fail before publication. Annotated and
lightweight tags are supported. An existing release causes the CLI to fail; the workflow
never edits or replaces it. After a transient CI failure, rerun the failed Actions run.
If code must change, make a new version commit and tag instead of moving an existing tag.

## Tests

`tests/run-safety.sh` discovers every `tests/test-*.sh` and `tests/test_*.py` suite. This
includes the merge gate, guard hooks, installers, upgrade setup, preflight, dependencies,
usage limits, writing format, cleanup and workflow behavior tests. A new matching suite
joins CI automatically. The runner prints every result and returns nonzero if any suite
fails; it also refuses an empty suite. Some Python tests have shell wrappers and therefore
run twice. Keep these tests offline and deterministic; paid agent evaluations belong in
`evals/` and are not part of this gate.

Dependencies: Bash, Python 3, Git, jq, Node.js, curl and tar. GitHub's Linux/macOS runners
provide the command-line utilities; the workflow selects Python 3.12 and Node.js 22.
Windows coverage remains limited to the Python status reader.

## Repository settings still matter

The **release workflow** waits for tests before it publishes.
The GitHub UI and a standalone `gh release create` call can bypass Actions. Branch checks
alone do not prevent that. No branch protection, tag rules or permissions are changed by
this code.

Before treating this as an enforced release policy:

- Require the checks listed below for `main` through a branch ruleset. Require review
  of changes to the workflows and release scripts.
- Add a tag ruleset for `v*`. Require the same checks before tag creation (do not enable
  the creation exemption), and bind their source to GitHub Actions. Confirm that GitHub
  offers this rule for the repository before relying on it. The checks must already be
  green on the version commit, normally from the push to `main`.
- Block updates and deletion for `v*` tags, with no routine bypass. This closes the
  interval between the remote-tag check and release creation.
- Limit release-writing credentials and adopt this workflow as the only publishing route.
  GitHub's contents-write permission includes manual release creation; writers/admins
  who retain it can bypass this policy for existing tags. An unchecked legacy tag or
  a tag outside `v*` is not covered by the new-tag rule. A protected environment alone
  does not stop manual releases.
- Consider GitHub's immutable releases setting to prevent changes after publication.

This is a personal-account repository. Collaborator write access includes release
management; GitHub does not offer a separate "push code but never create a release"
collaborator role here. Strict isolation requires withholding broad write credentials
from routine automation and using a trusted publisher. The repository owner can still
change rules. Do not describe the settings above as protection against the owner.

Use these exact check names from the direct **cross-platform** branch/PR run:

```text
safety (ubuntu-latest)
safety (macos-latest)
smoke (ubuntu-latest / py3.10)
smoke (ubuntu-latest / py3.12)
smoke (macos-latest / py3.10)
smoke (macos-latest / py3.12)
smoke (windows-latest / py3.10)
smoke (windows-latest / py3.12)
```

The **release** run adds `checks / ` to these names because it calls a reusable workflow.
Those tag-only names are not the branch requirements.

These settings require a separate repository-owner decision. Until then, this workflow
blocks its own publication on failed tests, but cannot promise to block manual releases.

References: [reusable workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows),
[GitHub CLI release creation](https://cli.github.com/manual/gh_release_create),
[repository rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets).

See [personal repository permissions](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/repository-access-and-collaboration/permission-levels-for-a-personal-account-repository)
and [available rules](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets)
for the permission and tag-check limits.
