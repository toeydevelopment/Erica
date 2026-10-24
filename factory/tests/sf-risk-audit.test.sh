#!/usr/bin/env bash
# Tests factory/bin/sf-risk-audit.sh against recorded GitHub API JSON through a fake gh. No network.
# fixtures/risk-audit/verify.py is upstream require-no-mistakes verify.py, copied unchanged at the
# commit pinned in .github/workflows/no-mistakes-required.yml (MIT, see verify.py.LICENSE), so the
# compliant and marker verdicts come from the real verifier.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="$HERE/../bin/sf-risk-audit.sh"
FX="$HERE/fixtures/risk-audit"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cat > "$TMP/paths" <<'EOF'
# test list
**/migrations/**   # schema changes
deploy/**          # runtime config

.github/workflows/**
EOF

# audit <args...>: sets OUT and CODE; gh calls go to $TMP/gh.log.
audit() {
  OUT=$(SF_GH="$FX/fake-gh.sh" SF_FIXTURES="$FX" SF_GH_LOG="$TMP/gh.log" FM_HOME="$TMP/home" \
    "$AUDIT" --repo acme/app --paths "$TMP/paths" "$@" 2>&1)
  CODE=$?
}

WANT="1 high compliant db/migrations/001_add.sql
2 high marker deploy/prod.yaml
3 high none .github/workflows/ci.yml
4 low none -
5 high none db/migrations/002_old.sql
8 low none -"
audit --since 2026-09-01 --until 2026-09-30 --cache "$TMP/cache"
[ "$CODE" = 0 ] || fail "online run exited $CODE: $OUT"
[ "$(sed '$d' <<<"$OUT")" = "$WANT" ] || fail "online lines:"$'\n'"$OUT"
case "$(tail -n 1 <<<"$OUT")" in
  "summary repo=acme/app window=2026-09-01..2026-09-30 base=all prs=6 high=4 high_compliant=1 high_marker=1 high_none=2 verifier="*) : ;;
  *) fail "summary: $(tail -n 1 <<<"$OUT")" ;;
esac
pass "tiers, statuses, rename, window bounds and summary"
ONLINE=$OUT

grep -qE -- '(^| )(-X|--method|-f|-F|--field|--raw-field|--input)( |$)' "$TMP/gh.log" && fail "write-capable gh call"$'\n'"$(cat "$TMP/gh.log")"
grep -qv '^api ' "$TMP/gh.log" && fail "non-api gh call"
pass "read-only: every gh call is a plain GET"

: > "$TMP/gh.log"
audit --since 2026-09-01 --until 2026-09-30 --cache "$TMP/cache" --offline
[ "$CODE" = 0 ] && [ "$OUT" = "$ONLINE" ] || fail "offline differs from online:"$'\n'"$OUT"
[ -s "$TMP/gh.log" ] && fail "offline run called gh"
audit --since 2026-09-01 --until 2026-09-30 --cache "$TMP/cache" --offline
[ "$OUT" = "$ONLINE" ] || fail "second offline run differs"
pass "offline rerun is byte-identical and makes no gh call"

: > "$TMP/gh.log"
audit --since 2026-09-01 --until 2026-09-30 --cache "$TMP/cache"
grep -q 'files' "$TMP/gh.log" && fail "cached files were fetched again"
pass "online rerun reuses cached file lists"

audit --since 2026-11-01 --until 2026-11-30 --cache "$TMP/cache" --offline
[ "$CODE" = 0 ] || fail "empty window exited $CODE"
case "$OUT" in "summary repo=acme/app window=2026-11-01..2026-11-30 base=all prs=0 high=0 high_compliant=0 high_marker=0 high_none=0 verifier="*) : ;;
  *) fail "empty window: $OUT" ;; esac
pass "empty window prints only a zero summary"

audit --since 2026-09-01 --until 2026-09-30 --cache "$TMP/cache" --offline --base main
[ "$CODE" = 0 ] || fail "--base exited $CODE: $OUT"
[ "$(sed '$d' <<<"$OUT")" = "$(grep -Ev '^(2|5) ' <<<"$WANT")" ] || fail "--base main lines:"$'\n'"$OUT"
case "$(tail -n 1 <<<"$OUT")" in *" base=main prs=4 high=2 "*) : ;; *) fail "--base summary: $OUT" ;; esac
pass "--base keeps only pull requests merged into that branch"

rm -f "$TMP/cache"/require-no-mistakes-*.py
audit --since 2026-09-01 --until 2026-09-30 --cache "$TMP/cache" --offline
[ "$CODE" = 2 ] || fail "missing verifier exited $CODE: $OUT"
pass "offline refuses a marker it cannot verify instead of calling it none"

audit --since 2026-09-01 --until 2026-09-30 --cache "$TMP/nocache" --offline
[ "$CODE" = 2 ] || fail "missing cache exited $CODE"
audit --since 2026-09-30 --until 2026-09-01 --cache "$TMP/cache" --offline
[ "$CODE" = 2 ] || fail "reversed window exited $CODE"
audit --since 2026-9-1 --until 2026-09-30 --offline
[ "$CODE" = 2 ] || fail "bad date exited $CODE"
pass "usage and cache errors exit 2"
