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
#   git stash other than push/save/pop/apply/drop/clear/list/show (stash branch, export, …);
#   git remote update, and git remote add with any option but -t/-m/--tags/--no-tags (it could
#   fetch past the mapping check; use git fetch);
#   git submodule other than status/summary/init/sync/absorbgitdirs/deinit, and submodule update
#   without --checkout or with other options (unchecked commits or rebases in submodules);
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
    case "${HR_GIT_ARGS[0]:-push}" in
      push | save | pop | apply | drop | clear | list | show | -*) hr_allow ;;
      *) hr_deny "git stash ${HR_GIT_ARGS[0]} creates or writes branches or refs; use stash push/pop/apply/drop/list/show" ;;
    esac
    ;;
  commit | branch | checkout | switch | worktree | reset | fetch | pull) ;;
  remote)
    case "${HR_GIT_ARGS[0]:-}" in
      update) hr_deny "git remote update fetches past FORGE's fetch checks; use git fetch" ;;
      add)
        skip=0
        for a in "${HR_GIT_ARGS[@]:1}"; do
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
    case "${HR_GIT_ARGS[0]:-status}" in
      status | summary | init | sync | absorbgitdirs | deinit) hr_allow ;;
      update)
        # Only listed options, and --checkout must be said: it overrides a configured
        # submodule.<name>.update=merge/rebase.
        checkout=0
        for a in "${HR_GIT_ARGS[@]:1}"; do
          case "$a" in
            --checkout) checkout=1 ;;
            --init | --recursive | -q | --quiet | --no-fetch | -N | --) ;;
            -*) hr_deny "git submodule update option $a is not one FORGE allows (it may merge, rebase or skip checks)" ;;
          esac
        done
        [[ $checkout == 1 ]] ||
          hr_deny "git submodule update must say --checkout, so configuration can't make it merge or rebase"
        hr_allow
        ;;
      *) hr_deny "git submodule ${HR_GIT_ARGS[0]} runs or changes things FORGE can't check inside submodules" ;;
    esac
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
    for a in ${HR_GIT_ARGS[@]+"${HR_GIT_ARGS[@]}"}; do
      case "$a" in
        --no-sign) nosign=1 ;;
        -l | --list | -d | --delete | -v | --verify | -i | --ignore-case | \
          --contains | --no-contains | --merged | --no-merged | --points-at | --contains=* | \
          --no-contains=* | --merged=* | --no-merged=* | --points-at=* | --sort=* | --format=* | \
          --column | --column=* | --no-column | -n | -n[0-9]*) ;;
        -a | --annotate | -s | --sign | -u | -m | -F | -e | --edit)
          hr_deny "a tag with a message (git tag $a) puts unscanned text into git; use a plain tag (git tag <name>)"
          ;;
        -*) hr_deny "git tag option $a is not one FORGE allows (it may carry a message); use a plain tag" ;;
        *) ((names += 1)) ;;
      esac
    done
    if [[ $names -gt 0 && $nosign == 0 ]]; then
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
  push | send-pack | http-push | merge | commit-tree | am | cherry-pick | revert | config | \
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
  # A configured mapping (git config remote.<name>.fetch) applies to every fetch: each one must
  # write only under refs/remotes/ (or be a negative ^refspec).
  [[ -n "$HR_GIT_DIR" && -d "$HR_GIT_DIR" ]] ||
    hr_deny "can't tell which repository this runs in, so can't check its fetch mappings"
  git -C "$HR_GIT_DIR" config --get-regexp '^remote\..*\.fetch$' >"$HR_TMP/mappings" 2>/dev/null || true
  while read -r _ mapping; do
    case "$mapping" in
      ^* | *:refs/remotes/*) ;;
      *) hr_deny "a configured fetch mapping ($mapping) maps fetched branches into local branches; fix remote.*.fetch first" ;;
    esac
  done <"$HR_TMP/mappings"
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
