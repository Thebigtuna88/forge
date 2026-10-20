#!/bin/bash
# FRG-26 stage 1: GitHub feasibility tests on a throwaway repository
# (docs/plans/2026-10-20-frg-26-permissions-isolation.md, sections 6 and 8).
#
# Run ONLY by the owner, from an owner handoff, in the owner's own Terminal. It acts as two people:
#   owner   the owner's own gh login: creates the repo, approves PRs, applies protection, resets
#   helper  the helper account's classic token: every bypass attempt
# It touches only github.com/Thebigtuna88/forge-frg26-throwaway and refuses any other repository.
#
#   github-throwaway.sh create            owner: create the throwaway repo (public; dev, main, side)
#   github-throwaway.sh invite            owner: invite the helper with write access
#   github-throwaway.sh accept            helper: try to accept the invitation with its token
#   github-throwaway.sh check-helper      helper login, token scopes = public_repo, permission = write
#   github-throwaway.sh reset             owner: dev, main, side back to the baseline (unprotected only)
#   github-throwaway.sh protect           owner: apply the dev and main branch protection
#   github-throwaway.sh ruleset           owner: add the main ruleset (only the owner may bypass)
#   github-throwaway.sh tests <phase>     run the bypass tests; phase = open | protected | ruleset
#   github-throwaway.sh actions-setting   B15: "Allow GitHub Actions to approve PRs" must be off
#   github-throwaway.sh status            print the repo's protection and rulesets (read-only)
#
# The helper's login and token come from FRG26_SECRETS (default below), a mode-600 file of
# HELPER_LOGIN=... and HELPER_TOKEN=... lines written by ho_secret_to_file. The token is never
# printed: every captured output is redacted before it is shown.
# Must run on macOS /bin/bash 3.2.
set -uo pipefail

readonly OWNER=Thebigtuna88
readonly REPO_NAME=forge-frg26-throwaway
readonly REPO="$OWNER/$REPO_NAME"
readonly MARKER="FRG-26 throwaway: permission tests. Safe to delete."
readonly BASELINE_TAG=frg26-baseline
SECRETS="${FRG26_SECRETS:-/Users/atl/code/forge/work/owner-secrets/frg26/helper.env}"

HELPER=""
TOKEN=""
WORK=""
CLONE=""
PHASE=""
FAILS=0
LAST_OUT=""
LAST_PR=""
OBS=""
BR=""

die() {
  printf 'github-throwaway: %s\n' "$*" >&2
  exit 2
}

redact() { # <text> — the helper's token never reaches the screen or a log
  local s="$1"
  if [[ -n "$TOKEN" ]]; then s="${s//"$TOKEN"/[REDACTED]}"; fi
  printf '%s' "$s"
}

say() { redact "$*"; printf '\n'; }

