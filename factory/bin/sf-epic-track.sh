#!/usr/bin/env bash
# sf-epic-track.sh - show an epic issue's progress from GitHub, optionally on the epic itself.
#
# Usage:
#   sf-epic-track.sh [--config <path>] [--comment] [--label] <owner/repo> <epic-issue-number>
#
# An epic is an issue carrying the epic label (epic_label, default "epic").
# Its children are its GitHub sub-issues (when the API returns them) plus every issue and
# pull request whose body has a "Part of #<epic>" line, found through issue search.
# A child issue's PR is a child PR whose body closes it (Closes, Fixes or Resolves #N);
# when several do, merged beats open beats closed. A child PR that closes no child issue
# gets its own row.
#
# Output: one tab-separated row per child, sorted by number:
#   #<number>  <title>  <PR URL or "no PR">  <merged|open|closed|none>  <flag or ->
# The flag is the first word of a "Flag:" line in the PR body. The last line is
# "progress: merged X/N".
#
# Options:
#   --comment  upsert one progress checklist comment on the epic, marked <!-- sf-epic-track -->,
#              so a rerun edits the same comment
#   --label    ensure label epic:<slug> exists and every child carries it; the slug is the
#              "Slug:" line of the epic body, else the title in lower-case dashes
#   --config   epics config (default: $SF_EPICS_CONFIG, else $FM_HOME/config/epics.json,
#              else factory/config-templates/epics.json)
# Without --comment or --label the script only reads.
#
# Environment: FM_HOME (default: this checkout), SF_GH (gh binary, default gh).
# Exit: 0 done, 2 usage, config, not-an-epic or GitHub error.
# jq programs are single-quoted on purpose; their $names are jq variables.
# shellcheck disable=SC2016
set -eu

CODE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_HOME="${FM_HOME:-$CODE_ROOT}"
GH="${SF_GH:-gh}"
CONFIG="${SF_EPICS_CONFIG:-}"
COMMENT=0
LABEL=0
POS=()
MARKER='<!-- sf-epic-track -->'

die() { echo "sf-epic-track: $*" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) [ "$#" -ge 2 ] || die "--config needs a path"; CONFIG=$2; shift 2 ;;
    --comment) COMMENT=1; shift ;;
    --label) LABEL=1; shift ;;
    -h|--help) sed -n '2,/^set -eu/p' "$0" | sed '$d'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) POS+=("$1"); shift ;;
  esac
