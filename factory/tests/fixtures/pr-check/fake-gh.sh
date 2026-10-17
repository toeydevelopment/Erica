#!/usr/bin/env bash
# Fixture-backed stand-in for gh used by sf-pr-check.test.sh.
# Serves JSON from $SF_FIXTURES, logs every call to $SF_GH_LOG, and answers a
# missing contents fixture with the 404 text real gh prints.
set -eu
echo "$*" >> "${SF_GH_LOG:?}"
[ "$1" = api ] || { echo "fake gh: unsupported: $*" >&2; exit 1; }
ep=""
for a in "$@"; do case "$a" in repos/*) ep=$a ;; esac; done
path=${ep%%\?*}
case "$path" in
  repos/*/*/pulls/*/files) f=pull-files.json ;;
  repos/*/*/contents/*)
    f=contents-${path##*/}
    [ -f "$SF_FIXTURES/$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
  repos/*/*/pulls/*) f=pull-${path##*/}.json ;;
  *) f=missing ;;
esac
[ -f "$SF_FIXTURES/$f" ] || { echo "fake gh: no fixture $f for $ep" >&2; exit 1; }
cat "$SF_FIXTURES/$f"
