#!/usr/bin/env bash
# sf-trunk-check.sh - read-only trunk-based delivery check for one pull request or the local branch.
#
# Usage:
#   sf-trunk-check.sh [--config <path>] <owner/repo> <pr-number-or-url>
#   sf-trunk-check.sh [--config <path>] --local
#
# The first form reads the pull request through gh. --local checks the current branch
# against origin/<default branch> with git only and no GitHub call; a worker runs it
# before reporting ready. Rules that need the PR (issue link, workflows) SKIP there.
#
# Rules, one numbered PASS/FAIL/SKIP line each:
#   1. base is the repository default branch
#   2. head branch matches none of long_lived_patterns (shell globs)
#   3. oldest commit on the branch is at most max_branch_age_hours old (author date)
#   4. added lines are at most max_changed_lines (deletions are free)
#   5. changed files are at most max_changed_files
#      Rules 4 and 5 ignore paths matching exclude_globs; "**/" also matches at the root.
#   6. PR body has "Part of #N", "Closes #N", "Fixes #N" or "Resolves #N" (require_issue_link);
#      SKIP when the repository has issues disabled
#   7. the branch has no merge commits (forbid_merge_commits)
#   8. every workflow in require_workflows has a completed successful run on the head SHA
# A null limit, a false switch or an empty workflow list turns that rule into SKIP.
#
# Config: --config, else $SF_TRUNK_CONFIG, else $FM_HOME/config/trunk.json; when the home
# has no file, factory/config-templates/trunk.json applies. Each key resolves from
# "repos"."<owner/repo>", then "default", then the template's "default"; null disables the rule.
#
# Environment: FM_HOME (default: this checkout), SF_GH (gh binary, default gh),
# SF_NOW (current Unix time, for tests).
# Exit: 0 every rule passed or skipped, 1 a rule failed, 2 usage, config, git or GitHub read error.
# jq programs are single-quoted on purpose; their $names are jq variables, and
# the rule_ functions are called through the rule table.
# shellcheck disable=SC2016,SC2329
set -eu
set -f # rule globs are matched with case, never against files

CODE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_HOME="${FM_HOME:-$CODE_ROOT}"
GH="${SF_GH:-gh}"
NOW="${SF_NOW:-$(date +%s)}"
CONFIG="${SF_TRUNK_CONFIG:-}"
LOCAL=0
POS=()

die() { echo "sf-trunk-check: $*" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) [ "$#" -ge 2 ] || die "--config needs a path"; CONFIG=$2; shift 2 ;;
    --local) LOCAL=1; shift ;;
    -h|--help) sed -n '2,/^set -eu/p' "$0" | sed '$d'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) POS+=("$1"); shift ;;
  esac
done
command -v jq >/dev/null || die "jq is required"

if [ -n "$CONFIG" ]; then
  [ -f "$CONFIG" ] || die "config not found: $CONFIG"
elif [ -f "$FM_HOME/config/trunk.json" ]; then
  CONFIG=$FM_HOME/config/trunk.json
else
  CONFIG=$CODE_ROOT/factory/config-templates/trunk.json
fi

api() { "$GH" api "$@" || die "GitHub read failed: $*"; }

