#!/bin/bash
# FRG-26 stage 1: GitHub feasibility tests on a throwaway repository
# (docs/plans/2026-10-20-frg-26-permissions-isolation.md, sections 6 and 8).
#
# Run ONLY by the owner, from an owner handoff, in the owner's own Terminal. It acts as two parties:
#   owner   the owner's own gh login: creates the repo, approves PRs, applies protection, resets
#   app     the owner's throwaway GitHub App (plan section 4, revised 2026-11-01): every bypass
#           attempt, with an installation token limited to the throwaway repo and four permissions
# It touches only two public throwaway repositories and refuses any other (review round 37):
#   github.com/Thebigtuna88/forge-frg26-throwaway     the tests: both parties write here
#   github.com/Thebigtuna88/forge-frg26-throwaway-2   test A2: the owner creates it once (one
#       branch, one file; create-second); after that only the app tries a push, an issue and a PR,
#       which must be refused (the app is not installed there); the owner only reads it. A2 failed
#       on 2026-11-11 (the issue got through); a2-probe then tries more there, as the app
#
#   github-throwaway.sh create            owner: create the throwaway repo (public; main dev side)
#   github-throwaway.sh check-app         the app, its installation and its token carry exactly the
#                                         throwaway repo and the four permissions (read-only; A1)
#   github-throwaway.sh rate              the app's API allowance: limit, used, reset (read-only)
#   github-throwaway.sh allowance         fails unless the app has enough allowance for a phase
#   github-throwaway.sh reset             owner: main dev side back to the baseline (unprotected only)
#   github-throwaway.sh protect           owner: apply the dev and main branch protection; a branch
#                                         that already has exactly it is left (can be run again)
#   github-throwaway.sh unprotect         owner: remove exactly that protection; a branch that is
#                                         already unprotected is left (can be run again)
#   github-throwaway.sh ruleset           owner: add the main ruleset (only the owner may bypass);
#                                         first checks the app has enough allowance
#   github-throwaway.sh tests <phase>     run the bypass tests (kind S); phase = open | protected | ruleset
#   github-throwaway.sh create-second     owner: the second public throwaway, app not installed (A2)
#   github-throwaway.sh ptests            the permission tests (kind P, each with a control):
#                                         S1 A6 A8 A5 A3 A2, and the readings A11 A12
#   github-throwaway.sh a2-probe          after A2 failed (owner-approved 2026-11-11): the app's
#                                         tokens on the second throwaway; code changes must be
#                                         refused, public activity is only recorded, nothing closed
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
# Neither the JWT nor a token is ever printed or put in a command's arguments. When the script
# ends it tries to revoke every token it got, except one held on purpose for a later check
# (hold-token); a revocation that fails is reported, and that token works until its hour runs out.
# Whether a revocation stops GitHub's stateless tokens at once is Unconfirmed until A5 (plan 4.3).
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
# Every token this run got that is neither revoked nor held: revocation of each is tried on exit, so
# a session token set aside while a second token is minted is never abandoned (round 17, C2).
OUTSTANDING=""
MINTED=0 # tokens GitHub issued to this run, kept or not
PROBE_ACTIVE="" # set while a2-probe runs: an error exit settles its tokens and reads back its objects
PROBE_SUMMARY="" # a2-probe's last line, printed by the exit clean-up after everything else
PROBE_RC=""      # a2-probe's exit status, decided by the exit clean-up
ISSUED=""        # label=token for every token GitHub issued to this run, kept or not
ISSUED_META=""   # one line per token: label, then GitHub's answer when it was issued (no token)
MINT_LABEL=""    # the name mint gives the next token (a2-probe: whole full P1 P2)
readonly CALL_SECS=20     # the longest a revocation or a check may take
readonly CLEANUP_SECS=180 # the longest the whole clean-up may take
CLEANUP_DEADLINE=""
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
  for t in $TOKEN $REVOKED_TOKENS $OUTSTANDING $REDACT_ONLY $JWT; do s="${s//"$t"/[REDACTED]}"; done
  printf '%s' "$s"
}

say() { redact "$*"; printf '\n'; }

# Set once the bypass tests start; cleared when cmd_tests sweeps on its own. While it's set, any
# other way out (die, or bash stopping on an error) closes the open test PRs first, so a PR (B11's
# with auto-merge armed) is never left behind. Subshells don't run this trap.
SWEEP_ON_EXIT=""
# Set by env-tests before the owner's workflow commit starts a run: any exit then cancels the S2 runs
# still waiting for review (round 16, C2).
CANCEL_ON_EXIT=""

cleanup() {
  local rc=$?
  # Once the clean-up starts it runs to its end: a second Ctrl-C, closing the window or a kill no
  # longer stops it (round 52, owner-approved). It is bounded in time instead: each revocation and
  # each check is given at most CALL_SECS, and the whole clean-up at most CLEANUP_SECS.
  trap '' HUP INT TERM
  CLEANUP_DEADLINE=$(($(date +%s) + CLEANUP_SECS))
  if [[ -n "$SWEEP_ON_EXIT" ]]; then
    SWEEP_ON_EXIT=""
    say "PHASE $PHASE: STOPPED by an error (status $rc); closing the open test PRs"
    sweep_prs
    if [[ "$PHASE" == permissions ]]; then sweep_issues; fi
  fi
  if [[ -n "$CANCEL_ON_EXIT" ]]; then
    CANCEL_ON_EXIT=""
    cancel_waiting_runs || true
  fi
  # Every way out of a2-probe ends here: its tokens are settled and checked, what it made is read
  # back, and its result decides the exit status (rounds 47, 52).
  if [[ -n "$PROBE_ACTIVE" ]]; then
    PROBE_ACTIVE=""
    probe_finish "$rc"
  fi
  revoke_outstanding
  if [[ -n "$HELD_LOCKED" ]]; then rmdir "$HELD.lock" 2>/dev/null || true; HELD_LOCKED=""; fi
  if [[ -n "$WORK" && -d "$WORK" ]]; then rm -rf "$WORK"; fi
  # a2-probe's summary is the last line, which the owner's handoff result shows (round 48).
  if [[ -n "$PROBE_SUMMARY" ]]; then say "$PROBE_SUMMARY"; fi
  if [[ -n "$PROBE_RC" ]]; then exit "$PROBE_RC"; fi
}
trap cleanup EXIT
# Closing the Terminal, Ctrl-C or a kill also end through cleanup, with the usual status (round 51,
# SEC-1): an explicit exit, so it holds whatever the signal finds bash doing. A force-kill (KILL)
# or a power loss can't be caught: a token not revoked then stays valid until it expires (GitHub
# issues each for at most an hour).
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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

