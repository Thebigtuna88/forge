#!/bin/bash -p
# Test-only gate (never registered in the real settings.json): denies `git push` to main, the
# way a real FRG-3 gate will, so hookrt and conformance can be proved before real hooks exist.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init sample-gate
[[ "$HR_TOOL" == Bash ]] || hr_part alt
hr_guarded || hr_allow
hr_require_simple
if [[ "${HR_TOK[0]}" == git && "$HR_GIT_SUB" == push ]]; then
  for a in ${HR_GIT_ARGS[@]+"${HR_GIT_ARGS[@]}"}; do
    case "$a" in
      main | *:main | refs/heads/main) hr_deny "push to main" ;;
    esac
  done
fi
hr_allow
