#!/usr/bin/env bash
# Tests for FRG-26 stage 1's tests/permissions/github-throwaway.sh, without GitHub: its guards,
# the expected-results table, how attempts are judged, token redaction and how it hands each
# identity to gh and git. Fake gh and git on PATH record what they're given; nothing reaches the
# network. The GitHub behaviour itself is tested only by the owner's handoff, on the throwaway
# repository.
# shellcheck disable=SC2031 # each test sets and reads T_TMP inside its own subshell (assert.sh)
# shellcheck disable=SC2034,SC2329 # variables and stand-in functions are read by the sourced script
# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

GT="$(cd "$(dirname "$0")/.." && pwd)/permissions/github-throwaway.sh"

# A fake classic token, built at run time so no token-shaped text sits in the repository.
fake_token() { printf 'gh%s_%s' p "$(printf 'Z%.0s' $(seq 1 36))"; }

load() { # source the script (main doesn't run when sourced)
  # shellcheck source=tests/permissions/github-throwaway.sh
  source "$GT"
}

fake_tools() { # gh and git that log their arguments and identity-related environment
  mkdir -p "$T_TMP/bin"
  cat >"$T_TMP/bin/gh" <<'EOF'
#!/bin/bash
{
  printf 'gh-args:%s\n' "$*"
  printf 'gh-token-set:%s\n' "${GH_TOKEN:+yes}"
  printf 'gh-github-token-set:%s\n' "${GITHUB_TOKEN:+yes}"
  printf 'gh-config-dir:%s\n' "${GH_CONFIG_DIR:-}"
} >>"$FAKE_LOG"
case "$*" in
  "api user --jq .login") printf '%s\n' "${FAKE_LOGIN:-someone}" ;;
  *) printf 'error: token %s rejected\n' "${GH_TOKEN:-none}" >&2; exit 1 ;;
esac
EOF
  cat >"$T_TMP/bin/git" <<'EOF'
#!/bin/bash
{
  printf 'git-args:%s\n' "$*"
  printf 'git-global:%s nosystem:%s prompt:%s askpass:%s home:%s\n' "${GIT_CONFIG_GLOBAL:-}" "${GIT_CONFIG_NOSYSTEM:-}" "${GIT_TERMINAL_PROMPT:-}" "${GIT_ASKPASS:+set}" "${HOME:-}"
  printf 'git-leaked:%s%s%s\n' "${GIT_COMMON_DIR:-}" "${GIT_TEMPLATE_DIR:-}" "${GIT_DIR:-}"
} >>"$FAKE_LOG"
EOF
  chmod +x "$T_TMP/bin/gh" "$T_TMP/bin/git"
  export FAKE_LOG="$T_TMP/fake.log"
  : >"$FAKE_LOG"
  PATH="$T_TMP/bin:$PATH"
}

secrets() { # <login> <token> [mode]
  printf 'HELPER_LOGIN=%s\nHELPER_TOKEN=%s\n' "$1" "$2" >"$T_TMP/helper.env"
  chmod "${3:-600}" "$T_TMP/helper.env"
  export FRG26_SECRETS="$T_TMP/helper.env"
}

# These run the real script. They stay offline even if the agent guard were broken: an empty
# environment and an empty home folder, so gh has no login (and no config) to use and stops
# before contacting GitHub.
offline() { /usr/bin/env -i HOME="$T_TMP/home" XDG_CONFIG_HOME="$T_TMP/home/.config" PATH=/usr/bin:/bin "$@"; }

test_refuses_inside_claude_code() {
  mkdir -p "$T_TMP/home"
  local out rc=0
  out="$(offline CLAUDECODE=1 /bin/bash "$GT" status 2>&1)" || rc=$?
  assert_exit 2 "$rc"
  assert_contains "$out" "never inside Claude Code"
}

test_main_runs_when_given_as_a_string() {
  # The handoffs run the script as `bash -p -c "<script>" frg26 <command>`: main must run then
  # (shown here by the agent guard answering, before anything else happens).
  mkdir -p "$T_TMP/home"
  local out rc=0
  out="$(offline CLAUDECODE=1 /bin/bash -p -c "$(cat "$GT")" frg26 status 2>&1)" || rc=$?
  assert_exit 2 "$rc"
  assert_contains "$out" "never inside Claude Code"
}

test_script_survives_the_launchers_round_trip() {
  # The handoffs hash printf '%s\n' "$(the blob)": that must equal the file's own sha256, which
  # holds when the file has no NUL byte and ends with exactly one newline.
  local direct trip
  direct="$(shasum -a 256 <"$GT" | cut -d' ' -f1)"
  trip="$(printf '%s\n' "$(cat "$GT")" | shasum -a 256 | cut -d' ' -f1)"
  assert_eq "$trip" "$direct" "sha256 after the launcher's round trip"
  assert_eq "$(tr -d '\000' <"$GT" | wc -c | tr -d ' ')" "$(wc -c <"$GT" | tr -d ' ')" "a NUL byte"
}

test_sourcing_does_not_run_main() {
  local out rc=0
  out="$(CLAUDECODE=1 bash -c 'source "$1"; echo sourced-ok' _ "$GT" 2>&1)" || rc=$?
  assert_exit 0 "$rc"
  assert_contains "$out" "sourced-ok"
}

test_expected_table_matches_the_plan() {
  load
  local id
  for id in B1 B2 B3 B4a B4b B6 B7 B8 B9 B10 B14a B14b M1 M3 M5a M5b; do
    assert_eq "$(expect "$id" open)" allowed "$id open"
    assert_eq "$(expect "$id" protected)" refused "$id protected"
    assert_eq "$(expect "$id" ruleset)" refused "$id ruleset"
  done
  for id in B5 B12 B13 M4; do
    assert_eq "$(expect "$id" open)" refused "$id open (GitHub's fixed rule)"
    assert_eq "$(expect "$id" ruleset)" refused "$id ruleset"
  done
  for id in B16 M6; do
    assert_eq "$(expect "$id" open)" allowed "$id open (control)"
    assert_eq "$(expect "$id" protected)" allowed "$id protected (control)"
    assert_eq "$(expect "$id" ruleset)" allowed "$id ruleset (control)"
  done
  assert_eq "$(expect B11 open)" allowed "B11 open"
  assert_eq "$(expect B11 protected)" refused "B11 protected"
  # M2 is the gap the ruleset closes: allowed with protection alone, refused with the ruleset.
  assert_eq "$(expect M2 open)" allowed "M2 open"
  assert_eq "$(expect M2 protected)" allowed "M2 protected"
  assert_eq "$(expect M2 ruleset)" refused "M2 ruleset"
}