if [ "$LOCAL" -eq 1 ]; then
  [ "${#POS[@]}" -eq 0 ] || die "--local takes no repository or PR"
  git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
  DEFAULT_BRANCH=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
  DEFAULT_BRANCH=${DEFAULT_BRANCH#origin/}
  if [ -z "$DEFAULT_BRANCH" ]; then
    git rev-parse --verify -q origin/main >/dev/null || die "cannot find origin's default branch (run git remote set-head origin --auto)"
    DEFAULT_BRANCH=main
  fi
  BASE="origin/$DEFAULT_BRANCH"
  REPO=$(git remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##' || true)
  HEAD_REF=$(git rev-parse --abbrev-ref HEAD)
  HEAD_SHA=$(git rev-parse HEAD)
  git merge-base "$BASE" HEAD >/dev/null || die "HEAD shares no history with $BASE"
  BASE_REF=$DEFAULT_BRANCH
  FIRST_COMMIT=$(git log --format=%at "$BASE..HEAD" | sort -n | head -n 1)
  CHANGES=$(git diff --numstat --no-renames "$BASE...HEAD" | awk -F'\t' '{ print ($1 == "-" ? 0 : $1) "\t" $3 }')
  HAS_ISSUES=true
  MERGES=$(git rev-list --merges "$BASE..HEAD" | cut -c1-7 | tr '\n' ' ')
  BODY=""
  echo "sf-trunk-check: local $HEAD_REF vs $BASE (head $HEAD_SHA)"
else
  [ "${#POS[@]}" -eq 2 ] || die "usage: sf-trunk-check.sh [--config <path>] <owner/repo> <pr-number-or-url> | --local"
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
  PR_JSON=$(api "repos/$REPO/pulls/$PR")
  HEAD_REF=$(jq -r '.head.ref' <<<"$PR_JSON")
  HEAD_SHA=$(jq -r '.head.sha' <<<"$PR_JSON")
  BASE_REF=$(jq -r '.base.ref' <<<"$PR_JSON")
  BODY=$(jq -r '.body // ""' <<<"$PR_JSON")
  REPO_JSON=$(api "repos/$REPO")
  DEFAULT_BRANCH=$(jq -r '.default_branch' <<<"$REPO_JSON")
  HAS_ISSUES=$(jq -r '.has_issues != false' <<<"$REPO_JSON")
  CHANGES=$(api --paginate "repos/$REPO/pulls/$PR/files?per_page=100")
  CHANGES=$(jq -rs 'add // [] | .[] | "\(.additions)\t\(.filename)"' <<<"$CHANGES")
  COMMITS=$(api --paginate "repos/$REPO/pulls/$PR/commits?per_page=100")
  COMMITS=$(jq -s 'add // []' <<<"$COMMITS")
  FIRST_COMMIT=$(jq -r 'map(.commit.author.date | fromdateiso8601) | min // empty' <<<"$COMMITS")
  MERGES=$(jq -r '.[] | select((.parents | length) > 1) | .sha[0:7]' <<<"$COMMITS" | tr '\n' ' ')
  echo "sf-trunk-check: $REPO#$PR ($HEAD_REF -> $BASE_REF, head $HEAD_SHA)"
fi
MERGES=${MERGES% }

TEMPLATE=$CODE_ROOT/factory/config-templates/trunk.json
CFG=$(jq -cn --arg repo "${REPO:-}" --slurpfile t "$TEMPLATE" --slurpfile c "$CONFIG" \
  '$t[0].default + ($c[0].default // {}) + ($c[0].repos[$repo] // {})') || die "unreadable config: $CONFIG"
# setting <key>: scalar as text, array as one item per line, null or missing as empty.
setting() { jq -r --arg k "$1" '.[$k] // empty | if type == "array" then .[] else tostring end' <<<"$CFG"; }
number() {
  local v
  v=$(setting "$1")
  case "$v" in ''|[0-9]|[1-9][0-9]*) printf '%s' "$v" ;; *) die "$1 must be a whole number or null in $CONFIG" ;; esac
}
switch() {
  case "$(setting "$1")" in true) echo 1 ;; false|'') echo 0 ;; *) die "$1 must be true or false in $CONFIG" ;; esac
}
on() { [ -n "$1" ] && echo 1 || echo 0; }

PATTERNS=$(setting long_lived_patterns | tr '\n' ' ')
MAX_AGE=$(number max_branch_age_hours)
MAX_LINES=$(number max_changed_lines)
MAX_FILES=$(number max_changed_files)
WORKFLOWS=$(setting require_workflows | tr '\n' ' ')
EXCLUDES=$(setting exclude_globs)

