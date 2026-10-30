#!/bin/bash
# FRG-26 stage 1: GitHub feasibility tests on a throwaway repository
# (docs/plans/2026-10-20-frg-26-permissions-isolation.md, sections 6 and 8).
#
# Run ONLY by the owner, from an owner handoff, in the owner's own Terminal. It acts as two people:
#   owner   the owner's own gh login: creates the repo, approves PRs, applies protection, resets
#   helper  the helper account's classic token: every bypass attempt
# It touches only github.com/Thebigtuna88/forge-frg26-throwaway and refuses any other repository.
#
#   github-throwaway.sh create            owner: create the throwaway repo (public; main dev side)
#   github-throwaway.sh invite            owner: invite the helper with write access
#   github-throwaway.sh accept            helper: try to accept the invitation with its token
#   github-throwaway.sh check-helper      helper login, token scopes = public_repo, permission = write
#   github-throwaway.sh rate              the helper's API allowance: limit, used, reset (read-only)
#   github-throwaway.sh diagnose          as the helper: GET /user, GET /rate_limit, one GraphQL
#                                         query; statuses, rate-limit headers, messages (read-only)
#   github-throwaway.sh reset             owner: main dev side back to the baseline (unprotected only)
#   github-throwaway.sh protect           owner: apply the dev and main branch protection
#   github-throwaway.sh ruleset           owner: add the main ruleset (only the owner may bypass)
#   github-throwaway.sh tests <phase>     run the bypass tests; phase = open | protected | ruleset
#   github-throwaway.sh actions-setting   B15: "Allow GitHub Actions to approve PRs" must be off
#   github-throwaway.sh status            print the repo's protection and rulesets (read-only)
#
# The owner's handoffs don't run this file: each step reads it from the reviewed git commit into
# memory, checks its sha256 and runs that copy with `bash -p -c` in an empty environment.
# The helper's login and token come from FRG26_SECRETS (default below), a mode-600 file of
# HELPER_LOGIN=... and HELPER_TOKEN=... lines written by ho_secret_to_file. The token is never
# printed and never put in a command's arguments.
# Must run on macOS /bin/bash 3.2.
set -uo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
export PATH

readonly OWNER=Thebigtuna88
readonly REPO_NAME=forge-frg26-throwaway
readonly REPO="$OWNER/$REPO_NAME"
readonly MARKER="FRG-26 throwaway: permission tests. Safe to delete."
readonly BASELINE_TAG=frg26-baseline
# The default branch is side, not dev as in FORGE, so that deleting dev can be tested (GitHub
# never deletes a default branch, protected or not).
readonly DEFAULT_BRANCH=side
# GraphQL points the helper must have left before a phase starts (each gh pr command uses some).
readonly MIN_GRAPHQL=300
SECRETS="${FRG26_SECRETS:-/Users/atl/code/forge/work/owner-secrets/frg26/helper.env}"

HELPER=""
TOKEN=""
WORK=""
CLONE=""
PHASE=""
FAILS=0
LAST_OUT=""
LAST_RC=0
LAST_PR=""
OBS=""
BR=""

die() {
  printf 'github-throwaway: %s\n' "$(redact "$*")" >&2
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
    unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST GH_REPO GH_CONFIG_DIR
    export GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1
    exec gh "$@"
  )
}

# The helper's token, for this one process only: an exported variable, never an argument (so it
# isn't in the process list), and an empty gh config folder (none of the owner's settings).
# shellcheck disable=SC2030,SC2031 # as above
helper_gh() {
  (
    unset GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_REPO
    export GH_TOKEN="$TOKEN" GH_HOST=github.com GH_CONFIG_DIR="$WORK/gh-helper" \
      GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1
    exec gh "$@"
  )
}

# git as the helper: no GIT_* variable, no system or global config (so no credential helper or
# URL rewrite of the owner's applies), no hooks, credentials only from our askpass script.
helper_git() {
  (
    local v
    for v in $(compgen -e); do
      case "$v" in GIT_* | SSH_ASKPASS) unset "$v" ;; esac
    done
    export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 HOME="$WORK/home"
    export FRG26_ASK_USER="$HELPER" FRG26_ASK_PASS="$TOKEN" GIT_ASKPASS="$WORK/askpass"
    exec git -c credential.helper= -c core.askPass="$WORK/askpass" -c core.hooksPath=/dev/null \
      -c commit.gpgsign=false -c protocol.allow=never -c protocol.https.allow=always \
      -c user.name="frg26-helper-test" -c user.email="$HELPER@users.noreply.github.com" "$@"
  )
}

# Run a command; keep its redacted output in LAST_OUT and its status in LAST_RC.
capture() {
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  LAST_OUT="$(redact "$out")"
  LAST_RC=$rc
  return $rc
}

evidence() { # the last lines of LAST_OUT, on one line
  printf '%s' "$LAST_OUT" | tail -n 3 | tr '\n\t' '  ' | cut -c1-240
}

# --- How an attempt is judged ---------------------------------------------------------------
# A refusal counts only when GitHub says why in its own words. Anything else (a network error, a
# validation error, a conflict, a state we couldn't read) is "inconclusive", which is always a
# FAIL: it proves nothing either way.

classify_push() { # after capture of a helper git push
  if [[ $LAST_RC -eq 0 ]]; then echo allowed; return; fi
  if printf '%s' "$LAST_OUT" | grep -Eiq 'GH006|GH013|protected branch|rule violation|Cannot force-push|cannot delete|Changes must be made through a pull request'; then
    echo refused
  else
    echo inconclusive
  fi
}

