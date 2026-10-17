#!/bin/bash -p
# Test-only gate whose reason holds a literal backslash sequence, for conformance's reason check.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init reason-gate
[[ "$HR_CMD" != *main* ]] || hr_deny 'path\tname is literal'
hr_allow
