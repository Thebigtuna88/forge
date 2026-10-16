#!/usr/bin/env bash
# Test-only gate: denies any command whose working folder is the harness root (the "main
# checkout"). Proves conformance's sandbox layout and its @ROOT@ / @WORKTREES@ placeholders.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init cwd-gate
[[ "$HR_CWD" == "$HR_ROOT" ]] && hr_deny "command runs in the main checkout"
hr_allow
