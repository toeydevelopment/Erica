#!/usr/bin/env bash
# Fixture-backed stand-in for gh api. Serves files from $SF_FIXTURES, logs every call to $SF_GH_LOG.
set -eu
echo "$*" >> "${SF_GH_LOG:?}"
[ "$1" = api ] || { echo "fake gh: unsupported: $*" >&2; exit 1; }
ep=""
for a in "$@"; do case "$a" in repos/*) ep=$a ;; esac; done
path=${ep%%\?*}
case "$path" in
  repos/kunchenguid/no-mistakes/contents/*/verify.py) f=verify.py ;;
  repos/*/*/pulls/*/files) n=${path%/files}; f=files-${n##*/}.json ;;
  repos/*/*/pulls) f=pulls.json ;;
  *) f=missing ;;
esac
[ -f "$SF_FIXTURES/$f" ] || { echo "fake gh: no fixture $f for $ep" >&2; exit 1; }
cat "$SF_FIXTURES/$f"
