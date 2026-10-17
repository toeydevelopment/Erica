#!/usr/bin/env bash
# Tests factory/bin/sf-epic-track.sh against recorded GitHub API JSON through a fake gh; no network.
# The fixtures in tests/fixtures/epic-track/good are an epic with sub-issues and "Part of" children;
# each case copies them and changes one thing.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACK="$HERE/../bin/sf-epic-track.sh"
FAKE="$HERE/fixtures/epic-track/fake-gh.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TAB=$'\t'

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

# scenario <name> [jq-edit-spec...]: copy the good fixtures; each spec is "<file>=<jq filter>".
scenario() {
  local name=$1 spec f
  shift
  rm -rf "${TMP:?}/$name"
  cp -R "$HERE/fixtures/epic-track/good" "$TMP/$name"
  for spec in "$@"; do
    f=${spec%%=*}
    jq "${spec#*=}" "$TMP/$name/$f" > "$TMP/$name/$f.new" && mv "$TMP/$name/$f.new" "$TMP/$name/$f"
  done
}

# run_track <scenario> [args...]: sets OUT and CODE; the call log is $TMP/<scenario>.log.
run_track() {
  local name=$1
  shift
  : > "$TMP/$name.log"
  OUT=$(SF_GH="$FAKE" SF_FIXTURES="$TMP/$name" SF_GH_LOG="$TMP/$name.log" FM_HOME="$TMP/nohome" "$TRACK" "$@" 2>&1)
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
run_track good acme/app 3
expect "rows for sub-issues and Part of children" 0 \
  "#4${TAB}Widget API${TAB}https://github.com/acme/app/pull/8${TAB}merged${TAB}widget_v2" \
  "#5${TAB}Widget UI${TAB}https://github.com/acme/app/pull/13${TAB}open${TAB}-" \
  "#10${TAB}Widget docs${TAB}no PR${TAB}none${TAB}-" \
  "#11${TAB}chore: widget cleanup${TAB}https://github.com/acme/app/pull/11${TAB}open${TAB}widget_cleanup" \
  "progress: merged 1/4"
printf '%s\n' "$OUT" | grep -qE '^#(6|9|12|13)	' && fail "other-repo, Part of #30 and attached PRs must not get their own row"
pass "other repo, other epic and attached PRs excluded"
[ "$(printf '%s\n' "$OUT" | sed -n 2p | cut -f1)" = "#4" ] || fail "rows not sorted by number"
pass "rows sorted by number"
grep -q -- '-X' "$TMP/good.log" && fail "read-only run issued a write"
pass "read-only without --comment or --label"

scenario nosub
rm "$TMP/nosub/sub_issues.json"
run_track nosub acme/app 3
expect "missing sub-issues API falls back to Part of children" 0 "#10" "#11" "progress: merged 0/2"

run_track good --comment acme/app 3
expect "--comment edits the marked comment" 0 "comment: updated 78"
grep -q '^api -X PATCH repos/acme/app/issues/comments/78 -f body=<!-- sf-epic-track -->' "$TMP/good.log" || fail "PATCH call missing"
# shellcheck disable=SC2016
grep -qF -- '- [x] #4 Widget API - https://github.com/acme/app/pull/8 (merged), flag `widget_v2`' "$TMP/good.log" || fail "checked row missing"
grep -qF -- '- [ ] #10 Widget docs - no PR' "$TMP/good.log" || fail "unchecked row missing"
grep -q 'POST' "$TMP/good.log" && fail "created a second comment"
pass "comment body is a checklist"

scenario fresh 'comments.json=[.[0]]'
run_track fresh --comment acme/app 3
expect "--comment creates the comment once" 0 "comment: created"
grep -q '^api -X POST repos/acme/app/issues/3/comments -f body=<!-- sf-epic-track -->' "$TMP/fresh.log" || fail "POST call missing"
pass "create call targets the epic"

run_track good --label acme/app 3
expect "--label creates the label and labels children" 0 "label: created epic:widget-v2" \
  "label: added epic:widget-v2 to #4" "label: added epic:widget-v2 to #9" "label: added epic:widget-v2 to #13"
case "$OUT" in *"to #8"*) fail "relabelled a child that already carries the label" ;; esac
grep -q '^api -X POST repos/acme/app/issues/10/labels -f labels\[\]=epic:widget-v2$' "$TMP/good.log" || fail "label call wrong"
pass "label calls skip labelled children"

scenario haslabel 'issue-3.json=.body="no slug line" | .title="Widget V2: Faster!"'
echo '{"name":"epic:widget-v2-faster"}' > "$TMP/haslabel/label.json"
run_track haslabel --label acme/app 3
expect "slug falls back to the title" 0 "label: added epic:widget-v2-faster to #4"
case "$OUT" in *"label: created"*) fail "recreated an existing label" ;; esac
pass "existing label not recreated"

scenario notepic 'issue-3.json=.labels=[{"name":"bug"}]'
run_track notepic acme/app 3
expect "issue without the epic label is an error" 2 "not an epic"
echo '{"epic_label":"initiative"}' > "$TMP/epics.json"
scenario custom 'issue-3.json=.labels=[{"name":"initiative"}]'
run_track custom --config "$TMP/epics.json" acme/app 3
expect "epic label is configurable" 0 "progress: merged 1/4"
run_track good --config "$TMP/missing.json" acme/app 3
expect "missing config is an error" 2 "config not found"
run_track good acme/app three
expect "bad epic argument is an error" 2 "epic must be an issue number"
rm "$TMP/good/search.json"
run_track good acme/app 3
expect "GitHub read failure is an error" 2 "GitHub call failed"
