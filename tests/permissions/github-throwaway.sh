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
#       branch, one file; create-second); after that only the app tries code changes (a push, a
#       file and a branch), which must be refused (the app is not installed there); the owner only
#       reads it. A2 failed on 2026-11-11 (an issue got through); a2-probe then tried more there,
#       as the app; since 2026-11-15 A2 no longer tries an issue (owner)
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
REVOKE_SENT="" # tokens a revocation request went out for (round 84): revoke_outstanding counts by them
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
UNRECEIVED=""    # per token request with no complete answer: label, when it was sent (this Mac's clock), the request
PENDING_MINT=""  # the token request in progress, in the same form, until its answer is settled
JWT_ERR=""
JWT_RC=0
MINT_LABEL=""    # the name mint gives the next token (a2-probe: whole full P1 P2)
readonly CALL_SECS=20     # the longest a GitHub API request (gh, curl) or a local git command may take
readonly PUSH_SECS=60     # the longest a git push or fetch may take (round 75, C1)
readonly CLONE_SECS=120   # the longest a git clone may take (round 75, C1)
readonly REVOKE_SECS=90   # the clean-up's first share, for the tokens alone (round 72, SEC-1)
readonly CLEANUP_SECS=180 # the longest the whole clean-up may take
readonly CONTROL_SECS=240 # the longest a control (A9, E1) may run, its own token clean-up included
readonly LIST_SECS=60     # no page of a baseline's list (or ruleset by id) is asked once this has passed (round 116)
readonly PAGE_SIZE=100    # the entries asked for on each page of a list (GitHub's most)
readonly PAGE_MAX=10      # the most pages with entries a baseline's list may have (1,000 entries), and then the empty one (rounds 116-117)
readonly TAG_MAX=100      # the most tags A2's baseline looks up, each by its exact ref (round 117)
# Round 115 (owner): the app's API attempts go through the system's own curl, by this path only: it is on
# macOS's sealed, read-only system volume, so no process running as the owner can replace it. That
# narrows the replacement risk; it does NOT protect it from same-user debugging (an open limit, not
# accepted).
readonly APP_API_CURL="/usr/bin/curl" # the app's API attempts' only program
readonly FD_LIST="/dev/fd" # where a process's own open descriptors are listed (round 116)
CLEANUP_DEADLINE=""
HELD_KEPT=""        # tokens this run stored for a later check: never revoked by its clean-up
CONFIRMED_TOKENS="" # tokens confirmed revoked, outside a2-probe: see revocation_judged
REVOKE_OK=""        # tokens whose revocation GitHub answered as done (round 74, SEC-2)
UNCONFIRMABLE=""    # token:kind for each token a read refused but whose revocation can't be confirmed
CLEANUP_UNDONE=""   # every tidy-up left undone, on any finish, for the clean-up's last line
RUN_ISSUES=""       # test issues this run made, by the number their create returned (round 102)
ISSUES_CLOSE_SENT="" # test issues whose close this run has sent: never sent twice
ISSUES_CLOSED=""    # test issues read back closed, by number, named in the clean-up's last line
PENDING_CREATE=""   # a test issue's create from before it is sent until its answer is settled (round 102)
ISSUES_SWEEP_BEGUN="" # set when sweep_issues starts, and ISSUES_SWEPT when it has ended (round 102)
ISSUES_SWEPT=""
CONTROLS=0          # controls started (A9, E1), each named control<n> before it can ask for a token
CONTROL_ID=""       # inside a control: its name, which its tokens' names start with
CONTROL_PENDING=""  # controls that haven't said they are done: their tokens count as NOT confirmed
CONTROL_CONFIRMED="" # names of control tokens their control confirmed revoked (HTTP 401)
CONTROL_UNCONFIRMED="" # names of control tokens their control could not confirm
CONTROL_PID=""      # the control running now, in the background (round 74, C1, SEC-1)
CONTROL_NAME=""     # its name
CONTROL_WATCH=""    # its watchdog
CONTROL_WRAP=""     # the wrapper whose unnamed pipe (fd 8) brings its status, and only that (round 110)
CONTROL_LINES=""    # what has come through that pipe after the process id
CONTROL_PARTIAL=""  # set if a line came cut short
CONTROL_KILLED=""   # set if it was stopped outright
CONTROL_MINTED_AT=0 # MINTED as it started: its token is named <id>-token<this + 1>
CONTROL_END_S=0     # its end, and when its watchdog tells it to stop, in the shell's SECONDS
CONTROL_TOLD_AT_S=0
CONTROL_RC=""       # its exit status (control_exit's bits), as its wrapper said it, once judged
CONTROL_TOLD=""     # set once a stop has been passed on to it
CONTROL_UNREC=""    # the requests it reports as possibly issued, never received
CONTROL_END=""      # inside a control: when its own clean-up must have ended
REQ_JOBS=""         # the requests (and waits) this shell has running, stopped whole by a stop
# Set (local) while a tidy-up runs (sweep_prs, sweep_issues, cancel_waiting_runs): as in the
# clean-up, its requests are bounded, and one with no answer in time is named as left undone by the
# tidy-up itself (round 73, C2) rather than stopping the run (round 75); a write among them is
# named outcome unknown too unless a read-back settles it (round 77).
TIDY_UP=""
TIMED_OUT=""        # the limit (seconds) of the request with_timeout last stopped in this shell
#                     for want of an answer; empty if it ended by itself or was never sent
STOP_WHY=""         # why the run stopped, said first by the clean-up (a request that timed out)
LAST_HTTP=""
WORK=""
WORK_MADE=""        # the work folder make_work made, which the clean-up never deletes (round 96)
# Round 109 (owner, 2026-11-25): the state of the run's writes is kept here, in the run's own shell,
# never in a file. A write is noted before it is sent and cleared only once its answer is stored and
# is the one its operation expects (round 110: answer_expected); any other answer, a lost or
# malformed one, or a failure leaves it outcome unknown, until an authoritative read-back settles it.
IR_EXPECT=""        # the answer a WRITE_HELPERS function's write expects (into_req)
WRITES_OUT=""       # writes sent and not yet answered, one per line: <n> <what>
WRITES_UNKNOWN=""   # writes whose outcome is unknown, one per line: <what> (<why>)
WRITE_SEQ=0
STOP_LINES=""       # requests with no answer within their limit, one per line: why the run stops
IN_JOB=""           # set inside into's job: its write and timeout are the run's shell's to note; a
#                     timeout there ends the job with 124, which into in the run's shell records
STOPS_HELD=""       # set while stops are ignored (a clean-up) or held (defer_signals): into then
#                     holds each answer in memory, through a command substitution (round 108)
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
  local rc=$? start incomplete=0
  # Once the clean-up starts it runs to its end: a second Ctrl-C, closing the window or a kill no
  # longer stops it (round 52, owner-approved). It is bounded in time instead: every GitHub call in
  # it is given at most CALL_SECS, never more than is left (the whole process tree is stopped at
  # its limit), and every wait and loop checks the cap: the whole clean-up ends within CLEANUP_SECS
  # plus a few seconds (the last call may end up to a second past it; the local work after it).
  trap '' HUP INT TERM
  # Stops are ignored from here, so each answer is held in memory (into, rounds 108-109).
  STOPS_HELD=1
  start=$(date +%s)
  # A request a stop found running is stopped first, with everything it started (round 75, C1).
  stop_requests
  if [[ -n "$STOP_WHY" ]]; then say "$STOP_WHY"; fi
  if [[ -n "$PROBE_ACTIVE" ]]; then
    # Every way out of a2-probe ends here: its tokens are settled and checked, what it made is read
    # back, and its result decides the exit status (rounds 47, 52).
    CLEANUP_DEADLINE=$((start + CLEANUP_SECS))
    PROBE_ACTIVE=""
    probe_finish "$rc"
    if [[ -n "$PENDING_MINT" || -n "$UNRECEIVED" ]]; then report_unreceived; fi
    revoke_outstanding
  else
    # Round 109: the clean-up uses no folder; what it reports is in the run's own memory.
    cleanup_tokens_first "$rc" "$start" || incomplete=1
  fi
  if [[ -n "$HELD_LOCKED" ]]; then rmdir "$HELD.lock" 2>/dev/null || true; HELD_LOCKED=""; fi
  # a2-probe's summary is the last line, which the owner's handoff result shows (round 48).
  if [[ -n "$PROBE_SUMMARY" ]]; then say "$PROBE_SUMMARY"; fi
  if [[ -n "$PROBE_RC" ]]; then exit "$PROBE_RC"; fi
  # Any other command: a clean-up not shown complete is never a success (round 72, SEC-1).
  if [[ $incomplete -ne 0 && $rc -eq 0 ]]; then exit 1; fi
}

# Every other command's clean-up (round 72, SEC-1). The tokens first, alone, within REVOKE_SECS of
# its start, so no tidy-up can keep a token from its revocation; then the tidy-up (test PRs and
# issues, waiting S2 runs) and a last try for any token not yet confirmed, within CLEANUP_SECS.
# A step the deadline leaves out is named as not done. Ends with one line naming each token
# confirmed revoked (a read with it got HTTP 401) or not, and what was left undone; 1 unless the
# clean-up is shown complete.
cleanup_tokens_first() { # <status> <start>
  CLEANUP_DEADLINE=$(($2 + REVOKE_SECS))
  settle_register
  # Requests that may have issued a token never received (round 61, C1).
  if [[ -n "$PENDING_MINT" || -n "$UNRECEIVED" ]]; then report_unreceived; fi
  settle_tokens "the clean-up's share for tokens (${REVOKE_SECS}s) was used up; tried again after the tidy-up if time allows"
  CLEANUP_DEADLINE=$(($2 + CLEANUP_SECS))
  # Each tidy-up records what it leaves undone itself, here as on a normal finish (round 73, C2).
  local swept=""
  if [[ -n "$SWEEP_ON_EXIT" ]]; then
    SWEEP_ON_EXIT=""
    say "PHASE $PHASE: STOPPED by an error (status $1); closing the open test PRs"
    sweep_prs || true
    if [[ "$PHASE" == permissions ]]; then sweep_issues; swept=1; fi
  fi
  # A permission run stopped before its issue sweep ended (the final one, run after SWEEP_ON_EXIT is
  # cleared, included), with that sweep begun or an issue of its not read back closed: the sweep
  # resumes here, within the cap; a close already started is only read back (round 92, SEC-2).
  if [[ "$PHASE" == permissions && -z "$swept" && -z "$ISSUES_SWEPT" ]] && [[ -n "$ISSUES_SWEEP_BEGUN" || -n "$(issues_unconfirmed)" ]]; then
    say "PHASE permissions: stopped before its test issues were swept; sweeping them now"
    sweep_issues
  fi
  if [[ -n "$CANCEL_ON_EXIT" ]]; then
    CANCEL_ON_EXIT=""
    cancel_waiting_runs || true
  fi
  # A control the stop found running settles its own tokens meanwhile, told to stop as the stop came;
  # its record is collected here, by the clean-up's cap at the latest (round 74, C1, SEC-1).
  if [[ -n "$CONTROL_PID" ]]; then control_collect; fi
  settle_tokens "the clean-up's time cap (${CLEANUP_SECS}s) was reached"
  cleanup_summary
}

# The token in use is always settled, as before, unless it is held for a later check; any token to
# settle that has no name yet is named "unnamed" (inside a control, after it), so it is checked and
# reported like the rest.
settle_register() {
  local t
  if [[ -n "$TOKEN" && " $OUTSTANDING $HELD_KEPT " != *" $TOKEN "* ]]; then OUTSTANDING="$OUTSTANDING $TOKEN"; fi
  for t in $OUTSTANDING; do
    [[ " $ISSUED " == *"=$t "* ]] || ISSUED="$ISSUED ${CONTROL_ID:+$CONTROL_ID-}unnamed=$t"
  done
}

undone() { # <what> — a tidy-up left undone, named once in the clean-up's last line (round 73, C2)
  [[ "$CLEANUP_UNDONE" == *" $1 (CLEANUP FAIL above);"* ]] || CLEANUP_UNDONE="$CLEANUP_UNDONE $1 (CLEANUP FAIL above);"
}

# label=token for each token of this run not yet confirmed revoked and not held, in issue order;
# one a read refused but whose revocation can't be confirmed is past trying (revocation_judged).
settle_list() {
  local e t
  for e in $ISSUED; do
    t="${e#*=}"
    [[ " $CONFIRMED_TOKENS $HELD_KEPT " == *" $t "* || " $UNCONFIRMABLE " == *" $t:"* ]] || printf '%s\n' "$e"
  done
  return 0
}

# Every token of the run's own not yet confirmed revoked: first a revocation for each one still
# outstanding, before any check, those the clean-up hasn't tried yet ahead of retries, so a hung
# call never keeps another token from its revocation; then a read with each, where HTTP 401 alone
# never confirms (revocation_judged). One a read doesn't refuse goes back on OUTSTANDING, for the
# last try. A step the deadline leaves out is named, with <why>.
SETTLE_TRIED="" # tokens whose revocation the clean-up has tried
settle_tokens() { # <why>
  local e t label pass why before="$SETTLE_TRIED"
  for pass in new again; do
    for e in $(settle_list); do
      t="${e#*=}" label="${e%%=*}"
      [[ " $OUTSTANDING " == *" $t "* ]] || continue
      if [[ " $before " == *" $t "* ]]; then [[ $pass == again ]] || continue; else [[ $pass == new ]] || continue; fi
      if ! call_budget; then
        if [[ $pass == new ]]; then say "TOKEN $label revocation not tried: $1"; else say "TOKEN $label revocation not tried again: $1"; fi
        continue
      fi
      SETTLE_TRIED="$SETTLE_TRIED $t"
      TOKEN="$t"
      revoke_token "$CALL_BUDGET" || true
    done
  done
  for e in $(settle_list); do
    t="${e#*=}" label="${e%%=*}"
    if ! call_budget; then
      say "TOKEN $label not checked yet: $1"
      continue
    fi
    if token_refused "$t" "$CALL_BUDGET"; then
      revocation_judged "$label" "$t"
    else
      [[ " $OUTSTANDING " == *" $t "* ]] || OUTSTANDING="$OUTSTANDING $t"
      why="$(evidence)"
      [[ $LAST_RC -ne 124 ]] || why="no answer within its time limit"
      say "TOKEN $label NOT confirmed revoked: a read with it did not get HTTP 401 ($why)"
    fi
  done
}

# After a read with a token got HTTP 401 (round 74, SEC-2). An expired token gets HTTP 401 too, so
# the revocation is confirmed only if GitHub answered a revocation of it as done and the read's
# answer came at least a minute before the expiry GitHub gave when it issued the token (the minute
# is taken off that expiry, never added). Otherwise no retry can confirm it: it is named NOT
# confirmed, with why, and not tried again.
revocation_judged() { # <label> <token>
  local now exp="" kind=""
  now=$(date +%s)
  if ! exp="$(expiry_of "$1")"; then kind=unknown
  elif [[ $((now + 60)) -gt $exp ]]; then kind=expired
  elif [[ " $REVOKE_OK " != *" $2 "* ]]; then kind=unanswered
  fi
  outstanding_drop "$2"
  if [[ -z "$kind" ]]; then
    CONFIRMED_TOKENS="$CONFIRMED_TOKENS $2"
    say "TOKEN $1 revoked: a read with it now gets HTTP 401, $((exp - now))s before its expiry, and GitHub answered its revocation as done"
    return
  fi
  UNCONFIRMABLE="$UNCONFIRMABLE $2:$kind"
  case "$kind" in
    unknown) say "TOKEN $1 NOT confirmed revoked: a read with it gets HTTP 401, but its expiry is unknown, so that may be expiry (expiry unknown, revocation not confirmed)" ;;
    expired) say "TOKEN $1 NOT confirmed revoked: expired, revocation not confirmed (a read with it got HTTP 401 at $(date -u -r "$now" +%H:%M:%SZ), less than a minute before its expiry $(date -u -r "$exp" +%H:%M:%SZ), or after it)" ;;
    *) say "TOKEN $1 NOT confirmed revoked: a read with it gets HTTP 401, but GitHub never answered a revocation of it as done (revocation never answered as done)" ;;
  esac
}

# The expiry GitHub gave when it issued that token (ISSUED_META), in seconds; 1 if unknown.
expiry_of() { # <label>
  local meta exp at
  meta="$(printf '%s' "$ISSUED_META" | awk -v l="$1" '$1 == l { sub(/^[^ ]+ /, ""); print; exit }')"
  exp="$(jq -r '.expires_at // empty' <<<"$meta" 2>/dev/null)" || return 1
  at="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$exp" +%s 2>/dev/null)" || return 1
  [[ "$at" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$at"
}

kind_of() { # <token> — why a read refused it but its revocation can't be confirmed, if so
  local k
  [[ " $UNCONFIRMABLE " == *" $1:"* ]] || return 0
  k="${UNCONFIRMABLE##* "$1":}"
  printf '%s' "${k%% *}"
}

unconfirmed_why() { # <kind> — how the last line names it
  case "$1" in
    expired) printf ' (expired, revocation not confirmed)' ;;
    unknown) printf ' (expiry unknown, revocation not confirmed)' ;;
    unanswered) printf ' (revocation never answered as done)' ;;
  esac
}

# The clean-up's last line, without a token: each token confirmed revoked or not, held ones apart,
# and what was left undone. Nothing when the run had no token and no tidy-up. 1 unless complete.
cleanup_summary() {
  local e t yes="" no="" held="" tokens unknown left
  for e in $ISSUED; do
    t="${e#*=}"
    if [[ " $HELD_KEPT " == *" $t "* ]]; then held="$held ${e%%=*}"
    elif [[ " $CONFIRMED_TOKENS " == *" $t "* ]]; then yes="$yes ${e%%=*}"
    else no="$no ${e%%=*}$(unconfirmed_why "$(kind_of "$t")")"
    fi
  done
  # The controls' tokens, as their controls reported them; a control that never said it was done
  # may hold one, NOT confirmed (round 73, C1, SEC-1).
  yes="$yes$CONTROL_CONFIRMED" no="$no$CONTROL_UNCONFIRMED"
  for t in $CONTROL_PENDING; do no="$no $t (no result)"; done
  # A write that got no answer in time may have taken effect: named until someone reads it back
  # (round 75, C1).
  unknown="$(unknown_writes)"
  unknown="${unknown%;}"
  # A test issue the run made, or whose close it started, counts only once read back closed
  # (round 92, SEC-2): any other is named, and the clean-up is INCOMPLETE.
  left="$(issues_unconfirmed)"
  [[ -n "$ISSUED$UNRECEIVED_LABELS$CLEANUP_UNDONE$CONTROL_CONFIRMED$CONTROL_UNCONFIRMED$CONTROL_PENDING$unknown$ISSUES_CLOSED$left" ]] || return 0
  tokens="tokens confirmed revoked (HTTP 401):${yes:- none}; NOT confirmed:${no:- none}"
  tokens="$tokens${UNRECEIVED_LABELS:+; possibly issued, never received:$UNRECEIVED_LABELS}${held:+; held for a later check:$held}"
  # Each test issue as its read-back by number found it, closed (round 102).
  tokens="$tokens${ISSUES_CLOSED:+; test issues read back closed:$ISSUES_CLOSED}"
  tokens="$tokens${unknown:+; writes with outcome unknown (not retried, not reconciled: check them on GitHub):$unknown}"
  tokens="$tokens${left:+; test issues not read back closed:$left}"
  # No work folder is deleted, nor anything in it (owner, 2026-11-24, round 96): said here, just
  # before the last line, which stays the summary.
  if [[ -n "$WORK_MADE" ]]; then
    say "CLEANUP this run's work folder $WORK_MADE is not deleted: it stays, private, for you to remove later once approved (nothing in it is shown)"
  fi
  if [[ -z "$no$UNRECEIVED_LABELS$CLEANUP_UNDONE$unknown$left" ]]; then
    say "CLEANUP DONE: $tokens; nothing left undone"
    return 0
  fi
  say "CLEANUP INCOMPLETE: $tokens; not done:${CLEANUP_UNDONE:- nothing.} A token not confirmed may work until it expires, within an hour of its issue"
  return 1
}

# Each write of this run's that got no complete answer or none in time, or that a stop cut short (it
# is still out), once, on one line. Round 102 (round 92, C2 = SEC-1): a test issue's create still
# pending (PENDING_CREATE) is one too, unless already named so; a close of a test issue read back
# closed is settled by that read-back, and not named. Round 109 (owner, 2026-11-25): all of it is
# the run's own memory (WRITES_UNKNOWN, WRITES_OUT, a control's as it reported them), never a file,
# so nothing a folder holds or loses can hide a write or add one.
unknown_writes() {
  local f all n settled
  all="$WRITES_UNKNOWN"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    all="$all${f#* } (cut short by the stop)"$'\n'
  done <<<"$WRITES_OUT"
  all="$(printf '%s' "$all" | sort -u)"
  if [[ -n "$PENDING_CREATE" && $'\n'"$all" != *$'\n'"$PENDING_CREATE ("* ]]; then
    all="$all"$'\n'"$PENDING_CREATE (no complete answer registered: it may have been made)"
  fi
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    settled=""
    for n in $ISSUES_CLOSED; do
      [[ "$f" != "owner gh issue close ${n#\#} --repo $REPO ("* ]] || settled=1
    done
    [[ -n "$settled" ]] || printf ' %s;' "$f"
  done <<<"$all"
}

# This run's test issues it made, or whose close it started, not read back closed: " #n" each.
issues_unconfirmed() {
  local n seen=""
  for n in $RUN_ISSUES $ISSUES_CLOSE_SENT; do
    [[ " $seen " != *" $n "* ]] || continue
    seen="$seen $n"
    [[ " $ISSUES_CLOSED " == *" #$n "* ]] || printf ' #%s' "$n"
  done
}

# A tidy-up's write that got no answer in time and that no read-back settled (round 77): never sent
# again blindly, and named in the clean-up's last line, its outcome unknown, so the clean-up is
# INCOMPLETE. In the run's own shell or the clean-up, where a tidy-up's timeout doesn't stop the run.
# Round 109: kept in the run's memory (WRITES_UNKNOWN), never a file, so it can't fail; a caller
# keeping a record of its own (a pending create) clears it only after this (review-lens round 93).
unsettled_write() { # <why> <runner> <args…> — the request, described by request_what
  local why="$1"
  shift
  write_unknown "$(request_what "$@")" "$why"
}

# Round 109 (owner, 2026-11-25): a write's pending state, in the shell that sends it. write_out notes it
# before it is sent, its number in WRITE_N; write_done clears it once its answer is stored and judged;
# write_unknown names it outcome unknown, with why.
write_out() { # <what> — sets WRITE_N
  WRITE_SEQ=$((WRITE_SEQ + 1))
  WRITE_N=$WRITE_SEQ
  WRITES_OUT="$WRITES_OUT$WRITE_N $(one_line "$1")"$'\n'
}
one_line() { printf '%s' "$1" | tr '\n\t\r' '   ' | cut -c1-200; } # <text> — a write's note is one line
write_done() { # <n>
  local l keep=""
  while IFS= read -r l; do
    [[ -z "$l" || "${l%% *}" == "$1" ]] || keep="$keep$l"$'\n'
  done < <(printf '%s' "$WRITES_OUT")
  WRITES_OUT="$keep"
}
write_unknown() { # <what> <why>
  WRITES_UNKNOWN="$WRITES_UNKNOWN$(one_line "$1 ($2)")"$'\n'
}

# An unknown write settled by an authoritative read-back of what it changed (round 110, owner's rule
# (b)): each note of it goes. Only a caller that has read the state back calls it.
write_resolved() { # <what>
  local l keep="" w
  w="$(one_line "$1")"
  while IFS= read -r l; do
    [[ -z "$l" || "$l" == "$w ("* ]] || keep="$keep$l"$'\n'
  done < <(printf '%s' "$WRITES_UNKNOWN")
  WRITES_UNKNOWN="$keep"
}

# 0 if a write's stored answer is the one its operation expects (round 110, owner: status 0 alone is
# never enough, and by rule (b) a failure is never taken as a refusal, whatever its words). <expect>:
# json:<jq filter that prints true>, text:<ERE a line of it must match>, status:<nnn> (the status line
# gh api -i prints first). An empty answer never is.
answer_expected() { # <expect> <answer>
  local got re
  [[ -n "$2" ]] || return 1
  case "$1" in
    json:?*) got="$(printf '%s' "$2" | jq -r "${1#json:}" 2>/dev/null)" || return 1; [[ "$got" == true ]] ;;
    # grep reads it all (no -q): an early exit would fail printf under pipefail.
    text:?*) printf '%s\n' "$2" | grep -E -- "${1#text:}" >/dev/null ;;
    status:[0-9][0-9][0-9])
      re="^HTTP/[0-9.]+ ${1#status:}( |\$)" # through a variable: bash 3.2 misreads it inline
      got="${2%%$'\n'*}"
      got="${got%$'\r'}"
      [[ "$got" =~ $re ]] ;;
    *) return 1 ;;
  esac
}

# A write whose operation's expected answer is declared (round 110): sent through capture, so its
# answer is stored, and settled only by status 0 with that answer; anything else leaves it unknown.
# Round 111 (review-lens round 99, C1; owner): it fails then too, so what depends on it doesn't run;
# LAST_RC stays its command's own status.
write_checked() { # <expect> <command…> — capture's status, else 1 if not settled on that answer
  WRITE_EXPECT="$1"
  shift
  capture "$@" || return
  [[ -z "$WRITE_UNSETTLED" ]]
}
WRITE_EXPECT=""
WRITE_UNSETTLED="" # set by into_settle: 1 if into's last write wasn't settled on its expected answer

# Helper functions that send a write of their own when into runs them (round 109): into can't see
# the request inside, so it notes the helper itself, by name and arguments, with the answer its
# operation expects (round 110).
readonly WRITE_HELPERS=" put_file_commit " # s2d_post's write is noted by s2d_approve, which reads its whole answer
helper_expect() { # <helper> — the answer its write expects
  case "$1" in
    put_file_commit) printf '%s' 'text:^[0-9a-f]{40}$' ;; # its --jq .commit.sha
  esac
}
trap cleanup EXIT
# Closing the Terminal, Ctrl-C or a kill also end through cleanup, with the usual status (round 51,
# SEC-1): an explicit exit, so it holds whatever the signal finds bash doing. A force-kill (KILL)
# or a power loss can't be caught: a token not revoked then stays valid until it expires (GitHub
# issues each for at most an hour). A stop ignores any further one first (round 74): a second
# signal as the clean-up begins, before it ignores them itself, would otherwise end it there (seen
# in a control's clean-up, which a stop can reach twice).
stop_traps() {
  trap 'trap "" HUP INT TERM; exit 129' HUP
  trap 'trap "" HUP INT TERM; exit 130' INT
  trap 'trap "" HUP INT TERM; exit 143' TERM
}
stop_traps


# --- The two identities -------------------------------------------------------------------------

# Every GitHub request goes through owner_gh, app_gh or app_git (or jwt_call's app_curl, the app's
# own requests), each bounded where it starts (round 75, C1): an API call by CALL_SECS (20s), a git
# push or fetch by PUSH_SECS (60s), a clone by CLONE_SECS (120s), a local git command by CALL_SECS;
# each less near the clean-up's cap. A test checks that no gh, git or curl runs any other way, and
# that none runs inside a command substitution or a pipeline, where bash would hold a stop until it
# ended (a2-probe's own code aside, whose contract covers that): its output comes through into.
owner_gh() { with_timeout "$(call_secs)" owner_gh_run "$@"; }
app_gh() { with_timeout "$(call_secs)" app_gh_run "$@"; }
app_git() { with_timeout "$(git_secs "$@")" app_git_run "$@"; }
app_curl() { with_timeout $((CALL_SECS + 5)) curl "$@"; } # curl's own --max-time ends it first
app_api_curl() { with_timeout "$(call_secs)" app_api_curl_run "$@"; } # the app's API attempts (round 115)

# The system's curl for the app's API attempts (round 115, owner): an empty environment (env -i: no
# proxy, CA bundle, key log or curl variable of anyone's, HOME the empty /var/empty), -q first so no
# .curlrc is read. Its standard input is the caller's (the headers, through a pipe). Every other
# descriptor is closed first: bash keeps a process substitution's own descriptor (63) open, and curl
# must hold nothing but its input, its answer and /dev/null (the test found 63). Round 116 (review-lens
# round 102, C5; owner): whatever their numbers (above 254 too), as FD_LIST lists them, in this
# subshell only (the run keeps its own). The list is read again once they are closed: if it can't
# be read, lacks 0, 1 or 2, or still shows one open, curl is never started (status 125).
app_api_curl_run() {
  (
    local f fd seen pass
    for pass in close check; do
      seen=""
      for f in "$FD_LIST"/*; do
        fd="${f##*/}"
        [[ "$fd" =~ ^[0-9]+$ ]] || exit 125
        if [[ $fd -le 2 ]]; then seen="$seen $fd"
        elif [[ "$pass" == close ]]; then eval "exec $fd>&-"
        elif (: >&"$fd") 2>/dev/null; then exit 125 # still open (the list's own, closed once read, isn't)
        fi
      done
      [[ "$seen" == *" 0"* && "$seen" == *" 1"* && "$seen" == *" 2"* ]] || exit 125
    done
    exec /usr/bin/env -i PATH=/usr/bin:/bin HOME=/var/empty "$APP_API_CURL" -q "$@"
  )
}

git_secs() { # <app git args…> — its time limit, by what it does
  case "$(git_subcommand "$@")" in
    clone) call_secs "$CLONE_SECS" ;;
    push | fetch) call_secs "$PUSH_SECS" ;;
    *) call_secs ;;
  esac
}