test_every_test_in_the_run_has_an_expectation() {
  # The ids cmd_tests runs are exactly the ones the table above covers, each one a function.
  load
  local ran id
  # shellcheck disable=SC2086 # one id per line
  ran="$(printf '%s\n' $TEST_ORDER | LC_ALL=C sort | tr '\n' ' ')"
  assert_eq "$ran" "B1 B10 B11 B12 B13 B14a B14b B16 B2 B3 B4a B4b B5 B6 B7 B8 B9 M1 M2 M3 M4 M5a M5b M6 "
  for id in $TEST_ORDER; do assert_eq "$(type -t "t_$id")" function "t_$id"; done
  assert_eq "$TEST_ORDER" "$ALL_TESTS" "the stand-ins below cover the same tests in the same order"
}

test_names_carry_a_per_run_id() {
  # Branch and file names must differ between runs, even at the same time on another day.
  load
  RUN_ID="20261020T101010Z-111"
  assert_eq "$(stamp)" "20261020T101010Z-111"
  # shellcheck disable=SC2016 # the literal source text is what's searched for
  assert_contains "$(grep -F 'RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"' "$GT")" 'RUN_ID=' "cmd_tests sets a dated, per-process run id"
}

test_record_judges_results() {
  load
  PHASE=protected
  FAILS=0
  local out
  out="$(record B1 refused "GH006"; echo "fails=$FAILS")"
  assert_contains "$out" "RESULT B1 protected PASS"
  assert_contains "$out" "fails=0"
  out="$(record B1 allowed "pushed"; echo "fails=$FAILS")"
  assert_contains "$out" "RESULT B1 protected FAIL"
  # Inconclusive is never a pass.
  PHASE=open
  out="$(record B11 inconclusive "HTTP 503"; echo "fails=$FAILS")"
  assert_contains "$out" "RESULT B11 open FAIL"
  assert_contains "$out" "fails=1"
  PHASE=protected
  out="$(setup_fail B8 "could not advance dev"; echo "fails=$FAILS")"
  assert_contains "$out" "RESULT B8 protected FAIL"
  assert_contains "$out" "observed=setup-failed"
}

# Every test cmd_tests runs, in its order. stub_phase replaces each one with a stand-in that logs
# its name and, for the ids given, records a result as the real test would.
ALL_TESTS="B5 B1 B2 B3 B4a B4b B6 B7 B8 B9 B10 B11 B12 B13 B16 M1 M2 M3 M4 M6 B14a B14b M5a M5b"

stub_phase() { # <id:allowed|refused|setup>...
  load
  need_owner() { :; }
  load_helper() { :; }
  need_helper_identity() { :; }
  assert_throwaway() { :; }
  verify_phase() { :; }
  need_allowance() { :; }
  helper_git() { :; }
  helper_rate() { return 1; }
  owner_gh() { :; } # no open PRs, nothing reaches gh
  # The script's exit cleanup removes WORK, so it must not be the folder holding the logs.
  WORK="$T_TMP/work"
  mkdir -p "$WORK"
  local id spec
  for id in $ALL_TESTS; do eval "t_$id() { echo \"RAN $id\"; }"; done
  for spec in "$@"; do
    id="${spec%%:*}"
    case "${spec#*:}" in
      setup) eval "t_$id() { echo \"RAN $id\"; setup_fail $id \"stand-in setup failure\"; }" ;;
      *) eval "t_$id() { echo \"RAN $id\"; record $id ${spec#*:} \"stand-in\"; }" ;;
    esac
  done
}

test_a_failed_test_stops_the_phase() {
  # The plan's stop rule: after a failed test nothing more is changed. B1 unexpectedly gets
  # through in the protected phase, so no test after it may run.
  local out rc=0
  out="$(stub_phase B1:allowed; cmd_tests protected 2>&1)" || rc=$?
  assert_exit 1 "$rc"
  assert_contains "$out" "RAN B5"
  assert_contains "$out" "RESULT B1 protected FAIL"
  assert_not_contains "$out" "RAN B2"
  assert_not_contains "$out" "RAN M5b"
  assert_contains "$out" "PHASE protected: STOPPED after B1"
}

test_a_failed_setup_stops_the_phase() {
  local out rc=0
  out="$(stub_phase B5:setup; cmd_tests ruleset 2>&1)" || rc=$?
  assert_exit 1 "$rc"
  assert_contains "$out" "observed=setup-failed"
  assert_not_contains "$out" "RAN B1"
  assert_contains "$out" "PHASE ruleset: STOPPED after B5"
}

test_a_passing_phase_runs_every_test() {
  local out rc=0 id
  out="$(stub_phase B5:refused M6:allowed; cmd_tests protected 2>&1)" || rc=$?
  assert_exit 0 "$rc"
  for id in $ALL_TESTS; do assert_contains "$out" "RAN $id"; done
  assert_contains "$out" "PHASE protected: ALL PASS"
}

test_admin_attempts_stop_at_the_first_change_that_gets_through() {
  # B12 and M4 try several ways to weaken protection; once one works, the rest must not run.
  load
  PHASE=protected
  FAILS=0
  capture() { echo "CALL $*" >>"$T_TMP/calls"; }
  classify_api() { echo allowed; }
  evidence() { echo "HTTP 200"; }
  local out
  out="$(admin_attempts B12 -X PUT "repos/$REPO/branches/dev/protection" ";;" -X DELETE "repos/$REPO/branches/dev/protection")"
  assert_contains "$out" "RESULT B12 protected FAIL"
  assert_eq "$(wc -l <"$T_TMP/calls" | tr -d ' ')" 1 "attempts made after the first got through"
}

test_b13_changes_nothing_after_its_attempts() {
  # The stop rule: after a failed attempt only test PRs are closed. B13 used to put the repo's
  # description back as the owner, failed or not (round 6, C3). A refused helper changed nothing,
  # and after one that got through the repo is left as it is (the next command's throwaway check
  # then refuses until the owner restores it).
  load
  PHASE=protected
  WORK="$T_TMP/work"
  mkdir -p "$WORK"
  owner_uid() { echo 1; }
  capture() { :; }
  evidence() { echo "stand-in"; }
  owner_gh() { echo "$*" >>"$T_TMP/owner"; }
  local obs
  for obs in allowed refused; do
    : >"$T_TMP/owner"
    FAILS=0
    classify_api() { echo "$obs"; }
    t_B13 >/dev/null
    assert_eq "$(cat "$T_TMP/owner")" "" "owner writes after B13's attempts were $obs"
  done
}