classify_api() { # after capture of a helper gh api call to an admin endpoint
  if [[ $LAST_RC -eq 0 ]]; then echo allowed; return; fi
  # GitHub also answers 403 when a client sends too many requests: that proves nothing.
  if printf '%s' "$LAST_OUT" | grep -Eiq 'rate limit|abuse detection|secondary rate'; then
    echo inconclusive
    return
  fi
  if printf '%s' "$LAST_OUT" | grep -Eq 'HTTP 403|HTTP 404|Must have admin rights|Resource not accessible by personal access token'; then
    echo refused
  else
    echo inconclusive
  fi
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
  for t in gh git jq shasum base64; do
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

owner_uid() {
  local id
  id="$(owner_gh api user --jq .id 2>/dev/null)" || die "can't read the owner's user id"
  [[ "$id" =~ ^[0-9]+$ ]] || die "unexpected user id"
  printf '%s' "$id"
}

load_helper() { # [token] — with "token", the token must be present and classic
  local dir mode
  dir="$(dirname "$SECRETS")"
  [[ -d "$dir" && ! -L "$dir" ]] || die "missing secrets folder $dir"
  mode="$(stat -f %Lp "$dir" 2>/dev/null)" || die "can't read the mode of $dir"
  [[ "$mode" == 700 ]] || die "$dir must be mode 700 (it is $mode)"
  [[ -f "$SECRETS" && ! -L "$SECRETS" ]] || die "missing secrets file $SECRETS"
  mode="$(stat -f %Lp "$SECRETS" 2>/dev/null)" || die "can't read the mode of $SECRETS"
  [[ "$mode" == 600 ]] || die "$SECRETS must be mode 600 (it is $mode)"
  HELPER="$(sed -n 's/^HELPER_LOGIN=//p' "$SECRETS" | tail -n 1)"
  TOKEN="$(sed -n 's/^HELPER_TOKEN=//p' "$SECRETS" | tail -n 1)"
  [[ "$HELPER" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]] || die "HELPER_LOGIN is missing or not a GitHub user name"
  local lh lo
  lh="$(printf '%s' "$HELPER" | tr '[:upper:]' '[:lower:]')"
  lo="$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]')"
  [[ "$lh" != "$lo" ]] || die "HELPER_LOGIN must not be the owner"
  if [[ "${1:-}" == token ]]; then
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
  WORK="$(mktemp -d "/private/tmp/frg26.XXXXXX")" || die "mktemp failed"
  chmod 700 "$WORK" || die "chmod failed"
  mkdir -m 700 "$WORK/home" "$WORK/gh-helper" "$WORK/template" || die "mkdir failed"
  cat >"$WORK/askpass" <<'EOF'
#!/bin/bash
case "${1:-}" in
  Username*) printf '%s\n' "$FRG26_ASK_USER" ;;
  *) printf '%s\n' "$FRG26_ASK_PASS" ;;
esac
EOF
  chmod 700 "$WORK/askpass" || die "chmod failed"
}

# --- Repository state ---------------------------------------------------------------------------

branch_state() { # <branch> — prints protected | unprotected | missing | error
  local out rc=0
  out="$(owner_gh api "repos/$REPO/branches/$1" --jq .protected 2>&1)" || rc=$?
  if [[ $rc -eq 0 && "$out" == true ]]; then echo protected
  elif [[ $rc -eq 0 && "$out" == false ]]; then echo unprotected
  elif printf '%s' "$out" | grep -q 'HTTP 404'; then echo missing
  else echo error
  fi
}

ruleset_count() {
  owner_gh api "repos/$REPO/rulesets" --jq length 2>/dev/null || echo error
}

readonly WANT_DEV="1 true true true true false false"
readonly WANT_MAIN="1 true true true false false false"

protection_of() { # <branch> — approvals codeowners last-push stale enforce-admins force deletions
  owner_gh api "repos/$REPO/branches/$1/protection" --jq '[.required_pull_request_reviews.required_approving_review_count, .required_pull_request_reviews.require_code_owner_reviews, .required_pull_request_reviews.require_last_push_approval, .required_pull_request_reviews.dismiss_stale_reviews, .enforce_admins.enabled, .allow_force_pushes.enabled, .allow_deletions.enabled] | map(tostring) | join(" ")' 2>/dev/null || echo error
}

ruleset_summary() { # one line describing the only ruleset, or error
  local id
  id="$(owner_gh api "repos/$REPO/rulesets" --jq '.[0].id' 2>/dev/null)" || { echo error; return; }
  [[ "$id" =~ ^[0-9]+$ ]] || { echo error; return; }
  owner_gh api "repos/$REPO/rulesets/$id" --jq '[.enforcement, .target, (.conditions.ref_name.include | join(",")), (.conditions.ref_name.exclude | length | tostring), ([.rules[] | if .type == "update" then "update:\(.parameters.update_allows_fetch_and_merge)" else .type end] | sort | join(",")), ([.bypass_actors[] | "\(.actor_type):\(.actor_id):\(.bypass_mode)"] | join(","))] | join(" ")' 2>/dev/null || echo error
}

want_ruleset() { # the two bypass choices this script may have installed
  printf 'active branch refs/heads/main 0 deletion,non_fast_forward,update:false User:%s:always\n' "$(owner_uid)"
  printf 'active branch refs/heads/main 0 deletion,non_fast_forward,update:false RepositoryRole:5:always\n'
}

verify_phase() { # <phase> — the repository must be exactly in the state that phase needs
  local d m r got
  d="$(branch_state dev)" m="$(branch_state main)" r="$(ruleset_count)"
  case "$1" in
    open)
      [[ "$d" == unprotected && "$m" == unprotected && "$r" == 0 ]] \
        || die "phase open needs dev and main unprotected and no ruleset (dev $d, main $m, rulesets $r)"
      ;;
    protected | ruleset)
      [[ "$d" == protected && "$m" == protected ]] || die "phase $1 needs dev and main protected (dev $d, main $m)"
      got="$(protection_of dev)"
      [[ "$got" == "$WANT_DEV" ]] || die "dev protection is '$got', expected '$WANT_DEV'"
      got="$(protection_of main)"
      [[ "$got" == "$WANT_MAIN" ]] || die "main protection is '$got', expected '$WANT_MAIN'"
      if [[ "$1" == protected ]]; then
        [[ "$r" == 0 ]] || die "phase protected needs no ruleset (found $r)"
      else
        [[ "$r" == 1 ]] || die "phase ruleset needs exactly one ruleset (found $r)"
        got="$(ruleset_summary)"
        want_ruleset | grep -Fxq -- "$got" || die "the ruleset is '$got', not one this script installs"
      fi
      ;;
    *) die "unknown phase $1" ;;
  esac
}

# --- Owner commands -----------------------------------------------------------------------------

