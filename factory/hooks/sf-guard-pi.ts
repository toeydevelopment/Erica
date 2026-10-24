// sf-guard-pi.ts - Pi extension that runs factory/hooks/sf-guard.sh before every tool call.
//
// Pi has no shell hook file; its pre-tool hook is the extension `tool_call` event, which
// blocks by returning {block: true}. This adapter only forwards {toolName, input, cwd}
// to sf-guard.sh, which owns every decision, and blocks when the guard exits 2.
// Load it with `pi -e factory/hooks/sf-guard-pi.ts`, or install a copy with
// factory/bin/sf-hooks-install.sh <project>/.pi/extensions/sf-guard.ts --apply,
// which pins the guard path below to this checkout.
import { spawnSync } from "node:child_process";

const GUARD = new URL("./sf-guard.sh", import.meta.url).pathname;

export default function (pi: any) {
  pi.on("tool_call", async (event: any, ctx: any) => {
    const r = spawnSync(GUARD, {
      input: JSON.stringify({ toolName: event.toolName, input: event.input, cwd: ctx?.cwd ?? process.cwd() }),
      encoding: "utf8",
    });
    return r.status === 2 ? { block: true, reason: r.stderr.trim() } : {};
  });
}