cleanup_gh() { # <states...> — pr_view answers these in turn (none = can't read); closes are logged
  printf '%s\n' "$@" >"$T_TMP/states"
  : >"$T_TMP/closes"
  pr_view() {
    local st
    st="$(head -n 1 "$T_TMP/states")"
    sed -i '' 1d "$T_TMP/states"
    [[ -n "$st" && "$st" != none ]] || return 1
    echo "$st"
  }
  owner_gh() { echo "$*" >>"$T_TMP/closes"; return "${CLOSE_RC:-0}"; }
}

test_a_pr_left_open_is_a_failure() {
  # A test PR must not stay open after its test: it could still merge (B11 arms auto-merge).
  load
  PHASE=protected
  local out rc
  # The close command fails and the PR stays open.
  FAILS=0 rc=0 CLOSE_RC=1
  cleanup_gh OPEN OPEN
  out="$(close_if_open 7; echo "rc=$? fails=$FAILS")"
  assert_contains "$out" "CLEANUP FAIL PR #7"
  assert_contains "$out" "rc=1 fails=1"
  # The close command succeeds but GitHub still reports the PR open.
  CLOSE_RC=0
  cleanup_gh OPEN OPEN
  out="$(close_if_open 7; echo "rc=$? fails=$FAILS")"
  assert_contains "$out" "rc=1 fails=1"
  # The PR's state can't be read.
  cleanup_gh none
  out="$(close_if_open 7; echo "rc=$? fails=$FAILS")"
  assert_contains "$out" "state unreadable"
  assert_contains "$out" "rc=1 fails=1"
}

test_a_closed_or_merged_pr_needs_no_cleanup() {
  load
  PHASE=protected
  local out st
  FAILS=0 CLOSE_RC=0
  cleanup_gh OPEN CLOSED
  out="$(close_if_open 7; echo "rc=$? fails=$FAILS")"
  assert_contains "$out" "rc=0 fails=0"
  assert_contains "$(cat "$T_TMP/closes")" "pr close 7"
  for st in CLOSED MERGED; do
    cleanup_gh "$st"
    out="$(close_if_open 7; echo "rc=$? fails=$FAILS")"
    assert_contains "$out" "rc=0 fails=0" "$st"
    assert_eq "$(wc -l <"$T_TMP/closes" | tr -d ' ')" 0 "a close for a $st PR"
  done
}

test_a_failed_cleanup_stops_the_phase() {
  local out rc=0
  # B5 passes, but its PR's state can't be read afterwards: the phase stops there.
  out="$(stub_phase; cleanup_gh none; t_B5() { echo "RAN B5"; record B5 refused "stand-in"; close_if_open 9; }; cmd_tests protected 2>&1)" || rc=$?
  assert_exit 1 "$rc"
  assert_contains "$out" "RESULT B5 protected PASS"
  assert_contains "$out" "CLEANUP FAIL PR #9"
  assert_not_contains "$out" "RAN B1"
  assert_contains "$out" "STOPPED after B5"
}

sweep_gh() { # <open PRs as JSON, or fail> <states...> — the PR list gh would give (filtered with
  # the script's own --jq, its last argument), plus cleanup_gh's states and logged closes
  SWEEP_LIST="$1"
  shift
  cleanup_gh "$@"
  owner_gh() {
    case "$1 $2" in
      "pr list")
        echo listed >>"$T_TMP/lists"
        [[ "$SWEEP_LIST" != fail ]] || return 1
        printf '%s' "$SWEEP_LIST" | jq -r "${@: -1}"
        ;;
      *) echo "$*" >>"$T_TMP/closes" ;;
    esac
  }
}

test_a_stopped_phase_closes_every_open_test_pr() {
  # B16's dev-advance merge fails, leaving its approved PR (77) open, and an earlier PR whose URL
  # couldn't be read (78) is open too. Both are closed before the phase stops; a PR that isn't a
  # FRG-26 test PR is left alone.
  local out rc=0 list
  list='[{"number":77,"title":"FRG-26 B16-advance (protected)"},{"number":78,"title":"FRG-26 B9 (protected)"},{"number":5,"title":"Someone else"}]'
  out="$(stub_phase B16:setup; sweep_gh "$list" OPEN CLOSED OPEN CLOSED; cmd_tests protected 2>&1)" || rc=$?
  assert_exit 1 "$rc"
  assert_contains "$out" "STOPPED after B16"
  assert_contains "$(cat "$T_TMP/closes")" "pr close 77"
  assert_contains "$(cat "$T_TMP/closes")" "pr close 78"
  assert_not_contains "$(cat "$T_TMP/closes")" "pr close 5"
  assert_not_contains "$out" "CLEANUP FAIL"
}

test_a_stopped_phase_reports_a_test_pr_it_cant_close() {
  local out rc=0
  out="$(stub_phase B16:setup; sweep_gh '[{"number":77,"title":"FRG-26 B16-advance (protected)"}]' OPEN OPEN; cmd_tests protected 2>&1)" || rc=$?
  assert_exit 1 "$rc"
  assert_contains "$out" "CLEANUP FAIL PR #77"
  assert_contains "$out" "STOPPED after B16"
}

test_a_passing_phase_ends_with_no_test_pr_open() {
  local out rc=0
  # A test PR still open at the end is closed; the phase passes only once it's confirmed closed.
  out="$(stub_phase; sweep_gh '[{"number":9,"title":"FRG-26 B5 (ruleset)"}]' OPEN CLOSED; cmd_tests ruleset 2>&1)" || rc=$?
  assert_exit 0 "$rc"
  assert_contains "$out" "closed test PR #9"
  assert_contains "$out" "PHASE ruleset: ALL PASS"
  # It can't be closed: the phase fails.
  rc=0
  out="$(stub_phase; sweep_gh '[{"number":9,"title":"FRG-26 B5 (ruleset)"}]' OPEN OPEN; cmd_tests ruleset 2>&1)" || rc=$?
  assert_exit 1 "$rc"
  assert_contains "$out" "CLEANUP FAIL PR #9"
  assert_not_contains "$out" "ALL PASS"
  # The open PRs can't be listed: the phase fails.
  rc=0
  out="$(stub_phase; sweep_gh fail; cmd_tests ruleset 2>&1)" || rc=$?
  assert_exit 1 "$rc"
  assert_contains "$out" "could not list the open PRs"
  assert_not_contains "$out" "ALL PASS"
}

