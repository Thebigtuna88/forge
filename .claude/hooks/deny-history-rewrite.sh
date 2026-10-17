#!/bin/bash -p
# deny-history-rewrite (spec 5.3, FRG-3). Refuses what rewrites or moves branch history:
#   git rebase, filter-branch, filter-repo, replace, any update-ref; git commit --amend;
#   git branch --force/-f/-M/-C (and abbreviations or clusters of them);
#   git checkout -B, git switch -C/--force-create, git worktree add -B (they reset a branch);
#   git reset, except unstaging: git reset [-q] [HEAD] [-- <paths>];
#   git fetch with --force/-f/--update-head-ok or a refspec with ":" or "+" (it moves local branches);
#   git pull --rebase/-r.
# A forced push is refused by deny-push-to-protected. A branch is updated with `git merge dev`.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init deny-history-rewrite
hr_guarded || hr_allow
hr_require_simple
[[ "${HR_TOK[0]:-}" == git ]] || hr_allow

case "$HR_GIT_SUB" in
  rebase | filter-branch | filter-repo | replace | update-ref)
    hr_deny "git $HR_GIT_SUB rewrites history; update a branch with git merge dev instead"
    ;;
  commit | branch | checkout | switch | worktree | reset | fetch | pull) ;;
  *) hr_allow ;;
esac

moves="git reset moves the branch; to unstage, use git reset -- <path> (or git reset HEAD <path>)"
head=0     # git reset: HEAD came first, so the words after it are paths
paths=0    # after --
for a in ${HR_GIT_ARGS[@]+"${HR_GIT_ARGS[@]}"}; do
  if [[ $paths == 1 ]]; then
    continue
  fi
  case "$HR_GIT_SUB:$a" in
    *:--) paths=1 ;;
    commit:--amend | commit:--amen | commit:--ame | commit:--am)
      hr_deny "git commit --amend rewrites history; make a new commit instead"
      ;;
    branch:-M | branch:-C | branch:--f | branch:--fo | branch:--for | branch:--forc | branch:--force)
      hr_deny "git branch $a rewrites history (it moves or overwrites a branch)"
      ;;
    branch:--*) ;;
    branch:-*[fMC]*)
      hr_deny "git branch $a rewrites history (it moves or overwrites a branch)"
      ;;
    checkout:-B | switch:-C | switch:--force-create | switch:--force-create=* | worktree:-B)
      hr_deny "git $HR_GIT_SUB $a resets an existing branch; create a new one with -b / -c instead"
      ;;
    reset:-q | reset:--quiet) ;;
    reset:-*) hr_deny "$moves" ;;
    reset:HEAD) head=1 ;;
    reset:*) [[ $head == 1 ]] || hr_deny "$moves" ;;
    fetch:-f | fetch:--force | fetch:--forc | fetch:--for | fetch:-u | fetch:--update-head-ok)
      hr_deny "git fetch $a updates local branches directly; fetch without it and merge"
      ;;
    fetch:-*) ;;
    fetch:*)
      case "$a" in
        *:* | +*) hr_deny "git fetch $a updates local branches directly; fetch without a refspec and merge" ;;
      esac
      ;;
    pull:-r | pull:--rebase | pull:--rebase=*)
      hr_deny "git pull $a rewrites history; use git pull --ff-only"
      ;;
  esac
done
hr_allow