# The key must belong to the owner's app, which asks for exactly the four permissions, installed
# exactly once (on the owner's account), on selected repositories only, not suspended, with exactly
# the four permissions.
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
  # The app's own permissions too, not only the installation's: a change the owner made to the app
  # that awaits the installation's approval shows here first (round 20, C1).
  got="$(jq -S -c .permissions <<<"$app" 2>/dev/null)" || got=error
  [[ "$got" == "$WANT_PERMS" ]] || die "the app itself must ask for exactly $WANT_PERMS (it asks for $got)"
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
# the permissions (the four unless a probe asks for fewer), selected repositories, and (narrowed)
# only the throwaway. Anything more is revoked at once (plan 4.2 step 3). MINT_ANSWER keeps what
# GitHub said it issued, without the token.
mint() { # <request json> <narrowed|whole> [permissions json, sorted]
  local want="${3:-$WANT_PERMS}"
  MINT_ANSWER=""
  printf '%s\n' "$1" >"$WORK/token-request.json" || die "writing the token request failed"
  jwt_call POST "app/installations/$INSTALLATION_ID/access_tokens" "$WORK/token-request.json" \
    || die "GitHub refused the token request (HTTP ${LAST_HTTP:-none}): $(evidence)"
  local ans="$LAST_OUT" t perms sel repos
  LAST_OUT=""
  t="$(jq -r '.token // empty' <<<"$ans" 2>/dev/null)" || t=""
  [[ -n "$t" ]] || die "GitHub's answer holds no installation token"
  # Whatever GitHub issued is revoked if it isn't kept (round 31: the owner's run refused a real
  # token and left it working until it expired). GitHub's stateless format is ghs_APPID_JWT, about
  # 520 characters, base64url parts joined by dots (changelog 2026-04-24). The length is checked on
  # its own: macOS regex allows at most 255 repeats. It is on the exit list before it is judged, so a
  # failed revocation is tried again on exit (round 32, C1).
  TOKEN="$t"
  OUTSTANDING="$OUTSTANDING $t"
  MINTED=$((MINTED + 1))
  ISSUED="$ISSUED ${MINT_LABEL:-token$MINTED}=$t"
  # What GitHub said it issued (named fields only, no token), kept before any check, so a token
  # refused below is still described if its revocation isn't confirmed (round 54, SEC-1).
  ISSUED_META="$ISSUED_META${MINT_LABEL:-token$MINTED} $(jq -S -c '{expires_at, permissions, repository_selection, repositories: [.repositories[]?.full_name]}' <<<"$ans" 2>/dev/null || echo unreadable)
"
  if [[ ! "$t" =~ ^ghs_[A-Za-z0-9._-]+$ ]] || [[ ${#t} -lt 30 || ${#t} -gt 4096 ]]; then
    if revoke_token; then
      die "GitHub's answer holds a token in a form this script doesn't expect: it was revoked"
    fi
    die "GitHub's answer holds a token in a form this script doesn't expect, and revoking it failed: it may work until it expires, within an hour; the exit clean-up tries once more"
  fi
  perms="$(jq -S -c .permissions <<<"$ans" 2>/dev/null)" || perms=error
  sel="$(jq -r .repository_selection <<<"$ans" 2>/dev/null)" || sel=error
  repos="$(jq -c '[.repositories[]?.full_name]' <<<"$ans" 2>/dev/null)" || repos=error
  if [[ "$perms" != "$want" || "$sel" != selected ]] || [[ "$2" == narrowed && "$repos" != "[\"$REPO\"]" ]]; then
    if revoke_token; then
      die "the token GitHub issued carries more than was asked (permissions $perms, repositories $sel $repos): it was revoked"
    fi
    die "the token GitHub issued carries more than was asked (permissions $perms, repositories $sel $repos), and revoking it failed: it may work until it expires, within an hour; the exit clean-up tries once more"
  fi
  # Named fields only, so nothing else GitHub may add to its answer is ever printed.
  MINT_ANSWER="$(jq -S -c '{expires_at, permissions, repository_selection, repositories: [.repositories[]?.full_name]}' <<<"$ans" 2>/dev/null)" || MINT_ANSWER=unreadable
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

revoke_token() { # DELETE /installation/token, which GitHub documents as stopping the token at once
  # (for stateless tokens Unconfirmed until A5, plan 4.3); 1 if GitHub didn't confirm it
  [[ -n "$TOKEN" ]] || return 0
  local rc=0
  # A network hang can't hold it: at most CALL_SECS, less near the clean-up's cap (rounds 52, 53).
  with_timeout "$(call_secs)" app_gh api -X DELETE installation/token >/dev/null 2>&1 || rc=$?
  if [[ $rc -ne 0 ]]; then say "note: revoking a token failed or timed out; GitHub expires it within an hour"; fi
  REVOKED_TOKENS="$REVOKED_TOKENS $TOKEN"
  # Only a confirmed revocation leaves the list: a failed one is tried again on exit (round 26).
  if [[ $rc -eq 0 ]]; then outstanding_drop "$TOKEN"; fi
  TOKEN=""
  return $rc
}

# Runs a command for at most <seconds> (none at 0); 124 if it was stopped. The whole process tree is
# stopped: app_gh and owner_gh are functions whose subshell execs gh, so killing the job's own
# process alone would leave gh running and holding capture's output open (round 53, C1, SEC-1).
# KILL, not TERM: the clean-up ignores TERM, and what it starts inherits that. The watchdog writes
# nowhere, so a command substitution around this never waits for it.
with_timeout() { # <seconds> <command…>
  local secs="$1" pid w rc=0 mark
  shift
  [[ "$secs" =~ ^[0-9]+$ && $secs -gt 0 ]] || return 124
  mark="${WORK:-${TMPDIR:-/tmp}}/timeout-$$-$RANDOM"
  "$@" &
  pid=$!
  (
    sleep "$secs"
    echo stopped >"$mark"
    kill_tree "$pid"
  ) </dev/null >/dev/null 2>&1 &
  w=$!
  wait "$pid" || rc=$?
  kill_tree "$w"
  wait "$w" 2>/dev/null
  if [[ -f "$mark" ]]; then
    rm -f "$mark"
    return 124
  fi
  return $rc
}

kill_tree() { # <pid> — stop it, then KILL it and every process below it
  local p
  kill -STOP "$1" 2>/dev/null || return 0
  for p in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$p"; done
  kill -KILL "$1" 2>/dev/null
}

# CALL_SECS, or less inside the clean-up: what is left of its budget, 0 once it has passed (round
# 53, C2, SEC-2), so no request runs past the cap.
call_secs() {
  local left
  if [[ -z "$CLEANUP_DEADLINE" ]]; then
    printf '%s' "$CALL_SECS"
    return
  fi
  left=$((CLEANUP_DEADLINE - $(date +%s)))
  if [[ $left -lt 0 ]]; then left=0; fi
  if [[ $left -gt $CALL_SECS ]]; then left=$CALL_SECS; fi
  printf '%s' "$left"
}

in_time() { # 1 once the clean-up's time cap has passed (no cap outside the clean-up)
  [[ -z "$CLEANUP_DEADLINE" || $(date +%s) -lt $CLEANUP_DEADLINE ]]
}

outstanding_drop() { # <token> — revoked or held: no longer this run's to revoke on exit
  local s=" $OUTSTANDING "
  OUTSTANDING="${s// $1 / }"
}

revoke_outstanding() { # the current token, then every other token this run minted and still owns
  local t n=0
  revoke_token
  for t in $OUTSTANDING; do
    in_time || break # the clean-up's time cap (round 52): what's left stays on the list, reported
    TOKEN="$t"
    revoke_token
  done
  for t in $OUTSTANDING; do n=$((n + 1)); done
  if [[ $n -gt 0 ]]; then
    say "note: $n token(s) of this run could not be revoked; GitHub expires each within an hour of its issue"
  fi
}

# A control's own token request (A9, E1) runs in a subshell whose output is hidden, and its tokens
# are revoked as it ends. Its exit list dies with it, so a token it could not revoke is reported
# here (round 35, C1/SEC-1): status 3 (the request worked) or 4 (it failed) from its exit trap.
control_exit() {
  local rc=$?
  revoke_outstanding >/dev/null 2>&1
  if [[ -n "${OUTSTANDING// /}" ]]; then
    if [[ $rc -eq 0 ]]; then exit 3; fi
    exit 4
  fi
}

control_token() { # <command> — 0 if it got its token; reports a token left unrevoked
  local rc=0
  (trap control_exit EXIT; "$@") >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 3 || $rc -eq 4 ]]; then
    say "note: a control's token could not be revoked; GitHub expires it within an hour of its issue"
  fi
  [[ $rc -eq 0 || $rc -eq 3 ]]
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

# The owner commits a file to main and prints the new commit's sha, from the write's own answer.
put_file_commit() { # <path> <content>
  local b64
  b64="$(printf '%s' "$2" | base64 | tr -d '\n')"
  owner_gh api -X PUT "repos/$REPO/contents/$1" -f message="FRG-26 throwaway: $1" \
    -f content="$b64" -f branch=main --jq .commit.sha
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
  # The branch first, then a commit on it: A2's PR attempt needs a branch ahead of main, or no one
  # could open it and its refusal would prove nothing (round 15, SEC-1).
  owner_gh api -X POST "repos/$REPO2/git/refs" -f ref="refs/heads/$A2_BRANCH" -f sha="$sha" >/dev/null || die "creating $A2_BRANCH failed"
  owner_gh api -X PUT "repos/$REPO2/contents/a2.txt" -f message="FRG-26 A2 branch" \
    -f content="$(printf 'FRG-26 A2\n' | base64 | tr -d '\n')" -f branch="$A2_BRANCH" >/dev/null || die "adding a2.txt to $A2_BRANCH failed"
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

# One branch, for protect and unprotect: sets BRANCH_PROTECTION to unprotected, or protected when
# it carries exactly protect's protection; anything else stops.
branch_protection() { # <branch>
  local s ea=false
  [[ "$1" == dev ]] && ea=true
  s="$(branch_state "$1")"
  case "$s" in
    unprotected | protected) ;;
    *) die "$1 reads $s: stopped before changing it" ;;
  esac
  if [[ "$s" == protected && "$(protection_full "$1")" != "$(want_protection "$ea")" ]]; then
    die "$1 is protected, but not exactly as protect applies it: stopped before changing it"
  fi
  BRANCH_PROTECTION="$s"
}

# Which of dev and main protect or unprotect must change, in PROTECTION_TODO. Each branch must be
# unprotected or carry exactly protect's protection; one already in the wanted state is left as it
# is, so a run that changed dev and then failed on main can be run again (review rounds 41 and 43,
# C1). Anything else, an unreadable branch or a ruleset, stops before any write. Each branch is
# read again right before its own write (protection_write), as reset does (review round 44, C1).
protection_todo() { # <protected|unprotected>: the state wanted
  local b
  PROTECTION_TODO=""
  [[ "$(ruleset_count)" == 0 ]] || die "protect and unprotect only run while there is no ruleset"
  for b in dev main; do
    branch_protection "$b"
    [[ "$BRANCH_PROTECTION" == "$1" ]] || PROTECTION_TODO="$PROTECTION_TODO $b"
  done
}

# Reads the branch again; writes only if it still needs it (GitHub has no conditional write, so a
# change in the moment between this read and the write can't be caught).
protection_write() { # <branch> <protected|unprotected> <gh api args…>
  local b="$1" want="$2"
  shift 2
  branch_protection "$b"
  [[ "$BRANCH_PROTECTION" != "$want" ]] || return 0
  owner_gh api "$@" >/dev/null
}

cmd_protect() {
  need_owner
  assert_throwaway
  protection_todo protected
  local b
  # dev: nobody merges without the owner's code-owner approval, admins included (D5).
  protection_json true >"$WORK/dev.json"
  # main: the same review rule; admins (only the owner) may bypass it, so the owner can merge
  # dev into main (M6). Who may update main at all is the ruleset's job (D6).
  protection_json false >"$WORK/main.json"
  for b in $PROTECTION_TODO; do
    protection_write "$b" protected -X PUT "repos/$REPO/branches/$b/protection" --input "$WORK/$b.json" || die "protecting $b failed"
  done
  verify_phase protected
  say "dev protection:  $(protection_of dev)   (approvals codeowners last-push stale enforce-admins force deletions)"
  say "main protection: $(protection_of main)"
}

# The reverse of protect, from the state protect leaves (or part of it, after a failed run), so a
# phase open can run again (owner, 2026-10-31: a fresh open phase on the reviewed commit).
cmd_unprotect() {
  need_owner
  assert_throwaway
  protection_todo unprotected
  local b
  for b in $PROTECTION_TODO; do
    protection_write "$b" unprotected -X DELETE "repos/$REPO/branches/$b/protection" || die "unprotecting $b failed"
  done
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

# Controls, all of which must succeed. Sets CTL (ok|failed) and adds to EV. The first one that fails
# ends the list: no later control (some write) runs after it, the stop rule (round 29).
p_controls() { # <args…> separated by ";;"
  local c
  CTL=ok
  while [[ $# -gt 0 && "$CTL" == ok ]]; do
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

# A8: secrets, variables, deploy keys, webhooks and pending collaborator invitations (settings
# only an admin may read). Control: the owner reads the same lists (nothing is created or written).
# Round 13 (SEC-5): no collaborator write; see the evidence line.
t_A8() {
  p_attempts api app_gh api "repos/$REPO/actions/secrets" ";;" \
    app_gh api "repos/$REPO/actions/secrets/public-key" ";;" \
    app_gh api "repos/$REPO/actions/variables" ";;" \
    app_gh api "repos/$REPO/keys" ";;" \
    app_gh api "repos/$REPO/hooks" ";;" \
    app_gh api "repos/$REPO/invitations"
  [[ "$OBS" == refused ]] || { record_p A8 "$OBS" "not run" "$EV"; return; }
  p_controls owner_gh api "repos/$REPO/actions/secrets" ";;" owner_gh api "repos/$REPO/actions/secrets/public-key" ";;" \
    owner_gh api "repos/$REPO/actions/variables" ";;" \
    owner_gh api "repos/$REPO/keys" ";;" owner_gh api "repos/$REPO/hooks" ";;" owner_gh api "repos/$REPO/invitations"
  record_p A8 "$OBS" "$CTL" "$EV (adding a collaborator is not tried: any valid target would invite a real person; it needs Administration, whose write A6 shows refused)"
}

# A5 (plan 4.3): does a revoked token stop working at once (documented; for stateless tokens
# Unconfirmed until this runs)? Control: the same read with that token
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
  local ahead
  ahead="$(owner_gh api "repos/$REPO2/compare/main...$A2_BRANCH" --jq .ahead_by 2>/dev/null)" || ahead=""
  [[ "$ahead" =~ ^[1-9][0-9]*$ ]] || { setup_fail_p A2 "$REPO2's $A2_BRANCH is not ahead of main (ahead by '${ahead:-unreadable}'): no PR could be opened from it"; return; }
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

# This run's test issues ("FRG-26 " titles carrying RUN_ID) are closed in the throwaway. The second
# throwaway is only read (round 13, SEC-4): an "FRG-26 " issue there means A2's attempt got through,
# and is reported for the owner to close; this script never writes there as the owner.
sweep_issues() {
  local open n mine
  mine=".[] | select(.pull_request == null) | select(.title | startswith(\"FRG-26 \")) | select(.title | contains(\"$RUN_ID\")) | .number"
  if ! open="$(owner_gh api --paginate "repos/$REPO/issues?state=open&per_page=100" --jq "$mine" 2>/dev/null)"; then
    FAILS=$((FAILS + 1))
    say "CLEANUP FAIL could not list the open issues in $REPO: close any \"FRG-26 \" test issue on GitHub"
  else
    for n in $open; do
      [[ "$n" =~ ^[0-9]+$ ]] || continue
      owner_gh issue close "$n" --repo "$REPO" >/dev/null 2>&1 || { FAILS=$((FAILS + 1)); say "CLEANUP FAIL issue #$n in $REPO may still be open"; }
    done
  fi
  if ! open="$(owner_gh api --paginate "repos/$REPO2/issues?state=open&per_page=100" \
    --jq '.[] | select(.title | startswith("FRG-26 ")) | .number' 2>/dev/null)"; then
    FAILS=$((FAILS + 1))
    say "CLEANUP FAIL could not list the open issues in $REPO2: check it on GitHub for \"FRG-26 \" issues"
  elif [[ -n "$open" ]]; then
    FAILS=$((FAILS + 1))
    say "CLEANUP FAIL $REPO2 has open \"FRG-26 \" issues or PRs (#$(printf '%s' "$open" | tr '\n' ' ')): the app wrote there; close them on GitHub"
  fi
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

# --- A2 investigation (owner-approved 2026-11-11; plan section 6, "A2, 2026-11-11") --------------
# A2 failed: the app opened an issue on the second throwaway, where it is not installed. This finds
# out what else its tokens can do there, all against that repository. Code changes (claim 9a) must
# be refused, each with a control on the throwaway; the first that isn't refused stops the run, and
# so does any change to the second throwaway's branches or tags. Public activity (claim 9b) is a
# reading, never a pass or a fail. Whatever an attempt creates stays there as evidence: nothing is
# closed or deleted, and each object is read back by the number GitHub returned. Each token's
# permissions, repositories and expiry are printed from GitHub's answer (without the token), its
# repositories read back with GET /installation/repositories, and its expiry checked to be within
# an hour; each is revoked as soon as its attempts end, and a read with it must then get HTTP 401.
#
# The clean-up contract (owner-approved, round 52). Every way out (the end, a stop, an error, Ctrl-C,
# closing the window, a kill) goes through cleanup, which then ignores further signals and:
#   1. revokes again every token GitHub issued to the run (whole full P1 P2) that no read has shown
#      revoked, and reads with it: only HTTP 401 confirms it;
#   2. reads back by number each object an attempt made;
#   3. ends with one line naming the tokens confirmed revoked and those not, never a token itself.
# Each revocation and each read is given at most CALL_SECS, and never more than is left of the
# clean-up's CLEANUP_SECS; the deadline is checked before each step; a step the time cap leaves out
# is named as not done. A timeout stops the request's whole process tree (gh included). Limits: a force-kill, a power loss, or a
# revocation that fails or times out leaves a token unconfirmed. It may stay valid until its
# expires_at, printed when it was issued. What it can do is what its TOKEN lines show for the first
# throwaway, plus what this run's readings show on a public repository it isn't installed on (A2).

readonly PROBE_PERMS_P1='{"contents":"write","metadata":"read"}'
readonly PROBE_PERMS_P2='{"metadata":"read"}'
PROBE_FAILS=0
PROBE_LABEL=""
PROBE_MADE=""     # kind:number of each object an attempt created
PROBE_READINGS=""
OBS_KEPT=""
PROBE_REVOKED=0
PROBE_CONFIRMED="" # tokens a read showed revoked (HTTP 401)
PROBE_END=""       # done, or "STOPPED: <why>"; empty after an error or a signal
PROBE_EXPIRY_OK="" # labels of the tokens whose expiry was checked within the hour
REFS_BEFORE=""

probe_stop() { # <why> — stop: the exit clean-up settles the tokens and reads back what was made
  PROBE_FAILS=$((PROBE_FAILS + 1))
  say "PROBE STOP: $1"
  PROBE_END="STOPPED: $1"
  if [[ -n "$REFS_BEFORE" ]]; then probe_refs_same || true; fi
  exit 1
}

probe_label_of() { # <token> — its name in this run, never the token
  local e
  for e in $ISSUED; do
    if [[ "${e#*=}" == "$1" ]]; then printf '%s' "${e%%=*}"; return; fi
  done
  printf 'unnamed'
}

# Is the token now refused? A read with it, within call_secs; 0 only for HTTP 401.
probe_refused() { # <token>
  TOKEN="$1"
  capture with_timeout "$(call_secs)" app_gh api "repos/$REPO" --jq .full_name || true
  TOKEN=""
  [[ $LAST_RC -ne 0 ]] && printf '%s' "$LAST_OUT" | grep -Eq 'HTTP 401|Bad credentials'
}

# Every token GitHub issued to this run that no read has yet shown revoked, whatever happened to it
# (refused by mint, a revocation GitHub didn't confirm or that timed out, an error exit): revoked
# again, even one whose earlier DELETE GitHub answered as done (round 50), then a read with it must
# get HTTP 401. One that still works stays on OUTSTANDING for the exit's last try (round 47, C1).
probe_settle_tokens() {
  local e t label
  for e in $ISSUED; do
    t="${e#*=}" label="${e%%=*}"
    [[ " $PROBE_CONFIRMED " != *" $t "* ]] || continue
    if ! in_time; then
      say "TOKEN $label not checked: the clean-up's time cap (${CLEANUP_SECS}s) was reached"
      continue
    fi
    TOKEN="$t"
    revoke_token || true
    if ! in_time; then
      say "TOKEN $label revocation tried, not checked: the clean-up's time cap (${CLEANUP_SECS}s) was reached"
      [[ " $OUTSTANDING " == *" $t "* ]] || OUTSTANDING="$OUTSTANDING $t"
      continue
    fi
    if probe_refused "$t"; then
      PROBE_REVOKED=$((PROBE_REVOKED + 1))
      PROBE_CONFIRMED="$PROBE_CONFIRMED $t"
      say "TOKEN $label revoked: a read with it now gets HTTP 401"
    else
      PROBE_FAILS=$((PROBE_FAILS + 1))
      [[ " $OUTSTANDING " == *" $t "* ]] || OUTSTANDING="$OUTSTANDING $t"
      say "TOKEN $label still answers a read after its revocation was tried ($(evidence)): it may stay valid until its expires_at; the exit clean-up tries once more"
    fi
  done
}

probe_token() { # <label> <request json> <narrowed|whole> <permissions json> — a token, its scope read back
  PROBE_LABEL="$1"
  MINT_LABEL="$1"
  mint "$2" "$3" "$4"
  MINT_LABEL=""
  say "TOKEN $1 issued: $MINT_ANSWER"
  # Its expiry, from GitHub's answer: in the future, and at most an hour away (with a minute's
  # leeway for the clocks).
  local exp at now
  exp="$(jq -r '.expires_at // empty' <<<"$MINT_ANSWER" 2>/dev/null)" || exp=""
  at="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$exp" +%s 2>/dev/null)" || at=""
  now="$(date +%s)"
  if [[ ! "$at" =~ ^[0-9]+$ ]] || [[ $at -le $now || $at -gt $((now + 3660)) ]]; then
    probe_stop "token $1's expiry '$exp' is not within the next hour, or could not be read"
  fi
  say "TOKEN $1 expires $exp, in $(((at - now) / 60)) minutes"
  PROBE_EXPIRY_OK="$PROBE_EXPIRY_OK $1"
  local got
  got="$(app_gh api installation/repositories --paginate --jq '.repositories[].full_name' 2>&1)" || got="unreadable: $got"
  say "TOKEN $1 reaches (GET /installation/repositories): $(printf '%s' "$got" | tr '\n' ' ')"
  [[ "$got" == "$REPO" ]] || probe_stop "token $1 reaches more than $REPO, or what it reaches could not be read"
}

revoke_confirmed() { # <label> — revoke the current token; a read with it afterwards must get HTTP 401
  local t="$TOKEN"
  if ! revoke_token; then
    PROBE_FAILS=$((PROBE_FAILS + 1))
    say "TOKEN $1 revocation FAILED: the exit clean-up tries again"
    return 0
  fi
  if probe_refused "$t"; then
    PROBE_REVOKED=$((PROBE_REVOKED + 1))
    PROBE_CONFIRMED="$PROBE_CONFIRMED $t"
    say "TOKEN $1 revoked: a read with it now gets HTTP 401"
  else
    PROBE_FAILS=$((PROBE_FAILS + 1))
    OUTSTANDING="$OUTSTANDING $t"
    say "TOKEN $1 revoked, but a read with it did not get HTTP 401 ($(evidence)): the exit clean-up tries again"
  fi
}

# A token not confirmed revoked, described for the owner without the token (round 54, SEC-1): what
# GitHub said when it was issued, whether its expiry was checked within the hour, and what it
# reaches now (a read with it, if the time cap allows).
probe_describe() { # <label> <token>
  local meta got
  meta="$(printf '%s' "$ISSUED_META" | sed -n "s/^$1 //p" | head -n 1)"
  say "TOKEN $1 NOT confirmed revoked. When it was issued GitHub said: ${meta:-nothing readable}"
  if [[ " $PROBE_EXPIRY_OK " == *" $1 "* ]]; then
    say "TOKEN $1 expiry checked within the hour: yes"
  else
    say "TOKEN $1 expiry checked within the hour: no (the run stopped before it was checked)"
  fi
  if ! in_time; then
    say "TOKEN $1 reach not read: the clean-up's time cap (${CLEANUP_SECS}s) was reached"
    return
  fi
  TOKEN="$2"
  got="$(with_timeout "$(call_secs)" app_gh api installation/repositories --paginate --jq '.repositories[].full_name' 2>&1)" || got="unreadable: $got"
  TOKEN=""
  say "TOKEN $1 still reaches (GET /installation/repositories): $(printf '%s' "$got" | tr '\n' ' ')"
}

# The end of every a2-probe run, from the exit clean-up: settle the tokens, read back, and the
# summary and status. <status> is the one the run stopped with.
probe_finish() {
  local rc="$1" e t yes="" no=""
  probe_settle_tokens
  probe_read_back
  for e in $ISSUED; do
    t="${e#*=}"
    if [[ " $PROBE_CONFIRMED " == *" $t "* ]]; then
      yes="$yes ${e%%=*}"
    else
      no="$no ${e%%=*}"
      probe_describe "${e%%=*}" "$t"
    fi
  done
  say "TOKENS $MINTED issued; confirmed revoked:${yes:- none}; NOT confirmed:${no:- none}"
  local tokens="$PROBE_REVOKED of $MINTED tokens revoked (confirmed)${no:+, NOT confirmed:$no}"
  case "$PROBE_END" in
    done)
      if [[ $PROBE_FAILS -eq 0 && -z "$no" ]]; then
        PROBE_SUMMARY="A2 PROBE: DONE: code changes refused (P5, controls ok, branches and tags unchanged); readings$PROBE_READINGS; $tokens"
        PROBE_RC=0
      else
        PROBE_SUMMARY="A2 PROBE: DONE WITH $PROBE_FAILS PROBLEM(S), see above; readings$PROBE_READINGS; $tokens"
        PROBE_RC=1
      fi
      ;;
    STOPPED:*)
      PROBE_SUMMARY="A2 PROBE: $PROBE_END; $tokens"
      PROBE_RC=1
      ;;
    *)
      PROBE_SUMMARY="A2 PROBE: STOPPED by an error or a signal (status $rc), see above; $tokens"
      PROBE_RC="$rc"
      [[ "$PROBE_RC" != 0 ]] || PROBE_RC=1
      ;;
  esac
}

# An attempt as the app, with GitHub's whole answer kept, headers too (X-Accepted-GitHub-Permissions
# names the permission GitHub wanted). Sets OBS.
probe_attempt() { # <label> <gh api args…>
  local label="$1"
  shift
  local status
  capture app_gh api -i "$@" || true
  OBS="$(classify_api)"
  if [[ $LAST_RC -eq 0 ]]; then status="$(printf '%s\n' "$LAST_OUT" | head -n 1 | tr -d '\r')"; else status="$(http_of)"; fi
  say "ATTEMPT $label (token $PROBE_LABEL): $OBS ($status); GitHub's answer:"
  printf '%s\n' "$LAST_OUT" | tr -d '\r' | sed 's/^/    /'
}

probe_keep() { # <kind> <jq path> — after an allowed attempt, note the object by the number GitHub returned
  [[ "$OBS" == allowed ]] || return 0
  local n
  n="$(printf '%s\n' "$LAST_OUT" | tr -d '\r' | awk 'body { print } /^$/ { body = 1 }' | jq -r "$2 // empty" 2>/dev/null)" || n=""
  if [[ "$n" =~ ^[0-9]+$ ]]; then
    PROBE_MADE="$PROBE_MADE $1:$n"
    OBS_KEPT=" (kept: $1 $n)"
  else
    PROBE_FAILS=$((PROBE_FAILS + 1))
    OBS_KEPT=" (GitHub's answer holds no number: look on $REPO2 for it)"
  fi
}

probe_reading() { # <id> <what was tried>
  local how
  if [[ "$OBS" == allowed ]]; then how="allowed$OBS_KEPT"; else how="$OBS ($(http_of))"; fi
  PROBE_READINGS="$PROBE_READINGS $1=$OBS"
  say "READING $1 $2: $how"
  # Neither allowed nor refused for a permission reason (an error, a rate limit): no reading, and
  # what GitHub did is unknown, so nothing more is tried (round 49, C1).
  if [[ "$OBS" != allowed && "$OBS" != refused ]]; then
    probe_stop "$1 got no clear answer from GitHub ($(http_of)): no reading; look on $REPO2 for anything it may have made"
  fi
}

probe_refs() { # the second throwaway's branches and tags with their commits, as the owner reads them
  local h t
  h="$(owner_gh api --paginate "repos/$REPO2/git/matching-refs/heads" --jq '.[] | "\(.ref) \(.object.sha)"' 2>/dev/null)" || { echo error; return; }
  t="$(owner_gh api --paginate "repos/$REPO2/git/matching-refs/tags" --jq '.[] | "\(.ref) \(.object.sha)"' 2>/dev/null)" || { echo error; return; }
  printf '%s\n%s\n' "$h" "$t"
}

probe_refs_same() { # 1 (and both lists shown) if they changed since the run began
  local now
  now="$(probe_refs)"
  if [[ "$now" == "$REFS_BEFORE" ]]; then
    say "REFS $REPO2 unchanged: $(printf '%s' "$now" | tr '\n' ';')"
    return 0
  fi
  say "REFS $REPO2 CHANGED. Before: $(printf '%s' "$REFS_BEFORE" | tr '\n' ';') Now: $(printf '%s' "$now" | tr '\n' ';')"
  return 1
}

probe_read_back() { # each object an attempt created, as the owner reads it by its number
  local m kind n
  for m in $PROBE_MADE; do
    kind="${m%%:*}" n="${m#*:}"
    if ! in_time; then
      # Not verified, so the run can't pass (round 54, C1).
      PROBE_FAILS=$((PROBE_FAILS + 1))
      say "KEPT $kind $n: not read back, the clean-up's time cap (${CLEANUP_SECS}s) was reached; look on $REPO2 for it"
      continue
    fi
    if [[ "$kind" == comment ]]; then
      capture with_timeout "$(call_secs)" owner_gh api "repos/$REPO2/issues/comments/$n" --jq '[.id, .user.login, .user.type, .author_association, (.performed_via_github_app | tostring), .issue_url] | map(tostring) | join(" ")' || true
    else
      capture with_timeout "$(call_secs)" owner_gh api "repos/$REPO2/issues/$n" --jq '[.number, .state, .user.login, .user.type, .author_association, (.performed_via_github_app | tostring), (.pull_request != null | tostring), .title] | map(tostring) | join(" ")' || true
    fi
    if [[ $LAST_RC -eq 0 ]]; then
      say "KEPT $kind $n: $LAST_OUT"
    else
      PROBE_FAILS=$((PROBE_FAILS + 1))
      say "KEPT $kind $n: could not be read back ($(evidence)); look on $REPO2 for it"
    fi
  done
  PROBE_MADE=""
}

# P5 (claim 9a), with the full token: a file and a branch on the second throwaway must be refused.
# Controls: the same two writes on the throwaway, on a new branch (never dev, main or side).
probe_code() {
  local main2 dev b content
  main2="$(owner_gh api "repos/$REPO2/branches/main" --jq .commit.sha 2>/dev/null)" || main2=""
  [[ "$main2" =~ ^[0-9a-f]{40}$ ]] || probe_stop "can't read $REPO2's main"
  dev="$(owner_gh api "repos/$REPO/branches/dev" --jq .commit.sha 2>/dev/null)" || dev=""
  [[ "$dev" =~ ^[0-9a-f]{40}$ ]] || probe_stop "can't read $REPO's dev"
  content="$(printf 'FRG-26 A2 probe P5\n' | base64 | tr -d '\n')"
  probe_attempt "P5 file" -X PUT "repos/$REPO2/contents/frg26-probe-$(stamp).txt" -f message="FRG-26 A2 probe P5 ($(stamp))" \
    -f content="$content" -f branch="$A2_BRANCH"
  probe_code_judge "P5 file"
  probe_attempt "P5 branch" -X POST "repos/$REPO2/git/refs" -f ref="refs/heads/frg26-probe-$(stamp)" -f sha="$main2"
  probe_code_judge "P5 branch"
  b="frg26/probe/P5-$(stamp)"
  capture app_gh api -X POST "repos/$REPO/git/refs" -f ref="refs/heads/$b" -f sha="$dev" \
    || probe_stop "control: the app could not create the branch $b on $REPO ($(evidence)), so the refusals prove nothing"
  capture app_gh api -X PUT "repos/$REPO/contents/tests/frg26-probe-$(stamp).txt" -f message="FRG-26 A2 probe P5 control ($(stamp))" \
    -f content="$content" -f branch="$b" \
    || probe_stop "control: the app could not add a file to $b on $REPO ($(evidence)), so the refusals prove nothing"
  say "CONTROL P5: the app created the branch $b and a file on it, on $REPO"
  probe_refs_same || probe_stop "$REPO2's branches or tags changed"
  say "RESULT P5 code changes refused: a file and a branch on $REPO2; controls ok; its branches and tags unchanged"
}

probe_code_judge() { # <label>
  case "$OBS" in
    refused) ;;
    allowed) probe_stop "$1 on $REPO2 GOT THROUGH: a code change on a repository the app is not installed on" ;;
    *) probe_stop "$1 on $REPO2 was neither allowed nor refused for a permission reason: it proves nothing" ;;
  esac
}

