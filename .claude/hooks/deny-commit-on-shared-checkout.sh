#!/bin/bash -p
# deny-commit-on-shared-checkout (spec 5.3, FRG-3). A commit runs only in a ticket worktree: a
# linked worktree under ~/code/forge-worktrees/, on a feature/… branch. The main checkout
# (~/code/forge) and each project's main checkout (~/code/forge/projects/<name>) stay on dev and
# are never edited by hand: there git merge and git pull may only fast-forward (--ff-only), so they
# never make a commit. A command whose folder or branch can't be determined is refused.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init deny-commit-on-shared-checkout
hr_guarded || hr_allow
hr_require_simple
[[ "${HR_TOK[0]:-}" == git ]] || hr_allow
case "$HR_GIT_SUB" in
  commit | merge | pull) ;;
  *) hr_allow ;;
esac

where="the ticket's worktree ($HR_WORKTREES/<KEY>-<n>-<slug>)"
[[ -n "$HR_GIT_DIR" && -d "$HR_GIT_DIR" ]] ||
  hr_deny "can't tell which folder this runs in; work inside $where"
if ! git -C "$HR_GIT_DIR" rev-parse --show-toplevel >"$HR_TMP/top" 2>/dev/null; then
  hr_deny "not inside a git repository ($HR_GIT_DIR); work inside $where"
fi
top="$(cat "$HR_TMP/top")"
worktree=0
case "$top/" in
  "$HR_WORKTREES"/?*/) worktree=1 ;;
esac

if [[ "$HR_GIT_SUB" != commit ]]; then
  # merge / pull: in a ticket worktree they are fine (secret-scan rules their form); elsewhere
  # (a main checkout) they may only fast-forward.
  [[ $worktree == 0 ]] || hr_allow
  for a in ${HR_GIT_ARGS[@]+"${HR_GIT_ARGS[@]}"}; do
    [[ "$a" != --ff-only ]] || hr_allow
  done
  hr_deny "in a main checkout ($top), git $HR_GIT_SUB is allowed only --ff-only, so it never makes a commit there"
fi

[[ $worktree == 1 ]] ||
  hr_deny "commits happen only in a ticket worktree, not in $top (main checkouts stay on dev and are never edited by hand); commit inside $where"
# A linked worktree has its own git folder, separate from the repository's common one.
git -C "$HR_GIT_DIR" rev-parse --path-format=absolute --git-dir --git-common-dir >"$HR_TMP/dirs"
gitdir="$(head -n 1 "$HR_TMP/dirs")"
common="$(tail -n 1 "$HR_TMP/dirs")"
[[ "$gitdir" != "$common" ]] ||
  hr_deny "$top is a standalone repository, not a linked worktree of the project; create the ticket worktree with git worktree add"
if ! git -C "$HR_GIT_DIR" symbolic-ref --quiet --short HEAD >"$HR_TMP/branch" 2>/dev/null; then
  hr_deny "this worktree is not on a branch (detached HEAD); commit on its feature/<KEY>-<n>-<slug> branch"
fi
branch="$(cat "$HR_TMP/branch")"
[[ "$branch" == feature/* ]] ||
  hr_deny "commits happen only on a feature/<KEY>-<n>-<slug> branch, not '$branch'"
hr_allow
