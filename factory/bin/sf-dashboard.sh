#!/usr/bin/env bash
# sf-dashboard.sh - open a local org-chart dashboard of this firstmate fleet.
#
# Usage:
#   factory/bin/sf-dashboard.sh [--port N] [--fixture <dir>] [--once]
#
# Serves factory/dashboard/ on http://127.0.0.1:<port>/ (default 8765) until
# interrupted. The page polls GET /api/fleet and GET /api/events?after=<seq>
# every 3 seconds. Nodes come from bin/fm-fleet-snapshot.sh --json; message
# flow comes from the fleet activity ledger (docs/fleet-ledger.md) and the
# task steering inboxes. It only reads fleet state.
#
# Options:
#   --port N         listen port; 0 picks a free one (the URL is printed)
#   --fixture <dir>  read a recorded home under <dir> instead of the live home:
#                    fleet-snapshot.json, recorded-state/, recorded-config/
#   --once           print the graph JSON (schema sf-dashboard.v1) and exit
#
# Environment:
#   FM_HOME  the home to show (default: this checkout)
#
# Exit codes: 0 ok, 1 runtime error, 2 usage error.
# See factory/docs/dashboard.md.
set -eu

CODE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_HOME="${FM_HOME:-$CODE_ROOT}"

usage() { echo "usage: sf-dashboard.sh [--port N] [--fixture <dir>] [--once]" >&2; exit 2; }

args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --port)
      [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || usage
      args+=(--port "$2"); shift 2 ;;
    --fixture)
      [ $# -ge 2 ] && [ -d "$2" ] || usage
      args+=(--fixture "$(cd "$2" && pwd)"); shift 2 ;;
    --once) args+=(--once); shift ;;
    *) usage ;;
  esac
done

command -v python3 >/dev/null || { echo "error: python3 is required" >&2; exit 1; }
export PYTHONDONTWRITEBYTECODE=1
exec python3 "$CODE_ROOT/factory/dashboard/server.py" --fm-root "$CODE_ROOT" --fm-home "$FM_HOME" ${args[@]+"${args[@]}"}
