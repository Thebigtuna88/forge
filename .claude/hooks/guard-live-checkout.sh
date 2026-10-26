#!/bin/bash -p
# guard-live-checkout (spec 5.3, rule 1, FRG-5). The main checkout (~/code/forge, and each
# project's under projects/<name>) is never edited by hand: only its scratch folders work/ and
# .harness/state/ are. Inside work/owner/<id>/ only a draft OWNER-RUN.sh is: results, pastes,
# VERIFIED.txt, META.json and logs come from the handoff tools, the owner's run and
# capture-owner-paste, and .harness/state/pastes.log only from capture-owner-paste. Claude Code's
# settings.local.json files and ~/.claude/settings*.json are refused too, since they could switch
# the hooks off. The checkout is the one this hook sits in, so the guard follows FORGE wherever it
# is installed. Paths are judged as written and with links resolved, compared as macOS compares
# names (hr_live_check). The file tools (Edit, Write, MultiEdit, NotebookEdit) are enforced; the
# Bash part guesses from redirections and write commands, so it starts in observe mode (L6).
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init guard-live-checkout
part="file"
arg="$HR_FILE"
case "$HR_TOOL" in
  Edit | Write | MultiEdit | NotebookEdit) ;;
  Bash)
    part=bash
    arg="$HR_CMD"
    hr_part bash
    ;;
  *) hr_allow ;;
esac

rc=0
hr_live_check "$part" "$arg" || rc=$?
[[ $rc != 0 ]] || hr_allow
reason="$(head -n 1 "$HR_TMP/live.out")"
[[ $rc == 1 ]] || hr_deny "can't tell where this writes ($reason)"
hr_deny "$reason"