test_an_error_stop_mid_phase_closes_every_open_test_pr() {
  # B11 arms auto-merge, then the owner's approval fails and the script stops with an error
  # (die): the exit itself still closes the armed PR, and no later test runs.
  local out rc=0
  out="$(stub_phase; sweep_gh '[{"number":77,"title":"FRG-26 B11 (protected)"}]' OPEN CLOSED
    t_B11() { echo "RAN B11"; die "the owner could not approve PR #77"; }
    cmd_tests protected 2>&1)" || rc=$?
  assert_exit 2 "$rc"
  assert_contains "$out" "could not approve PR #77"
  assert_not_contains "$out" "RAN B12"
  assert_contains "$(cat "$T_TMP/closes")" "pr close 77"
  assert_contains "$out" "PHASE protected: STOPPED by an error"
  assert_not_contains "$out" "ALL PASS"
}

test_an_error_stop_reports_a_test_pr_it_cant_close() {
  local out rc=0
  out="$(stub_phase; sweep_gh '[{"number":77,"title":"FRG-26 B11 (protected)"}]' OPEN OPEN
    t_B11() { die "the owner could not approve PR #77"; }
    cmd_tests protected 2>&1)" || rc=$?
  assert_exit 2 "$rc"
  assert_contains "$out" "CLEANUP FAIL PR #77"
}

test_an_error_before_the_phase_starts_closes_nothing() {
  # Until the tests start, the script has opened no PR, so an error then sweeps nothing.
  local out rc=0
  : >"$T_TMP/lists"
  out="$(stub_phase; sweep_gh '[{"number":77,"title":"FRG-26 B11 (protected)"}]' OPEN CLOSED
    verify_phase() { die "dev is not protected as the phase needs"; }
    cmd_tests protected 2>&1)" || rc=$?
  assert_exit 2 "$rc"
  assert_eq "$(wc -l <"$T_TMP/lists" | tr -d ' ')" 0 "PR lists read"
  assert_not_contains "$out" "STOPPED by an error"
}

test_a_phase_sweeps_once() {
  # A failed test and a passing phase each sweep once, not again on exit.
  local out rc=0
  : >"$T_TMP/lists"
  out="$(stub_phase B1:allowed; sweep_gh '[]'; cmd_tests protected 2>&1)" || rc=$?
  assert_exit 1 "$rc"
  assert_eq "$(wc -l <"$T_TMP/lists" | tr -d ' ')" 1 "PR lists read after a failed test"
  : >"$T_TMP/lists"
  rc=0
  out="$(stub_phase; sweep_gh '[]'; cmd_tests protected 2>&1)" || rc=$?
  assert_exit 0 "$rc"
  assert_eq "$(wc -l <"$T_TMP/lists" | tr -d ' ')" 1 "PR lists read after a passing phase"
}

status_gh() { # <dev protected?> — a stand-in owner_gh for cmd_status; other reads fail
  STATUS_DEV="$1"
  owner_gh() {
    case "$*" in
      "api repos/$REPO/branches/dev --jq .protected") echo "$STATUS_DEV" ;;
      "api repos/$REPO/branches/main --jq .protected") echo false ;;
      "api repos/$REPO/rulesets --jq length") echo 0 ;;
      "api repos/$REPO --jq .default_branch") echo side ;;
      *) echo "gh: Not Found (HTTP 404)" >&2; return 1 ;;
    esac
  }
}

test_status_reports_an_unprotected_repository() {
  load
  need_owner() { :; }
  assert_throwaway() { :; }
  status_gh false
  local out rc=0
  out="$(cmd_status 2>&1)" || rc=$?
  assert_exit 0 "$rc"
  assert_contains "$out" "dev: unprotected"
  assert_contains "$out" "default branch: side"
}

test_status_fails_when_a_read_fails() {
  load
  need_owner() { :; }
  assert_throwaway() { :; }
  local out rc=0
  # dev's state can't be read at all.
  status_gh unreadable
  out="$(cmd_status 2>&1)" || rc=$?
  assert_exit 2 "$rc"
  assert_contains "$out" "could not read"
  # dev reads as protected, but its protection can't be read.
  rc=0
  status_gh true
  out="$(cmd_status 2>&1)" || rc=$?
  assert_exit 2 "$rc"
  # Nothing can be read.
  rc=0
  owner_gh() { return 1; }
  out="$(cmd_status 2>&1)" || rc=$?
  assert_exit 2 "$rc"
}

test_classify_push() {
  load
  LAST_RC=0 LAST_OUT="ok"
  assert_eq "$(classify_push)" allowed
  LAST_RC=1 LAST_OUT="remote: error: GH006: Protected branch update failed for refs/heads/dev."
  assert_eq "$(classify_push)" refused "GH006"
  LAST_RC=1 LAST_OUT="remote: error: GH013: Repository rule violations found for refs/heads/main."
  assert_eq "$(classify_push)" refused "GH013"
  LAST_RC=128 LAST_OUT="fatal: unable to access 'https://github.com/x/y.git/': Could not resolve host: github.com"
  assert_eq "$(classify_push)" inconclusive "network failure"
  LAST_RC=1 LAST_OUT="remote: Invalid username or token."
  assert_eq "$(classify_push)" inconclusive "bad credentials"
}

test_classify_api() {
  load
  LAST_RC=0 LAST_OUT="{}"
  assert_eq "$(classify_api)" allowed
  LAST_RC=1 LAST_OUT="gh: Not Found (HTTP 404)"
  assert_eq "$(classify_api)" refused "404"
  LAST_RC=1 LAST_OUT="gh: Must have admin rights to Repository. (HTTP 403)"
  assert_eq "$(classify_api)" refused "403"
  LAST_RC=1 LAST_OUT="gh: Validation Failed (HTTP 422)"
  assert_eq "$(classify_api)" inconclusive "422 is not an authorisation refusal"
  LAST_RC=1 LAST_OUT="HTTP 503 Service Unavailable"
  assert_eq "$(classify_api)" inconclusive "503"
  LAST_RC=1 LAST_OUT="gh: API rate limit exceeded for user ID 1. (HTTP 403)"
  assert_eq "$(classify_api)" inconclusive "a rate-limit 403 is not a permission refusal"
  LAST_RC=1 LAST_OUT="gh: You have exceeded a secondary rate limit. (HTTP 403)"
  assert_eq "$(classify_api)" inconclusive "secondary rate limit"
}

test_b11_open_needs_a_confirmed_result() {
  load
  PHASE=open
  FAILS=0
  feature_pr() { LAST_PR=7; }
  wait_settled() { return 0; }
  sleep() { :; }
  close_if_open() { :; }
  helper_gh() { echo "HTTP 503 Service Unavailable" >&2; return 1; }
  pr_view() { return 1; }
  local out
  out="$(t_B11; echo "fails=$FAILS")"
  assert_contains "$out" "RESULT B11 open FAIL" "unreadable state passed"
  assert_contains "$out" "observed=inconclusive"
  pr_view() { case "$2" in state) echo OPEN ;; autoMergeRequest) echo true ;; esac; }
  out="$(t_B11; echo "fails=$FAILS")"
  assert_contains "$out" "RESULT B11 open PASS expected=allowed observed=allowed"
}

