#!/usr/bin/env bash
# sf-pr-check.sh - deterministic pull request description check.
#
# Usage:
#   sf-pr-check.sh [options] <owner/repo> <pr-number-or-url>
#   sf-pr-check.sh [options] --body-file <path> [--title <title>] [--base <ref>]
#
# The first form reads the title, body, changed files and base-branch
# .github/pull_request_template.md from GitHub. The second form is a local
# pre-push run: the template comes from the current repository's working tree,
# the changed files from `git diff --name-only <base>...HEAD` (default base
# origin/HEAD, else origin/main), and the title rule is skipped without --title.
#
# Options:
#   --body-file <path>  check this body instead of a pull request
#   --title <title>     title to check in --body-file mode
#   --base <ref>        base ref for the changed-file list in --body-file mode
#   --config <path>     config (default: $SF_PR_CHECK_CONFIG, else $FM_HOME/config/pr-check.json,
#                       else built-in defaults); template in factory/config-templates/pr-check.json
#
# Config keys (all optional):
#   ui_globs   shell globs for UI files (default: *.html *.vue *.tsx *.jsx *.css)
#   disabled   rule names to skip, for example ["title"]
#
# Rules, printed as numbered PASS/FAIL/SKIP lines in the RULES table order:
#   1. headings            every `## ` heading of the template, in order; without a
#                          template: ## Summary, ## Evidence, ## Merge Danger
#   2. local-verification  a `## Local Verification` section with a command (inline code,
#                          fenced code or a `$ ` line) and a result word (pass, fail, ok,
#                          error) or a count
#   3. merge-danger        `## Merge Danger` has **Door:** one-way, two-way or mixed and
#                          **Blast Radius:**; SKIP when a repository template omits the section
#   4. ui-evidence         a changed file matching ui_globs needs an embedded image
#   5. no-placeholders     no <angle placeholder>, TODO or TBD outside code
#   6. title               Conventional Commits: type(scope)!: subject, scope optional
#   7. no-address          no "captain" and no greeting line (hi, hello, hey, dear, ahoy)
#
# Exit codes: 0 every rule passed or skipped, 1 at least one rule failed,
# 2 usage, config or GitHub read error.
# The GitHub client is `gh` unless $SF_GH names another executable (the tests use a fake).
set -eu

GH=${SF_GH:-gh}
BODY_FILE=""
TITLE=""
TITLE_SET=0
BASE=""
CONFIG=""
POS=()

die() { echo "sf-pr-check: $*" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --body-file) [ "$#" -ge 2 ] || die "--body-file needs a path"; BODY_FILE=$2; shift 2 ;;
    --title) [ "$#" -ge 2 ] || die "--title needs a value"; TITLE=$2; TITLE_SET=1; shift 2 ;;
    --base) [ "$#" -ge 2 ] || die "--base needs a ref"; BASE=$2; shift 2 ;;
    --config) [ "$#" -ge 2 ] || die "--config needs a path"; CONFIG=$2; shift 2 ;;
    -h|--help) sed -n '2,/^set -eu/p' "$0" | sed '$d'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) POS+=("$1"); shift ;;
  esac
done

[ -n "$CONFIG" ] || CONFIG=${SF_PR_CHECK_CONFIG:-}
[ -n "$CONFIG" ] || { [ -n "${FM_HOME:-}" ] && [ -f "$FM_HOME/config/pr-check.json" ] && CONFIG=$FM_HOME/config/pr-check.json; } || true
UI_GLOBS='*.html *.vue *.tsx *.jsx *.css'
DISABLED=""
if [ -n "$CONFIG" ]; then
  [ -f "$CONFIG" ] || die "config not found: $CONFIG"
  jq -e 'type == "object"' "$CONFIG" >/dev/null 2>&1 || die "unreadable config: $CONFIG"
  g=$(jq -r '(.ui_globs // empty) | join(" ")' "$CONFIG") || die "ui_globs must be an array: $CONFIG"
  [ -z "$g" ] || UI_GLOBS=$g
  DISABLED=$(jq -r '(.disabled // []) | join(" ")' "$CONFIG") || die "disabled must be an array: $CONFIG"
fi

TEMPLATE=""
HAS_TEMPLATE=0
FILES=""
HAS_FILES=0
if [ -n "$BODY_FILE" ]; then
  [ "${#POS[@]}" -eq 0 ] || die "--body-file takes no <owner/repo> <pr> arguments"
  [ -f "$BODY_FILE" ] || die "body file not found: $BODY_FILE"
  BODY=$(cat "$BODY_FILE")
  LABEL=$BODY_FILE
  if TOP=$(git rev-parse --show-toplevel 2>/dev/null); then
    if [ -f "$TOP/.github/pull_request_template.md" ]; then
      TEMPLATE=$(cat "$TOP/.github/pull_request_template.md"); HAS_TEMPLATE=1
    fi
    if [ -z "$BASE" ]; then
      for b in origin/HEAD origin/main; do
        git rev-parse --verify -q "$b" >/dev/null && { BASE=$b; break; }
      done
    fi
    if [ -n "$BASE" ]; then
      FILES=$(git diff --name-only "$BASE...HEAD") || die "git diff against $BASE failed"
      HAS_FILES=1
    fi
  fi