put_file() { # <path> <content> — the owner commits a file to main through the API (no git)
  local b64
  b64="$(printf '%s' "$2" | base64 | tr -d '\n')"
  owner_gh api -X PUT "repos/$REPO/contents/$1" -f message="FRG-26 throwaway baseline: $1" \
    -f content="$b64" -f branch=main >/dev/null || die "adding $1 failed"
}

cmd_create() {
  need_owner
  if owner_gh api "repos/$REPO" >/dev/null 2>&1; then
    die "$REPO already exists; delete it in the browser first if you want a fresh one"
  fi
  # The baseline is written through GitHub's API with the owner's login: no local git, so no git
  # setting of the owner's can redirect a push.
  owner_gh repo create "$REPO" --public --description "$MARKER" --add-readme >/dev/null || die "gh repo create failed"
  assert_throwaway
  local first
  first="$(owner_gh api "repos/$REPO" --jq .default_branch)" || die "can't read the first branch's name"
  if [[ "$first" != main ]]; then
    owner_gh api -X POST "repos/$REPO/branches/$first/rename" -f new_name=main >/dev/null \
      || die "renaming the first branch '$first' to main failed"
  fi
  put_file .github/CODEOWNERS "* @$OWNER"$'\n'
  put_file docs/README.md "Docs folder (CODEOWNERS may also live here; test B4b)."$'\n'
  put_file tests/README.md "Test files land here."$'\n'
  local sha
  sha="$(owner_gh api "repos/$REPO/branches/main" --jq .commit.sha)" || die "can't read main"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "unexpected main sha"
  owner_gh api -X POST "repos/$REPO/git/refs" -f ref=refs/heads/dev -f sha="$sha" >/dev/null || die "creating dev failed"
  owner_gh api -X POST "repos/$REPO/git/refs" -f ref=refs/heads/side -f sha="$sha" >/dev/null || die "creating side failed"
  owner_gh api -X POST "repos/$REPO/git/refs" -f ref="refs/tags/$BASELINE_TAG" -f sha="$sha" >/dev/null || die "creating the baseline tag failed"
  repo_settings
  say "created $REPO (public), baseline $sha, branches main dev side, default $DEFAULT_BRANCH"
}

repo_settings() {
  # Auto-merge is on, so B11 tests whether an enabled auto-merge waits for the owner's approval.
  owner_gh api -X PATCH "repos/$REPO" -f default_branch="$DEFAULT_BRANCH" -F allow_auto_merge=true \
    -F allow_merge_commit=true -F allow_squash_merge=true -f description="$MARKER" >/dev/null \
    || die "setting the repository options failed"
}

cmd_invite() {
  need_owner
  load_helper
  assert_throwaway
  owner_gh api -X PUT "repos/$REPO/collaborators/$HELPER" -f permission=push >/dev/null \
    || die "inviting $HELPER failed"
  say "invited $HELPER to $REPO with write access"
}

# Records whether a public_repo token can accept a repository invitation (plan item 7). Exit 0 if
# it could, 3 if not (then the owner accepts it in the helper's browser window).
cmd_accept() {
  need_owner
  load_helper token
  need_helper_identity
  assert_throwaway
  local id
  capture helper_gh api user/repository_invitations --jq ".[] | select(.repository.full_name == \"$REPO\") | .id" || true
  id="$LAST_OUT"
  if [[ ! "$id" =~ ^[0-9]+$ ]]; then
    say "ACCEPT-WITH-PUBLIC_REPO: could not list the invitation with the token ($(evidence))"
    exit 3
  fi
  if capture helper_gh api -X PATCH "user/repository_invitations/$id"; then
    say "ACCEPT-WITH-PUBLIC_REPO: allowed (a public_repo token can accept invitations)"
    exit 0
  fi
  say "ACCEPT-WITH-PUBLIC_REPO: refused ($(evidence))"
  exit 3
}

# The helper's API allowance, read-only (GitHub doesn't count this request against it). Sets
# RATE_LINE (for people) and RATE_LEFT (GraphQL points remaining); 1 if it can't be read.
helper_rate() {
  RATE_LINE="" RATE_LEFT=""
  capture helper_gh api rate_limit || return 1
  RATE_LINE="$(printf '%s' "$LAST_OUT" | jq -r '.resources | "graphql limit=\(.graphql.limit) used=\(.graphql.used) remaining=\(.graphql.remaining) resets=\(.graphql.reset | todate) / rest limit=\(.core.limit) used=\(.core.used) remaining=\(.core.remaining)"' 2>/dev/null)" || return 1
  RATE_LEFT="$(printf '%s' "$LAST_OUT" | jq -r '.resources.graphql.remaining' 2>/dev/null)" || return 1
  [[ "$RATE_LEFT" =~ ^[0-9]+$ ]]
}

# A phase that ran out of allowance halfway would stop on a rate limit, so it doesn't start.
need_allowance() {
  helper_rate || die "could not read the helper's API allowance: $(evidence)"
  say "helper allowance: $RATE_LINE"
  [[ "$RATE_LEFT" -ge $MIN_GRAPHQL ]] \
    || die "the helper has only $RATE_LEFT GraphQL points left (a phase needs about $MIN_GRAPHQL): $RATE_LINE. Run this step again after that reset time."
}

cmd_rate() {
  load_helper token
  need_helper_identity
  helper_rate || die "could not read the helper's API allowance: $(evidence)"
  say "HELPER-RATE $RATE_LINE"
}

