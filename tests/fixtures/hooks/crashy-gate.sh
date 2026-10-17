#!/bin/bash -p
# Test-only broken gate: its "deny" branch calls a function that doesn't exist, so it exits 2 by
# crashing, not by deciding. Conformance must not count that as a working deny.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init crashy-gate
if [[ "$HR_CMD" == *main* ]]; then
  nonexistent_gate_function
fi
hr_allow
