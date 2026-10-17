#!/usr/bin/env bash
# Tests factory/bin/sf-trunk-check.sh: PR mode against recorded GitHub API JSON through a fake gh,
# and --local mode against a throwaway git repository. No network.
# The fixtures in tests/fixtures/trunk-check/good are a passing PR; each case copies them and breaks one thing.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../bin/sf-trunk-check.sh"
FAKE="$HERE/fixtures/trunk-check/fake-gh.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
NOW=$(jq -n '"2026-10-16T12:00:00Z" | fromdateiso8601')

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cat > "$TMP/config.json" <<'JSON'
{"default":{"long_lived_patterns":["epic/*","release/*"],"max_branch_age_hours":48,"max_changed_lines":400,
 "max_changed_files":20,"require_issue_link":true,"forbid_merge_commits":true,"require_workflows":[]},
 "repos":{"acme/app":{"require_workflows":["e2e.yml"]}}}
JSON

# scenario <name> [jq-edit-spec...]: copy the good fixtures; each spec is "<file>=<jq filter>".
scenario() {
  local name=$1 spec f
  shift
  rm -rf "${TMP:?}/$name"
  cp -R "$HERE/fixtures/trunk-check/good" "$TMP/$name"
  for spec in "$@"; do
    f=${spec%%=*}
    jq "${spec#*=}" "$TMP/$name/$f" > "$TMP/$name/$f.new" && mv "$TMP/$name/$f.new" "$TMP/$name/$f"
  done
}

# run_check <scenario> [args...]: sets OUT and CODE; the call log is $TMP/<scenario>.log.
run_check() {
  local name=$1
  shift
  : > "$TMP/$name.log"
  OUT=$(SF_GH="$FAKE" SF_FIXTURES="$TMP/$name" SF_GH_LOG="$TMP/$name.log" SF_NOW="$NOW" FM_HOME="$TMP/nohome" \
    "$CHECK" "$@" 2>&1)
  CODE=$?
}

expect() { # expect <label> <exit-code> <text-in-output>...
  local label=$1 want=$2 t
  shift 2
  [ "$CODE" = "$want" ] || fail "$label: exit $CODE, wanted $want"$'\n'"$OUT"
  for t in "$@"; do
    case "$OUT" in *"$t"*) : ;; *) fail "$label: missing '$t'"$'\n'"$OUT" ;; esac
  done
  pass "$label"
}

scenario good
run_check good --config "$TMP/config.json" acme/app 7
expect "good PR passes" 0 "1. PASS base is the default branch: main" "2. PASS head branch fm/widget" \
  "3. PASS branch age 10h (limit 48h)" "4. PASS added lines 120" "5. PASS changed files 3" \
  "6. PASS" "7. PASS no merge commits" "8. PASS required workflows succeeded" "RESULT: PASS"
grep -q -- '-X' "$TMP/good.log" && fail "check issued a write request"
pass "read-only: no write calls"
run_check good --config "$TMP/config.json" acme/app https://github.com/acme/app/pull/7
expect "PR URL accepted" 0 "RESULT: PASS"
run_check good --config "$TMP/config.json" other/app 7
expect "empty workflow list skips rule 8" 0 "8. SKIP workflows" "RESULT: PASS"
OUT=$(SF_GH="$FAKE" SF_FIXTURES="$TMP/good" SF_GH_LOG="$TMP/good.log" SF_NOW="$NOW" FM_HOME="$TMP/nohome" "$CHECK" acme/app 7 2>&1); CODE=$?
expect "template applies when the home has no config" 0 "8. SKIP" "6. SKIP issue_link" "4. PASS added lines 120 (limit 400)"
mkdir -p "$TMP/home/config"
echo '{"default":{"max_changed_lines":100,"max_branch_age_hours":null,"require_issue_link":false}}' > "$TMP/home/config/trunk.json"
OUT=$(SF_GH="$FAKE" SF_FIXTURES="$TMP/good" SF_GH_LOG="$TMP/good.log" SF_NOW="$NOW" FM_HOME="$TMP/home" "$CHECK" acme/app 7 2>&1); CODE=$?
expect "home config is read, null and false skip, missing keys keep template defaults" 1 \
  "4. FAIL added lines 120 (limit 100)" "3. SKIP branch_age" "6. SKIP issue_link" "5. PASS changed files 3 (limit 20)" "7. PASS"

