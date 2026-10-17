#!/bin/bash -p
# enforce-branch-format (spec 5.3, FRG-3). A branch that is created, renamed, copied or pushed must
# be named feature/<KEY>-<n>-<slug> with a known key. Covers explicit creation (checkout -b/-B/
# --orphan, switch -c/-C/--create/--force-create/--orphan, branch <new>, branch -m/-c, worktree add
# -b/-B), implicit creation (checkout/switch --track <remote>/<name>, checkout/switch <name> or
# worktree add <path> <name> that git creates from a remote branch, worktree add <path> alone, which
# names the branch after the folder) and git push origin <branch>. checkout, switch, branch and
# worktree add accept only the options listed here, spelled in full: an abbreviation (--creat) or a
# cluster (-qm) is refused, since git would accept it.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init enforce-branch-format
hr_guarded || hr_allow
hr_require_simple
[[ "${HR_TOK[0]:-}" == git ]] || hr_allow
case "$HR_GIT_SUB" in
  checkout | switch | branch | worktree | push) ;;
  *) hr_allow ;;
esac
# git worktree: only "add" creates a branch.
if [[ "$HR_GIT_SUB" == worktree && "${HR_GIT_ARGS[0]:-}" != add ]]; then hr_allow; fi

new=""      # the branch name this command creates, renames or copies to, or pushes
take=0      # the next word is the name a creating option takes
skip=0      # the next word is the value of another option
rename=0    # git branch -m / -c: the last name is the new one
listing=0   # git branch lists or deletes: its names are not new branches
track=0     # --track / -t without an explicit name: the name comes from the remote branch
detach=0    # --detach: no branch at all
paths=0     # after --: paths, not branches
names=()    # plain words after the subcommand (and after "add" for worktree)
first=1
for a in ${HR_GIT_ARGS[@]+"${HR_GIT_ARGS[@]}"}; do
  if [[ $first == 1 && "$HR_GIT_SUB" == worktree ]]; then
    first=0
    continue # the word "add"
  fi
  first=0
  if [[ $take == 1 ]]; then
    new="$a"
    take=0
    continue
  fi
  if [[ $skip == 1 ]]; then
    skip=0
    continue
  fi
  if [[ $paths == 1 ]]; then
    continue
  fi
  case "$HR_GIT_SUB:$a" in
    *:--) [[ "$HR_GIT_SUB" == push ]] || paths=1 ;;
    checkout:-b | checkout:-B | checkout:--orphan | switch:-c | switch:-C | switch:--create | \
      switch:--force-create | switch:--orphan | worktree:-b | worktree:-B)
      take=1
      ;;
    checkout:--orphan=* | switch:--orphan=* | switch:--create=* | switch:--force-create=*)
      new="${a#*=}"
      ;;
    checkout:-t | checkout:--track | switch:-t | switch:--track | worktree:--track) track=1 ;;
    checkout:--detach | switch:-d | switch:--detach | worktree:-d | worktree:--detach) detach=1 ;;
    checkout:-q | checkout:--quiet | checkout:-f | checkout:--force | checkout:--ours | \
      checkout:--theirs | checkout:-m | checkout:--merge | checkout:--no-track | \
      switch:-q | switch:--quiet | switch:-f | switch:--force | switch:--discard-changes | \
      switch:-m | switch:--merge | switch:--no-track | switch:--no-guess | \
      worktree:-f | worktree:--force | worktree:-q | worktree:--quiet | worktree:--checkout | \
      worktree:--no-checkout | worktree:--lock | worktree:--no-track | worktree:--no-guess-remote) ;;
    branch:-m | branch:-M | branch:--move | branch:-c | branch:-C | branch:--copy) rename=1 ;;
    branch:-d | branch:-D | branch:--delete | branch:-l | branch:--list | branch:-a | branch:--all | \
      branch:-r | branch:--remotes | branch:--show-current | branch:--merged | branch:--no-merged | \
      branch:--contains | branch:--no-contains | branch:--points-at | branch:--merged=* | \
      branch:--no-merged=* | branch:--contains=* | branch:--no-contains=* | branch:--points-at=* | \
      branch:--sort=* | branch:--format=* | branch:--edit-description | branch:--unset-upstream | \
      branch:--set-upstream-to=*)
      listing=1
      ;;
    branch:-u | branch:--set-upstream-to)
      listing=1
      skip=1
      ;;
    branch:-v | branch:-vv | branch:--verbose | branch:-q | branch:--quiet | branch:-t | \
      branch:--track | branch:--no-track | branch:-f | branch:--force | branch:--column | \
      branch:--no-column | branch:--color | branch:--no-color) ;;
    push:-*) ;; # deny-push-to-protected rules push options
    *:-*) hr_deny "git $HR_GIT_SUB option $a is not an option this gate knows; spell options in full, one at a time" ;;
    *) names+=("$a") ;;
  esac