test_b9_reaims_through_the_rest_api() {
  # The helper's token has only public_repo. `gh pr edit` also reads fields that need read:org,
  # so it failed on GitHub (owner's run, 2026-10-20). The REST call needs public_repo alone.
  load
  PHASE=open
  FAILS=0
  feature_pr() { LAST_PR=7; }
  owner_approve() { :; }
  sleep() { :; }
  close_if_open() { :; }
  helper_merge() { OBS=allowed; LAST_OUT=merged; }
  helper_gh() { printf '%s\n' "$*" >>"$T_TMP/helper-gh.log"; }
  pr_view() { echo "$FAKE_BASE"; }
  local out
  FAKE_BASE=dev
  out="$(t_B9; echo "fails=$FAILS")"
  assert_eq "$(cat "$T_TMP/helper-gh.log")" "api -X PATCH repos/$REPO/pulls/7 -f base=dev"
  assert_contains "$out" "RESULT B9 open PASS expected=allowed observed=allowed"
  # A re-aim GitHub didn't apply is a broken setup, not a result.
  FAKE_BASE=side
  out="$(t_B9; echo "fails=$FAILS")"
  assert_contains "$out" "RESULT B9 open FAIL"
  assert_contains "$out" "observed=setup-failed"
  # A refused re-aim never tries the merge B9 is about: setup-failed, never a protected PASS.
  PHASE=protected
  FAKE_BASE=dev
  helper_gh() { echo "gh: Resource not accessible by personal access token (HTTP 403)" >&2; return 1; }
  out="$(t_B9; echo "fails=$FAILS")"
  assert_contains "$out" "RESULT B9 protected FAIL"
  assert_contains "$out" "observed=setup-failed"
}

test_helper_never_uses_gh_pr_edit() {
  # Same reason as above, for every test: the helper's gh must not run `pr edit`.
  assert_eq "$(grep -c 'helper_gh pr edit' "$GT" || true)" "0" "helper_gh pr edit needs read:org"
}

rate_fixture() { # <graphql remaining>
  printf '{"resources":{"core":{"limit":5000,"used":12,"remaining":4988,"reset":1792540800},"graphql":{"limit":5000,"used":%s,"remaining":%s,"reset":1792540800}}}' \
    "$((5000 - $1))" "$1"
}

test_helper_rate_reads_the_allowance() {
  # The owner's runs stopped on "GraphQL: API rate limit already exceeded" for the helper:
  # the script must be able to show the helper's allowance (GitHub doesn't count that request).
  load
  helper_gh() { printf '%s\n' "$*" >>"$T_TMP/helper-gh.log"; rate_fixture 10; }
  helper_rate || _t_fail "a valid allowance was not read"
  assert_eq "$(cat "$T_TMP/helper-gh.log")" "api rate_limit"
  assert_eq "$RATE_LEFT" 10
  assert_contains "$RATE_LINE" "graphql limit=5000 used=4990 remaining=10 resets=2026-10-21T00:00:00Z"
  assert_contains "$RATE_LINE" "rest limit=5000 used=12 remaining=4988"
  helper_gh() { echo "HTTP 503" >&2; return 1; }
  if helper_rate; then _t_fail "an unreadable allowance was accepted"; fi
}

test_a_phase_needs_enough_helper_allowance() {
  # A phase that would run out halfway stops before its first test, naming the reset time.
  load
  local out rc
  helper_gh() { rate_fixture 10; }
  rc=0; out="$( need_allowance 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "10 points left"
  assert_contains "$out" "only 10 GraphQL points left"
  assert_contains "$out" "resets=2026-10-21T00:00:00Z"
  helper_gh() { echo "HTTP 503" >&2; return 1; }
  rc=0; out="$( need_allowance 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "unreadable allowance"
  helper_gh() { rate_fixture 4000; }
  rc=0; out="$( need_allowance 2>&1 )" || rc=$?
  assert_exit 0 "$rc" "4000 points left"
  assert_contains "$out" "helper allowance: graphql limit=5000 used=1000 remaining=4000"
}

test_a_phase_needs_enough_rest_allowance_too() {
  # Round 7 C1: the helper's REST requests run out too; GraphQL to spare is not enough.
  load
  local out rc
  helper_gh() { printf '{"resources":{"core":{"limit":5000,"used":5000,"remaining":0,"reset":1792540800},"graphql":{"limit":5000,"used":0,"remaining":5000,"reset":1792540800}}}'; }
  rc=0; out="$( need_allowance 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "0 REST requests left"
  assert_contains "$out" "only 0 REST requests left"
  helper_gh() { printf '{"resources":{"graphql":{"limit":5000,"used":0,"remaining":5000,"reset":1792540800}}}'; }
  rc=0; out="$( need_allowance 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "no REST allowance in the answer"
}

# GitHub's answers for the protection `protect` applies, as read from the throwaway on 2026-10-31.
protection_fixture() { # <dev|main>
  local ea=false
  [[ "$1" == dev ]] && ea=true
  printf '{"url":"https://api.github.com/repos/Thebigtuna88/forge-frg26-throwaway/branches/%s/protection","required_pull_request_reviews":{"url":"https://api.github.com/repos/Thebigtuna88/forge-frg26-throwaway/branches/%s/protection/required_pull_request_reviews","dismiss_stale_reviews":true,"require_code_owner_reviews":true,"require_last_push_approval":true,"required_approving_review_count":1},"required_signatures":{"url":"https://api.github.com/repos/Thebigtuna88/forge-frg26-throwaway/branches/%s/protection/required_signatures","enabled":false},"enforce_admins":{"url":"https://api.github.com/repos/Thebigtuna88/forge-frg26-throwaway/branches/%s/protection/enforce_admins","enabled":%s},"required_linear_history":{"enabled":false},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false},"block_creations":{"enabled":false},"required_conversation_resolution":{"enabled":false},"lock_branch":{"enabled":false},"allow_fork_syncing":{"enabled":false}}\n' "$1" "$1" "$1" "$1" "$ea"
}