git_subcommand() { # <git args…> — the command, after any -C <dir> and -c <setting>
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -C | -c) shift 2 ;;
      -*) shift ;;
      *) printf '%s' "$1"; return ;;
    esac
  done
}

# The owner's own gh login, as stored by gh. No token variable may override it.
# shellcheck disable=SC2030,SC2031 # each identity's variables live only in its own subshell
owner_gh_run() {
  (
    unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST GH_REPO GH_CONFIG_DIR
    export GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1
    exec gh "$@"
  )
}

# The app's installation token, for this one process only: an exported variable, never an argument
# (so it isn't in the process list), and for gh's settings the system's empty, read-only /var/empty
# (none of the owner's settings, and no folder of the run's own another process could change; round
# 109). Checked with gh 2.102.0, offline only: it starts, reads its defaults there and builds its
# requests (evidence 267); GitHub's answers weren't part of that check.
# shellcheck disable=SC2030,SC2031 # as above
app_gh_run() {
  (
    unset GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_REPO
    export GH_TOKEN="$TOKEN" GH_HOST=github.com GH_CONFIG_DIR=/var/empty \
      GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1
    exec gh "$@"
  )
}

# git as the app: no GIT_* variable, no system or global config (so no credential helper or
# URL rewrite of the owner's applies), no hooks. Round 109: no password helper and no home folder of
# the run's own: HOME is the system's empty /var/empty and git's prompt is /usr/bin/false. The token
# goes only to a request to GitHub (clone, fetch, push, pull, ls-remote), and only in git's
# environment, as an extra header for https://github.com/ (GIT_CONFIG_COUNT/KEY_0/VALUE_0), encoded
# through a pipe; never an argument. A local git command gets no token at all.
app_git_run() {
  (
    local v
    for v in $(compgen -e); do
      case "$v" in GIT_* | SSH_ASKPASS) unset "$v" ;; esac
    done
    export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 HOME=/var/empty GIT_ASKPASS=/usr/bin/false
    case "$(git_subcommand "$@")" in
      clone | fetch | push | pull | ls-remote)
        v="$(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')" || exit 1
        export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $v"
        ;;
    esac
    exec git -c credential.helper= -c core.askPass=/usr/bin/false -c core.hooksPath=/dev/null \
      -c commit.gpgsign=false -c protocol.allow=never -c protocol.https.allow=always \
      -c user.name="frg26-app-test" -c user.email="frg26-app-test@users.noreply.github.com" "$@"
  )
}

# Run a command; keep its redacted output in LAST_OUT and its status in LAST_RC.
capture() {
  local out rc=0
  into -2 out "$@" || rc=$?
  LAST_OUT="$(redact "$out")"
  LAST_RC=$rc
  return $rc
}

# A command's output, as "$(command…)" would give it, without the command substitution (round 75,
# C1): bash holds a stop until a command substitution returns, but acts on it at once while the
# shell waits for a job. <var> gets the output, its trailing newlines removed; the status is the
# command's. With -2 its error output is kept too, as 2>&1 inside would. Where stops are ignored (a
# clean-up) or held anyway (defer_signals: a token request), the command substitution itself is used:
# the answer is held in memory, and no file is made, read or removed (review-lens round 97, C1, C2;
# round 109). Elsewhere the answer passes through a private file in the work folder, so a stop acts
# at once (round 75): not in this round's scope (owner, 2026-11-25), an open limit.
# Round 109 (owner, 2026-11-25): the command runs as a job (IN_JOB), and what it means for the run is
# noted here, in this shell: a write before it starts, cleared only once its answer is stored and
# matches what its operation expects (round 110: write_checked, answer_expected), else outcome
# unknown; a job ended by its limit (124) stops the run. Round 110: an answer that can't be read back
# from its file (gone, unreadable) is unread, never empty. In memory, the job's fds 3 and 8 are closed
# with exec inside the substitution: a redirection on the call itself would leave bash's own copy of
# them (fd 10 and up) open to every program the job runs.
into() { # [-2] <var> <command…>
  local _i_both="" _i_var _i_f _i_pid _i_rc=0 _i_out="" _i_n="" _i_unread="" _i_expect="$WRITE_EXPECT"
  WRITE_EXPECT=""
  if [[ "$1" == -2 ]]; then _i_both=1; shift; fi
  _i_var="$1"
  shift
  into_req "$@"
  [[ -n "$_i_expect" ]] || _i_expect="$IR_EXPECT"
  if [[ -n "$IR_WRITE" && -z "$IN_JOB" && -z "$PROBE_ACTIVE" ]]; then
    write_out "$IR_WHAT"
    _i_n=$WRITE_N
  fi
  if [[ -n "$STOPS_HELD$DEFERRING" ]]; then
    if [[ -n "$_i_both" ]]; then
      _i_out="$(exec 3>&- 8<&- 2>&1; in_job "$@")" || _i_rc=$?
    else
      _i_out="$(exec 3>&- 8<&-; in_job "$@")" || _i_rc=$?
    fi
  else
    _i_f="$(umask 077 && mktemp "${WORK:-${TMPDIR:-/tmp}}/out.XXXXXX" 2>/dev/null)" || die "can't make a file for a request's output"
    if [[ -n "$_i_both" ]]; then
      in_job "$@" >"$_i_f" 2>&1 3>&- 8<&- &
    else
      in_job "$@" >"$_i_f" 3>&- 8<&- &
    fi
    _i_pid=$!
    REQ_JOBS="$REQ_JOBS $_i_pid"
    job_wait "$_i_pid" || _i_rc=$?
    jobs_drop "$_i_pid"
    if [[ -f "$_i_f" ]] && _i_out="$(cat "$_i_f")"; then :; else _i_out="" _i_unread=1; fi
    rm -f "$_i_f"
  fi
  printf -v "$_i_var" '%s' "$_i_out"
  into_settle "$_i_rc" "$_i_out" "$_i_n" "$_i_unread" "$_i_expect"
  timeout_check
  return $_i_rc
}

in_job() { IN_JOB=1; "$@"; } # <command…> — into's job (a subshell): what it means is into's to note

# What into is about to run, for its notes (round 109): the request's own words (request_what), its
# time limit and whether it may write, past a leading "with_timeout <seconds>". A helper function is
# known by its name and arguments; one of WRITE_HELPERS may write.
into_req() { # <command…> — sets IR_WHAT, IR_SECS (empty: unknown), IR_WRITE, IR_EXPECT (a helper's)
  IR_WHAT="" IR_SECS="" IR_WRITE="" IR_EXPECT=""
  if [[ "$1" == with_timeout ]]; then IR_SECS="$2"; shift 2; fi
  case "$1" in
    owner_gh | app_gh | owner_gh_run | app_gh_run) [[ -n "$IR_SECS" ]] || IR_SECS="$(call_secs)" ;;
    app_git | app_git_run) [[ -n "$IR_SECS" ]] || IR_SECS="$(git_secs "${@:2}")" ;;
    app_curl | jwt_curl) [[ -n "$IR_SECS" ]] || IR_SECS=$((CALL_SECS + 5)) ;;
    *)
      IR_WHAT="a request in $(one_line "$*" | cut -c1-120)"
      if [[ "$WRITE_HELPERS" == *" $1 "* ]]; then IR_WRITE=1 IR_EXPECT="$(helper_expect "$1")"; fi
      return 0
      ;;
  esac
  IR_WHAT="$(request_what "$@")"
  if request_writes "$@" && [[ "$*" != *" installation/token"* ]]; then IR_WRITE=1; fi
  return 0
}

# What into's job meant for the run, from its stored answer and status (round 109). A write noted
# before the job is cleared only by status 0 with the answer its operation expects (round 110);
# otherwise it is named outcome unknown, with why: no answer in time, a failure (rule (b): never a
# refusal by its words), an answer unread, empty, unchecked (none expected declared) or not as
# expected. A job ended by its limit (124, or 137 for a KILL) stops the run, as request_timed_out
# does, except where a timeout doesn't (a clean-up, a tidy-up, a2-probe); inside a job of a job, that
# job ends too, for the shell above it to note. Round 111: WRITE_UNSETTLED says, for write_checked,
# whether a write (or a command with an expected answer) was left unsettled, wherever it ran.
into_settle() { # <status> <answer> <write number, or empty> <unread, or empty> <expected answer>
  local rc="$1" secs="${IR_SECS:+${IR_SECS}s}" why=""
  WRITE_UNSETTLED=""
  if [[ -n "$IR_WRITE$5" ]]; then
    if [[ $rc -eq 124 || $rc -eq 137 ]]; then why="no answer within ${secs:-its limit}"
    elif [[ $rc -ne 0 ]]; then why="failed: status $rc"
    elif [[ -n "$4" ]]; then why="its answer could not be read"
    elif [[ -z "$2" ]]; then why="an empty answer"
    elif [[ -z "$5" ]]; then why="answered; no expected answer to check it against"
    elif ! answer_expected "$5" "$2"; then why="answered, not as expected"
    fi
    [[ -z "$why" ]] || WRITE_UNSETTLED=1
  fi
  if [[ -n "$3" ]]; then
    [[ -z "$why" ]] || write_unknown "$IR_WHAT" "$why"
    write_done "$3"
  fi
  [[ $rc -eq 124 || $rc -eq 137 ]] || return 0
  [[ -z "$CLEANUP_DEADLINE" && -z "$PROBE_ACTIVE" && -z "$TIDY_UP" && -n "$WORK" ]] || return 0
  [[ -z "$IN_JOB" ]] || exit 124
  if [[ -n "$IR_WRITE" ]]; then
    STOP_LINES="$STOP_LINES$IR_WHAT got no answer within its ${secs:-limit} (a write: its outcome is unknown; it may have taken effect, and it is not tried again)"$'\n'
  else
    STOP_LINES="$STOP_LINES$IR_WHAT got no answer within its ${secs:-limit}"$'\n'
  fi
}

# Waits for a job to end; a caught signal interrupts wait while it may still run, so wait again
# until it has (round 66, C1). A stop's trap ends the run from inside this wait.
job_wait() { # <pid> — its status
  local rc
  while :; do
    rc=0
    wait "$1" || rc=$?
    if [[ $rc -gt 128 ]] && kill -0 "$1" 2>/dev/null; then continue; fi
    return $rc
  done
}

jobs_drop() { # <pid…> — no longer running
  local p s=" $REQ_JOBS "
  for p in "$@"; do s="${s// $p / }"; done
  REQ_JOBS="$s"
}

# The requests and waits this shell started that are still running, each stopped with every process
# under it (a stop's trap left them there): the clean-up and a control's own clean-up begin here.
stop_requests() {
  local p
  for p in $REQ_JOBS; do kill_tree "$p"; done
  REQ_JOBS=""
}

# A wait between polls a stop ends at once (round 75, C1): bash would hold a stop until a sleep in
# the foreground ended.
nap() { # <seconds>
  local pid
  sleep "$1" 3>&- 8<&- & # a control's pipe closed for it (round 109)
  pid=$!
  REQ_JOBS="$REQ_JOBS $pid"
  job_wait "$pid" || true
  jobs_drop "$pid"
}

# Outside the clean-up (and a2-probe, whose own contract stands, round 52), a request with no answer
# within its limit stops the run: it and its processes are stopped (with_timeout), it is recorded in
# WORK (a write as outcome unknown: it may have taken effect, and is never tried again), and no new
# request or test action starts; the run goes to its bounded clean-up, which says why first and
# names each such write in its last line. A token's revocation is not named: the clean-up settles
# and checks every token.
request_timed_out() { # <seconds> <runner> <args…>
  [[ -z "$CLEANUP_DEADLINE" && -z "$PROBE_ACTIVE" && -z "$TIDY_UP" && -n "$WORK" ]] || return 0
  # Round 109: in into's job, the job ends here with 124; into notes it in the run's own shell.
  [[ -z "$IN_JOB" ]] || exit 124
  stop_note "$@"
  timeout_check
}

# A request with no answer within its limit, noted in this shell's memory (round 109: never a file):
# why the run stops, and a write's outcome unknown.
stop_note() { # <seconds> <runner> <args…>
  local secs="$1" what
  shift
  what="$(request_what "$@")"
  if request_writes "$@" && [[ "$*" != *" installation/token"* ]]; then
    write_unknown "$what" "no answer within ${secs}s"
    STOP_LINES="$STOP_LINES$what got no answer within its ${secs}s (a write: its outcome is unknown; it may have taken effect, and it is not tried again)"$'\n'
  else
    STOP_LINES="$STOP_LINES$what got no answer within its ${secs}s"$'\n'
  fi
}

# Once a request has timed out (in this shell, one of its jobs, or a control it ran), no new request
# starts: the run stops here, for its clean-up (round 75, C1). In into's job, the job ends (124).
timeout_check() {
  [[ -z "$CLEANUP_DEADLINE" && -z "$PROBE_ACTIVE" && -z "$TIDY_UP" && -n "$WORK" && -n "$STOP_LINES" ]] || return 0
  [[ -z "$IN_JOB" ]] || exit 124
  STOP_WHY="STOPPED: $(printf '%s' "$STOP_LINES" | sort -u | tr '\n' ';' | sed 's/;$//'); the run starts no further test action"
  exit 2
}

owner_what() { request_what owner "$@"; } # <gh args…> — how an owner's request is named (no request sent)
app_what() { request_what app "$@"; }     # <gh args…> — the same for the app's (round 112)

# Who asked what, in a few words: gh api's method and path, another gh command's first words, git's
# command and what follows it, curl's method and address. Never a token: none is an argument.
request_what() { # <runner> <args…>
  local who m="" a s="" n=0 p="" r=""
  case "$1" in
    owner | owner_gh | owner_gh_run) who="owner gh" ;; # owner: owner_what's naming only
    app | app_gh | app_gh_run) who="app gh" ;; # app: app_what's naming only
    app_git | app_git_run) who="app git" ;;
    app_curl | jwt_curl) who="app curl" ;;
    *) who="app $1" ;;
  esac
  shift
  case "$who" in
    *git)
      while [[ $# -gt 0 && "$1" == -* ]]; do
        case "$1" in -C | -c) shift 2 ;; *) shift ;; esac
      done
      ;;
    *curl)
      while [[ $# -gt 0 ]]; do
        case "$1" in -X) m="${2:-}"; shift ;; https://*) s="$1" ;; esac
        shift
      done
      printf '%s %s %s' "$who" "${m:-GET}" "$s"
      return
      ;;
    *)
      if [[ "${1:-}" == api ]]; then
        shift
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -X | --method) m="${2:-}"; shift ;;
            --jq | -q | --input | -f | -F | --field | --raw-field | -H | --header | -t | --template) shift ;;
            -*) ;;
            *) [[ -n "$s" ]] || s="$1" ;;
          esac
          shift
        done
        printf '%s api %s %s' "$who" "${m:-GET}" "$s"
        return
      fi
      ;;
  esac
  # The first four words, and the repository wherever it comes (round 77: "issue close 11 --repo"
  # named no repository).
  for a in "$@"; do
    n=$((n + 1))
    if [[ $n -le 4 ]]; then s="$s ${a:0:80}"; fi
    if [[ "$p" == --repo ]]; then r="${a:0:80}"; fi
    p="$a"
  done
  if [[ -n "$r" && "$s" != *" --repo $r"* ]]; then s="${s% --repo} --repo $r"; fi
  printf '%s%s' "$who" "$s"
}

request_writes() { # <runner> <args…> — 0 if the request may change something on GitHub
  local runner="$1" m="" fields=""
  shift
  case "$runner" in
    app_git | app_git_run) [[ "$(git_subcommand "$@")" == push ]]; return ;;
    curl | app_curl | jwt_curl) return 1 ;; # the app's own requests: a token request's answer is settled by request_token
  esac
  if [[ "${1:-}" != api ]]; then
    case "${1:-} ${2:-}" in
      "pr view" | "pr list" | "pr status" | "pr checks" | "pr diff" | "issue view" | "issue list" | "run view" | "run list" | "repo view") return 1 ;;
    esac
    return 0
  fi
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -X | --method) m="${2:-}"; shift ;;
      -X?*) m="${1#-X}" ;;
      -f | -F | --field | --raw-field | --input) fields=1; shift ;;
    esac
    shift
  done
  [[ -n "$m" ]] || { [[ -n "$fields" ]] && m=POST; } || m=GET
  [[ "$m" != GET && "$m" != get ]]
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

# An app's API attempt (round 112, review-lens round 99 C2; owner 2026-11-25): GitHub's whole answer,
# judged by api_verdict, never by GitHub's words. A write is noted before it is sent, and stays outcome
# unknown however it is answered, unless attempts_settle later reads its target back unchanged after a
# complete refusal (owner: a read-back alone never does). Sets OBS, AV_WHY, LAST_RC, LAST_OUT (what the
# answer is, in known forms only: never its body's text, which can hold anything) and adds a write to
# ATTEMPT_WRITES (its method and path, one a line). Round 113 (review-lens
# round 100, C2 = SEC-3, SEC-4; owner chose (a)): the answer is held in memory, straight from the program
# this attempt's job started, never through a file; so a stop while it is out is held until it ends: at
# most the request's own tested limit, with_timeout's KILL at CALL_SECS (20s), with curl's --max-time the
# same. The owner accepted this for these stage 1 API attempts only, not for git, the broker or a
# control's stop. The stop is acted on once the attempt is judged and noted: no further test action
# starts, and the bounded clean-up runs. Round 115 (review-lens round 101, SEC-1; owner): sent through
# the system's curl (attempt_send), which follows no redirect; curl's own report must agree.
app_attempt() { # <gh api args…>
  local wn="" what rc=0 out held=""
  what="$(app_what api "$@")"
  attempt_form "$@" || die "an app attempt not in its fixed form (-X <method>, one endpoint path, -f/-F/--input fields only): $what"
  attempt_body "$@" || die "an app attempt whose fields can't be sent as its body: $what"
  if [[ -z "$DEFERRING" ]]; then defer_signals; held=1; fi
  if request_writes app api "$@"; then
    write_out "$what"
    wn=$WRITE_N
  fi
  into out app_attempt_run "$@" || rc=$?
  LAST_RC=$rc
  # Its end mark: an answer without it was cut off (its job ended before it was whole).
  if [[ "$out" == *x ]]; then
    attempt_answer "${out%x}" "$rc"
  else
    attempt_answer "$out" "$rc"
    HA_INCOMPLETE="cut off before its end"
  fi
  api_verdict "$(accepted_permission "$@")" "$wn"
  LAST_OUT="HTTP $HA_STATUS (curl exit $rc); request id ${HA_REQUEST_ID:-none}; x-ratelimit-remaining ${HA_REMAINING:-none}; accepted permissions ${HA_PERMS:-none}; completion: ${HA_INCOMPLETE:-Content-Length $HA_LENGTH matches the body}; $OBS: $AV_WHY"
  if [[ -n "$wn" ]]; then
    write_unknown "$what" "answered HTTP $HA_STATUS (curl exit $rc): $OBS, not read back"
    ATTEMPT_WRITES="$ATTEMPT_WRITES$(attempt_target "$@")"$'\n'
    write_done "$wn"
  fi
  [[ -z "$held" ]] || resume_signals
}
ATTEMPT_WRITES="" # the writes the attempts of the current test sent, each "<method> <path>"
ATTEMPT_BODY=""   # the attempt's body, from its fields (attempt_body); empty for none

# The attempt itself, in into's job: the whole answer and curl's own report on its standard output, then
# an end mark "x" (so an answer cut off is seen, and its trailing newlines are kept for the length check);
# curl's own error output is discarded.
app_attempt_run() { # <gh api args…>
  local rc=0
  exec 2>/dev/null
  attempt_send "$@" || rc=$?
  printf x
  return "$rc"
}

# The request, through the system's curl (round 115, owner), as attempt_form and attempt_body read the
# caller's arguments (AT_METHOD, AT_PATH, ATTEMPT_BODY, set in the run's shell before this job): to
# https://api.github.com/<path> only; HTTPS only, verified (never -k), TLS 1.2 or newer; no redirect
# followed (no -L, --max-redirs 0) and no proxy; no retry (curl retries nothing unless told); the whole
# answer with its headers (--include), identity encoding, no "Expect: 100-continue"; then curl's own
# report on one last line (-w): GitHub's status, the redirects followed, TLS verification's result, the
# address it ended at. The token reaches curl only on its standard input, through a pipe from printf (a
# builtin), never an argument, a file or its environment.
attempt_send() { # <gh api args…> (already read into AT_*, ATTEMPT_BODY)
  local args=(-s --include --proto "=https" --tlsv1.2 --max-redirs 0 --noproxy "*" --max-time "$(call_secs)"
    -X "$AT_METHOD" -H @- -H "Accept-Encoding: identity" -H "Expect:"
    -w '\n@@FRG26-CURL %{http_code} %{num_redirects} %{ssl_verify_result} %{url_effective}')
  if [[ -n "$ATTEMPT_BODY" ]]; then args+=(-H "Content-Type: application/json" --data-binary "$ATTEMPT_BODY"); fi
  # This job's own standard input, by exec: a redirection on the call itself would leave bash's copy of
  # the old one (fd 10 and up) open to curl (round 110).
  exec < <(printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28\n' "$TOKEN")
  WT_STDIN=1 app_api_curl "${args[@]}" "https://api.github.com/$AT_PATH"
}

# The answer as curl gave it: GitHub's part read by http_answer (curl's transport: complete only with
# curl's exit 0), then curl's own report, which must agree: its status the answer's, no redirect
# followed, TLS verified (0), and the very address asked. Anything else leaves it incomplete.
attempt_answer() { # <curl's standard output> <curl's exit status>
  local resp="$1" meta="" code redirs tls url want="https://api.github.com/$AT_PATH" re
  re=$'\n''@@FRG26-CURL '
  if [[ "$resp" == *"$re"* ]]; then
    meta="${resp##*"$re"}"
    resp="${resp%"$re"*}"
  fi
  http_answer "$resp" "$2" syscurl
  [[ -z "$HA_INCOMPLETE" ]] || return 0
  if [[ -z "$meta" ]]; then HA_INCOMPLETE="no report of curl's own"; return 0; fi
  read -r code redirs tls url <<<"$meta"
  if ! [[ "$code" =~ ^[0-9]{3}$ && "$redirs" =~ ^[0-9]+$ && "$tls" =~ ^[0-9]+$ ]]; then HA_INCOMPLETE="curl's report not of its form"
  elif [[ "$code" != "$HA_STATUS" ]]; then HA_INCOMPLETE="curl reports HTTP $code, the answer $HA_STATUS"
  elif [[ "$redirs" != 0 ]]; then HA_INCOMPLETE="curl reports a redirect followed"
  elif [[ "$tls" != 0 ]]; then HA_INCOMPLETE="curl reports TLS not verified ($tls)"
  elif [[ "$url" != "$want" ]]; then HA_INCOMPLETE="curl ended at another address than the one asked"
  fi
}

# The body of an attempt, from its fields, as gh would send them (round 115): -f name=value a string;
# -F name=value a number, true, false or null, else a string; name[] adds to a list; --input <file> one
# JSON object, alone. Names are plain words (no nesting); nothing is read from a file but --input's.
# Sets ATTEMPT_BODY (empty with no fields); 1 for anything else.
attempt_body() { # <gh api args…>
  local body="" input="" k v t
  ATTEMPT_BODY=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -X) shift 2 ;;
      --input)
        [[ -z "$input" && -z "$body" && -f "${2:-}" ]] || return 1
        input="$(cat "$2")" || return 1
        json_one "$input" 'type == "object"' || return 1
        input="$(jq -c . <<<"$input")" || return 1
        shift 2 ;;
      -f | -F)
        [[ -z "$input" && "${2:-}" == *=* ]] || return 1
        k="${2%%=*}" v="${2#*=}" t="$1"
        [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*(\[\])?$ ]] || return 1
        [[ -n "$body" ]] || body='{}'
        if [[ "$t" == -F ]]; then
          [[ "$v" != @* ]] || return 1
          if [[ "$v" =~ ^(true|false|null|-?(0|[1-9][0-9]{0,15}))$ ]]; then t=json; else t=string; fi
        else
          t=string
        fi
        if [[ "$k" == *"[]" ]]; then
          if [[ "$t" == json ]]; then body="$(jq -c --arg k "${k%\[\]}" --argjson v "$v" '.[$k] += [$v]' <<<"$body")" || return 1
          else body="$(jq -c --arg k "${k%\[\]}" --arg v "$v" '.[$k] += [$v]' <<<"$body")" || return 1
          fi
        elif [[ "$t" == json ]]; then body="$(jq -c --arg k "$k" --argjson v "$v" '.[$k] = $v' <<<"$body")" || return 1
        else body="$(jq -c --arg k "$k" --arg v "$v" '.[$k] = $v' <<<"$body")" || return 1
        fi
        shift 2 ;;
      *) shift ;;
    esac
  done
  ATTEMPT_BODY="${input:-$body}"
}

# The one form an app attempt is sent in (round 114, review-lens round 100 C3 = SEC-1, item 1; owner): so
# the gh its job starts is asked exactly the method and path the attempt is judged for. -X <method> at
# most once, of GitHub's list (required when there are fields); exactly one endpoint path under repos/ or
# user/, with no URL, host, query or "..": no graphql; and -f, -F or --input fields only (no -i, -H,
# --hostname, --paginate, --jq or other gh option of the caller's). Sets AT_METHOD and AT_PATH; 1 else.
attempt_form() { # <gh api args…>
  local fields=""
  AT_METHOD="" AT_PATH=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -X)
        [[ -z "$AT_METHOD" && "${2:-}" =~ ^(GET|POST|PUT|PATCH|DELETE)$ ]] || return 1
        AT_METHOD="$2"
        shift 2 ;;
      -f | -F | --input)
        [[ $# -ge 2 ]] || return 1
        fields=1
        shift 2 ;;
      -*) return 1 ;;
      *)
        [[ -z "$AT_PATH" && "$1" =~ ^(repos|user)/[A-Za-z0-9._/-]+$ && "$1" != *..* ]] || return 1
        AT_PATH="$1"
        shift ;;
    esac
  done
  [[ -n "$AT_PATH" ]] || return 1
  if [[ -z "$AT_METHOD" ]]; then
    [[ -z "$fields" ]] || return 1
    AT_METHOD=GET
  fi
}
AT_METHOD="" AT_PATH=""

attempt_target() { # <gh api args…> — "<method> <path>", as request_what reads them
  local w
  w="$(app_what api "$@")"
  printf '%s' "${w#app gh api }"
}

# GitHub's whole answer to a gh api -i request, in known forms only (round 80's reading of S2d's answer;
# round 112, shared): HA_STATUS (its status, or unknown), HA_REQUEST_ID, HA_REMAINING, HA_RESOURCE (each
# of its form, else "[other]"), HA_RETRY (set if a retry-after header came), HA_PERMS (the permissions
# x-accepted-github-permissions names, space-separated, or "[other]"), HA_LENGTH, HA_BODY and
# HA_INCOMPLETE: why it isn't shown complete, empty when it is (GitHub's own Content-Length equal to the
# body's bytes, no content or transfer encoding, no timeout, and the program's exit status: gh's 0 or 1;
# round 115, the system curl's 0 only, as it exits 0 on any HTTP status). HA_TRANSPORT: gh or syscurl.
http_answer() { # <the program's standard output> <its exit status> [gh | syscurl]
  local LC_ALL=C raw="$1" first line name value head=1 offset=0 coding=""
  local re='^HTTP/[0-9.]+ ([0-9]{3})( |$)'
  HA_STATUS=unknown HA_REQUEST_ID="" HA_REMAINING="" HA_RESOURCE="" HA_RETRY="" HA_PERMS="" HA_LENGTH="" HA_BODY="" HA_INCOMPLETE=""
  HA_TRANSPORT="${3:-gh}"
  first="${raw%%$'\n'*}"
  line="${first%$'\r'}"
  if [[ "$line" =~ $re && "$raw" == *$'\n'* ]]; then
    HA_STATUS="${BASH_REMATCH[1]}"
    offset=$((${#first} + 1))
    while IFS= read -r line; do
      offset=$((offset + ${#line} + 1))
      line="${line%$'\r'}"
      if [[ -z "$line" ]]; then head=""; break; fi
      name="$(printf '%s' "${line%%:*}" | tr '[:upper:]' '[:lower:]')"
      value="${line#*:}"
      value="${value# }"
      case "$name" in
        x-github-request-id)
          [[ "$value" =~ ^[A-Fa-f0-9]{1,16}(:[A-Fa-f0-9]{1,16}){4}$ ]] || value="[other]"
          HA_REQUEST_ID="$value"
          ;;
        x-ratelimit-remaining)
          [[ "$value" =~ ^[0-9]{1,10}$ ]] || value="[other]"
          HA_REMAINING="$value"
          ;;
        x-ratelimit-resource)
          [[ " $S2D_RESOURCES " == *" $value "* && -n "$value" && "$value" != *" "* ]] || value="[other]"
          HA_RESOURCE="$value"
          ;;
        x-accepted-github-permissions) HA_PERMS="$(accepted_permissions_of "$value")" ;;
        retry-after) HA_RETRY=1 ;;
        content-length) if [[ -z "$HA_LENGTH" && "$value" =~ ^[0-9]{1,12}$ ]]; then HA_LENGTH="$value"; else HA_LENGTH=bad; fi ;;
        content-encoding) [[ "$value" == identity ]] || coding=1 ;;
        transfer-encoding) coding=1 ;;
      esac
    done < <(printf '%s' "${raw#*$'\n'}")
    if [[ -n "$head" ]]; then
      HA_STATUS=unknown HA_REQUEST_ID="" HA_REMAINING="" HA_RESOURCE="" HA_RETRY="" HA_PERMS=""
      HA_INCOMPLETE="cut before the end of its headers"
    else
      HA_BODY="${raw:$offset}"
    fi
  else
    HA_BODY="$raw"
    HA_INCOMPLETE="no HTTP status line"
  fi
  # Complete only when GitHub's own length says so; gh's exit status only supports it.
  if [[ -z "$HA_INCOMPLETE" ]]; then
    if [[ -n "$STOP_LINES" || "$2" == 124 ]]; then HA_INCOMPLETE="a request timed out"
    elif [[ "$HA_TRANSPORT" == syscurl && "$2" != 0 ]]; then HA_INCOMPLETE="the system curl's exit status $2"
    elif [[ "$2" != 0 && "$2" != 1 ]]; then HA_INCOMPLETE="gh exit status $2"
    elif [[ -n "$coding" ]]; then HA_INCOMPLETE="a content or transfer encoding: the length can't be checked"
    elif [[ -z "$HA_LENGTH" ]]; then HA_INCOMPLETE="no Content-Length: completion can't be told"
    elif [[ "$HA_LENGTH" == bad ]]; then HA_INCOMPLETE="a Content-Length not of its form, or more than one"
    elif [[ "${#HA_BODY}" != "$HA_LENGTH" ]]; then HA_INCOMPLETE="the body is ${#HA_BODY} bytes, Content-Length $HA_LENGTH"
    fi
  fi
}

