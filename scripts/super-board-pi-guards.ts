import { spawnSync } from 'node:child_process';

export default function (pi) {
  function check(event, hookEventName) {
    const result = spawnSync(process.env.SUPER_BOARD_PI_PYTHON, [process.env.SUPER_BOARD_PI_GUARDS], {
      input: JSON.stringify({ ...event, hookEventName }), encoding: 'utf8', timeout: 35000,
      maxBuffer: 1024 * 1024,
    });
    if (result.error || result.status !== 0) return { block: true, reason: 'Pi guard adapter failed; preserve work and repair the hook' };
    try { return JSON.parse(result.stdout); }
    catch { return { block: true, reason: 'Pi guard adapter returned invalid output' }; }
  }
  pi.on('tool_call', (event) => check(event, 'PreToolUse'));
  pi.on('tool_result', (event) => {
    const result = check(event, 'PostToolUse');
    if (result.block) return { content: [{ type: 'text', text: result.reason }], isError: true };
  });
}
