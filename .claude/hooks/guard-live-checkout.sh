#!/bin/bash -p
# guard-live-checkout (spec 5.3, rule 1, FRG-5). The main checkout (~/code/forge, and each
# project's under projects/<name>) is never edited by hand: only its scratch folders work/ and
# .harness/state/ are. Inside work/owner/<id>/ only a draft OWNER-RUN.sh is: results, pastes,
# VERIFIED.txt, META.json and logs come from the handoff tools, the owner's run and
# capture-owner-paste, and .harness/state/pastes.log only from capture-owner-paste. Claude Code's
# settings.local.json files and ~/.claude/settings*.json are refused too, since they could switch
# the hooks off. The checkout is the one this hook sits in, so the guard follows FORGE wherever it
# is installed. Paths are judged as written and with links resolved, compared as macOS compares
# names (hr_live_check). It judges the file tools (Edit, Write, MultiEdit, NotebookEdit) only:
# shell commands that write into the main checkout are NOT prevented by it (spec 11, L14), and a
# shell-write checker is FRG-32, after the FRG-26 checkpoint (owner decision 2026-10-27).
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init guard-live-checkout
case "$HR_TOOL" in
  Edit | Write | MultiEdit | NotebookEdit) ;;
  *) hr_allow ;;
esac

rc=0
hr_live_check "$HR_FILE" || rc=$?
[[ $rc != 0 ]] || hr_allow
reason="$(head -n 1 "$HR_TMP/live.out")"
[[ $rc == 1 ]] || hr_deny "can't tell where this writes ($reason)"
hr_deny "$reason"