accepted_permissions_of() { # <x-accepted-github-permissions> — "name=level …", or "[other]" if any isn't of that form
  local p out=""
  for p in $(printf '%s' "$1" | tr ',;' '  '); do
    [[ "$p" =~ ^[a-z_]{1,40}=(read|write|admin)$ ]] || { printf '[other]'; return; }
    out="$out $p"
  done
  printf '%s' "${out# }"
}

# The permission GitHub's documentation says an operation needs from an app, as x-accepted-github-
# permissions names it: the one line that ties a refusal to its endpoint and method. From the documented
# permissions as known here, not checked against GitHub (round 112, offline): a wrong one can only make a
# refusal inconclusive. None for an operation not listed (A6's installation PUT): never refused.
accepted_permission() { # <gh api args…>
  local t m p
  t="$(attempt_target "$@")"
  m="${t%% *}" p="${t#* }"
  case "$m $p" in
    "PATCH repos/"*) [[ "$p" =~ ^repos/[^/]+/[^/]+$ ]] && printf 'administration=write' ;;
    "PUT repos/"*/branches/*/protection | "DELETE repos/"*/branches/*/protection) printf 'administration=write' ;;
    "POST repos/"*/rulesets | "PUT repos/"*/rulesets/* | "DELETE repos/"*/rulesets/*) printf 'administration=write' ;;
    "GET repos/"*/actions/secrets | "GET repos/"*/actions/secrets/public-key) printf 'secrets=read' ;;
    "GET repos/"*/actions/variables) printf 'actions_variables=read' ;;
    "GET repos/"*/keys | "GET repos/"*/invitations) printf 'administration=read' ;;
    "GET repos/"*/hooks) printf 'repository_hooks=read' ;;
    "PUT repos/"*/contents/* | "POST repos/"*/git/refs) printf 'contents=write' ;;
    "PUT repos/"*/environments/*) [[ "$p" =~ ^repos/[^/]+/[^/]+/environments/[^/]+$ ]] && printf 'administration=write' ;;
    "GET repos/"*/environments/*/secrets/public-key) printf 'environments=read' ;;
    "DELETE repos/"*/environments/*/secrets/*) printf 'environments=write' ;;
    "POST repos/"*/actions/runs/*/pending_deployments) printf 'deployments=write' ;;
    "POST repos/"*/issues | "POST repos/"*/issues/*/comments) printf 'issues=write' ;;
    "POST repos/"*/pulls) printf 'pull_requests=write' ;;
  esac
  return 0
}

# Neither allowed nor refused until the answer is shown complete (http_answer; through curl, with curl's
# own report agreeing) and consistent: through gh, its exit agreeing with GitHub's status (round 116,
# review-lens round 102 C1; owner). Then allowed on GitHub's 2xx; refused only on GitHub's 403 (or 404,
# to a read: a write's 404 can mean nothing was there to change), a request id of its form (correlation
# only: the authenticated HTTPS connection is what says GitHub answered), no rate-limit sign, and
# <permission> named by GitHub; else inconclusive. Sets OBS and AV_WHY.
api_verdict() { # <the operation's permission> <its write number, or empty for a read>
  local limit=""
  OBS=inconclusive AV_WHY=""
  if [[ -n "$HA_INCOMPLETE" ]]; then AV_WHY="no complete answer: $HA_INCOMPLETE"; return; fi
  if [[ "${HA_TRANSPORT:-gh}" != syscurl ]] && ! gh_agrees; then AV_WHY="gh's exit $LAST_RC doesn't agree with HTTP $HA_STATUS"; return; fi
  if [[ "$HA_STATUS" =~ ^2[0-9][0-9]$ ]]; then OBS=allowed AV_WHY="a complete HTTP $HA_STATUS"; return; fi
  [[ "$HA_STATUS" != 429 ]] || limit="$limit HTTP 429;"
  [[ -z "$HA_RETRY" ]] || limit="$limit a retry-after header;"
  [[ "$HA_REMAINING" != 0 ]] || limit="$limit x-ratelimit-remaining 0;"
  if printf '%s' "$HA_BODY" | grep -Eiq 'rate limit|abuse detection|secondary rate'; then limit="$limit rate-limit words;"; fi
  if [[ "$HA_STATUS" != 403 && ! ("$HA_STATUS" == 404 && -z "$2") ]]; then AV_WHY="HTTP $HA_STATUS, not a refusal's status for this attempt"
  elif [[ -z "$HA_REQUEST_ID" || "$HA_REQUEST_ID" == "[other]" ]]; then AV_WHY="no x-github-request-id of its form"
  elif [[ -n "$limit" ]]; then AV_WHY="rate-limit signs:${limit%;}"
  elif ! [[ "$HA_REMAINING" =~ ^[0-9]+$ && "$HA_REMAINING" -gt 0 ]]; then AV_WHY="x-ratelimit-remaining '${HA_REMAINING}', not above 0"
  elif [[ -z "$HA_RESOURCE" || "$HA_RESOURCE" == "[other]" ]]; then AV_WHY="x-ratelimit-resource '${HA_RESOURCE}', not one of GitHub's listed resources"
  elif [[ -z "$1" ]]; then AV_WHY="no permission is known for this operation, so its answer can't be tied to it"
  elif [[ " $HA_PERMS " != *" $1 "* ]]; then AV_WHY="x-accepted-github-permissions '${HA_PERMS:-none}' doesn't name $1, this operation's"
  else OBS=refused AV_WHY="a complete HTTP $HA_STATUS, request $HA_REQUEST_ID, GitHub naming $1"
  fi
}

gh_agrees() { # gh's exit (LAST_RC) as GitHub's status (HA_STATUS) would have it: 0 for a 2xx, 1 for a 4xx or 5xx
  case "$LAST_RC:$HA_STATUS" in
    0:2[0-9][0-9] | 1:[45][0-9][0-9]) return 0 ;;
  esac
  return 1
}

# A test's write attempts, all refused (round 112, owner): its state read again and compared with the
# baseline read before the first attempt. Changed or unreadable: inconclusive, every write still unknown.
# Unchanged: each write that would have shown against that baseline is settled (attempt_observable); a
# no-op against it stays outcome unknown, whatever the verdict. Round 115: "unreadable" is the readers'
# own status (attempt_state), never a word found in what they read.
attempts_settle() { # <test id> — against ATTEMPT_BASE, read whole before the first attempt if ATTEMPT_BASE_OK
  local now t
  [[ "$OBS" == refused && -n "$ATTEMPT_WRITES" ]] || return 0
  if [[ "$ATTEMPT_BASE" == - ]]; then
    OBS=inconclusive
    EV="$EV no state of this test can show its writes unchanged |"
    return 0
  fi
  if [[ -z "$ATTEMPT_BASE_OK" ]]; then
    OBS=inconclusive
    EV="$EV its baseline: unreadable (a part failed, answered nothing, or wasn't of its kind) |"
    return 0
  fi
  if ! into now attempt_state "$1"; then
    OBS=inconclusive
    EV="$EV its state read back: unreadable (a part failed, answered nothing, or wasn't of its kind) |"
  elif [[ "$now" != "$ATTEMPT_BASE" ]]; then
    OBS=inconclusive
    EV="$EV its state read back: CHANGED since before the attempts |"
  else
    EV="$EV its state read back: unchanged since before the attempts |"
    while IFS= read -r t; do
      [[ -n "$t" ]] || continue
      if attempt_observable "$1" "$t" "$ATTEMPT_BASE"; then write_resolved "app gh api $t"; else EV="$EV $t would change nothing it can show: outcome unknown |"; fi
    done <<<"$ATTEMPT_WRITES"
  fi
}

# What a test's write attempts could change, as the owner reads it now, compared whole and never shown
# (round 112; round112-plan.md says what "unchanged" means for each): "-" for a test with none that can
# show them. Round 115 (review-lens round 101, C1 = SEC-2; owner): each part read by its own reader,
# which checks that GitHub's answer parses as one JSON value of its kind, with its required fields, and
# prints it canonical; 1 if any part can't be read so (a failed read, an empty or other answer).
attempt_state() { # <test id>
  local a b
  case "$1" in
    B12) into a state_protection dev || return 1; printf '%s\n' "$a" ;;
    M4)
      into a state_protection main || return 1
      if [[ "$PHASE" == ruleset ]]; then
        into b state_rulesets || return 1
        printf '%s\n%s\n' "$a" "$b"
      else
        printf '%s\n' "$a"
      fi ;;
    B13)
      into a state_rulesets || return 1
      into b state_repo || return 1
      printf '%s\n%s\n' "$a" "$b" ;;
    A2) into a state_refs2 || return 1; printf '%s\n' "$a" ;;
    S2c) into a state_environment || return 1; printf '%s\n' "$a" ;;
    *) printf -- '-\n' ;;
  esac
}

attempt_baseline() { # <test id> — sets ATTEMPT_BASE, and ATTEMPT_BASE_OK when it was read whole (round 112)
  ATTEMPT_WRITES="" ATTEMPT_BASE_OK=""
  case "$1" in
    B12 | M4 | B13 | A2 | S2c)
      if into ATTEMPT_BASE attempt_state "$1"; then ATTEMPT_BASE_OK=1; else ATTEMPT_BASE=""; fi ;;
    *) ATTEMPT_BASE=- ATTEMPT_BASE_OK=1 ;;
  esac
}
ATTEMPT_BASE="" ATTEMPT_BASE_OK=""

# Whether a write would have shown against its test's baseline: a protection DELETE only where there was
# one, the Environment PUT never (the settings it already has).
attempt_observable() { # <test id> <method path> <baseline>
  case "$1 $2" in
    "B12 DELETE "* | "M4 DELETE "*/protection) [[ "${3%%$'\n'*}" == '{"protected":true'* ]] ;;
    "S2c PUT "*) return 1 ;;
    B12* | M4* | B13* | A2* | "S2c DELETE "*) return 0 ;;
    *) return 1 ;;
  esac
}

# 0 if <text> is exactly one JSON value that <test> (a jq expression, with the jq arguments given before
# it) holds true for (round 115): nothing, two values, or anything not JSON fails.
json_one() { # <text> [jq args…] <test>
  local t="$1"
  shift
  local f="${*: -1}"
  set -- "${@:1:$(($# - 1))}"
  jq -e -s "$@" "length == 1 and (.[0] | $f)" >/dev/null 2>&1 <<<"$t"
}

# shellcheck disable=SC2016 # the $ names in these readers' tests are jq's own variables
state_protection() { # <branch> — {"protected":false}, or {"protected":true,"protection":<it, whole>}
  local b p
  into b owner_gh api "repos/$REPO/branches/$1" 2>/dev/null || return 1
  json_one "$b" --arg n "$1" 'type == "object" and .name == $n and (.protected | type) == "boolean"' || return 1
  if [[ "$(jq -r .protected <<<"$b")" == false ]]; then printf '{"protected":false}\n'; return 0; fi
  into p owner_gh api "repos/$REPO/branches/$1/protection" 2>/dev/null || return 1
  json_one "$p" 'type == "object" and (.enforce_admins.enabled | type) == "boolean" and (.allow_force_pushes.enabled | type) == "boolean" and (.allow_deletions.enabled | type) == "boolean"' || return 1
  jq -S -c '{protected: true, protection: .}' <<<"$p"
}

# One page of a list as gh api -i printed it (round 118, review-lens round 104 SEC-1; owner), gh having
# exited 0 within its time limit (into's status): GitHub's 200, its headers whole (each a name of letters,
# digits and hyphens, a colon and its value; ended by an empty line), at most one Link and at most one
# Content-Length (any case). The answer is shown complete by its body, which the reader then requires to
# be one JSON array or object: a cut one can't parse, as the bracket that closes it is its end. A
# Content-Length, if any, must be a number and, with no content or transfer encoding named, the body's
# bytes. Sets PA_BODY, and LP_* from the Link (link_pages); 1 for anything else. Nothing here prints.
page_answer() { # <gh's output>
  local LC_ALL=C raw="$1" first line name value offset links=0 link="" lengths=0 length="" coding="" head=1
  PA_BODY="" LP_NEXT="" LP_PREV="" LP_FIRST="" LP_LAST=""
  first="${raw%%$'\n'*}"
  [[ "${first%$'\r'}" =~ ^HTTP/[0-9.]+\ 200( |$) && "$raw" == *$'\n'* ]] || return 1
  offset=$((${#first} + 1))
  while IFS= read -r line; do
    offset=$((offset + ${#line} + 1))
    line="${line%$'\r'}"
    if [[ -z "$line" ]]; then head=""; break; fi
    [[ "$line" =~ ^[A-Za-z0-9-]+: ]] || return 1
    name="$(printf '%s' "${line%%:*}" | tr '[:upper:]' '[:lower:]')"
    value="${line#*:}"
    value="${value# }"
    case "$name" in
      link) links=$((links + 1)) link="$value" ;;
      content-length) lengths=$((lengths + 1)) length="$value" ;;
      content-encoding) [[ "$value" == identity ]] || coding=1 ;;
      transfer-encoding) coding=1 ;;
    esac
  done < <(printf '%s' "${raw#*$'\n'}")
  [[ -z "$head" && $links -le 1 && $lengths -le 1 ]] || return 1
  PA_BODY="${raw:$offset}"
  if [[ $lengths -eq 1 ]]; then
    [[ "$length" =~ ^[0-9]{1,12}$ ]] || return 1
    [[ -n "$coding" || "${#PA_BODY}" == "$length" ]] || return 1
  fi
  [[ $links -eq 0 ]] || link_pages "$link"
}

# The pages a Link header names (round 118), in GitHub's form only: comma-separated <URL>; rel="<r>",
# each r next, prev, first or last (any case) and named once at most, each URL with no space, exactly one
# page=<n> (n from 1) and at most one per_page, which must be PAGE_SIZE, in its query. A URL is read for
# those numbers alone: never followed, kept or printed. Sets LP_NEXT, LP_PREV, LP_FIRST and LP_LAST (each
# the page it names, or empty); 1 for a header not of that form.
link_pages() { # <the Link header's value>
  local LC_ALL=C rest="$1" url rel p q pages per more
  local re='^[[:space:]]*<([^<>[:space:]]+)>[[:space:]]*;[[:space:]]*rel="([A-Za-z]+)"[[:space:]]*(,(.*))?$'
  local -a parts
  LP_NEXT="" LP_PREV="" LP_FIRST="" LP_LAST=""
  while :; do
    [[ "$rest" =~ $re ]] || return 1
    url="${BASH_REMATCH[1]}" more="${BASH_REMATCH[3]}" rest="${BASH_REMATCH[4]}"
    rel="$(printf '%s' "${BASH_REMATCH[2]}" | tr '[:upper:]' '[:lower:]')"
    [[ "$url" == *\?* ]] || return 1
    pages=0 per=0 p=""
    IFS='&' read -r -a parts <<<"${url#*\?}"
    for q in ${parts[@]+"${parts[@]}"}; do
      case "$q" in
        page=*) pages=$((pages + 1)) p="${q#page=}" ;;
        per_page=*) per=$((per + 1)); [[ "${q#per_page=}" == "$PAGE_SIZE" ]] || return 1 ;;
      esac
    done
    [[ $pages -eq 1 && $per -le 1 && "$p" =~ ^[1-9][0-9]{0,5}$ ]] || return 1
    case "$rel" in
      next) [[ -z "$LP_NEXT" ]] || return 1; LP_NEXT="$p" ;;
      prev) [[ -z "$LP_PREV" ]] || return 1; LP_PREV="$p" ;;
      first) [[ -z "$LP_FIRST" ]] || return 1; LP_FIRST="$p" ;;
      last) [[ -z "$LP_LAST" ]] || return 1; LP_LAST="$p" ;;
      *) return 1 ;;
    esac
    [[ -n "$more" ]] || return 0
  done
}
PA_BODY="" LP_NEXT="" LP_PREV="" LP_FIRST="" LP_LAST=""

# A list GitHub gives in pages, read whole (round 116, review-lens round 102 C2 = SEC-1, C3; owner): each
# page asked at an address built here on the fixed endpoint, <path>?per_page=100&page=<n> (never a Link
# URL of GitHub's, so never gh's --paginate, which follows them), until an empty page (round 117,
# review-lens round 103 SEC-1; owner): never a short one, so a short page in the middle can't hide later
# ones. Each page must be one JSON value <test> holds for, its <list> (a jq path) at most a full page of
# objects, each with its <key> not seen before (so a page repeated is refused): id, a whole number, or
# (round 117, A2's branches and tags) name, a string not empty; with <count> (a jq
# path: GitHub's total_count), that is the same on every page, the empty one too, and the number of
# entries collected. Bounded: at most PAGE_MAX pages with entries (so PAGE_MAX x PAGE_SIZE: exactly 1,000
# can be read, round 117 C2) and the empty page that ends them, and none asked once LIST_SECS have passed
# since the first was (each page within its own request's limit). Prints the entries as one JSON list; 1
# for a page missing, malformed, repeated or inconsistent, or the list longer than its bounds.
# Pages are separate reads, not one snapshot: a list that changes while it is read can repeat an entry
# (refused) or move one onto a page already read (unseen), and nothing here can tell that apart from a
# list that never changed.
# Round 118 (review-lens round 104 SEC-1; owner): each page read with its headers (page_answer); the
# pages must agree with them: a page names a next page (n+1) exactly when the page after it has entries,
# so the empty page that ends the list names none and no page follows one that named none; a prev names
# n-1, a first 1, and every last the list's last page with entries.
# shellcheck disable=SC2016 # jq's own $m
state_pages() { # <path> <test> <list> <key> [count]
  local path="$1" test="$2" list="$3" key="$4" count="${5:-}" n=0 start raw page got all='[]' total="" t kt named="" lasts=""
  case "$key" in
    id) kt='(.id | type) == "number" and .id > 0 and .id == (.id | floor)' ;;
    name) kt='(.name | type) == "string" and (.name | length) > 0' ;;
    *) return 1 ;;
  esac
  start="$(date +%s)"
  while :; do
    n=$((n + 1))
    [[ $n -eq 1 || $(($(date +%s) - start)) -lt $LIST_SECS ]] || return 1
    into raw owner_gh api -i "$path?per_page=$PAGE_SIZE&page=$n" 2>/dev/null || return 1
    page_answer "$raw" || return 1
    page="$PA_BODY"
    json_one "$page" --argjson m "$PAGE_SIZE" "($test) and ($list | type == \"array\" and length <= \$m and all(.[]; type == \"object\" and $kt))" || return 1
    got="$(jq -c "$list" <<<"$page")" || return 1
    if [[ -n "$count" ]]; then
      t="$(jq -c "$count" <<<"$page")" || return 1
      [[ "$t" =~ ^(0|[1-9][0-9]{0,8})$ && $t -le $((PAGE_MAX * PAGE_SIZE)) ]] || return 1
      [[ -z "$total" || "$t" == "$total" ]] || return 1
      total="$t"
    fi
    [[ -z "$LP_NEXT" || "$LP_NEXT" == $((n + 1)) ]] || return 1
    [[ -z "$LP_PREV" || "$LP_PREV" == $((n - 1)) ]] || return 1
    [[ -z "$LP_FIRST" || "$LP_FIRST" == 1 ]] || return 1
    [[ -z "$LP_LAST" ]] || lasts="$lasts $LP_LAST"
    if [[ "$got" == '[]' ]]; then
      [[ -z "$named" && -z "$LP_NEXT" ]] || return 1 # a next page named, empty; or the empty page naming one
      break
    fi
    [[ $n -eq 1 || -n "$named" ]] || return 1 # entries after a page that named no next one
    named="$LP_NEXT"
    [[ $n -le $PAGE_MAX ]] || return 1 # an entry on the page after the last one allowed
    all="$(jq -c --argjson g "$got" '. + $g' <<<"$all")" || return 1
    jq -e --arg k "$key" '(map(.[$k]) | unique | length) == length' >/dev/null 2>&1 <<<"$all" || return 1
  done
  for t in $lasts; do [[ "$t" == $((n - 1)) ]] || return 1; done
  [[ -z "$count" || "$(jq length <<<"$all")" == "$total" ]] || return 1
  printf '%s\n' "$all"
}

# Every ruleset, its list read whole (state_pages) and each read whole by its id, none once LIST_SECS have
# passed since the list was begun, in id order.
# shellcheck disable=SC2016 # jq's own $i
state_rulesets() {
  local l id one out='[]' start
  start="$(date +%s)"
  into l state_pages "repos/$REPO/rulesets" 'type == "array"' . id || return 1
  for id in $(jq -r '.[].id' <<<"$l"); do
    [[ $(($(date +%s) - start)) -lt $LIST_SECS ]] || return 1
    into one owner_gh api "repos/$REPO/rulesets/$id" 2>/dev/null || return 1
    json_one "$one" --argjson i "$id" 'type == "object" and .id == $i and (.name | type) == "string" and (.enforcement | type) == "string" and (.target | type) == "string" and (.rules | type) == "array"' || return 1
    out="$(jq -c --argjson r "$one" '. + [$r]' <<<"$out")" || return 1
  done
  jq -S -c 'sort_by(.id)' <<<"$out"
}

# The repository's settings a PATCH can change (round 116, review-lens round 102 C4 = SEC-2; owner): each
# must be in GitHub's answer, of its type, so one missing is never read as null; only description and
# homepage may be null, when GitHub says so. The state holds exactly these.
readonly REPO_STRINGS='["full_name","default_branch","visibility"]'
readonly REPO_NULLABLE='["description","homepage"]'
readonly REPO_BOOLEANS='["archived","allow_auto_merge","allow_merge_commit","allow_squash_merge","allow_rebase_merge","delete_branch_on_merge","has_issues","has_wiki","has_projects"]'
# shellcheck disable=SC2016 # jq's own variables
state_repo() {
  local r
  into r owner_gh api "repos/$REPO" 2>/dev/null || return 1
  json_one "$r" --arg f "$REPO" --argjson s "$REPO_STRINGS" --argjson n "$REPO_NULLABLE" --argjson b "$REPO_BOOLEANS" \
    '. as $o | type == "object" and .full_name == $f
      and all($s[]; . as $k | $o | has($k) and (.[$k] | type) == "string")
      and all($n[]; . as $k | $o | has($k) and ((.[$k] | type) == "string" or (.[$k] | type) == "null"))
      and all($b[]; . as $k | $o | has($k) and (.[$k] | type) == "boolean")' || return 1
  jq -S -c --argjson s "$REPO_STRINGS" --argjson n "$REPO_NULLABLE" --argjson b "$REPO_BOOLEANS" \
    '. as $o | reduce ($s + $n + $b)[] as $f ({}; .[$f] = $o[$f])' <<<"$r"
}

# The second throwaway's branches (at least one) and tags, each by its ref with its commit (round 117,
# review-lens round 103 C1 = SEC-2; owner): read from its branches and tags lists, which GitHub documents
# as paged (per_page, page), each whole by state_pages, keyed by name; never matching-refs, whose pages
# GitHub doesn't document, nor gh's --paginate. Each name with a commit id.
# The tags list gives a tag's commit, not the tag object (round 117b; owner): so each tag is then looked
# up once, by its exact ref (git/ref/tags/<name>, which GitHub documents as 404 when nothing matches
# exactly), and its answer must be that ref, an object of kind commit (then the list's commit) or tag,
# with a 40-hex id; the kind and id are kept, so an annotated tag made again on the same commit reads
# changed. Only plain names are looked up (REF_NAME: letters, digits, . _ - in parts joined by /, no part
# starting with a dot, no ..), at most TAG_MAX, and none once LIST_SECS have passed since the tags list was
# begun; anything else, or a lookup that fails (a rate limit or throttling too: never asked again), leaves
# the state unreadable. Unverified offline: which kind GitHub gives a plain tag and an annotated one, and
# how it reads a name with a slash in this address (either differing reads unreadable). These are
# separate reads one after another, not one snapshot. jq's ^ and $ let a trailing newline through, so
# these patterns are anchored with \A and \z.
readonly REF_NAME='\A[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*\z'
readonly SHA_ID='\A[0-9a-f]{40}\z'
# shellcheck disable=SC2016 # jq's own variables
state_refs2() {
  local h t k start name one out='[]'
  into h state_pages "repos/$REPO2/branches" 'type == "array"' . name || return 1
  start="$(date +%s)"
  into t state_pages "repos/$REPO2/tags" 'type == "array"' . name || return 1
  k='all(.[]; (.commit | type) == "object" and (.commit.sha | type) == "string" and (.commit.sha | test($id)))'
  json_one "$h" --arg id "$SHA_ID" "length > 0 and $k" || return 1
  json_one "$t" --arg id "$SHA_ID" --arg re "$REF_NAME" --argjson m "$TAG_MAX" \
    "$k and length <= \$m and all(.[]; .name | test(\$re) and (contains(\"..\") | not))" || return 1
  for name in $(jq -r '.[].name' <<<"$t"); do # plain names only: no space, newline or glob character
    [[ $(($(date +%s) - start)) -lt $LIST_SECS ]] || return 1
    into one owner_gh api "repos/$REPO2/git/ref/tags/$name" 2>/dev/null || return 1
    json_one "$one" --arg r "refs/tags/$name" --arg n "$name" --arg id "$SHA_ID" --argjson t "$t" \
      'type == "object" and .ref == $r and (.object | type) == "object" and (.object.sha | type) == "string"
        and (.object.sha | test($id))
        and (.object.type == "tag" or (.object.type == "commit" and .object.sha == ($t[] | select(.name == $n) | .commit.sha)))' || return 1
    out="$(jq -c --argjson o "$one" '. + [{ref: $o.ref, type: $o.object.type, object: $o.object.sha}]' <<<"$out")" || return 1
  done
  json_one "$out" --argjson t "$t" 'length == ($t | length)' || return 1
  jq -n -S -c --argjson h "$h" --argjson t "$t" --argjson o "$out" \
    '{heads: ($h | map({ref: ("refs/heads/" + .name), sha: .commit.sha}) | sort_by(.ref)),
      tags: ($t | map({ref: ("refs/tags/" + .name), sha: .commit.sha} as $e | $e + ($o[] | select(.ref == $e.ref) | {type, object}))
        | sort_by(.ref))}'
}

# The Environment whole, its branch policies (every page, as many as GitHub's total_count says: round 116,
# review-lens round 102 C3; owner), in id order, and the disposable secret by name.
# shellcheck disable=SC2016 # jq's own $n
state_environment() {
  local e p s
  into e owner_gh api "repos/$REPO/environments/$ENV_NAME" 2>/dev/null || return 1
  json_one "$e" --arg n "$ENV_NAME" 'type == "object" and .name == $n and (.protection_rules | type) == "array" and (.updated_at | type) == "string"' || return 1
  into p state_pages "repos/$REPO/environments/$ENV_NAME/deployment-branch-policies" 'type == "object"' .branch_policies id .total_count || return 1
  into s owner_gh api "repos/$REPO/environments/$ENV_NAME/secrets/$DISPOSABLE_NAME" 2>/dev/null || return 1
  json_one "$s" --arg n "$DISPOSABLE_NAME" 'type == "object" and .name == $n and (.created_at | type) == "string" and (.updated_at | type) == "string"' || return 1
  jq -n -S -c --argjson e "$e" --argjson p "$p" --argjson s "$s" '{environment: $e, policies: ($p | sort_by(.id)), secret: ($s | {name, created_at, updated_at})}'
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
  [[ -x "$APP_API_CURL" && ! -L "$APP_API_CURL" ]] || die "$APP_API_CURL (the system's curl) is required"
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
  into who owner_gh api user --jq .login 2>/dev/null || die "gh is not signed in as the owner"
  [[ "$who" == "$OWNER" ]] || die "gh is signed in as '$who', not $OWNER"
}

owner_uid() {
  local id
  into id owner_gh api user --jq .id 2>/dev/null || die "can't read the owner's user id"
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
# app's key. Round 109: it stays in this shell's memory; it reaches curl only on curl's standard
# input, through a pipe (jwt_curl), never a file or an argument.
make_jwt() {
  local now h p sig
  now="$(date +%s)" || die "can't read the clock"
  h="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
  p="$(printf '{"iat":%s,"exp":%s,"iss":%s}' "$((now - 60))" "$((now + 540))" "$APP_ID" | b64url)"
  sig="$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$APP_KEY" -binary | b64url)" || die "signing the JWT failed"
  [[ -n "$sig" ]] || die "signing the JWT failed"
  JWT="$h.$p.$sig"
}

