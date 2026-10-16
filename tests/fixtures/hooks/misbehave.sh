#!/usr/bin/env bash
# Test-only hook that goes wrong in the way $MISBEHAVE says. Every one of these must deny.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init misbehave
case "${MISBEHAVE:-}" in
  unbound) echo "${no_such_variable_here:?}" ;;
  exit0) exit 0 ;;
  exit1) exit 1 ;;
  missing-command) no_such_command_frg2 ;;
  term) kill -TERM $$ ;;
esac
# falling off the end without hr_allow or hr_deny
