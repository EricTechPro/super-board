#!/usr/bin/env node
// Screenshot one route at desktop 1440 and mobile 390, in light and dark, once
// per data state, plus per-section crops and before|after comparison sheets.
// Run with cwd = the refine worktree (playwright resolves from there):
//
//   node <skill>/scripts/shoot.mjs --base http://localhost:PORT --route /reports \
//     --out <run>/shots --label round-2 [--states main,empty] [--themes light,dark] \
//     [--compare round-0] [--sections '<css>'] [--auth <module>] [--env .env.local]
//
// --states   comma list of state names, or a path to a JSON array of
//            {name, query?, env?} (refine.states from the super-board config).
//            `query` is appended to the route (e.g. "?fixture=empty"); `env` is
//            handed to the auth module. Default: main.
// --themes   default light,dark. Dark sets prefers-color-scheme: dark, stores
//            localStorage theme=dark (next-themes and friends) and puts the
//            `dark` class and data-theme="dark" on <html>.
// --sections CSS for the section crops, taken at desktop and mobile in light.
//            Default: [data-refine-section], else main's sections / children.
//            Crops are elements at least 80px tall, not nested, at most 8.
//            --sections none turns crops off.
// --compare  a label already in --out (normally round-0). Each full shot that
//            has a counterpart under that label also gets a side-by-side sheet
//            cmp-<label>-<state>-<viewport>-<theme>.png, before left, after right.
// --auth     optional ES module (refine.auth_script). Its default export (or
//            named `signIn`) is `async ({ page, base, state, env }) => void` and
//            must leave the page signed in. Optional named export
//            `isSignedOut(page) => boolean`; the default check is a URL whose path
//            matches /sign-?in|log-?in|auth/. No --auth → no sign-in, ever.
// --env      env file read into `env` for the auth module (default: none).
//
// Sessions are cached per state as <out>/../auth-<state>.json and reused until
// they stop working. Files: <label>-<state>-<viewport>-<theme>.png, crops
// <label>-<state>-<viewport>-light-s<i>.png. Prints every path written.
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

const DEFAULT_SECTIONS = '[data-refine-section]';
const FALLBACK_SECTIONS = 'main > section, main > div > section, main > *';

export function parseThemes(spec) {
  const t = (spec || 'light,dark').split(',').map((s) => s.trim()).filter(Boolean);
  for (const x of t) if (!['light', 'dark'].includes(x)) throw new Error(`unknown theme "${x}" (light | dark)`);
  return t;
}

// round-3-main-desktop-dark.png → round-0-main-desktop-dark.png / cmp-round-3-main-desktop-dark.png
export function pairNames(file, label, beforeLabel) {
  const dir = path.dirname(file);
  const rest = path.basename(file).slice(label.length + 1);
  return { before: path.join(dir, `${beforeLabel}-${rest}`), sheet: path.join(dir, `cmp-${label}-${rest}`) };
}

async function sectionCrops(page, selector, prefix) {
  if (selector === 'none') return [];
  const pick = async (sel) =>
    page.evaluateHandle((sel) => {
      const els = [...document.querySelectorAll(sel)].filter((el) => {
        const r = el.getBoundingClientRect();
        return r.height >= 80 && r.width >= window.innerWidth * 0.4 && getComputedStyle(el).visibility !== 'hidden';
      });
      return els.filter((el) => !els.some((o) => o !== el && o.contains(el))).slice(0, 8);
    }, sel);
  let handle = await pick(selector || DEFAULT_SECTIONS);
  if (!selector && (await handle.evaluate((a) => a.length)) === 0) handle = await pick(FALLBACK_SECTIONS);
  const n = await handle.evaluate((a) => a.length);
  const out = [];
  for (let i = 0; i < n; i++) {
    const el = await handle.evaluateHandle((a, i) => a[i], i);
    const file = `${prefix}-s${i + 1}.png`;
    try {
      await el.asElement().screenshot({ path: file });
      out.push(file);
    } catch {
      /* detached or zero-size: skip */
    }
  }
  return out;
}

