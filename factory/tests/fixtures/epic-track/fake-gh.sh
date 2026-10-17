#!/usr/bin/env bash
# Fixture-backed stand-in for gh api. Serves JSON from $SF_FIXTURES, logs every call to $SF_GH_LOG.
# A call with -X other than GET is a write: it is only logged and answers {}.
set -eu
echo "$*" >> "${SF_GH_LOG:?}"
[ "$1" = api ] || { echo "fake gh: unsupported: $*" >&2; exit 1; }
ep=""
method=GET
prev=""
for a in "$@"; do
  case "$a" in repos/*|search/*) ep=$a ;; esac
  [ "$prev" != -X ] || method=$a
  prev=$a
done
[ "$method" = GET ] || { echo '{}'; exit 0; }
path=${ep%%\?*}
case "$path" in
  repos/*/*/issues/*/sub_issues) f=sub_issues.json ;;
  repos/*/*/issues/*/comments) f=comments.json ;;
  repos/*/*/issues/*) f=issue-${path##*/}.json ;;
  repos/*/*/labels/*) f=label.json ;;
  search/issues) f=search.json ;;
  *) f=missing ;;
esac
[ -f "$SF_FIXTURES/$f" ] || { echo "fake gh: no fixture $f for $ep" >&2; exit 1; }
cat "$SF_FIXTURES/$f"
