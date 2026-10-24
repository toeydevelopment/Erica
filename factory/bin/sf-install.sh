#!/usr/bin/env bash
# sf-install.sh - install the Software Factory overlay into one firstmate home.
#
# Usage:
#   factory/bin/sf-install.sh [--dry-run]
#
# Writes only under the active home's gitignored config/ directory, so tracked
# files stay untouched and bin/fm-update.sh keeps fast-forwarding.
# The one file it writes is config/brief-include.md, composed from
# factory/brief-include.md plus the optional private config/brief-include.private.md.
# Running it again with unchanged inputs changes nothing.
# An existing config/brief-include.md that this script did not compose is never
# overwritten; move its text into config/brief-include.private.md first.
#
# The active home is $FM_HOME, or this checkout when FM_HOME is unset.
# Secondmate homes do not inherit brief-include.md: run this script once per
# secondmate home, for example `FM_HOME=<secondmate home> factory/bin/sf-install.sh`.
#
# It also prints `FAIL guard hook not installed in <settings>` for each project in
# the home's data/projects.md whose clone under projects/ has a .claude/settings.json
# that does not name sf-guard.sh (or has none). This is a warning only: the exit
# status stays 0 so the brief include is still written, and nothing is installed;
# run factory/bin/sf-hooks-install.sh to add the hook. Only Claude settings are checked.
set -eu

CODE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_HOME="${FM_HOME:-$CODE_ROOT}"
MARKER='<!-- composed by factory/bin/sf-install.sh; edit factory/brief-include.md or config/brief-include.private.md -->'

DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  "") ;;
  *) echo "usage: sf-install.sh [--dry-run]" >&2; exit 2 ;;
esac

SHARED="$CODE_ROOT/factory/brief-include.md"
PRIVATE="$FM_HOME/config/brief-include.private.md"
TARGET="$FM_HOME/config/brief-include.md"

[ -f "$SHARED" ] || { echo "error: $SHARED is missing" >&2; exit 1; }
[ -d "$FM_HOME" ] || { echo "error: FM_HOME '$FM_HOME' is not a directory" >&2; exit 1; }

if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
  if [ -L "$TARGET" ] || ! head -n 1 "$TARGET" | grep -qxF "$MARKER"; then
    echo "error: $TARGET was not composed by sf-install.sh; move its text into $PRIVATE and remove it, then rerun" >&2
    exit 1
  fi
fi

COMPOSED=$(mktemp "${TMPDIR:-/tmp}/sf-install.XXXXXX")
trap 'rm -f "$COMPOSED"' EXIT
{
  printf '%s\n\n' "$MARKER"
  cat "$SHARED"
  if [ -f "$PRIVATE" ]; then
    printf '\n'
    cat "$PRIVATE"
  fi
} > "$COMPOSED"

if [ -f "$TARGET" ] && cmp -s "$COMPOSED" "$TARGET"; then
  echo "unchanged: $TARGET"
elif [ "$DRY_RUN" -eq 1 ]; then
  echo "dry-run: would write $TARGET"
else
  mkdir -p "$FM_HOME/config"
  cp "$COMPOSED" "$TARGET"
  echo "wrote: $TARGET"
fi
echo "note: brief-include.md is not inherited by secondmate homes; run this script once per secondmate home with FM_HOME set to it"

REGISTRY="$FM_HOME/data/projects.md"
if [ -f "$REGISTRY" ]; then
  sed -n 's/^- \([^ ]*\) .*/\1/p' "$REGISTRY" | while IFS= read -r name; do
    [ -d "$FM_HOME/projects/$name" ] || continue
    settings="$FM_HOME/projects/$name/.claude/settings.json"
    grep -qF 'sf-guard.sh' "$settings" 2>/dev/null || echo "FAIL guard hook not installed in $settings"
  done
fi
