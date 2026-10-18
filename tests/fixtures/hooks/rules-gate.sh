#!/bin/bash -p
# Test-only gate that needs a .harness/*.toml file (as secret-scan needs gitleaks.toml): it
# denies when the file is missing, so conformance must copy .harness/*.toml into its sandbox.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init rules-gate
[[ -f "$HR_ROOT/.harness/rules.toml" ]] || hr_deny "rules.toml is missing"
[[ "$HR_CMD" != *main* ]] || hr_deny "main"
hr_allow
