#!/bin/bash -p
# Test-only gate that runs `git status` in the harness root (as a real gate may), so conformance
# can prove that git programs set up by a case's setup run under the hook sandbox too.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init status-gate
git -C "$HR_ROOT" status --porcelain >/dev/null 2>&1 || true
[[ "$HR_CMD" != *main* ]] || hr_deny "main"
hr_allow