else
  [ "${#POS[@]}" -eq 2 ] || die "usage: sf-pr-check.sh [options] <owner/repo> <pr-number-or-url> | --body-file <path>"
  REPO=${POS[0]}
  PR=${POS[1]}
  case "$REPO" in */*) : ;; *) die "repo must be owner/repo" ;; esac
  case "$PR" in
    https://github.com/*/pull/*)
      URL_REPO=${PR#https://github.com/}
      URL_REPO=${URL_REPO%%/pull/*}
      [ "$URL_REPO" = "$REPO" ] || die "PR URL repo $URL_REPO does not match $REPO"
      PR=${PR##*/pull/}
      PR=${PR%%[!0-9]*}
      ;;
  esac
  case "$PR" in ''|*[!0-9]*) die "PR must be a number or a pull request URL" ;; esac
  PR_JSON=$("$GH" api "repos/$REPO/pulls/$PR") || die "GitHub read failed: repos/$REPO/pulls/$PR"
  TITLE=$(jq -r '.title // ""' <<<"$PR_JSON"); TITLE_SET=1
  BODY=$(jq -r '.body // ""' <<<"$PR_JSON")
  BASE_REF=$(jq -r '.base.ref' <<<"$PR_JSON")
  FILES_JSON=$("$GH" api --paginate "repos/$REPO/pulls/$PR/files?per_page=100") \
    || die "GitHub read failed: repos/$REPO/pulls/$PR/files"
  FILES=$(printf '%s' "$FILES_JSON" | jq -rs 'add // [] | .[].filename') || die "unreadable files list for $REPO#$PR"
  HAS_FILES=1
  # A missing template is a 404; anything else is a read error, never "no template".
  ERR=$(mktemp)
  trap 'rm -f "$ERR"' EXIT
  if TEMPLATE=$("$GH" api -H 'Accept: application/vnd.github.raw' \
      "repos/$REPO/contents/.github/pull_request_template.md?ref=$BASE_REF" 2>"$ERR"); then
    HAS_TEMPLATE=1
  elif grep -q 'HTTP 404' "$ERR"; then
    TEMPLATE=""
  else
    cat "$ERR" >&2
    die "GitHub read failed: repos/$REPO/contents/.github/pull_request_template.md"
  fi
  LABEL="$REPO#$PR"
fi

BODY=$(printf '%s\n' "$BODY" | tr -d '\r')
TEMPLATE=$(printf '%s\n' "$TEMPLATE" | tr -d '\r')
# Prose views: no fenced blocks; NOCODE also drops inline code and HTML comments.
strip_fences() { awk '/^[[:space:]]*(```|~~~)/ { f = !f; next } !f'; }
PROSE=$(printf '%s\n' "$BODY" | strip_fences)
NOCODE=$(printf '%s\n' "$PROSE" | sed -e 's/`[^`]*`//g' | perl -0pe 's/<!--.*?-->//gs')

