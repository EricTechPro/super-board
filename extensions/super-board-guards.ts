/**
 * super-board guards — Pi port of the .claude guard hooks.
 *
 * Pi loads project extensions only after the project is trusted (headless lanes
 * pass `-a`). Each handler builds the same stdin JSON the Python guards already
 * understand, runs the guard with python3, and turns a PreToolUse deny into
 * `{ block, reason }`. A missing script or a broken guard never blocks a call,
 * exactly like the hooks' fail-open contract.
 *
 * Mirrors hooks/settings-snippet.json:
 *   Bash              -> guard-worktree-path, guard-delete-outside, guard-secrets, guard-key-literals
 *   Read|Grep         -> guard-secrets
 *   Edit|Write        -> guard-key-literals (PreToolUse; PostToolUse re-reads the file)
 *   session_start     -> cleanup-wt.py --auto --fetch (interactive sessions only)
 *   guard-protected-push runs only when `.claude/settings.json` wires it
 *   (install.sh --protect-main / onboard), the same opt-in switch Claude uses.
 *
 * Pi's tool names and inputs differ from Claude's; `claudeTool` and
 * `claudeInput` below are the whole translation layer.
 */
import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type Json = Record<string, unknown>;

/** Pi tool name -> the Claude hook tool name the Python guards match on. */
function claudeTool(toolName: string): string | undefined {
  switch (toolName) {
    case "bash":
      return "Bash";
    case "read":
      return "Read";
    case "grep":
      return "Grep";
    case "edit":
      return "Edit";
    case "write":
      return "Write";
    default:
      return undefined;
  }
}

/** Pi tool input -> the Claude hook tool_input fields the guards read. */
function claudeInput(toolName: string, input: Json): Json {
  if (toolName === "read") return { file_path: input.path };
  if (toolName === "write") return { file_path: input.path, content: input.content };
  if (toolName === "grep") return { pattern: input.pattern, path: input.path, glob: input.glob };
  if (toolName === "edit") {
    const edits = Array.isArray(input.edits) ? (input.edits as Json[]) : [];
    return {
      file_path: input.path,
      edits: edits.map((edit) => ({ old_string: edit.oldText, new_string: edit.newText })),
      new_string: edits.map((edit) => String(edit.newText ?? "")).join("\n"),
    };
  }
  return input;
}

/** Run one guard; returns its parsed stdout, or undefined on missing script/error/no output. */
function runGuard(file: string, project: string, payload: Json): Json | undefined {
  try {
    if (!existsSync(file)) return undefined;
    const result = spawnSync("python3", [file], {
      cwd: project,
      input: JSON.stringify(payload),
      encoding: "utf8",
      timeout: 10_000,
      env: { ...process.env, CLAUDE_PROJECT_DIR: project },
    });
    const text = (result.stdout ?? "").trim();
    return text ? (JSON.parse(text) as Json) : undefined;
  } catch {
    return undefined; // a broken guard must never block unrelated work
  }
}

function denyReason(output: Json | undefined): string | undefined {
  const specific = (output?.hookSpecificOutput ?? {}) as Json;
  if (specific.permissionDecision === "deny") {
    return String(specific.permissionDecisionReason ?? "Blocked by super-board guard");
  }
  return undefined;
}

/** The protect-main guard is opt-in: settings.json says whether it was wired. */
function protectsMain(project: string): boolean {
  try {
    const settings = join(project, ".claude", "settings.json");
    return existsSync(settings) && readFileSync(settings, "utf8").includes("guard-protected-push.py");
  } catch {
    return false;
  }
}

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
    const project = ctx.cwd;
    const tool = claudeTool(event.toolName);
    if (!tool) return undefined;
    const hooks = join(project, ".claude", "hooks");
    const guards: string[] = [];
    if (event.toolName === "bash") {
      guards.push(join(hooks, "guard-worktree-path.py"), join(hooks, "guard-delete-outside.py"));
      if (protectsMain(project)) guards.push(join(hooks, "guard-protected-push.py"));
    }
    if (event.toolName === "bash" || event.toolName === "read" || event.toolName === "grep") {
      guards.push(join(hooks, "guard-secrets.py"));
    }
    if (event.toolName === "bash" || event.toolName === "edit" || event.toolName === "write") {
      guards.push(join(hooks, "guard-key-literals.py"));
    }
    const payload = {
      hook_event_name: "PreToolUse",
      tool_name: tool,
      tool_input: claudeInput(event.toolName, event.input as Json),
      cwd: project,
    };
    for (const guard of guards) {
      const reason = denyReason(runGuard(guard, project, payload));
      if (reason) return { block: true, reason };
    }
    return undefined;
  });

  // PostToolUse key-literals: re-read what reached disk and surface the warning
  // with the tool result, where Claude's additionalContext would land.
  pi.on("tool_result", async (event, ctx) => {
    if (event.toolName !== "edit" && event.toolName !== "write") return undefined;
    if (event.isError) return undefined;
    const output = runGuard(join(ctx.cwd, ".claude", "hooks", "guard-key-literals.py"), ctx.cwd, {
      hook_event_name: "PostToolUse",
      tool_name: claudeTool(event.toolName)!,
      tool_input: claudeInput(event.toolName, event.input as Json),
      cwd: ctx.cwd,
    });
    const specific = (output?.hookSpecificOutput ?? {}) as Json;
    if (!specific.additionalContext) return undefined;
    return { content: [...event.content, { type: "text" as const, text: String(specific.additionalContext) }] };
  });

  // SessionStart parity: cleanup-wt --auto --fetch. Interactive sessions only —
  // headless lanes get the post-merge cleanup through the merge gate, and a
  // detached cleanup next to parallel lane worktrees would only add races.
  pi.on("session_start", async (_event, ctx) => {
    if (ctx.mode !== "tui" && ctx.mode !== "rpc") return;
    const script = join(ctx.cwd, ".claude", "hooks", "cleanup-wt.py");
    if (!existsSync(script)) return;
    try {
      spawn("python3", [script, "--auto", "--fetch"], {
        cwd: ctx.cwd,
        detached: true,
        stdio: "ignore",
        env: { ...process.env, CLAUDE_PROJECT_DIR: ctx.cwd },
      }).unref();
    } catch {
      // fail open, like the hook's `|| true`
    }
  });
}
