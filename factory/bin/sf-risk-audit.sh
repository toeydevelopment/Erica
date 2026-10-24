#!/usr/bin/env bash
# sf-risk-audit.sh - read-only audit: did merged high-risk pull requests go through no-mistakes?
#
# Usage:
#   sf-risk-audit.sh --repo <owner/name> --paths <file> --since <YYYY-MM-DD> --until <YYYY-MM-DD>
#                    [--base <branch>] [--cache <dir>] [--offline]
#
# Online, it lists the repository's closed pull requests through `gh api` (GET only, every
# parameter in the URL), keeps those merged inside the closed UTC date window, and caches the
# raw JSON per pull request under <cache>/<owner>__<name>/: pr-<n>.json (the list item) and
# files-<n>.json (its changed files, fetched only when missing so an interrupted run resumes).
# --base keeps only pull requests merged into that branch (default: every base).
# --offline makes no GitHub call and recomputes from the cache alone. Both modes compute the
# output from the cache through the same code, so a rerun on the same cache is byte-identical.
#
# Paths file: one shell glob per line; "#" starts a comment, blank lines are ignored.
# "*" also matches "/", and a leading "**/" also matches at the root. A pull request is
# "high" when any changed file, or the old name of a renamed file, matches a glob; else "low".
#
# No-mistakes status, from the pull request body and its final head SHA:
#   compliant  upstream require-no-mistakes verify.py accepts it: signature line plus a v1
#              attestation bound to the head with review, test and document completed.
#              This is a structural check of author-editable text, not a signature check.
#   marker     a no-mistakes marker is present but verify.py rejects it (stale head, a skipped step)
#   none       no no-mistakes marker at all
# verify.py is fetched once at the commit pinned in .github/workflows/no-mistakes-required.yml
# and cached as <cache>/require-no-mistakes-<sha>.py; it runs with an empty environment, so it
# never makes its own GitHub lookup.
#
# Output: one line per pull request sorted by number, "<number> <tier> <status> <matched-path>"
# ("-" when low), then one "summary" line with the counts.
# Environment: FM_HOME (default cache root: $FM_HOME/data/sf-risk-audit/cache), SF_GH (gh binary).
# Exit: 0 audit printed, 2 usage, cache, verifier or GitHub read error.
set -eu
set -o pipefail
export LC_ALL=C

CODE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_HOME="${FM_HOME:-$CODE_ROOT}"
GH="${SF_GH:-gh}"
REPO="" PATHS="" SINCE="" UNTIL="" CACHE="" BASE="" OFFLINE=0
SIG='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
MARKERS=("$SIG" '<!-- no-mistakes-pipeline-attestation:v1 ' '<!-- no-mistakes-pr-appendix:v1')

die() { echo "sf-risk-audit: $*" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo|--paths|--since|--until|--cache|--base)
      [ "$#" -ge 2 ] || die "$1 needs a value"
      case "$1" in
        --repo) REPO=$2 ;; --paths) PATHS=$2 ;; --since) SINCE=$2 ;; --until) UNTIL=$2 ;; --cache) CACHE=$2 ;; --base) BASE=$2 ;;
      esac
      shift 2 ;;
    --offline) OFFLINE=1; shift ;;
    -h|--help) sed -n '2,/^set -eu/p' "$0" | sed '$d'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$REPO" in */*/*|/*|*/|'') die "--repo must be owner/name" ;; */*) : ;; *) die "--repo must be owner/name" ;; esac