# A request as the app itself (with the JWT), for what only the app can ask: who it is, where it is
# installed, a token. -q first: no ~/.curlrc. Sets LAST_OUT (the body only), LAST_HTTP, JWT_ERR
# (curl's own message, kept apart so it can't spoil the body: round 56) and JWT_RC (curl's status);
# 1 unless curl finished cleanly with a 2xx. Round 109: no file at all. The headers come on curl's
# standard input (-H @-), the body (no secret in it) is an argument, and curl's own message comes in
# its answer (-w %{errormsg}, curl -s printing none of its own).
jwt_call() { # <method> <path> [json body]
  local args=(-q -s --proto "=https" --max-time "$CALL_SECS" -X "$1" -H @- -w '\nFRG26-ERR %{errormsg}\nHTTP %{http_code}')
  local out err=""
  if [[ -n "${3:-}" ]]; then args+=(-H "Content-Type: application/json" --data-binary "$3"); fi
  JWT_RC=0
  into out jwt_curl "${args[@]}" "https://api.github.com/$2" || JWT_RC=$?
  LAST_HTTP="$(printf '%s\n' "$out" | tail -n 1 | sed -n 's/^HTTP \([0-9][0-9][0-9]\)$/\1/p')"
  if [[ -n "$LAST_HTTP" ]]; then out="$(printf '%s\n' "$out" | sed '$d')"; fi
  if [[ "$(printf '%s\n' "$out" | tail -n 1)" == "FRG26-ERR"* ]]; then
    err="$(printf '%s\n' "$out" | tail -n 1 | sed 's/^FRG26-ERR *//')"
    out="$(printf '%s\n' "$out" | sed '$d')"
  fi
  LAST_OUT="$(redact "$out")"
  JWT_ERR="$(redact "${err:+curl: ($JWT_RC) $err}" | cut -c1-200)"
  [[ $JWT_RC -eq 0 && "$LAST_HTTP" =~ ^2[0-9][0-9]$ ]]
}