# One diagnostic request as the helper, through the same helper_gh the tests use. Prints the HTTP
# status, the listed headers only (never Authorization or cookies) and GitHub's answer in brief.
diag() { # <label> <helper_gh arguments…>
  local label="$1" clean status hdrs json summary ghmsg
  shift
  capture helper_gh "$@" || true
  clean="$(printf '%s\n' "$LAST_OUT" | tr -d '\r')"
  status="$(printf '%s\n' "$clean" | grep -m1 '^HTTP/')" || status="no HTTP status"
  hdrs="$(printf '%s\n' "$clean" | sed -n '/^HTTP\//,/^$/p' \
    | grep -iE '^(x-ratelimit-(limit|remaining|used|reset|resource)|retry-after|x-oauth-scopes|x-accepted-oauth-scopes|x-github-request-id):' \
    | awk '{ i = index($0, ":"); printf "%s:%s; ", tolower(substr($0, 1, i - 1)), substr($0, i + 1) }')"
  json="$(printf '%s\n' "$clean" | sed '1,/^$/d' | grep -v '^gh: ')"
  summary="$(printf '%s' "$json" | jq -r '
    if type != "object" then "no JSON body"
    elif .login then "login=\(.login) id=\(.id)"
    elif .resources then (.resources | "graphql limit=\(.graphql.limit) used=\(.graphql.used) remaining=\(.graphql.remaining) / rest limit=\(.core.limit) used=\(.core.used) remaining=\(.core.remaining)")
    elif .errors then (.errors | map("\(.type // "error"): \(.message)") | join(" | "))
    elif .data then "data=\(.data | tojson)"
    elif .message then "message=\(.message)"
    else "unrecognised JSON body" end' 2>/dev/null)" || summary="no JSON body"
  ghmsg="$(printf '%s\n' "$clean" | grep -m1 '^gh: ')" || ghmsg=""
  say "DIAG $label: exit=$LAST_RC $status | ${hdrs}| $summary${ghmsg:+ | $ghmsg}"
}

# Authenticates exactly as the tests do (load_helper, then helper_gh), and records what GitHub
# answers to three requests: who the token is, the allowance, and a one-line GraphQL query.
cmd_diagnose() {
  load_helper token
  diag "GET /user" api -i user
  diag "GET /rate_limit" api -i rate_limit
  diag "POST /graphql" api -i graphql -f "query=query { viewer { login } rateLimit { limit remaining used resetAt } }"
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
  local b s
  for b in main dev side; do
    s="$(branch_state "$b")"
    [[ "$s" == unprotected || "$s" == missing ]] || die "reset only runs while nothing is protected ($b is $s)"
  done
  [[ "$(ruleset_count)" == 0 ]] || die "reset only runs while there is no ruleset"
  local base open_prs n
  base="$(owner_gh api "repos/$REPO/git/ref/tags/$BASELINE_TAG" --jq .object.sha)" || die "the baseline tag is missing"
  [[ "$base" =~ ^[0-9a-f]{40}$ ]] || die "unexpected baseline sha"
  open_prs="$(owner_gh api "repos/$REPO/pulls?state=open&per_page=100" --jq '.[].number')" || die "can't list open PRs"
  for n in $open_prs; do
    [[ "$n" =~ ^[0-9]+$ ]] || die "unexpected PR number '$n'"
    owner_gh pr close "$n" --repo "$REPO" >/dev/null 2>&1 || die "closing PR #$n failed"
  done
  for b in main dev side; do
    if [[ "$(branch_state "$b")" == missing ]]; then
      owner_gh api -X POST "repos/$REPO/git/refs" -f ref="refs/heads/$b" -f sha="$base" >/dev/null \
        || die "recreating $b failed"
    else
      owner_gh api -X PATCH "repos/$REPO/git/refs/heads/$b" -f sha="$base" -F force=true >/dev/null \
        || die "resetting $b failed"
    fi
  done
  repo_settings
  verify_phase open
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
  verify_phase open
  # dev: nobody merges without the owner's code-owner approval, admins included (D5).
  protection_json true >"$WORK/dev.json"
  # main: the same review rule; admins (only the owner) may bypass it, so the owner can merge
  # dev into main (M6). Who may update main at all is the ruleset's job (D6).
  protection_json false >"$WORK/main.json"
  owner_gh api -X PUT "repos/$REPO/branches/dev/protection" --input "$WORK/dev.json" >/dev/null || die "protecting dev failed"
  owner_gh api -X PUT "repos/$REPO/branches/main/protection" --input "$WORK/main.json" >/dev/null || die "protecting main failed"
  verify_phase protected
  say "dev protection:  $(protection_of dev)   (approvals codeowners last-push stale enforce-admins force deletions)"
  say "main protection: $(protection_of main)"
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
  verify_phase protected
  local uid
  uid="$(owner_uid)"
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
  verify_phase ruleset
  say "ruleset: $(ruleset_summary)"
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

# A branch without protection and a repository without a ruleset have nothing more to read; any
# other read that fails makes the status step fail.
cmd_status() {
  need_owner
  assert_throwaway
  local b st prot n sum def bad=""
  for b in dev main; do
    st="$(branch_state "$b")"
    prot=none
    if [[ "$st" == protected ]]; then prot="$(protection_of "$b")"; fi
    if [[ "$st" == error || "$prot" == error ]]; then bad="$bad $b"; fi
    say "$b: $st [$prot]"
  done
  n="$(ruleset_count)"
  sum=none
  if [[ ! "$n" =~ ^[0-9]+$ ]]; then bad="$bad rulesets"
  elif [[ "$n" -gt 0 ]]; then
    sum="$(ruleset_summary)"
    if [[ "$sum" == error ]]; then bad="$bad ruleset"; fi
  fi
  say "rulesets: $n [$sum]"
  def="$(owner_gh api "repos/$REPO" --jq .default_branch)" || def=""
  if [[ -z "$def" ]]; then bad="$bad default-branch"; fi
  say "default branch: ${def:-error}"
  if [[ -n "$bad" ]]; then die "could not read:$bad"; fi
}

# --- Bypass tests -------------------------------------------------------------------------------

# Expected result of each test in each phase (plan section 6): allowed | refused.
expect() { # <id> <phase>
  case "$1:$2" in
    B5:* | B12:* | B13:* | M4:*) echo refused ;;
    B16:* | M6:*) echo allowed ;;
    M2:open | M2:protected) echo allowed ;;
    *:open) echo allowed ;;
    *) echo refused ;;
  esac
}