headings() { strip_fences | sed -n 's/^## \(.*[^[:space:]]\)[[:space:]]*$/\1/p'; }
# section <heading>: the body lines under that `## ` heading, fences kept.
section() {
  printf '%s\n' "$BODY" | awk -v h="## $1" '
    /^[[:space:]]*(```|~~~)/ { f = !f }
    !f && /^## / { t = $0; sub(/[ \t]+$/, "", t); s = (t == h); next }
    s'
}
has_heading() { printf '%s\n' "$BODY" | headings | grep -qxF "$1"; }

DETAIL=""
rule_headings() {
  local want got missing="" h pos prev=0 prevh=""
  if [ "$HAS_TEMPLATE" -eq 1 ]; then
    want=$(printf '%s\n' "$TEMPLATE" | headings)
    [ -n "$want" ] || { DETAIL="template has no ## headings"; return 0; }
  else
    want=$'Summary\nEvidence\nMerge Danger'
  fi
  got=$(printf '%s\n' "$BODY" | headings)
  while IFS= read -r h; do
    pos=$(printf '%s\n' "$got" | grep -nxF -m 1 "$h" | cut -d: -f1)
    pos=${pos:-0}
    if [ "$pos" -eq 0 ]; then
      missing="$missing, missing: $h"
    elif [ "$pos" -lt "$prev" ]; then
      missing="$missing, out of order: $h before $prevh"
    else
      prev=$pos; prevh=$h
    fi
  done <<<"$want"
  DETAIL="$( [ "$HAS_TEMPLATE" -eq 1 ] && echo "template" || echo "default") headings $(printf '%s\n' "$want" | paste -sd '|' -)"
  [ -z "$missing" ] || { DETAIL="${missing#, }"; return 1; }
}

rule_local_verification() {
  local s
  has_heading "Local Verification" || { DETAIL="no ## Local Verification section"; return 1; }
  s=$(section "Local Verification")
  printf '%s\n' "$s" | grep -qE '`[^`]+`|^[[:space:]]*(```|~~~)|^[[:space:]]*\$ ' \
    || { DETAIL="no command line (inline code, fenced code or \$ prompt)"; return 1; }
  printf '%s\n' "$s" \
    | grep -qiE '(^|[^[:alnum:]_])(pass(ed|es)?|fail(ed|s|ures?)?|ok|errors?)([^[:alnum:]_]|$)|(^|[^[:alnum:]_.-])[0-9]+([^[:alnum:]_.-]|$)' \
    || { DETAIL="no result word (pass, fail, ok, error) or count"; return 1; }
  DETAIL="command and result present"
}

rule_merge_danger() {
  local s bad=""
  if ! has_heading "Merge Danger"; then
    if [ "$HAS_TEMPLATE" -eq 1 ] && ! printf '%s\n' "$TEMPLATE" | headings | grep -qxF "Merge Danger"; then
      DETAIL="SKIP: repository template has no ## Merge Danger"; return 0
    fi
    DETAIL="no ## Merge Danger section"; return 1
  fi
  s=$(section "Merge Danger")
  printf '%s\n' "$s" | grep -qiE '\*\*Door:\*\*[[:space:]]*(one-way|two-way|mixed)([^[:alnum:]-]|$)' || bad="$bad, **Door:** one-way|two-way|mixed"
  printf '%s\n' "$s" | grep -qE '\*\*Blast Radius:\*\*[[:space:]]*[^[:space:]]' || bad="$bad, **Blast Radius:**"
  [ -z "$bad" ] || { DETAIL="missing ${bad#, }"; return 1; }
  DETAIL="door and blast radius present"
}

rule_ui_evidence() {
  local f g ui=""
  [ "$HAS_FILES" -eq 1 ] || { DETAIL="SKIP: changed files unknown (no git base)"; return 0; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    set -f
    for g in $UI_GLOBS; do
      # shellcheck disable=SC2254
      case "$f" in $g) ui=$f; break ;; esac
    done
    set +f
    [ -z "$ui" ] || break
  done <<<"$FILES"
  [ -n "$ui" ] || { DETAIL="SKIP: no changed file matches $UI_GLOBS"; return 0; }
  printf '%s\n' "$PROSE" | grep -qiE '!\[[^]]*\]\([^)]+\)|<img[[:space:]][^>]*src=' \
    || { DETAIL="UI file $ui changed but the body embeds no image"; return 1; }
  DETAIL="UI file $ui changed and an image is embedded"
}

# A placeholder is <text> with a space or ellipsis and no attribute; tags such as <img src=..> pass.
rule_no_placeholders() {
  local hit
  hit=$(printf '%s\n' "$NOCODE" | grep -oE '<[^<>=/!][^<>=]*( |\.\.\.)[^<>=]*>|<\.\.\.>|(^|[^[:alnum:]_])(TODO|TBD)([^[:alnum:]_]|$)' | head -n 3 | paste -sd ' ' -) || true
  [ -z "$hit" ] || { DETAIL="found: $hit"; return 1; }
  DETAIL="none found"
}

rule_title() {
  [ "$TITLE_SET" -eq 1 ] || { DETAIL="SKIP: no --title given"; return 0; }
  printf '%s\n' "$TITLE" | grep -qE '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^()]+\))?!?: [^[:space:]]' \
    || { DETAIL="not type(scope): subject: $TITLE"; return 1; }
  DETAIL="$TITLE"
}

rule_no_address() {
  local hit
  hit=$(printf '%s\n' "$BODY" | grep -inE '(^|[^[:alnum:]_])captain([^[:alnum:]_]|$)|^[[:space:]]*(hi|hello|hey|dear|ahoy)([[:space:],!:]|$)' | head -n 3 | cut -c1-60 | paste -sd ' ' -) || true
  [ -z "$hit" ] || { DETAIL="direct address at line $hit"; return 1; }
  DETAIL="none found"
}

# id|name|enabled|predicate
RULES='1|headings|on|rule_headings
2|local-verification|on|rule_local_verification
3|merge-danger|on|rule_merge_danger
4|ui-evidence|on|rule_ui_evidence
5|no-placeholders|on|rule_no_placeholders
6|title|on|rule_title
7|no-address|on|rule_no_address'

echo "sf-pr-check: $LABEL"
FAILS=0
while IFS='|' read -r id name enabled fn; do
  case " $DISABLED " in *" $name "*) enabled=off ;; esac
  if [ "$enabled" != on ]; then
    echo "$id. SKIP $name: disabled by config"; continue
  fi
  DETAIL=""
  if "$fn"; then
    case "$DETAIL" in
      SKIP:*) echo "$id. SKIP $name:${DETAIL#SKIP:}" ;;
      *) echo "$id. PASS $name: $DETAIL" ;;
    esac
  else
    echo "$id. FAIL $name: $DETAIL"
    FAILS=$((FAILS + 1))
  fi
done <<<"$RULES"

if [ "$FAILS" -eq 0 ]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL ($FAILS failed)"
exit 1
