# ui-refine-loop config: the `refine` block

These keys are optional and live in the active super-board config (`.claude/super-board/configs/<slug>.json`). `scripts/refine-setup.sh detect` resolves each one in this order: the config key, then auto-detection, then the default. Run `detect` and read its output before setup. Whatever it prints is what the loop will use. Anything in its `warnings` array (also printed to stderr in a banner) goes to the user before the loop starts and into the PR body.

```jsonc
"refine": {
  // Starts the dev server. $PORT is exported before it runs.
  // Auto: package.json `dev`, else `start`, run with the repo's package manager
  // (lockfile → bun / pnpm / yarn / npm). Vite, Astro, Next, Nuxt, Remix,
  // SvelteKit and Storybook scripts also get `--port $PORT`.
  "dev_command": "npm run dev -- --port $PORT",

  // Polled until it answers 2xx, 3xx, 401 or 403. Default "/".
  "ready_path": "/",

  // Commands the fixer must keep green; a red round is reverted.
  // Auto: package.json typecheck / lint / test scripts (test runs with CI=1),
  // else the config's top-level `verify_commands`.
  "check_commands": ["npm run typecheck", "npm run lint"],

  // Untracked env files copied into the refine worktree.
  // Auto: whichever of .env, .env.local, .env.development.local exist.
  "env_files": [".env.local"],

  // ES module that signs a browser page in. Absent → no sign-in, ever.
  // Contract: export default async ({ page, base, state, env }) => void
  //           (or a named `signIn`); optional `isSignedOut(page) => boolean`.
  // `env` is the env file merged with process.env, then with the state's `env`.
  "auth_script": "scripts/refine-auth.mjs",

  // Data states to shoot. Each: name, optional `query` appended to the route,
  // optional `env` handed to auth_script (e.g. a different fixture user).
  // Default [{ "name": "main" }].
  "states": [
    { "name": "main", "env": { "USER_PREFIX": "E2E_PRIMARY" } },
    { "name": "empty", "env": { "USER_PREFIX": "E2E_EMPTY" } }
  ],

  // The project's taste and direction file, written by the grill (references/grill.md).
  // Default docs/design/taste.md. Missing → the grill starts from the skill's neutral
  // references/taste.md. One per project; each target gets a block under Direction.
  "taste_file": "docs/design/taste.md",

  // Impeccable install: its skill folder, its scripts/impeccable launcher, or any file
  // in its scripts/. Both layouts work: v4.4+ (scripts/impeccable <verb>) and v4.0.x
  // (node scripts/detect.mjs, node scripts/context.mjs).
  // Auto: .claude/skills/impeccable and .agents/skills/impeccable in this directory
  // and every parent, then under ~. Not found → a loud warning and the built-in
  // rubric (references/rubric.md); a refine.impeccable that points at nothing warns too.
  "impeccable": ".agents/skills/impeccable",

  "rounds": 5            // fix rounds; a closing check follows the last
  // qa_hook_rounds is ignored if present: the board no longer runs this loop.
}
```

## Example auth script

A sign-in-form login whose credentials come from env and are picked per state:

```js
// scripts/refine-auth.mjs
export default async function signIn({ page, base, env }) {
  const p = env.USER_PREFIX || 'E2E_PRIMARY'
  await page.goto(`${base}/sign-in`)
  await page.getByLabel('Email').fill(env[`${p}_EMAIL`])
  await page.getByLabel('Password').fill(env[`${p}_PASSWORD`])
  await page.getByRole('button', { name: /sign in/i }).click()
  await page.waitForURL((u) => !u.pathname.includes('/sign-in'))
}
```

Any setup the server itself needs, such as a local database or a seeded fixture, belongs inside `dev_command` (for example `supabase start && npm run seed && npm run dev -- --port $PORT`) or in the project's own scripts. The loop does not know about it.