done
[[ $take == 0 ]] || hr_deny "git $HR_GIT_SUB needs a branch name after its option"

# A remote branch name without its remote ("origin/feature/FRG-3-a" → "feature/FRG-3-a").
count=${#names[@]}
case "$HR_GIT_SUB" in
  branch)
    if [[ $count -gt 0 && $listing == 0 ]]; then
      if [[ $rename == 1 ]]; then
        new="${names[$count - 1]}"
      else
        new="${names[0]}"
      fi
    fi
    ;;
  push)
    # git push <remote> <refspec>: the branch pushed to is after any ":" (deny-push-to-protected
    # allows only the plain form; this keeps the name rule for every spelling).
    if [[ $count -ge 2 ]]; then
      new="${names[1]#+}"
      new="${new#*:}"
    fi
    ;;
  checkout | switch)
    if [[ -z "$new" && $detach == 0 && $count -gt 0 ]]; then
      if [[ $track == 1 ]]; then
        new="${names[0]#*/}"
      elif [[ -z "$HR_GIT_DIR" || ! -d "$HR_GIT_DIR" ]]; then
        hr_deny "can't tell which repository this runs in, so can't tell whether git would create a branch"
      elif ! git -C "$HR_GIT_DIR" rev-parse --verify --quiet "refs/heads/${names[0]}" >/dev/null; then
        # Not a local branch: git creates one when the name matches a remote branch.
        git -C "$HR_GIT_DIR" for-each-ref --format='%(refname)' "refs/remotes/*/${names[0]}" >"$HR_TMP/remote"
        if [[ -s "$HR_TMP/remote" ]]; then new="${names[0]}"; fi
      fi
    fi
    ;;
  worktree)
    if [[ -z "$new" && $detach == 0 && $count -eq 1 ]]; then
      new="${names[0]##*/}" # git worktree add <path>: a branch named after the folder
    elif [[ -z "$new" && $detach == 0 && $count -ge 2 && $track == 1 ]]; then
      new="${names[1]#*/}"
    elif [[ -z "$new" && $detach == 0 && $count -ge 2 ]]; then
      [[ -n "$HR_GIT_DIR" && -d "$HR_GIT_DIR" ]] ||
        hr_deny "can't tell which repository this runs in, so can't tell whether git would create a branch"
      if ! git -C "$HR_GIT_DIR" rev-parse --verify --quiet "refs/heads/${names[1]}" >/dev/null; then
        git -C "$HR_GIT_DIR" for-each-ref --format='%(refname)' "refs/remotes/*/${names[1]}" >"$HR_TMP/remote"
        if [[ -s "$HR_TMP/remote" ]]; then new="${names[1]}"; fi
      fi
    fi
    ;;
esac
[[ -n "$new" ]] || hr_allow
# The only known ticket key is FRG until projects.json arrives (FRG-10).
ticket='^feature/FRG-[0-9]+-[a-z0-9]+(-[a-z0-9]+)*$'
[[ "$new" =~ $ticket ]] ||
  hr_deny "branch names must be feature/<KEY>-<n>-<slug> with a known key (FRG), lower-case slug words joined by -; not '$new'"
hr_allow
