#!/usr/bin/env bash
# Test-only broken hook: blocks any command mentioning "main", but treats a missing or unreadable
# mode.json as "allow everything" (fails open). Conformance's mode-failure check must catch it.
input="$(cat)"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
jq -e . "$here/../../.harness/mode.json" >/dev/null 2>&1 || exit 0
case "$input" in
  *main*)
    echo "blocked: main" >&2
    exit 2
    ;;
esac
exit 0
