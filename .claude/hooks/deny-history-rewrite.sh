#!/bin/bash -p
# deny-history-rewrite (spec 5.3, FRG-3). Refuses what rewrites or moves branch history, and any
# git command FORGE doesn't know:
#   git rebase, filter-branch, filter-repo, replace, any update-ref, fast-import; writing with
#   git symbolic-ref; git commit --amend; git branch --force/-f/-M/-C (also abbreviated or in a
#   cluster); git checkout -B, git switch -C/--force-create, git worktree add -B (they reset a
#   branch); git reset except unstaging (git reset [-q] [HEAD] [-- <paths>]);
#   git fetch other than `git fetch [-q] [--prune] [<repository> [<branch>…]]` with plain branch
#   names, and git pull with a refspec (":" or "+" moves local branches); git fetch or pull while a
#   configured remote.*.fetch mapping writes outside refs/remotes/; git pull --rebase;
#   git stash other than pop/apply/drop/clear/list/show (a stash is a commit made without the
#   secret scan; stash branch and export write refs);
#   git remote with any option before the subcommand but -v/--verbose, git remote update and
#   prune (use git fetch / git fetch --prune), and git remote add with any option but
#   -t/-m/--tags/--no-tags (it could fetch past the mapping check; use git fetch);
#   git fetch or pull in a repository with submodules (git fetches into them too, with their own
#   mappings);
#   git submodule other than status/summary (FORGE repositories don't use submodules, and update
#   fetches, merges or rebases inside them unchecked);
#   git config writes other than user.name, user.email, core.quotepath, color.* and advice.*
#   (other settings name programs git runs later, such as remote.<name>.uploadpack), and
#   git config rename-section / --edit; reading and removing settings are fine;
#   writing git notes; git reflog other than show/exists/list (delete --updateref moves a branch);
#   git tag with any option outside listing/deleting/verifying, or a plain tag while tag.gpgSign is
#   set (both put unscanned text into git, which push.followTags could carry with a branch);
#   any git command that is neither on the runtime's safe list nor checked by a FORGE gate
#   (git history, git replay, and whatever a newer git adds).
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
  fast-import)
    hr_deny "git fast-import writes refs directly (and makes unscanned commits)"
    ;;
  symbolic-ref)
    # Reading (git symbolic-ref [-q] [--short] <name>) is fine; anything else writes a ref.
    count=0
    for a in ${HR_GIT_ARGS[@]+"${HR_GIT_ARGS[@]}"}; do
      case "$a" in
        -q | --quiet | --short) ;;
        -*) hr_deny "git symbolic-ref $a writes refs directly" ;;
        *) ((count += 1)) ;;
      esac
    done
    [[ $count -le 1 ]] || hr_deny "git symbolic-ref with a target writes refs directly"
    hr_allow
    ;;
  stash)
    # Saving a stash (git stash, push, save, or an option such as -u) makes a commit that the
    # secret scan never sees; restoring, listing and dropping stashes is fine.
    case "${HR_GIT_ARGS[0]:-push}" in
      pop | apply | drop | clear | list | show) hr_allow ;;
      push | save | -*) hr_deny "git stash ${HR_GIT_ARGS[*]:-push} creates a commit without the secret scan; commit the work on the ticket branch instead" ;;
      *) hr_deny "git stash ${HR_GIT_ARGS[0]} creates or writes branches or refs; use stash pop/apply/drop/list/show" ;;
    esac
    ;;
  commit | branch | checkout | switch | worktree | reset | fetch | pull) ;;
  remote)
    # git remote [-v | --verbose] <subcommand> …
    first=0
    while [[ $first -lt ${#HR_GIT_ARGS[@]} && ("${HR_GIT_ARGS[$first]}" == -v || "${HR_GIT_ARGS[$first]}" == --verbose) ]]; do
      ((first += 1))
    done
    case "${HR_GIT_ARGS[$first]:-}" in
      -*) hr_deny "git remote option ${HR_GIT_ARGS[$first]} before the subcommand is not one FORGE knows (only -v / --verbose)" ;;
      update) hr_deny "git remote update fetches past FORGE's fetch checks; use git fetch" ;;
      prune) hr_deny "git remote prune deletes remote-tracking refs without FORGE's fetch checks; use git fetch --prune" ;;
      add)
        skip=0
        start=$first
        ((start += 1))
        for a in "${HR_GIT_ARGS[@]:start}"; do
          if [[ $skip == 1 ]]; then
            skip=0
            continue
          fi
          case "$a" in
            -t | -m) skip=1 ;;
            --tags | --no-tags) ;;
            -*) hr_deny "git remote add option $a is not one FORGE allows (only -t, -m, --tags, --no-tags); add the remote, then use git fetch" ;;
          esac
        done
        ;;
    esac
    hr_allow
    ;;
  submodule)
    # FORGE repositories don't use submodules. Anything beyond looking (update fetches, merges or
    # rebases inside them with their own, unchecked settings) is refused.
    case "${HR_GIT_ARGS[0]:-status}" in
      status | summary) hr_allow ;;
      *) hr_deny "git submodule ${HR_GIT_ARGS[0]} runs or changes things FORGE can't check inside submodules (FORGE repositories don't use submodules)" ;;
    esac
    ;;
  config)
    # Reading settings is fine. Many settings name a program git runs later (core.pager,
    # core.sshCommand, remote.<name>.uploadpack, diff.external, filter.*, …) or text it copies
    # into commits, so writing is limited to identity and display settings. Removing a setting is
    # allowed (the gates ask for that); renaming a section or opening an editor is not.
    mode=""
    skip=0
    cfgnames=()
    for a in ${HR_GIT_ARGS[@]+"${HR_GIT_ARGS[@]}"}; do
      if [[ $skip == 1 ]]; then
        skip=0
        continue
      fi
      case "$a" in
        --get | --get-all | --get-regexp | --get-urlmatch | --get-color | --get-colorbool | -l | --list) mode="reading" ;;
        --unset | --unset-all | --remove-section) mode="removing" ;;
        --add | --replace-all) mode="writing" ;;
        --local | --global | --system | --worktree | --show-origin | --show-scope | --name-only | -z | \
          --null | --includes | --no-includes | --bool | --int | --bool-or-int | --path | \
          --expiry-date | --fixed-value | --type=* | --default=* | --file=* | --blob=*) ;;
        -f | --file | --blob | -t | --type | --default) skip=1 ;;
        -*) hr_deny "git config option $a is not one FORGE knows (reading settings, writing identity and display settings, and removing settings are allowed)" ;;
        *) cfgnames+=("$a") ;;
      esac
    done
    if [[ -z "$mode" ]]; then
      # git config get|list|set|unset|… <name> (git 2.46 and later), or git config <name> [<value>]
      case "${cfgnames[0]:-}" in
        get | list) mode="reading" ;;
        unset | remove-section) mode="removing" ;;
        set)
          mode="writing"
          cfgnames=("${cfgnames[@]:1}")
          ;;
        rename-section | edit | "") hr_deny "git config ${cfgnames[0]:-with no setting} is not allowed (it can move settings into place or open an editor)" ;;
        *) if [[ ${#cfgnames[@]} -ge 2 ]]; then mode="writing"; else mode="reading"; fi ;;
      esac
    fi
    if [[ "$mode" == writing ]]; then
      key="$(_hr_lower "${cfgnames[0]:-}")"
      case "$key" in
        user.name | user.email | core.quotepath | color.* | advice.*) ;;
        *) hr_deny "git config may set only user.name, user.email, core.quotepath, color.* and advice.*, not '${cfgnames[0]:-}' (other settings can run programs or change what git writes)" ;;
      esac
    fi
    hr_allow
    ;;
  notes)
    case "${HR_GIT_ARGS[0]:-list}" in
      list | show) hr_allow ;;
      *) hr_deny "git notes ${HR_GIT_ARGS[0]} writes a notes commit without the secret scan; notes may only be read" ;;
    esac
    ;;
  tag)
    # Listing, deleting and verifying only (an option outside the list may carry a message, also
    # abbreviated or attached: --mes=, -mTEXT); a plain tag is refused while tag.gpgSign would make
    # it a signed tag with a message.
    names=0
    nosign=0
    notcreating=0  # listing, deleting or verifying: no tag is made
    for a in ${HR_GIT_ARGS[@]+"${HR_GIT_ARGS[@]}"}; do
      case "$a" in
        --no-sign) nosign=1 ;;
        -l | --list | -d | --delete | -v | --verify) notcreating=1 ;;
        # git lists tags when any of these is given, so the names after them are filters.
        --contains | --no-contains | --merged | --no-merged | --points-at | --contains=* | \
          --no-contains=* | --merged=* | --no-merged=* | --points-at=* | -n | -n[0-9]*) notcreating=1 ;;
        -i | --ignore-case | --sort=* | --format=* | --column | --column=* | --no-column) ;;
        -a | --annotate | -s | --sign | -u | -m | -F | -e | --edit)
          hr_deny "a tag with a message (git tag $a) puts unscanned text into git; use a plain tag (git tag <name>)"
          ;;
        -*) hr_deny "git tag option $a is not one FORGE allows (it may carry a message); use a plain tag" ;;
        *) ((names += 1)) ;;
      esac
    done
    if [[ $names -gt 0 && $nosign == 0 && $notcreating == 0 ]]; then
      [[ -n "$HR_GIT_DIR" && -d "$HR_GIT_DIR" ]] ||
        hr_deny "can't tell which repository this runs in, so can't check tag.gpgSign; use git tag --no-sign <name>"
      git -C "$HR_GIT_DIR" config --type=bool --get tag.gpgSign >"$HR_TMP/gpgsign" 2>/dev/null || true
      gpgsign="$(cat "$HR_TMP/gpgsign")"
      [[ "$gpgsign" != true ]] ||
        hr_deny "tag.gpgSign is set, so a plain tag would be a signed tag with a message; use git tag --no-sign <name>"
    fi
    hr_allow
    ;;
  reflog)
    case "${HR_GIT_ARGS[0]:-show}" in
      show | exists | list | -*) hr_allow ;;
      *) hr_deny "git reflog ${HR_GIT_ARGS[0]} can move or drop branch history (delete --updateref); reflog may only be read" ;;
    esac
    ;;
  push | send-pack | http-push | merge | commit-tree | am | cherry-pick | revert | \
    bundle | init | clone)
    hr_allow # checked by another FORGE gate, or understood and harmless to history
    ;;
  *)
    [[ "$_HR_GIT_SAFE_SUBS" == *" $HR_GIT_SUB "* ]] ||
      hr_deny "git $HR_GIT_SUB is not on FORGE's list of git commands it can check, so it is refused"
    hr_allow
    ;;
