#!/bin/bash -p
# enforce-branch-format (spec 5.3, FRG-3). A branch that is created, renamed, copied or pushed must
# be named feature/<KEY>-<n>-<slug>, with a known key: git checkout -b/-B/--orphan, git switch
# -c/-C/--create/--force-create/--orphan, git branch <new> / -m / -c, git worktree add -b/-B and
# git push origin <branch>.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init enforce-branch-format
hr_guarded || hr_allow
hr_require_simple
[[ "${HR_TOK[0]:-}" == git ]] || hr_allow

new=""     # the branch name this command creates, renames or copies to, or pushes
take=0     # the next word is the name a creating option takes
rename=0   # git branch -m / -c: the last name is the new one
listing=0  # git branch lists, deletes or configures: its names are not new branches
names=()   # plain words after the subcommand
for a in ${HR_GIT_ARGS[@]+"${HR_GIT_ARGS[@]}"}; do
  if [[ $take == 1 ]]; then
    new="$a"
    take=0
    continue
  fi
  case "$HR_GIT_SUB:$a" in
    checkout:-b | checkout:-B | checkout:--orphan | switch:-c | switch:-C | switch:--create | \
      switch:--force-create | switch:--orphan | worktree:-b | worktree:-B)
      take=1
      ;;
    checkout:-b?* | checkout:-B?* | switch:-c?* | switch:-C?* | worktree:-b?* | worktree:-B?*)
      new="${a:2}"
      ;;
    checkout:--orphan=* | switch:--orphan=* | switch:--create=* | switch:--force-create=*)
      new="${a#*=}"
      ;;
    branch:-m | branch:-M | branch:--move | branch:-c | branch:-C | branch:--copy)
      rename=1
      ;;
    branch:-d | branch:-D | branch:--delete | branch:-l | branch:--list | branch:-a | branch:--all | \
      branch:-r | branch:--remotes | branch:--show-current | branch:-v | branch:-vv | \
      branch:--verbose | branch:--merged* | branch:--no-merged* | branch:--contains* | \
      branch:--no-contains* | branch:--points-at* | branch:--sort=* | branch:--format=* | \
      branch:--edit-description | branch:--unset-upstream | branch:-u | branch:--set-upstream-to*)
      listing=1
      ;;
    *:-*) ;;
    *) names+=("$a") ;;
  esac
done
[[ $take == 0 ]] || hr_deny "git $HR_GIT_SUB needs a branch name after its option"

case "$HR_GIT_SUB" in
  checkout | switch | worktree) ;;
  branch)
    if [[ ${#names[@]} -gt 0 && $listing == 0 ]]; then
      if [[ $rename == 1 ]]; then
        new="${names[${#names[@]} - 1]}"
      else
        new="${names[0]}"
      fi
    fi
    ;;
  push)
    # git push <remote> <refspec>: the branch pushed to is after any ":" (deny-push-to-protected
    # allows only the plain form; this keeps the name rule for every spelling).
    if [[ ${#names[@]} -ge 2 ]]; then
      new="${names[1]#+}"
      new="${new#*:}"
    fi
    ;;
  *) hr_allow ;;
esac
[[ -n "$new" ]] || hr_allow
# The only known ticket key is FRG until projects.json arrives (FRG-10).
ticket='^feature/FRG-[0-9]+-[a-z0-9]+(-[a-z0-9]+)*$'
[[ "$new" =~ $ticket ]] ||
  hr_deny "branch names must be feature/<KEY>-<n>-<slug> with a known key (FRG), lower-case slug words joined by -; not '$new'"
hr_allow
