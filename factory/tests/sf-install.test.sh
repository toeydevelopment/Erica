#!/usr/bin/env bash
# sf-install.test.sh - exercise factory/bin/sf-install.sh in a throwaway home.
#
# Usage:
#   bash factory/tests/sf-install.test.sh
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="$HERE/../bin/sf-install.sh"
HOME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sf-install.XXXXXX")
trap 'rm -rf "$HOME_DIR"' EXIT
export FM_HOME="$HOME_DIR"
fail() { echo "FAIL: $1" >&2; exit 1; }

"$INSTALL" --dry-run | grep -q '^dry-run:' || fail "dry-run did not report"
[ ! -e "$HOME_DIR/config" ] || fail "dry-run wrote files"

"$INSTALL" | grep -q '^wrote:' || fail "first install did not write"
cmp -s <(tail -n +3 "$HOME_DIR/config/brief-include.md") "$HERE/../brief-include.md" || fail "composed file lacks shared text"
"$INSTALL" | grep -q '^unchanged:' || fail "second install was not idempotent"

echo 'Private rule.' > "$HOME_DIR/config/brief-include.private.md"
"$INSTALL" >/dev/null
tail -n 1 "$HOME_DIR/config/brief-include.md" | grep -qx 'Private rule.' || fail "private tail missing"

# Shared rules, a blank line, then the private tail, byte for byte.
printf 'Private rule.\n\nSecond private rule.\n' > "$HOME_DIR/config/brief-include.private.md"
"$INSTALL" | grep -q '^wrote:' || fail "changed private tail was not rewritten"
{ cat "$HERE/../brief-include.md"; printf '\n'; cat "$HOME_DIR/config/brief-include.private.md"; } > "$HOME_DIR/expected"
cmp -s <(tail -n +3 "$HOME_DIR/config/brief-include.md") "$HOME_DIR/expected" || fail "composition is not shared text then private tail"

# Guard hook check: warn per registered clone lacking sf-guard.sh, never install, exit 0.
mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects/bare" "$HOME_DIR/projects/guarded/.claude"
printf -- '- bare [direct-PR] - no settings (added 2026-10-24)\n- guarded - hooked (added 2026-10-24)\n- absent - not cloned (added 2026-10-24)\n' > "$HOME_DIR/data/projects.md"
echo '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"/x/factory/hooks/sf-guard.sh"}]}]}}' > "$HOME_DIR/projects/guarded/.claude/settings.json"
OUT=$("$INSTALL") || fail "guard hook warning changed the exit status"
for f in .claude/settings.json .codex/hooks.json .agents/hooks.json .pi/extensions/sf-guard.ts; do
  printf '%s\n' "$OUT" | grep -qxF "FAIL guard hook not installed in $HOME_DIR/projects/bare/$f" || fail "missing $f hook not reported"
done
[ "$(printf '%s\n' "$OUT" | grep -c '^FAIL.*/guarded/')" -eq 3 ] || fail "hooked claude settings reported"
printf '%s\n' "$OUT" | grep -q '/absent/' && fail "uncloned project reported"
printf '%s\n' "$OUT" | grep -q '^WARN codex: ' || fail "codex enforcement gap not warned"
[ ! -e "$HOME_DIR/projects/bare/.claude" ] || fail "check wrote project settings"
rm -rf "$HOME_DIR/data" "$HOME_DIR/projects"

# A copy of the overlay with FM_HOME unset installs into its own config/ only.
ISOLATED=$(mktemp -d "${TMPDIR:-/tmp}/sf-install-root.XXXXXX")
trap 'rm -rf "$HOME_DIR" "$ISOLATED"' EXIT
mkdir -p "$ISOLATED/factory"
cp -R "$HERE/../bin" "$HERE/../brief-include.md" "$ISOLATED/factory/"
mkdir -p "$ISOLATED/config"
echo 'Isolated tail.' > "$ISOLATED/config/brief-include.private.md"
env -u FM_HOME "$ISOLATED/factory/bin/sf-install.sh" | grep -q '^wrote:' || fail "isolated install did not write"
tail -n 1 "$ISOLATED/config/brief-include.md" | grep -qx 'Isolated tail.' || fail "isolated private tail missing"

echo handwritten > "$HOME_DIR/config/brief-include.md"
if "$INSTALL" >/dev/null 2>&1; then fail "overwrote a hand-written file"; fi
grep -qx handwritten "$HOME_DIR/config/brief-include.md" || fail "hand-written file changed"
echo "ok: sf-install"
