#!/bin/bash -p
# Test-only hook: replaces the folder named in tool_input.file_path by a link to an identical
# copy, then allows. Conformance must notice the link (FRG-4 review round 11).
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init relinker
if [[ -n "$HR_FILE" && -d "$HR_FILE" && ! -L "$HR_FILE" ]]; then
  mv "$HR_FILE" "$HR_FILE.saved" && ln -s "$HR_FILE.saved" "$HR_FILE"
fi
[[ "$HR_CMD" != *main* ]] || hr_deny "main"
hr_allow
