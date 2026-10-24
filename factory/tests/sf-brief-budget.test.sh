#!/usr/bin/env bash
# sf-brief-budget.test.sh - fail when factory/brief-include.md grows past its line budget.
#
# Usage:
#   bash factory/tests/sf-brief-budget.test.sh
#
# Every worker in every home reads brief-include.md, so each added line is a
# cost on every task. Raising BUDGET is allowed, but as a reviewed decision.
set -eu

BUDGET=140
BRIEF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/brief-include.md"
lines=$(wc -l < "$BRIEF" | tr -d ' ')
if [ "$lines" -gt "$BUDGET" ]; then
  echo "FAIL: factory/brief-include.md has $lines lines, budget is $BUDGET." >&2
  echo "Move a rule a script can decide into a check (leave one pointer line), or raise BUDGET in this test deliberately." >&2
  exit 1
fi
echo "ok: sf-brief-budget ($lines/$BUDGET lines)"