cleanup() {
  if [[ -n "$WORK" && -d "$WORK" ]]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT

# --- The two identities -------------------------------------------------------------------------

# The owner's own gh login, as stored by gh. No token variable may override it.
# shellcheck disable=SC2030,SC2031 # each identity's variables live only in its own subshell
owner_gh() {
  (
    unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST GH_REPO
    export GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1
    exec gh "$@"
  )
}

# The helper's token, for this one process only (an exported variable, never an argument, so it
# doesn't show in the process list).
# shellcheck disable=SC2030,SC2031 # as above
helper_gh() {
  (
    unset GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_REPO
    export GH_TOKEN="$TOKEN" GH_HOST=github.com GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1
    exec gh "$@"
  )
}

# git as the helper: no system or global git config (so no credential helper of the owner's can
# answer), credentials only from our askpass script, which reads them from the environment.
helper_git() {
  (
    unset GIT_DIR GIT_WORK_TREE GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_SSH_COMMAND \
      GIT_SSH SSH_ASKPASS GIT_PROXY_COMMAND
    export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
    export FRG26_ASK_USER="$HELPER" FRG26_ASK_PASS="$TOKEN" GIT_ASKPASS="$WORK/askpass"
    exec git -c credential.helper= -c core.askPass="$WORK/askpass" -c commit.gpgsign=false \
      -c user.name="frg26-helper-test" -c user.email="$HELPER@users.noreply.github.com" "$@"
  )
}

# Run a command, keep its redacted output in LAST_OUT, return its exit status.
capture() {
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  LAST_OUT="$(redact "$out")"
  return $rc
}

evidence() { # the last lines of LAST_OUT, on one line
  printf '%s' "$LAST_OUT" | tail -n 3 | tr '\n\t' '  ' | cut -c1-220
}

# --- Guards -------------------------------------------------------------------------------------

refuse_agent() {
  # Defence in depth: the agent must never run this (it would bypass the FORGE hooks, rule 9).
  if [[ -n "${CLAUDECODE:-}" || -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]]; then
    die "refusing: this runs only in the owner's own Terminal, from an owner handoff, never inside Claude Code"
  fi
}

need_tools() {
  local t
  for t in gh git jq shasum; do
    command -v "$t" >/dev/null 2>&1 || die "$t is required"
  done
  local v
  v="$(git --version | sed -E 's/^git version ([0-9]+)\.([0-9]+).*/\1 \2/')"
  # shellcheck disable=SC2086 # split "major minor" into $1 $2
  set -- $v
  if [[ ! "${1:-}" =~ ^[0-9]+$ || ! "${2:-}" =~ ^[0-9]+$ ]] || [[ $1 -lt 2 || ( $1 -eq 2 && $2 -lt 32 ) ]]; then
    die "git 2.32 or newer is required (GIT_CONFIG_GLOBAL)"
  fi
}

need_owner() {
  local who
  who="$(owner_gh api user --jq .login 2>/dev/null)" || die "gh is not signed in as the owner"
  [[ "$who" == "$OWNER" ]] || die "gh is signed in as '$who', not $OWNER"
}

load_helper() {
  [[ -f "$SECRETS" && ! -L "$SECRETS" ]] || die "missing secrets file $SECRETS"
  local mode
  mode="$(stat -f %Lp "$SECRETS" 2>/dev/null)" || die "can't read the mode of $SECRETS"
  [[ "$mode" == 600 ]] || die "$SECRETS must be mode 600 (it is $mode)"
  HELPER="$(sed -n 's/^HELPER_LOGIN=//p' "$SECRETS" | tail -n 1)"
  TOKEN="$(sed -n 's/^HELPER_TOKEN=//p' "$SECRETS" | tail -n 1)"
  [[ "$HELPER" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]] || die "HELPER_LOGIN is missing or not a GitHub user name"
  local lh lo
  lh="$(printf '%s' "$HELPER" | tr '[:upper:]' '[:lower:]')"
  lo="$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]')"
  [[ "$lh" != "$lo" ]] || die "HELPER_LOGIN must not be the owner"
  if [[ -n "$1" ]]; then
    [[ "$TOKEN" =~ ^ghp_[A-Za-z0-9]{30,250}$ ]] || die "HELPER_TOKEN is missing or not a classic token (ghp_...)"
  fi
}

need_helper_identity() {
  local who
  who="$(helper_gh api user --jq .login 2>/dev/null)" || die "the helper token was refused by GitHub"
  who="$(redact "$who")"
  [[ "$(printf '%s' "$who" | tr '[:upper:]' '[:lower:]')" == "$(printf '%s' "$HELPER" | tr '[:upper:]' '[:lower:]')" ]] \
    || die "the token belongs to '$who', not $HELPER"
}

# Every write is made only after this: the repo must be the throwaway one we created.
assert_throwaway() {
  local info
  info="$(owner_gh api "repos/$REPO" --jq '[.full_name, .owner.login, .description, (.private|tostring)] | @tsv' 2>/dev/null)" \
    || die "can't read $REPO"
  [[ "$info" == "$REPO"$'\t'"$OWNER"$'\t'"$MARKER"$'\t'false ]] \
    || die "$REPO is not the public throwaway repo this script created (description must be: $MARKER)"
}

make_work() {
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/frg26.XXXXXX")" || die "mktemp failed"
  chmod 700 "$WORK" || die "chmod failed"
  cat >"$WORK/askpass" <<'EOF'
#!/bin/bash
case "${1:-}" in
  Username*) printf '%s\n' "$FRG26_ASK_USER" ;;
  *) printf '%s\n' "$FRG26_ASK_PASS" ;;
esac
EOF
  chmod 700 "$WORK/askpass" || die "chmod failed"
}

protected_state() { # prints "<dev protected> <main protected> <ruleset count>"
  local d m r
  d="$(owner_gh api "repos/$REPO/branches/dev" --jq .protected 2>/dev/null)" || d=error
  m="$(owner_gh api "repos/$REPO/branches/main" --jq .protected 2>/dev/null)" || m=error
  r="$(owner_gh api "repos/$REPO/rulesets" --jq length 2>/dev/null)" || r=error
  printf '%s %s %s' "$d" "$m" "$r"
}

# --- Owner commands -----------------------------------------------------------------------------

