#!/usr/bin/env bash
# ui-refine-loop setup: resolve the pluggable settings, build the worktree, start
# the dev server on a free port, and tear it down again. Run from the repo root.
#
#   refine-setup.sh detect [--config <path>]
#       Print the resolved settings as JSON: config `refine.*` keys first, then
#       auto-detection from package.json and lockfiles, then defaults. Warnings
#       (Impeccable missing, a bad refine.impeccable) go to stderr in a banner
#       and into the JSON's `warnings` array; never silent.
#
#   refine-setup.sh up --slug <slug> [--config <path>]
#       New worktree <root>/refine-<slug> on branch refine/<slug> from HEAD
#       (root = $SUPER_REFINE_WT_ROOT or .claude/worktrees). Then node_modules, env files, dev server, readiness wait. Prints JSON:
#       {worktree, runDir, port, baseUrl, pid, base, nodeModules}. The base sha
#       and the branch it came from land in <runDir>/base and <runDir>/base-branch.
#
#   refine-setup.sh down --run <runDir>
#       Stop the dev server started by `up`.
#
# Exit codes: 0 ok · 64 usage · 69 dev server never became ready · 70 setup failed
set -euo pipefail

die() { echo "refine-setup: $1" >&2; exit "${2:-70}"; }
command -v node >/dev/null || die "node is required" 70

cmd="${1:-}"; shift || true
CONFIG="" SLUG="" RUN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --slug) SLUG="$2"; shift 2 ;;
    --run) RUN="$2"; shift 2 ;;
    *) die "unknown arg $1" 64 ;;
  esac
done

if [ -z "$CONFIG" ] && [ -f .claude/super-board/active ]; then
  CONFIG=".claude/super-board/configs/$(tr -d '[:space:]' < .claude/super-board/active).json"
fi