record() { # <id> <observed allowed|refused|inconclusive> <evidence>
  local want verdict
  want="$(expect "$1" "$PHASE")"
  if [[ "$2" != inconclusive && "$want" == "$2" ]]; then verdict=PASS; else
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

# Names of branches, files and commits carry this run's id (date, time and process id), so a later
# run never reuses a branch or a file an earlier run left behind. Within a run each test's name
# also carries its own id.
RUN_ID=""
stamp() { printf '%s' "$RUN_ID"; }

# The order cmd_tests runs the tests in. Last: in the open phase B14 and M5 rewrite or delete dev
# and main (a reset follows).
readonly TEST_ORDER="B5 B1 B2 B3 B4a B4b B6 B7 B8 B9 B10 B11 B12 B13 B16 M1 M2 M3 M4 M6 B14a B14b M5a M5b"

fresh_from() { # <remote branch> <local branch>
  helper_git -C "$CLONE" fetch -q --prune origin || die "fetch failed"
  helper_git -C "$CLONE" checkout -q -B "$2" "origin/$1" || die "checkout of origin/$1 failed"
}

add_commit() { # <path> <content>
  mkdir -p "$CLONE/$(dirname "$1")"
  printf '%s\n' "$2" >"$CLONE/$1"
  helper_git -C "$CLONE" add -- "$1" || die "git add failed"
  helper_git -C "$CLONE" commit -q -m "FRG-26 test: $1" || die "git commit failed"
}

push_branch() { # <branch> — push HEAD as a feature branch (always allowed)
  capture helper_git -C "$CLONE" push -q origin "HEAD:refs/heads/$1" || die "pushing $1 failed: $(evidence)"
}

helper_pr() { # <base> <head> <id> — sets LAST_PR, or returns 1
  capture helper_gh pr create --repo "$REPO" --base "$1" --head "$2" --title "FRG-26 $3 ($PHASE)" \
    --body "FRG-26 throwaway test $3, phase $PHASE." || return 1
  LAST_PR="$(printf '%s' "$LAST_OUT" | tail -n 1)"
  LAST_PR="${LAST_PR##*/}"
  [[ "$LAST_PR" =~ ^[0-9]+$ ]]
}

feature_pr() { # <id> [base] — a fresh feature branch with one new file, and a PR from the helper
  BR="frg26/$PHASE/$1-$(stamp)"
  fresh_from dev "$BR"
  add_commit "tests/$PHASE-$1-$(stamp).txt" "FRG-26 $1 $PHASE"
  push_branch "$BR"
  helper_pr "${2:-dev}" "$BR" "$1" || die "creating the PR for $1 failed: $(evidence)"
}

pr_view() { # <pr> <fields> <jq>
  owner_gh pr view "$1" --repo "$REPO" --json "$2" --jq "$3" 2>/dev/null
}

wait_settled() { # <pr> — GitHub computes mergeability in the background; 1 if it never settles
  local _ st
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    st="$(pr_view "$1" mergeable .mergeable)" || st=UNKNOWN
    [[ "$st" == MERGEABLE || "$st" == CONFLICTING ]] && return 0
    sleep 3
  done
  return 1
}

merge_facts() { # <pr> — "state mergeable mergeStateStatus reviewDecision"
  pr_view "$1" state,mergeable,mergeStateStatus,reviewDecision \
    '"\(.state) \(.mergeable) \(.mergeStateStatus) \(.reviewDecision)"' || echo "unknown unknown unknown unknown"
}

# The helper tries to merge. Allowed = GitHub then reports the PR MERGED. Refused = still open,
# free of conflicts, and GitHub reports it BLOCKED (by protection or a ruleset). Anything else is
# inconclusive. When the test expects "allowed", transient refusals are retried, so a refusal is
# never reported for a merge GitHub would have allowed.
helper_merge() { # <id> <pr> <merge flags…>
  local id="$1" pr="$2" _ facts
  shift 2
  for _ in 1 2 3; do
    if ! wait_settled "$pr"; then OBS=inconclusive; LAST_OUT="mergeability never settled [$(merge_facts "$pr")]"; return; fi
    capture helper_gh pr merge "$pr" --repo "$REPO" "$@" || true
    sleep 3
    facts="$(merge_facts "$pr")"
    if [[ "$facts" == MERGED* ]]; then OBS=allowed; LAST_OUT="$LAST_OUT [$facts]"; return; fi
    [[ "$(expect "$id" "$PHASE")" == allowed ]] || break
    sleep 5
  done
  # Refused needs both: the merge command itself was rejected for a protection reason, and GitHub
  # reports the PR open, free of conflicts and BLOCKED.
  OBS=inconclusive
  if [[ $LAST_RC -ne 0 && "$facts" == "OPEN MERGEABLE BLOCKED "* ]] && merge_rejected_by_policy; then OBS=refused; fi
  LAST_OUT="$LAST_OUT [$facts]"
}

merge_rejected_by_policy() { # LAST_OUT is a protection or ruleset refusal (not a rate limit)
  printf '%s' "$LAST_OUT" | grep -Eiq 'rate limit|abuse detection' && return 1
  printf '%s' "$LAST_OUT" | grep -Eiq 'base branch policy prohibits|approving review|code owner|rule violation|protected branch|not authorized to push|Must have admin rights'
}

owner_approve() { # <pr>
  wait_settled "$1" || die "PR #$1 never became mergeable"
  owner_gh pr review "$1" --repo "$REPO" --approve --body "FRG-26 test approval by the owner" >/dev/null 2>&1 \
    || die "the owner could not approve PR #$1"
  sleep 3
}

close_if_open() { # <pr> — tidy up after a refused attempt
  if [[ "$(pr_view "$1" state .state)" == OPEN ]]; then owner_gh pr close "$1" --repo "$REPO" >/dev/null 2>&1 || true; fi
}

dev_ahead() { # <id> — helper PR into dev, owner approves, helper merges (the B16 control)
  feature_pr "$1"
  owner_approve "$LAST_PR"
  helper_merge B16 "$LAST_PR" --squash
}

direct_push() { # <id> <branch> <path> <content> — a commit on top of <branch>, pushed to it
  fresh_from "$2" "$1-$(stamp)"
  add_commit "$3" "$4"
  capture helper_git -C "$CLONE" push origin "HEAD:refs/heads/$2" || true
  record "$1" "$(classify_push)" "$(evidence)"
}

t_B1() { direct_push B1 dev "tests/$PHASE-B1-$(stamp).txt" "direct push to dev"; }

t_B2() { # helper names itself code owner, straight on dev
  fresh_from dev "b2-$(stamp)"
  printf '* @%s\n# B2 %s %s\n' "$HELPER" "$PHASE" "$(stamp)" >"$CLONE/.github/CODEOWNERS"
  helper_git -C "$CLONE" commit -q -am "FRG-26 test: helper names itself code owner" || die "commit failed"
  capture helper_git -C "$CLONE" push origin HEAD:refs/heads/dev || true
  record B2 "$(classify_push)" "$(evidence)"
}

codeowners_pr() { # <id> <where: github|root|docs> — a PR that makes the helper the code owner
  BR="frg26/$PHASE/$1-$(stamp)"
  fresh_from dev "$BR"
  local line
  line="$(printf '* @%s\n# %s %s %s' "$HELPER" "$1" "$PHASE" "$(stamp)")"
  case "$2" in
    github)
      mkdir -p "$CLONE/.github"
      printf '%s\n' "$line" >"$CLONE/.github/CODEOWNERS"
      helper_git -C "$CLONE" add .github/CODEOWNERS || die "git add failed"
      ;;
    root | docs)
      # GitHub reads .github/CODEOWNERS first, then the root, then docs/: remove the earlier ones.
      helper_git -C "$CLONE" rm -q --ignore-unmatch .github/CODEOWNERS || die "git rm failed"
      if [[ "$2" == docs ]]; then
        helper_git -C "$CLONE" rm -q --ignore-unmatch CODEOWNERS || die "git rm failed"
        printf '%s\n' "$line" >"$CLONE/docs/CODEOWNERS"
        helper_git -C "$CLONE" add docs/CODEOWNERS || die "git add failed"
      else
        printf '%s\n' "$line" >"$CLONE/CODEOWNERS"
        helper_git -C "$CLONE" add CODEOWNERS || die "git add failed"
      fi
      ;;
  esac
  helper_git -C "$CLONE" commit -q -m "FRG-26 test $1: CODEOWNERS ($2) names the helper" || die "commit failed"
  push_branch "$BR"
  helper_pr dev "$BR" "$1" || die "creating the PR for $1 failed: $(evidence)"
  local pr="$LAST_PR"
  helper_merge "$1" "$pr" --squash
  record "$1" "$OBS" "$(evidence)"
  close_if_open "$pr"
}