cmd_create() {
  need_owner
  if owner_gh api "repos/$REPO" >/dev/null 2>&1; then
    die "$REPO already exists; delete it in the browser first if you want a fresh one"
  fi
  make_work
  local id email sha
  id="$(owner_gh api user --jq .id)" || die "can't read the owner's user id"
  [[ "$id" =~ ^[0-9]+$ ]] || die "unexpected user id"
  email="$id+$OWNER@users.noreply.github.com"
  owner_gh repo create "$REPO" --public --description "$MARKER" || die "gh repo create failed"
  local c="$WORK/seed"
  git init -q -b main "$c" || die "git init failed"
  mkdir -p "$c/.github" "$c/docs" "$c/tests"
  printf '# %s\n\n%s\n' "$REPO_NAME" "$MARKER" >"$c/README.md"
  printf '* @%s\n' "$OWNER" >"$c/.github/CODEOWNERS"
  printf 'Docs folder (CODEOWNERS may also live here; test B4).\n' >"$c/docs/README.md"
  printf 'Test files land here.\n' >"$c/tests/README.md"
  git -C "$c" add -A || die "git add failed"
  git -C "$c" -c user.name="$OWNER" -c user.email="$email" -c commit.gpgsign=false \
    commit -q -m "FRG-26 throwaway baseline" || die "git commit failed"
  sha="$(git -C "$c" rev-parse HEAD)" || die "rev-parse failed"
  git -C "$c" push -q "https://github.com/$REPO.git" main:refs/heads/main || die "initial push failed"
  assert_throwaway
  owner_gh api -X POST "repos/$REPO/git/refs" -f ref=refs/heads/dev -f sha="$sha" >/dev/null || die "creating dev failed"
  owner_gh api -X POST "repos/$REPO/git/refs" -f ref=refs/heads/side -f sha="$sha" >/dev/null || die "creating side failed"
  owner_gh api -X POST "repos/$REPO/git/refs" -f ref="refs/tags/$BASELINE_TAG" -f sha="$sha" >/dev/null || die "creating the baseline tag failed"
  owner_gh api -X PATCH "repos/$REPO" -f default_branch=dev -F allow_auto_merge=false \
    -F allow_merge_commit=true -F allow_squash_merge=true >/dev/null || die "setting the default branch failed"
  say "created $REPO (public), baseline $sha, branches main dev side, default dev"
}

cmd_invite() {
  need_owner
  load_helper ""
  assert_throwaway
  owner_gh api -X PUT "repos/$REPO/collaborators/$HELPER" -f permission=push >/dev/null \
    || die "inviting $HELPER failed"
  say "invited $HELPER to $REPO with write access"
}

# Records whether a public_repo token can accept a repository invitation (plan item 7). Exit 0 if
# it could, 3 if GitHub refused (then the owner accepts it in the helper's browser window).
cmd_accept() {
  need_owner
  load_helper token
  need_helper_identity
  assert_throwaway
  local id
  id="$(helper_gh api user/repository_invitations --jq ".[] | select(.repository.full_name == \"$REPO\") | .id" 2>&1)"
  id="$(redact "$id")"
  if [[ ! "$id" =~ ^[0-9]+$ ]]; then
    say "ACCEPT-WITH-PUBLIC_REPO: could not list invitations with the token ($id)"
    exit 3
  fi
  if capture helper_gh api -X PATCH "user/repository_invitations/$id"; then
    say "ACCEPT-WITH-PUBLIC_REPO: allowed (a public_repo token can accept invitations)"
    exit 0
  fi
  say "ACCEPT-WITH-PUBLIC_REPO: refused ($(evidence))"
  exit 3
}

cmd_check_helper() {
  need_owner
  load_helper token
  need_helper_identity
  assert_throwaway
  local hdr scopes perm role
  capture helper_gh api -i user || die "the helper token was refused: $(evidence)"
  hdr="$(printf '%s\n' "$LAST_OUT" | tr -d '\r' | grep -i '^x-oauth-scopes:' | head -n 1)"
  scopes="$(printf '%s' "${hdr#*:}" | tr -d ' ')"
  perm="$(owner_gh api "repos/$REPO/collaborators/$HELPER/permission" --jq .permission 2>/dev/null)" || perm=error
  role="$(owner_gh api "repos/$REPO/collaborators/$HELPER/permission" --jq .role_name 2>/dev/null)" || role=error
  say "helper=$HELPER token=classic scopes=${scopes:-none} permission=$perm role=$role"
  [[ "$scopes" == public_repo ]] || die "token scopes must be exactly public_repo (they are '${scopes:-none}')"
  [[ "$perm" == write && "$role" == write ]] || die "the helper must have write (not admin, maintain or read) on $REPO"
}

cmd_reset() {
  need_owner
  assert_throwaway
  local st
  st="$(protected_state)"
  [[ "$st" == "false false 0" ]] || die "reset only runs while nothing is protected (state: $st)"
  local base n
  base="$(owner_gh api "repos/$REPO/git/ref/tags/$BASELINE_TAG" --jq .object.sha)" || die "the baseline tag is missing"
  [[ "$base" =~ ^[0-9a-f]{40}$ ]] || die "unexpected baseline sha"
  local open_prs
  open_prs="$(owner_gh api "repos/$REPO/pulls?state=open&per_page=100" --jq '.[].number')" || die "can't list open PRs"
  for n in $open_prs; do
    [[ "$n" =~ ^[0-9]+$ ]] || die "unexpected PR number '$n'"
    owner_gh pr close "$n" --repo "$REPO" >/dev/null 2>&1 || die "closing PR #$n failed"
  done
  local b
  for b in main dev side; do
    if owner_gh api "repos/$REPO/git/ref/heads/$b" >/dev/null 2>&1; then
      owner_gh api -X PATCH "repos/$REPO/git/refs/heads/$b" -f sha="$base" -F force=true >/dev/null \
        || die "resetting $b failed"
    else
      owner_gh api -X POST "repos/$REPO/git/refs" -f ref="refs/heads/$b" -f sha="$base" >/dev/null \
        || die "recreating $b failed"
    fi
  done
  owner_gh api -X PATCH "repos/$REPO" -f default_branch=dev >/dev/null || die "setting the default branch failed"
  say "reset main dev side to the baseline $base"
}

protection_json() { # <enforce_admins true|false>
  cat <<EOF
{
  "required_status_checks": null,
  "enforce_admins": $1,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true,
    "required_approving_review_count": 1,
    "require_last_push_approval": true
  },
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": false,
  "lock_branch": false,
  "allow_fork_syncing": false
}
EOF
}

