#!/bin/bash -p
# Test-only hook that goes wrong in the way $MISBEHAVE says. Every one of these must deny.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
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
  usr1) kill -USR1 $$ ;;
  quit) kill -QUIT $$ ;;
  error-then-allow)
    no_such_command_frg2
    hr_allow
    ;;
  false-then-allow)
    false
    hr_allow
    ;;
  unset-decided)
    unset _HR_DECISION
    exit 0
    ;;
esac
# falling off the end without hr_allow or hr_deny