t_B3() { codeowners_pr B3 github; }
t_B4a() { codeowners_pr B4a root; }
t_B4b() { codeowners_pr B4b docs; }

t_B5() {
  feature_pr B5
  local pr="$LAST_PR" obs
  wait_settled "$pr" || { setup_fail B5 "PR never became mergeable"; close_if_open "$pr"; return; }
  capture helper_gh pr review "$pr" --repo "$REPO" --approve --body "self-approval attempt" || true
  if [[ $LAST_RC -eq 0 ]]; then obs=allowed
  elif printf '%s' "$LAST_OUT" | grep -Eiq 'approve your own pull request'; then obs=refused
  else obs=inconclusive
  fi
  record B5 "$obs" "$(evidence)"
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
  add_commit "tests/$PHASE-B7-after-approval-$(stamp).txt" "pushed after the owner's approval"
  push_branch "$BR"
  sleep 3
  helper_merge B7 "$pr" --squash
  record B7 "$OBS" "$(evidence)"
  close_if_open "$pr"
}

t_B8() {
  feature_pr B8
  local pr="$LAST_PR"
  owner_approve "$pr"
  local old_head dev_sha
  old_head="$(pr_view "$pr" headRefOid .headRefOid)" || old_head=""
  dev_ahead B8-advance
  [[ "$OBS" == allowed ]] || { setup_fail B8 "could not advance dev ($(evidence))"; close_if_open "$pr"; return; }
  dev_sha="$(owner_gh api "repos/$REPO/branches/dev" --jq .commit.sha 2>/dev/null)" || dev_sha=""
  if [[ ! "$old_head" =~ ^[0-9a-f]{40}$ || ! "$dev_sha" =~ ^[0-9a-f]{40}$ ]]; then
    setup_fail B8 "could not read the PR head or dev"
    close_if_open "$pr"
    return
  fi
  if ! capture helper_gh api -X PUT "repos/$REPO/pulls/$pr/update-branch"; then
    setup_fail B8 "update-branch refused ($(evidence))"
    close_if_open "$pr"
    return
  fi
  # update-branch is asynchronous: wait until the PR's head is a new commit with dev as a parent.
  if ! branch_updated "$pr" "$old_head" "$dev_sha"; then
    setup_fail B8 "the PR branch never picked up dev $dev_sha"
    close_if_open "$pr"
    return
  fi
  helper_merge B8 "$pr" --squash
  record B8 "$OBS" "$(evidence)"
  close_if_open "$pr"
}

branch_updated() { # <pr> <old head> <dev sha> — 0 once the head moved and has dev as a parent
  local _ head parents
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    head="$(pr_view "$1" headRefOid .headRefOid)" || head=""
    if [[ "$head" =~ ^[0-9a-f]{40}$ && "$head" != "$2" ]]; then
      parents="$(owner_gh api "repos/$REPO/commits/$head" --jq '[.parents[].sha] | join(" ")' 2>/dev/null)" || parents=""
      [[ " $parents " == *" $3 "* ]] && return 0
    fi
    sleep 3
  done
  return 1
}

