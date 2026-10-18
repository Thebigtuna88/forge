#!/bin/bash -p
# enforce-branch-format (spec 5.3, FRG-3). A branch that is created, renamed, copied or pushed must
# be named feature/<KEY>-<n>-<slug> with a known key. Covers explicit creation (checkout -b/-B/
# --orphan, switch -c/-C/--create/--force-create/--orphan, branch <new>, branch -m/-c, worktree add
# -b/-B), implicit creation (checkout/switch --track <remote>/<name>, checkout/switch <name> or
# worktree add <path> <name> that git creates from a remote branch, worktree add <path> alone, which
# names the branch after the folder) and git push origin <branch>. A new repository (git init) or
# a clone starts only on dev or main (-b / --initial-branch / --branch). checkout, switch, branch,
# worktree add, init and clone accept only the options listed here, spelled in full: an
# abbreviation (--creat) or a cluster (-qm) is refused, since git would accept it.
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
  checkout | switch | branch | worktree | push | init | clone) ;;
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
paths=0     # after --: no more options (and for checkout, paths rather than branches)
guess=""    # a name git may turn into a new branch from a remote branch
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
    [[ "$HR_GIT_SUB" == checkout ]] || names+=("$a")
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
    init:-b | init:--initial-branch | clone:-b | clone:--branch) take=1 ;;
    init:--initial-branch=* | clone:--branch=*) new="${a#*=}" ;;
    clone:--depth | clone:-o | clone:--origin) skip=1 ;;
    init:-q | init:--quiet | \
      init:--shared | init:--shared=* | init:--object-format=* | init:--ref-format=* | \
      clone:-q | clone:--quiet | clone:--depth=* | clone:--single-branch | clone:--no-single-branch | \
      clone:-n | clone:--no-checkout | clone:--origin=* | clone:--no-tags | clone:--filter=* | \
      clone:--sparse) ;;
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
      branch:--format=* | branch:--edit-description | branch:--unset-upstream | \
      branch:--set-upstream-to=*)
      listing=1
      ;;
    branch:-u | branch:--set-upstream-to)
      listing=1
      skip=1
      ;;
    branch:-v | branch:-vv | branch:--verbose | branch:-q | branch:--quiet | branch:-t | branch:--sort=* | \
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
    # -m / -c win over any listing option given with them (git branch -m --sort=… old new).
    if [[ $count -gt 0 && $rename == 1 ]]; then
      new="${names[$count - 1]}"
    elif [[ $count -gt 0 && $listing == 0 ]]; then
      new="${names[0]}"
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
    # --track without a name, or a name git would create from a remote branch: the name git
    # infers depends on the remote's configured mapping, so the gate wants it spelled out.
    if [[ -z "$new" && $detach == 0 && $count -gt 0 ]]; then
      [[ $track == 0 ]] || hr_deny "create the branch explicitly with -b / -c feature/<KEY>-<n>-<slug>: git would infer its name from a remote branch"
      guess="${names[0]}"
    fi
    ;;
  worktree)
    if [[ -z "$new" && $detach == 0 && $count -eq 1 ]]; then
      folder="${names[0]}"
      while [[ "$folder" == */ ]]; do folder="${folder%/}"; done
      new="${folder##*/}" # git worktree add <path>: a branch named after the folder (no trailing /)
    elif [[ -z "$new" && $detach == 0 && $count -ge 2 ]]; then
      [[ $track == 0 ]] || hr_deny "create the branch explicitly with -b / -c feature/<KEY>-<n>-<slug>: git would infer its name from a remote branch"
      guess="${names[1]}"
    fi
    ;;
esac
if [[ -n "$guess" ]]; then
  # Not a local branch, but a remote-tracking branch of that name exists (at any depth): git
  # would create a local branch from it, named by the remote's mapping.
  [[ -n "$HR_GIT_DIR" && -d "$HR_GIT_DIR" ]] ||
    hr_deny "can't tell which repository this runs in, so can't tell whether git would create a branch"
  if ! git -C "$HR_GIT_DIR" rev-parse --verify --quiet "refs/heads/$guess" >/dev/null; then
    git -C "$HR_GIT_DIR" for-each-ref --format='%(refname)' refs/remotes/ >"$HR_TMP/remotes"
    while IFS= read -r ref; do
      [[ "$ref" != */"$guess" ]] || hr_deny "create the branch explicitly with -b / -c feature/<KEY>-<n>-<slug>: git would infer its name from a remote branch"
    done <"$HR_TMP/remotes"
  fi
fi
if [[ "$HR_GIT_SUB" == init || "$HR_GIT_SUB" == clone ]]; then
  # A new repository or clone starts on dev or main, named explicitly, and without a template
  # directory (templates can carry refs of their own). It is never bare: a bare repository keeps
  # its refs outside a .git folder, where the runtime's .git path guard can't see them.
  # The configuration that applies is the one where the command runs (git -C <dir>).
  [[ -n "$HR_GIT_DIR" && -d "$HR_GIT_DIR" ]] ||
    hr_deny "can't tell which folder git $HR_GIT_SUB runs in, so can't check init.templateDir"
  git -C "$HR_GIT_DIR" config --get init.templateDir >"$HR_TMP/template" 2>/dev/null || true
  [[ ! -s "$HR_TMP/template" ]] ||
    hr_deny "init.templateDir is set: a template can install branches of its own; remove it first"
  [[ -n "$new" ]] ||
    hr_deny "name the initial branch: git $HR_GIT_SUB -b dev (or -b main); otherwise git picks it from configuration or the remote"
  [[ "$new" == dev || "$new" == main ]] ||
    hr_deny "git $HR_GIT_SUB may start only on dev or main as its initial branch, not '$new'"
  hr_allow
fi
[[ -n "$new" ]] || hr_allow
# The only known ticket key is FRG until projects.json arrives (FRG-10).
ticket='^feature/FRG-[0-9]+-[a-z0-9]+(-[a-z0-9]+)*$'
[[ "$new" =~ $ticket ]] ||
  hr_deny "branch names must be feature/<KEY>-<n>-<slug> with a known key (FRG), lower-case slug words joined by -; not '$new'"
hr_allow