probe_issue() { # <id> <what the token is> — an issue on the second throwaway, with the current token
  OBS_KEPT=""
  probe_attempt "$1" -X POST "repos/$REPO2/issues" -f title="FRG-26 A2 probe $1 ($(stamp))" \
    -f body="FRG-26 throwaway: an issue by the app, investigating test A2. Kept as evidence; safe to delete with the repository."
  probe_keep issue .number
  probe_reading "$1" "an issue, with a token $2"
}

# P3, P4 (claim 9b), with the full token: a comment on A2's issue #1, and a PR. Readings.
probe_public() {
  local ahead
  OBS_KEPT=""
  probe_attempt P3 -X POST "repos/$REPO2/issues/1/comments" \
    -f body="FRG-26 throwaway: a comment by the app, investigating test A2 ($(stamp)). Kept as evidence."
  probe_keep comment .id
  probe_reading P3 "a comment on issue #1"
  OBS_KEPT=""
  ahead="$(owner_gh api "repos/$REPO2/compare/main...$A2_BRANCH" --jq .ahead_by 2>/dev/null)" || ahead=""
  if [[ ! "$ahead" =~ ^[1-9][0-9]*$ ]]; then
    PROBE_FAILS=$((PROBE_FAILS + 1))
    OBS=not-tried
    say "READING P4 not tried: $REPO2's $A2_BRANCH is not ahead of main (ahead by '${ahead:-unreadable}')"
    PROBE_READINGS="$PROBE_READINGS P4=not-tried"
    return 0
  fi
  probe_attempt P4 -X POST "repos/$REPO2/pulls" -f title="FRG-26 A2 probe P4 ($(stamp))" -f head="$A2_BRANCH" -f base=main \
    -f body="FRG-26 throwaway: a PR by the app, investigating test A2. Kept as evidence; never merge."
  probe_keep pr .number
  probe_reading P4 "a PR from $A2_BRANCH into main"
}

