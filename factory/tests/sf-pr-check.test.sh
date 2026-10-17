#!/usr/bin/env bash
# Tests factory/bin/sf-pr-check.sh with body fixtures built here; no network.
# good_body is a passing body; each case edits it to break exactly one rule.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../bin/sf-pr-check.sh"
FAKE="$HERE/fixtures/pr-check/fake-gh.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Body-file runs happen outside any git repository unless a case makes one.
cd "$TMP" || exit 1

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

good_body() {
  cat <<'MD'
## Summary
Adds a check.

<!-- reviewer note: <keep this comment> -->
```sh
echo "<not a placeholder inside code>" # TODO in code is fine
```

## Evidence
- **Before:** nothing checked.  **After:** `sf-pr-check.sh` prints PASS.

## Merge Danger
**Door:** two-way
**Blast Radius:** low - a wrong rule blocks a PR until reverted

## Local Verification
- `bash factory/tests/sf-pr-check.test.sh` - 20 ok, 0 failed
MD
}

# body <name> [sed-expr...]: write good_body edited by each sed expression to $TMP/<name>.md.
body() {
  local name=$1 e
  shift
  good_body > "$TMP/$name.md"
  for e in "$@"; do
    sed -e "$e" "$TMP/$name.md" > "$TMP/$name.new" && mv "$TMP/$name.new" "$TMP/$name.md"
  done
}