cmd_protect() {
  need_owner
  assert_throwaway
  make_work
  # dev: nobody merges without the owner's code-owner approval, admins included (D5).
  protection_json true >"$WORK/dev.json"
  # main: the same review rule; admins (only the owner) may bypass it, so the owner can merge
  # dev into main (M6). Who may update main at all is the ruleset's job (D6).
  protection_json false >"$WORK/main.json"
  owner_gh api -X PUT "repos/$REPO/branches/dev/protection" --input "$WORK/dev.json" >/dev/null || die "protecting dev failed"
  owner_gh api -X PUT "repos/$REPO/branches/main/protection" --input "$WORK/main.json" >/dev/null || die "protecting main failed"
  local b got
  for b in dev main; do
    got="$(owner_gh api "repos/$REPO/branches/$b/protection" --jq '[.required_pull_request_reviews.required_approving_review_count, .required_pull_request_reviews.require_code_owner_reviews, .required_pull_request_reviews.require_last_push_approval, .required_pull_request_reviews.dismiss_stale_reviews, .enforce_admins.enabled, .allow_force_pushes.enabled, .allow_deletions.enabled] | @tsv')" \
      || die "reading $b protection back failed"
    say "$b protection: approvals codeowners last-push stale-dismiss enforce-admins force-push deletions = $(printf '%s' "$got" | tr '\t' ' ')"
  done
}

ruleset_json() { # <actor_type> <actor_id>
  cat <<EOF
{
  "name": "main: only the owner",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/heads/main"], "exclude": [] } },
  "bypass_actors": [ { "actor_id": $2, "actor_type": "$1", "bypass_mode": "always" } ],
  "rules": [
    { "type": "update", "parameters": { "update_allows_fetch_and_merge": false } },
    { "type": "deletion" },
    { "type": "non_fast_forward" }
  ]
}
EOF
}

# The bypass list must hold only the owner. First choice: the owner as a User. If GitHub refuses
# that for a personal repo, the Repository admin role (role id 5), which on a personal repo is
# only the owner. Which one GitHub accepted is printed; M2 and M6 prove whether it works.
cmd_ruleset() {
  need_owner
  assert_throwaway
  make_work
  local n uid
  n="$(owner_gh api "repos/$REPO/rulesets" --jq length)" || die "can't list rulesets"
  [[ "$n" == 0 ]] || die "a ruleset already exists on $REPO"
  uid="$(owner_gh api user --jq .id)" || die "can't read the owner's user id"
  [[ "$uid" =~ ^[0-9]+$ ]] || die "unexpected user id"
  ruleset_json User "$uid" >"$WORK/ruleset-user.json"
  ruleset_json RepositoryRole 5 >"$WORK/ruleset-admin.json"
  if capture owner_gh api -X POST "repos/$REPO/rulesets" --input "$WORK/ruleset-user.json"; then
    say "ruleset created with bypass: the owner (User $uid)"
  else
    say "GitHub refused a User bypass: $(evidence)"
    capture owner_gh api -X POST "repos/$REPO/rulesets" --input "$WORK/ruleset-admin.json" \
      || die "GitHub refused the Repository admin bypass too: $(evidence)"
    say "ruleset created with bypass: Repository admin role (5)"
  fi
  say "rulesets now: $(owner_gh api "repos/$REPO/rulesets" --jq '[.[] | .name] | @csv')"
  local id
  id="$(owner_gh api "repos/$REPO/rulesets" --jq '.[0].id')" || die "can't read the ruleset id"
  say "bypass actors: $(owner_gh api "repos/$REPO/rulesets/$id" --jq '[.bypass_actors[] | "\(.actor_type):\(.actor_id):\(.bypass_mode)"] | @csv')"
}

