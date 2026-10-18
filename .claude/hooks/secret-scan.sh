#!/bin/bash -p
# secret-scan (spec 5.3, FRG-3). Every way of making a commit goes through a secret scan:
# - git commit only as `git commit -F <message file>` (or --file), and only if gitleaks finds no
#   secret in the staged files or in the message file. The staged files are read straight from
#   git's index as raw blobs (git cat-file), so .gitattributes (-diff, filters) and diff settings
#   (diff.relative, diff.ignoreSubmodules) can't hide them. They are scanned twice: under their own
#   names (gitleaks has rules that match names) and under neutral names (gitleaks' defaults skip
#   some paths, such as package-lock.json, entirely). The message is scanned under a neutral name.
#   The message file must be a regular file (not a link). gitleaks always uses FORGE's own rules
#   (.harness/gitleaks.toml), never the repository's .gitleaks.toml, .gitleaksignore or
#   gitleaks:allow comments; a missing gitleaks blocks.
# - git merge only as `git merge --no-commit [--no-edit] [--no-ff] [-q] <branch>`, `--ff-only`,
#   `--squash` or `git merge --abort`: git never makes the merge commit itself, since a merge driver
#   or filter can write new content into the result; `git commit -F` then scans the whole merged
#   result (a fast-forward makes no new content). <branch> is dev, main or a ticket
#   branch (or origin/ and one of those) and must be a branch, not a tag: git writes the name, and
#   an annotated tag's message, into the merge commit's message. A merge stopped by a conflict is
#   concluded with git commit -F (scanned), not git merge --continue. Refused while a
#   branch.*.mergeOptions setting could add options (such as -F) behind the command's back, or
#   merge.branchdesc / a branch.*.description could put unscanned text into the merge message.
# - git pull only with --ff-only (no merge commit), and not while pull.rebase or branch.*.rebase
#   is set. Merge and pull are refused while merge.autoStash or pull.autoStash is on (an automatic
#   stash is a commit of the working files, made without the scan).
# - The author and committer git writes into a commit or merge commit (user.name, user.email) are
#   scanned too. Commit and merge are refused while i18n.commitEncoding names anything but UTF-8
#   (git copies it into the commit) or commit.gpgSign is on (a signing program's output goes in).
# - Guarded git commands are refused while the environment sets GIT_* variables (hookrt.sh), so
#   the index and identity scanned here are the ones git uses.
# - git commit-tree, am, cherry-pick, revert and fast-import skip the scan, so they're refused.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init secret-scan
hr_guarded || hr_allow
hr_require_simple
[[ "${HR_TOK[0]:-}" == git ]] || hr_allow
case "$HR_GIT_SUB" in
  commit | merge | pull) ;;
  commit-tree | am | cherry-pick | revert | fast-import)
    hr_deny "git $HR_GIT_SUB makes a commit without the secret scan; commit with: git commit -F <message file>"
    ;;
  *) hr_allow ;;
esac

if [[ "$HR_GIT_SUB" == merge || "$HR_GIT_SUB" == pull ]]; then
  [[ -n "$HR_GIT_DIR" && -d "$HR_GIT_DIR" ]] ||
    hr_deny "can't tell which repository this runs in, so can't check its merge settings"
  git -C "$HR_GIT_DIR" config --get-regexp '^branch\..*\.mergeoptions$' >"$HR_TMP/mergecfg" 2>/dev/null || true
  while read -r key value; do
    hr_deny "$key is set ($value): mergeOptions can add options (such as -F <file>) the gate doesn't see; remove it first"
  done <"$HR_TMP/mergecfg"
  git -C "$HR_GIT_DIR" config --get-regexp '^(merge\.branchdesc|branch\..*\.description)$' >"$HR_TMP/desccfg" 2>/dev/null || true
  while read -r key _; do
    hr_deny "$key is set: a branch description can go into the merge message unscanned; remove it first"
  done <"$HR_TMP/desccfg"
  git -C "$HR_GIT_DIR" config --get-regexp '^(merge|pull)\.autostash$' >"$HR_TMP/stashcfg" 2>/dev/null || true
  while read -r key value; do
    low="$(_hr_lower "$value")"
    case "$low" in
      false | no | off | 0) ;;
      *) hr_deny "$key is set ($value): an automatic stash commits the working files without the secret scan; remove it first" ;;
    esac
  done <"$HR_TMP/stashcfg"
fi