run() { # run <args...>: sets OUT and CODE
  OUT=$(SF_PR_CHECK_CONFIG="" FM_HOME="$TMP/nohome" "$CHECK" "$@" 2>&1)
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

body good
run --body-file "$TMP/good.md" --title "feat(factory): add sf-pr-check"
expect "good body passes" 0 "1. PASS headings" "2. PASS local-verification" "3. PASS merge-danger" \
  "4. SKIP ui-evidence" "5. PASS no-placeholders" "6. PASS title" "7. PASS no-address" "RESULT: PASS"
run --body-file "$TMP/good.md"
expect "no --title skips the title rule" 0 "6. SKIP title: no --title given"
printf '%s' "$(good_body | sed 's/$/\r/')" > "$TMP/crlf.md"
run --body-file "$TMP/crlf.md" --title "fix: crlf body"
expect "CRLF body passes" 0 "RESULT: PASS"

body nosummary '/^## Summary/d'
run --body-file "$TMP/nosummary.md"
expect "missing default heading fails" 1 "1. FAIL headings: missing: Summary" "RESULT: FAIL (1 failed)"

body order '/^## Summary/d' '$a\
## Summary'
run --body-file "$TMP/order.md"
expect "out-of-order heading fails" 1 "1. FAIL headings: out of order: Evidence before Summary"

body fencedheading '/^## Summary/d' '/^```sh/a\
## Summary'
run --body-file "$TMP/fencedheading.md"
expect "heading inside a code fence does not count" 1 "1. FAIL headings: missing: Summary"

body nolv '/^## Local Verification/,/^- `bash/d'
run --body-file "$TMP/nolv.md"
expect "missing Local Verification fails" 1 "2. FAIL local-verification: no ## Local Verification section"

body nocmd 's/^- `bash factory.*$/- ran the tests, 20 ok/'
run --body-file "$TMP/nocmd.md"
expect "Local Verification without a command fails" 1 "2. FAIL local-verification: no command line"

printf '%s\n\n## Local Verification\n- `npm run test:e2e`\n' "$(good_body | sed '/^## Local Verification/,$d')" > "$TMP/nores.md"
run --body-file "$TMP/nores.md"
expect "Local Verification without a result fails" 1 "2. FAIL local-verification: no result word"

body codedresult 's/^- `bash factory.*$/- `bash x.test.sh` - `ok: x`/'
run --body-file "$TMP/codedresult.md"
expect "result word inside inline code counts" 0 "2. PASS local-verification"

body nodoor 's/^\*\*Door:\*\* two-way/**Door:** maybe/'
run --body-file "$TMP/nodoor.md"
expect "bad door fails" 1 "3. FAIL merge-danger: missing **Door:**"

body noblast '/Blast Radius/d'
run --body-file "$TMP/noblast.md"
expect "missing blast radius fails" 1 "3. FAIL merge-danger: missing **Blast Radius:**"

body placeholder 's/^Adds a check./Adds <what it adds>./'
run --body-file "$TMP/placeholder.md"
expect "angle placeholder fails" 1 "5. FAIL no-placeholders: found: <what it adds>"
body todo 's/^Adds a check./Adds a check. TODO: screenshots/'
run --body-file "$TMP/todo.md"
expect "TODO fails" 1 "5. FAIL no-placeholders: found:" "TODO"
body tbd 's/^Adds a check./Owner TBD./'
run --body-file "$TMP/tbd.md"
expect "TBD fails" 1 "5. FAIL no-placeholders" "TBD"
body tags 's|^Adds a check.|Adds a check. <details><summary>log</summary><img src="x.png"></details>|'
run --body-file "$TMP/tags.md"
expect "HTML tags are not placeholders" 0 "5. PASS no-placeholders"

run --body-file "$TMP/good.md" --title "Add sf-pr-check"
expect "non-conventional title fails" 1 "6. FAIL title: not type(scope): subject"
run --body-file "$TMP/good.md" --title "feat!: breaking change"
expect "breaking-change title passes" 0 "6. PASS title"

body addr 's/^Adds a check./Adds a check for the Captain./'
run --body-file "$TMP/addr.md"
expect "address word fails" 1 "7. FAIL no-address"
body greet '1i\
Hi team,'
run --body-file "$TMP/greet.md"
expect "greeting line fails" 1 "7. FAIL no-address"

printf '{"disabled":["title"]}\n' > "$TMP/cfg.json"
OUT=$(SF_PR_CHECK_CONFIG="$TMP/cfg.json" "$CHECK" --body-file "$TMP/good.md" --title "bad title" 2>&1); CODE=$?
expect "disabled rule keeps its number" 0 "6. SKIP title: disabled by config" "7. PASS no-address"
run --config "$TMP/missing.json" --body-file "$TMP/good.md"
expect "missing config is an error" 2 "config not found"
printf 'not json' > "$TMP/bad.json"
run --config "$TMP/bad.json" --body-file "$TMP/good.md"
expect "bad config is an error" 2 "unreadable config"
run
expect "no arguments is a usage error" 2 "usage:"

# Local repository: template headings and changed UI files come from git.
REPO="$TMP/repo"
git init -q -b main "$REPO"
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "chore: base"
git -C "$REPO" update-ref refs/remotes/origin/main HEAD
mkdir -p "$REPO/.github" "$REPO/web"
printf '## Why\n<why>\n\n## Summary\n<what>\n' > "$REPO/.github/pull_request_template.md"
printf '<p>x</p>\n' > "$REPO/web/page.vue"
git -C "$REPO" add -A
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q -m "feat: page"
body tpl '1i\
## Why\
Because.\
' '/^## Merge Danger/,/Blast Radius/d'
(cd "$REPO" && run --body-file "$TMP/tpl.md" && printf '%s\n%s' "$CODE" "$OUT") > "$TMP/tpl.out"
CODE=$(head -n 1 "$TMP/tpl.out"); OUT=$(tail -n +2 "$TMP/tpl.out")
expect "template headings and UI file from git" 1 "1. PASS headings: template headings Why|Summary" \
  "3. SKIP merge-danger: repository template has no ## Merge Danger" "4. FAIL ui-evidence: UI file web/page.vue"
printf '\n![page](https://example.com/page.png)\n' >> "$TMP/tpl.md"
(cd "$REPO" && run --body-file "$TMP/tpl.md" && printf '%s\n%s' "$CODE" "$OUT") > "$TMP/tpl.out"
CODE=$(head -n 1 "$TMP/tpl.out"); OUT=$(tail -n +2 "$TMP/tpl.out")
expect "embedded image satisfies UI evidence" 0 "4. PASS ui-evidence"

printf '\n<why>\n' >> "$TMP/tpl.md"
(cd "$REPO" && run --body-file "$TMP/tpl.md" && printf '%s\n%s' "$CODE" "$OUT") > "$TMP/tpl.out"
CODE=$(head -n 1 "$TMP/tpl.out"); OUT=$(tail -n +2 "$TMP/tpl.out")
expect "template placeholder left in the body fails" 1 "5. FAIL no-placeholders: found: <why>"

# Pull request mode against the fake GitHub client.
FX="$TMP/fx"
mkdir -p "$FX"
jq -n --rawfile b "$TMP/good.md" '{title:"feat(factory): add sf-pr-check", body:$b, base:{ref:"main"}}' > "$FX/pull-7.json"
printf '[{"filename":"factory/bin/sf-pr-check.sh"}]\n' > "$FX/pull-files.json"
runpr() { : > "$TMP/gh.log"; OUT=$(SF_GH="$FAKE" SF_FIXTURES="$FX" SF_GH_LOG="$TMP/gh.log" FM_HOME="$TMP/nohome" "$CHECK" "$@" 2>&1); CODE=$?; }
runpr acme/app https://github.com/acme/app/pull/7
expect "PR mode passes with no template (404)" 0 "sf-pr-check: acme/app#7" "1. PASS headings: default headings" "RESULT: PASS"
grep -qF 'contents/.github/pull_request_template.md?ref=main' "$TMP/gh.log" || fail "template not read from the base branch"
pass "template read from the base branch"
printf '[{"filename":"src/App.tsx"}]\n' > "$FX/pull-files.json"
runpr acme/app 7
expect "PR mode UI change without image fails" 1 "4. FAIL ui-evidence: UI file src/App.tsx"
printf '{"ui_globs":["*.svelte"]}\n' > "$TMP/ui.json"
runpr --config "$TMP/ui.json" acme/app 7
expect "ui_globs from config replace the defaults" 0 "4. SKIP ui-evidence: no changed file matches *.svelte"
printf '## Summary\n## Evidence\n## Risk\n' > "$FX/contents-pull_request_template.md"
runpr acme/app 7
expect "PR mode uses the repository template" 1 "1. FAIL headings: missing: Risk" "3. PASS merge-danger"
runpr acme/app https://github.com/other/app/pull/7
expect "URL for another repo is an error" 2 "does not match"
rm "$FX/pull-7.json"
runpr acme/app 7
expect "GitHub read failure is an error" 2 "GitHub read failed"
