#!/bin/bash
# FRG-26 stage 1: GitHub feasibility tests on a throwaway repository
# (docs/plans/2026-10-20-frg-26-permissions-isolation.md, sections 6 and 8).
#
# Run ONLY by the owner, from an owner handoff, in the owner's own Terminal. It acts as two parties:
#   owner   the owner's own gh login: creates the repo, approves PRs, applies protection, resets
#   app     the owner's throwaway GitHub App (plan section 4, revised 2026-11-01): every bypass
#           attempt, with an installation token limited to the throwaway repo and four permissions
# It touches only github.com/Thebigtuna88/forge-frg26-throwaway and refuses any other repository.
#
#   github-throwaway.sh create            owner: create the throwaway repo (public; main dev side)
#   github-throwaway.sh check-app         the app, its installation and its token carry exactly the
#                                         throwaway repo and the four permissions (read-only; A1)
#   github-throwaway.sh rate              the app's API allowance: limit, used, reset (read-only)
#   github-throwaway.sh allowance         fails unless the app has enough allowance for a phase
#   github-throwaway.sh reset             owner: main dev side back to the baseline (unprotected only)
#   github-throwaway.sh protect           owner: apply the dev and main branch protection
#   github-throwaway.sh unprotect         owner: remove exactly that protection (protected state only)
#   github-throwaway.sh ruleset           owner: add the main ruleset (only the owner may bypass);
#                                         first checks the app has enough allowance
#   github-throwaway.sh tests <phase>     run the bypass tests (kind S); phase = open | protected | ruleset
#   github-throwaway.sh create-second     owner: the second public throwaway, app not installed (A2)
#   github-throwaway.sh ptests            the permission tests (kind P, each with a control):
#                                         S1 A6 A8 A5 A3 A2, and the readings A11 A12
#   github-throwaway.sh env-setup         owner: the Environment frg26-test, a dummy value (S2)
#   github-throwaway.sh env-tests         S2b S2d S2a S2c, in the open phase (then reset)
#   github-throwaway.sh hold-token <name> keep a token for a later check: age keyold suspend
#                                         uninstall delete (plan 4.3)
#   github-throwaway.sh token-age-check   A4: a token over an hour old is refused
#   github-throwaway.sh key-check         A9, A9b: after the old key was deleted in the browser
#   github-throwaway.sh suspend-check     E1 (first half): while the installation is suspended
#   github-throwaway.sh unsuspend-check   E1 (verdict): a new token works again after unsuspending
#   github-throwaway.sh uninstall-check   E2: after the app was uninstalled
#   github-throwaway.sh delete-check      E3: after the app was deleted
#   github-throwaway.sh actions-setting   B15: "Allow GitHub Actions to approve PRs" must be off
#   github-throwaway.sh status            print the repo's protection and rulesets (read-only)
#
# The owner's handoffs don't run this file: each step reads it from the reviewed git commit into
# memory, checks its sha256 and runs that copy with `bash -p -c` in an empty environment.
# The app's id comes from FRG26_SECRETS (default below), a mode-600 file with an APP_ID=... line;
# its private key from FRG26_APP_KEY, a mode-600 PEM file in the same mode-700 folder. The key only
# signs a JWT (RS256, valid at most 10 minutes) to ask GitHub for an installation token (1 hour).
# Neither the JWT nor a token is ever printed or put in a command's arguments; each token is
# revoked when the script ends.
# Must run on macOS /bin/bash 3.2.
set -uo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
export PATH

readonly OWNER=Thebigtuna88
readonly REPO_NAME=forge-frg26-throwaway
readonly REPO="$OWNER/$REPO_NAME"
readonly MARKER="FRG-26 throwaway: permission tests. Safe to delete."
# A second public throwaway the app is NOT installed on (test A2), with one branch for a PR attempt.
readonly REPO2_NAME=forge-frg26-throwaway-2
readonly REPO2="$OWNER/$REPO2_NAME"
readonly MARKER2="FRG-26 throwaway 2: the app is not installed here (test A2). Safe to delete."
readonly A2_BRANCH=frg26-a2
readonly BASELINE_TAG=frg26-baseline
# The default branch is side, not dev as in FORGE, so that deleting dev can be tested (GitHub
# never deletes a default branch, protected or not).
readonly DEFAULT_BRANCH=side
# GraphQL points the app must have left before a phase starts (each gh pr command uses some).
readonly MIN_GRAPHQL=300
# REST requests too (gh api calls and the identity check); the normal limit is 5000 an hour.
readonly MIN_REST=300
SECRETS="${FRG26_SECRETS:-/Users/atl/code/forge/work/owner-secrets/frg26/app.env}"
APP_KEY="${FRG26_APP_KEY:-/Users/atl/code/forge/work/owner-secrets/frg26/app.pem}"
# The only permissions the app, its installation and every token may carry (plan 4.1).
readonly WANT_PERMS='{"contents":"write","issues":"write","metadata":"read","pull_requests":"write"}'

APP_ID=""
APP_SLUG=""
APP_BOT=""
INSTALLATION_ID=""
JWT=""
TOKEN=""
REVOKED_TOKENS=""
REDACT_ONLY="" # tokens held for a later check: hidden like the others, never revoked by this run
LAST_HTTP=""
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

redact() { # <text> — no token or JWT ever reaches the screen or a log
  local s="$1" t
  for t in $TOKEN $REVOKED_TOKENS $REDACT_ONLY $JWT; do s="${s//"$t"/[REDACTED]}"; done
  printf '%s' "$s"
}

say() { redact "$*"; printf '\n'; }

# Set once the bypass tests start; cleared when cmd_tests sweeps on its own. While it's set, any
# other way out (die, or bash stopping on an error) closes the open test PRs first, so a PR (B11's
# with auto-merge armed) is never left behind. Subshells don't run this trap.
SWEEP_ON_EXIT=""