async function compareSheet(browser, before, after, sheet, beforeLabel, label) {
  const ctx = await browser.newContext({ viewport: { width: 1600, height: 900 } });
  const page = await ctx.newPage();
  const uri = (f) => `data:image/png;base64,${fs.readFileSync(f).toString('base64')}`;
  await page.setContent(`<!doctype html><style>
    body{margin:0;background:#888;font:600 14px system-ui;display:flex;gap:12px;padding:12px;align-items:flex-start}
    figure{margin:0;background:#fff;color:#111} figcaption{padding:6px 8px}
    img{display:block;width:var(--w)}
  </style><figure><figcaption>BEFORE · ${beforeLabel}</figcaption><img id=a src="${uri(before)}"></figure>
  <figure><figcaption>AFTER · ${label}</figcaption><img id=b src="${uri(after)}"></figure>`);
  await page.evaluate(async () => {
    const imgs = [...document.images];
    await Promise.all(imgs.map((i) => (i.complete ? null : new Promise((r) => (i.onload = r)))));
    const w = Math.min(760, Math.max(...imgs.map((i) => i.naturalWidth)) / 2);
    document.body.style.setProperty('--w', `${w}px`);
  });
  await page.screenshot({ path: sheet, fullPage: true });
  await ctx.close();
}

async function main() {
  const a = parseArgs(process.argv.slice(2));
  const { base, route } = a;
  if (!base || !route) throw new Error('usage: shoot.mjs --base URL --route /path [--out dir] [--label name] [--states …] [--themes light,dark] [--compare round-0] [--sections css|none] [--auth module]');
  const outDir = path.resolve(a.out || '.refine/shots');
  const label = a.label || 'shot';
  const env = { ...readEnvFile(a.env && path.resolve(a.env)), ...process.env };
  const states = parseStates(a.states);
  const themes = parseThemes(a.themes);
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
  const full = [];
  const crops = [];
  const sheets = [];
  try {
    const viewports = [
      { name: 'desktop', width: 1440, height: 900, isMobile: false },
      { name: 'mobile', width: 390, height: 844, isMobile: true },
    ];
    for (const state of states) {
      const url = `${base}${route}${state.query || ''}`;
      const authFile = path.join(path.dirname(outDir), `auth-${state.name}.json`);
      for (const vp of viewports) {
        for (const theme of themes) {
          const ctx = await browser.newContext({
            viewport: { width: vp.width, height: vp.height },
            isMobile: vp.isMobile,
            hasTouch: vp.isMobile,
            deviceScaleFactor: vp.isMobile ? 2 : 1,
            colorScheme: theme,
            storageState: auth && fs.existsSync(authFile) ? authFile : undefined,
          });
          await ctx.addInitScript((t) => {
            try { localStorage.setItem('theme', t); } catch {}
          }, theme);
          const page = await ctx.newPage();
          await page.goto(url, { waitUntil: 'networkidle', timeout: 120_000 });
          if (auth && (await auth.isSignedOut(page))) {
            await auth.signIn({ page, base, state, env: { ...env, ...(state.env || {}) } });
            await ctx.storageState({ path: authFile });
            await page.goto(url, { waitUntil: 'networkidle', timeout: 120_000 });
          }
          await page.evaluate((t) => {
            const h = document.documentElement;
            h.classList.toggle('dark', t === 'dark');
            h.classList.toggle('light', t === 'light');
            h.dataset.theme = t;
            h.style.colorScheme = t;
          }, theme);
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
          const stem = path.join(outDir, `${label}-${state.name}-${vp.name}-${theme}`);
          await page.screenshot({ path: `${stem}.png`, fullPage: true });
          full.push(`${stem}.png`);
          if (theme === 'light') crops.push(...(await sectionCrops(page, a.sections, stem)));
          await ctx.close();
        }
      }
    }
    if (a.compare && a.compare !== label) {
      for (const file of full) {
        const { before, sheet } = pairNames(file, label, a.compare);
        if (!fs.existsSync(before)) continue;
        await compareSheet(browser, before, file, sheet, a.compare, label);
        sheets.push(sheet);
      }
    }
  } finally {
    await browser.close();
  }
  console.log([...full, ...crops, ...sheets].join('\n'));
}

if (process.argv[1]?.endsWith('shoot.mjs')) {
  main().catch((err) => {
    console.error(err.message);
    process.exitCode = 1;
  });
}