detect() {
  CONFIG="$CONFIG" HOME="$HOME" node <<'JS'
const fs = require('fs'), path = require('path')
const readJson = (f) => {
  if (!f || !fs.existsSync(f)) return null
  const txt = fs.readFileSync(f, 'utf8')
  try { return JSON.parse(txt) } catch { return JSON.parse(txt.replace(/^\s*\/\/.*$/gm, '')) }
}
const cfg = readJson(process.env.CONFIG) || {}
const r = cfg.refine || {}
const pkg = readJson('package.json') || {}
const scripts = pkg.scripts || {}
const exists = (f) => fs.existsSync(f)

const pm = exists('bun.lockb') || exists('bun.lock') ? 'bun'
  : exists('pnpm-lock.yaml') ? 'pnpm'
  : exists('yarn.lock') ? 'yarn' : 'npm'
const lockfile = { bun: exists('bun.lock') ? 'bun.lock' : 'bun.lockb', pnpm: 'pnpm-lock.yaml', yarn: 'yarn.lock', npm: 'package-lock.json' }[pm]
const run = (s, extra = '') => pm === 'npm' ? `npm run ${s}${extra ? ' -- ' + extra : ''}` : `${pm} run ${s}${extra ? ' ' + extra : ''}`

// Dev command: $PORT is exported before it runs. Frameworks that ignore the
// PORT env var get an explicit --port flag.
let dev = r.dev_command || null
if (!dev) {
  const s = scripts.dev ? 'dev' : scripts.start ? 'start' : null
  if (s) dev = /\b(vite|astro|next|nuxt|remix|svelte-kit|storybook)\b/.test(scripts[s]) ? run(s, '--port $PORT') : run(s)
}

const pick = (...names) => names.find((n) => scripts[n])
const checks = r.check_commands || (() => {
  const out = []
  const tc = pick('typecheck', 'type-check', 'check-types', 'tsc'); if (tc) out.push(run(tc))
  const lint = pick('lint'); if (lint) out.push(run(lint))
  const test = pick('test:unit', 'test'); if (test && !/no test specified/.test(scripts[test])) out.push(`CI=1 ${run(test)}`)
  return out.length ? out : (cfg.verify_commands || [])
})()

const envFiles = r.env_files || ['.env', '.env.local', '.env.development.local'].filter(exists)

const home = process.env.HOME || ''
const warnings = []

// Impeccable ships in two layouts: v4.0.x runs Node scripts
// (scripts/detect.mjs, scripts/context.mjs); v4.4+ ships a launcher
// (scripts/impeccable <verb>). Accept a skill dir, the launcher, or any file
// inside scripts/, and normalise to {layout, skillDir, detect, context}.
const sh = (p) => (/^[\w@%+=:,./-]+$/.test(p) ? p : `'${p.replace(/'/g, `'\\''`)}'`)
const resolveImpeccable = (p) => {
  if (!p) return null
  let dir = path.resolve(p)
  if (!exists(dir)) return null
  if (fs.statSync(dir).isFile()) dir = path.dirname(dir)
  if (path.basename(dir) === 'scripts') dir = path.dirname(dir)
  const s = (f) => path.join(dir, 'scripts', f)
  let version = null
  try { version = (fs.readFileSync(path.join(dir, 'SKILL.md'), 'utf8').match(/^version:\s*["']?([^\s"']+)/m) || [])[1] || null } catch {}
  const base = { skillDir: dir, version, reference: path.join(dir, 'reference') }
  if (exists(s('impeccable'))) {
    return { ...base, layout: 'launcher', detect: `${sh(s('impeccable'))} detect --json`, context: `${sh(s('impeccable'))} context` }
  }
  if (exists(s('detect.mjs'))) {
    return { ...base, layout: 'node', detect: `node ${sh(s('detect.mjs'))} --json`, context: exists(s('context.mjs')) ? `node ${sh(s('context.mjs'))}` : null }
  }
  return null
}

// Look in .claude/skills and .agents/skills of this dir and every parent (a
// project nested inside a bigger repo inherits its skills), then under ~.
const candidates = []
for (let d = process.cwd(); ; d = path.dirname(d)) {
  candidates.push(path.join(d, '.claude/skills/impeccable'), path.join(d, '.agents/skills/impeccable'))
  if (path.dirname(d) === d) break
}
candidates.push(path.join(home, '.claude/skills/impeccable'), path.join(home, '.agents/skills/impeccable'))

let impeccable = null
if (r.impeccable) {
  impeccable = resolveImpeccable(r.impeccable)
  if (!impeccable) warnings.push(`refine.impeccable = ${r.impeccable} is not an Impeccable install (no scripts/impeccable and no scripts/detect.mjs)`)
}
if (!impeccable) impeccable = candidates.map(resolveImpeccable).find(Boolean) || null
if (!impeccable) warnings.push('Impeccable NOT FOUND: the loop will use the built-in rubric (references/rubric.md). Scores are not Impeccable scores. Install the impeccable skill under .claude/skills or .agents/skills, or set refine.impeccable.')

const tastePath = r.taste_file || 'docs/design/taste.md'

console.log(JSON.stringify({
  config: process.env.CONFIG && exists(process.env.CONFIG) ? process.env.CONFIG : null,
  packageManager: pm,
  lockfile: exists(lockfile) ? lockfile : null,
  devCommand: dev,
  readyPath: r.ready_path || '/',
  checks,
  envFiles,
  authScript: r.auth_script || null,
  states: r.states || [{ name: 'main' }],
  rounds: r.rounds || 5,
  critic: impeccable ? 'impeccable' : 'rubric',
  impeccable,
  tasteFile: tastePath,
  tasteExists: exists(tastePath),
  warnings,
}, null, 2))
for (const w of warnings) console.error(`\n!!! ui-refine-loop WARNING: ${w}\n`)
JS
}

field() { node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));const v=j[process.argv[1]];process.stdout.write(v==null?"":Array.isArray(v)?v.join("\n"):String(v))' "$1"; }

# node_modules for the worktree: an APFS clone (real directory, near-zero disk;
# a symlink breaks Turbopack, which rejects links outside the project root), a
# reflink copy on btrfs/xfs, else a frozen-lockfile install. A lockfile that
# differs from HEAD always installs fresh.
node_modules() {
  local wt="$1" pm="$2" lock="$3"
  [ -f "$wt/package.json" ] || { echo "none"; return; }
  [ -d "$wt/node_modules" ] && { echo "present"; return; }
  if [ -d node_modules ] && { [ -z "$lock" ] || git diff --quiet HEAD -- "$lock"; }; then
    if cp -c -R node_modules "$wt/node_modules" 2>/dev/null; then
      [ -L "$wt/node_modules/node_modules" ] && rm "$wt/node_modules/node_modules"
      echo "apfs-clone"; return
    fi
    rm -rf "$wt/node_modules"
    if cp -R --reflink=always node_modules "$wt/node_modules" 2>/dev/null; then
      echo "reflink-copy"; return
    fi
    rm -rf "$wt/node_modules"
  fi
  case "$pm" in
    npm)  if [ -n "$lock" ]; then (cd "$wt" && npm ci --silent); else (cd "$wt" && npm install --silent); fi ;;
    pnpm) (cd "$wt" && pnpm install --frozen-lockfile --silent) ;;
    yarn) (cd "$wt" && (yarn install --immutable --silent 2>/dev/null || yarn install --frozen-lockfile --silent)) ;;
    bun)  (cd "$wt" && bun install --frozen-lockfile) ;;
  esac >&2 || die "dependency install failed in $wt" 70
  echo "install"
}

free_port() { node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'; }

case "$cmd" in
  detect) detect ;;

  up)
    S=$(detect)
    PM=$(field packageManager <<<"$S"); LOCK=$(field lockfile <<<"$S")
    DEV=$(field devCommand <<<"$S"); READY=$(field readyPath <<<"$S")
    [ -n "$DEV" ] || die "no dev command: set refine.dev_command in the super-board config" 70
    [ -n "$SLUG" ] || die "up needs --slug" 64
    ROOT="${SUPER_REFINE_WT_ROOT:-.claude/worktrees}"
    mkdir -p "$ROOT"
    WT="$(cd "$ROOT" && pwd)/refine-$SLUG"; RUN="$WT.run"
    [ -e "$WT" ] && die "$WT already exists — finish or remove the previous run first" 70
    git worktree add -q -b "refine/$SLUG" "$WT" HEAD >&2
    mkdir -p "$RUN/shots"
    git -C "$WT" rev-parse HEAD > "$RUN/base"
    git rev-parse --abbrev-ref HEAD > "$RUN/base-branch" 2>/dev/null || true
    NM=$(node_modules "$WT" "$PM" "$LOCK")
    while IFS= read -r f || [ -n "$f" ]; do [ -n "$f" ] && [ -f "$f" ] && [ ! -e "$WT/$f" ] && cp "$f" "$WT/$f" || true; done < <(field envFiles <<<"$S")
    PORT=$(free_port)
    # Every fd redirected, or the server holds the caller's $(…) pipe open forever.
    ( cd "$WT" && PORT="$PORT" exec nohup sh -c "$DEV" ) > "$RUN/dev.log" 2>&1 < /dev/null &
    echo $! > "$RUN/dev.pid"
    BASE="http://localhost:$PORT"
    for _ in $(seq 1 180); do
      code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE$READY" || true)
      case "$code" in 2??|3??|401|403) break ;; esac
      kill -0 "$(cat "$RUN/dev.pid")" 2>/dev/null || die "dev server exited — see $RUN/dev.log" 69
      sleep 1
    done
    case "$code" in 2??|3??|401|403) ;; *) die "dev server not ready after 180s ($code) — see $RUN/dev.log" 69 ;; esac
    printf '{"worktree":"%s","runDir":"%s","port":%s,"baseUrl":"%s","pid":%s,"base":"%s","nodeModules":"%s"}\n' \
      "$WT" "$RUN" "$PORT" "$BASE" "$(cat "$RUN/dev.pid")" "$(cat "$RUN/base")" "$NM"
    ;;

  down)
    [ -n "$RUN" ] && [ -f "$RUN/dev.pid" ] || die "down needs --run <runDir> with a dev.pid" 64
    PID=$(cat "$RUN/dev.pid")
    kill_tree() { local p; for p in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$p"; done; kill "$1" 2>/dev/null || true; }
    kill_tree "$PID"
    rm -f "$RUN/dev.pid"
    echo "stopped dev server $PID"
    ;;

  *) die "usage: refine-setup.sh detect|up|down …" 64 ;;
esac