[ -f "$PATHS" ] || die "--paths file not found: ${PATHS:-<unset>}"
for d in "$SINCE" "$UNTIL"; do
  [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--since and --until must be YYYY-MM-DD"
done
[[ ! "$SINCE" > "$UNTIL" ]] || die "--since is after --until"
command -v jq >/dev/null || die "jq is required"

CACHE=${CACHE:-$FM_HOME/data/sf-risk-audit/cache}
DIR=$CACHE/${REPO%%/*}__${REPO#*/}
PIN=$(sed -n 's#.*kunchenguid/no-mistakes/\.github/actions/require-no-mistakes@\([0-9a-f]\{40\}\).*#\1#p' \
  "$CODE_ROOT/.github/workflows/no-mistakes-required.yml" 2>/dev/null | head -n 1)
[ -n "$PIN" ] || die "cannot read the require-no-mistakes pin from .github/workflows/no-mistakes-required.yml"
VERIFIER=$CACHE/require-no-mistakes-$PIN.py

api() { "$GH" api "$@" || die "GitHub read failed: $*"; }

if [ "$OFFLINE" -eq 0 ]; then
  mkdir -p "$DIR"
  if [ ! -s "$VERIFIER" ]; then
    api -H 'Accept: application/vnd.github.raw' \
      "repos/kunchenguid/no-mistakes/contents/.github/actions/require-no-mistakes/verify.py?ref=$PIN" > "$VERIFIER.tmp"
    mv "$VERIFIER.tmp" "$VERIFIER"
  fi
  api --paginate "repos/$REPO/pulls?state=closed&per_page=100" |
    jq -c -s --arg s "$SINCE" --arg u "$UNTIL" \
      'add // [] | .[] | select(.merged_at != null and .merged_at[0:10] >= $s and .merged_at[0:10] <= $u)' |
    while IFS= read -r pr; do
      n=$(jq -r '.number' <<<"$pr")
      jq -S . <<<"$pr" > "$DIR/pr-$n.json"
      [ -s "$DIR/files-$n.json" ] && continue
      api --paginate "repos/$REPO/pulls/$n/files?per_page=100" | jq -S -s 'add // []' > "$DIR/files-$n.json.tmp"
      mv "$DIR/files-$n.json.tmp" "$DIR/files-$n.json"
    done
fi
[ -d "$DIR" ] || die "no cache for $REPO under $CACHE (run once without --offline)"

GLOBS=$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$PATHS" | grep -v '^$' || true)
# first_match <files>: print the first file (sorted) that matches any glob.
first_match() {
  local f g
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      # shellcheck disable=SC2254
      case "$f" in $g|${g#\*\*/}) printf '%s' "$f"; return ;; esac
    done <<<"$GLOBS"
  done <<<"$1"
}
# nm_status <pr.json>: compliant, marker or none.
nm_status() {
  local body m found=0
  body=$(jq -r '.body // ""' "$1")
  for m in "${MARKERS[@]}"; do case "$body" in *"$m"*) found=1 ;; esac; done
  [ "$found" -eq 1 ] || { echo none; return; }
  [ -s "$VERIFIER" ] || die "a PR body has a no-mistakes marker but $VERIFIER is not cached (run once without --offline)"
  if env -i PATH="$PATH" PR_BODY="$body" PR_HEAD_SHA="$(jq -r '.head.sha // ""' "$1")" \
    PR_NUMBER="$(jq -r '.number' "$1")" python3 -I "$VERIFIER" >/dev/null 2>&1; then
    echo compliant
  else
    echo marker
  fi
}

OUT=$(for f in "$DIR"/pr-*.json; do
  [ -e "$f" ] || continue
  jq -e --arg s "$SINCE" --arg u "$UNTIL" --arg b "$BASE" \
    '.merged_at != null and .merged_at[0:10] >= $s and .merged_at[0:10] <= $u and ($b == "" or .base.ref == $b)' \
    "$f" >/dev/null || continue
  n=$(jq -r '.number' "$f")
  [ -f "$DIR/files-$n.json" ] || die "files-$n.json missing from $DIR (run once without --offline)"
  match=$(first_match "$(jq -r '.[] | .filename, (.previous_filename // empty)' "$DIR/files-$n.json" | sort -u)")
  st=$(nm_status "$f") || exit 2 # errexit does not reach into this substitution
  echo "$n $([ -n "$match" ] && echo high || echo low) $st ${match:--}"
done | sort -n -k1,1)
[ -z "$OUT" ] || printf '%s\n' "$OUT"
awk -v repo="$REPO" -v win="$SINCE..$UNTIL" -v base="${BASE:-all}" -v pin="$PIN" '
  NF { t++ } $2 == "high" { h++; c[$3]++ }
  END { printf "summary repo=%s window=%s base=%s prs=%d high=%d high_compliant=%d high_marker=%d high_none=%d verifier=%s\n",
    repo, win, base, t, h, c["compliant"], c["marker"], c["none"], pin }' <<<"$OUT"
