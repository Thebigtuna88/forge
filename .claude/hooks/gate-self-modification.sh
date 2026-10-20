#!/bin/bash -p
# gate-self-modification (spec 5.3, rule 7, FRG-4). The agent never merges a PR that changes an
# owner-only path; those PRs are the owner's to merge, through an owner-merge handoff. On every
# gh pr merge (which must have the one allowed form), the PR's changed files come from the diff
# recomputed from GitHub's dev and head (hr_merge_prepare, review-diff.sh), never from GitHub's
# file list, which stops at 100 files. The owner-only paths are those of both lists: the live
# .harness/self-modification-paths.json in this checkout and the one at the PR's merge base. A
# missing or malformed list refuses. Names are compared as macOS compares them (case, Unicode
# form, invisible characters), a rename counts as both of its paths, and any symlink or submodule
# in the diff counts as owner-only (hr_owner_hits).
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init gate-self-modification
hr_guarded || hr_allow
hr_require_simple
[[ "${HR_TOK[0]:-} ${HR_TOK[1]:-} ${HR_TOK[2]:-}" == "gh pr merge" ]] || hr_allow
hr_merge_form || hr_deny "merge only as: $HR_MERGE_FORM"
hr_merge_prepare

hr_base_blob .harness/self-modification-paths.json "$HR_TMP/base-list.json" ||
  hr_deny "PR #$HR_PR's merge base has no .harness/self-modification-paths.json, so its owner-only paths can't be checked; the owner must merge this"
rc=0
if hr_owner_hits "$HR_PR_DIR/raw" "$HR_ROOT/.harness/self-modification-paths.json" "$HR_TMP/base-list.json"; then
  hr_allow
else
  rc=$?
fi
hits="$(head -n 5 "$HR_TMP/owner.hits" | tr '\n' ';')"
[[ $rc == 1 ]] || hr_deny "can't check PR #$HR_PR's owner-only paths ($hits); the owner must merge this"
hr_deny "PR #$HR_PR changes owner-only paths ($hits …): the owner must merge this (rule 7); write an owner-merge handoff"
