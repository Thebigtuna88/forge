#!/bin/bash -p
# gate-spend (spec 5.3, 8.5, rule 8, FRG-5). Paid APIs are called only through a project's budget
# wrapper, and live payment keys never. A command naming a paid host or a provider key variable
# from .harness/spend-limits.json (owner-only), or a live Stripe key prefix (always_blocked), is
# refused, wherever it appears in the command. There is no budget wrapper yet, so nothing is
# exempt; FRG-11 adds the wrapper's exemption. A missing or malformed list refuses everything.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init gate-spend
rc=0
hr_spend_hits || rc=$?
hits="$(head -n 1 "$HR_TMP/spend.out")"
[[ $rc != 0 ]] || hr_allow
[[ $rc == 1 ]] || hr_deny "can't read .harness/spend-limits.json ($hits), so paid APIs can't be told apart"
hr_deny "this command names $hits; paid APIs are called only through a project's budget wrapper, and live payment keys never (rule 8)"