cmd_a2_probe() {
  need_owner
  assert_throwaway
  assert_second
  load_app
  need_app_identity
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  PROBE_ACTIVE=1
  say "== FRG-26 A2 investigation, app $APP_BOT (id $APP_ID, installation $INSTALLATION_ID), run $RUN_ID =="
  REFS_BEFORE="$(probe_refs)"
  if [[ "$REFS_BEFORE" == error || "$REFS_BEFORE" != *"refs/heads/$A2_BRANCH "* ]]; then
    REFS_BEFORE=""
    probe_stop "can't read $REPO2's branches and tags"
  fi
  say "REFS $REPO2 before: $(printf '%s' "$REFS_BEFORE" | tr '\n' ';')"
  # C1: what a token for the whole installation reaches, then each narrowed token in turn.
  probe_token whole '{}' whole "$WANT_PERMS"
  revoke_confirmed whole
  probe_token full "{\"repositories\":[\"$REPO_NAME\"],\"permissions\":$WANT_PERMS}" narrowed "$WANT_PERMS"
  if ! app_rate || [[ "$RATE_REST" -lt $MIN_REST ]]; then
    probe_stop "the app's allowance is too low or can't be read: ${RATE_LINE:-$(evidence)}"
  fi
  say "app allowance: $RATE_LINE"
  probe_code
  probe_public
  revoke_confirmed full
  probe_token P1 "{\"repositories\":[\"$REPO_NAME\"],\"permissions\":$PROBE_PERMS_P1}" narrowed "$PROBE_PERMS_P1"
  probe_issue P1 "without Issues (contents write, metadata read)"
  revoke_confirmed P1
  probe_token P2 "{\"repositories\":[\"$REPO_NAME\"],\"permissions\":$PROBE_PERMS_P2}" narrowed "$PROBE_PERMS_P2"
  probe_issue P2 "with metadata read only"
  revoke_confirmed P2
  probe_refs_same || probe_stop "$REPO2's branches or tags changed"
  # The exit clean-up settles the tokens, reads back, and decides the status (probe_finish).
  PROBE_END="done"
  exit 0
}