scenario badbase 'pull-7.json=.base.ref="epic/widgets"'
run_check badbase --config "$TMP/config.json" acme/app 7
expect "non-default base fails" 1 "1. FAIL base is epic/widgets, default branch is main" "RESULT: FAIL (1 failed)"
scenario epichead 'pull-7.json=.head.ref="release/2026.10"'
run_check epichead --config "$TMP/config.json" acme/app 7
expect "long-lived head fails" 1 "2. FAIL head branch release/2026.10 matches long-lived pattern release/*"
scenario old 'commits.json=.[0].commit.author.date="2026-10-13T12:00:00Z"'
run_check old --config "$TMP/config.json" acme/app 7
expect "old branch fails" 1 "3. FAIL branch age 72h (limit 48h)"
scenario big 'files.json=.[0].additions=381 | . + [range(18) | {filename: "src/f\(.).go", additions: 0}]'
run_check big --config "$TMP/config.json" acme/app 7
expect "oversized diff fails" 1 "4. FAIL added lines 421 (limit 400)" "5. FAIL changed files 21 (limit 20)" "RESULT: FAIL (2 failed)"
echo '{"default":{"exclude_globs":[]}}' > "$TMP/noexclude.json"
run_check good --config "$TMP/noexclude.json" acme/app 7
expect "exclude_globs can be emptied" 1 "4. FAIL added lines 1820" "5. PASS changed files 6"
scenario noissues 'repo.json=.has_issues=false' 'pull-7.json=.body="no link"'
run_check noissues --config "$TMP/config.json" acme/app 7
expect "issues disabled skips the issue link" 0 "6. SKIP issue link (issues are disabled on acme/app)"
scenario nolink 'pull-7.json=.body="Adds the widget. See #3."'
run_check nolink --config "$TMP/config.json" acme/app 7
expect "missing issue link fails" 1 "6. FAIL PR body needs Part of #N"
scenario link 'pull-7.json=.body="fixes  #3"'
run_check link --config "$TMP/config.json" acme/app 7
expect "any closing keyword is a link" 0 "6. PASS"
scenario merge 'commits.json=.[1].parents += [{"sha":"9999999"}]'
run_check merge --config "$TMP/config.json" acme/app 7
expect "merge commit fails" 1 "7. FAIL merge commits on the branch: 2222222"
scenario e2efail 'runs-e2e.yml.json=.workflow_runs |= map(select(.conclusion != "success"))'
run_check e2efail --config "$TMP/config.json" acme/app 7
expect "workflow without success fails" 1 "8. FAIL no successful run on cccc2222cccc2222cccc2222cccc2222cccc2222 for: e2e.yml"
echo '{"default":{"max_changed_lines":"lots"}}' > "$TMP/bad.json"
run_check good --config "$TMP/bad.json" acme/app 7
expect "bad limit is an error" 2 "max_changed_lines must be a whole number"
run_check good --config "$TMP/config.json" acme/app seven
expect "bad PR argument is an error" 2 "PR must be"
rm "$TMP/good/pull-7.json"
run_check good --config "$TMP/config.json" acme/app 7
expect "GitHub read failure is an error" 2 "GitHub read failed"

# --local: a bare origin with main, then a feature branch with dated commits.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git init -q --bare -b main "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
cd "$TMP/work" || fail "no clone"
git config user.email t@example.com
git config user.name t
commit() { # commit <file> <lines> <author-date>
  seq "$2" > "$1"
  git add "$1"
  GIT_AUTHOR_DATE="$3" GIT_COMMITTER_DATE="$3" git commit -q -m "$1"
}
commit base.txt 1 2026-10-01T00:00:00Z
git push -q origin main
git remote set-head origin --auto >/dev/null
git checkout -q -b fm/widget
commit a.txt 10 2026-10-16T06:00:00Z
commit b.txt 5 2026-10-16T09:00:00Z
mkdir -p factory/tests/fixtures
commit factory/tests/fixtures/big.json 900 2026-10-16T09:00:00Z
git rm -q base.txt && git commit -q -m "drop base"

run_local() { OUT=$(SF_GH=/nonexistent SF_NOW="$NOW" FM_HOME="$TMP/nohome" "$CHECK" --config "$TMP/config.json" "$@" 2>&1); CODE=$?; }
run_local --local
expect "--local passes a fresh small branch" 0 "local fm/widget vs origin/main" "1. PASS" "3. PASS branch age 6h" \
  "4. PASS added lines 15" "5. PASS changed files 3" "6. SKIP issue link" "7. PASS" "8. SKIP" "RESULT: PASS"

git checkout -q main
commit c.txt 1 2026-10-16T10:00:00Z
git push -q origin main
git checkout -q fm/widget
GIT_AUTHOR_DATE=2026-10-16T11:00:00Z GIT_COMMITTER_DATE=2026-10-16T11:00:00Z git merge -q --no-edit origin/main
run_local --local
expect "--local flags a merge from base" 1 "7. FAIL merge commits on the branch"
git reset -q --hard HEAD~1

git checkout -q -b epic/widgets
commit big.txt 500 2026-10-10T00:00:00Z
run_local --local
expect "--local flags long-lived, old and big" 1 "2. FAIL head branch epic/widgets" "3. FAIL branch age 156h" "4. FAIL added lines 515"