cleanup() {
  local rc=$?
  if [[ -n "$SWEEP_ON_EXIT" ]]; then
    SWEEP_ON_EXIT=""
    say "PHASE $PHASE: STOPPED by an error (status $rc); closing the open test PRs"
    sweep_prs
  fi
  revoke_token
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

# The app's installation token, for this one process only: an exported variable, never an argument
# (so it isn't in the process list), and an empty gh config folder (none of the owner's settings).
# shellcheck disable=SC2030,SC2031 # as above
app_gh() {
  (
    unset GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_REPO
    export GH_TOKEN="$TOKEN" GH_HOST=github.com GH_CONFIG_DIR="$WORK/gh-app" \
      GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1
    exec gh "$@"
  )
}

# git as the app: no GIT_* variable, no system or global config (so no credential helper or
# URL rewrite of the owner's applies), no hooks, credentials only from our askpass script.
app_git() {
  (
    local v
    for v in $(compgen -e); do
      case "$v" in GIT_* | SSH_ASKPASS) unset "$v" ;; esac
    done
    export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 HOME="$WORK/home"
    export FRG26_ASK_USER=x-access-token FRG26_ASK_PASS="$TOKEN" GIT_ASKPASS="$WORK/askpass"
    exec git -c credential.helper= -c core.askPass="$WORK/askpass" -c core.hooksPath=/dev/null \
      -c commit.gpgsign=false -c protocol.allow=never -c protocol.https.allow=always \
      -c user.name="frg26-app-test" -c user.email="frg26-app-test@users.noreply.github.com" "$@"
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

classify_push() { # after capture of an app git push
  if [[ $LAST_RC -eq 0 ]]; then echo allowed; return; fi
  if printf '%s' "$LAST_OUT" | grep -Eiq 'GH006|GH013|protected branch|rule violation|Cannot force-push|cannot delete|Changes must be made through a pull request'; then
    echo refused
  else
    echo inconclusive
  fi
}

classify_api() { # after capture of an app gh api call to an admin endpoint
  if [[ $LAST_RC -eq 0 ]]; then echo allowed; return; fi
  # GitHub also answers 403 when a client sends too many requests: that proves nothing.
  if printf '%s' "$LAST_OUT" | grep -Eiq 'rate limit|abuse detection|secondary rate'; then
    echo inconclusive
    return
  fi
  if printf '%s' "$LAST_OUT" | grep -Eq 'HTTP 403|HTTP 404|Must have admin rights|Resource not accessible by integration'; then
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
  for t in gh git jq shasum base64 curl openssl; do
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

load_app() { # the app's id and private key: present, private (mode 600 in a mode-700 folder)
  local f dir mode
  for f in "$SECRETS" "$APP_KEY"; do
    dir="$(dirname "$f")"
    [[ -d "$dir" && ! -L "$dir" ]] || die "missing secrets folder $dir"
    mode="$(stat -f %Lp "$dir" 2>/dev/null)" || die "can't read the mode of $dir"
    [[ "$mode" == 700 ]] || die "$dir must be mode 700 (it is $mode)"
    [[ -f "$f" && ! -L "$f" ]] || die "missing file $f"
    mode="$(stat -f %Lp "$f" 2>/dev/null)" || die "can't read the mode of $f"
    [[ "$mode" == 600 ]] || die "$f must be mode 600 (it is $mode)"
  done
  APP_ID="$(sed -n 's/^APP_ID=//p' "$SECRETS" | tail -n 1)"
  [[ "$APP_ID" =~ ^[0-9]{1,12}$ ]] || die "APP_ID is missing or not a number"
  head -n 1 "$APP_KEY" | grep -Eq '^-----BEGIN (RSA )?PRIVATE KEY-----$' || die "$APP_KEY is not a private key (PEM)"
}

b64url() { base64 | tr -d '\n=' | tr '/+' '_-'; }

# A JWT that says "I am app APP_ID" for at most 9 minutes (GitHub allows 10), signed RS256 with the
# app's key. It goes to curl only through a mode-600 header file, never as an argument.
make_jwt() {
  local now h p sig
  now="$(date +%s)" || die "can't read the clock"
  h="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
  p="$(printf '{"iat":%s,"exp":%s,"iss":%s}' "$((now - 60))" "$((now + 540))" "$APP_ID" | b64url)"
  sig="$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$APP_KEY" -binary | b64url)" || die "signing the JWT failed"
  [[ -n "$sig" ]] || die "signing the JWT failed"
  JWT="$h.$p.$sig"
  (
    umask 077
    printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28\n' "$JWT" >"$WORK/jwt.hdr"
  ) || die "writing the JWT header file failed"
}

# A request as the app itself (with the JWT), for what only the app can ask: who it is, where it is
# installed, a token. -q first: no ~/.curlrc. Sets LAST_OUT (the body) and LAST_HTTP; 1 unless 2xx.
jwt_call() { # <method> <path> [json body file]
  local args=(-q -sS --proto "=https" -X "$1" -H @"$WORK/jwt.hdr" -w '\nHTTP %{http_code}')
  if [[ -n "${3:-}" ]]; then args+=(-H "Content-Type: application/json" --data-binary @"$3"); fi
  capture curl "${args[@]}" "https://api.github.com/$2" || true
  LAST_HTTP="$(printf '%s\n' "$LAST_OUT" | tail -n 1 | sed -n 's/^HTTP \([0-9][0-9][0-9]\)$/\1/p')"
  LAST_OUT="$(printf '%s\n' "$LAST_OUT" | sed '$d')"
  [[ "$LAST_HTTP" =~ ^2[0-9][0-9]$ ]]
}

# The key must belong to the owner's app, installed exactly once (on the owner's account), on
# selected repositories only, not suspended, with exactly the four permissions.
need_app_identity() {
  make_jwt
  jwt_call GET app || die "GitHub refused the app's signed request (HTTP ${LAST_HTTP:-none}): $(evidence)"
  local app id owner slug inst got
  app="$LAST_OUT"
  id="$(jq -r .id <<<"$app" 2>/dev/null)" || id=""
  owner="$(jq -r .owner.login <<<"$app" 2>/dev/null)" || owner=""
  slug="$(jq -r .slug <<<"$app" 2>/dev/null)" || slug=""
  [[ "$id" == "$APP_ID" ]] || die "the key belongs to app '$id', not APP_ID $APP_ID"
  [[ "$owner" == "$OWNER" ]] || die "the app belongs to '$owner', not $OWNER"
  [[ "$slug" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "unexpected app name '$slug'"
  APP_SLUG="$slug"
  APP_BOT="${slug}[bot]"
  jwt_call GET "app/installations?per_page=100" || die "can't list the app's installations: $(evidence)"
  inst="$(jq -c --arg o "$OWNER" 'if type == "array" and length == 1 and .[0].account.login == $o then .[0] else empty end' <<<"$LAST_OUT" 2>/dev/null)" || inst=""
  [[ -n "$inst" ]] || die "the app must be installed exactly once, on $OWNER's account"
  [[ "$(jq -r .repository_selection <<<"$inst")" == selected ]] || die "the installation must use \"Only select repositories\""
  [[ "$(jq -r .suspended_at <<<"$inst")" == null ]] || die "the app's installation is suspended"
  got="$(jq -S -c .permissions <<<"$inst")"
  [[ "$got" == "$WANT_PERMS" ]] || die "the app's permissions must be exactly $WANT_PERMS (they are $got)"
  INSTALLATION_ID="$(jq -r .id <<<"$inst")"
  [[ "$INSTALLATION_ID" =~ ^[0-9]+$ ]] || die "unexpected installation id"
}

# Asks GitHub for an installation token and keeps it only if GitHub issued exactly what was asked:
# the four permissions, selected repositories, and (narrowed) only the throwaway. Anything more is
# revoked at once (plan 4.2 step 3).
mint() { # <request json> <narrowed|whole>
  printf '%s\n' "$1" >"$WORK/token-request.json" || die "writing the token request failed"
  jwt_call POST "app/installations/$INSTALLATION_ID/access_tokens" "$WORK/token-request.json" \
    || die "GitHub refused the token request (HTTP ${LAST_HTTP:-none}): $(evidence)"
  local ans="$LAST_OUT" t perms sel repos
  LAST_OUT=""
  t="$(jq -r .token <<<"$ans" 2>/dev/null)" || t=""
  [[ "$t" =~ ^ghs_[A-Za-z0-9]{30,250}$ ]] || die "GitHub's answer holds no installation token"
  TOKEN="$t"
  perms="$(jq -S -c .permissions <<<"$ans" 2>/dev/null)" || perms=error
  sel="$(jq -r .repository_selection <<<"$ans" 2>/dev/null)" || sel=error
  repos="$(jq -c '[.repositories[]?.full_name]' <<<"$ans" 2>/dev/null)" || repos=error
  if [[ "$perms" != "$WANT_PERMS" || "$sel" != selected ]] || [[ "$2" == narrowed && "$repos" != "[\"$REPO\"]" ]]; then
    revoke_token
    die "the token GitHub issued carries more than was asked (permissions $perms, repositories $sel $repos): it was revoked"
  fi
}

mint_token() { mint "{\"repositories\":[\"$REPO_NAME\"],\"permissions\":$WANT_PERMS}" narrowed; }

# Plan item 9: the installation itself, not only each token, reaches only the throwaway (so test A2
# tries a repository the app isn't installed on). Read with a whole-installation token, then revoked.
need_installation_scope() {
  mint '{}' whole
  local got
  got="$(app_gh api installation/repositories --paginate --jq '.repositories[].full_name' 2>/dev/null)" || got=error
  revoke_token
  [[ "$got" == "$REPO" ]] || die "the app must be installed on $REPO only (it reaches: $(printf '%s' "$got" | tr '\n' ' '))"
}

revoke_token() { # the current token stops working at once (DELETE /installation/token)
  [[ -n "$TOKEN" ]] || return 0
  app_gh api -X DELETE installation/token >/dev/null 2>&1 || say "note: revoking a token failed; GitHub expires it within an hour"
  REVOKED_TOKENS="$REVOKED_TOKENS $TOKEN"
  TOKEN=""
}

app_session() { # every command that acts as the app starts here
  load_app
  need_app_identity
  need_installation_scope
  mint_token
}

# Every write is made only after this: the repo must be the throwaway one we created.
assert_throwaway() {
  local info
  info="$(owner_gh api "repos/$REPO" --jq '[.full_name, .owner.login, .description, (.private|tostring)] | @tsv' 2>/dev/null)" \
    || die "can't read $REPO"
  [[ "$info" == "$REPO"$'\t'"$OWNER"$'\t'"$MARKER"$'\t'false ]] \
    || die "$REPO is not the public throwaway repo this script created (description must be: $MARKER)"
}

assert_second() { # writes to the second throwaway are attempts only, and only there
  local info
  info="$(owner_gh api "repos/$REPO2" --jq '[.full_name, .owner.login, .description, (.private|tostring)] | @tsv' 2>/dev/null)" \
    || die "can't read $REPO2"
  [[ "$info" == "$REPO2"$'\t'"$OWNER"$'\t'"$MARKER2"$'\t'false ]] \
    || die "$REPO2 is not the public second throwaway this script created (description must be: $MARKER2)"
}

make_work() {
  WORK="$(mktemp -d "/private/tmp/frg26.XXXXXX")" || die "mktemp failed"
  chmod 700 "$WORK" || die "chmod failed"
  mkdir -m 700 "$WORK/home" "$WORK/gh-app" "$WORK/template" || die "mkdir failed"
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

# A branch's whole protection as GitHub returns it, its url fields removed and keys sorted, or error.
protection_full() { # <branch>
  owner_gh api "repos/$REPO/branches/$1/protection" 2>/dev/null \
    | jq -S -c 'walk(if type == "object" then del(.url) else . end)' 2>/dev/null || echo error
}

# What protection_full reads after protection_json <enforce_admins> is applied (read from the
# throwaway on 2026-10-31). GitHub leaves out required_status_checks and restrictions when null.
want_protection() { # <enforce_admins true|false>
  printf '{"allow_deletions":{"enabled":false},"allow_force_pushes":{"enabled":false},"allow_fork_syncing":{"enabled":false},"block_creations":{"enabled":false},"enforce_admins":{"enabled":%s},"lock_branch":{"enabled":false},"required_conversation_resolution":{"enabled":false},"required_linear_history":{"enabled":false},"required_pull_request_reviews":{"dismiss_stale_reviews":true,"require_code_owner_reviews":true,"require_last_push_approval":true,"required_approving_review_count":1},"required_signatures":{"enabled":false}}\n' "$1"
}

ruleset_summary() { # one line describing the only ruleset, or error
  local id
  id="$(owner_gh api "repos/$REPO/rulesets" --jq '.[0].id' 2>/dev/null)" || { echo error; return; }
  [[ "$id" =~ ^[0-9]+$ ]] || { echo error; return; }
  owner_gh api "repos/$REPO/rulesets/$id" --jq '[.enforcement, .target, (.conditions.ref_name.include | join(",")), (.conditions.ref_name.exclude | length | tostring), ([.rules[] | if .type == "update" then "update:\(.parameters.update_allows_fetch_and_merge)" else .type end] | sort | join(",")), ([.bypass_actors[] | "\(.actor_type):\(.actor_id):\(.bypass_mode)"] | join(","))] | join(" ")' 2>/dev/null || echo error
}

want_ruleset() { # the two bypass choices this script may have installed
  local uid
  uid="$(owner_uid)" || return 1 # owner_uid's die ends only this subshell (review round 10)
  printf 'active branch refs/heads/main 0 deletion,non_fast_forward,update:false User:%s:always\n' "$uid"
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
      # All of it, not only those fields: an extra required check or restriction would make a
      # refusal pass for the wrong reason, and unprotect would delete what protect didn't apply.
      got="$(protection_full dev)"
      [[ "$got" == "$(want_protection true)" ]] || die "dev protection is not exactly what protect applies: $got"
      got="$(protection_full main)"
      [[ "$got" == "$(want_protection false)" ]] || die "main protection is not exactly what protect applies: $got"
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

# The second throwaway (test A2): public, the app not installed, one branch to open a PR from.
cmd_create_second() {
  need_owner
  if owner_gh api "repos/$REPO2" >/dev/null 2>&1; then
    die "$REPO2 already exists; delete it in the browser first if you want a fresh one"
  fi
  owner_gh repo create "$REPO2" --public --description "$MARKER2" --add-readme >/dev/null || die "gh repo create failed"
  assert_second
  local first sha
  first="$(owner_gh api "repos/$REPO2" --jq .default_branch)" || die "can't read the first branch's name"
  if [[ "$first" != main ]]; then
    owner_gh api -X POST "repos/$REPO2/branches/$first/rename" -f new_name=main >/dev/null \
      || die "renaming the first branch '$first' to main failed"
  fi
  sha="$(owner_gh api "repos/$REPO2/branches/main" --jq .commit.sha)" || die "can't read main"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "unexpected main sha"
  owner_gh api -X PUT "repos/$REPO2/contents/a2.txt" -f message="FRG-26 A2 branch" \
    -f content="$(printf 'FRG-26 A2\n' | base64 | tr -d '\n')" -f branch=main >/dev/null || die "adding a2.txt failed"
  sha="$(owner_gh api "repos/$REPO2/branches/main" --jq .commit.sha)" || die "can't read main"
  owner_gh api -X POST "repos/$REPO2/git/refs" -f ref="refs/heads/$A2_BRANCH" -f sha="$sha" >/dev/null || die "creating $A2_BRANCH failed"
  say "created $REPO2 (public; the app is not installed here), branch $A2_BRANCH"
}

repo_settings() {
  # Auto-merge is on, so B11 tests whether an enabled auto-merge waits for the owner's approval.
  owner_gh api -X PATCH "repos/$REPO" -f default_branch="$DEFAULT_BRANCH" -F allow_auto_merge=true \
    -F allow_merge_commit=true -F allow_squash_merge=true -f description="$MARKER" >/dev/null \
    || die "setting the repository options failed"
}

# The app's API allowance, read-only (GitHub doesn't count this request against it). Sets
# RATE_LINE (for people), RATE_LEFT (GraphQL points remaining) and RATE_REST (REST requests
# remaining); 1 if any of them can't be read.
app_rate() {
  RATE_LINE="" RATE_LEFT="" RATE_REST=""
  capture app_gh api rate_limit || return 1
  RATE_LINE="$(printf '%s' "$LAST_OUT" | jq -r '.resources | "graphql limit=\(.graphql.limit) used=\(.graphql.used) remaining=\(.graphql.remaining) resets=\(.graphql.reset | todate) / rest limit=\(.core.limit) used=\(.core.used) remaining=\(.core.remaining)"' 2>/dev/null)" || return 1
  RATE_LEFT="$(printf '%s' "$LAST_OUT" | jq -r '.resources.graphql.remaining' 2>/dev/null)" || return 1
  RATE_REST="$(printf '%s' "$LAST_OUT" | jq -r '.resources.core.remaining' 2>/dev/null)" || return 1
  [[ "$RATE_LEFT" =~ ^[0-9]+$ && "$RATE_REST" =~ ^[0-9]+$ ]]
}

# A phase that ran out of allowance halfway would stop on a rate limit, so it doesn't start.
need_allowance() {
  app_rate || die "could not read the app's API allowance: $(evidence)"
  say "app allowance: $RATE_LINE"
  [[ "$RATE_LEFT" -ge $MIN_GRAPHQL ]] \
    || die "the app has only $RATE_LEFT GraphQL points left (a phase needs about $MIN_GRAPHQL): $RATE_LINE. Run this step again after that reset time."
  [[ "$RATE_REST" -ge $MIN_REST ]] \
    || die "the app has only $RATE_REST REST requests left (a phase needs about $MIN_REST): $RATE_LINE. Run this step again in an hour."
}

cmd_rate() {
  app_session
  app_rate || die "could not read the app's API allowance: $(evidence)"
  say "APP-RATE $RATE_LINE"
}

# The same gate a phase applies, on its own: fails (status 2) unless the app has enough left, so a
# handoff can stop before anything is changed.
cmd_allowance() {
  app_session
  need_allowance
}

# A1: the app, its installation and its token carry exactly the throwaway and the four permissions
# (app_session stops otherwise). Read-only.
cmd_check_app() {
  need_owner
  assert_throwaway
  app_session
  say "app=$APP_SLUG id=$APP_ID installation=$INSTALLATION_ID permissions=$WANT_PERMS repositories=$REPO (installation and token both checked)"
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
  open_prs="$(owner_gh api --paginate "repos/$REPO/pulls?state=open&per_page=100" --jq '.[].number')" || die "can't list open PRs"
  for n in $open_prs; do
    [[ "$n" =~ ^[0-9]+$ ]] || die "unexpected PR number '$n'"
    owner_gh pr close "$n" --repo "$REPO" >/dev/null 2>&1 || die "closing PR #$n failed"
  done
  # Read again right before each rewrite, and rewrite only an unprotected branch (or recreate a
  # missing one): an unreadable or newly protected branch stops the reset (review round 11).
  for b in main dev side; do
    s="$(branch_state "$b")"
    case "$s" in
      missing)
        owner_gh api -X POST "repos/$REPO/git/refs" -f ref="refs/heads/$b" -f sha="$base" >/dev/null \
          || die "recreating $b failed"
        ;;
      unprotected)
        owner_gh api -X PATCH "repos/$REPO/git/refs/heads/$b" -f sha="$base" -F force=true >/dev/null \
          || die "resetting $b failed"
        ;;
      *) die "reset stopped before rewriting $b: it reads $s now" ;;
    esac
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

# The reverse of protect, only from exactly the state protect leaves (no ruleset), so a phase
# open can run again (owner, 2026-10-31: a fresh open phase on the reviewed commit).
cmd_unprotect() {
  need_owner
  assert_throwaway
  verify_phase protected
  owner_gh api -X DELETE "repos/$REPO/branches/dev/protection" >/dev/null || die "unprotecting dev failed"
  owner_gh api -X DELETE "repos/$REPO/branches/main/protection" >/dev/null || die "unprotecting main failed"
  verify_phase open
  say "dev and main unprotected; no ruleset"
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
  # The ruleset phase that follows needs the app's allowance; without it, the ruleset isn't added
  # (it would sit there untested). Owner, review round 6: executable and fail-closed.
  app_session
  need_allowance
  local uid
  uid="$(owner_uid)" || die "can't read the owner's user id, so no ruleset was requested"
  ruleset_json User "$uid" >"$WORK/ruleset-user.json"
  ruleset_json RepositoryRole 5 >"$WORK/ruleset-admin.json"
  if capture owner_gh api -X POST "repos/$REPO/rulesets" --input "$WORK/ruleset-user.json"; then
    say "ruleset created with bypass: the owner (User $uid)"
  else
    # Fall back only on a clear rejection that changed nothing: GitHub answered 422 (invalid) and
    # there is still no ruleset. A lost answer after GitHub created it must not lead to a second.
    local ev n
    ev="$(evidence)"
    n="$(ruleset_count)"
    if ! printf '%s' "$LAST_OUT" | grep -q 'HTTP 422' || [[ "$n" != 0 ]]; then
      die "the ruleset request failed without a clear rejection, or a ruleset exists now (rulesets: $n): check $REPO's rulesets on GitHub before running this again: $ev"
    fi
    say "GitHub refused a User bypass: $ev"
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
  app_git -C "$CLONE" fetch -q --prune origin || die "fetch failed"
  app_git -C "$CLONE" checkout -q -B "$2" "origin/$1" || die "checkout of origin/$1 failed"
}

add_commit() { # <path> <content>
  mkdir -p "$CLONE/$(dirname "$1")"
  printf '%s\n' "$2" >"$CLONE/$1"
  app_git -C "$CLONE" add -- "$1" || die "git add failed"
  app_git -C "$CLONE" commit -q -m "FRG-26 test: $1" || die "git commit failed"
}

push_branch() { # <branch> — push HEAD as a feature branch (always allowed)
  capture app_git -C "$CLONE" push -q origin "HEAD:refs/heads/$1" || die "pushing $1 failed: $(evidence)"
}

app_pr() { # <base> <head> <id> — sets LAST_PR, or returns 1
  capture app_gh pr create --repo "$REPO" --base "$1" --head "$2" --title "FRG-26 $3 ($PHASE)" \
    --body "FRG-26 throwaway test $3, phase $PHASE." || return 1
  LAST_PR="$(printf '%s' "$LAST_OUT" | tail -n 1)"
  LAST_PR="${LAST_PR##*/}"
  [[ "$LAST_PR" =~ ^[0-9]+$ ]]
}

feature_pr() { # <id> [base] — a fresh feature branch with one new file, and a PR from the app
  BR="frg26/$PHASE/$1-$(stamp)"
  fresh_from dev "$BR"
  add_commit "tests/$PHASE-$1-$(stamp).txt" "FRG-26 $1 $PHASE"
  push_branch "$BR"
  app_pr "${2:-dev}" "$BR" "$1" || die "creating the PR for $1 failed: $(evidence)"
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

# The app tries to merge. Allowed = GitHub then reports the PR MERGED. Refused = still open,
# free of conflicts, and GitHub reports it BLOCKED (by protection or a ruleset). Anything else is
# inconclusive. When the test expects "allowed", transient refusals are retried, so a refusal is
# never reported for a merge GitHub would have allowed.
app_merge() { # <id> <pr> <merge flags…>
  local id="$1" pr="$2" _ facts
  shift 2
  for _ in 1 2 3; do
    if ! wait_settled "$pr"; then OBS=inconclusive; LAST_OUT="mergeability never settled [$(merge_facts "$pr")]"; return; fi
    capture app_gh pr merge "$pr" --repo "$REPO" "$@" || true
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

# A test PR left open could still merge (B11 arms auto-merge), so a PR not confirmed closed or
# merged afterwards is a failure: the phase stops, and the owner is told which PR to close.
close_if_open() { # <pr> — tidy up after a refused attempt
  local st
  st="$(pr_view "$1" state .state)" || st=""
  if [[ "$st" == OPEN ]]; then
    owner_gh pr close "$1" --repo "$REPO" >/dev/null 2>&1 || true
    st="$(pr_view "$1" state .state)" || st=""
  fi
  if [[ "$st" == CLOSED || "$st" == MERGED ]]; then return 0; fi
  FAILS=$((FAILS + 1))
  say "CLEANUP FAIL PR #$1 may still be open (state ${st:-unreadable}): close it on GitHub, in $REPO, before another phase"
  return 1
}

# When a phase stops or ends, every test PR still open in the throwaway repository is closed,
# found by its "FRG-26 " title rather than by number: a test can stop before it knows its PR's
# number (dev_ahead, or a PR URL that couldn't be read). Any PR it can't confirm closed, or a
# list it can't read, is a failure.
sweep_prs() {
  local open pr
  # Every page, so no test PR is missed however many PRs are open (review round 9).
  if ! open="$(owner_gh api --paginate "repos/$REPO/pulls?state=open&per_page=100" \
    --jq '.[] | select(.title | startswith("FRG-26 ")) | .number' 2>/dev/null)"; then
    FAILS=$((FAILS + 1))
    say "CLEANUP FAIL could not list the open PRs in $REPO: close any \"FRG-26 \" test PR on GitHub before another phase"
    return 1
  fi
  for pr in $open; do
    if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
      FAILS=$((FAILS + 1))
      say "CLEANUP FAIL unexpected PR list entry; close any \"FRG-26 \" test PR in $REPO on GitHub before another phase"
      return 1
    fi
    if close_if_open "$pr"; then say "CLEANUP closed test PR #$pr, left open by a test"; fi
  done
}

dev_ahead() { # <id> — app PR into dev, owner approves, app merges (the B16 control)
  feature_pr "$1"
  owner_approve "$LAST_PR"
  app_merge B16 "$LAST_PR" --squash
}

direct_push() { # <id> <branch> <path> <content> — a commit on top of <branch>, pushed to it
  fresh_from "$2" "$1-$(stamp)"
  add_commit "$3" "$4"
  capture app_git -C "$CLONE" push origin "HEAD:refs/heads/$2" || true
  record "$1" "$(classify_push)" "$(evidence)"
}

t_B1() { direct_push B1 dev "tests/$PHASE-B1-$(stamp).txt" "direct push to dev"; }

t_B2() { # the app names itself code owner, straight on dev
  fresh_from dev "b2-$(stamp)"
  printf '* @%s\n# B2 %s %s\n' "$APP_BOT" "$PHASE" "$(stamp)" >"$CLONE/.github/CODEOWNERS"
  app_git -C "$CLONE" commit -q -am "FRG-26 test: the app names itself code owner" || die "commit failed"
  capture app_git -C "$CLONE" push origin HEAD:refs/heads/dev || true
  record B2 "$(classify_push)" "$(evidence)"
}

codeowners_pr() { # <id> <where: github|root|docs> — a PR that makes the app the code owner
  BR="frg26/$PHASE/$1-$(stamp)"
  fresh_from dev "$BR"
  local line
  line="$(printf '* @%s\n# %s %s %s' "$APP_BOT" "$1" "$PHASE" "$(stamp)")"
  case "$2" in
    github)
      mkdir -p "$CLONE/.github"
      printf '%s\n' "$line" >"$CLONE/.github/CODEOWNERS"
      app_git -C "$CLONE" add .github/CODEOWNERS || die "git add failed"
      ;;
    root | docs)
      # GitHub reads .github/CODEOWNERS first, then the root, then docs/: remove the earlier ones.
      app_git -C "$CLONE" rm -q --ignore-unmatch .github/CODEOWNERS || die "git rm failed"
      if [[ "$2" == docs ]]; then
        app_git -C "$CLONE" rm -q --ignore-unmatch CODEOWNERS || die "git rm failed"
        printf '%s\n' "$line" >"$CLONE/docs/CODEOWNERS"
        app_git -C "$CLONE" add docs/CODEOWNERS || die "git add failed"
      else
        printf '%s\n' "$line" >"$CLONE/CODEOWNERS"
        app_git -C "$CLONE" add CODEOWNERS || die "git add failed"
      fi
      ;;
  esac
  app_git -C "$CLONE" commit -q -m "FRG-26 test $1: CODEOWNERS ($2) names the app" || die "commit failed"
  push_branch "$BR"
  app_pr dev "$BR" "$1" || die "creating the PR for $1 failed: $(evidence)"
  local pr="$LAST_PR"
  app_merge "$1" "$pr" --squash
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
  capture app_gh pr review "$pr" --repo "$REPO" --approve --body "self-approval attempt" || true
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
  app_merge B6 "$pr" --squash
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
  app_merge B7 "$pr" --squash
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
  if ! capture app_gh api -X PUT "repos/$REPO/pulls/$pr/update-branch"; then
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
  app_merge B8 "$pr" --squash
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
  # REST, not `gh pr edit`: that also reads fields beyond the app's four permissions (it needed
  # read:org with the helper's token). Re-aiming is setup, not the bypass under test (the merge
  # is): any failure proves nothing.
  if ! capture app_gh api -X PATCH "repos/$REPO/pulls/$pr" -f base=dev; then
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
  app_merge B9 "$pr" --squash
  record B9 "$OBS" "$(evidence)"
  close_if_open "$pr"
}

t_B10() {
  feature_pr B10
  local pr="$LAST_PR"
  app_merge B10 "$pr" --squash --admin
  record B10 "$OBS" "$(evidence)"
  close_if_open "$pr"
}

# B11: auto-merge is enabled on the repository. In the open phase, the app's auto-merge must work
# (the PR merges, or auto-merge is armed). In the protected phases the app arms it for
# its unapproved PR, which must not merge; then, as a control, the owner approves and the PR
# must merge by itself (proving auto-merge was really armed). An unreadable state is
# inconclusive.
t_B11() {
  feature_pr B11
  local pr="$LAST_PR" armed st
  wait_settled "$pr" || { setup_fail B11 "PR never became mergeable"; close_if_open "$pr"; return; }
  capture app_gh pr merge "$pr" --repo "$REPO" --squash --auto || true
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
    capture app_gh api "${c[@]}" || true
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
  local uid
  uid="$(owner_uid)" || { setup_fail B13 "could not read the owner's user id"; return; }
  ruleset_json User "$uid" >"$WORK/app-ruleset-user.json"
  ruleset_json RepositoryRole 5 >"$WORK/app-ruleset-admin.json"
  admin_attempts B13 -X POST "repos/$REPO/rulesets" --input "$WORK/app-ruleset-user.json" ";;" \
    -X POST "repos/$REPO/rulesets" --input "$WORK/app-ruleset-admin.json" ";;" \
    -X PATCH "repos/$REPO" -f description="changed by the app"
  # Nothing is put back (the stop rule): a refused app changed nothing, and whatever got
  # through stays for the owner to see. A ruleset the app added makes every later verify_phase,
  # ruleset and reset refuse (each needs an exact ruleset count, and the attempts stop there, before
  # the description). A changed description makes every later command's assert_throwaway refuse.
  # Either way nothing runs again until the owner puts it right.
}

force_push() { # <id> <branch> — an unrelated history pushed over <branch>
  app_git -C "$CLONE" checkout -q --orphan "$1-$(stamp)" || die "checkout failed"
  app_git -C "$CLONE" rm -rq --cached . >/dev/null 2>&1 || true
  add_commit "tests/orphan-$1-$(stamp).txt" "unrelated history"
  capture app_git -C "$CLONE" push --force origin "HEAD:refs/heads/$2" || true
  record "$1" "$(classify_push)" "$(evidence)"
}

delete_branch() { # <id> <branch>
  capture app_git -C "$CLONE" push origin ":refs/heads/$2" || true
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
  app_pr main dev M2 || { setup_fail M2 "could not open dev->main ($(evidence))"; return; }
  local pr="$LAST_PR"
  owner_approve "$pr"
  app_merge M2 "$pr" --merge
  record M2 "$OBS" "$(evidence)"
  close_if_open "$pr"
}

t_M3() {
  dev_ahead M3-advance
  [[ "$OBS" == allowed ]] || { setup_fail M3 "could not advance dev ($(evidence))"; return; }
  app_pr main dev M3 || { setup_fail M3 "could not open dev->main ($(evidence))"; return; }
  local pr="$LAST_PR"
  app_merge M3 "$pr" --merge --admin
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
  # (so they are valid requests): one switches it off; the other adds the app to the bypass list as
  # an Integration actor (GitHub Apps may be bypass actors: Confirmed, docs), whichever form the
  # owner's bypass took.
  local rs
  rs="$(owner_gh api "repos/$REPO/rulesets/$id" 2>/dev/null)" || { setup_fail M4 "could not read the ruleset"; return; }
  printf '%s' "$rs" | jq '{name, target, enforcement: "disabled", conditions, rules, bypass_actors}' >"$WORK/ruleset-off.json" \
    || { setup_fail M4 "could not build the switch-off payload"; return; }
  [[ "$APP_ID" =~ ^[0-9]+$ ]] || { setup_fail M4 "no app id"; return; }
  printf '%s' "$rs" | jq --argjson aid "$APP_ID" '{name, target, enforcement, conditions, rules, bypass_actors: (.bypass_actors + [{actor_id: $aid, actor_type: "Integration", bypass_mode: "always"}])}' \
    >"$WORK/ruleset-app.json" || { setup_fail M4 "could not build the app-bypass payload"; return; }
  admin_attempts M4 -X PUT "repos/$REPO/branches/main/protection" --input "$WORK/weak.json" ";;" \
    -X DELETE "repos/$REPO/branches/main/protection" ";;" \
    -X PUT "repos/$REPO/rulesets/$id" --input "$WORK/ruleset-off.json" ";;" \
    -X PUT "repos/$REPO/rulesets/$id" --input "$WORK/ruleset-app.json" ";;" \
    -X DELETE "repos/$REPO/rulesets/$id"
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

# --- Kind P: permission tests (plan section 6, revised 2026-11-01) -----------------------------
# GitHub forbids these from the outset, so they can't "get through first". Each attempt must be
# refused for a permission reason, and its control must succeed: the same request made by a
# credential that may make it (a no-op where it writes), or the nearest action the app may take.
# A refusal with a failed control proves nothing (the request may have been malformed): a FAIL.

readonly P_TEST_ORDER="S1 A6 A8 A5 A3 A2 A11 A12"

record_p() { # <id> <attempt allowed|refused|inconclusive> <control ok|failed> <evidence>
  local verdict=PASS
  if [[ "$2" != refused || "$3" != ok ]]; then
    verdict=FAIL
    FAILS=$((FAILS + 1))
  fi
  say "RESULT $1 permissions $verdict attempt=$2 control=$3 :: $4"
}

reading() { # <id> <text> — a finding for the owner, never a pass or a fail (A11, A12)
  say "READING $1 $2"
}

classify_push_perm() { # after capture of an app git push: refused only for a permission reason
  if [[ $LAST_RC -eq 0 ]]; then echo allowed; return; fi
  # shellcheck disable=SC2016 # the backticks are GitHub's own words, not a command
  if printf '%s' "$LAST_OUT" | grep -Eiq 'Permission to [^ ]+ denied|Write access to repository not granted|without `workflows` permission'; then
    echo refused
  else
    echo inconclusive
  fi
}

http_of() { # the HTTP status gh reported in LAST_OUT, or "allowed" after a success
  if [[ $LAST_RC -eq 0 ]]; then echo allowed; return; fi
  printf '%s' "$LAST_OUT" | grep -Eo 'HTTP [0-9]{3}' | tail -n 1 || echo "failed: $(evidence)"
}

# Attempts, in order; the first one not refused ends the list (the stop rule). Sets OBS and EV.
p_attempts() { # <kind api|push> <args…> separated by ";;"
  local kind="$1" c
  shift
  OBS=refused EV=""
  while [[ $# -gt 0 && "$OBS" == refused ]]; do
    c=()
    while [[ $# -gt 0 && "$1" != ";;" ]]; do c+=("$1"); shift; done
    [[ $# -gt 0 ]] && shift
    capture "${c[@]}" || true
    if [[ "$kind" == push ]]; then OBS="$(classify_push_perm)"; else OBS="$(classify_api)"; fi
    EV="$EV ${c[*]:0:4}: $(evidence) |"
  done
}

# Controls, all of which must succeed. Sets CTL (ok|failed) and adds to EV.
p_controls() { # <args…> separated by ";;"
  local c
  CTL=ok
  while [[ $# -gt 0 ]]; do
    c=()
    while [[ $# -gt 0 && "$1" != ";;" ]]; do c+=("$1"); shift; done
    [[ $# -gt 0 ]] && shift
    if ! capture "${c[@]}"; then CTL=failed; EV="$EV control ${c[*]:0:4}: $(evidence) |"; fi
  done
}

# S1 (plan 4.4): read-only, as the owner: no repository secrets; the workflow token reads only;
# Actions may not approve PRs.
t_S1() {
  local n d a
  n="$(owner_gh api "repos/$REPO/actions/secrets" --jq .total_count 2>/dev/null)" || n=error
  d="$(owner_gh api "repos/$REPO/actions/permissions/workflow" --jq .default_workflow_permissions 2>/dev/null)" || d=error
  a="$(owner_gh api "repos/$REPO/actions/permissions/workflow" --jq .can_approve_pull_request_reviews 2>/dev/null)" || a=error
  if [[ "$n" == 0 && "$d" == read && "$a" == false ]]; then
    say "RESULT S1 permissions PASS :: repository secrets $n, workflow token $d, Actions may approve PRs: $a"
  else
    FAILS=$((FAILS + 1))
    say "RESULT S1 permissions FAIL :: repository secrets $n (want 0), workflow token $d (want read), Actions may approve PRs: $a (want false)"
  fi
}

# A6: the repository's settings (a no-op write: the description it already has) and the app's own
# installation (adding the repository it already has). Control: the owner's same no-op write.
t_A6() {
  local rid
  rid="$(owner_gh api "repos/$REPO" --jq .id 2>/dev/null)" || rid=""
  [[ "$rid" =~ ^[0-9]+$ ]] || { setup_fail_p A6 "could not read the repository id"; return; }
  p_attempts api app_gh api -X PATCH "repos/$REPO" -f description="$MARKER" ";;" \
    app_gh api -X PUT "user/installations/$INSTALLATION_ID/repositories/$rid"
  [[ "$OBS" == refused ]] || { record_p A6 "$OBS" "not run" "$EV"; return; }
  p_controls owner_gh api -X PATCH "repos/$REPO" -f description="$MARKER"
  record_p A6 "$OBS" "$CTL" "$EV (the installation attempt has no control: only the owner's browser changes it)"
}

# A8: managing secrets, variables, deploy keys, webhooks, collaborators. Control: the owner reads
# the same lists (no secret is created, nothing is written).
t_A8() {
  p_attempts api app_gh api "repos/$REPO/actions/secrets" ";;" \
    app_gh api "repos/$REPO/actions/secrets/public-key" ";;" \
    app_gh api "repos/$REPO/actions/variables" ";;" \
    app_gh api "repos/$REPO/keys" ";;" \
    app_gh api "repos/$REPO/hooks" ";;" \
    app_gh api -X PUT "repos/$REPO/collaborators/$OWNER" -f permission=push
  [[ "$OBS" == refused ]] || { record_p A8 "$OBS" "not run" "$EV"; return; }
  p_controls owner_gh api "repos/$REPO/actions/secrets" ";;" owner_gh api "repos/$REPO/actions/variables" ";;" \
    owner_gh api "repos/$REPO/keys" ";;" owner_gh api "repos/$REPO/hooks"
  record_p A8 "$OBS" "$CTL" "$EV"
}

# A5 (plan 4.3): a revoked token stops working at once. Control: the same read with that token
# before it was revoked. The session's own token is put back afterwards.
t_A5() {
  local session="$TOKEN"
  mint_token
  OBS=inconclusive CTL=failed EV=""
  if capture app_gh api "repos/$REPO" --jq .full_name && [[ "$LAST_OUT" == "$REPO" ]]; then CTL=ok; fi
  EV="before revoking: $(evidence) |"
  local second="$TOKEN"
  revoke_token
  TOKEN="$second"
  capture app_gh api "repos/$REPO" --jq .full_name || true
  if [[ $LAST_RC -ne 0 ]] && printf '%s' "$LAST_OUT" | grep -Eq 'HTTP 401|Bad credentials'; then OBS=refused
  elif [[ $LAST_RC -eq 0 ]]; then OBS=allowed
  fi
  EV="$EV after revoking: $(evidence)"
  TOKEN="$session"
  record_p A5 "$OBS" "$CTL" "$EV"
}

# A3: a commit adding a workflow file, on a feature branch. Control: the same push with a plain file.
t_A3() {
  fresh_from dev "a3-wf-$(stamp)"
  add_commit ".github/workflows/frg26-a3-$(stamp).yml" "name: frg26 a3"
  p_attempts push app_git -C "$CLONE" push origin "HEAD:refs/heads/frg26/permissions/A3-wf-$(stamp)"
  [[ "$OBS" == refused ]] || { record_p A3 "$OBS" "not run" "$EV"; return; }
  fresh_from dev "a3-plain-$(stamp)"
  add_commit "tests/permissions-A3-$(stamp).txt" "FRG-26 A3 control"
  p_controls app_git -C "$CLONE" push origin "HEAD:refs/heads/frg26/permissions/A3-plain-$(stamp)"
  record_p A3 "$OBS" "$CTL" "$EV"
}

# A2 (plan 4.1, item 9): writes to a public repository the app is not installed on: a push, an
# issue, a PR (from a branch the owner made there). Control: the same three on the throwaway.
t_A2() {
  fresh_from dev "a2-$(stamp)"
  add_commit "tests/permissions-A2-$(stamp).txt" "FRG-26 A2"
  # The push is judged by git's own words, the two API calls by GitHub's status.
  p_attempts push app_git -C "$CLONE" push "https://github.com/$REPO2.git" "HEAD:refs/heads/frg26-a2-$(stamp)"
  [[ "$OBS" == refused ]] || { record_p A2 "$OBS" "not run" "$EV"; return; }
  local ev="$EV"
  p_attempts api app_gh api -X POST "repos/$REPO2/issues" -f title="FRG-26 A2 ($(stamp))" ";;" \
    app_gh api -X POST "repos/$REPO2/pulls" -f title="FRG-26 A2 ($(stamp))" -f head="$A2_BRANCH" -f base=main
  EV="$ev$EV"
  [[ "$OBS" == refused ]] || { record_p A2 "$OBS" "not run" "$EV"; return; }
  p_controls app_git -C "$CLONE" push origin "HEAD:refs/heads/frg26/permissions/A2-$(stamp)" ";;" \
    app_gh api -X POST "repos/$REPO/issues" -f title="FRG-26 A2 control ($(stamp))" ";;" \
    app_gh api -X POST "repos/$REPO/pulls" -f title="FRG-26 A2 control ($(stamp))" -f head="frg26/permissions/A2-$(stamp)" -f base=dev
  record_p A2 "$OBS" "$CTL" "$EV"
}

# A11: whether CI results on a public repo can be read with no Checks/Actions permission. A reading
# for the owner (plan 4.1): if one can't be read, the owner decides before anything is added.
t_A11() {
  local p
  for p in commits/main/check-runs commits/main/status "actions/runs?per_page=1"; do
    capture app_gh api "repos/$REPO/$p" || true
    reading A11 "${p%%\?*}: $(http_of)" | sed 's#commits/main/##'
  done
}

try_reading() { # <id> <label> <command…> — "works" or "fails" with GitHub's words
  local id="$1" label="$2"
  shift 2
  if capture "$@"; then reading "$id" "$label: works"; else reading "$id" "$label: fails: $(evidence)"; fi
}

# A12: the gh commands FORGE uses, with the app's token. Readings, not results.
t_A12() {
  local n
  try_reading A12 "gh issue create" app_gh issue create --repo "$REPO" --title "FRG-26 A12 ($(stamp))" --body "FRG-26 throwaway test A12."
  n="${LAST_OUT##*/}"
  if [[ $LAST_RC -eq 0 && "$n" =~ ^[0-9]+$ ]]; then
    try_reading A12 "gh issue comment" app_gh issue comment "$n" --repo "$REPO" --body "FRG-26 A12 comment."
    try_reading A12 "gh issue view" app_gh issue view "$n" --repo "$REPO" --json title --jq .title
  fi
  try_reading A12 "gh issue list" app_gh issue list --repo "$REPO" --limit 1
  try_reading A12 "gh pr list" app_gh pr list --repo "$REPO" --limit 1
  try_reading A12 "gh run list" app_gh run list --repo "$REPO" --limit 1
  try_reading A12 "gh api (read)" app_gh api "repos/$REPO" --jq .full_name
}

setup_fail_p() { # <id> <what failed>
  FAILS=$((FAILS + 1))
  say "RESULT $1 permissions FAIL attempt=setup-failed :: $2"
}

# Test issues ("FRG-26 " titles) are closed in both throwaway repos when the run ends.
sweep_issues() {
  local r open n
  for r in "$REPO" "$REPO2"; do
    if ! open="$(owner_gh api --paginate "repos/$r/issues?state=open&per_page=100" \
      --jq '.[] | select(.pull_request == null) | select(.title | startswith("FRG-26 ")) | .number' 2>/dev/null)"; then
      FAILS=$((FAILS + 1))
      say "CLEANUP FAIL could not list the open issues in $r: close any \"FRG-26 \" test issue on GitHub"
      continue
    fi
    for n in $open; do
      [[ "$n" =~ ^[0-9]+$ ]] || continue
      owner_gh issue close "$n" --repo "$r" >/dev/null 2>&1 || { FAILS=$((FAILS + 1)); say "CLEANUP FAIL issue #$n in $r may still be open"; }
    done
  done
}

cmd_ptests() {
  need_owner
  assert_throwaway
  assert_second
  app_session
  need_allowance
  PHASE=permissions
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  CLONE="$WORK/clone"
  app_git clone -q --template="$WORK/template" "https://github.com/$REPO.git" "$CLONE" || die "clone failed"
  say "== FRG-26 permission tests (kind P), app $APP_BOT, $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
  local id
  SWEEP_ON_EXIT=1
  for id in $P_TEST_ORDER; do
    "t_$id"
    if [[ $FAILS -ne 0 ]]; then
      SWEEP_ON_EXIT=""
      sweep_prs
      sweep_issues
      say "PERMISSION TESTS: STOPPED after $id (a failed test stops the run; only test PRs and issues were closed after it)"
      exit 1
    fi
  done
  SWEEP_ON_EXIT=""
  sweep_prs
  sweep_issues
  if [[ $FAILS -ne 0 ]]; then
    say "PERMISSION TESTS: FAILED at the final cleanup"
    exit 1
  fi
  say "PERMISSION TESTS: ALL PASS"
  exit 0
}

# --- S2: an Environment keeps its secret from the app (plan 4.4, revised 2026-11-01) ------------
# On the throwaway only, in the open phase (no protection, so the app may push main). The value is
# a dummy, never a real secret; the workflow prints only its length.

readonly ENV_NAME=frg26-test
readonly DUMMY_NAME=FRG26_DUMMY
readonly DUMMY_VALUE=frg26-dummy-not-a-secret
readonly S2_WORKFLOW=.github/workflows/frg26-s2.yml

s2_workflow() {
  cat <<'EOF'
name: frg26-s2
on:
  push:
    branches: [main, 'frg26-s2-*']
permissions: {}
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: frg26-test
    steps:
      - name: Report the dummy value's length only
        env:
          V: ${{ secrets.FRG26_DUMMY }}
        run: echo "FRG26-S2 value length ${#V}"
EOF
}

# The Environment exactly as env-setup makes it: the owner the only reviewer, self-review
# prevented, only the branch main may deploy.
env_summary() {
  local e p
  e="$(owner_gh api "repos/$REPO/environments/$ENV_NAME" --jq '[([.protection_rules[] | select(.type == "required_reviewers") | .prevent_self_review | tostring] | join(",")), ([.protection_rules[] | select(.type == "required_reviewers") | .reviewers[] | "\(.type):\(.reviewer.login)"] | join(",")), (.deployment_branch_policy.protected_branches | tostring), (.deployment_branch_policy.custom_branch_policies | tostring)] | join(" ")' 2>/dev/null)" || { echo error; return; }
  p="$(owner_gh api "repos/$REPO/environments/$ENV_NAME/deployment-branch-policies" --jq '[.branch_policies[] | "\(.type // "branch"):\(.name)"] | join(",")' 2>/dev/null)" || { echo error; return; }
  printf '%s %s\n' "$e" "$p"
}

want_env() { printf 'true User:%s false true branch:main\n' "$OWNER"; }

cmd_env_setup() {
  need_owner
  assert_throwaway
  verify_phase open
  local uid
  uid="$(owner_uid)" || die "can't read the owner's user id, so no Environment was made"
  printf '{"wait_timer":0,"prevent_self_review":true,"reviewers":[{"type":"User","id":%s}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}\n' "$uid" >"$WORK/env.json"
  owner_gh api -X PUT "repos/$REPO/environments/$ENV_NAME" --input "$WORK/env.json" >/dev/null || die "making the Environment failed"
  if ! owner_gh api "repos/$REPO/environments/$ENV_NAME/deployment-branch-policies" --jq '.branch_policies[].name' 2>/dev/null | grep -Fxq main; then
    owner_gh api -X POST "repos/$REPO/environments/$ENV_NAME/deployment-branch-policies" -f name=main -f type=branch >/dev/null \
      || die "limiting the Environment to main failed"
  fi
  # A dummy value, not a secret: gh encrypts it for GitHub. Only its length is ever printed.
  owner_gh secret set "$DUMMY_NAME" --env "$ENV_NAME" --repo "$REPO" --body "$DUMMY_VALUE" >/dev/null \
    || die "storing the dummy value failed"
  local got
  got="$(env_summary)"
  [[ "$got" == "$(want_env)" ]] || die "the Environment is '$got', expected '$(want_env)'"
  say "Environment $ENV_NAME: reviewer $OWNER only, self-review prevented, only main deploys; dummy value stored"
}

runs_for() { # <sha> — "id status conclusion actor" for each run of the S2 workflow on that commit
  owner_gh api "repos/$REPO/actions/runs?head_sha=$1&per_page=20" \
    --jq '.workflow_runs[] | select(.name == "frg26-s2") | "\(.id) \(.status) \(.conclusion) \(.actor.login)"' 2>/dev/null
}

wait_run() { # <sha> <status…> — sets RUN to "id status conclusion actor" once it has one of them
  local sha="$1" _ line="" st want
  shift
  RUN=""
  for _ in $(seq 1 60); do
    line="$(runs_for "$sha" | head -n 1)" || line=""
    st="$(printf '%s' "$line" | cut -d' ' -f2)"
    for want in "$@"; do
      if [[ -n "$line" && "$st" == "$want" ]]; then RUN="$line"; return 0; fi
    done
    sleep 5
  done
  RUN="$line"
  return 1
}

env_id() { owner_gh api "repos/$REPO/environments/$ENV_NAME" --jq .id 2>/dev/null; }

approve_run() { # <who owner_gh|app_gh> <run id> <env id>
  capture "$1" api -X POST "repos/$REPO/actions/runs/$2/pending_deployments" \
    -F "environment_ids[]=$3" -f state=approved -f comment="FRG-26 S2 approval attempt"
}

run_log_has_value() { # <run id> — 0 if the job printed the dummy value's length
  owner_gh run view "$1" --repo "$REPO" --log 2>/dev/null | grep -Fq "FRG26-S2 value length ${#DUMMY_VALUE}"
}

cancel_waiting_runs() {
  local id
  for id in $(owner_gh api "repos/$REPO/actions/runs?status=waiting&per_page=50" --jq '.workflow_runs[] | select(.name == "frg26-s2") | .id' 2>/dev/null); do
    [[ "$id" =~ ^[0-9]+$ ]] && owner_gh api -X POST "repos/$REPO/actions/runs/$id/cancel" >/dev/null 2>&1
  done
}

# S2b: the app's push to main starts a run; the app tries to approve its own deployment. Control:
# the owner approves the same run, and the job then reports the dummy value's length.
t_S2b() {
  fresh_from main "s2b-$(stamp)"
  add_commit "tests/permissions-S2b-$(stamp).txt" "FRG-26 S2b"
  capture app_git -C "$CLONE" push origin HEAD:refs/heads/main || { setup_fail_p S2b "the app could not push main in the open phase: $(evidence)"; return; }
  local sha eid id
  sha="$(app_git -C "$CLONE" rev-parse HEAD)" || sha=""
  eid="$(env_id)" || eid=""
  [[ "$sha" =~ ^[0-9a-f]{40}$ && "$eid" =~ ^[0-9]+$ ]] || { setup_fail_p S2b "could not read the commit or the Environment"; return; }
  wait_run "$sha" waiting || { setup_fail_p S2b "the app's run never waited for review ($RUN)"; return; }
  id="${RUN%% *}"
  approve_run app_gh "$id" "$eid" || true
  OBS="$(classify_api)"
  EV="the app approving its own run: $(evidence) |"
  if [[ "$OBS" != refused ]]; then record_p S2b "$OBS" "not run" "$EV"; cancel_waiting_runs; return; fi
  CTL=failed
  if approve_run owner_gh "$id" "$eid" && wait_run "$sha" completed && run_log_has_value "$id"; then CTL=ok; fi
  EV="$EV owner approving: $(evidence), run $RUN"
  S2B_OWNER_APPROVAL="$CTL"
  record_p S2b "$OBS" "$CTL" "$EV"
}

# S2d: the run the owner's own workflow commit started (env-tests' first step): the owner's own
# approval is refused, because Prevent self-review is on. Control: the very same request, by the
# same owner, on the app's run in S2b, was accepted.
t_S2d() {
  local eid id
  eid="$(env_id)" || eid=""
  [[ "$eid" =~ ^[0-9]+$ ]] || { setup_fail_p S2d "could not read the Environment"; return; }
  wait_run "$S2_OWNER_SHA" waiting || { setup_fail_p S2d "the owner's run never waited for review ($RUN)"; return; }
  id="${RUN%% *}"
  approve_run owner_gh "$id" "$eid" || true
  OBS=inconclusive
  if [[ $LAST_RC -ne 0 ]] && wait_run "$S2_OWNER_SHA" waiting; then OBS=refused; elif [[ $LAST_RC -eq 0 ]]; then OBS=allowed; fi
  EV="the owner approving the owner's own run: $(evidence)"
  owner_gh api -X POST "repos/$REPO/actions/runs/$id/cancel" >/dev/null 2>&1 || true
  record_p S2d "$OBS" "${S2B_OWNER_APPROVAL:-failed}" "$EV (control: the owner's approval of the app's run in S2b)"
}

# S2a: a feature branch's run may not deploy (only main may): it never waits for review and its
# job never gets the value. Control: S2b's run on main did.
t_S2a() {
  local br
  br="frg26-s2-a-$(stamp)"
  fresh_from main "$br"
  add_commit "tests/permissions-S2a-$(stamp).txt" "FRG-26 S2a"
  capture app_git -C "$CLONE" push origin "HEAD:refs/heads/$br" || { setup_fail_p S2a "pushing $br failed: $(evidence)"; return; }
  local sha id
  sha="$(app_git -C "$CLONE" rev-parse HEAD)" || sha=""
  wait_run "$sha" completed waiting || { setup_fail_p S2a "no run finished for $br ($RUN)"; return; }
  id="${RUN%% *}"
  OBS=inconclusive
  if [[ "$RUN" == *" completed failure "* ]] && ! run_log_has_value "$id"; then OBS=refused
  elif [[ "$RUN" == *" waiting "* ]] || run_log_has_value "$id"; then OBS=allowed
  fi
  record_p S2a "$OBS" ok "feature-branch run $RUN (control: S2b's run on main got the value)"
  cancel_waiting_runs
}

# S2c: the app tries to change the Environment's protection or its secret. Control: the owner reads
# the same Environment, unchanged.
t_S2c() {
  printf '{"wait_timer":0,"prevent_self_review":false,"reviewers":[],"deployment_branch_policy":null}\n' >"$WORK/env-weak.json"
  p_attempts api app_gh api -X PUT "repos/$REPO/environments/$ENV_NAME" --input "$WORK/env-weak.json" ";;" \
    app_gh api "repos/$REPO/environments/$ENV_NAME/secrets/public-key" ";;" \
    app_gh api -X DELETE "repos/$REPO/environments/$ENV_NAME/secrets/$DUMMY_NAME"
  [[ "$OBS" == refused ]] || { record_p S2c "$OBS" "not run" "$EV"; return; }
  CTL=failed
  [[ "$(env_summary)" == "$(want_env)" ]] && CTL=ok
  record_p S2c "$OBS" "$CTL" "$EV"
}

readonly S2_TEST_ORDER="S2b S2d S2a S2c"
S2_OWNER_SHA=""
S2B_OWNER_APPROVAL=""

cmd_env_tests() {
  need_owner
  assert_throwaway
  app_session
  verify_phase open
  need_allowance
  [[ "$(env_summary)" == "$(want_env)" ]] || die "run env-setup first (the Environment reads '$(env_summary)')"
  PHASE=permissions
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  CLONE="$WORK/clone"
  say "== FRG-26 Environment tests (S2), app $APP_BOT, $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
  # The owner adds the workflow to main: that commit starts the owner's own run (S2d's).
  put_file "$S2_WORKFLOW" "$(s2_workflow)"
  S2_OWNER_SHA="$(owner_gh api "repos/$REPO/branches/main" --jq .commit.sha 2>/dev/null)" || S2_OWNER_SHA=""
  [[ "$S2_OWNER_SHA" =~ ^[0-9a-f]{40}$ ]] || die "can't read main after adding the S2 workflow"
  local id
  for id in $S2_TEST_ORDER; do
    # A fresh clone each time: S2b moves main.
    rm -rf "$CLONE"
    app_git clone -q --template="$WORK/template" "https://github.com/$REPO.git" "$CLONE" || die "clone failed"
    "t_$id"
    if [[ $FAILS -ne 0 ]]; then
      cancel_waiting_runs
      say "ENVIRONMENT TESTS: STOPPED after $id"
      exit 1
    fi
  done
  cancel_waiting_runs
  say "ENVIRONMENT TESTS: ALL PASS (run reset next: main holds the S2 workflow)"
  exit 0
}

# --- Held tokens: A4, A9b, E1, E2, E3 (plan 4.3, revised 2026-11-01) --------------------------
# Some tests need a token issued earlier: one over an hour old (A4), or one issued before a key is
# deleted or the app is suspended, uninstalled or deleted. Such a token is "held": kept until its
# check, then revoked (if it still works) and removed. Held tokens are VAR=value lines in a mode-600
# file beside the app's key (HELD_AGE=…), so a handoff's ho_redact_file can hide them too; when each
# was issued is kept apart, in HELD_TIMES (not a secret). What GitHub does with each is recorded;
# where GitHub's docs are silent it is a reading.

HELD="$(dirname "$SECRETS")/held-tokens.env"
HELD_TIMES="$(dirname "$SECRETS")/held-times"
STATE="$(dirname "$SECRETS")/frg26-state"

held_var() { printf 'HELD_%s' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"; }

held_get() { # <name> — prints "token issued-epoch" or fails
  [[ -f "$HELD" && ! -L "$HELD" && -f "$HELD_TIMES" && ! -L "$HELD_TIMES" ]] || return 1
  local tok at
  tok="$(sed -n "s/^$(held_var "$1")=\(ghs_[A-Za-z0-9]*\)$/\1/p" "$HELD" | tail -n 1)"
  at="$(sed -n "s/^$1 \([0-9][0-9]*\)$/\1/p" "$HELD_TIMES" | tail -n 1)"
  [[ -n "$tok" && -n "$at" ]] || return 1
  printf '%s %s\n' "$tok" "$at"
}

drop_line() { # <file> <line prefix> — the file keeps mode 600
  [[ -f "$1" ]] || return 0
  (umask 077; grep -v "^$2" "$1" >"$1.new") || true
  chmod 600 "$1.new" && mv "$1.new" "$1"
}

held_drop() { # <name>
  drop_line "$HELD" "$(held_var "$1")="
  drop_line "$HELD_TIMES" "$1 "
}

state_set() { # <key> <value>
  (umask 077; touch "$STATE")
  grep -v "^$1 " "$STATE" >"$STATE.new" || true
  printf '%s %s\n' "$1" "$2" >>"$STATE.new"
  chmod 600 "$STATE.new" && mv "$STATE.new" "$STATE"
}

state_get() { [[ -f "$STATE" ]] && sed -n "s/^$1 //p" "$STATE" | tail -n 1; }

# hold-token <name>: a second narrowed token, kept for a later check; the session's own token is
# revoked as usual when the script ends.
cmd_hold_token() {
  local name="${1:-}"
  [[ "$name" =~ ^(age|keyold|suspend|uninstall|delete)$ ]] || die "usage: hold-token age|keyold|suspend|uninstall|delete"
  need_owner
  assert_throwaway
  app_session
  local session="$TOKEN" held
  mint_token
  held="$TOKEN"
  TOKEN="$session"
  REDACT_ONLY="$REDACT_ONLY $held"
  held_drop "$name"
  (umask 077; printf '%s=%s\n' "$(held_var "$name")" "$held" >>"$HELD") || die "storing the held token failed"
  (umask 077; printf '%s %s\n' "$name" "$(date +%s)" >>"$HELD_TIMES") || die "storing when it was issued failed"
  chmod 600 "$HELD" "$HELD_TIMES" || die "chmod failed"
  say "held token '$name' stored (issued $(date -u +%Y-%m-%dT%H:%M:%SZ), used only by its check)"
}

use_held() { # <name> — sets HELD_RESULT to "works" or GitHub's status; the token is then dropped
  local line tok
  line="$(held_get "$1")" || die "no held token '$1': run hold-token $1 first"
  tok="${line%% *}"
  REDACT_ONLY="$REDACT_ONLY $tok"
  local session="$TOKEN"
  TOKEN="$tok"
  capture app_gh api "repos/$REPO" --jq .full_name || true
  if [[ $LAST_RC -eq 0 && "$LAST_OUT" == "$REPO" ]]; then HELD_RESULT=works; revoke_token; else
    HELD_RESULT="$(http_of)"
    TOKEN=""
  fi
  TOKEN="$session"
  held_drop "$1"
  HELD_AGE=$(( $(date +%s) - ${line##* } ))
}

# A4: a token over an hour old is refused. Control: a fresh token, the same read.
cmd_token_age_check() {
  need_owner
  assert_throwaway
  local line
  line="$(held_get age)" || die "no held token 'age': run hold-token age first"
  (( $(date +%s) - ${line##* } > 3660 )) || die "the held token is not over an hour old yet: run this later"
  app_session
  use_held age
  local obs=inconclusive
  case "$HELD_RESULT" in works) obs=allowed ;; "HTTP 401") obs=refused ;; esac
  local ctl=failed
  if capture app_gh api "repos/$REPO" --jq .full_name && [[ "$LAST_OUT" == "$REPO" ]]; then ctl=ok; fi
  FAILS=0
  record_p A4 "$obs" "$ctl" "a token issued $HELD_AGE s ago: $HELD_RESULT"
  [[ $FAILS -eq 0 ]]
}

jwt_with() { # <key file> — a JWT signed with that key, for one request
  local keep="$APP_KEY"
  APP_KEY="$1"
  make_jwt
  APP_KEY="$keep"
}

# A9 and A9b: after the owner deleted the app's old key (app.pem) and installed a new one
# (app-new.pem): a JWT signed with the old key is refused (control: the new key's is accepted);
# what a token issued before the deletion does is recorded. The new key then becomes app.pem.
cmd_key_check() {
  need_owner
  assert_throwaway
  load_app
  local new
  new="$(dirname "$APP_KEY")/app-new.pem"
  [[ -f "$new" && ! -L "$new" && "$(stat -f %Lp "$new")" == 600 ]] || die "missing $new (mode 600): the new key's handoff step stores it"
  jwt_with "$APP_KEY"
  jwt_call GET app || true
  local obs=inconclusive old_http="$LAST_HTTP"
  case "$old_http" in 2*) obs=allowed ;; 401) obs=refused ;; esac
  jwt_with "$new"
  local ctl=failed
  if jwt_call GET app && [[ "$(jq -r .id <<<"$LAST_OUT")" == "$APP_ID" ]]; then ctl=ok; fi
  FAILS=0
  record_p A9 "$obs" "$ctl" "the deleted key's JWT: HTTP ${old_http:-none}; the new key's: HTTP ${LAST_HTTP:-none}"
  APP_KEY="$new"
  need_app_identity
  use_held keyold
  reading A9b "a token issued before the key was deleted, $HELD_AGE s later: $HELD_RESULT"
  [[ $FAILS -eq 0 ]] || exit 1
  mv "$new" "$(dirname "$new")/app.pem" || die "making the new key app.pem failed"
}

# E1, first half (the owner has just suspended the installation): a new token is refused; what a
# token issued before the suspension does is recorded. The verdict waits for the control.
cmd_suspend_check() {
  need_owner
  assert_throwaway
  load_app
  make_jwt
  jwt_call GET "app/installations?per_page=100" || die "can't list the app's installations: $(evidence)"
  local inst sus
  inst="$(jq -c --arg o "$OWNER" '[.[] | select(.account.login == $o)] | if length == 1 then .[0] else empty end' <<<"$LAST_OUT" 2>/dev/null)" || inst=""
  [[ -n "$inst" ]] || die "the app must still be installed (suspended) on $OWNER's account"
  sus="$(jq -r .suspended_at <<<"$inst")"
  [[ "$sus" != null ]] || die "the installation is not suspended: suspend it first"
  INSTALLATION_ID="$(jq -r .id <<<"$inst")"
  printf '%s\n' "{\"repositories\":[\"$REPO_NAME\"],\"permissions\":$WANT_PERMS}" >"$WORK/token-request.json"
  jwt_call POST "app/installations/$INSTALLATION_ID/access_tokens" "$WORK/token-request.json" || true
  local obs=inconclusive
  if [[ "$LAST_HTTP" =~ ^2 ]]; then
    obs=allowed
    TOKEN="$(jq -r .token <<<"$LAST_OUT")"
    revoke_token
  elif [[ "$LAST_HTTP" =~ ^(401|403|404)$ ]]; then obs=refused
  fi
  state_set E1 "$obs HTTP-${LAST_HTTP:-none}"
  use_held suspend
  reading E1 "a token issued before the suspension (suspended at $sus): $HELD_RESULT"
  say "E1 a new token while suspended: $obs (HTTP ${LAST_HTTP:-none}); the verdict follows after you unsuspend"
}

# E1, second half (the owner has unsuspended): the control, a new token, must work.
cmd_unsuspend_check() {
  need_owner
  assert_throwaway
  local first
  first="$(state_get E1)" || first=""
  [[ -n "$first" ]] || die "run suspend-check first"
  local ctl=failed
  if (app_session) >/dev/null 2>&1; then ctl=ok; fi
  FAILS=0
  record_p E1 "${first%% *}" "$ctl" "a new token while suspended: ${first#* }; after unsuspending: $ctl"
  [[ $FAILS -eq 0 ]]
}

# E2 (the owner has just uninstalled the app): what a token issued before does is recorded, and
# GitHub must list no installation for the owner.
cmd_uninstall_check() {
  need_owner
  assert_throwaway
  load_app
  make_jwt
  jwt_call GET "app/installations?per_page=100" || die "can't list the app's installations: $(evidence)"
  local n
  n="$(jq --arg o "$OWNER" '[.[] | select(.account.login == $o)] | length' <<<"$LAST_OUT" 2>/dev/null)" || n=error
  [[ "$n" == 0 ]] || die "the app is still installed on $OWNER's account ($n installations): uninstall it first"
  use_held uninstall
  reading E2 "a token issued before the uninstall: $HELD_RESULT"
}

# E3 (the owner has just deleted the app): what a token issued before does is recorded, and the
# app's own key must be refused.
cmd_delete_check() {
  need_owner
  assert_throwaway
  load_app
  make_jwt
  jwt_call GET app || true
  [[ ! "$LAST_HTTP" =~ ^2 ]] || die "GitHub still knows the app: delete it first"
  local gone="HTTP ${LAST_HTTP:-none}"
  use_held delete
  reading E3 "a token issued before the app was deleted: $HELD_RESULT; the app's own key now gets $gone"
}

cmd_tests() {
  PHASE="${1:-}"
  case "$PHASE" in open | protected | ruleset) ;; *) die "usage: tests open|protected|ruleset" ;; esac
  need_owner
  assert_throwaway
  app_session
  verify_phase "$PHASE"
  need_allowance
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  CLONE="$WORK/clone"
  app_git clone -q --template="$WORK/template" "https://github.com/$REPO.git" "$CLONE" || die "clone failed"
  say "== FRG-26 bypass tests, phase $PHASE, app $APP_BOT, $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
  # The stop rule (plan section 3): after a failed or inconclusive test nothing more is changed
  # except closing test PRs. The next test never starts; sweep_prs closes every test PR left open,
  # here or, if the phase stops with an error, on exit.
  local id
  SWEEP_ON_EXIT=1
  for id in $TEST_ORDER; do
    "t_$id"
    if [[ $FAILS -ne 0 ]]; then
      SWEEP_ON_EXIT=""
      sweep_prs
      if app_rate; then say "app allowance after the phase: $RATE_LINE"; fi
      say "PHASE $PHASE: STOPPED after $id (a failed test stops the phase; only test PRs were closed after it)"
      exit 1
    fi
  done
  SWEEP_ON_EXIT=""
  sweep_prs
  if app_rate; then say "app allowance after the phase: $RATE_LINE"; fi
  if [[ $FAILS -ne 0 ]]; then
    say "PHASE $PHASE: FAILED at the final cleanup (a test PR may still be open)"
    exit 1
  fi
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
    create-second) cmd_create_second ;;
    check-app) cmd_check_app ;;
    rate) cmd_rate ;;
    allowance) cmd_allowance ;;
    reset) cmd_reset ;;
    protect) cmd_protect ;;
    unprotect) cmd_unprotect ;;
    ruleset) cmd_ruleset ;;
    tests) cmd_tests "$@" ;;
    ptests) cmd_ptests ;;
    env-setup) cmd_env_setup ;;
    env-tests) cmd_env_tests ;;
    hold-token) cmd_hold_token "$@" ;;
    token-age-check) cmd_token_age_check ;;
    key-check) cmd_key_check ;;
    suspend-check) cmd_suspend_check ;;
    unsuspend-check) cmd_unsuspend_check ;;
    uninstall-check) cmd_uninstall_check ;;
    delete-check) cmd_delete_check ;;
    actions-setting) cmd_actions_setting ;;
    status) cmd_status ;;
    *) die "usage: github-throwaway.sh create|create-second|check-app|rate|allowance|reset|protect|unprotect|ruleset|tests <phase>|ptests|env-setup|env-tests|hold-token <name>|token-age-check|key-check|suspend-check|unsuspend-check|uninstall-check|delete-check|actions-setting|status" ;;
  esac
}

# Run main when executed as a file or as `bash -p -c "<this script>" frg26 <command>` (the
# handoffs), but not when a test sources it.
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
