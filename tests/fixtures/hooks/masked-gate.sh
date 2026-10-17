#!/bin/bash -p
# Test-only gate that works, but uses a command substitution whose failure would be masked
# (local x="$(…)"). Conformance's source check must refuse it.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init masked-gate
check() {
  # shellcheck disable=SC2155 # the masked form is what this fixture is about
  local text="$(printf '%s' "$HR_CMD")"
  [[ "$text" != *main* ]] || hr_deny "main"
}
check
hr_allow