protection_gh() { # owner_gh answering protection reads from $T_TMP/<branch>.json; other calls logged
  protection_fixture dev >"$T_TMP/dev.json"
  protection_fixture main >"$T_TMP/main.json"
  : >"$T_TMP/owner"
  branch_state() { echo protected; }
  ruleset_count() { echo 0; }
  owner_gh() {
    local f=""
    case "$*" in
      "api repos/$REPO/branches/dev/protection"*) f=dev ;;
      "api repos/$REPO/branches/main/protection"*) f=main ;;
    esac
    if [[ -z "$f" ]]; then echo "$*" >>"$T_TMP/owner"; return 0; fi
    if [[ "${3:-}" == --jq ]]; then jq -r "$4" "$T_TMP/$f.json"; else cat "$T_TMP/$f.json"; fi
  }
}

test_protected_means_exactly_what_protect_applies() {
  # Round 7 C2: a protection with anything more (or less) than protect's settings is not the
  # protected state: no phase runs on it, and unprotect doesn't delete it.
  load
  protection_gh
  local rc out
  rc=0; (verify_phase protected) >/dev/null 2>&1 || rc=$?
  assert_exit 0 "$rc" "protect's own settings"
  jq -c '. + {required_status_checks: {strict: true, contexts: ["owner-extra-check"]}}' "$T_TMP/dev.json" >"$T_TMP/x" && mv "$T_TMP/x" "$T_TMP/dev.json"
  rc=0; out="$(verify_phase protected 2>&1)" || rc=$?
  assert_exit 2 "$rc" "an extra required check on dev"
  assert_contains "$out" "dev protection is not exactly what protect applies"
  need_owner() { :; }
  assert_throwaway() { :; }
  rc=0; (cmd_unprotect) >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "unprotect with an extra required check"
  assert_eq "$(cat "$T_TMP/owner")" "" "deletes with an extra required check"
  protection_fixture main | jq -c 'del(.lock_branch)' >"$T_TMP/main.json"
  protection_fixture dev >"$T_TMP/dev.json"
  rc=0; out="$(verify_phase protected 2>&1)" || rc=$?
  assert_exit 2 "$rc" "a setting missing on main"
  assert_contains "$out" "main protection is not exactly what protect applies"
}

owner_cmd_stubs() { # an owner command's checks pass; its gh calls are logged to $T_TMP/owner
  load
  need_owner() { :; }
  assert_throwaway() { :; }
  load_helper() { :; }
  need_helper_identity() { :; }
  owner_uid() { echo 1; }
  owner_gh() { echo "$*" >>"$T_TMP/owner"; }
  WORK="$T_TMP/work"
  mkdir -p "$WORK"
  : >"$T_TMP/owner"
}

test_ruleset_needs_enough_helper_allowance_before_it_changes_anything() {
  # The phase after the ruleset needs the helper's allowance; if it is short, the ruleset must
  # not be added (it would sit there untested). Round 6, owner: executable and fail-closed.
  owner_cmd_stubs
  verify_phase() { :; }
  local out rc
  helper_gh() { rate_fixture 10; }
  rc=0; out="$(cmd_ruleset 2>&1)" || rc=$?
  assert_exit 2 "$rc" "10 points left"
  assert_contains "$out" "only 10 GraphQL points left"
  assert_eq "$(cat "$T_TMP/owner")" "" "owner calls with 10 points left"
  helper_gh() { echo "HTTP 503" >&2; return 1; }
  rc=0; out="$(cmd_ruleset 2>&1)" || rc=$?
  assert_exit 2 "$rc" "unreadable allowance"
  assert_eq "$(cat "$T_TMP/owner")" "" "owner calls with an unreadable allowance"
  helper_gh() { rate_fixture 4000; }
  rc=0; out="$(cmd_ruleset 2>&1)" || rc=$?
  assert_contains "$(cat "$T_TMP/owner")" "api -X POST repos/$REPO/rulesets"
}

test_ruleset_falls_back_only_after_a_clear_rejection() {
  # Round 8 C1: a lost answer after GitHub created the ruleset must not lead to a second one. The
  # Repository admin form is tried only when GitHub rejected the User form as invalid (HTTP 422)
  # and there is still no ruleset.
  owner_cmd_stubs
  verify_phase() { :; }
  helper_gh() { rate_fixture 4000; }
  owner_gh() {
    case "$*" in
      *"-X POST repos/$REPO/rulesets"*)
        echo "$*" >>"$T_TMP/owner"
        if [[ "$(grep -c 'X POST' "$T_TMP/owner")" == 1 ]]; then echo "$FIRST_ERR" >&2; return 1; fi
        ;;
    esac
  }
  local case_ err count rc posts
  for case_ in "gh: HTTP 502 Bad Gateway|0|2|1" "gh: Validation Failed (HTTP 422)|1|2|1" \
    "gh: Validation Failed (HTTP 422)|error|2|1" "gh: Validation Failed (HTTP 422)|0|0|2"; do
    IFS='|' read -r err count rc posts <<<"$case_"
    FIRST_ERR="$err"
    eval "ruleset_count() { echo $count; }"
    : >"$T_TMP/owner"
    local got=0
    (cmd_ruleset) >/dev/null 2>&1 || got=$?
    assert_exit "$rc" "$got" "first answer '$err', rulesets after it: $count"
    assert_eq "$(grep -c 'X POST' "$T_TMP/owner")" "$posts" "ruleset requests after '$err' with $count rulesets"
  done
}

test_allowance_check_fails_closed() {
  owner_cmd_stubs
  local out rc
  helper_gh() { rate_fixture 10; }
  rc=0; out="$(cmd_allowance 2>&1)" || rc=$?
  assert_exit 2 "$rc" "10 points left"
  helper_gh() { echo "HTTP 503" >&2; return 1; }
  rc=0; out="$(cmd_allowance 2>&1)" || rc=$?
  assert_exit 2 "$rc" "unreadable allowance"
  helper_gh() { rate_fixture 4000; }
  rc=0; out="$(cmd_allowance 2>&1)" || rc=$?
  assert_exit 0 "$rc" "4000 points left"
  assert_contains "$out" "helper allowance: graphql limit=5000 used=1000 remaining=4000"
}

test_unprotect_lifts_exactly_what_protect_applies() {
  # The fresh open phase (owner, 2026-10-31) starts from the protected state the throwaway is in:
  # unprotect only runs from exactly that state, removes both protections, and checks the result.
  owner_cmd_stubs
  verify_phase() { echo "verify $1" >>"$T_TMP/owner"; }
  local rc=0
  cmd_unprotect >/dev/null 2>&1 || rc=$?
  assert_exit 0 "$rc"
  assert_eq "$(cat "$T_TMP/owner")" "verify protected
api -X DELETE repos/$REPO/branches/dev/protection
api -X DELETE repos/$REPO/branches/main/protection
verify open"
  : >"$T_TMP/owner"
  verify_phase() { die "phase $1 needs dev and main protected"; }
  rc=0
  (cmd_unprotect) >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "not in the protected state"
  assert_eq "$(cat "$T_TMP/owner")" "" "owner calls outside the protected state"
}

