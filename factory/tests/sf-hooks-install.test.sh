#!/usr/bin/env bash
# sf-hooks-install.test.sh - exercise factory/bin/sf-hooks-install.sh on temporary files.
#
# Usage:
#   bash factory/tests/sf-hooks-install.test.sh
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="$HERE/../bin/sf-hooks-install.sh"
DIR=$(mktemp -d "${TMPDIR:-/tmp}/sf-hooks-install.XXXXXX")
trap 'rm -rf "$DIR"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
S="$DIR/settings.json"
echo '{"model":"x","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/other.sh"}]}]}}' > "$S"
before=$(cat "$S")

"$INSTALL" "$S" | grep -q '^dry-run:' || fail "dry run did not report"
[ "$(cat "$S")" = "$before" ] || fail "dry run changed the file"
[ ! -e "$S.sf-bak" ] || fail "dry run wrote a backup"

"$INSTALL" "$S" --apply | grep -q '^wrote:' || fail "apply did not write"
[ "$(cat "$S.sf-bak")" = "$before" ] || fail "backup differs from original"
jq -e '.model == "x" and (.hooks.PreToolUse | length) == 2 and .hooks.PreToolUse[0].hooks[0].command == "/other.sh"' "$S" >/dev/null || fail "merge lost existing settings"
jq -e '.hooks.PreToolUse[1].hooks[0].command | endswith("factory/hooks/sf-guard.sh")' "$S" >/dev/null || fail "hook not added"

"$INSTALL" "$S" --apply | grep -q '^unchanged:' || fail "second apply was not idempotent"
[ "$(jq '.hooks.PreToolUse | length' "$S")" = 2 ] || fail "duplicate hook entry"

"$INSTALL" "$DIR/new.json" --apply >/dev/null
jq -e '.hooks.PreToolUse | length == 1' "$DIR/new.json" >/dev/null || fail "missing target not created"
[ ! -e "$DIR/new.json.sf-bak" ] || fail "backup made for a new file"

# Antigravity: a named hook beside existing ones, recognised again on rerun.
A="$DIR/proj/.agents/hooks.json"
mkdir -p "$(dirname "$A")"
echo '{"lint":{"PostToolUse":[]}}' > "$A"
"$INSTALL" "$A" --apply >/dev/null
jq -e '.lint and (.["sf-guard"].PreToolUse[0].hooks[0].command | endswith("factory/hooks/sf-guard.sh"))' "$A" >/dev/null || fail "agy hook not added"
"$INSTALL" "$A" --apply | grep -q '^unchanged:' || fail "agy apply was not idempotent"

# Pi: a copy of the adapter with the guard path pinned to this checkout.
T="$DIR/proj/.pi/extensions/sf-guard.ts"
"$INSTALL" "$T" | grep -q '^dry-run:' || fail "pi dry run did not report"
[ ! -e "$T" ] || fail "pi dry run wrote the extension"
"$INSTALL" "$T" --apply >/dev/null
grep -qxF "const GUARD = \"$(cd "$HERE/../hooks" && pwd)/sf-guard.sh\";" "$T" || fail "pi guard path not pinned"
"$INSTALL" "$T" --apply | grep -q '^unchanged:' || fail "pi apply was not idempotent"

echo '[1]' > "$DIR/bad.json"
if "$INSTALL" "$DIR/bad.json" --apply >/dev/null 2>&1; then fail "accepted a non-object file"; fi
if "$INSTALL" >/dev/null 2>&1; then fail "accepted no target"; fi
echo "ok: sf-hooks-install"
