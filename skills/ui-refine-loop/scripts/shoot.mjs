#!/usr/bin/env node
// Screenshot one route at desktop 1440 and mobile 390, light theme, once per data
// state. Run with cwd = the refine worktree (playwright resolves from there):
//
//   node <skill>/scripts/shoot.mjs --base http://localhost:PORT --route /reports \
//     --out <run>/shots --label round-0 [--states main,empty] [--auth <module>] [--env .env.local]
//
// --states   comma list of state names, or a path to a JSON array of
//            {name, query?, env?} (refine.states from the super-board config).
//            `query` is appended to the route (e.g. "?fixture=empty"); `env` is
//            handed to the auth module. Default: main.
// --auth     optional ES module (refine.auth_script). Its default export (or
//            named `signIn`) is `async ({ page, base, state, env }) => void` and
//            must leave the page signed in. Optional named export
//            `isSignedOut(page) => boolean`; the default check is a URL whose path
//            matches /sign-?in|log-?in|auth/. No --auth → no sign-in, ever.
// --env      env file read into `env` for the auth module (default: none).
//
// Sessions are cached per state as <out>/../auth-<state>.json and reused until
// they stop working. Files: <label>-<state>-<desktop|mobile>.png. Prints the paths.
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import fs from 'node:fs';
import path from 'node:path';

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 2) out[argv[i].replace(/^--/, '')] = argv[i + 1];
  return out;
}

function readEnvFile(file) {
  if (!file || !fs.existsSync(file)) return {};
  return Object.fromEntries(
    fs
      .readFileSync(file, 'utf8')
      .split('\n')
      .map((l) => l.match(/^\s*(?:export\s+)?([A-Za-z0-9_]+)\s*=\s*(.*)\s*$/))
      .filter(Boolean)
      .map(([, k, v]) => [k, v.replace(/^['"]|['"]$/g, '')]),
  );
}

export function parseStates(spec) {
  if (!spec) return [{ name: 'main' }];
  if (spec.trim().startsWith('[')) return JSON.parse(spec);
  if (fs.existsSync(spec)) return JSON.parse(fs.readFileSync(spec, 'utf8'));
  return spec.split(',').filter(Boolean).map((name) => ({ name }));
}

const defaultSignedOut = (page) => /sign-?in|log-?in|\/auth\b/i.test(new URL(page.url()).pathname);

async function main() {
  const a = parseArgs(process.argv.slice(2));
  const { base, route } = a;
  if (!base || !route) throw new Error('usage: shoot.mjs --base URL --route /path [--out dir] [--label name] [--states …] [--auth module]');
  const outDir = path.resolve(a.out || '.refine/shots');
  const label = a.label || 'shot';
  const env = { ...readEnvFile(a.env && path.resolve(a.env)), ...process.env };
  const states = parseStates(a.states);
  let auth = null;
  if (a.auth) {
    const mod = await import(pathToFileURL(path.resolve(a.auth)).href);
    auth = { signIn: mod.signIn || mod.default, isSignedOut: mod.isSignedOut || defaultSignedOut };
    if (typeof auth.signIn !== 'function') throw new Error(`${a.auth} must export signIn (or default) as a function`);
  }
  fs.mkdirSync(outDir, { recursive: true });

  const require = createRequire(path.join(process.cwd(), 'package.json'));
  let chromium;
  try {
    ({ chromium } = require('playwright'));
  } catch {
    ({ chromium } = require('@playwright/test'));
  }
  const browser = await chromium.launch();
  const written = [];
  try {
    const viewports = [
      { name: 'desktop', width: 1440, height: 900, isMobile: false },
      { name: 'mobile', width: 390, height: 844, isMobile: true },
    ];
    for (const state of states) {
      const url = `${base}${route}${state.query || ''}`;
      const authFile = path.join(path.dirname(outDir), `auth-${state.name}.json`);
      for (const vp of viewports) {
        const ctx = await browser.newContext({
          viewport: { width: vp.width, height: vp.height },
          isMobile: vp.isMobile,
          hasTouch: vp.isMobile,
          deviceScaleFactor: vp.isMobile ? 2 : 1,
          colorScheme: 'light',
          storageState: auth && fs.existsSync(authFile) ? authFile : undefined,
        });
        const page = await ctx.newPage();
        await page.goto(url, { waitUntil: 'networkidle', timeout: 120_000 });
        if (auth && (await auth.isSignedOut(page))) {
          await auth.signIn({ page, base, state, env: { ...env, ...(state.env || {}) } });
          await ctx.storageState({ path: authFile });
          await page.goto(url, { waitUntil: 'networkidle', timeout: 120_000 });
        }
        await page.waitForTimeout(1500); // let skeletons and charts settle
        // Framework dev overlays are not part of the design.
        await page.addStyleTag({ content: 'nextjs-portal,vite-error-overlay,#webpack-dev-server-client-overlay{display:none!important}' });
        // Apps that scroll inside an inner container stop fullPage at the
        // viewport. Grow the viewport to the tallest scroller (capped) instead.
        const tallest = await page.evaluate(() => {
          let max = document.documentElement.scrollHeight;
          for (const el of document.querySelectorAll('*')) {
            const o = getComputedStyle(el).overflowY;
            if ((o === 'auto' || o === 'scroll') && el.scrollHeight > el.clientHeight) {
              max = Math.max(max, el.scrollHeight + el.getBoundingClientRect().top);
            }
          }
          return max;
        });
        if (tallest > vp.height) {
          await page.setViewportSize({ width: vp.width, height: Math.min(Math.ceil(tallest), 6000) });
          await page.waitForTimeout(500);
        }
        const file = path.join(outDir, `${label}-${state.name}-${vp.name}.png`);
        await page.screenshot({ path: file, fullPage: true });
        written.push(file);
        await ctx.close();
      }
    }
  } finally {
    await browser.close();
  }
  console.log(written.join('\n'));
}

if (process.argv[1]?.endsWith('shoot.mjs')) {
  main().catch((err) => {
    console.error(err.message);
    process.exitCode = 1;
  });
}