# --- S2: an Environment keeps its secret from the app (plan 4.4, revised 2026-11-01) ------------
# On the throwaway only, in the open phase (no protection, so the app may push main). The value is
# a dummy, never a real secret; the workflow prints only its length.

readonly ENV_NAME=frg26-test
readonly DUMMY_NAME=FRG26_DUMMY
readonly DUMMY_VALUE=frg26-dummy-not-a-secret
readonly DISPOSABLE_NAME=FRG26_DISPOSABLE # made and deleted by S2c (its delete control)
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

env_json() { # <owner's user id> — the Environment's settings, as env-setup applies them
  printf '{"wait_timer":0,"prevent_self_review":true,"reviewers":[{"type":"User","id":%s}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}\n' "$1"
}

cmd_env_setup() {
  need_owner
  assert_throwaway
  verify_phase open
  local uid
  uid="$(owner_uid)" || die "can't read the owner's user id, so no Environment was made"
  env_json "$uid" >"$WORK/env.json"
  owner_gh api -X PUT "repos/$REPO/environments/$ENV_NAME" --input "$WORK/env.json" >/dev/null || die "making the Environment failed"
  # Only a listing GitHub actually returned decides whether main is missing (round 31, C1).
  local names
  names="$(owner_gh api "repos/$REPO/environments/$ENV_NAME/deployment-branch-policies" --jq '.branch_policies[].name' 2>/dev/null)" \
    || die "can't read the Environment's branch policies, so nothing more was changed"
  if ! printf '%s\n' "$names" | grep -Fxq main; then
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

run_log_value() { # <run id> — yes (the job printed the dummy value's length), no, or error (the
  # log couldn't be read: that is not "no value", round 13)
  local log
  log="$(owner_gh run view "$1" --repo "$REPO" --log 2>/dev/null)" || { echo error; return; }
  if grep -Fq "FRG26-S2 value length ${#DUMMY_VALUE}" <<<"$log"; then echo yes; else echo no; fi
}

# GitHub's own word on whether the owner may approve the run's waiting deployment.
can_approve() { # <run id> — true | false | error
  owner_gh api "repos/$REPO/actions/runs/$1/pending_deployments" --jq '.[0].current_user_can_approve' 2>/dev/null || echo error
}

github_refused() { # after capture: GitHub itself answered with a 4xx that isn't a rate limit
  [[ $LAST_RC -ne 0 ]] || return 1
  printf '%s' "$LAST_OUT" | grep -Eiq 'rate limit|abuse detection|secondary rate' && return 1
  printf '%s' "$LAST_OUT" | grep -Eq 'HTTP 4[0-9][0-9]'
}

# The check run's id is the last part of the job's check_run_url: an Actions job id is not a
# check-run id (round 16, C1).
deploy_job() { # <run id> — "check-run-id steps-run conclusion" of the run's deploy job, or error
  local j
  j="$(owner_gh api "repos/$REPO/actions/runs/$1/jobs" --jq '.jobs[] | select(.name == "deploy") | "\(.check_run_url | split("/") | last) \(.steps | length) \(.conclusion)"' 2>/dev/null | head -n 1)" || j=""
  printf '%s\n' "${j:-error}"
}

# GitHub's annotation when an Environment's deployment branches leave a branch out. The wording is
# Unconfirmed (the docs don't quote it): if it differs, S2a reads inconclusive and stops the run.
policy_rejected() { # <check-run id>
  owner_gh api "repos/$REPO/check-runs/$1/annotations" --jq '.[].message' 2>/dev/null | grep -Eiq 'not allowed to deploy'
}

# The ids of S2 runs not yet completed (queued, in progress, waiting…), every page; fails if the
# list can't be read. Not only waiting ones: a queued run reaches the approval gate later (round 22).
unfinished_runs() {
  owner_gh api --paginate "repos/$REPO/actions/runs?per_page=100" \
    --jq '.workflow_runs[] | select(.name == "frg26-s2" and .status != "completed") | .id' 2>/dev/null
}

# Every unfinished S2 run GitHub shows is cancelled, and confirmed finished (rounds 14, 22, 25); then
# the clean-up fails if a run may still be missing: a commit env-tests made whose run never showed
# within a minute (round 23), or a workflow commit whose sha is unknown (round 24). The visible runs
# are always dealt with first, whatever else failed (round 25, SEC-1). 1 on any failure.
cancel_waiting_runs() {
  local ids id _ sha seen unseen="" ok=""
  for sha in $S2_SHAS; do
    seen=""
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
      if [[ -n "$(runs_for "$sha")" ]]; then seen=1; break; fi
      sleep 5
    done
    [[ -n "$seen" ]] || unseen="$unseen ${sha:0:7}"
  done
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if ! ids="$(unfinished_runs)"; then
      say "CLEANUP FAIL could not list the unfinished S2 runs in $REPO: cancel any on GitHub (Actions)"
      return 1
    fi
    if [[ -z "$ids" ]]; then ok=1; break; fi
    for id in $ids; do
      if [[ ! "$id" =~ ^[0-9]+$ ]]; then say "CLEANUP FAIL unexpected run id in $REPO: cancel any unfinished S2 run on GitHub"; return 1; fi
      owner_gh api -X POST "repos/$REPO/actions/runs/$id/cancel" >/dev/null 2>&1 || true
    done
    sleep 5
  done
  if [[ -z "$ok" ]]; then
    say "CLEANUP FAIL S2 runs still unfinished in $REPO ($(printf '%s' "$ids" | tr '\n' ' ')): cancel them on GitHub (Actions)"
    return 1
  fi
  if [[ -n "$S2_UNKNOWN" ]]; then
    say "CLEANUP FAIL the S2 workflow commit's outcome is unknown, so its run may appear later: check $REPO's Actions on GitHub and cancel any S2 run there"
    return 1
  fi
  if [[ -n "$unseen" ]]; then
    say "CLEANUP FAIL the S2 runs for commit(s)$unseen never appeared within a minute: check $REPO's Actions on GitHub and cancel any S2 run there"
    return 1
  fi
  return 0
}

# S2b: the app's push to main starts a run; the app tries to approve its own deployment. Control:
# the owner approves the same run, and the job then reports the dummy value's length.
t_S2b() {
  fresh_from main "s2b-$(stamp)"
  add_commit "tests/permissions-S2b-$(stamp).txt" "FRG-26 S2b"
  # Recorded before the push: GitHub may accept it, and start its run, even if the push reports a
  # failure (round 25, C2).
  local sha eid id
  sha="$(app_git -C "$CLONE" rev-parse HEAD)" || sha=""
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { setup_fail_p S2b "could not read the local commit"; return; }
  S2_SHAS="$S2_SHAS $sha"
  capture app_git -C "$CLONE" push origin HEAD:refs/heads/main || { setup_fail_p S2b "the app could not push main in the open phase: $(evidence)"; return; }
  eid="$(env_id)" || eid=""
  [[ "$sha" =~ ^[0-9a-f]{40}$ && "$eid" =~ ^[0-9]+$ ]] || { setup_fail_p S2b "could not read the commit or the Environment"; return; }
  wait_run "$sha" waiting || { setup_fail_p S2b "the app's run never waited for review ($RUN)"; return; }
  id="${RUN%% *}"
  approve_run app_gh "$id" "$eid" || true
  OBS="$(classify_api)"
  EV="the app approving its own run: $(evidence) |"
  if [[ "$OBS" != refused ]]; then record_p S2b "$OBS" "not run" "$EV"; cancel_waiting_runs || true; return; fi
  CTL=failed
  local can
  can="$(can_approve "$id")"
  if [[ "$can" == true ]] && approve_run owner_gh "$id" "$eid" && wait_run "$sha" completed && [[ "$(run_log_value "$id")" == yes ]]; then CTL=ok; fi
  EV="$EV GitHub says the owner can approve it: $can; owner approving: $(evidence), run $RUN"
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
  # Refused needs all three (round 13, C2/SEC-2): GitHub says the owner can't approve this run, GitHub
  # itself refused the approval (a 4xx, not a network error or a rate limit), and it still waits.
  local can
  can="$(can_approve "$id")"
  approve_run owner_gh "$id" "$eid" || true
  OBS=inconclusive
  if [[ $LAST_RC -eq 0 ]]; then OBS=allowed
  elif [[ "$can" == false ]] && github_refused && wait_run "$S2_OWNER_SHA" waiting; then OBS=refused
  fi
  EV="GitHub says the owner can approve it: $can; the owner approving the owner's own run: $(evidence)"
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
  local sha id
  # Recorded before the push, as in S2b (round 25, C2).
  sha="$(app_git -C "$CLONE" rev-parse HEAD)" || sha=""
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { setup_fail_p S2a "could not read the local commit"; return; }
  S2_SHAS="$S2_SHAS $sha"
  capture app_git -C "$CLONE" push origin "HEAD:refs/heads/$br" || { setup_fail_p S2a "pushing $br failed: $(evidence)"; return; }
  wait_run "$sha" completed waiting || { setup_fail_p S2a "no run finished for $br ($RUN)"; return; }
  id="${RUN%% *}"
  # Refused needs GitHub's own rejection (round 13, C3/SEC-1): the deploy job failed without running
  # a step, and its annotation says the branch may not deploy. A run that failed for another reason,
  # or that can't be read, proves nothing.
  local job jid steps concl
  OBS=inconclusive
  if [[ "$RUN" == *" waiting "* ]]; then OBS=allowed
  else
    job="$(deploy_job "$id")"
    read -r jid steps concl <<<"$job"
    if [[ "$concl" == failure && "$steps" == 0 && "$jid" =~ ^[0-9]+$ ]] && policy_rejected "$jid"; then OBS=refused
    elif [[ "$(run_log_value "$id")" == yes ]]; then OBS=allowed
    fi
  fi
  record_p S2a "$OBS" ok "feature-branch run $RUN, deploy job ${job:-unread} (control: S2b's run on main got the value)"
  # A clean-up that failed stops the phase before S2c writes anything (round 38, C1).
  cancel_waiting_runs || FAILS=$((FAILS + 1))
}

# S2c: the app tries to change the Environment or its secrets. Each attempt's control is the same
# request by the owner (round 15, SEC-2): a no-op update (exactly env-setup's settings), the secrets'
# public key, and deleting a disposable dummy secret made for this test. The Environment must read
# unchanged afterwards.
t_S2c() {
  local uid
  uid="$(owner_uid)" || { setup_fail_p S2c "could not read the owner's user id"; return; }
  env_json "$uid" >"$WORK/env.json"
  if ! capture owner_gh secret set "$DISPOSABLE_NAME" --env "$ENV_NAME" --repo "$REPO" --body "$DUMMY_VALUE"; then
    setup_fail_p S2c "could not make the disposable dummy secret: $(evidence)"
    return
  fi
  p_attempts api app_gh api -X PUT "repos/$REPO/environments/$ENV_NAME" --input "$WORK/env.json" ";;" \
    app_gh api "repos/$REPO/environments/$ENV_NAME/secrets/public-key" ";;" \
    app_gh api -X DELETE "repos/$REPO/environments/$ENV_NAME/secrets/$DISPOSABLE_NAME"
  if [[ "$OBS" != refused ]]; then
    # The stop rule (round 28, C1): nothing more is written after an attempt that wasn't refused.
    record_p S2c "$OBS" "not run" "$EV (the disposable dummy secret $DISPOSABLE_NAME is left in the Environment for you to see and delete)"
    return
  fi
  p_controls owner_gh api -X PUT "repos/$REPO/environments/$ENV_NAME" --input "$WORK/env.json" ";;" \
    owner_gh api "repos/$REPO/environments/$ENV_NAME/secrets/public-key" ";;" \
    owner_gh api -X DELETE "repos/$REPO/environments/$ENV_NAME/secrets/$DISPOSABLE_NAME"
  [[ "$(env_summary)" == "$(want_env)" ]] || { CTL=failed; EV="$EV the Environment reads '$(env_summary)' afterwards |"; }
  record_p S2c "$OBS" "$CTL" "$EV"
}

readonly S2_TEST_ORDER="S2b S2d S2a S2c"
S2_OWNER_SHA=""
S2_SHAS="" # every commit env-tests made that starts an S2 run (round 22, C2)
S2_UNKNOWN="" # set while the owner's workflow commit may have happened but its sha isn't known
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
  # The owner adds the workflow to main: that commit starts the owner's own run (S2d's). Its sha comes
  # from the write's own answer; until it is known the outcome counts as unknown, which the clean-up
  # can't reconcile and reports (round 24, SEC-1).
  CANCEL_ON_EXIT=1
  S2_UNKNOWN=1
  S2_OWNER_SHA="$(put_file_commit "$S2_WORKFLOW" "$(s2_workflow)" 2>/dev/null)" || S2_OWNER_SHA=""
  [[ "$S2_OWNER_SHA" =~ ^[0-9a-f]{40}$ ]] || die "adding the S2 workflow failed, or its commit is unknown"
  S2_SHAS="$S2_SHAS $S2_OWNER_SHA"
  S2_UNKNOWN=""
  local id
  for id in $S2_TEST_ORDER; do
    # A fresh clone each time: S2b moves main.
    rm -rf "$CLONE"
    app_git clone -q --template="$WORK/template" "https://github.com/$REPO.git" "$CLONE" || die "clone failed"
    "t_$id"
    if [[ $FAILS -ne 0 ]]; then
      CANCEL_ON_EXIT=""
      cancel_waiting_runs || true
      say "ENVIRONMENT TESTS: STOPPED after $id"
      exit 1
    fi
  done
  CANCEL_ON_EXIT=""
  if ! cancel_waiting_runs; then
    say "ENVIRONMENT TESTS: FAILED at the final clean-up (a run may still wait for review)"
    exit 1
  fi
  say "ENVIRONMENT TESTS: ALL PASS (run reset next: main holds the S2 workflow)"
  exit 0
}