cmd_actions_setting() {
  need_owner
  assert_throwaway
  local v
  v="$(owner_gh api "repos/$REPO/actions/permissions/workflow" --jq .can_approve_pull_request_reviews)" \
    || die "can't read the Actions workflow permissions"
  say "B15 can_approve_pull_request_reviews=$v (must be false)"
  [[ "$v" == false ]]
}

cmd_status() {
  need_owner
  assert_throwaway
  say "state (dev-protected main-protected rulesets): $(protected_state)"
  say "default branch: $(owner_gh api "repos/$REPO" --jq .default_branch)"
}

# --- Bypass tests -------------------------------------------------------------------------------

# Expected result of each test in each phase (plan section 6): allowed | refused | any.
expect() { # <id> <phase>
  case "$1:$2" in
    B5:*|B12:*|B13:*|M4:*) echo refused ;;
    B16:*|M6:*) echo allowed ;;
    B11:open) echo any ;;
    M2:open|M2:protected) echo allowed ;;
    *:open) echo allowed ;;
    *) echo refused ;;
  esac
}

record() { # <id> <observed allowed|refused> <evidence>
  local want verdict
  want="$(expect "$1" "$PHASE")"
  if [[ "$want" == any || "$want" == "$2" ]]; then verdict=PASS; else
    verdict=FAIL
    FAILS=$((FAILS + 1))
  fi
  say "RESULT $1 $PHASE $verdict expected=$want observed=$2 :: $3"
}

# A test whose own setup failed proves nothing either way: always a FAIL, never a refusal.
setup_fail() { # <id> <what failed>
  FAILS=$((FAILS + 1))
  say "RESULT $1 $PHASE FAIL expected=$(expect "$1" "$PHASE") observed=setup-failed :: $2"
}

stamp() { date -u +%H%M%S; }

fresh_dev() { # <branch> — a local branch at the current origin/dev
  helper_git -C "$CLONE" fetch -q origin || die "fetch failed"
  helper_git -C "$CLONE" checkout -q -B "$1" origin/dev || die "checkout failed"
}

add_commit() { # <path> <content>
  mkdir -p "$CLONE/$(dirname "$1")"
  printf '%s\n' "$2" >"$CLONE/$1"
  helper_git -C "$CLONE" add -- "$1" || die "git add failed"
  helper_git -C "$CLONE" commit -q -m "FRG-26 test: $1" || die "git commit failed"
}

push_branch() { # <branch> — push HEAD as a new feature branch (always allowed)
  helper_git -C "$CLONE" push -q origin "HEAD:refs/heads/$1" >/dev/null 2>&1 || die "pushing $1 failed"
}

helper_pr() { # <base> <head> <id> — sets LAST_PR
  local url
  url="$(helper_gh pr create --repo "$REPO" --base "$1" --head "$2" --title "FRG-26 $3 ($PHASE)" \
    --body "FRG-26 throwaway test $3, phase $PHASE." 2>&1)" || die "creating a PR for $3 failed: $(redact "$url")"
  LAST_PR="${url##*/}"
  [[ "$LAST_PR" =~ ^[0-9]+$ ]] || die "unexpected PR URL: $(redact "$url")"
}

feature_pr() { # <id> [base] — a fresh feature branch with one new file, and a PR from the helper
  local br
  br="frg26/$PHASE/$1-$(stamp)"
  fresh_dev "$br"
  add_commit "tests/$PHASE-$1-$(stamp).txt" "FRG-26 $1 $PHASE"
  push_branch "$br"
  helper_pr "${2:-dev}" "$br" "$1"
  BR="$br"
}

wait_settled() { # <pr> — GitHub computes mergeability in the background
  local _ st
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    st="$(owner_gh pr view "$1" --repo "$REPO" --json mergeable --jq .mergeable 2>/dev/null)" || st=UNKNOWN
    [[ "$st" != UNKNOWN ]] && return 0
    sleep 2
  done
  return 0
}

pr_state() { owner_gh pr view "$1" --repo "$REPO" --json state --jq .state 2>/dev/null || echo UNKNOWN; }

merge_info() { # <pr> — evidence GitHub gives about why a PR can or can't merge
  owner_gh pr view "$1" --repo "$REPO" --json mergeStateStatus,reviewDecision,reviewRequests \
    --jq '"mergeState=\(.mergeStateStatus) reviewDecision=\(.reviewDecision) requested=\([.reviewRequests[].login] | join(","))"' 2>/dev/null || echo "merge info unavailable"
}