LINES=0
FILES=0
while IFS=$'\t' read -r added path; do
  [ -n "$path" ] || continue
  skip=0
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    # shellcheck disable=SC2254
    case "$path" in $g|${g#\*\*/}) skip=1; break ;; esac
  done <<<"$EXCLUDES"
  [ "$skip" -eq 0 ] || continue
  LINES=$((LINES + added))
  FILES=$((FILES + 1))
done <<<"$CHANGES"

# Each rule_<name> <limit> sets ST (PASS, FAIL or SKIP) and MSG.
rule_base() {
  if [ "$BASE_REF" = "$1" ]; then ST=PASS; MSG="base is the default branch: $BASE_REF"
  else ST=FAIL; MSG="base is $BASE_REF, default branch is $1"; fi
}
rule_long_lived() {
  local p
  for p in $1; do
    # shellcheck disable=SC2254
    case "$HEAD_REF" in $p) ST=FAIL; MSG="head branch $HEAD_REF matches long-lived pattern $p"; return ;; esac
  done
  ST=PASS; MSG="head branch $HEAD_REF is short-lived"
}
rule_branch_age() {
  [ -n "$FIRST_COMMIT" ] || { ST=SKIP; MSG="branch age (no commits off base)"; return; }
  local h=$(((NOW - FIRST_COMMIT) / 3600))
  if [ "$h" -le "$1" ]; then ST=PASS; else ST=FAIL; fi
  MSG="branch age ${h}h (limit ${1}h)"
}
rule_added_lines() { if [ "$LINES" -le "$1" ]; then ST=PASS; else ST=FAIL; fi; MSG="added lines $LINES (limit $1)"; }
rule_changed_files() { if [ "$FILES" -le "$1" ]; then ST=PASS; else ST=FAIL; fi; MSG="changed files $FILES (limit $1)"; }
rule_issue_link() {
  [ "$LOCAL" -eq 0 ] || { ST=SKIP; MSG="issue link (no PR body with --local)"; return; }
  [ "$HAS_ISSUES" = true ] || { ST=SKIP; MSG="issue link (issues are disabled on $REPO)"; return; }
  if printf '%s' "$BODY" | grep -qiE '(part of|closes|fixes|resolves)[[:space:]]+#[0-9]+'; then
    ST=PASS; MSG="PR body links an issue"
  else
    ST=FAIL; MSG="PR body needs Part of #N, Closes #N, Fixes #N or Resolves #N"
  fi
}
rule_merge_commits() {
  if [ -z "$MERGES" ]; then ST=PASS; MSG="no merge commits"
  else ST=FAIL; MSG="merge commits on the branch: $MERGES (rebase onto the default branch)"; fi
}
rule_workflows() {
  [ "$LOCAL" -eq 0 ] || { ST=SKIP; MSG="required workflows (no GitHub call with --local)"; return; }
  local wf runs bad=""
  for wf in $1; do
    runs=$(api "repos/$REPO/actions/workflows/$(jq -rn --arg s "$wf" '$s|@uri')/runs?head_sha=$HEAD_SHA&per_page=100")
    [ "$(jq --arg sha "$HEAD_SHA" '[.workflow_runs[] | select(.head_sha == $sha and .status == "completed" and .conclusion == "success")] | length' <<<"$runs")" -gt 0 ] || bad="$bad $wf"
  done
  if [ -z "$bad" ]; then ST=PASS; MSG="required workflows succeeded on $HEAD_SHA: $1"
  else ST=FAIL; MSG="no successful run on $HEAD_SHA for:$bad"; fi
}

# id|name|enabled|limit - a new rule is one row plus its rule_<name> function.
RULES="1|base|1|$DEFAULT_BRANCH
2|long_lived|1|$PATTERNS
3|branch_age|$(on "$MAX_AGE")|$MAX_AGE
4|added_lines|$(on "$MAX_LINES")|$MAX_LINES
5|changed_files|$(on "$MAX_FILES")|$MAX_FILES
6|issue_link|$(switch require_issue_link)|-
7|merge_commits|$(switch forbid_merge_commits)|-
8|workflows|$(on "$WORKFLOWS")|$WORKFLOWS"

FAILS=0
while IFS='|' read -r id name enabled limit; do
  if [ "$enabled" = 1 ]; then
    "rule_$name" "$limit"
  else
    ST=SKIP; MSG="$name (disabled in config)"
  fi
  printf '%s. %s %s\n' "$id" "$ST" "$MSG"
  [ "$ST" != FAIL ] || FAILS=$((FAILS + 1))
done <<<"$RULES"

if [ "$FAILS" -eq 0 ]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL ($FAILS failed)"
exit 1
