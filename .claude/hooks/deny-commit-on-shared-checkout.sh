#!/bin/bash -p
# deny-commit-on-shared-checkout (spec 5.3, FRG-3). A commit runs only in a ticket worktree under
# ~/code/forge-worktrees/, on a feature/… branch. The main checkout (~/code/forge) and each
# project's main checkout (~/code/forge/projects/<name>) stay on dev and are never edited by hand.
# A commit whose folder or branch can't be determined is refused.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init deny-commit-on-shared-checkout
hr_guarded || hr_allow
hr_require_simple
[[ "${HR_TOK[0]:-}" == git && "$HR_GIT_SUB" == commit ]] || hr_allow

where="the ticket's worktree ($HR_WORKTREES/<KEY>-<n>-<slug>)"
[[ -n "$HR_GIT_DIR" && -d "$HR_GIT_DIR" ]] ||
  hr_deny "can't tell which folder this commit runs in; commit inside $where"
if ! git -C "$HR_GIT_DIR" rev-parse --show-toplevel >"$HR_TMP/top" 2>/dev/null; then
  hr_deny "not inside a git repository ($HR_GIT_DIR); commit inside $where"
fi
top="$(cat "$HR_TMP/top")"
case "$top/" in
  "$HR_WORKTREES"/?*/) ;;
  *)
    hr_deny "commits happen only in a ticket worktree, not in $top (main checkouts stay on dev and are never edited by hand); commit inside $where"
    ;;
esac
if ! git -C "$HR_GIT_DIR" symbolic-ref --quiet --short HEAD >"$HR_TMP/branch" 2>/dev/null; then
  hr_deny "this worktree is not on a branch (detached HEAD); commit on its feature/<KEY>-<n>-<slug> branch"
fi
branch="$(cat "$HR_TMP/branch")"
[[ "$branch" == feature/* ]] ||
  hr_deny "commits happen only on a feature/<KEY>-<n>-<slug> branch, not '$branch'"
hr_allow