fake_diag_gh() { # stands in for helper_gh: logs its arguments, answers like `gh api -i`
  printf '%s\n' "$*" >>"$T_TMP/helper-gh.log"
  case "$*" in
    "api -i user")
      printf 'HTTP/2.0 200 OK\r\nAuthorization: token %s\r\nSet-Cookie: s=1\r\nX-Oauth-Scopes: public_repo\r\nX-Ratelimit-Limit: 60\r\nX-Ratelimit-Remaining: 52\r\nX-Ratelimit-Resource: core\r\nX-Github-Request-Id: AB:CD\r\n\r\n{"login":"TTHelper","id":345506119}\n' "$TOKEN" ;;
    "api -i rate_limit")
      printf 'HTTP/2.0 200 OK\r\nX-Ratelimit-Limit: 60\r\n\r\n%s\n' "$(rate_fixture 0)" ;;
    "api -i graphql "*)
      printf 'HTTP/2.0 403 Forbidden\r\nX-Ratelimit-Limit: 0\r\nX-Ratelimit-Resource: graphql\r\n\r\n{"errors":[{"type":"RATE_LIMITED","message":"API rate limit already exceeded for user ID 345506119."}]}\ngh: API rate limit already exceeded for user ID 345506119.\n'
      return 1 ;;
  esac
}

test_diagnose_records_statuses_headers_and_messages_only() {
  # The owner asked: authenticate exactly as the tests do, then record HTTP statuses, rate-limit
  # headers and GitHub's messages for GET /user, GET /rate_limit and GraphQL, never the token
  # or an Authorization header.
  load
  TOKEN="$(fake_token)"
  HELPER=TTHelper
  load_helper() { :; }
  helper_gh() { fake_diag_gh "$@"; }
  local out
  out="$(cmd_diagnose 2>&1)"
  assert_eq "$(sed -n 1,2p "$T_TMP/helper-gh.log")" "$(printf 'api -i user\napi -i rate_limit')"
  assert_contains "$(sed -n 3p "$T_TMP/helper-gh.log")" "api -i graphql -f query="
  assert_contains "$out" "DIAG GET /user: exit=0 HTTP/2.0 200 OK"
  assert_contains "$out" "x-oauth-scopes: public_repo"
  assert_contains "$out" "x-ratelimit-limit: 60"
  assert_contains "$out" "x-github-request-id: AB:CD"
  assert_contains "$out" "login=TTHelper"
  assert_contains "$out" "DIAG GET /rate_limit: exit=0 HTTP/2.0 200 OK"
  assert_contains "$out" "graphql limit=5000 used=5000 remaining=0"
  assert_contains "$out" "DIAG POST /graphql: exit=1 HTTP/2.0 403 Forbidden"
  assert_contains "$out" "x-ratelimit-resource: graphql"
  assert_contains "$out" "RATE_LIMITED: API rate limit already exceeded for user ID 345506119."
  assert_not_contains "$out" "$TOKEN" "the token"
  assert_not_contains "$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')" "authorization" "an Authorization header"
  assert_not_contains "$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')" "set-cookie" "a header outside the list"
}

test_ruleset_summary_includes_the_update_rules_parameter() {
  load
  owner_gh() {
    local q="" path=""
    while [[ $# -gt 0 ]]; do
      case "$1" in --jq) q="$2"; shift ;; repos/*) path="$1" ;; esac
      shift
    done
    case "$path" in
      */rulesets) jq -r "$q" <<<'[{"id": 9}]' ;;
      */rulesets/9) jq -r "$q" <<<"$FIXTURE" ;;
      *) return 1 ;;
    esac
  }
  owner_uid() { echo 42; }
  FIXTURE='{"enforcement":"active","target":"branch","conditions":{"ref_name":{"include":["refs/heads/main"],"exclude":[]}},"rules":[{"type":"update","parameters":{"update_allows_fetch_and_merge":true}},{"type":"deletion"},{"type":"non_fast_forward"}],"bypass_actors":[{"actor_type":"User","actor_id":42,"bypass_mode":"always"}]}'
  local got
  got="$(ruleset_summary)"
  assert_contains "$got" "update:true"
  if want_ruleset | grep -Fxq -- "$got"; then _t_fail "a ruleset that lets main pull upstream changes was accepted"; fi
  FIXTURE="${FIXTURE/true/false}"
  got="$(ruleset_summary)"
  want_ruleset | grep -Fxq -- "$got" || _t_fail "the installed ruleset was not recognised: $got"
}

test_helper_merge_needs_a_blocked_mergeable_pr_to_count_as_refused() {
  load
  PHASE=protected
  sleep() { :; }
  helper_gh() { echo "X Pull request is not mergeable: the base branch policy prohibits the merge." >&2; return 1; }
  pr_view() {
    case "$2" in
      mergeable) echo MERGEABLE ;;
      *) echo "$FAKE_FACTS" ;;
    esac
  }
  FAKE_FACTS="OPEN MERGEABLE BLOCKED REVIEW_REQUIRED"
  helper_merge B6 7 --squash
  assert_eq "$OBS" refused "blocked by protection"
  FAKE_FACTS="OPEN MERGEABLE CLEAN APPROVED"
  helper_merge B6 7 --squash
  assert_eq "$OBS" inconclusive "open but not blocked: something else went wrong"
  # Blocked on GitHub, but the merge request itself failed for another reason: proves nothing.
  pr_view() {
    case "$2" in
      mergeable) echo MERGEABLE ;;
      *) echo "OPEN MERGEABLE BLOCKED REVIEW_REQUIRED" ;;
    esac
  }
  helper_gh() { echo "HTTP 503 Service Unavailable" >&2; return 1; }
  helper_merge B6 7 --squash
  assert_eq "$OBS" inconclusive "a failed request with a blocked PR"
  helper_gh() { echo "gh: API rate limit exceeded; base branch policy prohibits the merge" >&2; return 1; }
  helper_merge B6 7 --squash
  assert_eq "$OBS" inconclusive "a rate limit with a policy-looking message"
  pr_view() { return 1; }
  helper_merge B6 7 --squash
  assert_eq "$OBS" inconclusive "state unreadable (network)"
  assert_contains "$LAST_OUT" "never settled"
}

