#!/bin/bash -p
# deny-push-to-protected (spec 5.3, FRG-3). A push is allowed only as
#   git push [-u | --set-upstream] origin feature/<KEY>-<n>-<slug>
# so nothing reaches main or dev (they change only through pull requests), nothing is forced or
# deleted, and nothing goes to another remote. git send-pack and git http-push are refused. Git
# configuration can redirect even that form (remote.origin.push maps a branch to another
# destination, remote.origin.mirror pushes everything, old-style .git/remotes or .git/branches
# files can map pushes), so the push is refused while any of those is set.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init deny-push-to-protected
hr_guarded || hr_allow
hr_require_simple
[[ "${HR_TOK[0]:-}" == git ]] || hr_allow
case "$HR_GIT_SUB" in
  push) ;;
  send-pack | http-push)
    hr_deny "git $HR_GIT_SUB pushes refs directly; push with: git push -u origin feature/<KEY>-<n>-<slug>"
    ;;
  *) hr_allow ;;
esac

remote=""
branch=""
for a in ${HR_GIT_ARGS[@]+"${HR_GIT_ARGS[@]}"}; do
  case "$a" in
    -u | --set-upstream) ;;
    -*)
      hr_deny "push option $a is not allowed (no force, delete, mirror, all, prune or tags); push with: git push -u origin feature/<KEY>-<n>-<slug>"
      ;;
    *)
      if [[ -z "$remote" ]]; then
        remote="$a"
      elif [[ -z "$branch" ]]; then
        branch="$a"
      else
        hr_deny "push one branch at a time: git push -u origin feature/<KEY>-<n>-<slug>"
      fi
      ;;
  esac
done
[[ -n "$branch" ]] || hr_deny "name the remote and the branch: git push -u origin feature/<KEY>-<n>-<slug>"
[[ "$remote" == origin ]] || hr_deny "push only to origin, not '$remote'"
# The only known ticket key is FRG until projects.json arrives (FRG-10).
ticket='^feature/FRG-[0-9]+-[a-z0-9]+(-[a-z0-9]+)*$'
[[ "$branch" =~ $ticket ]] ||
  hr_deny "push only a ticket branch (feature/<KEY>-<n>-<slug>), not '$branch'; main and dev change only through pull requests"

[[ -n "$HR_GIT_DIR" && -d "$HR_GIT_DIR" ]] ||
  hr_deny "can't tell which repository this push runs in, so can't check where git would send it"
git -C "$HR_GIT_DIR" config --get-regexp '^remote\.origin\.(push|mirror)$' >"$HR_TMP/pushcfg" 2>/dev/null || true
while read -r key value; do
  hr_deny "$key is set ($value), so git could push somewhere other than the named branch; remove it first"
done <"$HR_TMP/pushcfg"
git -C "$HR_GIT_DIR" rev-parse --path-format=absolute --git-common-dir >"$HR_TMP/common"
common="$(cat "$HR_TMP/common")"
find "$common/remotes" "$common/branches" -mindepth 1 -print -quit >"$HR_TMP/legacy" 2>/dev/null || true
[[ ! -s "$HR_TMP/legacy" ]] ||
  hr_deny "old-style remote definitions ($common/remotes or $common/branches) can redirect pushes; remove them first"
hr_allow