# The helper tries to merge. Observed = allowed only if GitHub then reports the PR MERGED. When
# the test expects "allowed", transient refusals are retried, so a refusal is never reported for
# a merge GitHub would have allowed; a retry can't turn a refusal into a PASS.
helper_merge() { # <id> <pr> <merge flags…>
  local id="$1" pr="$2" _
  shift 2
  for _ in 1 2 3; do
    wait_settled "$pr"
    capture helper_gh pr merge "$pr" --repo "$REPO" "$@" || true
    sleep 2
    if [[ "$(pr_state "$pr")" == MERGED ]]; then OBS=allowed; return 0; fi
    [[ "$(expect "$id" "$PHASE")" == allowed ]] || break
    sleep 5
  done
  OBS=refused
  LAST_OUT="$LAST_OUT [$(merge_info "$pr")]"
}

owner_approve() { # <pr>
  wait_settled "$1"
  owner_gh pr review "$1" --repo "$REPO" --approve --body "FRG-26 test approval by the owner" >/dev/null 2>&1 \
    || die "the owner could not approve PR #$1"
  sleep 3
}

close_if_open() { # <pr> — tidy up after a refused attempt
  if [[ "$(pr_state "$1")" == OPEN ]]; then owner_gh pr close "$1" --repo "$REPO" >/dev/null 2>&1 || true; fi
}

dev_ahead() { # helper PR into dev, owner approves, helper merges (the B16 control)
  feature_pr "$1"
  owner_approve "$LAST_PR"
  helper_merge B16 "$LAST_PR" --squash
}

t_B1() {
  fresh_dev "b1-$(stamp)"
  add_commit "tests/$PHASE-B1-$(stamp).txt" "direct push to dev"
  if capture helper_git -C "$CLONE" push origin HEAD:refs/heads/dev; then OBS=allowed; else OBS=refused; fi
  record B1 "$OBS" "$(evidence)"
}

t_B2() {
  fresh_dev "b2-$(stamp)"
  printf '* @%s\n' "$HELPER" >"$CLONE/.github/CODEOWNERS"
  helper_git -C "$CLONE" commit -q -am "FRG-26 test: helper names itself code owner" || die "commit failed"
  if capture helper_git -C "$CLONE" push origin HEAD:refs/heads/dev; then OBS=allowed; else OBS=refused; fi
  record B2 "$OBS" "$(evidence)"
}

t_B3() {
  local br
  br="frg26/$PHASE/B3-$(stamp)"
  fresh_dev "$br"
  printf '* @%s\n' "$HELPER" >"$CLONE/.github/CODEOWNERS"
  helper_git -C "$CLONE" commit -q -am "FRG-26 test: PR naming the helper code owner" || die "commit failed"
  push_branch "$br"
  helper_pr dev "$br" B3
  local pr="$LAST_PR"
  helper_merge B3 "$pr" --squash
  record B3 "$OBS" "$(evidence)"
  close_if_open "$pr"
}

t_B4() {
  local br
  br="frg26/$PHASE/B4-$(stamp)"
  fresh_dev "$br"
  helper_git -C "$CLONE" rm -q .github/CODEOWNERS || die "git rm failed"
  printf '* @%s\n' "$HELPER" >"$CLONE/CODEOWNERS"
  printf '* @%s\n' "$HELPER" >"$CLONE/docs/CODEOWNERS"
  helper_git -C "$CLONE" add CODEOWNERS docs/CODEOWNERS || die "git add failed"
  helper_git -C "$CLONE" commit -q -m "FRG-26 test: CODEOWNERS moved to root and docs/" || die "commit failed"
  push_branch "$br"
  helper_pr dev "$br" B4
  local pr="$LAST_PR"
  helper_merge B4 "$pr" --squash
  record B4 "$OBS" "$(evidence)"
  close_if_open "$pr"
}

t_B5() {
  feature_pr B5
  local pr="$LAST_PR"
  wait_settled "$pr"
  if capture helper_gh pr review "$pr" --repo "$REPO" --approve --body "self-approval attempt"; then OBS=allowed; else OBS=refused; fi
  record B5 "$OBS" "$(evidence)"
  close_if_open "$pr"
}

t_B6() {
  feature_pr B6
  local pr="$LAST_PR"
  helper_merge B6 "$pr" --squash
  record B6 "$OBS" "$(evidence)"
  close_if_open "$pr"
}

t_B7() {
  feature_pr B7
  local pr="$LAST_PR"
  owner_approve "$pr"
  helper_git -C "$CLONE" checkout -q "$BR" || die "checkout failed"
  add_commit "tests/$PHASE-B7-after-approval-$(stamp).txt" "pushed after the owner's approval"
  helper_git -C "$CLONE" push -q origin "HEAD:refs/heads/$BR" >/dev/null 2>&1 || die "pushing after approval failed"
  sleep 3
  helper_merge B7 "$pr" --squash
  record B7 "$OBS" "$(evidence)"
  close_if_open "$pr"
}