test_branch_updated_waits_for_a_head_with_dev_as_parent() {
  load
  sleep() { :; }
  local old=1111111111111111111111111111111111111111 new=2222222222222222222222222222222222222222
  local dev=3333333333333333333333333333333333333333
  pr_view() { echo "$FAKE_HEAD"; }
  owner_gh() { echo "$FAKE_PARENTS"; }
  FAKE_HEAD=$old FAKE_PARENTS=""
  if branch_updated 7 "$old" "$dev"; then _t_fail "accepted an unchanged head"; fi
  FAKE_HEAD=$new FAKE_PARENTS="$old 4444444444444444444444444444444444444444"
  if branch_updated 7 "$old" "$dev"; then _t_fail "accepted a new head without dev as a parent"; fi
  FAKE_HEAD=$new FAKE_PARENTS="$old $dev"
  branch_updated 7 "$old" "$dev" || _t_fail "a head merging dev was not accepted"
}

test_redact_hides_the_token() {
  load
  TOKEN="$(fake_token)"
  local out
  out="$(say "remote said: bad credentials for $TOKEN (again $TOKEN)")"
  assert_not_contains "$out" "$TOKEN"
  assert_contains "$out" "[REDACTED]"
  out="$( die "oops $TOKEN" 2>&1 )" || true
  assert_not_contains "$out" "$TOKEN" "die redacts too"
}

test_load_helper_accepts_a_classic_token() {
  load
  secrets frg-helper "$(fake_token)"
  SECRETS="$FRG26_SECRETS"
  ( load_helper token ) || _t_fail "a valid login and classic token were refused"
}

test_load_helper_refusals() {
  load
  local out rc
  secrets frg-helper "$(fake_token)" 644
  SECRETS="$FRG26_SECRETS"
  rc=0; out="$( load_helper token 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "mode 644"
  assert_contains "$out" "must be mode 600"

  secrets frg-helper "github_pat_$(printf 'Y%.0s' $(seq 1 40))"
  rc=0; out="$( load_helper token 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "fine-grained token"
  assert_contains "$out" "not a classic token"

  secrets thebigtuna88 "$(fake_token)"
  rc=0; out="$( load_helper token 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "owner as helper"
  assert_contains "$out" "must not be the owner"

  secrets 'bad;name' "$(fake_token)"
  rc=0; out="$( load_helper token 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "invalid login"

  secrets frg-helper "$(fake_token)"
  chmod 755 "$T_TMP"
  rc=0; out="$( load_helper token 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "secrets folder not mode 700"
  assert_contains "$out" "must be mode 700"
  chmod 700 "$T_TMP"

  rm -f "$T_TMP/helper.env"
  ln -s /etc/hosts "$T_TMP/helper.env"
  rc=0; out="$( load_helper token 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "symlinked secrets file"
}

test_helper_gh_passes_the_token_only_in_the_environment() {
  load
  fake_tools
  TOKEN="$(fake_token)"
  WORK="$T_TMP/work"
  GITHUB_TOKEN=should-be-unset helper_gh api user --jq .login >/dev/null
  assert_eq "$(grep '^gh-token-set:' "$FAKE_LOG")" "gh-token-set:yes"
  assert_eq "$(grep '^gh-github-token-set:' "$FAKE_LOG")" "gh-github-token-set:" "GITHUB_TOKEN reached the helper's gh"
  assert_eq "$(grep '^gh-config-dir:' "$FAKE_LOG")" "gh-config-dir:$T_TMP/work/gh-helper" "the owner's gh config"
  assert_not_contains "$(grep '^gh-args:' "$FAKE_LOG")" "$TOKEN" "token in gh's arguments"
}

test_owner_gh_never_uses_a_token_variable() {
  load
  fake_tools
  GH_TOKEN=leaked GITHUB_TOKEN=leaked GH_CONFIG_DIR=/elsewhere owner_gh api user --jq .login >/dev/null
  assert_eq "$(grep '^gh-token-set:' "$FAKE_LOG")" "gh-token-set:" "GH_TOKEN reached the owner's gh"
  assert_eq "$(grep '^gh-github-token-set:' "$FAKE_LOG")" "gh-github-token-set:" "GITHUB_TOKEN reached the owner's gh"
  assert_eq "$(grep '^gh-config-dir:' "$FAKE_LOG")" "gh-config-dir:" "GH_CONFIG_DIR redirected the owner's gh"
}

test_helper_git_is_isolated_from_the_owners_git_config() {
  load
  fake_tools
  TOKEN="$(fake_token)"
  HELPER=frg-helper
  WORK="$T_TMP/work"
  mkdir -p "$WORK"
  GIT_COMMON_DIR=/tmp/x GIT_TEMPLATE_DIR=/tmp/y GIT_DIR=/tmp/z helper_git status
  local log
  log="$(cat "$FAKE_LOG")"
  assert_contains "$log" "git-global:/dev/null nosystem:1 prompt:0 askpass:set home:$T_TMP/work/home"
  assert_eq "$(grep '^git-leaked:' "$FAKE_LOG")" "git-leaked:" "a GIT_* variable reached the helper's git"
  assert_contains "$log" "-c credential.helper= "
  assert_contains "$log" "-c core.hooksPath=/dev/null"
  assert_not_contains "$log" "$TOKEN" "token in git's arguments"
}

test_capture_redacts_tool_output() {
  load
  fake_tools
  TOKEN="$(fake_token)"
  WORK="$T_TMP/work"
  capture helper_gh api -X DELETE repos/x/y || true
  assert_not_contains "$LAST_OUT" "$TOKEN"
  assert_contains "$LAST_OUT" "[REDACTED]"
}

test_assert_throwaway_refuses_another_repo() {
  load
  owner_gh() { printf 'Thebigtuna88/forge-frg26-throwaway\tThebigtuna88\tsomething else\tfalse\n'; }
  local out rc=0
  out="$( assert_throwaway 2>&1 )" || rc=$?
  assert_exit 2 "$rc"
  assert_contains "$out" "is not the public throwaway repo"
  owner_gh() { printf 'Thebigtuna88/forge-frg26-throwaway\tThebigtuna88\t%s\ttrue\n' "$MARKER"; }
  rc=0; out="$( assert_throwaway 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "private repo"
  owner_gh() { printf 'Thebigtuna88/forge-frg26-throwaway\tThebigtuna88\t%s\tfalse\n' "$MARKER"; }
  rc=0; ( assert_throwaway ) || rc=$?
  assert_exit 0 "$rc" "the real throwaway repo"
}

test_only_the_throwaway_repo_is_named() {
  # Every repository the script names is the throwaway one: no other owner/name appears.
  local others
  others="$(grep -oE 'repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "$GT" || true)"
  assert_eq "$others" "" "a hard-coded repository other than \$REPO"
  assert_eq "$(grep -c 'Thebigtuna88/forge"' "$GT" || true)" "0" "FORGE itself is named"
}

run_tests