if [[ "$HR_GIT_SUB" == merge ]]; then
  target=""
  nocommit=0
  for a in ${HR_GIT_ARGS[@]+"${HR_GIT_ARGS[@]}"}; do
    case "$a" in
      --continue)
        hr_deny "conclude a merge with git commit -F <message file> (scanned), not git merge --continue"
        ;;
      --abort)
        [[ ${#HR_GIT_ARGS[@]} == 1 ]] || hr_deny "abort a merge with git merge --abort alone"
        hr_allow
        ;;
      --no-commit | --ff-only | --squash) nocommit=1 ;;
      --no-edit | --no-ff | -q | --quiet) ;;
      -*)
        hr_deny "merge only as: git merge --no-commit [--no-ff] <branch> (or --ff-only, --squash), or git merge --abort (not $a)"
        ;;
      *)
        [[ -z "$target" ]] || hr_deny "merge one branch at a time"
        target="$a"
        ;;
    esac
  done
  # A merge commit made by git itself skips the scan of its result, so git must stop first.
  [[ $nocommit == 1 ]] ||
    hr_deny "merge as git merge --no-commit <branch>, then commit the result with git commit -F <message file>, which scans it (a fast-forward needs no commit)"
  # The branch name goes into the merge message, so it must be one whose text is known.
  [[ -n "$target" ]] || hr_deny "name the branch to merge: git merge --no-commit dev"
  named='^(origin/)?(dev|main|feature/FRG-[0-9]+-[a-z0-9]+(-[a-z0-9]+)*)$'
  [[ "$target" =~ $named ]] ||
    hr_deny "merge only dev, main or a ticket branch (or origin/ and one of those), not '$target'"
  # Every ref git could take the name for, in git's own order; it must be a branch and nothing else.
  found=""
  for ref in "refs/$target" "refs/tags/$target" "refs/heads/$target" "refs/remotes/$target" "refs/remotes/$target/HEAD"; do
    if git -C "$HR_GIT_DIR" show-ref --verify --quiet "$ref"; then
      [[ -z "$found" ]] || hr_deny "'$target' names more than one ref ($found and $ref); merge a name that is only a branch"
      found="$ref"
    fi
  done
  [[ "$found" == "refs/heads/$target" || "$found" == "refs/remotes/$target" ]] ||
    hr_deny "'$target' is not a branch (it is ${found:-no ref at all}); a tag's name and message would go into the merge message unscanned"
fi

if [[ "$HR_GIT_SUB" == pull ]]; then
  git -C "$HR_GIT_DIR" config --get-regexp '^(pull\.rebase|branch\..*\.rebase)$' >"$HR_TMP/rebasecfg" 2>/dev/null || true
  while read -r key value; do
    [[ "$value" == false ]] || hr_deny "$key is set ($value), so git pull could rebase; remove it first"
  done <"$HR_TMP/rebasecfg"
  ffonly=0
  for a in ${HR_GIT_ARGS[@]+"${HR_GIT_ARGS[@]}"}; do
    case "$a" in
      --ff-only) ffonly=1 ;;
      -q | --quiet) ;;
      -*) hr_deny "pull only with --ff-only: git pull --ff-only <remote> <branch> (not $a)" ;;
    esac
  done
  [[ $ffonly == 1 ]] || hr_deny "pull only with --ff-only, so it never makes an unscanned merge commit"
  hr_allow
fi

