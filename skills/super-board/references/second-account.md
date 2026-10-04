# Second GitHub account for the robot

Follow this when onboard step 2 chooses "Yes". Allow about 10 minutes.
Keep the owner active until step 3 has picked or created the Project.
Replace every `<placeholder>` below before running a command. NEVER read a `.env` file.

## Why

GraphQL calls from `gh issue`, `gh pr` and `gh project` use the signed-in user's
[5,000 points/hr](https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api).
The owner's browsing and other tools share the budget. Points are not a count of calls.
Finfluencer, 2026-10-03/04: 3 cards cost ~2,850 points (~950/card); 14 exhausted
5,000 in ~40 minutes. Moves failed until reset; nearly every wave idled for up to an hour.

A machine user gets its own 5,000/hr. Robot comments show its name; the owner's budget stays free.
[GitHub's terms](https://docs.github.com/en/site-policy/github-terms/github-terms-of-service#3-account-requirements)
allow one free machine account alongside your personal account. A personal account cannot request
a higher limit. Enterprise limits are higher, but those costly plans are meant for companies.

## 1. Only the person — create the account

Create it on github.com: `<owner>-bot` or `<Owner>Service` works well.
A Gmail address like `you+bot@gmail.com` lands in your usual inbox.
Complete signup yourself; tell the agent only the username. Keep it for automation.

## 2. Agent — grant access as the owner

Use the original repo owner and the Project owner from onboard, not the bot's username.

```bash
gh auth switch -u <owner-login>
gh api -X PUT repos/<owner>/<repo>/collaborators/<bot> -f permission=push
```

After onboard step 3, add the bot to the user-owned Project as `WRITER`:

```bash
gh api users/<bot> --jq .node_id
gh project view <n> --owner <owner> --format json --jq .id
gh api graphql -f query='mutation {
  updateProjectV2Collaborators(input: {
    projectId: "<project-id>"
    collaborators: [{userId: "<bot-node-id>", role: WRITER}]
  }) { clientMutationId }
}'
```

Use the IDs returned by the first two commands in the mutation.
[Mutation fields](https://docs.github.com/en/graphql/reference/projects#updateprojectv2collaborators).
For an org-owned Project, have its admin grant the bot Write access in the org's Project settings.

## 3. Only the person — create and install the token

Signed in as the bot, open Settings → Developer settings → Personal access tokens →
Tokens (classic) → Generate new token (classic). Expiry: **30 days**.

| Tick exactly | Why |
|---|---|
| `repo` | Repo, issues and pull requests |
| `project` | Read and move Project cards |
| `read:org` | Required by `gh auth login` |
| `gist` | Listed by `gh auth login` as a minimum scope |
| `workflow` | Work on workflow files |

DON'T tick everything. A real run included `delete_repo` and `admin:enterprise` — far too much.
Missing `read:org` fails with `missing required scope 'read:org'`.

Run this yourself in the **Claude Code prompt**, replacing `<token>` locally:

```text
! echo <token> | gh auth login --with-token
```

The token goes right after `echo`; the line must end with `--with-token`.
DON'T run the literal word `TOKEN` or put the token after `login`.
Agents MUST NOT type tokens: secret-guard hooks block it. NEVER paste the token into chat.
If it appeared in chat, rotate it after the run.

## 4. Agent — accept the invite and verify as the bot

```bash
gh auth switch -u <bot>
gh api user/repository_invitations
gh api -X PATCH user/repository_invitations/<id>
gh auth status
gh api repos/<owner>/<repo> --jq .permissions.push
gh project view <n> --owner <owner>
gh api rate_limit --jq .resources.graphql.remaining
```

Pick only the invitation ID for this repo. No email click is needed.
Verify both accounts are listed, bot active, push `true`, and Project readable.
The bot has its own 5,000-point bucket; remaining may be just below 5,000 after verification.
If a token environment override defeats account switching, stop and ask the person to clear it.
NEVER print token values or read dotenv files to diagnose it.

## 5. Agent — keep claim identity stable

Stage `notifications.bot_identity` as the bot username for new boards; save at onboard step 8.
Existing boards may keep the owner's name. The bot can assign either account.
`run-workflow.md` step 3 proceeds only when assignees equal exactly `[bot_identity]`.
NEVER change that identity during a run or because the active login changes.

Optional per-run fallback: the person may ask the orchestrator to also use the owner's bucket
(~10,000 points/hr combined, less the owner's use). No config key or automatic switch is added.
Before each wave, with no workers running, check `gh api rate_limit`. If GraphQL remaining is
below ~3,000, `gh auth switch -u <other>` and check again. Keep the other account only if it has
more; otherwise switch back. Keep existing rate guards and halt rules; NEVER switch mid-wave.

## End of run

Leave the bot active. The person rotates any token that appeared in chat, revokes the exposed
token, and installs the replacement using step 3. Renew the bot token before its 30-day expiry.
