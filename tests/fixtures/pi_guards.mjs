#!/usr/bin/env node
// Harness for extensions/super-board-guards.ts — run via tests/test-pi-guards.sh.
//
// Stubs Pi's extension API (registering only what the extension uses), plants
// fake .claude/hooks/*.py guards that log the payload they received, and drives
// the handlers directly. No real Pi, no network: node + python3 only. Node's
// built-in type stripping runs the TypeScript extension as-is.
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const PACK = process.argv[2];
let failures = 0;
const ok = (condition, message) => {
  if (!condition) {
    failures += 1;
    console.error(`FAIL: ${message}`);
  }
};
const until = async (check, ms = 3000) => {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (await check()) return true;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  return false;
};

const root = await mkdtemp(join(tmpdir(), "sb-pi-guards-"));
const hooks = join(root, ".claude", "hooks");
const log = join(root, "guards.jsonl");
await mkdir(hooks, { recursive: true });
process.env.GUARD_LOG = log;

async function stub(dir, name, body) {
  const text = [
    "#!/usr/bin/env python3",
    "import json, os, sys",
    'payload = json.loads(sys.stdin.read() or "{}")',
    'with open(os.environ["GUARD_LOG"], "a") as fh:',
    `    fh.write(json.dumps({"guard": "${name}", "project": os.environ.get("CLAUDE_PROJECT_DIR"), "payload": payload}) + "\\n")`,
    body,
  ].join("\n");
  await writeFile(join(dir, name), `${text}\n`, { mode: 0o755 });
}

// worktree: allows. delete: crashes with garbage (fail-open case). secrets:
// denies reads/greps. key-literals: warns only after edits. push: denies.
await stub(hooks, "guard-worktree-path.py", "pass");
await stub(hooks, "guard-delete-outside.py", 'print("boom")\nsys.exit(1)');
await stub(
  hooks,
  "guard-secrets.py",
  'if payload.get("tool_name") in ("Read", "Grep"):\n' +
    '    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "secret file blocked"}}))',
);
await stub(
  hooks,
  "guard-key-literals.py",
  'if payload.get("hook_event_name") == "PostToolUse":\n' +
    '    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "live key on disk at line 3"}}))',
);
await stub(
  hooks,
  "guard-protected-push.py",
  'print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "protected branch"}}))',
);

const module = await import(pathToFileURL(join(PACK, "extensions", "super-board-guards.ts")).href);
const handlers = new Map();
module.default({ on: (name, handler) => handlers.set(name, handler) });
const ctx = { cwd: root, mode: "print", hasUI: false };

const readLog = async () => {
  try {
    return (await readFile(log, "utf8")).split("\n").filter(Boolean).map((line) => JSON.parse(line));
  } catch {
    return [];
  }
};
const clearLog = () => writeFile(log, "");

// Unmapped tools (find, ls, custom) never spawn a guard.
await clearLog();
ok((await handlers.get("tool_call")({ toolName: "find", input: { pattern: "x" } }, ctx)) === undefined, "unmapped tools pass through");
ok((await readLog()).length === 0, "unmapped tools spawn no guard");

// Bash runs worktree/delete/secrets/key-literals; the crash in delete fails open.
await clearLog();
let result = await handlers.get("tool_call")({ toolName: "bash", input: { command: "git push origin main" } }, ctx);
ok(result === undefined, "a crashing guard never blocks a call");
let entries = await readLog();
ok(entries.filter((entry) => entry.guard === "guard-protected-push.py").length === 0, "the opt-in push guard stays off until settings.json wires it");
for (const name of ["guard-worktree-path.py", "guard-delete-outside.py", "guard-secrets.py", "guard-key-literals.py"]) {
  ok(entries.some((entry) => entry.guard === name), `bash reaches ${name}`);
}
const worktree = entries.find((entry) => entry.guard === "guard-worktree-path.py");
ok(
  worktree.payload.hook_event_name === "PreToolUse" &&
    worktree.payload.tool_name === "Bash" &&
    worktree.payload.tool_input.command === "git push origin main" &&
    worktree.payload.cwd === root &&
    worktree.project === root,
  "bash arrives in the Claude hook payload shape",
);

// Wired settings.json turns the opt-in push guard on.
await writeFile(
  join(root, ".claude", "settings.json"),
  JSON.stringify({ hooks: { PreToolUse: [{ hooks: [{ command: 'python3 "$CLAUDE_PROJECT_DIR"/.claude/hooks/guard-protected-push.py' }] }] } }),
);
await clearLog();
result = await handlers.get("tool_call")({ toolName: "bash", input: { command: "git push origin main" } }, ctx);
ok(result?.block === true && result.reason === "protected branch", "a wired push guard blocks with its reason");
ok((await readLog()).some((entry) => entry.guard === "guard-protected-push.py"), "a wired push guard runs for bash");
await rm(join(root, ".claude", "settings.json"));