# --- Held tokens: A4, A9b, E1, E2, E3 (plan 4.3, revised 2026-11-01) --------------------------
# Some tests need a token issued earlier: one over an hour old (A4), or one issued before a key is
# deleted or the app is suspended, uninstalled or deleted. Such a token is "held": kept until its
# check, then revoked (if it still works) and removed. Held tokens are VAR=value lines in a mode-600
# file beside the app's key, HELD_AGE=<token> with HELD_AGE_AT=<when it was issued>, so a handoff's
# ho_redact_file can hide them too. The file is always rewritten whole (a temp file, then a move), so
# a token is never recorded without its time (round 15, C1/SEC-3). What GitHub does with each is
# recorded; where GitHub's docs are silent it is a reading.

HELD="$(dirname "$SECRETS")/held-tokens.env"
# A held token this old (55 minutes) is near its hour: if it is refused, plain expiry could explain it,
# so A9b, E1, E2 and E3 give no reading then (round 18, C1). A4 is the expiry test.
readonly FRESH_MAX=3300
INCONCLUSIVE=0
STATE="$(dirname "$SECRETS")/frg26-state"

held_var() { printf 'HELD_%s' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"; }

# One step at a time reads and rewrites the held file (round 19, C1): mkdir either makes the lock or
# fails, atomically. The exit clean-up releases it.
HELD_LOCKED=""
held_lock() {
  [[ -n "$HELD_LOCKED" ]] && return 0
  mkdir "$HELD.lock" 2>/dev/null \
    || die "another FRG-26 step is using the held tokens (if none is running, one stopped uncleanly: remove $HELD.lock, then run this step again)"
  HELD_LOCKED=1
}

held_get() { # <name> — prints "token issued-epoch" or fails
  [[ -f "$HELD" && ! -L "$HELD" ]] || return 1
  local v tok at
  v="$(held_var "$1")"
  tok="$(sed -n "s/^$v=\(ghs_[A-Za-z0-9._-]*\)$/\1/p" "$HELD" | tail -n 1)"
  at="$(sed -n "s/^${v}_AT=\([0-9][0-9]*\)$/\1/p" "$HELD" | tail -n 1)"
  [[ -n "$tok" && -n "$at" ]] || return 1
  printf '%s %s\n' "$tok" "$at"
}

held_present() { # <name> — any line for it, complete or not
  [[ -f "$HELD" ]] && grep -Eq "^$(held_var "$1")(_AT)?=" "$HELD"
}

# Rewrites the held file whole: every other name's lines, plus (with a token) this name's two.
held_write() { # <name> [token]
  local v tmp
  v="$(held_var "$1")"
  tmp="$(umask 077 && mktemp "$HELD.XXXXXX" 2>/dev/null)" || return 1
  if [[ -f "$HELD" ]]; then grep -Ev "^$v(_AT)?=" "$HELD" >"$tmp"; [[ $? -le 1 ]] || { rm -f "$tmp"; return 1; }; fi
  if [[ -n "${2:-}" ]]; then printf '%s=%s\n%s_AT=%s\n' "$v" "$2" "$v" "$(date +%s)" >>"$tmp" || { rm -f "$tmp"; return 1; }; fi
  if ! chmod 600 "$tmp" || ! mv -f "$tmp" "$HELD"; then rm -f "$tmp"; return 1; fi
}

held_drop() { # <name> — 1 if the record couldn't be removed (round 18, C2)
  held_write "$1"
}

held_reading() { # <id> <text> — what a revocation did to a held token, unless expiry could explain it
  if [[ "$HELD_RESULT" != works && $HELD_AGE -ge $FRESH_MAX ]]; then
    INCONCLUSIVE=1
    say "READING $1 INCONCLUSIVE: $2 (the token was $HELD_AGE s old, near its hour: expiry alone could explain the refusal, so this doesn't correct the plan)"
  else
    reading "$1" "$2"
  fi
}

state_set() { # <key> <value> — the file is rewritten whole; 1 if that failed (round 17, C1)
  local tmp
  tmp="$(umask 077 && mktemp "$STATE.XXXXXX" 2>/dev/null)" || return 1
  if [[ -f "$STATE" ]]; then grep -v "^$1 " "$STATE" >"$tmp"; [[ $? -le 1 ]] || { rm -f "$tmp"; return 1; }; fi
  printf '%s %s\n' "$1" "$2" >>"$tmp" || { rm -f "$tmp"; return 1; }
  if ! chmod 600 "$tmp" || ! mv -f "$tmp" "$STATE"; then rm -f "$tmp"; return 1; fi
}

state_get() { [[ -f "$STATE" ]] && sed -n "s/^$1 //p" "$STATE" | tail -n 1; }

# hold-token <name>: a second narrowed token, kept for a later check; the session's own token is
# revoked as usual when the script ends.
cmd_hold_token() {
  local name="${1:-}"
  [[ "$name" =~ ^(age|keyold|suspend|uninstall|delete)$ ]] || die "usage: hold-token age|keyold|suspend|uninstall|delete"
  need_owner
  assert_throwaway
  held_lock
  app_session
  # A retried step must not abandon the token it held before (round 14, SEC-2): settle that one
  # first, and hold nothing new while it is unsettled.
  if held_get "$name" >/dev/null; then
    use_held "$name"
    if held_get "$name" >/dev/null; then die "the token held earlier as '$name' couldn't be revoked: run this step again"; fi
    say "the token held earlier as '$name' was settled first ($HELD_RESULT)"
  elif held_present "$name"; then
    die "$HELD has an incomplete record for '$name' (a token without its time, or the reverse): check it before holding another"
  fi
  local session="$TOKEN" held
  mint_token
  held="$TOKEN"
  REDACT_ONLY="$REDACT_ONLY $held"
  # Stored whole, or revoked at once: a token is never left without its record (round 15, C1/SEC-3).
  if ! held_write "$name" "$held"; then
    if revoke_token; then TOKEN="$session"; die "storing the held token failed; it was revoked"; fi
    TOKEN="$session"
    die "storing the held token failed, and revoking it failed too: GitHub expires it within an hour"
  fi
  outstanding_drop "$held"
  TOKEN="$session"
  say "held token '$name' stored (issued $(date -u +%Y-%m-%dT%H:%M:%SZ), used only by its check)"
}

# Sets HELD_RESULT ("works" or GitHub's status) and HELD_AGE. Revocation is tried whatever the read
# says (round 13, C4/SEC-6); the token is removed only once that is settled: revoked, refused as bad
# credentials (401), or ("final") its installation or app is gone. If GitHub couldn't be read
# reliably (no HTTP answer, a server error, a rate limit), the step stops and keeps the token.
use_held() { # <name> [final]
  local line tok
  line="$(held_get "$1")" || die "no held token '$1': run hold-token $1 first"
  tok="${line%% *}"
  REDACT_ONLY="$REDACT_ONLY $tok"
  HELD_AGE=$(( $(date +%s) - ${line##* } ))
  local session="$TOKEN"
  TOKEN="$tok"
  capture app_gh api "repos/$REPO" --jq .full_name || true
  if [[ $LAST_RC -eq 0 && "$LAST_OUT" == "$REPO" ]]; then HELD_RESULT=works
  elif github_refused; then HELD_RESULT="$(http_of)"
  else
    # Revocation is still tried (round 14, C2). Revoked: removed, and this reading is lost.
    # Not revoked: kept for a retry. Either way the step stops.
    local ev
    ev="$(evidence)"
    if revoke_token; then
      TOKEN="$session"
      held_drop "$1" || die "couldn't remove the held record '$1' from $HELD (its token was revoked): delete its $(held_var "$1") lines by hand"
      die "GitHub couldn't be read reliably with the held token '$1' ($ev); it was revoked, so this reading is lost: hold a new token and check again"
    fi
    TOKEN="$session"
    die "GitHub couldn't be read reliably with the held token '$1' ($ev), nor could it be revoked; it is kept: run this step again"
  fi
  local settled=no
  if revoke_token; then settled=yes
  elif [[ "$HELD_RESULT" == "HTTP 401" ]] || [[ "${2:-}" == final && "$HELD_RESULT" != works ]]; then settled=yes
  fi
  TOKEN="$session"
  if [[ $settled == yes ]]; then
    held_drop "$1" || die "couldn't remove the held record '$1' from $HELD (its token is settled): delete its $(held_var "$1") lines by hand before going on"
  else
    say "note: the held token '$1' read $HELD_RESULT and couldn't be revoked now; it stays held for a later step (it expires within an hour of $(date -u -r "${line##* }" +%H:%M:%SZ) anyway)"
  fi
}

# A4: a token over an hour old is refused. Control: a fresh token, the same read.
cmd_token_age_check() {
  need_owner
  assert_throwaway
  held_lock
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
  held_lock
  load_app
  local new
  new="$(dirname "$APP_KEY")/app-new.pem"
  [[ -f "$new" && ! -L "$new" && "$(stat -f %Lp "$new")" == 600 ]] || die "missing $new (mode 600): the new key's handoff step stores it"
  local old="$APP_KEY"
  # The installation, read with the new key (the old one is deleted).
  APP_KEY="$new"
  need_app_identity
  # A9 (round 19, C2): a token request signed with the deleted key must be refused; the control is
  # the same request signed with the new key, whose token is then revoked.
  jwt_with "$old"
  printf '%s\n' "{\"repositories\":[\"$REPO_NAME\"],\"permissions\":$WANT_PERMS}" >"$WORK/token-request.json" \
    || die "writing the token request failed"
  jwt_call POST "app/installations/$INSTALLATION_ID/access_tokens" "$WORK/token-request.json" || true
  local obs=inconclusive old_http="$LAST_HTTP" t
  case "$old_http" in
    2*)
      obs=allowed
      # Whatever GitHub issued, in any form, is revoked (round 33, C1).
      t="$(jq -r '.token // empty' <<<"$LAST_OUT" 2>/dev/null)" || t=""
      if [[ -n "$t" ]]; then TOKEN="$t"; OUTSTANDING="$OUTSTANDING $t"; revoke_token; fi
      ;;
    401) obs=refused ;;
  esac
  LAST_OUT=""
  make_jwt
  local ctl=failed
  if control_token mint_token; then ctl=ok; fi
  FAILS=0
  record_p A9 "$obs" "$ctl" "a token request signed with the deleted key: HTTP ${old_http:-none}; with the new key: $ctl"
  use_held keyold
  held_reading A9b "a token issued before the key was deleted, $HELD_AGE s later: $HELD_RESULT"
  [[ $FAILS -eq 0 ]] || exit 1
  # Not before the old key's token is settled (round 16, SEC-1): app-new.pem stays where it is, so
  # running this step again retries the revocation.
  if held_get keyold >/dev/null; then die "the token held over the key change couldn't be revoked: run this step again"; fi
  # The configured key path, whatever its name (round 26, C1).
  mv "$new" "$old" || die "putting the new key at $old failed"
  [[ $INCONCLUSIVE -eq 0 ]] || exit 1
}

# E1, first half (the owner has just suspended the installation): a new token is refused; what a
# token issued before the suspension does is recorded. The verdict waits for the control.
cmd_suspend_check() {
  need_owner
  assert_throwaway
  held_lock
  load_app
  make_jwt
  jwt_call GET "app/installations?per_page=100" || die "can't list the app's installations: $(evidence)"
  local inst sus
  inst="$(jq -c --arg o "$OWNER" '[.[] | select(.account.login == $o)] | if length == 1 then .[0] else empty end' <<<"$LAST_OUT" 2>/dev/null)" || inst=""
  [[ -n "$inst" ]] || die "the app must still be installed (suspended) on $OWNER's account"
  sus="$(jq -r .suspended_at <<<"$inst")"
  [[ "$sus" != null ]] || die "the installation is not suspended: suspend it first"
  INSTALLATION_ID="$(jq -r .id <<<"$inst")"
  # An earlier observation must never be judged as this one: it is cleared first, and this one must
  # be stored, or the step stops (round 17, C1).
  state_set E1 "pending HTTP-none" || die "can't write $STATE, where this step's observation is kept"
  state_set E1_HELD pending || die "can't write $STATE, where this step's observation is kept"
  state_set E1_AFTER none || die "can't write $STATE, where this step's observation is kept"
  printf '%s\n' "{\"repositories\":[\"$REPO_NAME\"],\"permissions\":$WANT_PERMS}" >"$WORK/token-request.json"
  jwt_call POST "app/installations/$INSTALLATION_ID/access_tokens" "$WORK/token-request.json" || true
  local obs=inconclusive
  if [[ "$LAST_HTTP" =~ ^2 ]]; then
    obs=allowed
    # On the exit clean-up's list before it is revoked, so a failed revocation is tried again
    # (round 27, SEC-1; as key-check does).
    local t
    t="$(jq -r '.token // empty' <<<"$LAST_OUT" 2>/dev/null)" || t=""
    LAST_OUT=""
    # Whatever GitHub issued, in any form (round 33, C1).
    if [[ -n "$t" ]]; then TOKEN="$t"; OUTSTANDING="$OUTSTANDING $t"; revoke_token; fi
  elif [[ "$LAST_HTTP" =~ ^(401|403|404)$ ]] && ! grep -Eiq 'rate limit|abuse detection' <<<"$LAST_OUT"; then obs=refused
  fi
  state_set E1 "$obs HTTP-${LAST_HTTP:-none}" || die "can't store this step's observation in $STATE: run it again"
  use_held suspend
  held_reading E1 "a token issued before the suspension (suspended at $sus): $HELD_RESULT (issued $HELD_AGE s earlier)"
  # Stored, so a later or repeated unsuspend-check can't pass without it (round 21, C1).
  if [[ $INCONCLUSIVE -ne 0 ]]; then state_set E1_HELD inconclusive; else state_set E1_HELD ok; fi \
    || die "can't store this step's held-token reading in $STATE: run the E1 steps again"
  say "E1 a new token while suspended: $obs (HTTP ${LAST_HTTP:-none}); the verdict follows after you unsuspend"
  if [[ $INCONCLUSIVE -ne 0 ]]; then
    say "stopping here: unsuspend the app in your browser (Settings, Applications, Installed GitHub Apps, Configure, Unsuspend)"
    exit 1
  fi
}

# E1, second half (the owner has unsuspended): the control, a new token, must work.
cmd_unsuspend_check() {
  need_owner
  assert_throwaway
  held_lock
  local first
  first="$(state_get E1)" || first=""
  [[ -n "$first" ]] || die "run suspend-check first"
  local ctl=failed
  # In a subshell (a failed session must not end this step), which revokes its own token when it
  # ends: the EXIT trap isn't inherited (round 13, C1/SEC-3).
  if control_token app_session; then ctl=ok; fi
  # The installation exists again, so this is not "final" (round 14, SEC-1): a token that can't be
  # revoked stays held, and the step fails so it is run again.
  if held_get suspend >/dev/null; then
    # Before the held token is used: "pending", so a failed run or a failed write never leaves an
    # earlier "ok" for a retry to accept (round 22, SEC-1).
    # Its own record, E1_AFTER: a token that works after unsuspending says nothing about what the
    # suspension did, so it never replaces the suspension's reading (round 23, C2).
    state_set E1_AFTER pending || die "can't write $STATE, where E1's reading is kept: nothing was used; run this step again"
    use_held suspend
    held_reading E1 "the token issued before the suspension, after unsuspending: $HELD_RESULT (issued $HELD_AGE s earlier)"
    if [[ $INCONCLUSIVE -ne 0 ]]; then state_set E1_AFTER inconclusive; else state_set E1_AFTER ok; fi \
      || die "can't store E1's reading in $STATE: do E1 again"
    if held_get suspend >/dev/null; then die "the token held over the suspension couldn't be revoked: run this step again"; fi
  fi
  FAILS=0
  record_p E1 "${first%% *}" "$ctl" "a new token while suspended: ${first#* }; after unsuspending: $ctl"
  # E1 is complete only with a conclusive held-token reading from this suspension cycle (round 21,
  # C1): an inconclusive, unfinished or missing one means doing E1 again.
  local held_state after_state
  held_state="$(state_get E1_HELD)" || held_state=""
  after_state="$(state_get E1_AFTER)" || after_state=""
  if [[ "$held_state" != ok || ( "$after_state" != ok && "$after_state" != none ) ]]; then
    say "E1's held-token readings are '${held_state:-missing}' (while suspended) and '${after_state:-missing}' (after): do E1 again (hold-token suspend, suspend in your browser, suspend-check, unsuspend, unsuspend-check)"
    return 1
  fi
  [[ $FAILS -eq 0 && $INCONCLUSIVE -eq 0 ]]
}

# E2 (the owner has just uninstalled the app): what a token issued before does is recorded, and
# GitHub must list no installation for the owner.
cmd_uninstall_check() {
  need_owner
  assert_throwaway
  held_lock
  load_app
  make_jwt
  jwt_call GET "app/installations?per_page=100" || die "can't list the app's installations: $(evidence)"
  local n
  n="$(jq --arg o "$OWNER" '[.[] | select(.account.login == $o)] | length' <<<"$LAST_OUT" 2>/dev/null)" || n=error
  [[ "$n" == 0 ]] || die "the app is still installed on $OWNER's account ($n installations): uninstall it first"
  use_held uninstall final
  held_reading E2 "a token issued before the uninstall: $HELD_RESULT (issued $HELD_AGE s earlier)"
  # A token that still works stays held if it couldn't be revoked (round 19, SEC-1).
  if held_get uninstall >/dev/null; then die "the token issued before the uninstall still works and couldn't be revoked: it stays held; run this step again"; fi
  [[ $INCONCLUSIVE -eq 0 ]] || exit 1
}

# E3 (the owner has just deleted the app): what a token issued before does is recorded, and the
# app's own key must be refused.
cmd_delete_check() {
  need_owner
  assert_throwaway
  held_lock
  load_app
  make_jwt
  jwt_call GET app || true
  # Only GitHub's own answer counts (round 13, C5/SEC-7): 401 or 404. No answer or a server error
  # proves nothing, and the held token is kept.
  [[ ! "$LAST_HTTP" =~ ^2 ]] || die "GitHub still knows the app: delete it first"
  [[ "$LAST_HTTP" == 401 || "$LAST_HTTP" == 404 ]] || die "GitHub didn't confirm the app is gone (HTTP ${LAST_HTTP:-none}): run this step again"
  local gone="HTTP $LAST_HTTP"
  use_held delete final
  held_reading E3 "a token issued before the app was deleted: $HELD_RESULT (issued $HELD_AGE s earlier); the app's own key now gets $gone"
  if held_get delete >/dev/null; then die "the token issued before the app was deleted still works and couldn't be revoked: it stays held; run this step again"; fi
  [[ $INCONCLUSIVE -eq 0 ]] || exit 1
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
    a2-probe) cmd_a2_probe ;;
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
    *) die "usage: github-throwaway.sh create|create-second|check-app|rate|allowance|reset|protect|unprotect|ruleset|tests <phase>|ptests|a2-probe|env-setup|env-tests|hold-token <name>|token-age-check|key-check|suspend-check|unsuspend-check|uninstall-check|delete-check|actions-setting|status" ;;
  esac
}

# Run main when executed as a file or as `bash -p -c "<this script>" frg26 <command>` (the
# handoffs), but not when a test sources it.
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