# curl as the app, the JWT's headers on its standard input through a pipe (round 109): a process
# substitution, never a here-string (a temp file in bash 3.2), nor a pipeline (held stops). printf is
# a builtin: the JWT is never in a process's arguments. Bounded by app_curl.
jwt_curl() { # <curl args…>
  WT_STDIN=1 app_curl "$@" < <(printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28\n' "$JWT")
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

# The one token request (round 60, C1: mint, key-check and suspend-check all use it), with every
# safeguard the clean-up relies on. Asked once, never again (owner, round 56). GitHub issues a token
# for an hour from its issue, and a request with no complete answer may have been issued at a time
# this run can't know, so no expiry is stated for it (owner, 2026-11-23): REQ_AT is only when the
# request was sent, by this Mac's clock. It is recorded as pending before it is sent, so a signal
# while it is out still reaches the clean-up's report (round 57, C1). Catchable signals are held from before it is
# sent until a token its answer brings is registered (rounds 58, 59): a signal while it is out is
# acted on once the answer is in hand, normally within curl's own CALL_SECS (20s), or CALL_SECS + 5
# if curl fails to stop and app_curl's backstop ends it (an accepted limit for stage 1 commands only,
# not the production broker: owner, 2026-11-18, round 76). A token in a whole answer is registered
# (TOKEN, OUTSTANDING, MINTED, ISSUED, ISSUED_META) before the signal is acted on, so the clean-up
# tries its revocation and checks it; one in a lost or cut answer can't be, and is reported. A token
# is taken from the answer whatever happened to the transfer (round 56, C1), a whole quoted value
# only, never a cut one. An answer without one that isn't a clear refusal (4xx) - a timeout, a broken
# transfer, a 5xx, a 2xx without a readable token (round 57, C2) - may mean a token this run never
# received: it goes to UNRECEIVED for the clean-up's report (round 56, SEC-1). Never dies once the
# request is sent. Sets REQ_OK (0 when curl finished cleanly with a 2xx), REQ_ANSWER (the body),
# REQ_TOKEN (yes|no), REQ_UNRECEIVED (yes|no) and REQ_AT.
request_token() { # <request json>
  local t meta label
  REQ_OK=0 REQ_TOKEN=no REQ_UNRECEIVED=no REQ_ANSWER=""
  REQ_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  label="${MINT_LABEL:-${CONTROL_ID:+$CONTROL_ID-}token$((MINTED + 1))}"
  # Signals held from here (DEFERRING): into holds the answer, which holds the token, in memory.
  defer_signals
  PENDING_MINT="$label $REQ_AT $1"
  jwt_call POST "app/installations/$INSTALLATION_ID/access_tokens" "$1" || REQ_OK=1
  REQ_ANSWER="$LAST_OUT"
  LAST_OUT=""
  # Through pipes, never a here-string: bash 3.2 keeps a here-string in a temp file (round 109).
  t="$(printf '%s' "$REQ_ANSWER" | jq -r '.token // empty' 2>/dev/null)" || t=""
  if [[ -z "$t" ]]; then
    t="$(printf '%s' "$REQ_ANSWER" | grep -Eo '"token"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n 1 | sed -E 's/^"token"[[:space:]]*:[[:space:]]*"//; s/"$//')" || t=""
  fi
  if [[ -n "$t" ]]; then
    # On the exit list before it is judged, so a failed revocation is tried again on exit (round 32,
    # C1); what GitHub said it issued (named fields only, no token) kept too, so a token refused
    # later is still described if its revocation isn't confirmed (round 54, SEC-1).
    meta="$(printf '%s' "$REQ_ANSWER" | jq -S -c '{expires_at, permissions, repository_selection, repositories: [.repositories[]?.full_name]}' 2>/dev/null || echo unreadable)"
    TOKEN="$t"
    OUTSTANDING="$OUTSTANDING $t"
    MINTED=$((MINTED + 1))
    ISSUED="$ISSUED $label=$t"
    ISSUED_META="$ISSUED_META$label $meta
"
    REQ_TOKEN=yes
  elif [[ ! "$LAST_HTTP" =~ ^4[0-9][0-9]$ ]]; then
    UNRECEIVED="$UNRECEIVED$PENDING_MINT
"
    REQ_UNRECEIVED=yes
  fi
  # The pending record goes only once the token is registered or the answer settled.
  PENDING_MINT=""
  resume_signals
}

# Asks GitHub for an installation token and keeps it only if GitHub issued exactly what was asked:
# the permissions (the four unless a probe asks for fewer), selected repositories, and (narrowed)
# only the throwaway. Anything more is revoked at once (plan 4.2 step 3). MINT_ANSWER keeps what
# GitHub said it issued, without the token.
mint() { # <request json> <narrowed|whole> [permissions json, sorted]
  local want="${3:-$WANT_PERMS}" ans t perms sel repos ok
  MINT_ANSWER=""
  request_token "$1"
  ans="$REQ_ANSWER" ok="$REQ_OK"
  if [[ "$REQ_TOKEN" == no ]]; then
    if [[ "$REQ_UNRECEIVED" == yes ]]; then
      die "the token request got no usable answer (HTTP ${LAST_HTTP:-none}${JWT_ERR:+, $JWT_ERR}): it holds no installation token, but GitHub may have issued one this run never received, which can't be revoked from here; if so its expiry is unknown: one hour from when GitHub issued it (the request was sent at $REQ_AT by this Mac's clock). The run stops and does not ask again"
    fi
    die "GitHub refused the token request (HTTP $LAST_HTTP): $(printf '%s' "$ans" | tail -n 3 | tr '\n\t' '  ' | cut -c1-240)"
  fi
  # Whatever GitHub issued is revoked if it isn't kept (round 31: the owner's run refused a real
  # token and left it working until it expired). GitHub's stateless format is ghs_APPID_JWT, about
  # 520 characters, base64url parts joined by dots (changelog 2026-04-24). The length is checked on
  # its own: macOS regex allows at most 255 repeats.
  t="$TOKEN"
  if [[ $ok -ne 0 ]]; then
    # What happened, never more (round 57, C3, SEC-2).
    if revoke_token; then
      die "the token request did not end cleanly (HTTP ${LAST_HTTP:-none}${JWT_ERR:+, $JWT_ERR}), but its answer held a token: it was revoked, and the clean-up checks it"
    fi
    die "the token request did not end cleanly (HTTP ${LAST_HTTP:-none}${JWT_ERR:+, $JWT_ERR}), but its answer held a token: revoking it failed; the exit clean-up tries again and checks it"
  fi
  if [[ ! "$t" =~ ^ghs_[A-Za-z0-9._-]+$ ]] || [[ ${#t} -lt 30 || ${#t} -gt 4096 ]]; then
    if revoke_token; then
      die "GitHub's answer holds a token in a form this script doesn't expect: it was revoked"
    fi
    die "GitHub's answer holds a token in a form this script doesn't expect, and revoking it failed: it may work until it expires, within an hour; the exit clean-up tries once more"
  fi
  # The answer holds the token: read through pipes, never a here-string's temp file (round 109).
  perms="$(printf '%s' "$ans" | jq -S -c .permissions 2>/dev/null)" || perms=error
  sel="$(printf '%s' "$ans" | jq -r .repository_selection 2>/dev/null)" || sel=error
  repos="$(printf '%s' "$ans" | jq -c '[.repositories[]?.full_name]' 2>/dev/null)" || repos=error
  if [[ "$perms" != "$want" || "$sel" != selected ]] || [[ "$2" == narrowed && "$repos" != "[\"$REPO\"]" ]]; then
    if revoke_token; then
      die "the token GitHub issued carries more than was asked (permissions $perms, repositories $sel $repos): it was revoked"
    fi
    die "the token GitHub issued carries more than was asked (permissions $perms, repositories $sel $repos), and revoking it failed: it may work until it expires, within an hour; the exit clean-up tries once more"
  fi
  # Named fields only, so nothing else GitHub may add to its answer is ever printed.
  MINT_ANSWER="$(printf '%s' "$ans" | jq -S -c '{expires_at, permissions, repository_selection, repositories: [.repositories[]?.full_name]}' 2>/dev/null)" || MINT_ANSWER=unreadable
}

mint_token() { mint "{\"repositories\":[\"$REPO_NAME\"],\"permissions\":$WANT_PERMS}" narrowed; }

# Plan item 9: the installation itself, not only each token, reaches only the throwaway (so test A2
# tries a repository the app isn't installed on). Read with a whole-installation token, then revoked.
need_installation_scope() {
  mint '{}' whole
  local got
  # Bounded like every other request (round 74, C1, SEC-1): it runs inside E1's control too.
  into got with_timeout "$(call_secs)" app_gh api installation/repositories --paginate --jq '.repositories[].full_name' 2>/dev/null || got=error
  revoke_token
  [[ "$got" == "$REPO" ]] || die "the app must be installed on $REPO only (it reaches: $(printf '%s' "$got" | tr '\n' ' '))"
}

revoke_token() { # [seconds] DELETE /installation/token, which GitHub documents as stopping the token
  # at once (for stateless tokens Unconfirmed until A5, plan 4.3); 1 if GitHub didn't confirm it
  [[ -n "$TOKEN" ]] || return 0
  local rc=0 secs="${1:-$(call_secs)}"
  # No time left: not sent, and said so, never a failure or a timeout (round 83). It stays outstanding.
  if [[ $secs -le 0 ]]; then
    say "note: a token's revocation was not sent: the clean-up's time cap was reached"
    REVOKED_TOKENS="$REVOKED_TOKENS $TOKEN"
    TOKEN=""
    return 124
  fi
  # A network hang can't hold it: at most CALL_SECS, less near the clean-up's cap (rounds 52, 53).
  [[ " $REVOKE_SENT " == *" $TOKEN "* ]] || REVOKE_SENT="$REVOKE_SENT $TOKEN"
  with_timeout "$secs" app_gh api -X DELETE installation/token >/dev/null 2>&1 || rc=$?
  if [[ $rc -ne 0 ]]; then say "note: revoking a token failed or timed out; GitHub expires it within an hour"; fi
  REVOKED_TOKENS="$REVOKED_TOKENS $TOKEN"
  # Only a confirmed revocation leaves the list: a failed one is tried again on exit (round 26).
  # GitHub's answer that it was done is kept: the clean-up's confirmation needs it (round 74, SEC-2).
  if [[ $rc -eq 0 ]]; then
    outstanding_drop "$TOKEN"
    REVOKE_OK="$REVOKE_OK $TOKEN"
  fi
  TOKEN=""
  return $rc
}

# A catchable signal waits while a token is being registered (round 58, C1, SEC-1): the clean-up
# then finds the registration whole. resume_signals acts on a signal that came meanwhile. While a stop
# waits anyway, into holds each answer in memory (DEFERRING, round 109): a token request's answer,
# which holds the new token, is never in a file.
DEFERRED_SIG=""
DEFERRING=""
defer_signals() {
  DEFERRED_SIG=""
  DEFERRING=1
  trap 'DEFERRED_SIG=129' HUP
  trap 'DEFERRED_SIG=130' INT
  trap 'DEFERRED_SIG=143' TERM
}
resume_signals() {
  DEFERRING=""
  stop_traps
  if [[ -n "$DEFERRED_SIG" ]]; then
    trap '' HUP INT TERM
    exit "$DEFERRED_SIG"
  fi
}

# Runs a command for at most <seconds> (none at 0); 124 if it was stopped. The whole process tree is
# stopped: app_gh and owner_gh are functions whose subshell execs gh, so killing the job's own
# process alone would leave gh running and holding capture's output open (round 53, C1, SEC-1).
# KILL, not TERM: the clean-up ignores TERM, and what it starts inherits that. The watchdog writes
# nowhere, so a command substitution around this never waits for it. Both are on REQ_JOBS while they
# run, so a stop's clean-up stops them at once (round 75, C1). A GitHub request (through an identity)
# that times out stops the run (request_timed_out), and none starts once one has (timeout_check).
# A timeout is told by the command's own status, never by a file (review-lens round 97, SEC-1,
# SEC-3): the watchdog ends it with KILL, so it ends with 137. A command ended by KILL from anywhere
# else has no answer either, and is taken the same way: stopped at its limit, its outcome unknown.
# Round 109: neither the command nor the watchdog gets a control's pipe (fds 3 and 8), so nothing it
# starts can add to a control's record or hold it open. Its standard input is /dev/null, as for any
# command bash starts in the background, unless WT_STDIN is set (jwt_call: the JWT on a pipe).
with_timeout() { # <seconds> <command…>
  local secs="$1" pid w rc=0 n=""
  shift
  TIMED_OUT=""
  timeout_check
  [[ "$secs" =~ ^[0-9]+$ && $secs -gt 0 ]] || return 124
  # A write is noted while it is out, in this shell's memory (round 109; into notes its own job's): one
  # a stop cuts short is named by the clean-up, its outcome unknown, as is one that times out (round
  # 75, C1).
  case "$1" in
    owner_gh_run | app_gh_run | app_git_run)
      if [[ -z "$IN_JOB" && -z "$CLEANUP_DEADLINE" && -z "$PROBE_ACTIVE" ]] && request_writes "$@" && [[ "$*" != *" installation/token"* ]]; then
        write_out "$(request_what "$@")"
        n=$WRITE_N
      fi
      ;;
  esac
  if [[ -n "${WT_STDIN:-}" ]]; then "$@" <&0 3>&- 8<&- & else "$@" 3>&- 8<&- & fi
  pid=$!
  (
    # A signal to the whole process group (closing the window) must not end the watchdog: a subshell
    # resets caught signals to their default, so it ignores them itself (round 67, C1).
    trap '' HUP INT TERM
    /bin/sleep "$secs" # the clock itself, never a function of that name (round 72)
    kill_tree "$pid"
  ) </dev/null >/dev/null 2>&1 3>&- 8<&- &
  w=$!
  REQ_JOBS="$REQ_JOBS $pid $w"
  # A caught signal interrupts wait while the command may still run: job_wait waits again, under the
  # same watchdog, until the command itself has ended (round 66, C1).
  job_wait "$pid" || rc=$?
  kill_tree "$w"
  wait "$w" 2>/dev/null
  jobs_drop "$pid" "$w"
  # Its answer went to the caller, unstored and unchecked here, so even status 0 doesn't settle it
  # (round 110, review-lens round 98 C3: every write meant to settle goes through write_checked); a
  # timeout is noted by request_timed_out; a tidy-up's caller reads the state back itself.
  if [[ -n "$n" ]]; then
    if [[ $rc -ne 137 && -z "$TIDY_UP" ]]; then write_unknown "$(request_what "$@")" "sent with its answer neither stored nor checked: status $rc"; fi
    write_done "$n"
  fi
  if [[ $rc -eq 137 ]]; then
    # shellcheck disable=SC2034 # for a caller that runs with_timeout directly (round 110: the tidy-ups use capture)
    TIMED_OUT="$secs"
    case "$1" in
      owner_gh | app_gh | app_git | owner_gh_run | app_gh_run | app_git_run | curl) request_timed_out "$secs" "$@" ;;
    esac
    return 124
  fi
  return $rc
}

kill_tree() { # <pid> — stop it, then KILL it and every process below it
  local p
  kill -STOP "$1" 2>/dev/null || return 0
  for p in $(pgrep -P "$1" 2>/dev/null 3>&- 8<&-); do kill_tree "$p"; done # no control pipe for pgrep (round 110)
  kill -KILL "$1" 2>/dev/null
}

# CALL_SECS (or <limit>), or less inside the clean-up: what is left of its budget, 0 once it has
# passed (round 53, C2, SEC-2), so no request runs past the cap.
call_secs() { # [limit]
  local left max="${1:-$CALL_SECS}"
  if [[ -z "$CLEANUP_DEADLINE" ]]; then
    printf '%s' "$max"
    return
  fi
  left=$((CLEANUP_DEADLINE - $(date +%s)))
  if [[ $left -lt 0 ]]; then left=0; fi
  if [[ $left -gt $max ]]; then left=$max; fi
  printf '%s' "$left"
}

in_time() { # 1 once the clean-up's time cap has passed (no cap outside the clean-up)
  [[ -z "$CLEANUP_DEADLINE" || $(date +%s) -lt $CLEANUP_DEADLINE ]]
}

# A token request's time, read once and given to the request (round 83): a check with in_time and
# then call_secs read the clock twice, and a second turning over between them gave the request 0 s,
# so it was never sent yet counted as a try. Sets CALL_BUDGET; 1 when none is left.
CALL_BUDGET=""
call_budget() {
  CALL_BUDGET="$(call_secs)"
  [[ $CALL_BUDGET -gt 0 ]]
}

pause() { # <seconds> — a wait between polls, never past the clean-up's cap (round 72, SEC-1)
  local s
  s="$(call_secs)"
  [[ $s -lt $1 ]] || s=$1
  [[ $s -le 0 ]] || nap "$s"
}

no_answer() { # <status> — why a bounded call failed, for its CLEANUP FAIL line
  [[ $1 -ne 124 ]] || printf ' (no answer within its time limit)'
}

outstanding_drop() { # <token> — revoked or held: no longer this run's to revoke on exit
  local s=" $OUTSTANDING "
  OUTSTANDING="${s// $1 / }"
}

revoke_outstanding() { # the current token, then every other token this run minted and still owns
  local t n=0 sent=0
  revoke_token
  for t in $OUTSTANDING; do
    call_budget || break # the clean-up's time cap (round 52): what's left stays on the list, reported
    TOKEN="$t"
    revoke_token "$CALL_BUDGET"
  done
  # Each token still outstanding counted once (round 84, review-lens round 80, C1 = SEC-1): a request
  # went out for it, here or before, and was not confirmed, or none ever did (the cap came first).
  for t in $OUTSTANDING; do
    n=$((n + 1))
    [[ " $REVOKE_SENT " != *" $t "* ]] || sent=$((sent + 1))
  done
  if [[ $n -gt 0 ]]; then
    say "note: $n token(s) of this run still outstanding: $sent with a revocation request sent and not confirmed, $((n - sent)) with none sent (the clean-up's time cap was reached); GitHub expires each within an hour of its issue"
  fi
}

# A control's own token request (A9, E1) runs in a subshell whose output is hidden, and its tokens
# are revoked as it ends (round 35, C1/SEC-1). Round 110 (owner, 2026-11-25): it holds no pipe and
# writes no report: the run takes from it only its exit status, which control_exit sets and its
# wrapper passes on (control_start). 64 always (set only by control_exit), plus 32 if its command
# failed, 16 if every token it was issued (at most one) was confirmed revoked, 8 if a token request
# may have issued one never received, 4 if a request got no answer within its limit, 2 if a write has
# an unknown outcome, 1 if it was issued a token. Why a token wasn't confirmed, what a possibly
# issued one asked for and which request had no answer don't travel, so the run names them in
# general words.
control_exit() {
  local rc=$?
  # Like the clean-up, it runs to its end: a further signal (closing the window signals every
  # process, this subshell too) can't cut it short and hide a token it couldn't revoke (round 65).
  trap '' HUP INT TERM
  # Stops ignored: its answers are held in memory (round 109).
  STOPS_HELD=1
  # A request it was told to stop in is stopped first, whole (round 75, C1).
  stop_requests
  if [[ -n "$PENDING_MINT" ]]; then UNRECEIVED="$UNRECEIVED$PENDING_MINT
"; fi
  # Its own tokens are settled here and never leave it (round 73, C1, SEC-1): each revoked and its
  # revocation confirmed (revocation_judged), tried up to three times within REVOKE_SECS, and never
  # past CONTROL_END, the end of the control's own time (round 74, C1).
  local n e t s=64 issued=0 all=1
  CLEANUP_DEADLINE=$(($(date +%s) + REVOKE_SECS))
  if [[ -n "$CONTROL_END" && $CONTROL_END -lt $CLEANUP_DEADLINE ]]; then CLEANUP_DEADLINE=$CONTROL_END; fi
  settle_register
  for n in 1 2 3; do
    if [[ -z "$(settle_list)" ]] || ! in_time; then break; fi
    settle_tokens "its control's share (${REVOKE_SECS}s) was used up" >/dev/null 2>&1
    if [[ -n "$(settle_list)" && $n -lt 3 ]]; then pause 2; fi
  done
  for e in $ISSUED; do
    t="${e#*=}"
    [[ " $HELD_KEPT " != *" $t "* ]] || continue
    issued=$((issued + 1))
    [[ " $CONFIRMED_TOKENS " == *" $t "* ]] || all=""
  done
  [[ $rc -eq 0 ]] || s=$((s | 32))
  [[ -z "$UNRECEIVED" ]] || s=$((s | 8))
  [[ -z "$STOP_LINES" ]] || s=$((s | 4))
  [[ -z "$WRITES_UNKNOWN$WRITES_OUT" ]] || s=$((s | 2))
  [[ $issued -eq 0 ]] || s=$((s | 1))
  if [[ -n "$all" && $issued -le 1 ]]; then s=$((s | 16)); fi
  exit "$s"
}

control_begin() { # <name> — inside a control: only its own tokens, named after it, and its own notes
  CONTROL_ID="$1"
  TOKEN="" OUTSTANDING="" ISSUED="" ISSUED_META="" CONFIRMED_TOKENS="" SETTLE_TRIED="" UNRECEIVED="" PENDING_MINT=""
  REVOKE_OK="" UNCONFIRMABLE="" CONTROL_PID="" REQ_JOBS=""
  WRITES_OUT="" WRITES_UNKNOWN="" STOP_LINES=""
}

# A control runs in the background, bounded as a whole (round 74, C1, SEC-1). Its watchdog tells it
# to stop (TERM) once its work has had its share, which leaves its own clean-up REVOKE_SECS (and
# CALL_SECS for the request it may be in), and stops it outright (KILL) at CONTROL_SECS. A stop to
# the run while a control works isn't held until the control ends any more: the control is told to
# stop and settles its own tokens while the run's clean-up runs, which collects its result
# (control_collect). A control stopped outright, or one with no result, leaves its tokens NOT
# confirmed and the clean-up INCOMPLETE.
control_token() { # <command> — 0 if its command worked; its tokens are settled in it and reported here
  # Named, and counted as not done, before it can ask for a token (round 73, C1, SEC-1).
  CONTROLS=$((CONTROLS + 1))
  CONTROL_NAME="control$CONTROLS"
  CONTROL_PENDING="$CONTROL_PENDING $CONTROL_NAME"
  # Signals are held while it starts and while its result is registered here, so a signal then can't
  # lose it (round 63, C1); while it runs, a stop is acted on within a second (control_wait).
  defer_signals
  control_start "$@"
  control_wait || resume_signals
  control_end ""
  resume_signals
  # A control's request that may have issued a token never received stops the run, reported
  # (round 61, SEC-1).
  if [[ -n "$CONTROL_UNREC" ]]; then
    report_unreceived
    die "a control's token request got no usable answer: GitHub may have issued a token this run never received; the run stops"
  fi
  # A request of the control's that timed out stops the run too (round 75, C1).
  timeout_check
  [[ -n "$CONTROL_RC" ]] && [[ $((CONTROL_RC & 32)) -eq 0 ]]
}

# The control and its watchdog (round 110). A wrapper, the process substitution, starts the control
# as its own job with no pipe (output and errors to /dev/null, fds 3 and 8 closed), says the
# control's process id, waits for it and says its exit status: two lines, the only ones on the pipe.
# The wrapper runs no program, only builtins, so it alone holds the pipe's write end; the run reads it
# on fd 8, and every program the run starts while it is open has fd 8 closed.
control_start() { # <command…>
  local stop_in=$((CONTROL_SECS - REVOKE_SECS - CALL_SECS - 5)) line=""
  CONTROL_END=$(($(date +%s) + CONTROL_SECS - 5))
  CONTROL_END_S=$((SECONDS + CONTROL_SECS - 5)) CONTROL_TOLD_AT_S=$((SECONDS + stop_in))
  CONTROL_RC="" CONTROL_WATCH="" CONTROL_TOLD="" CONTROL_PID="" CONTROL_LINES="" CONTROL_PARTIAL="" CONTROL_KILLED=""
  CONTROL_MINTED_AT=$MINTED
  # shellcheck disable=SC2030 # the wrapper's own variables, in its subshell
  exec 8< <(
    (
      control_begin "$CONTROL_NAME"
      trap control_exit EXIT
      resume_signals
      "$@"
    ) >/dev/null 2>&1 </dev/null 3>&- 8<&- &
    c=$!
    # Started first, so the control keeps its own signals; the wrapper itself ignores them.
    trap '' HUP INT TERM
    echo "CONTROL $CONTROL_NAME pid $c"
    rc=0
    wait "$c" || rc=$?
    echo "CONTROL $CONTROL_NAME status $rc"
  )
  CONTROL_WRAP=$!
  IFS= read -r -t 5 line <&8 || true
  if [[ "$line" =~ ^CONTROL\ $CONTROL_NAME\ pid\ ([0-9]+)$ ]]; then
    CONTROL_PID="${BASH_REMATCH[1]}"
  else
    CONTROL_LINES="$line"$'\n' CONTROL_PARTIAL=1
    return 0
  fi
  # Told to stop (TERM) once its work has had its share; stopped outright (status 11) at its limit.
  (
    trap '' HUP INT TERM
    /bin/sleep "$stop_in"
    kill -0 "$CONTROL_PID" 2>/dev/null || exit 0
    kill -TERM "$CONTROL_PID" 2>/dev/null
    /bin/sleep $((REVOKE_SECS + CALL_SECS + 5))
    kill -0 "$CONTROL_PID" 2>/dev/null || exit 0
    kill_tree "$CONTROL_PID"
    exit 11
  ) </dev/null >/dev/null 2>&1 3>&- 8<&- &
  CONTROL_WATCH=$!
}

# 0 once the control's status has come; 1 as soon as a stop comes instead, or if one came while it
# started. A stop is passed on to the control as it comes; it is acted on within about a second
# (bash 3.2's read of a pipe isn't cut short by a signal, so the pipe is read a second at a time: a
# change of stop behaviour the owner decides on before any live use). Signals are held again after.
control_wait() {
  trap 'control_stop 129' HUP
  trap 'control_stop 130' INT
  trap 'control_stop 143' TERM
  [[ -z "$DEFERRED_SIG" ]] || control_stop "$DEFERRED_SIG"
  while :; do
    [[ -z "$DEFERRED_SIG" ]] || return 1
    control_read $((CONTROL_END_S + 10)) || break
  done
  trap 'DEFERRED_SIG=129' HUP
  trap 'DEFERRED_SIG=130' INT
  trap 'DEFERRED_SIG=143' TERM
  return 0
}

control_stop() { # <status> — a stop while a control runs: kept, and passed on to the control once
  DEFERRED_SIG="$1"
  [[ -n "$CONTROL_TOLD" || -z "$CONTROL_PID" ]] || kill -TERM "$CONTROL_PID" 2>/dev/null
  CONTROL_TOLD=1
}

# One read of the control's pipe, for at most a second; builtins only, no program (none may get fd 8).
# bash 3.2's read gives the same status when nothing came within the second and at the pipe's end, so
# the end is told otherwise: 1 once the status line has come, the wrapper is gone, or <cap> (in the
# shell's SECONDS) has passed. A last line cut short (no newline) is kept, and marks it partial.
control_read() { # <cap, in SECONDS>
  local line="" rc=0
  IFS= read -r -t 1 line <&8 || rc=$?
  if [[ $rc -eq 0 ]]; then
    CONTROL_LINES="$CONTROL_LINES$line"$'\n'
    [[ "$line" != "CONTROL $CONTROL_NAME status "* ]] || return 1
    return 0
  fi
  if [[ -n "$line" ]]; then CONTROL_LINES="$CONTROL_LINES$line"$'\n' CONTROL_PARTIAL=1; fi
  kill -0 "$CONTROL_WRAP" 2>/dev/null || return 1
  [[ $SECONDS -lt $1 ]] || return 1
  return 0
}

# The control's end and its result: once it has ended, or (in the clean-up) by <cap> at the latest,
# when it is stopped outright. The result is judged (control_judge) and said.
control_end() { # [cap, in seconds since 1970]
  local id="$CONTROL_NAME" w cap
  if [[ -n "$1" && -n "$CONTROL_PID" ]]; then
    cap=$((SECONDS + $1 - $(date +%s 3>&- 8<&-)))
    while control_read "$cap"; do :; done
    if [[ "$CONTROL_LINES" != *"CONTROL $id status "* ]] && kill -0 "$CONTROL_PID" 2>/dev/null; then
      kill_tree "$CONTROL_PID"
      CONTROL_KILLED=1
      while control_read $((SECONDS + 3)); do :; done
    fi
  fi
  if [[ -n "$CONTROL_WATCH" ]]; then
    if kill -0 "$CONTROL_WATCH" 2>/dev/null; then
      kill_tree "$CONTROL_WATCH"
      wait "$CONTROL_WATCH" 2>/dev/null
    else
      w=0
      wait "$CONTROL_WATCH" 2>/dev/null || w=$?
      [[ $w -ne 11 ]] || CONTROL_KILLED=1
    fi
  fi
  if kill -0 "$CONTROL_WRAP" 2>/dev/null; then kill_tree "$CONTROL_WRAP"; fi
  exec 8<&-
  CONTROL_PID="" CONTROL_WATCH="" CONTROL_UNREC=""
  control_judge "$id"
  if [[ -n "$CONTROL_KILLED" ]]; then say "note: $id did not end in time and was stopped outright, before it could report"; fi
  if [[ -n "$CONTROL_RC" && $((CONTROL_RC & 32)) -ne 0 && -z "$CONTROL_TOLD" && $SECONDS -ge $CONTROL_TOLD_AT_S ]]; then
    say "note: $id's work took longer than its share of its ${CONTROL_SECS}s: it was told to stop"
  fi
  if [[ " $CONTROL_PENDING " == *" $id "* ]]; then
    say "note: $id ended without reporting on its tokens: any it holds is NOT confirmed revoked"
  fi
}

# A control's result comes only from its wrapper's one line after the process id: its status,
# whole, with control_exit's marker (64) and bits that agree (not every token confirmed only if it was
# issued one). Anything else (a cut line, another line, a status without the marker, a signal's,
# another control's, nothing) is no result: the control stays pending, its tokens NOT confirmed, the
# clean-up INCOMPLETE (owner, 2026-11-25). Its token is named as request_token names it:
# <id>-token<MINTED+1>.
control_judge() { # <id> — from CONTROL_LINES, CONTROL_PARTIAL, CONTROL_MINTED_AT
  local id="$1" l="${CONTROL_LINES%$'\n'}" s label p
  CONTROL_RC=""
  [[ -z "$CONTROL_PARTIAL" && "$CONTROL_LINES" == "$l"$'\n' && "$l" != *$'\n'* ]] || return 0
  [[ "$l" =~ ^CONTROL\ $id\ status\ ([0-9]+)$ ]] || return 0
  s="${BASH_REMATCH[1]}"
  [[ $s -lt 128 && $((s & 64)) -ne 0 ]] || return 0
  [[ $((s & 16)) -ne 0 || $((s & 1)) -ne 0 ]] || return 0
  CONTROL_RC="$s"
  p=" $CONTROL_PENDING "
  CONTROL_PENDING="${p// $id / }"
  label="$id-token$((CONTROL_MINTED_AT + 1))"
  if [[ $((s & 1)) -ne 0 && $((s & 16)) -ne 0 ]]; then
    CONTROL_CONFIRMED="$CONTROL_CONFIRMED $label"
  elif [[ $((s & 1)) -ne 0 ]]; then
    # What the control reports is said before a held signal acts (round 64, C1, SEC-1): its tokens
    # live only in its subshell.
    CONTROL_UNCONFIRMED="$CONTROL_UNCONFIRMED $label"
    say "note: a control's token could not be revoked, or its revocation not confirmed: $label (and any later token of $id's; why is not passed on); it may work until it expires, within an hour of its issue"
  fi
  if [[ $((s & 8)) -ne 0 ]]; then
    CONTROL_UNREC="$id-token$((CONTROL_MINTED_AT + 1 + (s & 1))) unknown {}"$'\n'
    UNRECEIVED="$UNRECEIVED$CONTROL_UNREC"
  fi
  [[ $((s & 4)) -eq 0 ]] || STOP_LINES="${STOP_LINES}a request of $id's got no answer within its limit"$'\n'
  [[ $((s & 2)) -eq 0 ]] || write_unknown "$id's writes" "it had one or more with no settled answer: their outcomes are unknown"
  return 0
}

# In the clean-up: a control the stop found running, collected by the clean-up's cap at the latest.
control_collect() {
  control_end "${CLEANUP_DEADLINE:-$((CONTROL_END + 5))}"
  if [[ -n "$CONTROL_UNREC" ]]; then report_unreceived; fi
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
  into info owner_gh api "repos/$REPO" --jq '[.full_name, .owner.login, .description, (.private|tostring)] | @tsv' 2>/dev/null \
    || die "can't read $REPO"
  [[ "$info" == "$REPO"$'\t'"$OWNER"$'\t'"$MARKER"$'\t'false ]] \
    || die "$REPO is not the public throwaway repo this script created (description must be: $MARKER)"
}

assert_second() { # writes to the second throwaway are attempts only, and only there
  local info
  into info owner_gh api "repos/$REPO2" --jq '[.full_name, .owner.login, .description, (.private|tostring)] | @tsv' 2>/dev/null \
    || die "can't read $REPO2"
  [[ "$info" == "$REPO2"$'\t'"$OWNER"$'\t'"$MARKER2"$'\t'false ]] \
    || die "$REPO2 is not the public second throwaway this script created (description must be: $MARKER2)"
}

# The run's private work folder: its clone, the clone's template and the payloads of its requests.
# Round 109: nothing the clean-up relies on is in it, and no credential: no password helper, no home
# folder, no gh settings, no JWT, no record of a write (all kept in the run's own shell). It is never
# deleted (owner, 2026-11-24): the clean-up says so.
make_work() {
  WORK="$(mktemp -d "/private/tmp/frg26.XXXXXX")" || die "mktemp failed"
  WORK_MADE="$WORK"
  chmod 700 "$WORK" || die "chmod failed"
  mkdir -m 700 "$WORK/template" || die "mkdir failed"
}

# --- Repository state ---------------------------------------------------------------------------

branch_state() { # <branch> — prints protected | unprotected | missing | error
  local out rc=0
  into -2 out owner_gh api "repos/$REPO/branches/$1" --jq .protected || rc=$?
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
  local j
  into j owner_gh api "repos/$REPO/branches/$1/protection" 2>/dev/null || { echo error; return; }
  jq -S -c 'walk(if type == "object" then del(.url) else . end)' <<<"$j" 2>/dev/null || echo error
}

# What protection_full reads after protection_json <enforce_admins> is applied (read from the
# throwaway on 2026-10-31). GitHub leaves out required_status_checks and restrictions when null.
want_protection() { # <enforce_admins true|false>
  printf '{"allow_deletions":{"enabled":false},"allow_force_pushes":{"enabled":false},"allow_fork_syncing":{"enabled":false},"block_creations":{"enabled":false},"enforce_admins":{"enabled":%s},"lock_branch":{"enabled":false},"required_conversation_resolution":{"enabled":false},"required_linear_history":{"enabled":false},"required_pull_request_reviews":{"dismiss_stale_reviews":true,"require_code_owner_reviews":true,"require_last_push_approval":true,"required_approving_review_count":1},"required_signatures":{"enabled":false}}\n' "$1"
}

# A protection that isn't protect's is reported by these fixed names only (review-lens round 82,
# SEC-1): never a value GitHub returned and never another name, since a required check's name is
# free text and could hold a credential. The settings of a whole protection, as GitHub names them:
readonly PROTECTION_SETTINGS="allow_deletions allow_force_pushes allow_fork_syncing block_creations enforce_admins lock_branch required_conversation_resolution required_linear_history required_pull_request_reviews required_signatures required_status_checks restrictions"
# and protection_of's seven fields, in its order.
readonly SEVEN_FIELDS="required_approving_review_count require_code_owner_reviews require_last_push_approval dismiss_stale_reviews enforce_admins allow_force_pushes allow_deletions"

protection_diff() { # <got> <want>: whole protections; the listed settings that differ, as one line
  jq -n -r --argjson a "$1" --argjson b "$2" --arg names "$PROTECTION_SETTINGS" '
    ($names | split(" ")) as $n
    | if ($a | type) != "object" then "an answer that is not a protection" else
        ([$a, $b] | map(keys) | add | unique | map(select($a[.] != $b[.]))) as $d
        | [$d[] | select(. as $k | any($n[]; . == $k))]
          + (if any($d[]; . as $k | any($n[]; . == $k) | not) then ["a setting not on the list"] else [] end)
        | if length == 0 then "nothing that can be named" else join(", ") end
      end' 2>/dev/null || echo "an answer that can't be read"
}

fields_diff() { # <got> <want>: protection_of lines; the names of the fields that differ
  local -a got_fields want_fields field_names
  local i out=""
  read -r -a got_fields <<<"$1"
  read -r -a want_fields <<<"$2"
  read -r -a field_names <<<"$SEVEN_FIELDS"
  if [[ ${#got_fields[@]} -ne ${#field_names[@]} ]]; then echo "an answer that can't be compared field by field"; return; fi
  for ((i = 0; i < ${#field_names[@]}; i++)); do
    [[ "${got_fields[$i]}" == "${want_fields[$i]}" ]] || out="${out:+$out, }${field_names[$i]}"
  done
  echo "${out:-nothing that can be named}"
}

ruleset_summary() { # one line describing the only ruleset, or error
  local id
  into id owner_gh api "repos/$REPO/rulesets" --jq '.[0].id' 2>/dev/null || { echo error; return; }
  [[ "$id" =~ ^[0-9]+$ ]] || { echo error; return; }
  owner_gh api "repos/$REPO/rulesets/$id" --jq '[.enforcement, .target, (.conditions.ref_name.include | join(",")), (.conditions.ref_name.exclude | length | tostring), ([.rules[] | if .type == "update" then "update:\(.parameters.update_allows_fetch_and_merge)" else .type end] | sort | join(",")), ([.bypass_actors[] | "\(.actor_type):\(.actor_id):\(.bypass_mode)"] | join(","))] | join(" ")' 2>/dev/null || echo error
}

want_ruleset() { # the two bypass choices this script may have installed (the second, before round 111)
  local uid
  into uid owner_uid || return 1 # owner_uid's die ends only its own job (review round 10)
  printf 'active branch refs/heads/main 0 deletion,non_fast_forward,update:false User:%s:always\n' "$uid"
  printf 'active branch refs/heads/main 0 deletion,non_fast_forward,update:false RepositoryRole:5:always\n'
}

verify_phase() { # <phase> — the repository must be exactly in the state that phase needs
  local d m r got want
  into d branch_state dev
  into m branch_state main
  into r ruleset_count
  case "$1" in
    open)
      [[ "$d" == unprotected && "$m" == unprotected && "$r" == 0 ]] \
        || die "phase open needs dev and main unprotected and no ruleset (dev $d, main $m, rulesets $r)"
      ;;
    protected | ruleset)
      [[ "$d" == protected && "$m" == protected ]] || die "phase $1 needs dev and main protected (dev $d, main $m)"
      # A mismatch names the settings that differ, never what GitHub returned (round 82, SEC-1).
      into got protection_of dev
      [[ "$got" == "$WANT_DEV" ]] || die "dev protection is not exactly what protect applies (differs in: $(fields_diff "$got" "$WANT_DEV"))"
      into got protection_of main
      [[ "$got" == "$WANT_MAIN" ]] || die "main protection is not exactly what protect applies (differs in: $(fields_diff "$got" "$WANT_MAIN"))"
      # All of it, not only those fields: an extra required check or restriction would make a
      # refusal pass for the wrong reason, and unprotect would delete what protect didn't apply.
      into got protection_full dev
      [[ "$got" == "$(want_protection true)" ]] || die "dev protection is not exactly what protect applies (differs in: $(protection_diff "$got" "$(want_protection true)"))"
      into got protection_full main
      [[ "$got" == "$(want_protection false)" ]] || die "main protection is not exactly what protect applies (differs in: $(protection_diff "$got" "$(want_protection false)"))"
      if [[ "$1" == protected ]]; then
        [[ "$r" == 0 ]] || die "phase protected needs no ruleset (found $r)"
      else
        [[ "$r" == 1 ]] || die "phase ruleset needs exactly one ruleset (found $r)"
        into got ruleset_summary
        { into want want_ruleset && grep -Fxq -- "$got" <<<"$want"; } || die "the ruleset is '$got', not one this script installs"
      fi
      ;;
    *) die "unknown phase $1" ;;
  esac
}

# --- Owner commands -----------------------------------------------------------------------------

# Round 110 (owner): each of these setup writes goes through write_checked, settled only by the
# answer its operation expects (the object GitHub's API returns); anything else stays outcome unknown.
put_file() { # <path> <content> — the owner commits a file to main through the API (no git)
  local b64
  b64="$(printf '%s' "$2" | base64 | tr -d '\n')"
  write_checked "json:.content.path == \"$1\"" owner_gh api -X PUT "repos/$REPO/contents/$1" -f message="FRG-26 throwaway baseline: $1" \
    -f content="$b64" -f branch=main || die "adding $1 failed"
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
  write_checked "text:^https://github.com/$REPO\$" owner_gh repo create "$REPO" --public --description "$MARKER" --add-readme || die "gh repo create failed"
  assert_throwaway
  # The repository read back as the one this script creates: its create is settled (rule (b)).
  write_resolved "$(owner_what repo create "$REPO" --public --description "$MARKER" --add-readme)"
  local first
  into first owner_gh api "repos/$REPO" --jq .default_branch || die "can't read the first branch's name"
  if [[ "$first" != main ]]; then
    write_checked 'json:.name == "main"' owner_gh api -X POST "repos/$REPO/branches/$first/rename" -f new_name=main \
      || die "renaming the first branch '$first' to main failed"
  fi
  put_file .github/CODEOWNERS "* @$OWNER"$'\n'
  put_file docs/README.md "Docs folder (CODEOWNERS may also live here; test B4b)."$'\n'
  put_file tests/README.md "Test files land here."$'\n'
  local sha
  into sha owner_gh api "repos/$REPO/branches/main" --jq .commit.sha || die "can't read main"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "unexpected main sha"
  write_checked 'json:.ref == "refs/heads/dev"' owner_gh api -X POST "repos/$REPO/git/refs" -f ref=refs/heads/dev -f sha="$sha" || die "creating dev failed"
  write_checked 'json:.ref == "refs/heads/side"' owner_gh api -X POST "repos/$REPO/git/refs" -f ref=refs/heads/side -f sha="$sha" || die "creating side failed"
  write_checked "json:.ref == \"refs/tags/$BASELINE_TAG\"" owner_gh api -X POST "repos/$REPO/git/refs" -f ref="refs/tags/$BASELINE_TAG" -f sha="$sha" || die "creating the baseline tag failed"
  repo_settings
  say "created $REPO (public), baseline $sha, branches main dev side, default $DEFAULT_BRANCH"
}

# The second throwaway (test A2): public, the app not installed, one branch to open a PR from.
cmd_create_second() {
  need_owner
  if owner_gh api "repos/$REPO2" >/dev/null 2>&1; then
    die "$REPO2 already exists; delete it in the browser first if you want a fresh one"
  fi
  write_checked "text:^https://github.com/$REPO2\$" owner_gh repo create "$REPO2" --public --description "$MARKER2" --add-readme || die "gh repo create failed"
  assert_second
  write_resolved "$(owner_what repo create "$REPO2" --public --description "$MARKER2" --add-readme)"
  local first sha
  into first owner_gh api "repos/$REPO2" --jq .default_branch || die "can't read the first branch's name"
  if [[ "$first" != main ]]; then
    write_checked 'json:.name == "main"' owner_gh api -X POST "repos/$REPO2/branches/$first/rename" -f new_name=main \
      || die "renaming the first branch '$first' to main failed"
  fi
  into sha owner_gh api "repos/$REPO2/branches/main" --jq .commit.sha || die "can't read main"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "unexpected main sha"
  # The branch first, then a commit on it: A2's PR attempt needs a branch ahead of main, or no one
  # could open it and its refusal would prove nothing (round 15, SEC-1).
  write_checked "json:.ref == \"refs/heads/$A2_BRANCH\"" owner_gh api -X POST "repos/$REPO2/git/refs" -f ref="refs/heads/$A2_BRANCH" -f sha="$sha" || die "creating $A2_BRANCH failed"
  write_checked 'json:.content.path == "a2.txt"' owner_gh api -X PUT "repos/$REPO2/contents/a2.txt" -f message="FRG-26 A2 branch" \
    -f content="$(printf 'FRG-26 A2\n' | base64 | tr -d '\n')" -f branch="$A2_BRANCH" || die "adding a2.txt to $A2_BRANCH failed"
  say "created $REPO2 (public; the app is not installed here), branch $A2_BRANCH"
}

repo_settings() {
  # Auto-merge is on, so B11 tests whether an enabled auto-merge waits for the owner's approval.
  write_checked "json:.full_name == \"$REPO\" and .default_branch == \"$DEFAULT_BRANCH\"" owner_gh api -X PATCH "repos/$REPO" \
    -f default_branch="$DEFAULT_BRANCH" -F allow_auto_merge=true -F allow_merge_commit=true -F allow_squash_merge=true \
    -f description="$MARKER" || die "setting the repository options failed"
}

# The app's API allowance, read-only (GitHub doesn't count this request against it). Sets
# RATE_LINE (for people), RATE_LEFT (GraphQL points remaining) and RATE_REST (REST requests
# remaining); 1 if any of them can't be read.
app_rate() {
  RATE_LINE="" RATE_LEFT="" RATE_REST=""
  capture with_timeout "$(call_secs)" app_gh api rate_limit || return 1
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
    into s branch_state "$b"
    [[ "$s" == unprotected || "$s" == missing ]] || die "reset only runs while nothing is protected ($b is $s)"
  done
  local base open_prs n
  into n ruleset_count
  [[ "$n" == 0 ]] || die "reset only runs while there is no ruleset"
  into base owner_gh api "repos/$REPO/git/ref/tags/$BASELINE_TAG" --jq .object.sha || die "the baseline tag is missing"
  [[ "$base" =~ ^[0-9a-f]{40}$ ]] || die "unexpected baseline sha"
  into open_prs owner_gh api --paginate "repos/$REPO/pulls?state=open&per_page=100" --jq '.[].number' || die "can't list open PRs"
  for n in $open_prs; do
    [[ "$n" =~ ^[0-9]+$ ]] || die "unexpected PR number '$n'"
    # gh's own words for a close (not checked against gh 2.102.0's output, which may print none
    # unless on a terminal); the list read back below settles it either way (round 110, rule (b)).
    write_checked "text:Closed pull request .*#$n" owner_gh pr close "$n" --repo "$REPO" || die "closing PR #$n failed"
  done
  if [[ -n "$open_prs" ]]; then
    local still
    into still owner_gh api --paginate "repos/$REPO/pulls?state=open&per_page=100" --jq '.[].number' || die "can't list open PRs after closing them"
    for n in $open_prs; do
      [[ " $(printf '%s' "$still" | tr '\n' ' ') " == *" $n "* ]] && die "PR #$n is still open after its close"
      write_resolved "$(owner_what pr close "$n" --repo "$REPO")"
    done
  fi
  # Read again right before each rewrite, and rewrite only an unprotected branch (or recreate a
  # missing one): an unreadable or newly protected branch stops the reset (review round 11).
  for b in main dev side; do
    into s branch_state "$b"
    case "$s" in
      missing)
        write_checked "json:.ref == \"refs/heads/$b\" and .object.sha == \"$base\"" owner_gh api -X POST "repos/$REPO/git/refs" \
          -f ref="refs/heads/$b" -f sha="$base" || die "recreating $b failed"
        ;;
      unprotected)
        write_checked "json:.ref == \"refs/heads/$b\" and .object.sha == \"$base\"" owner_gh api -X PATCH "repos/$REPO/git/refs/heads/$b" \
          -f sha="$base" -F force=true || die "resetting $b failed"
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
  local s ea=false full
  [[ "$1" == dev ]] && ea=true
  into s branch_state "$1"
  case "$s" in
    unprotected | protected) ;;
    *) die "$1 reads $s: stopped before changing it" ;;
  esac
  if [[ "$s" == protected ]]; then
    into full protection_full "$1"
    [[ "$full" == "$(want_protection "$ea")" ]] || die "$1 is protected, but not exactly as protect applies it: stopped before changing it"
  fi
  BRANCH_PROTECTION="$s"
}

# Which of dev and main protect or unprotect must change, in PROTECTION_TODO. Each branch must be
# unprotected or carry exactly protect's protection; one already in the wanted state is left as it
# is, so a run that changed dev and then failed on main can be run again (review rounds 41 and 43,
# C1). Anything else, an unreadable branch or a ruleset, stops before any write. Each branch is
# read again right before its own write (protection_write), as reset does (review round 44, C1).
protection_todo() { # <protected|unprotected>: the state wanted
  local b n
  PROTECTION_TODO=""
  into n ruleset_count
  [[ "$n" == 0 ]] || die "protect and unprotect only run while there is no ruleset"
  for b in dev main; do
    branch_protection "$b"
    [[ "$BRANCH_PROTECTION" == "$1" ]] || PROTECTION_TODO="$PROTECTION_TODO $b"
  done
}

# Reads the branch again; writes only if it still needs it (GitHub has no conditional write, so a
# change in the moment between this read and the write can't be caught).
protection_write() { # <branch> <protected|unprotected> <gh api args…>
  local b="$1" want="$2" code=200
  shift 2
  branch_protection "$b"
  [[ "$BRANCH_PROTECTION" != "$want" ]] || return 0
  # Checked by GitHub's status line (round 110): 200 for a protection set, 204 for one removed; the
  # caller's full read-back (verify_phase) then settles it either way (rule (b)).
  [[ "$want" == protected ]] || code=204
  write_checked "status:$code" owner_gh api -i "$@"
}

# After verify_phase has read the whole protection back as wanted: each branch's protection write
# is settled by that read-back (round 110, owner's rule (b)).
protection_resolved() { # <PUT|DELETE>
  local b
  for b in dev main; do write_resolved "owner gh api $1 repos/$REPO/branches/$b/protection"; done
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
  protection_resolved PUT
  local p
  into p protection_of dev
  say "dev protection:  $p   (approvals codeowners last-push stale enforce-admins force deletions)"
  into p protection_of main
  say "main protection: $p"
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
  protection_resolved DELETE
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
  into uid owner_uid || die "can't read the owner's user id, so no ruleset was requested"
  ruleset_json User "$uid" >"$WORK/ruleset-user.json"
  # Round 111 (review-lens round 99, C3 = SEC-1; owner): sent once, with no fallback form: a failure,
  # whatever its words, or a list showing no ruleset can't show the first request changed nothing, so a
  # second could make two. Anything but its expected answer (the ruleset, with its id) stops here.
  # Round 113 (review-lens round 100, C4; owner): that answer doesn't settle it: sent with no expected
  # answer of its own, so it stays outcome unknown until the read-back below of the very form sent.
  capture owner_gh api -X POST "repos/$REPO/rulesets" --input "$WORK/ruleset-user.json" || true
  if [[ $LAST_RC -ne 0 ]] || ! answer_expected 'json:.id | type == "number"' "$LAST_OUT"; then
    die "the ruleset request wasn't answered as made (its outcome is unknown; not sent again): check $REPO's rulesets on GitHub before running this again: $(evidence)"
  fi
  local rid back sent sum
  rid="$(jq -r .id <<<"$LAST_OUT")"
  [[ "$rid" =~ ^[0-9]+$ ]] || die "the ruleset's id isn't a number (its outcome is unknown): check $REPO's rulesets on GitHub"
  say "ruleset created with bypass: the owner (User $uid)"
  verify_phase ruleset
  # Round 115 (review-lens round 101, C2; owner): read back by the id its create answered with, and
  # every field submitted (ruleset_form) equal to the read-back, normalised: only then is it settled.
  into back owner_gh api "repos/$REPO/rulesets/$rid" 2>/dev/null \
    || die "the ruleset $rid can't be read back (its outcome stays unknown): check $REPO's rulesets on GitHub"
  sent="$(ruleset_form "$(cat "$WORK/ruleset-user.json")")" || die "the ruleset sent can't be read as JSON"
  [[ -n "$sent" && "$(ruleset_form "$back")" == "$sent" ]] \
    || die "the ruleset read back is not, field for field, the one requested: check $REPO's rulesets on GitHub"
  write_resolved "$(owner_what api -X POST "repos/$REPO/rulesets")"
  into sum ruleset_summary
  say "ruleset: $sum"
}

# The fields cmd_ruleset submits, from a ruleset as sent or as GitHub returns it, normalised: GitHub's own
# extra fields left out, the rules (each its type, and its parameters where it has any) and the bypass
# actors (each its id, type and mode) in a fixed order. Nothing if it isn't one JSON object.
ruleset_form() { # <ruleset JSON>
  json_one "$1" 'type == "object"' || return 1
  jq -S -c '{name, target, enforcement, conditions,
    rules: ((.rules // []) | map({type} + (if (.parameters // null) != null then {parameters} else {} end)) | sort_by(.type)),
    bypass_actors: ((.bypass_actors // []) | map({actor_id, actor_type, bypass_mode}) | sort_by(.actor_type, .actor_id))}' <<<"$1"
}

cmd_actions_setting() {
  need_owner
  assert_throwaway
  local v
  into v owner_gh api "repos/$REPO/actions/permissions/workflow" --jq .can_approve_pull_request_reviews \
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
    into st branch_state "$b"
    prot=none
    if [[ "$st" == protected ]]; then into prot protection_of "$b"; fi
    if [[ "$st" == error || "$prot" == error ]]; then bad="$bad $b"; fi
    say "$b: $st [$prot]"
  done
  into n ruleset_count
  sum=none
  if [[ ! "$n" =~ ^[0-9]+$ ]]; then bad="$bad rulesets"
  elif [[ "$n" -gt 0 ]]; then
    into sum ruleset_summary
    if [[ "$sum" == error ]]; then bad="$bad ruleset"; fi
  fi
  say "rulesets: $n [$sum]"
  into def owner_gh api "repos/$REPO" --jq .default_branch || def=""
  if [[ -z "$def" ]]; then bad="$bad default-branch"; fi
  say "default branch: ${def:-error}"
  if [[ -n "$bad" ]]; then die "could not read:$bad"; fi
}

# The handoffs' exact-protection check (owner 2026-11-22, review-lens round 81, C1 = SEC-1): the
# whole protection, compared as protect's own read-back compares it (verify_phase protected: dev and
# main each exactly as protect applies it, no ruleset), where status prints only seven fields, which
# a required check or a locked branch doesn't change. As the owner, reads only; no app token.
cmd_exact_protection() {
  need_owner
  assert_throwaway
  verify_phase protected
  say "exact protection: dev and main exactly as protect applies them, no ruleset"
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
  with_timeout "$(call_secs)" owner_gh pr view "$1" --repo "$REPO" --json "$2" --jq "$3" 2>/dev/null
}

wait_settled() { # <pr> — GitHub computes mergeability in the background; 1 if it never settles
  local _ st
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    into st pr_view "$1" mergeable .mergeable || st=UNKNOWN
    [[ "$st" == MERGEABLE || "$st" == CONFLICTING ]] && return 0
    nap 3
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
    if ! wait_settled "$pr"; then
      into facts merge_facts "$pr"
      OBS=inconclusive LAST_OUT="mergeability never settled [$facts]"
      return
    fi
    capture app_gh pr merge "$pr" --repo "$REPO" "$@" || true
    nap 3
    into facts merge_facts "$pr"
    if [[ "$facts" == MERGED* ]]; then OBS=allowed; LAST_OUT="$LAST_OUT [$facts]"; return; fi
    [[ "$(expect "$id" "$PHASE")" == allowed ]] || break
    nap 5
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
  # gh's own words for an approval (round 110; not checked against gh 2.102.0's output, which may print
  # none unless on a terminal: then it stays outcome unknown, rule (b)).
  write_checked "text:Approved pull request .*#$1" owner_gh pr review "$1" --repo "$REPO" --approve --body "FRG-26 test approval by the owner" \
    || die "the owner could not approve PR #$1"
  nap 3
}

# A test PR left open could still merge (B11 arms auto-merge), so a PR not confirmed closed or
# merged afterwards is a failure: the phase stops, and the owner is told which PR to close.
# A close with no answer in time is settled only by that read-back (round 77): the state read is
# reported; a PR not read closed or merged is named outcome unknown too. owner_gh bounds the close
# itself, by the clean-up's cap too (call_secs): a second limit around it ended first and left the
# close noted as cut short by a stop that never came.
close_if_open() { # <pr> — tidy up after a refused attempt
  local st late="" what
  what="$(owner_what pr close "$1" --repo "$REPO")"
  into st pr_view "$1" state .state || st=""
  if [[ "$st" == OPEN ]] && in_time; then
    # Through capture: its answer stored; it stays outcome unknown until the read-back below settles
    # it (round 110, owner's rule (b)).
    capture owner_gh pr close "$1" --repo "$REPO" || { [[ $LAST_RC -ne 124 ]] || late="$IR_SECS"; }
    into st pr_view "$1" state .state || st=""
  fi
  if [[ "$st" == CLOSED || "$st" == MERGED ]]; then
    write_resolved "$what"
    [[ -z "$late" ]] || say "CLEANUP PR #$1 in $REPO: its close got no answer within ${late}s; read back: $st"
    return 0
  fi
  if [[ -n "$late" ]]; then
    write_resolved "$what"
    unsettled_write "no answer within ${late}s; read back: ${st:-unreadable}" owner_gh pr close "$1" --repo "$REPO"
  fi
  FAILS=$((FAILS + 1))
  undone "closing the open test PRs"; say "CLEANUP FAIL PR #$1 may still be open (state ${st:-unreadable}): close it on GitHub, in $REPO, before another phase"
  return 1
}

# When a phase stops or ends, every test PR still open in the throwaway repository is closed,
# found by its "FRG-26 " title rather than by number: a test can stop before it knows its PR's
# number (dev_ahead, or a PR URL that couldn't be read). Any PR it can't confirm closed, or a
# list it can't read, is a failure.
sweep_prs() {
  local open pr rc=0 TIDY_UP=1
  # Every page, so no test PR is missed however many PRs are open (review round 9). Each call is
  # bounded, and the clean-up's cap checked before each PR (round 72, SEC-1).
  into open with_timeout "$(call_secs)" owner_gh api --paginate "repos/$REPO/pulls?state=open&per_page=100" \
    --jq '.[] | select(.title | startswith("FRG-26 ")) | .number' 2>/dev/null || rc=$?
  if [[ $rc -ne 0 ]]; then
    FAILS=$((FAILS + 1))
    undone "closing the open test PRs"; say "CLEANUP FAIL could not list the open PRs in $REPO$(no_answer $rc): close any \"FRG-26 \" test PR on GitHub before another phase"
    return 1
  fi
  for pr in $open; do
    if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
      FAILS=$((FAILS + 1))
      undone "closing the open test PRs"; say "CLEANUP FAIL unexpected PR list entry; close any \"FRG-26 \" test PR in $REPO on GitHub before another phase"
      return 1
    fi
    if ! in_time; then
      FAILS=$((FAILS + 1))
      undone "closing the open test PRs"; say "CLEANUP FAIL the clean-up's time cap (${CLEANUP_SECS}s) was reached before PR #$pr was closed: close it, and any other \"FRG-26 \" test PR in $REPO, on GitHub before another phase"
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
  nap 3
  app_merge B7 "$pr" --squash
  record B7 "$OBS" "$(evidence)"
  close_if_open "$pr"
}

t_B8() {
  feature_pr B8
  local pr="$LAST_PR"
  owner_approve "$pr"
  local old_head dev_sha
  into old_head pr_view "$pr" headRefOid .headRefOid || old_head=""
  dev_ahead B8-advance
  [[ "$OBS" == allowed ]] || { setup_fail B8 "could not advance dev ($(evidence))"; close_if_open "$pr"; return; }
  into dev_sha owner_gh api "repos/$REPO/branches/dev" --jq .commit.sha 2>/dev/null || dev_sha=""
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
    into head pr_view "$1" headRefOid .headRefOid || head=""
    if [[ "$head" =~ ^[0-9a-f]{40}$ && "$head" != "$2" ]]; then
      into parents owner_gh api "repos/$REPO/commits/$head" --jq '[.parents[].sha] | join(" ")' 2>/dev/null || parents=""
      [[ " $parents " == *" $3 "* ]] && return 0
    fi
    nap 3
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
  nap 3
  local base
  into base pr_view "$pr" baseRefName .baseRefName || base=""
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
  nap 30
  into st pr_view "$pr" state .state || st=unknown
  into armed pr_view "$pr" autoMergeRequest '.autoMergeRequest != null' || armed=unknown
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
    into st pr_view "$pr" state .state || st=unknown
    [[ "$st" == MERGED ]] && break
    nap 5
  done
  if [[ "$st" == MERGED ]]; then
    record B11 refused "$first [held until the owner approved, then merged by itself]"
  else
    setup_fail B11 "held, but did not merge after the owner approved [state $st]"
    close_if_open "$pr"
  fi
}

admin_attempts() { # <id> <method path [input]>... separated by ";;" — refused only if every one is
  # The first attempt that isn't refused ends the test: none after it is made (the stop rule). Round
  # 112: each judged by GitHub's whole answer, then the test's state read back against its baseline.
  local id="$1" obs=refused ev="" c
  shift
  attempt_baseline "$id"
  while [[ $# -gt 0 && "$obs" == refused ]]; do
    c=()
    while [[ $# -gt 0 && "$1" != ";;" ]]; do c+=("$1"); shift; done
    [[ $# -gt 0 ]] && shift
    app_attempt "${c[@]}"
    obs="$OBS"
    ev="$ev ${c[0]} ${c[1]}: $LAST_OUT |"
  done
  OBS="$obs" EV="$ev"
  attempts_settle "$id"
  record "$id" "$OBS" "$EV"
}

t_B12() {
  printf '{"required_status_checks":null,"enforce_admins":false,"required_pull_request_reviews":null,"restrictions":null}\n' >"$WORK/weak.json"
  admin_attempts B12 -X PUT "repos/$REPO/branches/dev/protection" --input "$WORK/weak.json" ";;" \
    -X DELETE "repos/$REPO/branches/dev/protection"
}

t_B13() {
  # The same payloads the owner's own ruleset step uses (one of them is proven valid there).
  local uid
  into uid owner_uid || { setup_fail B13 "could not read the owner's user id"; return; }
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
  into id owner_gh api "repos/$REPO/rulesets" --jq '.[0].id' 2>/dev/null || id=""
  [[ "$id" =~ ^[0-9]+$ ]] || { setup_fail M4 "could not read the ruleset's id"; return; }
  # Changing the ruleset. Both payloads are built from GitHub's own copy of the installed ruleset
  # (so they are valid requests): one switches it off; the other adds the app to the bypass list as
  # an Integration actor (GitHub Apps may be bypass actors: Confirmed, docs), whichever form the
  # owner's bypass took.
  local rs
  into rs owner_gh api "repos/$REPO/rulesets/$id" 2>/dev/null || { setup_fail M4 "could not read the ruleset"; return; }
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
  nap 3
  into facts merge_facts "$pr"
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

# After capture of an app git push (kind P). Round 112 (owner 2026-11-25): git's words can't tell a
# rejection the remote completed from a transport failure, so a push that fails is inconclusive, its
# write outcome unknown, until a way to tell them apart is approved (proposed: round112-plan.md).
classify_push_perm() {
  if [[ $LAST_RC -eq 0 ]]; then echo allowed; else echo inconclusive; fi
}

http_of() { # the HTTP status gh reported in LAST_OUT, or "allowed" after a success
  if [[ $LAST_RC -eq 0 ]]; then echo allowed; return; fi
  printf '%s' "$LAST_OUT" | grep -Eo 'HTTP [0-9]{3}' | tail -n 1 || echo "failed: $(evidence)"
}

# Attempts, in order; the first one not refused ends the list (the stop rule). Sets OBS and EV. Round
# 112: an api attempt (app_gh api …) is judged by GitHub's whole answer (app_attempt), then the test's
# state read back against its baseline (attempts_settle).
p_attempts() { # <kind api|push> <test id> <args…> separated by ";;"
  local kind="$1" id="$2" c
  shift 2
  OBS=refused EV=""
  [[ "$kind" != api ]] || attempt_baseline "$id"
  while [[ $# -gt 0 && "$OBS" == refused ]]; do
    c=()
    while [[ $# -gt 0 && "$1" != ";;" ]]; do c+=("$1"); shift; done
    [[ $# -gt 0 ]] && shift
    if [[ "$kind" == push ]]; then
      capture "${c[@]}" || true
      OBS="$(classify_push_perm)"
      EV="$EV ${c[*]:0:4}: $(evidence) |"
    else
      [[ "${c[0]} ${c[1]}" == "app_gh api" ]] || die "p_attempts api: not an app gh api attempt: ${c[*]:0:2}"
      app_attempt "${c[@]:2}"
      EV="$EV ${c[*]:0:4}: $LAST_OUT |"
    fi
  done
  [[ "$kind" != api ]] || attempts_settle "$id"
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
  into n owner_gh api "repos/$REPO/actions/secrets" --jq .total_count 2>/dev/null || n=error
  into d owner_gh api "repos/$REPO/actions/permissions/workflow" --jq .default_workflow_permissions 2>/dev/null || d=error
  into a owner_gh api "repos/$REPO/actions/permissions/workflow" --jq .can_approve_pull_request_reviews 2>/dev/null || a=error
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
  into rid owner_gh api "repos/$REPO" --jq .id 2>/dev/null || rid=""
  [[ "$rid" =~ ^[0-9]+$ ]] || { setup_fail_p A6 "could not read the repository id"; return; }
  p_attempts api A6 app_gh api -X PATCH "repos/$REPO" -f description="$MARKER" ";;" \
    app_gh api -X PUT "user/installations/$INSTALLATION_ID/repositories/$rid"
  # Owner 2026-11-25 (round 112): inconclusive whatever GitHub answers: both writes are no-ops (the
  # description it has, the repository the installation has), which no read can show unchanged. Their
  # outcome stays unknown.
  if [[ "$OBS" == refused ]]; then OBS=inconclusive EV="$EV A6 stays inconclusive: its no-op writes can't be read back |"; fi
  [[ "$OBS" == refused ]] || { record_p A6 "$OBS" "not run" "$EV"; return; }
  p_controls owner_gh api -X PATCH "repos/$REPO" -f description="$MARKER"
  record_p A6 "$OBS" "$CTL" "$EV (the installation attempt has no control: only the owner's browser changes it)"
}

# A8: secrets, variables, deploy keys, webhooks and pending collaborator invitations (settings
# only an admin may read). Control: the owner reads the same lists (nothing is created or written).
# Round 13 (SEC-5): no collaborator write; see the evidence line.
t_A8() {
  p_attempts api A8 app_gh api "repos/$REPO/actions/secrets" ";;" \
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
  # HTTP 401 itself, never the words alone (round 58, C2's class).
  if [[ $LAST_RC -ne 0 ]] && printf '%s' "$LAST_OUT" | grep -q 'HTTP 401'; then OBS=refused
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
  p_attempts push A3 app_git -C "$CLONE" push origin "HEAD:refs/heads/frg26/permissions/A3-wf-$(stamp)"
  [[ "$OBS" == refused ]] || { record_p A3 "$OBS" "not run" "$EV"; return; }
  fresh_from dev "a3-plain-$(stamp)"
  add_commit "tests/permissions-A3-$(stamp).txt" "FRG-26 A3 control"
  p_controls app_git -C "$CLONE" push origin "HEAD:refs/heads/frg26/permissions/A3-plain-$(stamp)"
  record_p A3 "$OBS" "$CTL" "$EV"
}

# A2 (plan 4.1, item 9, claim 9a): code changes on a public repository the app is not installed
# on: a push, and a file and a branch through the API, each refused, with that repository's
# branches and tags unchanged. Control: the same three on the throwaway. Opening an issue there is
# not tried (owner, 2026-11-15): the A2 investigation showed it is allowed whatever the token
# carries, and item 9 stays failed for it (plan sections 6 and 13).
t_A2() {
  local main2 dev before after content b
  into main2 owner_gh api "repos/$REPO2/branches/main" --jq .commit.sha 2>/dev/null || main2=""
  [[ "$main2" =~ ^[0-9a-f]{40}$ ]] || { setup_fail_p A2 "could not read $REPO2's main"; return; }
  into dev owner_gh api "repos/$REPO/branches/dev" --jq .commit.sha 2>/dev/null || dev=""
  [[ "$dev" =~ ^[0-9a-f]{40}$ ]] || { setup_fail_p A2 "could not read $REPO's dev"; return; }
  # The file goes on the owner's branch there: with that branch missing, a 404 would prove nothing.
  # Only the exact branch counts, never a look-alike branch or tag (round 70, C1, SEC-1). Round 117
  # (owner): read as the baseline reads them (state_refs2, the bounded lists), not probe_refs.
  into before state_refs2 2>/dev/null || before=""
  if [[ -z "$before" ]] || ! jq -e --arg r "refs/heads/$A2_BRANCH" '.heads | any(.ref == $r)' >/dev/null 2>&1 <<<"$before"; then
    setup_fail_p A2 "could not read $REPO2's branches and tags, or $A2_BRANCH is missing"
    return
  fi
  fresh_from dev "a2-$(stamp)"
  add_commit "tests/permissions-A2-$(stamp).txt" "FRG-26 A2"
  # The push is judged by git's own words, the two API calls by GitHub's status.
  p_attempts push A2 app_git -C "$CLONE" push "https://github.com/$REPO2.git" "HEAD:refs/heads/frg26-a2-$(stamp)"
  [[ "$OBS" == refused ]] || { record_p A2 "$OBS" "not run" "$EV"; return; }
  local ev="$EV"
  content="$(printf 'FRG-26 A2\n' | base64 | tr -d '\n')"
  p_attempts api A2 app_gh api -X PUT "repos/$REPO2/contents/frg26-a2-$(stamp).txt" -f message="FRG-26 A2 ($(stamp))" \
    -f content="$content" -f branch="$A2_BRANCH" ";;" \
    app_gh api -X POST "repos/$REPO2/git/refs" -f ref="refs/heads/frg26-a2-api-$(stamp)" -f sha="$main2"
  EV="$ev$EV"
  [[ "$OBS" == refused ]] || { record_p A2 "$OBS" "not run" "$EV"; return; }
  into after state_refs2 2>/dev/null || after=""
  if [[ -z "$after" || "$after" != "$before" ]]; then
    record_p A2 allowed "not run" "$EV $REPO2's branches or tags changed (or could not be read again)"
    return
  fi
  b="frg26/permissions/A2-$(stamp)"
  p_controls app_git -C "$CLONE" push origin "HEAD:refs/heads/$b" ";;" \
    app_gh api -X PUT "repos/$REPO/contents/tests/permissions-A2-api-$(stamp).txt" -f message="FRG-26 A2 control ($(stamp))" \
    -f content="$content" -f branch="$b" ";;" \
    app_gh api -X POST "repos/$REPO/git/refs" -f ref="refs/heads/frg26/permissions/A2-api-$(stamp)" -f sha="$dev"
  record_p A2 "$OBS" "$CTL" "$EV (opening an issue there is not tried: allowed whatever the token carries, A2 investigation 2026-11-14; item 9 stays failed)"
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
  # Pending from before it is sent until its answer is settled (review-lens round 92, C2 = SEC-1): a
  # stop meanwhile leaves it a write with outcome unknown (unknown_writes). As request_what names it.
  PENDING_CREATE="app gh issue create --repo $REPO"
  # Each write's expected answer (round 110): the new issue's address, the new comment's.
  WRITE_EXPECT="text:^https://github.com/$REPO/issues/[0-9]+\$"
  try_reading A12 "gh issue create" app_gh issue create --repo "$REPO" --title "FRG-26 A12 ($(stamp))" --body "FRG-26 throwaway test A12."
  n="${LAST_OUT##*/}"
  # Round 111 (review-lens round 99, C1): taken as the run's issue only if its answer was the new
  # issue's address here; any other answer, even one ending in a number, leaves nothing to act on.
  local unsettled="$WRITE_UNSETTLED"
  if [[ $LAST_RC -eq 0 && -z "$unsettled" && "$n" =~ ^[0-9]+$ ]]; then
    # Closed by this number, not only if a list finds it (round 102: part 0's #129). The number is
    # kept before the pending record is cleared, in one command, so no stop comes between them.
    RUN_ISSUES="$RUN_ISSUES $n" PENDING_CREATE=""
    WRITE_EXPECT="text:^https://github.com/$REPO/issues/$n#issuecomment-[0-9]+\$"
    try_reading A12 "gh issue comment" app_gh issue comment "$n" --repo "$REPO" --body "FRG-26 A12 comment."
    try_reading A12 "gh issue view" app_gh issue view "$n" --repo "$REPO" --json title --jq .title
  elif [[ $LAST_RC -eq 0 ]]; then
    # Answered as made, with no number to close it by (or none shown to be this one's): its outcome
    # is unknown. The pending record is cleared only once this one is written (review-lens round 93,
    # C1), else it stays, named.
    local why="answered without an issue number"
    [[ ! "$n" =~ ^[0-9]+$ ]] || why="answered, not with a new issue's address in $REPO"
    unsettled_write "$why" app_gh issue create --repo "$REPO" && PENDING_CREATE=""
  else
    # Failed, with no number: its outcome is unknown, whatever the answer says (no refusal is taken
    # from its text: rounds 92, C1 = SEC-3, and 93, C2 = SEC-1). Cleared as above.
    unsettled_write "failed, with no issue number: it may have been made" app_gh issue create --repo "$REPO" && PENDING_CREATE=""
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

issue_state() { # <n> — open or closed, as a read of that issue by its number finds it
  with_timeout "$(call_secs)" owner_gh api "repos/$REPO/issues/$1" --jq .state 2>/dev/null
}

# A test issue is closed at most once, then read back by its number; only one read back closed
# counts as closed (round 102: part 0's #129 stayed open after CLEANUP DONE, and no close of it
# was on GitHub's record). Bounded by owner_gh alone, as in close_if_open (round 77). A close with
# no answer in time is settled by that read-back alone, never sent again; read back otherwise, it
# is named outcome unknown. A close is marked started (ISSUES_CLOSE_SENT) before it is sent, so a
# sweep resumed after a stop never sends it again, only reads the issue back (round 92, SEC-2).
close_issue() { # <n>
  local st late="" again="" what
  what="$(owner_what issue close "$1" --repo "$REPO")"
  if [[ " $ISSUES_CLOSE_SENT " == *" $1 "* ]]; then
    again=1
  else
    ISSUES_CLOSE_SENT="$ISSUES_CLOSE_SENT $1"
    # Through capture; outcome unknown until the read-back by number settles it (round 110, rule (b)).
    capture owner_gh issue close "$1" --repo "$REPO" || { [[ $LAST_RC -ne 124 ]] || late="$IR_SECS"; }
  fi
  into st issue_state "$1" || st=""
  if [[ "$st" == closed ]]; then
    write_resolved "$what"
    [[ " $ISSUES_CLOSED " == *" #$1 "* ]] || ISSUES_CLOSED="$ISSUES_CLOSED #$1"
    if [[ -n "$late" ]]; then
      say "CLEANUP issue #$1 in $REPO: its close got no answer within ${late}s; read back: closed"
    elif [[ -n "$again" ]]; then
      say "CLEANUP issue #$1 in $REPO: its close was started earlier in this run (not sent again); read back: closed"
    else
      say "CLEANUP closed test issue #$1 in $REPO; read back: closed"
    fi
    return 0
  fi
  FAILS=$((FAILS + 1))
  undone "closing the test issues"
  if [[ -n "$late" ]]; then
    write_resolved "$what"
    unsettled_write "no answer within ${late}s; read back: ${st:-unreadable}" owner_gh issue close "$1" --repo "$REPO"
    say "CLEANUP FAIL issue #$1 in $REPO: its close got no answer within ${late}s, so its outcome is unknown (not tried again; read back: ${st:-unreadable}): check it on GitHub"
  elif [[ -n "$again" ]]; then
    say "CLEANUP FAIL issue #$1 in $REPO may still be open (its close was started earlier in this run, not sent again; read back: ${st:-unreadable}): close it on GitHub"
  else
    say "CLEANUP FAIL issue #$1 in $REPO may still be open (read back: ${st:-unreadable}): close it on GitHub"
  fi
  return 1
}

# The jq selecting this run's own test items from a list of issues: a title "FRG-26 …" that ends with
# this run's id in its own parentheses, as every title this run makes does (stamp), so another run's
# id that starts with or contains this one's is not taken (review-lens round 92, C3 = SEC-4).
run_title_jq() { printf 'select(.title | startswith("FRG-26 ")) | select(.title | endswith(" (%s)"))' "$RUN_ID"; }
run_issues_jq() { printf '.[] | select(.pull_request == null) | %s | .number' "$(run_title_jq)"; } # issues only
run_items_jq() { printf '.[] | %s | .number' "$(run_title_jq)"; } # issues and PRs

# This run's test issues are closed in the throwaway: each one a create returned (RUN_ISSUES), each
# one whose close was already started (ISSUES_CLOSE_SENT: only read back), and any of this run's a
# list finds (run_issues_jq; a list read just after a create can miss it: round 102), each once. The second throwaway is only read (round 13, SEC-4): an "FRG-26 " issue or PR of
# this run's there means this run wrote there, and is reported for the owner to close; this script
# never writes there as the owner. ISSUES_SWEPT is set once the sweep has ended, however it ended;
# a stop before that has the clean-up resume it (cleanup_tokens_first).
sweep_issues() {
  local open n todo="" rc=0 TIDY_UP=1
  ISSUES_SWEEP_BEGUN=1
  # Each call bounded, the clean-up's cap checked before each step (round 72, SEC-1).
  into open with_timeout "$(call_secs)" owner_gh api --paginate "repos/$REPO/issues?state=open&per_page=100" --jq "$(run_issues_jq)" 2>/dev/null || rc=$?
  if [[ $rc -ne 0 ]]; then
    open=""
    FAILS=$((FAILS + 1))
    undone "closing the test issues"; say "CLEANUP FAIL could not list the open issues in $REPO$(no_answer $rc): close any \"FRG-26 \" test issue on GitHub"
  fi
  # Every close already started too (review-lens round 93, C3 = SEC-2): a list read after a stop may
  # no longer show an issue whose close was sent, so it is read back by its number (not sent again).
  for n in $RUN_ISSUES $ISSUES_CLOSE_SENT $open; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    [[ " $todo " == *" $n "* ]] || todo="$todo $n"
  done
  for n in $todo; do
    if ! in_time; then
      FAILS=$((FAILS + 1))
      undone "closing the test issues"; say "CLEANUP FAIL the clean-up's time cap (${CLEANUP_SECS}s) was reached before issue #$n was closed and read back: close it, and any other \"FRG-26 \" test issue in $REPO, on GitHub"
      break
    fi
    close_issue "$n" || true
  done
  if ! in_time; then
    FAILS=$((FAILS + 1))
    undone "checking $REPO2 for this run's issues"; say "CLEANUP FAIL the clean-up's time cap (${CLEANUP_SECS}s) was reached before $REPO2 was checked: check it on GitHub for \"FRG-26 \" issues"
    ISSUES_SWEPT=1
    return 0
  fi
  # Only this run's: issues #1-#3 there are the A2 evidence, kept open (owner, 2026-11-11).
  rc=0
  into open with_timeout "$(call_secs)" owner_gh api --paginate "repos/$REPO2/issues?state=open&per_page=100" \
    --jq "$(run_items_jq)" 2>/dev/null || rc=$?
  if [[ $rc -ne 0 ]]; then
    FAILS=$((FAILS + 1))
    undone "checking $REPO2 for this run's issues"; say "CLEANUP FAIL could not list the open issues in $REPO2$(no_answer $rc): check it on GitHub for \"FRG-26 \" issues"
  elif [[ -n "$open" ]]; then
    FAILS=$((FAILS + 1))
    undone "closing this run's issues or PRs on $REPO2"; say "CLEANUP FAIL $REPO2 has open \"FRG-26 \" issues or PRs (#$(printf '%s' "$open" | tr '\n' ' ')): the app wrote there; close them on GitHub"
  fi
  ISSUES_SWEPT=1
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
# A token request with no complete answer (a timeout, a broken transfer, a 5xx) stops the run and is
# reported as a token possibly issued and never received, with the most it could carry and when its
# request was sent; its expiry is unknown (an hour from an issue time this run can't know: owner,
# 2026-11-23); it can't be revoked from here, and the run never asks again (round 56: a limit the
# owner accepted for this throwaway investigation only, not for the broker).
# Each revocation and each read is given at most CALL_SECS, and never more than is left of the
# clean-up's CLEANUP_SECS; the deadline is checked before each step; a step the time cap leaves out
# is named as not done. A timeout stops the request's whole process tree (gh included). Every request
# the run makes is bounded the same way (round 55), so a stop signal, which bash acts on only when
# the request in progress returns, reaches the clean-up within CALL_SECS. Limits: a force-kill, a power loss, or a
# revocation that fails or times out leaves a token unconfirmed, and a token request with no
# complete answer may leave a token this run never received. One left unconfirmed may stay valid
# until its expires_at, printed when it was issued; one never received, until an expiry this run
# can't know (an hour from its issue). What it can do is what its TOKEN lines show for the first
# throwaway, plus what this run's readings show on a public repository it isn't installed on (A2).
# Accepted by the owner for this investigation only (2026-11-13): a Ctrl-C or a closed window at an
# unlucky moment may leave the report incomplete or a revocation unconfirmed; such a token stays
# within the scope above, for as long as said above. A clean-up is never reported successful without a 401 for each
# token. Not extended to the other stage 1 commands or the broker without separate approval.

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

probe_stop() { # <why> — stop: the exit clean-up settles the tokens, compares the second throwaway's
  # branches and tags, and reads back what was made, in that order (round 55, SEC-1)
  PROBE_FAILS=$((PROBE_FAILS + 1))
  say "PROBE STOP: $1"
  PROBE_END="STOPPED: $1"
  exit 1
}

probe_label_of() { # <token> — its name in this run, never the token
  local e
  for e in $ISSUED; do
    if [[ "${e#*=}" == "$1" ]]; then printf '%s' "${e%%=*}"; return; fi
  done
  printf 'unnamed'
}

# Is the token now refused? A read with it, within [seconds] (call_secs by default); 0 only for HTTP
# 401 itself, never for words alone (round 58, C2). With no time left the read isn't sent, and
# LAST_OUT says so (round 83).
token_refused() { # <token> [seconds]
  local secs="${2:-$(call_secs)}"
  if [[ $secs -le 0 ]]; then
    LAST_OUT="not sent: the clean-up's time cap was reached" LAST_RC=124
    return 1
  fi
  TOKEN="$1"
  capture with_timeout "$secs" app_gh api "repos/$REPO" --jq .full_name || true
  TOKEN=""
  [[ $LAST_RC -ne 0 ]] && printf '%s' "$LAST_OUT" | grep -q 'HTTP 401'
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
    if ! call_budget; then
      say "TOKEN $label not checked: the clean-up's time cap (${CLEANUP_SECS}s) was reached"
      continue
    fi
    TOKEN="$t"
    revoke_token "$CALL_BUDGET" || true
    if ! call_budget; then
      say "TOKEN $label revocation tried, not checked: the clean-up's time cap (${CLEANUP_SECS}s) was reached"
      [[ " $OUTSTANDING " == *" $t "* ]] || OUTSTANDING="$OUTSTANDING $t"
      continue
    fi
    if token_refused "$t" "$CALL_BUDGET"; then
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
  got="$(with_timeout "$(call_secs)" app_gh api installation/repositories --paginate --jq '.repositories[].full_name' 2>&1)" || got="unreadable: $got"
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
  if token_refused "$t"; then
    PROBE_REVOKED=$((PROBE_REVOKED + 1))
    PROBE_CONFIRMED="$PROBE_CONFIRMED $t"
    say "TOKEN $1 revoked: a read with it now gets HTTP 401"
  else
    PROBE_FAILS=$((PROBE_FAILS + 1))
    OUTSTANDING="$OUTSTANDING $t"
    say "TOKEN $1 revoked, but a read with it did not get HTTP 401 ($(evidence)): the exit clean-up tries again"
  fi
}

# Every token GitHub may have issued that this run never received (round 56, SEC-1), a request still
# pending included (round 57, C1), reported whole: the requested repositories and permissions and
# when the request was sent; its expiry is unknown (owner, 2026-11-24). Shared by every command
# (round 61, C1). Sets UNRECEIVED_LABELS; each request is reported once.
UNRECEIVED_LABELS=""
report_unreceived() {
  local line label at req repos perms
  if [[ -n "$PENDING_MINT" ]]; then
    UNRECEIVED="$UNRECEIVED$PENDING_MINT
"
    PENDING_MINT=""
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    label="${line%% *}" line="${line#* }"
    at="${line%% *}" req="${line#* }"
    UNRECEIVED_LABELS="$UNRECEIVED_LABELS $label"
    # At most what was asked; a request that names none asks for the installation's.
    repos="$(jq -r 'if .repositories then (.repositories | join(", ")) else empty end' <<<"$req" 2>/dev/null)" || repos=""
    perms="$(jq -S -c '.permissions // empty' <<<"$req" 2>/dev/null)" || perms=""
    # (Defaults set apart: bash 3.2 misreads an apostrophe inside a quoted ${x:-...}.)
    [[ -n "$repos" ]] || repos="every repository the installation is on"
    [[ -n "$perms" ]] || perms="the installation's $WANT_PERMS"
    # A control's passes on neither its request nor when it was sent (round 110): said so.
    local sent="the request was sent at $at by this Mac's clock"
    [[ "$at" != unknown ]] || sent="its control doesn't pass on when the request was sent"
    say "TOKEN $label possibly issued, never received: its request got no complete answer, so this run can't revoke or check it. If GitHub issued it, it carries at most: repositories $repos; permissions $perms; its expiry is unknown: GitHub gives such a token one hour from when it issues it, and this run doesn't know whether or when that was ($sent). This run does not ask for it again"
  done <<<"$UNRECEIVED"
  UNRECEIVED=""
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
  # After a stop, the second throwaway's branches and tags against the run's start (the normal end
  # compared them already).
  if [[ "$PROBE_END" != "done" && -n "$REFS_BEFORE" ]]; then
    if in_time; then
      probe_refs_same || true
    else
      PROBE_FAILS=$((PROBE_FAILS + 1))
      say "REFS $REPO2 not compared: the clean-up's time cap (${CLEANUP_SECS}s) was reached"
    fi
  fi
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
  report_unreceived
  local unrec="$UNRECEIVED_LABELS"
  say "TOKENS $MINTED issued; confirmed revoked:${yes:- none}; NOT confirmed:${no:- none}"
  local tokens="$PROBE_REVOKED of $MINTED tokens revoked (confirmed)${no:+, NOT confirmed:$no}${unrec:+; possibly issued, never received:$unrec}"
  case "$PROBE_END" in
    done)
      if [[ $PROBE_FAILS -eq 0 && -z "$no" && -z "$unrec" ]]; then
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
# names the permission GitHub wanted). Sets OBS. <kind> <jq path> name the object an allowed attempt
# makes (- - for none). Catchable signals are held from before the request until its answer is shown
# and the object recorded (round 60, SEC-1), so a signal as it succeeds loses neither.
probe_attempt() { # <label> <kind|-> <jq path|-> <gh api args…>
  local label="$1" kind="$2" path="$3"
  shift 3
  local status out rc=0 w=""
  defer_signals
  # Round 112: judged as every attempt of the app's is (api_verdict on GitHub's whole answer), never by
  # its words; gh's own error line is discarded.
  into out probe_run "$@" || rc=$?
  LAST_OUT="$(redact "$out")" LAST_RC=$rc
  http_answer "$out" "$rc"
  if request_writes app api "$@"; then w=1; fi
  api_verdict "$(accepted_permission "$@")" "$w"
  if [[ $LAST_RC -eq 0 ]]; then status="$(printf '%s\n' "$LAST_OUT" | head -n 1 | tr -d '\r')"; else status="HTTP $HA_STATUS"; fi
  say "ATTEMPT $label (token $PROBE_LABEL): $OBS ($status); GitHub's answer:"
  printf '%s\n' "$LAST_OUT" | tr -d '\r' | sed 's/^/    /'
  OBS_KEPT=""
  if [[ "$kind" != - ]]; then probe_keep "$kind" "$path"; fi
  resume_signals
}

probe_run() { with_timeout "$(call_secs)" app_gh api -i "$@" -H "Accept-Encoding: identity" 2>/dev/null; } # <gh api args…>

# After gh's exit 0, note the object by the number GitHub returned: an allowed attempt's, or (round 116)
# one whose answer wasn't shown whole, so the clean-up still finds what it may have made.
probe_keep() { # <kind> <jq path>
  [[ $LAST_RC -eq 0 ]] || return 0
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
  if [[ "$OBS" == allowed ]]; then how="allowed$OBS_KEPT"
  elif [[ "$OBS" == refused ]]; then how="refused (HTTP $HA_STATUS)"
  else how="$OBS (HTTP $HA_STATUS: $AV_WHY)"
  fi
  PROBE_READINGS="$PROBE_READINGS $1=$OBS"
  say "READING $1 $2: $how"
  # Neither allowed nor refused for a permission reason (an error, a rate limit): no reading, and
  # what GitHub did is unknown, so nothing more is tried (round 49, C1).
  if [[ "$OBS" != allowed && "$OBS" != refused ]]; then
    probe_stop "$1 got no clear answer from GitHub (HTTP $HA_STATUS: $AV_WHY): no reading; look on $REPO2 for anything it may have made"
  fi
}

probe_refs() { # the second throwaway's branches and tags with their commits, as the owner reads them
  local h t
  # A read with no answer within its limit, outside a2-probe, ends into's job with 124 (round 109), so
  # the run still stops for it.
  h="$(with_timeout "$(call_secs)" owner_gh api --paginate "repos/$REPO2/git/matching-refs/heads" --jq '.[] | "\(.ref) \(.object.sha)"' 2>/dev/null)" || { probe_refs_timeout $?; echo error; return; }
  t="$(with_timeout "$(call_secs)" owner_gh api --paginate "repos/$REPO2/git/matching-refs/tags" --jq '.[] | "\(.ref) \(.object.sha)"' 2>/dev/null)" || { probe_refs_timeout $?; echo error; return; }
  printf '%s\n%s\n' "$h" "$t"
}

probe_refs_timeout() { # <status> — in into's job, outside a2-probe, a timeout (124) ends the job
  [[ "$1" -eq 124 && -n "$IN_JOB" && -z "$PROBE_ACTIVE" ]] || return 0
  exit 124
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
  main2="$(with_timeout "$(call_secs)" owner_gh api "repos/$REPO2/branches/main" --jq .commit.sha 2>/dev/null)" || main2=""
  [[ "$main2" =~ ^[0-9a-f]{40}$ ]] || probe_stop "can't read $REPO2's main"
  dev="$(with_timeout "$(call_secs)" owner_gh api "repos/$REPO/branches/dev" --jq .commit.sha 2>/dev/null)" || dev=""
  [[ "$dev" =~ ^[0-9a-f]{40}$ ]] || probe_stop "can't read $REPO's dev"
  content="$(printf 'FRG-26 A2 probe P5\n' | base64 | tr -d '\n')"
  probe_attempt "P5 file" - - -X PUT "repos/$REPO2/contents/frg26-probe-$(stamp).txt" -f message="FRG-26 A2 probe P5 ($(stamp))" \
    -f content="$content" -f branch="$A2_BRANCH"
  probe_code_judge "P5 file"
  probe_attempt "P5 branch" - - -X POST "repos/$REPO2/git/refs" -f ref="refs/heads/frg26-probe-$(stamp)" -f sha="$main2"
  probe_code_judge "P5 branch"
  b="frg26/probe/P5-$(stamp)"
  # A stop held during the branch request acts once the branch is reported, before the file request
  # starts: a stop starts no new test action (round 68, C1, SEC-1).
  defer_signals
  capture with_timeout "$(call_secs)" app_gh api -X POST "repos/$REPO/git/refs" -f ref="refs/heads/$b" -f sha="$dev" \
    || probe_stop "control: the app could not create the branch $b on $REPO ($(evidence)), so the refusals prove nothing"
  say "CONTROL P5 branch: the app created the branch $b on $REPO"
  resume_signals
  defer_signals
  capture with_timeout "$(call_secs)" app_gh api -X PUT "repos/$REPO/contents/tests/frg26-probe-$(stamp).txt" -f message="FRG-26 A2 probe P5 control ($(stamp))" \
    -f content="$content" -f branch="$b" \
    || probe_stop "control: the app could not add a file to $b on $REPO ($(evidence)), so the refusals prove nothing"
  say "CONTROL P5: the app created the branch $b and a file on it, on $REPO"
  resume_signals
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
  probe_attempt "$1" issue .number -X POST "repos/$REPO2/issues" -f title="FRG-26 A2 probe $1 ($(stamp))" \
    -f body="FRG-26 throwaway: an issue by the app, investigating test A2. Kept as evidence; safe to delete with the repository."
  probe_reading "$1" "an issue, with a token $2"
}

# P3, P4 (claim 9b), with the full token: a comment on A2's issue #1, and a PR. Readings.
probe_public() {
  local ahead
  probe_attempt P3 comment .id -X POST "repos/$REPO2/issues/1/comments" \
    -f body="FRG-26 throwaway: a comment by the app, investigating test A2 ($(stamp)). Kept as evidence."
  probe_reading P3 "a comment on issue #1"
  OBS_KEPT=""
  ahead="$(with_timeout "$(call_secs)" owner_gh api "repos/$REPO2/compare/main...$A2_BRANCH" --jq .ahead_by 2>/dev/null)" || ahead=""
  if [[ ! "$ahead" =~ ^[1-9][0-9]*$ ]]; then
    PROBE_FAILS=$((PROBE_FAILS + 1))
    OBS=not-tried
    say "READING P4 not tried: $REPO2's $A2_BRANCH is not ahead of main (ahead by '${ahead:-unreadable}')"
    PROBE_READINGS="$PROBE_READINGS P4=not-tried"
    return 0
  fi
  probe_attempt P4 pr .number -X POST "repos/$REPO2/pulls" -f title="FRG-26 A2 probe P4 ($(stamp))" -f head="$A2_BRANCH" -f base=main \
    -f body="FRG-26 throwaway: a PR by the app, investigating test A2. Kept as evidence; never merge."
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
  # P5's file goes on the owner's branch: with that branch missing, a 404 would prove nothing. Only
  # a whole line of the branch list counts, never a look-alike branch or tag (round 71, SEC-1):
  # branch lines are the only ones starting refs/heads/.
  REFS_BEFORE="$(probe_refs)"
  if [[ "$REFS_BEFORE" == error ]] || ! printf '%s\n' "$REFS_BEFORE" | grep -Eqx "refs/heads/$A2_BRANCH [0-9a-f]{40}"; then
    REFS_BEFORE=""
    probe_stop "can't read $REPO2's branches and tags, or $A2_BRANCH is missing"
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
  into e owner_gh api "repos/$REPO/environments/$ENV_NAME" --jq '[([.protection_rules[] | select(.type == "required_reviewers") | .prevent_self_review | tostring] | join(",")), ([.protection_rules[] | select(.type == "required_reviewers") | .reviewers[] | "\(.type):\(.reviewer.login)"] | join(",")), (.deployment_branch_policy.protected_branches | tostring), (.deployment_branch_policy.custom_branch_policies | tostring)] | join(" ")' 2>/dev/null || { echo error; return; }
  into p owner_gh api "repos/$REPO/environments/$ENV_NAME/deployment-branch-policies" --jq '[.branch_policies[] | "\(.type // "branch"):\(.name)"] | join(",")' 2>/dev/null || { echo error; return; }
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
  into uid owner_uid || die "can't read the owner's user id, so no Environment was made"
  env_json "$uid" >"$WORK/env.json"
  # Round 110: each write settled only by its expected answer (the Environment's, the policy's) or, for
  # the dummy value, by reading it back by name.
  write_checked "json:.name == \"$ENV_NAME\"" owner_gh api -X PUT "repos/$REPO/environments/$ENV_NAME" --input "$WORK/env.json" \
    || die "making the Environment failed"
  # Only a listing GitHub actually returned decides whether main is missing (round 31, C1).
  local names
  into names owner_gh api "repos/$REPO/environments/$ENV_NAME/deployment-branch-policies" --jq '.branch_policies[].name' 2>/dev/null \
    || die "can't read the Environment's branch policies, so nothing more was changed"
  if ! printf '%s\n' "$names" | grep -Fxq main; then
    write_checked 'json:.name == "main"' owner_gh api -X POST "repos/$REPO/environments/$ENV_NAME/deployment-branch-policies" \
      -f name=main -f type=branch || die "limiting the Environment to main failed"
  fi
  # A dummy value, not a secret: gh encrypts it for GitHub. Only its length is ever printed.
  write_checked "text:Set Actions secret $DUMMY_NAME" owner_gh secret set "$DUMMY_NAME" --env "$ENV_NAME" --repo "$REPO" --body "$DUMMY_VALUE" \
    || die "storing the dummy value failed"
  local stored
  into stored owner_gh api "repos/$REPO/environments/$ENV_NAME/secrets/$DUMMY_NAME" --jq .name 2>/dev/null || stored=""
  [[ "$stored" == "$DUMMY_NAME" ]] || die "the dummy value isn't there, read back by its name"
  write_resolved "$(owner_what secret set "$DUMMY_NAME" --env "$ENV_NAME" --repo "$REPO" --body "$DUMMY_VALUE")"
  local got
  into got env_summary
  [[ "$got" == "$(want_env)" ]] || die "the Environment is '$got', expected '$(want_env)'"
  say "Environment $ENV_NAME: reviewer $OWNER only, self-review prevented, only main deploys; dummy value stored"
}

runs_for() { # <sha> — "id status conclusion actor" for each run of the S2 workflow on that commit
  with_timeout "$(call_secs)" owner_gh api "repos/$REPO/actions/runs?head_sha=$1&per_page=20" \
    --jq '.workflow_runs[] | select(.name == "frg26-s2") | "\(.id) \(.status) \(.conclusion) \(.actor.login)"' 2>/dev/null
}

wait_run() { # <sha> <status…> — sets RUN to "id status conclusion actor" once it has one of them
  local sha="$1" _ line="" st want
  shift
  RUN=""
  for _ in $(seq 1 60); do
    into line runs_for "$sha" || line=""
    line="${line%%$'\n'*}"
    st="$(printf '%s' "$line" | cut -d' ' -f2)"
    for want in "$@"; do
      if [[ -n "$line" && "$st" == "$want" ]]; then RUN="$line"; return 0; fi
    done
    nap 5
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
  into log owner_gh run view "$1" --repo "$REPO" --log 2>/dev/null || { echo error; return; }
  if grep -Fq "FRG26-S2 value length ${#DUMMY_VALUE}" <<<"$log"; then echo yes; else echo no; fi
}

# GitHub's own word on whether the owner may approve the run's waiting deployment.
can_approve() { # <run id> — true | false | [other] | error
  owner_gh api "repos/$REPO/actions/runs/$1/pending_deployments" --jq '.[0].current_user_can_approve | if type == "boolean" then tostring else "[other]" end' 2>/dev/null || echo error
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
  into j owner_gh api "repos/$REPO/actions/runs/$1/jobs" --jq '.jobs[] | select(.name == "deploy") | "\(.check_run_url | split("/") | last) \(.steps | length) \(.conclusion)"' 2>/dev/null || j=""
  j="${j%%$'\n'*}"
  printf '%s\n' "${j:-error}"
}

# GitHub's annotation when an Environment's deployment branches leave a branch out. The wording is
# Unconfirmed (the docs don't quote it): if it differs, S2a reads inconclusive and stops the run.
policy_rejected() { # <check-run id>
  local m
  into m owner_gh api "repos/$REPO/check-runs/$1/annotations" --jq '.[].message' 2>/dev/null && grep -Eiq 'not allowed to deploy' <<<"$m"
}

# The ids of S2 runs not yet completed (queued, in progress, waiting…), every page; fails if the
# list can't be read. Not only waiting ones: a queued run reaches the approval gate later (round 22).
unfinished_runs() {
  with_timeout "$(call_secs)" owner_gh api --paginate "repos/$REPO/actions/runs?per_page=100" \
    --jq '.workflow_runs[] | select(.name == "frg26-s2" and .status != "completed") | .id' 2>/dev/null
}

# The S2 cancels this run has started (round 77; round 110: every one, whatever its answer). Round
# 111 (review-lens round 99, SEC-2; owner: "record each S2 cancel before dispatch so a stop cannot
# allow a resend"): one record for the whole run, each cancel entered before it is sent, never
# removed, so no later tidy-up, test or clean-up after a stop sends a second for that run. Each entry
# id:<answer>:<state>. The answer: - until it is kept (a stop came first), ok (GitHub's 202), the
# seconds of no answer, or s<status> (s0: answered otherwise). The state: sent; read (a list of
# unfinished runs read after it still shows the run); done (one no longer does: settled, rule (b)).
S2_CANCELS=""

s2_cancel() { # <run id> — sent only if this run's record has none for it; 1 unless GitHub accepted it (202)
  local id="$1" a rc=0
  [[ " $S2_CANCELS " != *" $id:"* ]] || return 1
  S2_CANCELS="$S2_CANCELS $id:-:sent"
  # Bounded by owner_gh alone, as in close_if_open (round 77); checked by GitHub's status line (round 110).
  write_checked status:202 owner_gh api -i -X POST "repos/$REPO/actions/runs/$id/cancel" || rc=$?
  if [[ $rc -eq 0 ]]; then a=ok
  elif [[ $LAST_RC -eq 124 ]]; then a="$IR_SECS"
  else a="s$LAST_RC"
  fi
  S2_CANCELS="${S2_CANCELS/ $id:-:sent/ $id:$a:sent}"
  return "$rc"
}

# runs_reread, with each list of unfinished runs read: a run no longer on it is settled (its cancel's
# note resolved, rule (b)), said unless GitHub accepted its cancel; one still on it is marked read.
runs_reread() { # <the list>
  local e id a st keep=""
  for e in $S2_CANCELS; do
    id="${e%%:*}" st="${e##*:}" a="${e#*:}" a="${a%:*}"
    if [[ "$st" == "done" ]]; then
      keep="$keep $e"
    elif [[ " $(printf '%s' "$1" | tr '\n' ' ') " == *" $id "* ]]; then
      keep="$keep $id:$a:read"
    else
      write_resolved "$(owner_what api -X POST "repos/$REPO/actions/runs/$id/cancel")"
      [[ "$a" == ok ]] || say "CLEANUP S2 run $id in $REPO: its cancel $(cancel_answer "$a"); read back: no longer unfinished"
      keep="$keep $id:$a:done"
    fi
  done
  S2_CANCELS="$keep"
}

cancel_answer() { # <ok | - | seconds | s<status>> — how a cancel's answer is said
  case "$1" in
    ok) printf 'was accepted (HTTP 202)' ;;
    -) printf 'was started, its answer not kept (a stop came)' ;;
    s0) printf 'answered, not as expected' ;;
    s*) printf 'failed (status %s)' "${1#s}" ;;
    *) printf 'got no answer within %ss' "$1" ;;
  esac
}

# runs_unsettled, when cancel_waiting_runs ends: each cancel not settled is named outcome unknown,
# with what the list read back (round 110: its own note from capture gives way to this one). Kept in
# the record: a later tidy-up's list may still settle it, and never sends it again.
runs_unsettled() {
  local e id a st why
  for e in $S2_CANCELS; do
    st="${e##*:}"
    [[ "$st" != "done" ]] || continue
    id="${e%%:*}" a="${e#*:}" a="${a%:*}"
    why="not read back"
    [[ "$st" != read ]] || why="read back: still unfinished"
    case "$a" in
      ok) why="accepted (HTTP 202); $why" ;;
      -) why="its answer not kept (a stop came); $why" ;;
      s0) why="answered, not as expected; $why" ;;
      s*) why="failed: status ${a#s}; $why" ;;
      *) why="no answer within ${a}s; $why" ;;
    esac
    write_resolved "$(owner_what api -X POST "repos/$REPO/actions/runs/$id/cancel")"
    unsettled_write "$why" owner_gh api -X POST "repos/$REPO/actions/runs/$id/cancel"
  done
}

# Every unfinished S2 run GitHub shows is cancelled, and confirmed finished (rounds 14, 22, 25); then
# the clean-up fails if a run may still be missing: a commit env-tests made whose run never showed
# within a minute (round 23), or a workflow commit whose sha is unknown (round 24). The visible runs
# are always dealt with first, whatever else failed (round 25, SEC-1). Each call bounded, and no
# wait or poll runs past the clean-up's cap (round 72, SEC-1). 1 on any failure.
cancel_waiting_runs() {
  local ids id _ sha seen unseen="" ok="" rc runs TIDY_UP=1
  for sha in $S2_SHAS; do
    seen=""
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
      in_time || break
      into runs runs_for "$sha" || true
      if [[ -n "$runs" ]]; then seen=1; break; fi
      pause 5
    done
    [[ -n "$seen" ]] || unseen="$unseen ${sha:0:7}"
  done
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if ! in_time; then
      runs_unsettled
      undone "cancelling the waiting S2 runs"; say "CLEANUP FAIL the clean-up's time cap (${CLEANUP_SECS}s) was reached before the S2 runs in $REPO were cancelled: cancel any unfinished S2 run on GitHub (Actions)"
      return 1
    fi
    rc=0
    into ids unfinished_runs || rc=$?
    if [[ $rc -ne 0 ]]; then
      runs_unsettled
      undone "cancelling the waiting S2 runs"; say "CLEANUP FAIL could not list the unfinished S2 runs in $REPO$(no_answer $rc): cancel any on GitHub (Actions)"
      return 1
    fi
    runs_reread "$ids"
    if [[ -z "$ids" ]]; then ok=1; break; fi
    for id in $ids; do
      if [[ ! "$id" =~ ^[0-9]+$ ]]; then runs_unsettled; undone "cancelling the waiting S2 runs"; say "CLEANUP FAIL unexpected run id in $REPO: cancel any unfinished S2 run on GitHub"; return 1; fi
      in_time || break
      # Round 110 (owner's rule (b)): every cancel is sent once, whatever its answer (a failure is never
      # taken as a refusal), and waits in the run's record for the lists that follow to settle it;
      # round 111: one already in it, from this run's S2d, an earlier tidy-up or before a stop, is not sent.
      s2_cancel "$id" || true
    done
    pause 5
  done
  runs_unsettled
  if [[ -z "$ok" ]]; then
    undone "cancelling the waiting S2 runs"; say "CLEANUP FAIL S2 runs still unfinished in $REPO ($(printf '%s' "$ids" | tr '\n' ' ')): cancel them on GitHub (Actions)"
    return 1
  fi
  if [[ -n "$S2_UNKNOWN" ]]; then
    undone "cancelling the waiting S2 runs"; say "CLEANUP FAIL the S2 workflow commit's outcome is unknown, so its run may appear later: check $REPO's Actions on GitHub and cancel any S2 run there"
    return 1
  fi
  if [[ -n "$unseen" ]]; then
    undone "cancelling the waiting S2 runs"; say "CLEANUP FAIL the S2 runs for commit(s)$unseen never appeared within a minute: check $REPO's Actions on GitHub and cancel any S2 run there"
    return 1
  fi
  return 0
}

# S2b: the app's push to main starts a run; the app tries to approve its own deployment. Control:
# the owner approves the same run, and the job then reports the dummy value's length. GitHub's state
# is also read around the owner's approval (S2d's criterion 6, owner 2026-11-20): it must show the
# change an approval makes, so that S2d's "unchanged" means something. S2B_READINGS says whether it
# did; S2b's own verdict doesn't depend on it.
t_S2b() {
  S2B_READINGS=""
  fresh_from main "s2b-$(stamp)"
  add_commit "tests/permissions-S2b-$(stamp).txt" "FRG-26 S2b"
  # Recorded before the push: GitHub may accept it, and start its run, even if the push reports a
  # failure (round 25, C2).
  local sha eid id
  into sha app_git -C "$CLONE" rev-parse HEAD || sha=""
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { setup_fail_p S2b "could not read the local commit"; return; }
  S2_SHAS="$S2_SHAS $sha"
  capture app_git -C "$CLONE" push origin HEAD:refs/heads/main || { setup_fail_p S2b "the app could not push main in the open phase: $(evidence)"; return; }
  into eid env_id || eid=""
  [[ "$sha" =~ ^[0-9a-f]{40}$ && "$eid" =~ ^[0-9]+$ ]] || { setup_fail_p S2b "could not read the commit or the Environment"; return; }
  wait_run "$sha" waiting || { setup_fail_p S2b "the app's run never waited for review ($RUN)"; return; }
  id="${RUN%% *}"
  # Round 112 (owner): the app's attempt is judged by GitHub's whole answer, and settled only if the
  # run, read back, is as its baseline was before the attempt: the same run, commit, Environment and one
  # deployment, still pending, no approval recorded.
  local base bdep
  s2_reading "S2B baseline" "$id" "$sha" "$APP_BOT"
  s2_pending_check "$id" "$sha" "$APP_BOT" "$eid" true
  base="$S2_WHY" bdep="$S2R_DEP"
  if [[ -n "$base" || -z "$bdep" ]]; then
    setup_fail_p S2b "the app's run is not bound before its attempt (${base:-no deployment})"
    cancel_waiting_runs || true
    return
  fi
  ATTEMPT_WRITES=""
  app_attempt -X POST "repos/$REPO/actions/runs/$id/pending_deployments" -F "environment_ids[]=$eid" \
    -f state=approved -f comment="FRG-26 S2 approval attempt"
  EV="the app approving its own run: $LAST_OUT |"
  if [[ "$OBS" != refused ]]; then record_p S2b "$OBS" "not run" "$EV"; cancel_waiting_runs || true; return; fi
  CTL=failed
  local can logv="" before dep
  into can can_approve "$id"
  [[ "$can" == true || "$can" == false || "$can" == error ]] || can="[other]"
  s2_reading "S2B before" "$id" "$sha" "$APP_BOT"
  s2_pending_check "$id" "$sha" "$APP_BOT" "$eid" true
  before="$S2_WHY" dep="$S2R_DEP"
  if [[ -n "$before" || "$dep" != "$bdep" ]]; then
    OBS=inconclusive
    EV="$EV its run read back: not as before the attempt (${before:-another deployment}) |"
    record_p S2b "$OBS" "not run" "$EV"
    cancel_waiting_runs || true
    return
  fi
  write_resolved "app gh api POST repos/$REPO/actions/runs/$id/pending_deployments"
  EV="$EV its run read back: as before the attempt |"
  if [[ "$can" == true ]] && approve_run owner_gh "$id" "$eid" && wait_run "$sha" completed && into logv run_log_value "$id" && [[ "$logv" == yes ]]; then CTL=ok; fi
  EV="$EV GitHub says the owner can approve it: $can; owner approving: $(evidence), run $RUN"
  s2_reading "S2B after" "$id" "$sha" "$APP_BOT" "$dep"
  s2_approved_check "$id" "$sha" "$APP_BOT" "$eid" "$dep"
  if [[ -z "$before" && -z "$S2_WHY" && -n "$dep" ]]; then
    S2B_READINGS=ok
  else
    S2B_READINGS="before the owner's approval: ${before:-bound}; after it: ${S2_WHY:-the approval shows}"
  fi
  s2_say "S2B readings: $S2B_READINGS"
  S2B_OWNER_APPROVAL="$CTL"
  record_p S2b "$OBS" "$CTL" "$EV"
}

# S2's readings (rounds 78-81, owner 2026-11-20). On 2026-11-20 GitHub answered the owner's approval
# of their own run with HTTP 422 "No pending deployment requests to approve or reject", which fits both
# "pending, but not the owner's to review" and "nothing pending", and gh's error line named no HTTP
# status. So GitHub's own state of a run is read around each owner approval, bound to the run, its
# commit, the Environment and the one deployment GitHub made for them, and S2d's attempt keeps
# GitHub's status line (gh api -i), not gh's wording. Only the fields the checks need are kept
# (round 80, SEC-1): payloads, descriptions, comments, messages and links can hold any text, a
# credential included. Each kept field is a value from GitHub's documented list, or the one value
# wanted, else "[other]"; ids only when GitHub sent a number (round 81, SEC-1 of review-lens round
# 78: a form check let a credential of that form through).
S2R_RUN=""       # "id status sha actor event branch workflow", or error
S2R_PENDING=""   # "count environment-id environment-name can-approve reviewers", or error
S2R_DEPS=""      # "count id sha environment" of the deployments for the commit and Environment, or error
S2R_DEP=""       # the deployment whose statuses were read: the one wanted, or the first found
S2R_STATES=""    # its status states in the order GitHub listed them (not documented), or error
S2R_LATEST=""    # the state of its latest status by created_at: none, [unclear], or a state
S2R_MORE=""      # why its statuses may go on past the page read (100 or more, a Link header); empty if not
S2R_APPROVALS="" # "count state:login:environment-ids …", or error
S2_J=""          # the JSON of the read s2_json made last (never said)
S2_WHY=""        # what a check found that doesn't match, "; "-separated; empty when all of it does

# jq's helpers for the kept fields: known(<GitHub's documented list>), is(<the one value wanted>), num
# (a JSON number) and bool (a JSON boolean). null stays "null"; anything else is "[other]". get(f) is
# null where f can't be read (a field of something that isn't an object). The lists, from GitHub's
# REST documentation (2026-11-20): a run's status from the values "List workflow runs" filters by
# (the run object documents none); a deployment status's state from "List deployment statuses",
# with waiting, which only GraphQL's DeploymentStatusState documents; an approval's state from "Get
# the review history for a workflow run"; a reviewer's type from "Get pending deployments".
# shellcheck disable=SC2016 # jq's own $variables
readonly S2_JQ='def known($list): . as $v | if $v == null then "null" elif ($list | any(. == $v)) then $v else "[other]" end;
def is($w): known([$w]);
def num: if type == "number" and . == floor and . >= 0 and . < 1e15 then tostring elif . == null then "null" else "[other]" end;
def bool: if type == "boolean" then tostring elif . == null then "null" else "[other]" end;
def get(f): try f catch null;
def list(f): if type == "array" then f else "not a list" end;
def run_status: known(["completed","action_required","cancelled","failure","neutral","skipped","stale","success","timed_out","in_progress","queued","requested","waiting","pending"]);
def dep_state: known(["error","failure","inactive","in_progress","pending","queued","success","waiting"]);
def approval_state: known(["approved","rejected","pending"]);
def reviewer_type: known(["User","Team"]);
def at: get(.created_at) | if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") then . else null end;'

# Any text shaped like a GitHub token or a JWT hidden, not only this run's tokens: a second guard,
# behind keeping only fields of a known form.
s2_redact() { # <text>
  printf '%s' "$1" | sed -E 's/(gh[pousr]_|github_pat_)[A-Za-z0-9_.-]+/[REDACTED]/g; s/eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/[REDACTED]/g'
}

s2_say() { say "$(s2_redact "$1")"; }

s2_why() { S2_WHY="${S2_WHY:+$S2_WHY; }$1"; }

s2_want() { # <what> <read> <wanted>
  [[ "$2" == "$3" ]] || s2_why "$1 '$2', not '$3'"
}

s2_json() { # <path> — one read as the owner, its JSON kept in S2_J (not said)
  local j
  S2_J=""
  into j owner_gh api "repos/$REPO/$1" 2>/dev/null || return 1
  jq -e . >/dev/null 2>&1 <<<"$j" || return 1
  S2_J="$j"
}

# The same, as gh api -i prints it, for a list read one page at a time (round 82, C1 of review-lens
# round 79): only a 200 answer whose headers end counts as read. S2_PAGED is set when it carried a
# Link header, which GitHub sends only when the list has more than one page; its value isn't kept.
S2_PAGED=""
s2_json_page() { # <path>
  local LC_ALL=C raw rest line head=1
  S2_J="" S2_PAGED=""
  into raw owner_gh api -i "repos/$REPO/$1" 2>/dev/null || return 1
  line="${raw%%$'\n'*}"
  [[ "${line%$'\r'}" =~ ^HTTP/[0-9.]+\ 200( |$) && "$raw" == *$'\n'* ]] || return 1
  rest="${raw#*$'\n'}"
  while [[ "$rest" == *$'\n'* ]]; do
    line="${rest%%$'\n'*}"
    rest="${rest#*$'\n'}"
    line="${line%$'\r'}"
    if [[ -z "$line" ]]; then head=""; break; fi
    case "${line%%:*}" in
      [Ll][Ii][Nn][Kk]) S2_PAGED=1 ;;
    esac
  done
  [[ -z "$head" ]] || return 1
  jq -e . >/dev/null 2>&1 <<<"$rest" || return 1
  S2_J="$rest"
}

S2_SHA="" S2_ACTOR="" # the commit and the run's actor s2_reading wants

s2_fields() { # <jq filter> — the kept fields of S2_J, or [unreadable]
  jq -r --arg env "$ENV_NAME" --arg owner "$OWNER" --arg sha "$S2_SHA" --arg actor "$S2_ACTOR" "$S2_JQ $1" <<<"$S2_J" 2>/dev/null || echo "[unreadable]"
}

# One reading of a run, its pending deployments, the deployments for its commit and the Environment
# (and the statuses of the one wanted, or of the first found), and its approvals. Reads only; says
# the kept fields of each. The latest status is told by created_at, since GitHub doesn't document the
# list's order: none when there is none; [unclear] when a time isn't of its form, or the latest time
# holds two states.
s2_reading() { # <label> <run id> <sha> <the run's actor> [<deployment wanted>]
  local d n
  S2R_RUN=error S2R_PENDING=error S2R_DEPS=error S2R_DEP="" S2R_STATES="" S2R_LATEST="" S2R_MORE="" S2R_APPROVALS=error
  S2_SHA="$3" S2_ACTOR="$4"
  if s2_json "actions/runs/$2"; then
    # shellcheck disable=SC2016 # jq's own $sha and $actor
    S2R_RUN="$(s2_fields 'if type == "object" then "\(.id | num) \(.status | run_status) \(.head_sha | is($sha)) \(get(.actor.login) | is($actor)) \(.event | is("push")) \(.head_branch | is("main")) \(.name | is("frg26-s2"))" else "not an object" end')"
    s2_say "$1 run: $S2R_RUN"
  fi
  if s2_json "actions/runs/$2/pending_deployments"; then
    # shellcheck disable=SC2016 # jq's own $env and $owner
    S2R_PENDING="$(s2_fields 'list(.[0] as $p | "\(length) \($p | get(.environment.id) | num) \($p | get(.environment.name) | is($env)) \($p | get(.current_user_can_approve) | bool) \([$p | get(.reviewers) | if type == "array" then .[] else empty end | "\(get(.type) | reviewer_type):\(get(.reviewer.login) | is($owner))"] | join(","))")')"
    s2_say "$1 pending_deployments: $S2R_PENDING"
  fi
  if s2_json "deployments?sha=$3&environment=$ENV_NAME&per_page=100"; then
    # shellcheck disable=SC2016 # jq's own $sha and $env
    S2R_DEPS="$(s2_fields 'list(.[0] as $d | "\(length) \($d | get(.id) | num) \($d | get(.sha) | is($sha)) \($d | get(.environment) | is($env))")')"
    s2_say "$1 deployments: $S2R_DEPS"
    d="$(s2_fields 'list(.[0] | get(.id) | num)')"
    [[ "$d" =~ ^[0-9]+$ ]] || d=""
    if [[ -n "$d" && ( -z "${5:-}" || "$d" == "$5" ) ]]; then
      S2R_DEP="$d" S2R_STATES=error
      if s2_json_page "deployments/$d/statuses?per_page=100"; then
        S2R_STATES="$(s2_fields 'list([.[] | get(.state) | dep_state] | join(","))')"
        n="$(s2_fields 'list(length)')"
        if [[ "$n" =~ ^[0-9]+$ && "$n" -ge 100 ]]; then S2R_MORE="$n of them"; fi
        if [[ -n "$S2_PAGED" ]]; then S2R_MORE="${S2R_MORE:+$S2R_MORE; }a Link header"; fi
        # shellcheck disable=SC2016 # jq's own $t, $m and $i
        S2R_LATEST="$(s2_fields 'list(if length == 0 then "none" else [.[] | at] as $t
          | if any($t[]; . == null) then "[unclear]" else ($t | max) as $m
            | [range(length) as $i | select($t[$i] == $m) | .[$i] | get(.state) | dep_state] | unique
            | if length == 1 then .[0] else "[unclear]" end end end)')"
        s2_say "$1 deployment $d statuses: $S2R_STATES; latest $S2R_LATEST${S2R_MORE:+; may go on past this page: $S2R_MORE}"
      fi
    fi
  fi
  if s2_json "actions/runs/$2/approvals"; then
    # shellcheck disable=SC2016 # jq's own $owner
    S2R_APPROVALS="$(s2_fields 'list("\(length) \([.[] | "\(get(.state) | approval_state):\(get(.user.login) | is($owner)):\([get(.environments) | if type == "array" then .[] else empty end | get(.id) | num] | join(","))"] | join(" "))")')"
    s2_say "$1 approvals: $S2R_APPROVALS"
  fi
}

s2_read_ok() { # <what> <its reading> — false, and S2_WHY says so, when that read failed
  [[ "$2" != error ]] || { s2_why "the $1 read failed"; return 1; }
}

# The deployment's statuses as S2 needs them: all on the page read (fewer than 100, no Link header),
# a list, not empty, each state on GitHub's list. Sets S2_WHY when not; true when they are.
s2_states_known() {
  local d="$S2R_DEP"
  if [[ -n "$S2R_MORE" ]]; then s2_why "deployment $d's statuses may go on past this page ($S2R_MORE): not all are shown"; return 1; fi
  if [[ "$S2R_STATES" == "not a list" || "$S2R_STATES" == "[unreadable]" ]]; then s2_why "deployment $d's statuses are not a list"; return 1; fi
  if [[ -z "$S2R_STATES" ]]; then s2_why "deployment $d has no status: GitHub doesn't show it waiting"; return 1; fi
  if [[ ",$S2R_STATES," == *",[other],"* || ",$S2R_STATES," == *",null,"* ]]; then s2_why "deployment $d states '$S2R_STATES': a state not on GitHub's list"; return 1; fi
}

# The run still waits, untouched: on <sha>, pushed by <actor> to main; exactly one deployment pending,
# for this Environment, the owner its only reviewer, current_user_can_approve as given; exactly one
# deployment for the commit and Environment (the one found before, when given), shown waiting: each
# status's state on GitHub's list, none started or ended, the latest waiting, queued or pending (round
# 81, C1 of review-lens round 78), all of them on the page read (round 82); no approval recorded. Queued or pending say only that it hasn't
# started: that it waits for the owner's review is the rest of the reading. Sets S2_WHY.
s2_pending_check() { # <run id> <sha> <actor> <Environment id> <true|false> [<deployment>]
  local re=',(in_progress|success|failure|error|inactive),'
  S2_WHY=""
  if s2_read_ok run "$S2R_RUN"; then s2_want run "$S2R_RUN" "$1 waiting $2 $3 push main frg26-s2"; fi
  if s2_read_ok pending_deployments "$S2R_PENDING"; then s2_want "pending deployments" "$S2R_PENDING" "1 $4 $ENV_NAME $5 User:$OWNER"; fi
  if s2_read_ok deployments "$S2R_DEPS"; then s2_want deployments "$S2R_DEPS" "1 ${6:-$S2R_DEP} $2 $ENV_NAME"; fi
  if [[ -n "$S2R_DEP" ]] && s2_read_ok "deployment $S2R_DEP statuses" "$S2R_STATES"; then
    if [[ ",$S2R_STATES," =~ $re ]]; then
      s2_why "deployment $S2R_DEP states $S2R_STATES: it started or ended"
    elif s2_states_known; then
      case "$S2R_LATEST" in
        waiting | queued | pending) ;;
        *) s2_why "deployment $S2R_DEP's latest status can't be told by its time ('$S2R_LATEST')" ;;
      esac
    fi
  fi
  if s2_read_ok approvals "$S2R_APPROVALS"; then s2_want approvals "$S2R_APPROVALS" "0 "; fi
}

# After the owner's approval of <run id>: the same run, commit and deployment, the run's status on
# GitHub's list; nothing pending any more; an approval by the owner recorded for this Environment;
# the deployment's statuses, each on GitHub's list, showing it started. Sets S2_WHY.
s2_approved_check() { # <run id> <sha> <actor> <Environment id> <deployment>
  local parts
  S2_WHY=""
  if s2_read_ok run "$S2R_RUN"; then
    read -r -a parts <<<"$S2R_RUN"
    s2_want run "${parts[0]:-} ${parts[2]:-} ${parts[3]:-} ${parts[4]:-} ${parts[5]:-} ${parts[6]:-}" "$1 $2 $3 push main frg26-s2"
    [[ "${parts[1]:-}" != "[other]" && "${parts[1]:-}" != null && -n "${parts[1]:-}" ]] || s2_why "run status '${parts[1]:-}': not on GitHub's list"
  fi
  if s2_read_ok pending_deployments "$S2R_PENDING"; then s2_want "pending deployments" "$S2R_PENDING" "0 null null null "; fi
  if s2_read_ok deployments "$S2R_DEPS"; then s2_want deployments "$S2R_DEPS" "1 $5 $2 $ENV_NAME"; fi
  if [[ -n "$5" && "$S2R_DEP" == "$5" ]] && s2_read_ok "deployment $5 statuses" "$S2R_STATES" && s2_states_known; then
    [[ ",$S2R_STATES," == *,in_progress,* || ",$S2R_STATES," == *,success,* ]] || s2_why "deployment $5 states '$S2R_STATES': no sign it started"
  fi
  if s2_read_ok approvals "$S2R_APPROVALS"; then
    [[ " ${S2R_APPROVALS#* } " == *" approved:$OWNER:$4 "* ]] || s2_why "approvals '$S2R_APPROVALS': no approval by $OWNER for Environment $4"
  fi
}

readonly S2D_WORDS="No pending deployment requests to approve or reject" # GitHub's, 2026-11-20
# The resources GET /rate_limit documents (2026-11-20).
readonly S2D_RESOURCES="core graphql search code_search source_import integration_manifest actions_runner_registration scim dependency_snapshots dependency_sbom code_scanning_autofix copilot_usage_records"
S2D_HTTP=""       # GitHub's status for S2d's attempt, or unknown
S2D_RC=""         # gh's exit status for it
S2D_REQUEST_ID="" # its x-github-request-id, in the form GitHub has used (five groups of hex digits;
#                   GitHub doesn't document one): correlation only; the authenticated HTTPS
#                   connection is what says GitHub answered
S2D_REMAINING=""  # its x-ratelimit-remaining
S2D_RESOURCE=""   # its x-ratelimit-resource, one of S2D_RESOURCES
S2D_RETRY=""      # set when it carried a retry-after header (a rate-limit sign; the value isn't kept)
S2D_ANSWER=""     # what the body is, in known words and values only (never its text)
S2D_ERRORS=""     # the body's errors as text: compared, never said
S2D_GH_LINE=""    # whether gh's error line repeats GitHub's words: repeats | other | none
S2D_LIMIT=""      # the rate-limit signs found, "; "-separated
S2D_INCOMPLETE="" # why the answer isn't shown complete; empty when it is
S2D_MISSING=""    # which of the criteria for a refusal didn't hold, "; "-separated

# The attempt. Identity encoding is asked for, so the body arrives as GitHub sent it and its length can
# be checked against Content-Length (round 80, C1): Go's client, which gh uses, drops Content-Length
# when it decompresses an answer itself. Its output and error output go to files, read whole.
s2d_post() { # <run id> <Environment id>
  owner_gh api -i -X POST "repos/$REPO/actions/runs/$1/pending_deployments" -H "Accept-Encoding: identity" \
    -F "environment_ids[]=$2" -f state=approved -f comment="FRG-26 S2d approval attempt" >"$WORK/s2d.out" 2>"$WORK/s2d.err"
}

# The owner's approval of the run's deployment. Kept: GitHub's status, gh's exit status, the request id,
# x-ratelimit-remaining and x-ratelimit-resource (each of its known form), the body's kind and known
# words, whether gh's error line repeats GitHub's words, and whether the answer is shown complete.
# Never kept: the body's text, gh's error text, any other header.
s2d_approve() { # <run id> <Environment id>
  # shellcheck disable=SC2034 # ignored: into's output, empty (the request writes its own files)
  local LC_ALL=C raw body="" length="" err ignored=""
  S2D_RC=0 S2D_HTTP=unknown S2D_REQUEST_ID="" S2D_REMAINING="" S2D_RESOURCE="" S2D_RETRY="" S2D_ERRORS="" S2D_INCOMPLETE=""
  : >"$WORK/s2d.out"
  : >"$WORK/s2d.err"
  # The approval is a write: noted here, in the run's memory, and cleared only once its whole answer
  # is read and shown complete below (round 109); else its outcome is unknown.
  write_out "owner gh api POST repos/$REPO/actions/runs/$1/pending_deployments"
  local wn=$WRITE_N
  into ignored s2d_post "$1" "$2" || S2D_RC=$?
  raw="$(cat "$WORK/s2d.out"; printf x)"
  raw="${raw%x}"
  err="$(cat "$WORK/s2d.err")"
  # Read as every app attempt's answer is (round 112: one reader, http_answer).
  http_answer "$raw" "$S2D_RC"
  S2D_HTTP="$HA_STATUS" S2D_REQUEST_ID="$HA_REQUEST_ID" S2D_REMAINING="$HA_REMAINING" S2D_RESOURCE="$HA_RESOURCE"
  S2D_RETRY="$HA_RETRY" S2D_INCOMPLETE="$HA_INCOMPLETE" body="$HA_BODY" length="$HA_LENGTH"
  if jq -e . >/dev/null 2>&1 <<<"$body"; then
    S2D_ANSWER="$(jq -r --arg words "$S2D_WORDS" '
      def msg: . as $m | if $m == null then "none" elif ($m | type) != "string" then "[other]"
        elif ([ "Validation Failed", "Not Found", "Forbidden", "Server Error", "Bad credentials",
                "Resource not accessible by integration" ] | any(. == $m)) then $m
        elif ($m | test("^API rate limit exceeded")) then "API rate limit exceeded"
        elif ($m | test("secondary rate limit"; "i")) then "secondary rate limit" else "[other]" end;
      if type == "object" then
        (.message | msg) as $mc
        | "error, message \($mc), errors \(if .errors == null then "none" elif .errors == $words then "GitHub'"'"'s words of 2026-11-20" else "other text (not kept)" end)"
      elif type == "array" then "a list of \(length), ids \([.[] | (try .id catch null) | if type == "number" and . == floor and . >= 0 and . < 1e15 then tostring else "[other]" end] | join(",") | if . == "" then "none" else . end)"
      else "JSON of another kind (not kept)" end' <<<"$body" 2>/dev/null)" || S2D_ANSWER="[other]"
    S2D_ERRORS="$(jq -r 'if type == "object" then (.errors | if type == "string" then . elif type == "array" then map(if type == "string" then . else (.message // tostring) end) | join("; ") else "" end) else "" end' <<<"$body" 2>/dev/null)" || S2D_ERRORS=""
  elif [[ -z "$body" ]]; then
    S2D_ANSWER="empty"
  else
    S2D_ANSWER="not JSON (not kept)"
  fi
  if [[ -n "$S2D_INCOMPLETE" || ! "$S2D_HTTP" =~ ^[0-9]{3}$ ]]; then
    write_unknown "owner gh api POST repos/$REPO/actions/runs/$1/pending_deployments" "no complete answer: ${S2D_INCOMPLETE:-no HTTP status}"
  fi
  write_done "$wn"
  if [[ -z "$err" ]]; then S2D_GH_LINE=none
  elif [[ "$err" == *"$S2D_WORDS"* ]]; then S2D_GH_LINE=repeats
  else S2D_GH_LINE=other
  fi
  S2D_LIMIT=""
  [[ "$S2D_HTTP" != 429 && "$S2D_HTTP" != 403 ]] || S2D_LIMIT="$S2D_LIMIT HTTP $S2D_HTTP;"
  [[ -z "$S2D_RETRY" ]] || S2D_LIMIT="$S2D_LIMIT a retry-after header;"
  [[ "$S2D_REMAINING" != 0 ]] || S2D_LIMIT="$S2D_LIMIT x-ratelimit-remaining 0;"
  if printf '%s %s' "$body" "$err" | grep -Eiq 'rate limit|abuse detection|secondary rate'; then S2D_LIMIT="$S2D_LIMIT rate-limit words;"; fi
  S2D_LIMIT="${S2D_LIMIT# }"
  s2_say "S2D approval: HTTP $S2D_HTTP (exit $S2D_RC); request id ${S2D_REQUEST_ID:-none}; x-ratelimit-remaining ${S2D_REMAINING:-none}; x-ratelimit-resource ${S2D_RESOURCE:-none}; answer: $S2D_ANSWER; completion: ${S2D_INCOMPLETE:-Content-Length $length matches the body}; gh's error line: $S2D_GH_LINE${S2D_RETRY:+; a retry-after header (not kept)}"
}

s2d_miss() { S2D_MISSING="${S2D_MISSING:+$S2D_MISSING; }$1"; }

# The criteria for a refusal (owner, 2026-11-20): the reading before bound (checked by t_S2d before
# any attempt); an answer shown complete (round 80: GitHub's Content-Length, no encoding, no timeout;
# gh's exit status 1 and its error line repeating GitHub's words only support it); HTTP 422 with a
# request id; the errors exactly GitHub's words of 2026-11-20; no rate-limit sign and quota left; the
# reading after bound to the same deployment; S2b's control and readings (criterion 6). The words
# support the reading; they don't prove the refusal's cause.
s2d_criteria() { # sets S2D_MISSING
  S2D_MISSING=""
  [[ -z "$S2D_INCOMPLETE" ]] || s2d_miss "the answer is not shown complete ($S2D_INCOMPLETE)"
  [[ "$S2D_RC" == 1 ]] || s2d_miss "gh's exit status $S2D_RC, not 1"
  [[ "$S2D_GH_LINE" == repeats ]] || s2d_miss "gh's error line doesn't repeat GitHub's words ($S2D_GH_LINE)"
  [[ "$S2D_HTTP" == 422 ]] || s2d_miss "HTTP $S2D_HTTP, not 422"
  [[ -n "$S2D_REQUEST_ID" && "$S2D_REQUEST_ID" != "[other]" ]] || s2d_miss "no x-github-request-id of its form"
  [[ "$S2D_ERRORS" == "$S2D_WORDS" ]] || s2d_miss "the errors are not GitHub's words of 2026-11-20 (their text is not kept)"
  [[ -z "$S2D_LIMIT" ]] || s2d_miss "rate-limit signs: $S2D_LIMIT"
  [[ "$S2D_REMAINING" =~ ^[0-9]+$ && "$S2D_REMAINING" -gt 0 ]] || s2d_miss "x-ratelimit-remaining '${S2D_REMAINING}', not above 0"
  [[ -n "$S2D_RESOURCE" && "$S2D_RESOURCE" != "[other]" ]] || s2d_miss "x-ratelimit-resource '${S2D_RESOURCE}', not one of GitHub's listed resources"
  [[ -z "$S2_WHY" ]] || s2d_miss "after it: $S2_WHY"
  [[ "$S2B_OWNER_APPROVAL" == ok ]] || s2d_miss "S2b's control was not ok"
  [[ "$S2B_READINGS" == ok ]] || s2d_miss "S2b's readings don't show an approval taking effect (${S2B_READINGS:-not read})"
}

# S2d: the run the owner's own workflow commit started (env-tests' first step): the owner tries to
# approve it, which Prevent self-review should refuse. Control: the very same request, by the same
# owner, on the app's run in S2b, was accepted. No approval is sent unless the reading before it is
# bound in every part. Allowed when GitHub accepted the approval (exit 0 or a 2xx), recorded one, or
# the deployment started. Refused only when every criterion holds (s2d_criteria), and then only
# "refused in this tested configuration": no general guarantee. Anything else: inconclusive.
t_S2d() {
  local eid id dep after
  into eid env_id || eid=""
  [[ "$eid" =~ ^[0-9]+$ ]] || { setup_fail_p S2d "could not read the Environment"; return; }
  wait_run "$S2_OWNER_SHA" waiting || { setup_fail_p S2d "the owner's run never waited for review ($RUN)"; return; }
  id="${RUN%% *}"
  [[ "$id" =~ ^[0-9]+$ ]] || { setup_fail_p S2d "unexpected run id ($RUN)"; return; }
  OBS=inconclusive
  s2_reading "S2D before" "$id" "$S2_OWNER_SHA" "$OWNER"
  s2_pending_check "$id" "$S2_OWNER_SHA" "$OWNER" "$eid" false
  if [[ -n "$S2_WHY" ]]; then
    s2_say "S2D before: NOT bound: $S2_WHY"
    EV="inconclusive: no approval sent, GitHub's state before the attempt is not bound ($S2_WHY)"
  else
    dep="$S2R_DEP"
    s2_say "S2D before: bound: run $id, commit $S2_OWNER_SHA, Environment $ENV_NAME ($eid), deployment $dep"
    s2d_approve "$id" "$eid"
    s2_reading "S2D after" "$id" "$S2_OWNER_SHA" "$OWNER" "$dep"
    s2_pending_check "$id" "$S2_OWNER_SHA" "$OWNER" "$eid" false "$dep"
    after="bound: the same run, commit, Environment and deployment, still pending, no approval"
    [[ -z "$S2_WHY" ]] || after="NOT bound: $S2_WHY"
    s2_say "S2D after: $after"
    s2d_criteria
    if [[ $S2D_RC -eq 0 || "$S2D_HTTP" == 2?? || "${S2R_APPROVALS%% *}" =~ ^[1-9][0-9]*$ || ",$S2R_STATES," == *,in_progress,* || ",$S2R_STATES," == *,success,* ]]; then
      OBS=allowed
      EV="allowed: GitHub answered HTTP $S2D_HTTP (exit $S2D_RC); after it: $after"
    elif [[ -z "$S2D_MISSING" ]]; then
      OBS=refused
      EV="self-approval refused in this tested configuration (Environment $ENV_NAME, Prevent self-review on, $OWNER its only reviewer): a complete HTTP 422 answer whose errors are GitHub's words of 2026-11-20, request $S2D_REQUEST_ID; deployment $dep pending before and after, no approval recorded; S2b's control ok and its readings show an approval taking effect. GitHub's words support this; they don't prove the refusal's cause"
    else
      EV="inconclusive: $S2D_MISSING"
    fi
  fi
  EV="$(s2_redact "$EV (S2D lines above; control: the owner's approval of the app's run in S2b)")"
  # Checked by GitHub's status line (round 110): 202 for a cancel accepted, else outcome unknown. In the
  # run's record before it is sent (round 111), so no tidy-up after it sends a second.
  s2_cancel "$id" || true
  record_p S2d "$OBS" "${S2B_OWNER_APPROVAL:-failed}" "$EV"
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
  into sha app_git -C "$CLONE" rev-parse HEAD || sha=""
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { setup_fail_p S2a "could not read the local commit"; return; }
  S2_SHAS="$S2_SHAS $sha"
  capture app_git -C "$CLONE" push origin "HEAD:refs/heads/$br" || { setup_fail_p S2a "pushing $br failed: $(evidence)"; return; }
  wait_run "$sha" completed waiting || { setup_fail_p S2a "no run finished for $br ($RUN)"; return; }
  id="${RUN%% *}"
  # Refused needs GitHub's own rejection (round 13, C3/SEC-1): the deploy job failed without running
  # a step, and its annotation says the branch may not deploy. A run that failed for another reason,
  # or that can't be read, proves nothing.
  local job jid steps concl logv
  OBS=inconclusive
  if [[ "$RUN" == *" waiting "* ]]; then OBS=allowed
  else
    into job deploy_job "$id"
    read -r jid steps concl <<<"$job"
    if [[ "$concl" == failure && "$steps" == 0 && "$jid" =~ ^[0-9]+$ ]] && policy_rejected "$jid"; then OBS=refused
    else
      into logv run_log_value "$id"
      if [[ "$logv" == yes ]]; then OBS=allowed; fi
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
  local uid got
  into uid owner_uid || { setup_fail_p S2c "could not read the owner's user id"; return; }
  env_json "$uid" >"$WORK/env.json"
  if ! capture owner_gh secret set "$DISPOSABLE_NAME" --env "$ENV_NAME" --repo "$REPO" --body "$DUMMY_VALUE"; then
    setup_fail_p S2c "could not make the disposable dummy secret: $(evidence)"
    return
  fi
  p_attempts api S2c app_gh api -X PUT "repos/$REPO/environments/$ENV_NAME" --input "$WORK/env.json" ";;" \
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
  into got env_summary
  [[ "$got" == "$(want_env)" ]] || { CTL=failed; EV="$EV the Environment reads '$got' afterwards |"; }
  record_p S2c "$OBS" "$CTL" "$EV"
}

readonly S2_TEST_ORDER="S2b S2d S2a S2c"
S2_OWNER_SHA=""
S2_SHAS="" # every commit env-tests made that starts an S2 run (round 22, C2)
S2_UNKNOWN="" # set while the owner's workflow commit may have happened but its sha isn't known
S2B_OWNER_APPROVAL=""
S2B_READINGS="" # ok when S2b's readings show its owner approval taking effect (S2d's criterion 6)

cmd_env_tests() {
  need_owner
  assert_throwaway
  app_session
  verify_phase open
  need_allowance
  local got
  into got env_summary
  [[ "$got" == "$(want_env)" ]] || die "run env-setup first (the Environment reads '$got')"
  PHASE=permissions
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  CLONE="$WORK/clone"
  say "== FRG-26 Environment tests (S2), app $APP_BOT, $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
  # The owner adds the workflow to main: that commit starts the owner's own run (S2d's). Its sha comes
  # from the write's own answer; until it is known the outcome counts as unknown, which the clean-up
  # can't reconcile and reports (round 24, SEC-1).
  CANCEL_ON_EXIT=1
  S2_UNKNOWN=1
  into S2_OWNER_SHA put_file_commit "$S2_WORKFLOW" "$(s2_workflow)" 2>/dev/null || S2_OWNER_SHA=""
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
  HELD_KEPT="$HELD_KEPT $held"
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
  # Through request_token, with its safeguards (round 60, C1).
  request_token "{\"repositories\":[\"$REPO_NAME\"],\"permissions\":$WANT_PERMS}"
  local obs=inconclusive old_http="$LAST_HTTP"
  case "$old_http" in
    2*) obs=allowed ;;
    401) obs=refused ;;
  esac
  # Whatever GitHub issued, in any form, is revoked (round 33, C1), whatever the answer's status.
  if [[ "$REQ_TOKEN" == yes ]]; then
    obs=allowed
    revoke_token || true
  fi
  # An answer that may mean a token never received stops the step at once, before any other token
  # is asked for, reported whole (round 61, C1).
  if [[ "$REQ_UNRECEIVED" == yes ]]; then
    report_unreceived
    die "the request signed with the deleted key got no usable answer (HTTP ${LAST_HTTP:-none}): GitHub may have issued a token this run never received; the step stops"
  fi
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
  # Through request_token, with its safeguards (round 60, C1): a token it brings is on the exit
  # clean-up's list before it is revoked, so a failed revocation is tried again (round 27, SEC-1).
  request_token "{\"repositories\":[\"$REPO_NAME\"],\"permissions\":$WANT_PERMS}"
  local obs=inconclusive
  if [[ "$REQ_TOKEN" == yes ]]; then
    # Whatever GitHub issued, in any form (round 33, C1).
    obs=allowed
    revoke_token || true
  elif [[ "$LAST_HTTP" =~ ^2 ]]; then obs=allowed
  elif [[ "$LAST_HTTP" =~ ^(401|403|404)$ ]] && ! printf '%s' "$REQ_ANSWER" | grep -Ei 'rate limit|abuse detection' >/dev/null; then obs=refused
  fi
  # As in key-check (round 61, C1): reported whole, then the step stops at once.
  if [[ "$REQ_UNRECEIVED" == yes ]]; then
    report_unreceived
    die "the token request got no usable answer (HTTP ${LAST_HTTP:-none}): GitHub may have issued a token this run never received; the step stops"
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
    exact-protection) cmd_exact_protection ;;
    *) die "usage: github-throwaway.sh create|create-second|check-app|rate|allowance|reset|protect|unprotect|ruleset|tests <phase>|ptests|a2-probe|env-setup|env-tests|hold-token <name>|token-age-check|key-check|suspend-check|unsuspend-check|uninstall-check|delete-check|actions-setting|status|exact-protection" ;;
  esac
}

# Run main when executed as a file or as `bash -p -c "<this script>" frg26 <command>` (the
# handoffs), but not when a test sources it.
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