done
[ "${#POS[@]}" -eq 2 ] || die "usage: sf-epic-track.sh [--config <path>] [--comment] [--label] <owner/repo> <epic-issue-number>"
REPO=${POS[0]}
EPIC=${POS[1]}
case "$REPO" in */*) : ;; *) die "repo must be owner/repo" ;; esac
case "$EPIC" in ''|*[!0-9]*) die "epic must be an issue number" ;; esac
command -v jq >/dev/null || die "jq is required"

if [ -n "$CONFIG" ]; then
  [ -f "$CONFIG" ] || die "config not found: $CONFIG"
elif [ -f "$FM_HOME/config/epics.json" ]; then
  CONFIG=$FM_HOME/config/epics.json
else
  CONFIG=$CODE_ROOT/factory/config-templates/epics.json
fi
EPIC_LABEL=$(jq -r '.epic_label // "epic"' "$CONFIG") || die "unreadable config: $CONFIG"

api() { "$GH" api "$@" || die "GitHub call failed: $*"; }
uri() { jq -rn --arg s "$1" '$s|@uri'; }

ISSUE=$(api "repos/$REPO/issues/$EPIC")
jq -e --arg l "$EPIC_LABEL" 'any(.labels[]?; (.name // .) == $l)' <<<"$ISSUE" >/dev/null \
  || die "#$EPIC is not an epic: it has no '$EPIC_LABEL' label"
SLUG=$(jq -r '((.body // "") | capture("(?m)^Slug:[ \t]*(?<s>[^ \t\r\n]+)").s) // .title
  | ascii_downcase | gsub("[^a-z0-9]+"; "-") | gsub("^-+|-+$"; "")' <<<"$ISSUE")
[ -n "$SLUG" ] || die "cannot derive a slug for #$EPIC"

# Sub-issues are optional: older GitHub servers answer this endpoint with 404.
SUBS=$("$GH" api --paginate "repos/$REPO/issues/$EPIC/sub_issues?per_page=100" 2>/dev/null || echo '[]')
SUBS=$(jq -s 'add // []' <<<"$SUBS")
FOUND=$(api --paginate "search/issues?q=$(uri "repo:$REPO in:body \"Part of #$EPIC\"")&per_page=100")
FOUND=$(jq -s 'map(.items) | add // []' <<<"$FOUND")

ROWS=$(jq -n --arg repo "$REPO" --argjson epic "$EPIC" --argjson subs "$SUBS" --argjson found "$FOUND" '
  def rank: {merged: 3, open: 2, closed: 1}[.state];
  ($found | map(select((.body // "") | test("part of\\s+#\($epic)\\b"; "i")))) as $parts
  | ([$subs[] | select((.repository_url // "") | endswith("/repos/" + $repo))]
     + [$parts[] | select(.pull_request | not)]
     | map(select(.number != $epic)) | unique_by(.number)) as $issues
  | [$parts[] | select(.pull_request)
     | {number, title, url: .html_url, labels: [.labels[]?.name],
        state: (if .pull_request.merged_at then "merged" else .state end),
        flag: (((.body // "") | capture("(?m)^Flag:[ \t]*(?<f>[^ \t\r\n]+)").f) // "-"),
        closes: [(.body // "") | scan("(?i)\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\\s+#([0-9]+)") | .[0] | tonumber]}] as $prs
  | ($issues | map(.number)) as $nums
  | [$issues[] | . as $i
      | ([$prs[] | select(.closes | index($i.number))] | max_by([rank, .number])) as $pr
      | {number, title, labels: [.labels[]?.name], url: ($pr.url // "no PR"), state: ($pr.state // "none"),
         flag: ($pr.flag // "-"), prs: [$prs[] | select(.closes | index($i.number)) | {number, labels}]}]
    + [$prs[] | select([.closes[] | select(($nums | index(.)) != null)] | length == 0) | . + {prs: []}]
  | sort_by(.number)')

TOTAL=$(jq 'length' <<<"$ROWS")
MERGED=$(jq '[.[] | select(.state == "merged")] | length' <<<"$ROWS")

printf 'ISSUE\tTITLE\tPR\tSTATE\tFLAG\n'
jq -r '.[] | ["#\(.number)", (.title | gsub("[\t\r\n]"; " ")), .url, .state, .flag] | @tsv' <<<"$ROWS"
echo "progress: merged $MERGED/$TOTAL"

if [ "$COMMENT" -eq 1 ]; then
  TEXT=$(jq -r --arg marker "$MARKER" --arg progress "merged $MERGED/$TOTAL" '
    "\($marker)\n### Epic progress: \($progress)\n\n" + (map(
      "- [\(if .state == "merged" then "x" else " " end)] #\(.number) \(.title)"
      + (if .url == "no PR" then " - no PR" else " - \(.url) (\(.state))" end)
      + (if .flag == "-" then "" else ", flag `\(.flag)`" end)) | join("\n"))' <<<"$ROWS")
  COMMENTS=$(api --paginate "repos/$REPO/issues/$EPIC/comments?per_page=100")
  ID=$(jq -s -r --arg m "$MARKER" 'add // [] | map(select((.body // "") | contains($m))) | first | .id // empty' <<<"$COMMENTS")
  if [ -n "$ID" ]; then
    api -X PATCH "repos/$REPO/issues/comments/$ID" -f body="$TEXT" >/dev/null
    echo "comment: updated $ID"
  else
    api -X POST "repos/$REPO/issues/$EPIC/comments" -f body="$TEXT" >/dev/null
    echo "comment: created"
  fi
fi

if [ "$LABEL" -eq 1 ]; then
  NAME="epic:$SLUG"
  if ! "$GH" api "repos/$REPO/labels/$(uri "$NAME")" >/dev/null 2>&1; then
    api -X POST "repos/$REPO/labels" -f name="$NAME" -f color=5319e7 -f description="Part of epic #$EPIC" >/dev/null
    echo "label: created $NAME"
  fi
  for n in $(jq -r --arg l "$NAME" '[.[], .[].prs[]] | map(select(.labels | index($l) | not) | .number) | unique | .[]' <<<"$ROWS"); do
    api -X POST "repos/$REPO/issues/$n/labels" -f "labels[]=$NAME" >/dev/null
    echo "label: added $NAME to #$n"
  done
fi