t_B9() {
  feature_pr B9 side
  local pr="$LAST_PR"
  owner_approve "$pr"
  # REST, not `gh pr edit`: that also reads fields needing read:org, which the helper's token lacks.
  # Re-aiming is setup, not the bypass under test (the merge is): any failure proves nothing.
  if ! capture helper_gh api -X PATCH "repos/$REPO/pulls/$pr" -f base=dev; then
    setup_fail B9 "re-aiming at dev failed: $(evidence)"
    close_if_open "$pr"
    return
  fi
  sleep 3
  local base
  base="$(pr_view "$pr" baseRefName .baseRefName)" || base=""
  if [[ "$base" != dev ]]; then
    setup_fail B9 "re-aimed PR's base reads '${base:-unreadable}', not dev"
    close_if_open "$pr"
    return
  fi
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

# B11: auto-merge is enabled on the repository. In the open phase, the helper's auto-merge must
# work (the PR merges, or auto-merge is armed). In the protected phases the helper arms it for
# its unapproved PR, which must not merge; then, as a control, the owner approves and the PR
# must merge by itself (proving auto-merge was really armed). An unreadable state is
# inconclusive.
t_B11() {
  feature_pr B11
  local pr="$LAST_PR" armed st
  wait_settled "$pr" || { setup_fail B11 "PR never became mergeable"; close_if_open "$pr"; return; }
  capture helper_gh pr merge "$pr" --repo "$REPO" --squash --auto || true
  local first
  first="$(evidence)"
  sleep 30
  st="$(pr_view "$pr" state .state)" || st=unknown
  armed="$(pr_view "$pr" autoMergeRequest '.autoMergeRequest != null')" || armed=unknown
  if [[ "$PHASE" == open ]]; then
    if [[ "$st" == MERGED || ( "$st" == OPEN && "$armed" == true ) ]]; then
      record B11 allowed "$first [state $st, armed $armed]"
    else
      record B11 inconclusive "$first [state $st, armed $armed]"
    fi
    close_if_open "$pr"
    return
  fi
  if [[ "$st" == MERGED ]]; then
    record B11 allowed "$first [merged without approval]"
    return
  fi
  if [[ "$st" != OPEN || "$armed" != true ]]; then
    setup_fail B11 "auto-merge was not armed ($first) [state $st, armed $armed]"
    close_if_open "$pr"
    return
  fi
  owner_approve "$pr"
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    st="$(pr_view "$pr" state .state)" || st=unknown
    [[ "$st" == MERGED ]] && break
    sleep 5
  done
  if [[ "$st" == MERGED ]]; then
    record B11 refused "$first [held until the owner approved, then merged by itself]"
  else
    setup_fail B11 "held, but did not merge after the owner approved [state $st]"
    close_if_open "$pr"
  fi
}

admin_attempts() { # <id> <method path [input]>... separated by ";;" — refused only if every one is
  # The first attempt that isn't refused ends the test: none after it is made (the stop rule).
  local id="$1" obs=refused ev="" c
  shift
  while [[ $# -gt 0 && "$obs" == refused ]]; do
    c=()
    while [[ $# -gt 0 && "$1" != ";;" ]]; do c+=("$1"); shift; done
    [[ $# -gt 0 ]] && shift
    capture helper_gh api "${c[@]}" || true
    obs="$(classify_api)"
    ev="$ev ${c[0]} ${c[1]}: $(evidence) |"
  done
  record "$id" "$obs" "$ev"
}

t_B12() {
  printf '{"required_status_checks":null,"enforce_admins":false,"required_pull_request_reviews":null,"restrictions":null}\n' >"$WORK/weak.json"
  admin_attempts B12 -X PUT "repos/$REPO/branches/dev/protection" --input "$WORK/weak.json" ";;" \
    -X DELETE "repos/$REPO/branches/dev/protection"
}

t_B13() {
  # The same payloads the owner's own ruleset step uses (one of them is proven valid there).
  ruleset_json User "$(owner_uid)" >"$WORK/helper-ruleset-user.json"
  ruleset_json RepositoryRole 5 >"$WORK/helper-ruleset-admin.json"
  admin_attempts B13 -X POST "repos/$REPO/rulesets" --input "$WORK/helper-ruleset-user.json" ";;" \
    -X POST "repos/$REPO/rulesets" --input "$WORK/helper-ruleset-admin.json" ";;" \
    -X PATCH "repos/$REPO" -f description="changed by the helper"
  # Put the marker back if the helper managed to change it, so later commands still recognise
  # the throwaway repo.
  owner_gh api -X PATCH "repos/$REPO" -f description="$MARKER" >/dev/null 2>&1 || true
}

force_push() { # <id> <branch> — an unrelated history pushed over <branch>
  helper_git -C "$CLONE" checkout -q --orphan "$1-$(stamp)" || die "checkout failed"
  helper_git -C "$CLONE" rm -rq --cached . >/dev/null 2>&1 || true
  add_commit "tests/orphan-$1-$(stamp).txt" "unrelated history"
  capture helper_git -C "$CLONE" push --force origin "HEAD:refs/heads/$2" || true
  record "$1" "$(classify_push)" "$(evidence)"
}

delete_branch() { # <id> <branch>
  capture helper_git -C "$CLONE" push origin ":refs/heads/$2" || true
  record "$1" "$(classify_push)" "$(evidence)"
}

t_B14a() { force_push B14a dev; }
t_B14b() { delete_branch B14b dev; }
t_M5a() { force_push M5a main; }
t_M5b() { delete_branch M5b main; }

t_B16() {
  dev_ahead B16
  record B16 "$OBS" "$(evidence)"
}

t_M1() { direct_push M1 main "tests/$PHASE-M1-$(stamp).txt" "direct push to main"; }

t_M2() {
  dev_ahead M2-advance
  [[ "$OBS" == allowed ]] || { setup_fail M2 "could not advance dev ($(evidence))"; return; }
  helper_pr main dev M2 || { setup_fail M2 "could not open dev->main ($(evidence))"; return; }
  local pr="$LAST_PR"
  owner_approve "$pr"
  helper_merge M2 "$pr" --merge
  record M2 "$OBS" "$(evidence)"
  close_if_open "$pr"
}

t_M3() {
  dev_ahead M3-advance
  [[ "$OBS" == allowed ]] || { setup_fail M3 "could not advance dev ($(evidence))"; return; }
  helper_pr main dev M3 || { setup_fail M3 "could not open dev->main ($(evidence))"; return; }
  local pr="$LAST_PR"
  helper_merge M3 "$pr" --merge --admin
  record M3 "$OBS" "$(evidence)"
  close_if_open "$pr"
}

t_M4() {
  printf '{"required_status_checks":null,"enforce_admins":false,"required_pull_request_reviews":null,"restrictions":null}\n' >"$WORK/weak.json"
  if [[ "$PHASE" != ruleset ]]; then
    admin_attempts M4 -X PUT "repos/$REPO/branches/main/protection" --input "$WORK/weak.json" ";;" \
      -X DELETE "repos/$REPO/branches/main/protection"
    return
  fi
  local id
  id="$(owner_gh api "repos/$REPO/rulesets" --jq '.[0].id' 2>/dev/null)" || id=""
  [[ "$id" =~ ^[0-9]+$ ]] || { setup_fail M4 "could not read the ruleset's id"; return; }
  # Changing the ruleset. Both payloads are built from GitHub's own copy of the installed ruleset
  # (so they are valid requests): one switches it off; the other adds the helper to the bypass
  # list, in the actor form GitHub accepted for the owner on this repo (a User). If GitHub only
  # accepted the Repository admin role, there is no proven form that names the helper, and that
  # attempt is skipped (said in the evidence).
  local rs kind
  rs="$(owner_gh api "repos/$REPO/rulesets/$id" 2>/dev/null)" || { setup_fail M4 "could not read the ruleset"; return; }
  printf '%s' "$rs" | jq '{name, target, enforcement: "disabled", conditions, rules, bypass_actors}' >"$WORK/ruleset-off.json" \
    || { setup_fail M4 "could not build the switch-off payload"; return; }
  kind="$(printf '%s' "$rs" | jq -r '.bypass_actors[0].actor_type')" || kind=""
  if [[ "$kind" == User ]]; then
    local hid
    hid="$(owner_gh api "users/$HELPER" --jq .id 2>/dev/null)" || hid=""
    [[ "$hid" =~ ^[0-9]+$ ]] || { setup_fail M4 "could not read the helper's user id"; return; }
    printf '%s' "$rs" | jq --argjson hid "$hid" '{name, target, enforcement, conditions, rules, bypass_actors: (.bypass_actors + [{actor_id: $hid, actor_type: "User", bypass_mode: "always"}])}' \
      >"$WORK/ruleset-helper.json" || { setup_fail M4 "could not build the helper-bypass payload"; return; }
    admin_attempts M4 -X PUT "repos/$REPO/branches/main/protection" --input "$WORK/weak.json" ";;" \
      -X DELETE "repos/$REPO/branches/main/protection" ";;" \
      -X PUT "repos/$REPO/rulesets/$id" --input "$WORK/ruleset-off.json" ";;" \
      -X PUT "repos/$REPO/rulesets/$id" --input "$WORK/ruleset-helper.json" ";;" \
      -X DELETE "repos/$REPO/rulesets/$id"
  else
    admin_attempts M4 -X PUT "repos/$REPO/branches/main/protection" --input "$WORK/weak.json" ";;" \
      -X DELETE "repos/$REPO/branches/main/protection" ";;" \
      -X PUT "repos/$REPO/rulesets/$id" --input "$WORK/ruleset-off.json" ";;" \
      -X DELETE "repos/$REPO/rulesets/$id"
    say "M4 note: the add-the-helper-as-bypass attempt was skipped (the ruleset's bypass is $kind, so no proven actor form names the helper)"
  fi
}

t_M6() { # the owner merges dev into main
  dev_ahead M6-advance
  [[ "$OBS" == allowed ]] || { setup_fail M6 "could not advance dev ($(evidence))"; return; }
  if ! capture owner_gh pr create --repo "$REPO" --base main --head dev --title "FRG-26 M6 ($PHASE)" \
    --body "FRG-26 throwaway test M6: the owner merges dev into main."; then
    setup_fail M6 "the owner could not open the PR: $(evidence)"
    return
  fi
  local pr facts
  pr="$(printf '%s' "$LAST_OUT" | tail -n 1)"
  pr="${pr##*/}"
  [[ "$pr" =~ ^[0-9]+$ ]] || { setup_fail M6 "unexpected PR URL: $(evidence)"; return; }
  wait_settled "$pr" || { setup_fail M6 "PR never became mergeable"; close_if_open "$pr"; return; }
  capture owner_gh pr merge "$pr" --repo "$REPO" --merge --admin || true
  sleep 3
  facts="$(merge_facts "$pr")"
  if [[ "$facts" == MERGED* ]]; then OBS=allowed; else OBS=inconclusive; fi
  record M6 "$OBS" "$(evidence) [$facts]"
  close_if_open "$pr"
}

cmd_tests() {
  PHASE="${1:-}"
  case "$PHASE" in open | protected | ruleset) ;; *) die "usage: tests open|protected|ruleset" ;; esac
  need_owner
  load_helper token
  need_helper_identity
  assert_throwaway
  verify_phase "$PHASE"
  need_allowance
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  CLONE="$WORK/clone"
  helper_git clone -q --template="$WORK/template" "https://github.com/$REPO.git" "$CLONE" || die "clone failed"
  say "== FRG-26 bypass tests, phase $PHASE, helper $HELPER, $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
  # The stop rule (plan section 3): after a failed or inconclusive test nothing more is changed.
  # A test tidies up after itself before it returns; the next one never starts.
  local id
  for id in $TEST_ORDER; do
    "t_$id"
    if [[ $FAILS -ne 0 ]]; then
      if helper_rate; then say "helper allowance after the phase: $RATE_LINE"; fi
      say "PHASE $PHASE: STOPPED after $id (a failed test stops the phase; nothing more was changed)"
      exit 1
    fi
  done
  if helper_rate; then say "helper allowance after the phase: $RATE_LINE"; fi
  say "PHASE $PHASE: ALL PASS"
  exit 0
}

main() {
  refuse_agent
  need_tools
  make_work
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    create) cmd_create ;;
    invite) cmd_invite ;;
    accept) cmd_accept ;;
    check-helper) cmd_check_helper ;;
    rate) cmd_rate ;;
    diagnose) cmd_diagnose ;;
    reset) cmd_reset ;;
    protect) cmd_protect ;;
    ruleset) cmd_ruleset ;;
    tests) cmd_tests "$@" ;;
    actions-setting) cmd_actions_setting ;;
    status) cmd_status ;;
    *) die "usage: github-throwaway.sh create|invite|accept|check-helper|rate|diagnose|reset|protect|ruleset|tests <phase>|actions-setting|status" ;;
  esac
}

# Run main when executed as a file or as `bash -p -c "<this script>" frg26 <command>` (the
# handoffs), but not when a test sources it.
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