t_B8() {
  feature_pr B8
  local pr="$LAST_PR"
  owner_approve "$pr"
  dev_ahead B8-advance
  [[ "$OBS" == allowed ]] || { setup_fail B8 "could not advance dev ($(evidence))"; close_if_open "$pr"; return; }
  if ! capture helper_gh api -X PUT "repos/$REPO/pulls/$pr/update-branch"; then
    setup_fail B8 "update-branch refused ($(evidence))"
    close_if_open "$pr"
    return
  fi
  sleep 5
  helper_merge B8 "$pr" --squash
  record B8 "$OBS" "$(evidence)"
  close_if_open "$pr"
}

t_B9() {
  feature_pr B9 side
  local pr="$LAST_PR"
  owner_approve "$pr"
  if ! capture helper_gh pr edit "$pr" --repo "$REPO" --base dev; then
    record B9 refused "re-aiming at dev was refused ($(evidence))"
    close_if_open "$pr"
    return
  fi
  sleep 3
  helper_merge B9 "$pr" --squash
  record B9 "$OBS" "$(evidence)"
  close_if_open "$pr"
}

t_B10() {
  feature_pr B10
  local pr="$LAST_PR"
  helper_merge B10 "$pr" --squash --admin
  record B10 "$OBS" "$(evidence)"
  close_if_open "$pr"
}

t_B11() {
  feature_pr B11
  local pr="$LAST_PR"
  wait_settled "$pr"
  capture helper_gh pr merge "$pr" --repo "$REPO" --squash --auto || true
  local first
  first="$(evidence)"
  sleep 30
  if [[ "$(pr_state "$pr")" == MERGED ]]; then OBS=allowed; else OBS=refused; fi
  record B11 "$OBS" "$first [$(merge_info "$pr")]"
  close_if_open "$pr"
}

t_B12() {
  printf '{"required_status_checks":null,"enforce_admins":false,"required_pull_request_reviews":null,"restrictions":null}\n' >"$WORK/weak.json"
  OBS=refused
  local ev=""
  if capture helper_gh api -X PUT "repos/$REPO/branches/dev/protection" --input "$WORK/weak.json"; then OBS=allowed; fi
  ev="PUT: $(evidence)"
  if capture helper_gh api -X DELETE "repos/$REPO/branches/dev/protection"; then OBS=allowed; fi
  record B12 "$OBS" "$ev | DELETE: $(evidence)"
}

t_B13() {
  ruleset_json User 1 >"$WORK/helper-ruleset.json"
  OBS=refused
  local ev=""
  if capture helper_gh api -X POST "repos/$REPO/rulesets" --input "$WORK/helper-ruleset.json"; then OBS=allowed; fi
  ev="ruleset: $(evidence)"
  if capture helper_gh api -X PATCH "repos/$REPO" -f description="changed by the helper"; then OBS=allowed; fi
  record B13 "$OBS" "$ev | settings: $(evidence)"
  if [[ "$OBS" == allowed ]]; then
    # Put the marker back so later commands still recognise the throwaway repo.
    owner_gh api -X PATCH "repos/$REPO" -f description="$MARKER" >/dev/null 2>&1 || true
  fi
}

t_B14() { # destructive when it succeeds (open phase): runs last, before a reset
  OBS=refused
  helper_git -C "$CLONE" checkout -q --orphan "b14-$(stamp)" || die "checkout failed"
  helper_git -C "$CLONE" rm -rq --cached . >/dev/null 2>&1 || true
  add_commit "tests/orphan-$(stamp).txt" "unrelated history"
  local ev=""
  if capture helper_git -C "$CLONE" push --force origin HEAD:refs/heads/dev; then OBS=allowed; fi
  ev="force-push: $(evidence)"
  if capture helper_git -C "$CLONE" push origin :refs/heads/dev; then OBS=allowed; fi
  record B14 "$OBS" "$ev | delete: $(evidence)"
}

t_B16() {
  dev_ahead B16
  record B16 "$OBS" "$(evidence)"
}

t_M1() {
  helper_git -C "$CLONE" fetch -q origin || die "fetch failed"
  helper_git -C "$CLONE" checkout -q -B "m1-$(stamp)" origin/main || die "checkout failed"
  add_commit "tests/$PHASE-M1-$(stamp).txt" "direct push to main"
  if capture helper_git -C "$CLONE" push origin HEAD:refs/heads/main; then OBS=allowed; else OBS=refused; fi
  record M1 "$OBS" "$(evidence)"
}

t_M2() {
  dev_ahead M2-advance
  [[ "$OBS" == allowed ]] || { setup_fail M2 "could not advance dev ($(evidence))"; return; }
  helper_pr main dev M2
  local pr="$LAST_PR"
  owner_approve "$pr"
  helper_merge M2 "$pr" --merge
  record M2 "$OBS" "$(evidence)"
  close_if_open "$pr"
}

t_M3() {
  dev_ahead M3-advance
  [[ "$OBS" == allowed ]] || { setup_fail M3 "could not advance dev ($(evidence))"; return; }
  helper_pr main dev M3
  local pr="$LAST_PR"
  helper_merge M3 "$pr" --merge --admin
  record M3 "$OBS" "$(evidence)"
  close_if_open "$pr"
}

