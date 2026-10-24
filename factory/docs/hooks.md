# Guard hooks

`factory/hooks/sf-guard.sh` is a pre-tool hook that stops three mistakes before a worker makes them.
The tool call arrives as JSON on stdin, and the hook blocks by exiting 2 with the reason on stderr (on agy, by printing `{"decision":"deny"}` with exit 0, that harness's contract).
Any other outcome means no decision, so a missing `jq` or a malformed payload never blocks work.
The script header lists the payload shape it reads from each harness.

## What it blocks

- Reading a secret file with the Read tool or a Bash reader such as `cat`, `grep` or `source`.
  Secret files are `.env`, `.env.*`, `*.pem`, `id_*`, `.credentials*`, `*credentials.json`, `.netrc`, and token files named `token`, `.token`, `*.token` or `token.json`.
  Names ending in `.example`, `.sample`, `.template` or `.pub` are allowed.
- Writing a literal secret with Write, Edit or MultiEdit: AWS access key ids, GitHub, Slack, Anthropic and OpenAI style tokens, and PEM private key headers.
- `rm`, `unlink`, `rmdir` or `shred` on a path outside the project root (the hook's `cwd`).
  A path built from a variable or command substitution is blocked because it cannot be checked.

The Bash checks are a heuristic over the command text, not a sandbox.
They catch the common accidents; they do not stop a determined bypass such as an encoded command.

## Exceptions for firstmate

- Anything under `$FM_HOME/state/` and `$FM_HOME/data/` is never blocked, so status files, steering inboxes, task tokens and reports stay readable.
- `gh auth` needs no exception: `gh auth token` and `~/.config/gh/hosts.yml` match no secret pattern.
- Firstmate scripts that source files such as `config/x-mode.env` do so inside the script, outside any tool call, so the hook never sees them.
- To allow more paths, set `SF_GUARD_ALLOW` to a colon-separated list of path prefixes in the worker's environment.

## Harness support

Each harness reads the guard from its own project file; install every file a project's workers may use.

| Harness | Project file | Verified (2026-10-24) |
|---|---|---|
| Claude Code | `.claude/settings.json` | existing guard tests |
| Grok | `.claude/settings.json` (Grok also reads Claude settings) | not verified: Grok was not signed in on the recording host, so no Grok payload is recorded; its documented camelCase shape is accepted but untested |
| Codex | `.codex/hooks.json` | codex-cli 0.163.0, live block of a secret read and an `apply_patch` key write |
| Antigravity (agy) | `.agents/hooks.json` | agy 1.4.5, live block of a secret read |
| Pi | `.pi/extensions/sf-guard.ts`, the `factory/hooks/sf-guard-pi.ts` adapter | Pi 1.1.0, live block of a secret read and a key write |

Limits a project file cannot fix:

- Firstmate launches Codex crewmates and scouts with Codex's hook layer disabled (see `bin/fm-spawn.sh`), so the guard does not run for them even when installed.
- Grok and Pi run project hooks and extensions only in a trusted folder; Pi workers show a trust prompt on first launch in a slot.
- Codex edits arrive as `apply_patch`; only the added lines are scanned, and a patch never counts as a secret read.

## Install

```sh
factory/bin/sf-hooks-install.sh <file>            # dry run, prints the diff
factory/bin/sf-hooks-install.sh <file> --apply    # backs up to <file>.sf-bak, then writes
```

The file's path picks the format, as the script header lists.
The installer never runs on its own and touches only the file you name.
It keeps existing settings and hooks, and running it again changes nothing.

`factory/bin/sf-install.sh` reports, without installing anything, each harness file above that lacks the guard in a registered project clone, as `FAIL guard hook not installed in <file>`, plus a `WARN` line for Codex's disabled hook layer and for Grok's unverified payload; neither changes its exit status.

## Tests

`bash factory/tests/sf-guard.test.sh` feeds sample hook JSON to the guard.
`bash factory/tests/sf-guard.test.sh` also replays `factory/tests/fixtures/harness-payloads.jsonl`: Codex, Pi and agy payloads recorded live with a capture hook, with ids and paths replaced.
`bash factory/tests/sf-hooks-install.test.sh` runs the installer against temporary files.
`bash factory/tests/sf-install.test.sh` pins the presence warning.