esac

if [[ "$HR_GIT_SUB" == fetch || "$HR_GIT_SUB" == pull ]]; then
  # A configured mapping (git config remote.<name>.fetch) applies to every fetch: each must have
  # the standard shape, refs/heads/<x>:refs/remotes/<name>/<x> (or a negative ^refspec), so it
  # never writes a local branch. Old-style .git/remotes and .git/branches files map fetches too.
  [[ -n "$HR_GIT_DIR" && -d "$HR_GIT_DIR" ]] ||
    hr_deny "can't tell which repository this runs in, so can't check its fetch mappings"
  git -C "$HR_GIT_DIR" config --get-regexp '^remote\..*\.fetch$' >"$HR_TMP/mappings" 2>/dev/null || true
  while read -r key mapping; do
    name="${key#remote.}"
    name="${name%.fetch}"
    src="${mapping#+}"
    src="${src%%:*}"
    dst="${mapping#*:}"
    if [[ "$mapping" != ^* && ("$src" != refs/heads/* || "$dst" != "refs/remotes/$name/${src#refs/heads/}") ]]; then
      hr_deny "a configured fetch mapping ($mapping) maps fetched branches into local branches or outside refs/remotes/$name/; fix remote.$name.fetch first"
    fi
  done <"$HR_TMP/mappings"
  git -C "$HR_GIT_DIR" rev-parse --path-format=absolute --git-common-dir >"$HR_TMP/common"
  common="$(cat "$HR_TMP/common")"
  find "$common/remotes" "$common/branches" -mindepth 1 -print -quit >"$HR_TMP/legacy" 2>/dev/null || true
  [[ ! -s "$HR_TMP/legacy" ]] ||
    hr_deny "old-style remote definitions ($common/remotes or $common/branches) can map fetches into local branches; remove them first"
  # git also fetches populated submodules (on demand, or always with fetch.recurseSubmodules),
  # each with its own mappings, which this gate doesn't check: no fetch where submodules exist.
  find "$common/modules" -mindepth 1 -print -quit >"$HR_TMP/modules" 2>/dev/null || true
  git -C "$HR_GIT_DIR" ls-files --stage -- ':(top)' >"$HR_TMP/index"
  if [[ -s "$HR_TMP/modules" ]] || grep -q '^160000 ' "$HR_TMP/index"; then
    hr_deny "this repository has submodules, and git $HR_GIT_SUB would fetch into them with mappings FORGE doesn't check; FORGE repositories don't use submodules"
  fi
fi

moves="git reset moves the branch; to unstage, use git reset -- <path> (or git reset HEAD <path>)"
fetchonly="fetch only as: git fetch [-q] [--prune] [<repository> [<branch>…]]"
head=0      # git reset: HEAD came first, so the words after it are paths
endopts=0   # after --: no more options
operands=0  # git fetch / pull: positional words so far (the first is the repository)
for a in ${HR_GIT_ARGS[@]+"${HR_GIT_ARGS[@]}"}; do
  if [[ $endopts == 1 && "$HR_GIT_SUB" == reset ]]; then
    continue # paths
  fi
  if [[ $endopts == 0 && "$a" == -- ]]; then
    endopts=1
    continue
  fi
  word="$a"
  if [[ $endopts == 1 ]]; then word="operand:$a"; fi
  case "$HR_GIT_SUB:$word" in
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
    fetch:-q | fetch:--quiet | fetch:-p | fetch:--prune) ;;
    fetch:-*)
      hr_deny "$fetchonly (not $a, which updates local branches directly or isn't checked here)"
      ;;
    pull:-r | pull:--rebase | pull:--rebase=*)
      hr_deny "git pull $a rewrites history; use git pull --ff-only"
      ;;
    pull:-*) ;; # secret-scan rules pull's options
    fetch:* | pull:*)
      ((operands += 1))
      if [[ $operands -gt 1 ]]; then
        case "$a" in
          *:* | +*) hr_deny "$fetchonly ($a updates local branches directly)" ;;
        esac
      fi
      ;;
  esac
done
hr_allow