message=""
if [[ "$HR_GIT_SUB" == commit ]]; then
  if [[ ${#HR_GIT_ARGS[@]} -eq 2 && ("${HR_GIT_ARGS[0]}" == -F || "${HR_GIT_ARGS[0]}" == --file) ]]; then
    message="${HR_GIT_ARGS[1]}"
  elif [[ ${#HR_GIT_ARGS[@]} -eq 1 && "${HR_GIT_ARGS[0]}" == --file=* ]]; then
    message="${HR_GIT_ARGS[0]#--file=}"
  fi
  [[ -n "$message" ]] ||
    hr_deny "commit only as: git commit -F <message file> (no -m, -a, --amend, --no-verify or other options)"
  [[ -n "$HR_GIT_DIR" && -d "$HR_GIT_DIR" ]] ||
    hr_deny "can't tell which repository this commit is in, so it can't be scanned for secrets"
  # git reads "-" as standard input, never as a file of that name.
  [[ "$message" != - ]] ||
    hr_deny "the message must come from a message file, not standard input (git commit -F -)"
  [[ "$message" == /* ]] || message="$HR_GIT_DIR/$message"
  [[ -f "$message" && -r "$message" && ! -L "$message" ]] ||
    hr_deny "the message file must be a regular file you can read (not a link), so it can be scanned too: $message"
fi
type -P gitleaks >/dev/null || hr_deny "gitleaks is not installed, so the commit can't be scanned for secrets"
rules="$HR_ROOT/.harness/gitleaks.toml"
mkdir "$HR_TMP/no-ignore" "$HR_TMP/identity"

# Other configuration git copies into the commit object.
git -C "$HR_GIT_DIR" config --get i18n.commitEncoding >"$HR_TMP/encoding" 2>/dev/null || true
encoding="$(cat "$HR_TMP/encoding")"
low="$(_hr_lower "$encoding")"
case "$low" in
  "" | utf-8 | utf8) ;;
  *) hr_deny "i18n.commitEncoding is set ($encoding): git copies it into the commit unscanned; remove it first" ;;
esac
git -C "$HR_GIT_DIR" config --type=bool --get commit.gpgSign >"$HR_TMP/gpgsign" 2>/dev/null || true
gpgsign="$(cat "$HR_TMP/gpgsign")"
[[ "$gpgsign" != true ]] ||
  hr_deny "commit.gpgSign is on: the signing program's output goes into the commit unscanned; remove it first"

# A half-finished cherry-pick, rebase or am keeps the original commit's author, not the identity
# scanned below, so no commit while one is in progress.
if [[ "$HR_GIT_SUB" == commit ]]; then
  git -C "$HR_GIT_DIR" rev-parse --path-format=absolute --git-dir >"$HR_TMP/gitdir"
  gitdir="$(cat "$HR_TMP/gitdir")"
  for state in CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply sequencer; do
    [[ ! -e "$gitdir/$state" ]] ||
      hr_deny "a cherry-pick, revert, rebase or am is in progress ($state), and git would keep that commit's author, which FORGE can't scan; ask the owner to finish or abort it"
  done
fi

# The author and committer git writes into the commit (user.name / user.email, or what git works
# out without them).
if ! git -C "$HR_GIT_DIR" var GIT_AUTHOR_IDENT >"$HR_TMP/identity/author" 2>/dev/null; then
  hr_deny "can't tell who the commit's author would be (git var GIT_AUTHOR_IDENT failed); set user.name and user.email"
fi
if ! git -C "$HR_GIT_DIR" var GIT_COMMITTER_IDENT >"$HR_TMP/identity/committer" 2>/dev/null; then
  hr_deny "can't tell who the commit's committer would be (git var GIT_COMMITTER_IDENT failed); set user.name and user.email"
fi
if ! gitleaks dir --config "$rules" --gitleaks-ignore-path "$HR_TMP/no-ignore" --ignore-gitleaks-allow \
  --no-banner --no-color --redact --exit-code 1 "$HR_TMP/identity" >"$HR_TMP/identity.out" 2>&1; then
  summary="$(tail -n 3 "$HR_TMP/identity.out")"
  hr_deny "gitleaks found a possible secret in the commit's author or committer (user.name / user.email), or could not scan them: ${summary//$'\n'/ | }"
fi
[[ "$HR_GIT_SUB" == commit ]] || hr_allow

# The staged files as raw blobs, read by their exact object ids, under their own paths. The whole
# index is listed (--no-relative), whatever folder the commit runs from.
mkdir "$HR_TMP/staged" "$HR_TMP/neutral" "$HR_TMP/message"
n=0
git -C "$HR_GIT_DIR" diff --cached --raw -z --no-abbrev --no-renames --no-relative \
  --ignore-submodules=none --diff-filter=ACMRT >"$HR_TMP/staged.list"
while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
  read -r _ mode _ blob _ <<<"$meta"
  [[ "$mode" != 160000 ]] || hr_deny "a staged submodule ($path) can't be scanned for secrets"
  case "$path" in
    */*) mkdir -p "$HR_TMP/staged/${path%/*}" ;;
  esac
  git -C "$HR_GIT_DIR" cat-file blob "$blob" >"$HR_TMP/staged/$path"
  ((n += 1))
  cp "$HR_TMP/staged/$path" "$HR_TMP/neutral/blob-$n"
done <"$HR_TMP/staged.list"
cp "$message" "$HR_TMP/message/commit-message"

for scan in staged neutral message; do
  if ! gitleaks dir --config "$rules" --gitleaks-ignore-path "$HR_TMP/no-ignore" --ignore-gitleaks-allow \
    --no-banner --no-color --redact --exit-code 1 "$HR_TMP/$scan" >"$HR_TMP/$scan.out" 2>&1; then
    summary="$(tail -n 3 "$HR_TMP/$scan.out")"
    if [[ "$scan" == message ]]; then
      hr_deny "gitleaks found a possible secret in the commit message (or could not scan it): ${summary//$'\n'/ | }"
    fi
    hr_deny "gitleaks found a possible secret in the staged changes (or could not scan them): ${summary//$'\n'/ | }"
  fi
done
hr_allow
