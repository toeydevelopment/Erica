#!/usr/bin/env bash
# sf-dashboard.test.sh - exercise factory/bin/sf-dashboard.sh on the recorded fixture home.
#
# Usage:
#   bash factory/tests/sf-dashboard.test.sh
#
# Needs python3 and curl; talks only to 127.0.0.1.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASH="$HERE/../bin/sf-dashboard.sh"
FIXTURE="$HERE/fixtures/dashboard"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/sf-dashboard.XXXXXX")
PID=
cleanup() { [ -z "$PID" ] || kill "$PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

"$DASH" --once --fixture "$FIXTURE" > "$TMP/graph.json" || fail "--once on the fixture exited $?"
python3 - "$TMP/graph.json" <<'PY' || fail "fixture graph"
import json, sys
g = json.load(open(sys.argv[1]))
assert g["schema"] == "sf-dashboard.v1", g["schema"]
assert g["ledger"] == {"enabled": True}, g["ledger"]
assert g["errors"] == [], g["errors"]
nodes = {n["id"]: n for n in g["nodes"]}
assert len(nodes) == 5, sorted(nodes)
want = {
    "firstmate": ("firstmate", None, "working"),
    "sm-docs": ("secondmate", "firstmate", "working"),
    "ship-login": ("ship", "firstmate", "done"),
    "ship-api": ("ship", "firstmate", "blocked"),
    "sm-docs/scout-perf": ("scout", "sm-docs", "paused"),
}
for nid, (kind, parent, state) in want.items():
    n = nodes[nid]
    assert (n["kind"], n["parent"], n["state"]) == (kind, parent, state), n
assert nodes["sm-docs"]["busy"] and not nodes["ship-api"]["busy"]
assert nodes["ship-login"]["pr"] == "https://github.com/acme/webapp/pull/7"
assert nodes["ship-login"]["project"] == "webapp" and nodes["ship-login"]["branch"] == "fm/ship-login"
assert nodes["ship-login"]["since"] == 1790000300
edges = g["edges"]
assert [e["seq"] for e in edges] == list(range(1, 11)), [e["seq"] for e in edges]
assert [e["ts"] for e in edges] == sorted(e["ts"] for e in edges)
login = [(e["kind"], e["from"], e["to"]) for e in edges if "ship-login" in (e["from"], e["to"])]
assert login == [
    ("dispatch", "firstmate", "ship-login"),
    ("status", "ship-login", "firstmate"),
    ("steer", "firstmate", "ship-login"),
    ("status", "ship-login", "firstmate"),
    ("pr_ready", "ship-login", "firstmate"),
    ("merged", "firstmate", "ship-login"),
], login
steers = [e["text"] for e in edges if e["kind"] == "steer"]
assert steers == ["Also cover the expired-session redirect.",
                  "Use the seeded test database instead; credentials are not coming."], steers
PY
pass "fixture: 5 nodes, mixed states, edges in seq order"

mkdir -p "$TMP/empty"
"$DASH" --once --fixture "$TMP/empty" > "$TMP/empty.json" || fail "--once on an empty home exited $?"
python3 -c '
import json, sys
g = json.load(open(sys.argv[1]))
assert [n["id"] for n in g["nodes"]] == ["firstmate"], g["nodes"]
assert g["edges"] == [] and g["ledger"]["enabled"] is False
' "$TMP/empty.json" || fail "empty home graph"
pass "empty home renders the firstmate alone with the ledger off"

"$DASH" --port nope >/dev/null 2>&1
[ $? = 2 ] || fail "bad --port did not exit 2"
"$DASH" --fixture "$TMP/missing" >/dev/null 2>&1
[ $? = 2 ] || fail "missing --fixture dir did not exit 2"
pass "usage errors exit 2"

cp -R "$FIXTURE" "$TMP/home"
(cd "$TMP/home" && find . -type f -exec cksum {} + | sort) > "$TMP/before"
"$DASH" --port 0 --fixture "$TMP/home" > "$TMP/server.log" 2>&1 &
PID=$!
URL=
for _ in $(seq 50); do
  URL=$(grep -o 'http://127\.0\.0\.1:[0-9]*/' "$TMP/server.log" || true)
  [ -n "$URL" ] && break
  sleep 0.1
done
[ -n "$URL" ] || fail "server did not report its URL: $(cat "$TMP/server.log")"

curl -fsS "$URL" | grep -q '<title>Fleet Dashboard</title>' || fail "GET / did not serve the page"
curl -fsS "${URL}api/fleet" | python3 -c 'import json,sys; g=json.load(sys.stdin); assert g["schema"]=="sf-dashboard.v1" and len(g["nodes"])==5' \
  || fail "GET /api/fleet"
curl -fsS "${URL}api/events?after=8" | python3 -c '
import json, sys
e = json.load(sys.stdin)["edges"]
assert [(x["seq"], x["kind"]) for x in e] == [(9, "steer"), (10, "merged")], e
' || fail "GET /api/events?after=8"
code=$(curl -s -o /dev/null -w '%{http_code}' "${URL}api/events?after=x")
[ "$code" = 400 ] || fail "bad after returned $code"
pass "server: page, fleet, events after a seq, bad after is 400"

(cd "$TMP/home" && find . -type f -exec cksum {} + | sort) > "$TMP/after"
cmp -s "$TMP/before" "$TMP/after" || fail "serving changed the home: $(diff "$TMP/before" "$TMP/after")"
pass "serving writes nothing in the home"

printf '%s\n' '{"v":1,"ts":1790000400,"event":"task.cleaned_up","task":"ship-login"}' >> "$TMP/home/recorded-state/fleet-ledger.jsonl"
curl -fsS "${URL}api/events?after=10" | python3 -c '
import json, sys
e = json.load(sys.stdin)["edges"]
assert [(x["seq"], x["kind"], x["from"], x["to"]) for x in e] == [(11, "cleaned_up", "firstmate", "ship-login")], e
' || fail "new ledger line did not arrive as seq 11"
pass "a new ledger line arrives as the next event"
