#!/bin/bash -p
# Test-only hook: appends to the file named in tool_input.file_path, then allows. Conformance must
# notice when a run changes a live file.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init toucher
if [[ -n "$HR_FILE" ]]; then printf 'touched\n' >>"$HR_FILE"; fi
[[ "$HR_CMD" != *main* ]] || hr_deny "main"
hr_allow
