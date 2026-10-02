# arch-loop

Runs an architecture review in a loop: a fresh sub-agent finds deepening opportunities,
the loop implements the top one, proves it with the project's verify commands, commits,
and goes again. It stops after two passes in a row find nothing new.

- **Finder:** `/improve-codebase-architecture` or `/codebase-design` from
  [mattpocock/skills](https://github.com/mattpocock/skills) when installed; a built-in
  shallow-module scan otherwise.
- **State:** `docs/arch-loop-ledger.md`, one entry per finding. Restarting resumes.
- **Safety:** one finding per commit; red passes are reverted and marked `deferred`;
  schema, contract, dependency, auth and payment changes stop for a human.

Start it with `/arch-loop`. The full procedure is in [`SKILL.md`](SKILL.md).

Credit: adapted from the `arch-loop` skill in Eric Tech's BookKeepingApp.
