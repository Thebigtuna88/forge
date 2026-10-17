#!/bin/bash -p
# secret-scan (spec 5.3, FRG-3). Every way of making a commit goes through a secret scan:
# - git commit only as `git commit -F <message file>` (or --file), and only if gitleaks finds no
#   secret in the staged files or in the message file. The staged files are read straight from
#   git's index as raw blobs (git cat-file), under their own names (gitleaks has rules that match
#   names), so .gitattributes (-diff, filters) and diff settings (diff.relative) can't hide them.
#   The message file must be a regular file (not a link). gitleaks always uses FORGE's own rules
#   (.harness/gitleaks.toml), never the repository's .gitleaks.toml, .gitleaksignore or
#   gitleaks:allow comments; a missing gitleaks blocks.
# - git merge only as `git merge [--no-edit] [--no-ff | --ff-only] [--squash] [-q] <branch>` or
#   `git merge --abort`: it brings in commits that were scanned. A merge stopped by a conflict is
#   concluded with git commit -F (scanned), not git merge --continue.
# - git pull only with --ff-only (no merge commit).
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

if [[ "$HR_GIT_SUB" == merge ]]; then
  for a in ${HR_GIT_ARGS[@]+"${HR_GIT_ARGS[@]}"}; do
    case "$a" in
      --continue)
        hr_deny "conclude a merge with git commit -F <message file> (scanned), not git merge --continue"
        ;;
      --abort | --no-edit | --no-ff | --ff-only | --squash | -q | --quiet) ;;
      -*)
        hr_deny "merge only as: git merge [--no-edit] [--no-ff | --ff-only] [--squash] <branch>, or git merge --abort (not $a)"
        ;;
    esac
  done
  hr_allow
fi

if [[ "$HR_GIT_SUB" == pull ]]; then
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
if [[ ${#HR_GIT_ARGS[@]} -eq 2 && ("${HR_GIT_ARGS[0]}" == -F || "${HR_GIT_ARGS[0]}" == --file) ]]; then
  message="${HR_GIT_ARGS[1]}"
elif [[ ${#HR_GIT_ARGS[@]} -eq 1 && "${HR_GIT_ARGS[0]}" == --file=* ]]; then
  message="${HR_GIT_ARGS[0]#--file=}"
fi
[[ -n "$message" ]] ||
  hr_deny "commit only as: git commit -F <message file> (no -m, -a, --amend, --no-verify or other options)"
[[ -n "$HR_GIT_DIR" && -d "$HR_GIT_DIR" ]] ||
  hr_deny "can't tell which repository this commit is in, so it can't be scanned for secrets"
[[ "$message" == /* ]] || message="$HR_GIT_DIR/$message"
[[ -f "$message" && -r "$message" && ! -L "$message" ]] ||
  hr_deny "the message file must be a regular file you can read (not a link), so it can be scanned too: $message"
type -P gitleaks >/dev/null || hr_deny "gitleaks is not installed, so the commit can't be scanned for secrets"

# The staged files as raw blobs, read by their exact object ids, under their own paths. The whole
# index is listed (--no-relative), whatever folder the commit runs from.
mkdir "$HR_TMP/staged" "$HR_TMP/no-ignore"
git -C "$HR_GIT_DIR" diff --cached --raw -z --no-abbrev --no-renames --no-relative --diff-filter=ACMRT \
  >"$HR_TMP/staged.list"
while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
  read -r _ mode _ blob _ <<<"$meta"
  [[ "$mode" != 160000 ]] || hr_deny "a staged submodule ($path) can't be scanned for secrets"
  case "$path" in
    */*) mkdir -p "$HR_TMP/staged/${path%/*}" ;;
  esac
  git -C "$HR_GIT_DIR" cat-file blob "$blob" >"$HR_TMP/staged/$path"
done <"$HR_TMP/staged.list"

rules="$HR_ROOT/.harness/gitleaks.toml"
if ! gitleaks dir --config "$rules" --gitleaks-ignore-path "$HR_TMP/no-ignore" --ignore-gitleaks-allow \
  --no-banner --no-color --redact --exit-code 1 "$HR_TMP/staged" >"$HR_TMP/staged.out" 2>&1; then
  summary="$(tail -n 3 "$HR_TMP/staged.out")"
  hr_deny "gitleaks found a possible secret in the staged changes (or could not scan them): ${summary//$'\n'/ | }"
fi
if ! gitleaks dir --config "$rules" --gitleaks-ignore-path "$HR_TMP/no-ignore" --ignore-gitleaks-allow \
  --no-banner --no-color --redact --exit-code 1 "$message" >"$HR_TMP/message.out" 2>&1; then
  summary="$(tail -n 3 "$HR_TMP/message.out")"
  hr_deny "gitleaks found a possible secret in the commit message (or could not scan it): ${summary//$'\n'/ | }"
fi
hr_allow
