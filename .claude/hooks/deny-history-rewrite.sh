#!/bin/bash -p
# deny-history-rewrite (spec 5.3, FRG-3). Refuses git rebase, git commit --amend, git
# filter-branch, git filter-repo, git replace, any git update-ref and git branch with --force (-f,
# -M, -C). A forced push is refused by deny-push-to-protected. A branch is updated with
# `git merge dev` instead.
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
  commit | branch) ;;
  *) hr_allow ;;
esac
for a in ${HR_GIT_ARGS[@]+"${HR_GIT_ARGS[@]}"}; do
  case "$HR_GIT_SUB:$a" in
    commit:--amend)
      hr_deny "git commit --amend rewrites history; make a new commit instead"
      ;;
    branch:--force | branch:-M | branch:-C)
      hr_deny "git branch $a rewrites history (it moves or overwrites a branch)"
      ;;
    branch:--*) ;;
    branch:-*f*)
      hr_deny "git branch $a rewrites history (it moves or overwrites a branch)"
      ;;
  esac
done
hr_allow