t_M4() {
  printf '{"required_status_checks":null,"enforce_admins":false,"required_pull_request_reviews":null,"restrictions":null}\n' >"$WORK/weak.json"
  OBS=refused
  local ev="" id
  if capture helper_gh api -X PUT "repos/$REPO/branches/main/protection" --input "$WORK/weak.json"; then OBS=allowed; fi
  ev="PUT main protection: $(evidence)"
  if capture helper_gh api -X DELETE "repos/$REPO/branches/main/protection"; then OBS=allowed; fi
  ev="$ev | DELETE main protection: $(evidence)"
  id="$(owner_gh api "repos/$REPO/rulesets" --jq '.[0].id // empty' 2>/dev/null)" || id=""
  if [[ "$id" =~ ^[0-9]+$ ]]; then
    if capture helper_gh api -X DELETE "repos/$REPO/rulesets/$id"; then OBS=allowed; fi
    ev="$ev | DELETE ruleset: $(evidence)"
  fi
  record M4 "$OBS" "$ev"
}

t_M5() { # destructive when it succeeds (open phase): runs last, before a reset
  OBS=refused
  helper_git -C "$CLONE" checkout -q --orphan "m5-$(stamp)" || die "checkout failed"
  helper_git -C "$CLONE" rm -rq --cached . >/dev/null 2>&1 || true
  add_commit "tests/orphan-main-$(stamp).txt" "unrelated history"
  local ev=""
  if capture helper_git -C "$CLONE" push --force origin HEAD:refs/heads/main; then OBS=allowed; fi
  ev="force-push: $(evidence)"
  if capture helper_git -C "$CLONE" push origin :refs/heads/main; then OBS=allowed; fi
  record M5 "$OBS" "$ev | delete: $(evidence)"
}

t_M6() { # the owner merges dev into main
  dev_ahead M6-advance
  [[ "$OBS" == allowed ]] || { setup_fail M6 "could not advance dev ($(evidence))"; return; }
  local url pr
  if ! url="$(owner_gh pr create --repo "$REPO" --base main --head dev --title "FRG-26 M6 ($PHASE)" \
    --body "FRG-26 throwaway test M6: the owner merges dev into main." 2>&1)"; then
    setup_fail M6 "the owner could not open the PR: $(redact "$url")"
    return
  fi
  pr="${url##*/}"
  [[ "$pr" =~ ^[0-9]+$ ]] || { setup_fail M6 "unexpected PR URL: $(redact "$url")"; return; }
  wait_settled "$pr"
  capture owner_gh pr merge "$pr" --repo "$REPO" --merge --admin || true
  sleep 2
  if [[ "$(pr_state "$pr")" == MERGED ]]; then OBS=allowed; else OBS=refused; fi
  record M6 "$OBS" "$(evidence)"
  close_if_open "$pr"
}

cmd_tests() {
  PHASE="${1:-}"
  case "$PHASE" in open | protected | ruleset) ;; *) die "usage: tests open|protected|ruleset" ;; esac
  need_owner
  load_helper token
  need_helper_identity
  assert_throwaway
  local st want
  st="$(protected_state)"
  case "$PHASE" in
    open) want="false false 0" ;;
    protected) want="true true 0" ;;
    ruleset) want="true true 1" ;;
  esac
  [[ "$st" == "$want" ]] || die "phase $PHASE needs state '$want' (dev-protected main-protected rulesets), found '$st'"
  make_work
  CLONE="$WORK/clone"
  helper_git clone -q "https://github.com/$REPO.git" "$CLONE" || die "clone failed"
  say "== FRG-26 bypass tests, phase $PHASE, helper $HELPER, $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
  t_B5; t_B1; t_B2; t_B3; t_B4; t_B6; t_B7; t_B8; t_B9; t_B10; t_B11; t_B12; t_B13; t_B16
  t_M1; t_M2; t_M3; t_M4; t_M6
  t_B14; t_M5
  if [[ $FAILS -eq 0 ]]; then
    say "PHASE $PHASE: ALL PASS"
    exit 0
  fi
  say "PHASE $PHASE: $FAILS FAILED"
  exit 1
}

main() {
  refuse_agent
  need_tools
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    create) cmd_create ;;
    invite) cmd_invite ;;
    accept) cmd_accept ;;
    check-helper) cmd_check_helper ;;
    reset) cmd_reset ;;
    protect) cmd_protect ;;
    ruleset) cmd_ruleset ;;
    tests) cmd_tests "$@" ;;
    actions-setting) cmd_actions_setting ;;
    status) cmd_status ;;
    *) die "usage: github-throwaway.sh create|invite|accept|check-helper|reset|protect|ruleset|tests <phase>|actions-setting|status" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
