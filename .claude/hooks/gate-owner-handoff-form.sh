#!/bin/bash -p
# gate-owner-handoff-form (spec 4.6, FRG-5), a Stop hook. When the agent ends a turn by giving the
# owner commands to type or web-UI steps to follow by hand, instead of an owner handoff (an
# OWNER-RUN.sh path and "HANDOFF-RESULT"), it sends the agent back with "rewrite this as an owner
# handoff". It reads the turn's last message from the input's last_assistant_message. It never
# blocks twice in a row (stop_hook_active) and fails open: Claude Code ignores onFailure on Stop
# hooks, and a Stop hook that blocked on its own errors would block every turn (hookrt; it even
# exits 0 if the runtime can't load). A text heuristic, so it starts in observe mode (L6); the
# owner promotes it by a PR to mode.json.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "FORGE hook failed open: hookrt failed to load"; exit 0; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "FORGE hook failed open: hookrt not loaded"; exit 0; }

hr_init gate-owner-handoff-form
rc=0
hr_handoff_form || rc=$?
reason="$(head -n 1 "$HR_TMP/form.out")"
case "$rc" in
  0 | 4) hr_allow ;;
  1) hr_deny "rewrite this as an owner handoff ($reason): the owner gets a script to run, never instructions to carry out by hand (CLAUDE.md, owner handoffs)" ;;
esac
hr_fail_open "can't read the turn's last message ($reason)"