// Read: path -> file_path; secrets denies; key-literals never sees it.
await clearLog();
result = await handlers.get("tool_call")({ toolName: "read", input: { path: ".env", offset: 1, limit: 5 } }, ctx);
ok(result?.block === true && result.reason === "secret file blocked", "reading a secret is blocked");
entries = await readLog();
ok(
  entries.length === 1 && entries[0].guard === "guard-secrets.py" && entries[0].payload.tool_name === "Read" && entries[0].payload.tool_input.file_path === ".env",
  "read maps path to file_path and runs only the secrets guard",
);

// Grep: pattern/path/glob survive the translation.
await clearLog();
result = await handlers.get("tool_call")({ toolName: "grep", input: { pattern: "KEY", path: "src", glob: "*.env" } }, ctx);
ok(result?.block === true, "grepping for secrets is blocked");
entries = await readLog();
ok(
  entries[0].payload.tool_name === "Grep" && entries[0].payload.tool_input.pattern === "KEY" && entries[0].payload.tool_input.path === "src" && entries[0].payload.tool_input.glob === "*.env",
  "grep maps pattern/path/glob",
);

// Edit: edits[] -> new_string and edits[].new_string.
await clearLog();
result = await handlers.get("tool_call")({ toolName: "edit", input: { path: "app/config.py", edits: [{ oldText: 'K = ""', newText: 'K = "sk-live-123"' }] } }, ctx);
ok(result === undefined, "edit passes when guards allow");
entries = await readLog();
ok(
  entries.length === 1 &&
    entries[0].payload.tool_name === "Edit" &&
    entries[0].payload.tool_input.file_path === "app/config.py" &&
    entries[0].payload.tool_input.new_string === 'K = "sk-live-123"' &&
    entries[0].payload.tool_input.edits[0].new_string === 'K = "sk-live-123"',
  "edit maps edits to the Claude Edit shape",
);

// Write: content survives.
await clearLog();
await handlers.get("tool_call")({ toolName: "write", input: { path: "notes.txt", content: "hello" } }, ctx);
entries = await readLog();
ok(
  entries[0].payload.tool_name === "Write" && entries[0].payload.tool_input.file_path === "notes.txt" && entries[0].payload.tool_input.content === "hello",
  "write maps path/content",
);

// PostToolUse key-literals warning rides with the tool result.
const appended = await handlers.get("tool_result")(
  { toolName: "edit", input: { path: "notes.txt", edits: [] }, content: [{ type: "text", text: "edited" }], isError: false },
  ctx,
);
ok(appended?.content?.length === 2 && appended.content[1].text === "live key on disk at line 3", "a post-write warning is appended to the tool result");
ok((await handlers.get("tool_result")({ toolName: "edit", input: {}, content: [], isError: true }, ctx)) === undefined, "failed tool results are left alone");
ok((await handlers.get("tool_result")({ toolName: "read", input: {}, content: [], isError: false }, ctx)) === undefined, "only edit/write results are re-checked");

// A project without hook scripts stays untouched (fail-open install).
const empty = await mkdtemp(join(tmpdir(), "sb-pi-empty-"));
ok((await handlers.get("tool_call")({ toolName: "bash", input: { command: "rm -rf /" } }, { cwd: empty, mode: "print" })) === undefined, "missing guard scripts leave calls untouched");

// SessionStart parity: interactive only, cleanup-wt --auto --fetch, detached.
const emptyHooks = join(empty, ".claude", "hooks");
const cleanupMarker = join(empty, "cleanup.args");
await mkdir(emptyHooks, { recursive: true });
await writeFile(
  join(emptyHooks, "cleanup-wt.py"),
  '#!/usr/bin/env python3\nimport os, sys\nopen(os.path.join(os.path.dirname(__file__), "..", "..", "cleanup.args"), "w").write(" ".join(sys.argv[1:]))\n',
  { mode: 0o755 },
);
await handlers.get("session_start")({}, { cwd: empty, mode: "print" });
await new Promise((resolve) => setTimeout(resolve, 150));
ok(!(await readFile(cleanupMarker, "utf8").catch(() => "")), "print-mode session start skips cleanup");
await handlers.get("session_start")({}, { cwd: empty, mode: "tui" });
ok(await until(async () => (await readFile(cleanupMarker, "utf8").catch(() => "")) === "--auto --fetch"), "interactive session start runs cleanup-wt --auto --fetch");

await rm(root, { recursive: true, force: true });
await rm(empty, { recursive: true, force: true });
if (failures > 0) {
  console.error(`${failures} assertion(s) failed`);
  process.exit(1);
}
console.log("PASS: test-pi-guards.sh (payload mapping, fail-open, opt-in push, session start)");
