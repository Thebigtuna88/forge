#!/bin/bash -p
# capture-owner-paste (spec 4.5, FRG-5; owner decision 2026-10-16-handoff-evidence-provenance), a
# UserPromptSubmit hook. When the owner's message holds a HANDOFF-RESULT block for a frozen handoff,
# it saves the block itself to work/owner/<id>/PASTED-<utc>.txt and records the file's sha256 in
# .harness/state/pastes.log; handoff verify accepts only a paste recorded there, and
# guard-live-checkout keeps the agent's file tools from writing either. Shell writes to them are
# not prevented (spec 11, L14, open until permission-based protection is implemented and tested).
# Its note (what it saved, or why not) reaches the agent as added context. It never blocks the
# owner's message: it is registered without
# "onFailure": "block" and fails open (hookrt; it even exits 0 if the runtime can't load), so a
# failure only means the paste isn't recorded, which verify then refuses. Claude Code also runs
# this hook on turns it starts itself (a scheduled task, a background agent reporting back,
# another session's message) without saying who wrote the text, so a block sent that way would be
# recorded too: spec 11, L4.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "FORGE hook failed open: hookrt failed to load"; exit 0; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "FORGE hook failed open: hookrt not loaded"; exit 0; }

hr_init capture-owner-paste
hr_capture_paste || hr_fail_open "the capture could not finish (see the note above), so verify will refuse the paste"
hr_allow
