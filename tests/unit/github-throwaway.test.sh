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
SCAN="$(cd "$(dirname "$0")/../lib" && pwd)/request-scan.py"

# A fake installation token, built at run time so no token-shaped text sits in the repository.
# GitHub's stateless format (ghs_APPID_JWT, about 520 characters, changelog 2026-04-24): base64url
# parts joined by dots, so - _ and . all appear.
new_token() { printf 'ghs_123456_eyJhbGciOiJSUzI1NiJ9.%s.%s' "$(printf 'eyJ-_x%.0s' $(seq 1 40))" "$(printf 'S1g_-n%.0s' $(seq 1 40))"; }
fake_token() { printf 'gh%s_%s' s "$(printf 'Z%.0s' $(seq 1 36))"; }

load() { # source the script (main doesn't run when sourced)
  # shellcheck source=tests/permissions/github-throwaway.sh
  source "$GT"
}

# Sourcing installs the script's exit clean-up in the test's own subshell. A test that leaves a
# stand-in run's tokens behind ends with this: they aren't a real run's, so its end is no clean-up.
end_stand_in_run() { trap - EXIT; }

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
  printf 'git-global:%s nosystem:%s prompt:%s askpass:%s home:%s\n' "${GIT_CONFIG_GLOBAL:-}" "${GIT_CONFIG_NOSYSTEM:-}" "${GIT_TERMINAL_PROMPT:-}" "${GIT_ASKPASS:-}" "${HOME:-}"
  printf 'git-leaked:%s%s%s\n' "${GIT_COMMON_DIR:-}" "${GIT_TEMPLATE_DIR:-}" "${GIT_DIR:-}"
} >>"$FAKE_LOG"
EOF
  cat >"$T_TMP/bin/curl" <<'EOF'
#!/bin/bash
printf 'curl-args:%s\n' "$*" >>"$FAKE_LOG"
# Its standard input (round 109: the headers, when -H @- asks for them), one line each.
if [[ " $* " == *" -H @- "* ]]; then sed 's/^/curl-stdin:/' >>"$FAKE_LOG"; fi
printf '{"fake":"answer"}\nFRG26-ERR \nHTTP %s' "${FAKE_HTTP:-201}"
EOF
  chmod +x "$T_TMP/bin/gh" "$T_TMP/bin/git" "$T_TMP/bin/curl"
  export FAKE_LOG="$T_TMP/fake.log"
  : >"$FAKE_LOG"
  PATH="$T_TMP/bin:$PATH"
}

app_files() { # <app id> [env mode] [key mode] — the app's id and a fresh test key (never a real one)
  printf 'APP_ID=%s\n' "$1" >"$T_TMP/app.env"
  chmod "${2:-600}" "$T_TMP/app.env"
  [[ -f "$T_TMP/app.pem" ]] || openssl genrsa -out "$T_TMP/app.pem" 2048 2>/dev/null
  chmod "${3:-600}" "$T_TMP/app.pem"
  export FRG26_SECRETS="$T_TMP/app.env" FRG26_APP_KEY="$T_TMP/app.pem"
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
  load_app() { :; }
  need_app_identity() { :; }
  need_installation_scope() { :; }
  mint_token() { :; }
  assert_throwaway() { :; }
  verify_phase() { :; }
  need_allowance() { :; }
  app_git() { :; }
  app_rate() { return 1; }
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
  : >"$T_TMP/calls"
  attempt_baseline() { ATTEMPT_BASE=unprotected ATTEMPT_WRITES=""; } # round 112: its baseline, as read
  app_attempt() { echo "CALL $*" >>"$T_TMP/calls"; OBS=allowed LAST_OUT="HTTP 200"; }
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
  owner_gh() { echo "$*" >>"$T_TMP/owner"; }
  local obs
  for obs in allowed refused; do
    : >"$T_TMP/owner"
    FAILS=0
    eval "app_attempt() { OBS=$obs LAST_OUT=stand-in; }"
    t_B13 >/dev/null
    # Round 112: the owner reads B13's state before and after (its baseline); never a write.
    assert_eq "$(grep -E -- '-X |-f |-F |--input' "$T_TMP/owner" || true)" "" "owner writes after B13's attempts were $obs"
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
  # the script's own --jq, its last argument), plus cleanup_gh's states and logged closes. With
  # SWEEP_PAGE2 set, that JSON page comes after the first only when every page is asked for.
  SWEEP_LIST="$1"
  shift
  cleanup_gh "$@"
  owner_gh() {
    case "$*" in
      "api --paginate repos/$REPO/pulls?state=open&per_page=100 "* | "pr list "*)
        echo listed >>"$T_TMP/lists"
        [[ "$SWEEP_LIST" != fail ]] || return 1
        {
          printf '%s\n' "$SWEEP_LIST"
          if [[ -n "${SWEEP_PAGE2:-}" && "$1 $2" == "api --paginate" ]]; then printf '%s\n' "$SWEEP_PAGE2"; fi
        } | jq -r "${@: -1}"
        ;;
      *) echo "$*" >>"$T_TMP/closes" ;;
    esac
  }
}

test_a_sweep_reads_every_page_of_open_prs() {
  # Round 9 C1: a test PR beyond the first page of open PRs (B11's, with auto-merge armed) must be
  # closed too, not missed while the sweep reports success.
  load
  PHASE=protected
  FAILS=0
  sweep_gh '[{"number":5,"title":"Someone else"}]' OPEN CLOSED
  SWEEP_PAGE2='[{"number":91,"title":"FRG-26 B11 (protected)"}]'
  sweep_prs >/dev/null
  assert_contains "$(cat "$T_TMP/closes")" "pr close 91"
}

test_reset_rewrites_a_branch_only_while_it_reads_unprotected_or_missing() {
  # Round 11 C1: reset's second look at each branch (right before rewriting it) took anything but
  # "missing" as leave to force-update it, an unreadable or protected branch included.
  load
  need_owner() { :; }
  assert_throwaway() { :; }
  ruleset_count() { echo 0; }
  repo_settings() { :; }
  verify_phase() { :; }
  local later rc
  for later in error protected; do
    : >"$T_TMP/owner"
    : >"$T_TMP/reads"
    LATER="$later"
    # The first three reads (the checks before anything changes) say unprotected; later ones don't.
    branch_state() {
      echo x >>"$T_TMP/reads"
      if [[ "$(wc -l <"$T_TMP/reads" | tr -d ' ')" -le 3 ]]; then echo unprotected; else echo "$LATER"; fi
    }
    owner_gh() {
      case "$*" in
        "api repos/$REPO/git/ref/tags/$BASELINE_TAG"*) printf '%040d\n' 0 ;;
        *"pulls?state=open"*) ;;
        *) echo "$*" >>"$T_TMP/owner" ;;
      esac
    }
    rc=0
    (cmd_reset) >/dev/null 2>&1 || rc=$?
    assert_exit 2 "$rc" "a branch that reads $later just before its rewrite"
    assert_not_contains "$(cat "$T_TMP/owner")" "git/refs" "branch writes when a branch reads $later"
  done
}

test_reset_closes_every_open_pr_on_every_page() {
  # Round 9 C1: reset closed only the first 100 open PRs.
  load
  need_owner() { :; }
  assert_throwaway() { :; }
  branch_state() { echo unprotected; }
  ruleset_count() { echo 0; }
  repo_settings() { :; }
  verify_phase() { :; }
  : >"$T_TMP/owner"
  owner_gh() {
    case "$*" in
      "api repos/$REPO/git/ref/tags/$BASELINE_TAG"*) printf '%040d\n' 0 ;;
      *"pulls?state=open"*)
        echo 11
        if [[ "$*" == *--paginate* ]]; then echo 12; fi
        ;;
      # Each close answered as gh does (round 111: an unexpected answer stops the reset).
      "pr close "*) echo "$*" >>"$T_TMP/owner"; echo "Closed pull request $REPO#$3 (FRG-26 test)" ;;
      *) echo "$*" >>"$T_TMP/owner" ;;
    esac
  }
  (cmd_reset) >/dev/null 2>&1
  assert_contains "$(cat "$T_TMP/owner")" "pr close 11"
  assert_contains "$(cat "$T_TMP/owner")" "pr close 12"
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

test_b11_open_needs_a_confirmed_result() {
  load
  PHASE=open
  FAILS=0
  feature_pr() { LAST_PR=7; }
  wait_settled() { return 0; }
  sleep() { :; }
  close_if_open() { :; }
  app_gh() { echo "HTTP 503 Service Unavailable" >&2; return 1; }
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
  app_merge() { OBS=allowed; LAST_OUT=merged; }
  app_gh() { printf '%s\n' "$*" >>"$T_TMP/app-gh.log"; }
  pr_view() { echo "$FAKE_BASE"; }
  local out
  FAKE_BASE=dev
  out="$(t_B9; echo "fails=$FAILS")"
  assert_eq "$(cat "$T_TMP/app-gh.log")" "api -X PATCH repos/$REPO/pulls/7 -f base=dev"
  assert_contains "$out" "RESULT B9 open PASS expected=allowed observed=allowed"
  # A re-aim GitHub didn't apply is a broken setup, not a result.
  FAKE_BASE=side
  out="$(t_B9; echo "fails=$FAILS")"
  assert_contains "$out" "RESULT B9 open FAIL"
  assert_contains "$out" "observed=setup-failed"
  # A refused re-aim never tries the merge B9 is about: setup-failed, never a protected PASS.
  PHASE=protected
  FAKE_BASE=dev
  app_gh() { echo "gh: Resource not accessible by personal access token (HTTP 403)" >&2; return 1; }
  out="$(t_B9; echo "fails=$FAILS")"
  assert_contains "$out" "RESULT B9 protected FAIL"
  assert_contains "$out" "observed=setup-failed"
}

test_app_never_uses_gh_pr_edit() {
  # Same reason as above, for every test: the helper's gh must not run `pr edit`.
  assert_eq "$(grep -c 'app_gh pr edit' "$GT" || true)" "0" "app_gh pr edit needs read:org"
}

rate_fixture() { # <graphql remaining>
  printf '{"resources":{"core":{"limit":5000,"used":12,"remaining":4988,"reset":1792540800},"graphql":{"limit":5000,"used":%s,"remaining":%s,"reset":1792540800}}}' \
    "$((5000 - $1))" "$1"
}

test_app_rate_reads_the_allowance() {
  # The owner's runs stopped on "GraphQL: API rate limit already exceeded" for the helper:
  # the script must be able to show the helper's allowance (GitHub doesn't count that request).
  load
  app_gh() { printf '%s\n' "$*" >>"$T_TMP/app-gh.log"; rate_fixture 10; }
  app_rate || _t_fail "a valid allowance was not read"
  assert_eq "$(cat "$T_TMP/app-gh.log")" "api rate_limit"
  assert_eq "$RATE_LEFT" 10
  assert_contains "$RATE_LINE" "graphql limit=5000 used=4990 remaining=10 resets=2026-10-21T00:00:00Z"
  assert_contains "$RATE_LINE" "rest limit=5000 used=12 remaining=4988"
  app_gh() { echo "HTTP 503" >&2; return 1; }
  if app_rate; then _t_fail "an unreadable allowance was accepted"; fi
}

test_a_phase_needs_enough_app_allowance() {
  # A phase that would run out halfway stops before its first test, naming the reset time.
  load
  local out rc
  app_gh() { rate_fixture 10; }
  rc=0; out="$( need_allowance 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "10 points left"
  assert_contains "$out" "only 10 GraphQL points left"
  assert_contains "$out" "resets=2026-10-21T00:00:00Z"
  app_gh() { echo "HTTP 503" >&2; return 1; }
  rc=0; out="$( need_allowance 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "unreadable allowance"
  app_gh() { rate_fixture 4000; }
  rc=0; out="$( need_allowance 2>&1 )" || rc=$?
  assert_exit 0 "$rc" "4000 points left"
  assert_contains "$out" "app allowance: graphql limit=5000 used=1000 remaining=4000"
}

test_a_phase_needs_enough_rest_allowance_too() {
  # Round 7 C1: the helper's REST requests run out too; GraphQL to spare is not enough.
  load
  local out rc
  app_gh() { printf '{"resources":{"core":{"limit":5000,"used":5000,"remaining":0,"reset":1792540800},"graphql":{"limit":5000,"used":0,"remaining":5000,"reset":1792540800}}}'; }
  rc=0; out="$( need_allowance 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "0 REST requests left"
  assert_contains "$out" "only 0 REST requests left"
  app_gh() { printf '{"resources":{"graphql":{"limit":5000,"used":0,"remaining":5000,"reset":1792540800}}}'; }
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

exact_gh() { # GitHub for exact-protection, answered from $T_TMP (dev.json, main.json, rulesets); every call logged
  protection_fixture dev >"$T_TMP/dev.json"
  protection_fixture main >"$T_TMP/main.json"
  echo 0 >"$T_TMP/rulesets"
  : >"$T_TMP/calls"
  owner_gh() {
    echo "owner_gh $*" >>"$T_TMP/calls"
    local f=""
    case "$*" in
      "api user --jq .login") echo "$OWNER"; return ;;
      "api repos/$REPO --jq "*) printf '%s\t%s\t%s\tfalse\n' "$REPO" "$OWNER" "$MARKER"; return ;;
      "api repos/$REPO/rulesets --jq length") cat "$T_TMP/rulesets"; return ;;
      "api repos/$REPO/branches/dev --jq .protected") if [[ -s "$T_TMP/dev.json" ]]; then echo true; else echo false; fi; return ;;
      "api repos/$REPO/branches/main --jq .protected") if [[ -s "$T_TMP/main.json" ]]; then echo true; else echo false; fi; return ;;
      "api repos/$REPO/branches/dev/protection"*) f=dev ;;
      "api repos/$REPO/branches/main/protection"*) f=main ;;
      *) echo "gh: Not Found (HTTP 404)" >&2; return 1 ;;
    esac
    [[ -s "$T_TMP/$f.json" ]] || { echo "gh: Branch not protected (HTTP 404)" >&2; return 1; }
    if [[ "${3:-}" == --jq ]]; then jq -r "$4" "$T_TMP/$f.json"; else cat "$T_TMP/$f.json"; fi
  }
  local f
  for f in app_session mint_token load_app app_gh app_git app_curl; do
    eval "$f() { echo \"$f \$*\" >>\"\$T_TMP/calls\"; }"
  done
}

exact_reads_only() { # <what>: every request was an owner read; no app token asked for or used
  assert_eq "$(grep -cv '^owner_gh api ' "$T_TMP/calls" || true)" 0 "$1: a call other than an owner read"
  assert_eq "$(grep -cE -- ' (-X|--method|-f|-F|--field|--raw-field|--input)( |$)' "$T_TMP/calls" || true)" 0 "$1: a write"
}

test_exact_protection_compares_the_whole_protection_reading_only() {
  # Owner 2026-11-22 (review-lens round 81, C1 = SEC-1): the handoffs' exact-protection check
  # compares the whole protection, as protect's own read-back does, not the seven fields status
  # prints; as the owner, reading only, with no app token issued.
  load
  exact_gh
  local rc out
  rc=0; out="$(cmd_exact_protection 2>&1)" || rc=$?
  assert_exit 0 "$rc" "protect's own settings"
  assert_contains "$out" "exact protection: dev and main exactly as protect applies them, no ruleset"
  exact_reads_only "exact"
  assert_contains "$(cat "$T_TMP/calls")" "owner_gh api repos/$REPO/branches/dev/protection"
  assert_contains "$(cat "$T_TMP/calls")" "owner_gh api repos/$REPO/branches/main/protection"
  # An extra required check on dev: the seven fields are unchanged.
  exact_gh
  jq -c '. + {required_status_checks: {url: "x", strict: true, contexts: ["owner-extra-check"], checks: [{context: "owner-extra-check", app_id: null}]}}' "$T_TMP/dev.json" >"$T_TMP/x" && mv "$T_TMP/x" "$T_TMP/dev.json"
  assert_eq "$(protection_of dev)" "$WANT_DEV" "the seven fields with an extra required check"
  : >"$T_TMP/calls"
  rc=0; out="$(cmd_exact_protection 2>&1)" || rc=$?
  assert_exit 2 "$rc" "an extra required check on dev"
  assert_contains "$out" "dev protection is not exactly what protect applies"
  assert_not_contains "$out" "exact protection: dev and main"
  exact_reads_only "an extra required check"
  # A locked main: the seven fields are unchanged.
  exact_gh
  jq -c '.lock_branch.enabled = true' "$T_TMP/main.json" >"$T_TMP/x" && mv "$T_TMP/x" "$T_TMP/main.json"
  assert_eq "$(protection_of main)" "$WANT_MAIN" "the seven fields with main locked"
  : >"$T_TMP/calls"
  rc=0; out="$(cmd_exact_protection 2>&1)" || rc=$?
  assert_exit 2 "$rc" "main locked"
  assert_contains "$out" "main protection is not exactly what protect applies"
  exact_reads_only "main locked"
  # Restrictions on who may push to dev.
  exact_gh
  jq -c '. + {restrictions: {users: [], teams: [], apps: []}}' "$T_TMP/dev.json" >"$T_TMP/x" && mv "$T_TMP/x" "$T_TMP/dev.json"
  rc=0; out="$(cmd_exact_protection 2>&1)" || rc=$?
  assert_exit 2 "$rc" "push restrictions on dev"
  assert_contains "$out" "dev protection is not exactly what protect applies"
  exact_reads_only "push restrictions"
  # main unprotected.
  exact_gh
  : >"$T_TMP/main.json"
  rc=0; out="$(cmd_exact_protection 2>&1)" || rc=$?
  assert_exit 2 "$rc" "main unprotected"
  assert_contains "$out" "phase protected needs dev and main protected"
  exact_reads_only "main unprotected"
  # A ruleset.
  exact_gh
  echo 1 >"$T_TMP/rulesets"
  rc=0; out="$(cmd_exact_protection 2>&1)" || rc=$?
  assert_exit 2 "$rc" "a ruleset"
  assert_contains "$out" "phase protected needs no ruleset"
  exact_reads_only "a ruleset"
  # The protection can't be read.
  exact_gh
  owner_gh() { echo "owner_gh $*" >>"$T_TMP/calls"; return 1; }
  rc=0; out="$(cmd_exact_protection 2>&1)" || rc=$?
  assert_exit 2 "$rc" "nothing readable"
  assert_not_contains "$out" "exact protection: dev and main"
  exact_reads_only "nothing readable"
  # The handoffs reach it as a command of its own.
  assert_contains "$(grep -c '^    exact-protection) cmd_exact_protection ;;$' "$GT")" 1 "exact-protection dispatched"
  assert_contains "$(grep 'die "usage: github-throwaway.sh' "$GT")" "|exact-protection" "exact-protection in the usage"
}

test_a_protection_mismatch_names_only_listed_settings() {
  # Owner 2026-11-22 (review-lens round 82, SEC-1): a protection that isn't exactly protect's is
  # reported by the fixed names of the settings that differ; never a value GitHub returned, and never
  # a name outside the list (a required check's name is free text, and could hold a credential).
  load
  exact_gh
  local rc out canary
  canary="$(printf 'sk_%s_%s' live FRG26canary0123456789)"
  # An extra required check whose name is a credential.
  jq -c --arg c "$canary" '. + {required_status_checks: {url: "x", strict: true, contexts: [$c], checks: [{context: $c, app_id: null}]}}' "$T_TMP/dev.json" >"$T_TMP/x" && mv "$T_TMP/x" "$T_TMP/dev.json"
  rc=0; out="$(cmd_exact_protection 2>&1)" || rc=$?
  assert_exit 2 "$rc" "a required check named like a credential"
  assert_contains "$out" "dev protection is not exactly what protect applies (differs in: required_status_checks)"
  assert_not_contains "$out" "$canary"
  assert_not_contains "$out" '{"'
  # A setting GitHub might add, with a credential for its name.
  exact_gh
  jq -c --arg c "$canary" '. + {($c): {enabled: true}}' "$T_TMP/main.json" >"$T_TMP/x" && mv "$T_TMP/x" "$T_TMP/main.json"
  rc=0; out="$(cmd_exact_protection 2>&1)" || rc=$?
  assert_exit 2 "$rc" "an unlisted setting on main"
  assert_contains "$out" "main protection is not exactly what protect applies (differs in: a setting not on the list)"
  assert_not_contains "$out" "$canary"
  # A listed setting that differs, holding a credential inside it, beside an unlisted one.
  exact_gh
  jq -c --arg c "$canary" '.lock_branch = {enabled: true, note: $c} | . + {($c): 1}' "$T_TMP/main.json" >"$T_TMP/x" && mv "$T_TMP/x" "$T_TMP/main.json"
  rc=0; out="$(cmd_exact_protection 2>&1)" || rc=$?
  assert_exit 2 "$rc" "main locked, with an unlisted setting"
  assert_contains "$out" "main protection is not exactly what protect applies (differs in: lock_branch, a setting not on the list)"
  assert_not_contains "$out" "$canary"
  # One of the seven status fields, holding a credential: named, not shown.
  exact_gh
  jq -c --arg c "$canary" '.required_pull_request_reviews.required_approving_review_count = $c' "$T_TMP/dev.json" >"$T_TMP/x" && mv "$T_TMP/x" "$T_TMP/dev.json"
  rc=0; out="$(cmd_exact_protection 2>&1)" || rc=$?
  assert_exit 2 "$rc" "a review count holding a credential"
  assert_contains "$out" "dev protection is not exactly what protect applies (differs in: required_approving_review_count)"
  assert_not_contains "$out" "$canary"
  # The same, with a space in it, so the seven fields no longer line up.
  exact_gh
  jq -c --arg c "$canary and more" '.required_pull_request_reviews.dismiss_stale_reviews = $c' "$T_TMP/dev.json" >"$T_TMP/x" && mv "$T_TMP/x" "$T_TMP/dev.json"
  rc=0; out="$(cmd_exact_protection 2>&1)" || rc=$?
  assert_exit 2 "$rc" "a review setting with spaces"
  assert_contains "$out" "dev protection is not exactly what protect applies (differs in: an answer that can't be compared field by field)"
  assert_not_contains "$out" "$canary"
  # An answer that isn't an object.
  exact_gh
  printf '["%s"]\n' "$canary" >"$T_TMP/dev.json"
  rc=0; out="$(verify_phase protected 2>&1)" || rc=$?
  assert_exit 2 "$rc" "an answer that is not an object"
  assert_contains "$out" "dev protection is not exactly what protect applies"
  assert_not_contains "$out" "$canary"
  exact_reads_only "mismatches"
}

owner_cmd_stubs() { # an owner command's checks pass; its gh calls are logged to $T_TMP/owner
  load
  need_owner() { :; }
  assert_throwaway() { :; }
  load_app() { :; }
  need_app_identity() { :; }
  need_installation_scope() { :; }
  mint_token() { :; }
  owner_uid() { echo 1; }
  owner_gh() { echo "$*" >>"$T_TMP/owner"; owner_answer "$@"; }
  WORK="$T_TMP/work"
  mkdir -p "$WORK"
  : >"$T_TMP/owner"
}

# Round 110: each of the owner's setup writes answered as GitHub does (its expected answer), and the
# dummy value read back by its name; anything else answers nothing.
owner_answer() {
  case "$*" in
    "api -X PUT repos/$REPO/environments/"*) printf '{"name":"%s"}\n' "$ENV_NAME" ;;
    "api -X POST repos/$REPO/environments/"*"/deployment-branch-policies"*) printf '{"name":"main"}\n' ;;
    "secret set "*) printf 'Set Actions secret %s for %s\n' "$3" "$REPO" ;;
    "api repos/$REPO/environments/"*"/secrets/"*" --jq .name") printf '%s\n' "$DUMMY_NAME" ;;
  esac
}

test_ruleset_needs_enough_app_allowance_before_it_changes_anything() {
  # The phase after the ruleset needs the helper's allowance; if it is short, the ruleset must
  # not be added (it would sit there untested). Round 6, owner: executable and fail-closed.
  owner_cmd_stubs
  verify_phase() { :; }
  local out rc
  app_gh() { rate_fixture 10; }
  rc=0; out="$(cmd_ruleset 2>&1)" || rc=$?
  assert_exit 2 "$rc" "10 points left"
  assert_contains "$out" "only 10 GraphQL points left"
  assert_eq "$(cat "$T_TMP/owner")" "" "owner calls with 10 points left"
  app_gh() { echo "HTTP 503" >&2; return 1; }
  rc=0; out="$(cmd_ruleset 2>&1)" || rc=$?
  assert_exit 2 "$rc" "unreadable allowance"
  assert_eq "$(cat "$T_TMP/owner")" "" "owner calls with an unreadable allowance"
  app_gh() { rate_fixture 4000; }
  rc=0; out="$(cmd_ruleset 2>&1)" || rc=$?
  assert_contains "$(cat "$T_TMP/owner")" "api -X POST repos/$REPO/rulesets"
}

# Round 8 C1: a lost answer after GitHub created the ruleset must not lead to a second one. Round 111
# (review-lens round 99, C3 = SEC-1; owner): no fallback form at all. A create not settled by its
# expected answer (the ruleset, with its id) stops the command, its outcome unknown, whatever the
# answer's words or a list read after it; one that is, is settled only by the read-back of the very
# form it sent.
test_a_ruleset_create_is_sent_once_whatever_its_answer() {
  owner_cmd_stubs
  verify_phase() { echo "VERIFY $1" >>"$T_TMP/owner"; }
  app_gh() { rate_fixture 4000; }
  owner_gh() {
    case "$*" in
      *"-X POST repos/$REPO/rulesets"*)
        echo "$*" >>"$T_TMP/owner"
        printf '%s\n' "$FIRST_OUT"
        return "$FIRST_RC" ;;
      # Round 115: read back by its id, as GitHub returns it: the form sent, or the admin-role form.
      "api repos/$REPO/rulesets/7")
        if [[ "$SUMMARY" == user ]]; then ruleset_json User 1; else ruleset_json RepositoryRole 5; fi ;;
    esac
  }
  ruleset_count() { echo "$COUNT"; }
  ruleset_summary() { echo "a summary"; }
  die() { printf 'DIED: %s\n' "$*"; unknown_writes; exit 2; } # with the writes the clean-up would name
  local case_ name rc want_rc out
  for case_ in "a gateway error|gh: HTTP 502 Bad Gateway|1|0|user|2" \
    "a 422 with no ruleset after it (the old fallback)|gh: Validation Failed (HTTP 422)|1|0|user|2" \
    "a 422 with a ruleset after it|gh: Validation Failed (HTTP 422)|1|1|user|2" \
    "an unexpected answer, status 0|{\"message\":\"later\"}|0|0|user|2" \
    "its expected answer, another form read back|{\"id\":7}|0|1|admin|2" \
    "its expected answer, its form read back|{\"id\":7}|0|1|user|0"; do
    IFS='|' read -r name FIRST_OUT FIRST_RC COUNT SUMMARY want_rc <<<"$case_"
    : >"$T_TMP/owner"
    rc=0
    out="$({ cmd_ruleset && unknown_writes; } 2>&1)" || rc=$?
    assert_exit "$want_rc" "$rc" "$name"
    assert_eq "$(grep -c 'X POST' "$T_TMP/owner")" 1 "$name: ruleset creates sent"
    assert_not_contains "$(cat "$T_TMP/owner")" "ruleset-admin.json" "$name: the fallback form"
    if [[ "$want_rc" == 0 ]]; then
      assert_contains "$(cat "$T_TMP/owner")" "VERIFY ruleset" "$name"
      assert_not_contains "$out" "POST repos/$REPO/rulesets (" "$name: named outcome unknown"
    elif [[ "$name" == *"another form"* ]]; then
      assert_contains "$out" "DIED: the ruleset read back is not, field for field, the one requested" "$name"
      # Round 113 (review-lens round 100, C4; owner): its expected answer alone doesn't settle it; only
      # the read-back of the form sent does, so one that fails leaves it outcome unknown.
      assert_contains "$out" "owner gh api POST repos/$REPO/rulesets (" "$name: settled before its read-back"
    else
      assert_contains "$out" "owner gh api POST repos/$REPO/rulesets (" "$name: named outcome unknown"
    fi
    [[ "$name" == *"another form"* || "$want_rc" == 0 ]] || assert_not_contains "$(cat "$T_TMP/owner")" "VERIFY ruleset" "$name: read back as if made"
  done
}

test_a_failed_owner_id_read_stops_whatever_needs_it() {
  # Round 10 C1: owner_uid's die inside $( ) ends only the subshell. Each of its three users must
  # stop on a failed read instead of going on with an empty id.
  owner_cmd_stubs
  verify_phase() { :; }
  app_gh() { rate_fixture 4000; }
  owner_uid() { die "can't read the owner's user id"; }
  local rc=0
  (cmd_ruleset) >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "ruleset with no owner id"
  assert_eq "$(cat "$T_TMP/owner")" "" "owner calls with no owner id"
  PHASE=protected
  FAILS=0
  : >"$T_TMP/calls"
  capture() { echo "CALL $*" >>"$T_TMP/calls"; }
  local out
  out="$(t_B13; echo "FAILS=$FAILS")"
  assert_contains "$out" "RESULT B13 protected FAIL"
  assert_contains "$out" "observed=setup-failed"
  assert_eq "$(cat "$T_TMP/calls")" "" "helper attempts with no owner id"
  if want_ruleset >/dev/null 2>&1; then _t_fail "want_ruleset passed with no owner id"; fi
}

test_allowance_check_fails_closed() {
  owner_cmd_stubs
  local out rc
  app_gh() { rate_fixture 10; }
  rc=0; out="$(cmd_allowance 2>&1)" || rc=$?
  assert_exit 2 "$rc" "10 points left"
  app_gh() { echo "HTTP 503" >&2; return 1; }
  rc=0; out="$(cmd_allowance 2>&1)" || rc=$?
  assert_exit 2 "$rc" "unreadable allowance"
  app_gh() { rate_fixture 4000; }
  rc=0; out="$(cmd_allowance 2>&1)" || rc=$?
  assert_exit 0 "$rc" "4000 points left"
  assert_contains "$out" "app allowance: graphql limit=5000 used=1000 remaining=4000"
}

protect_stubs() { # <dev state> <main state>: a stand-in repository protect and unprotect change
  # Each branch's state is a file, so it survives the subshell a failing command runs in. A PUT
  # protects a branch, a DELETE unprotects it; the write named in $T_TMP/fail fails once. A
  # protected branch reads protect's own settings, or more once $T_TMP/extra-<branch> exists. After
  # dev's write, main's state becomes what $T_TMP/then-main holds, with more settings (someone
  # changing it meanwhile).
  owner_cmd_stubs
  echo "$1" >"$T_TMP/state-dev"
  echo "$2" >"$T_TMP/state-main"
  : >"$T_TMP/fail"
  rm -f "$T_TMP/extra-dev" "$T_TMP/extra-main" "$T_TMP/then-main"
  branch_state() { cat "$T_TMP/state-$1"; }
  ruleset_count() { echo 0; }
  protection_full() {
    if [[ -e "$T_TMP/extra-$1" ]]; then echo '{"owner-extra":true}'
    elif [[ "$1" == dev ]]; then want_protection true
    else want_protection false
    fi
  }
  protection_of() { echo stub; }
  owner_gh() {
    # Round 110: protection writes come with -i (their answer judged by GitHub's status line); noted
    # whole in owner-raw, and logged without it as before.
    echo "$*" >>"$T_TMP/owner-raw"
    [[ "${2:-}" != -i ]] || set -- "$1" "${@:3}"
    echo "$*" >>"$T_TMP/owner"
    local w="${2:-} ${3:-} ${4:-}" st b code
    case "$w" in
      "-X PUT repos/$REPO/branches/"*"/protection") st=protected code="200 OK" ;;
      "-X DELETE repos/$REPO/branches/"*"/protection") st=unprotected code="204 No Content" ;;
      *) return 0 ;;
    esac
    if [[ "$w" == "$(cat "$T_TMP/fail")" ]]; then : >"$T_TMP/fail"; return 1; fi
    b="${4#repos/"$REPO"/branches/}"
    b="${b%/protection}"
    echo "$st" >"$T_TMP/state-$b"
    if [[ "$b" == dev && -s "$T_TMP/then-main" ]]; then
      cp "$T_TMP/then-main" "$T_TMP/state-main"
      touch "$T_TMP/extra-main"
    fi
    printf 'HTTP/2.0 %s\r\n' "$code"
  }
  verify_phase() { # the real rule on the stand-in's state, logged
    echo "verify $1" >>"$T_TMP/owner"
    local d m
    d="$(cat "$T_TMP/state-dev")" m="$(cat "$T_TMP/state-main")"
    case "$1" in
      open) [[ "$d" == unprotected && "$m" == unprotected ]] || die "phase open needs dev and main unprotected (dev $d, main $m)" ;;
      protected) [[ "$d" == protected && "$m" == protected ]] || die "phase protected needs dev and main protected (dev $d, main $m)" ;;
    esac
  }
}

test_unprotect_lifts_exactly_what_protect_applies() {
  # The fresh open phase (owner, 2026-10-31) starts from the protected state the throwaway is in:
  # unprotect removes both protections and checks the result.
  protect_stubs protected protected
  local rc=0
  cmd_unprotect >/dev/null 2>&1 || rc=$?
  assert_exit 0 "$rc"
  assert_eq "$(cat "$T_TMP/owner")" "api -X DELETE repos/$REPO/branches/dev/protection
api -X DELETE repos/$REPO/branches/main/protection
verify open"
}

test_protect_applies_both_protections_from_the_open_state() {
  protect_stubs unprotected unprotected
  local rc=0
  cmd_protect >/dev/null 2>&1 || rc=$?
  assert_exit 0 "$rc"
  assert_eq "$(cat "$T_TMP/owner")" "api -X PUT repos/$REPO/branches/dev/protection --input $WORK/dev.json
api -X PUT repos/$REPO/branches/main/protection --input $WORK/main.json
verify protected"
  assert_eq "$(jq -c .enforce_admins "$WORK/dev.json") $(jq -c .enforce_admins "$WORK/main.json")" "true false" "dev enforces admins, main doesn't"
  # Round 110: each write asks for GitHub's status line (-i) and is settled by it, then by the
  # read-back: nothing is left outcome unknown.
  assert_contains "$(cat "$T_TMP/owner-raw")" "api -i -X PUT repos/$REPO/branches/dev/protection" "protect's writes judged by their status line"
  assert_eq "$(unknown_writes)" "" "a protection write left outcome unknown"
}

test_protect_and_unprotect_resume_after_their_second_write_failed() {
  # Rounds 41 and 43, C1: a run that changed dev and then failed on main can be run again; dev,
  # already in the wanted state, is left as it is.
  local rc out
  protect_stubs unprotected unprotected
  echo "-X PUT repos/$REPO/branches/main/protection" >"$T_TMP/fail"
  rc=0; out="$( (cmd_protect) 2>&1)" || rc=$?
  assert_exit 2 "$rc" "protect, main's write failing"
  assert_contains "$out" "protecting main failed"
  assert_eq "$(cat "$T_TMP/state-dev") $(cat "$T_TMP/state-main")" "protected unprotected" "after protect's failed run"
  : >"$T_TMP/owner"
  rc=0; out="$( (cmd_protect) 2>&1)" || rc=$?
  assert_exit 0 "$rc" "protect run again"
  assert_eq "$(cat "$T_TMP/owner")" "api -X PUT repos/$REPO/branches/main/protection --input $WORK/main.json
verify protected" "protect run again"

  protect_stubs protected protected
  echo "-X DELETE repos/$REPO/branches/main/protection" >"$T_TMP/fail"
  rc=0; out="$( (cmd_unprotect) 2>&1)" || rc=$?
  assert_exit 2 "$rc" "unprotect, main's write failing"
  assert_contains "$out" "unprotecting main failed"
  assert_eq "$(cat "$T_TMP/state-dev") $(cat "$T_TMP/state-main")" "unprotected protected" "after unprotect's failed run"
  : >"$T_TMP/owner"
  rc=0; out="$( (cmd_unprotect) 2>&1)" || rc=$?
  assert_exit 0 "$rc" "unprotect run again"
  assert_eq "$(cat "$T_TMP/owner")" "api -X DELETE repos/$REPO/branches/main/protection
verify open" "unprotect run again"
}

test_protect_and_unprotect_read_each_branch_again_right_before_its_write() {
  # Round 44 C1: main changing while dev is written (more settings, or unreadable) stops the
  # command before main's write, as reset reads each branch again before rewriting it.
  local rc out cmd from st
  for cmd in protect unprotect; do
    from=unprotected
    [[ "$cmd" == unprotect ]] && from=protected
    for st in protected error; do
      protect_stubs "$from" "$from"
      echo "$st" >"$T_TMP/then-main"
      rc=0; out="$( ("cmd_$cmd") 2>&1)" || rc=$?
      assert_exit 2 "$rc" "$cmd, main $st with more settings after dev's write"
      if [[ "$st" == protected ]]; then
        assert_contains "$out" "main is protected, but not exactly as protect applies it"
      else
        assert_contains "$out" "main reads error"
      fi
      assert_eq "$(grep -c 'branches/main/protection' "$T_TMP/owner")" 0 "$cmd's writes to main after it changed to $st"
      assert_eq "$(grep -c 'branches/dev/protection' "$T_TMP/owner")" 1 "$cmd's write to dev"
    done
  done
}

test_protect_and_unprotect_change_nothing_unless_each_branch_is_unprotected_or_exactly_protected() {
  local rc out cmd s
  for cmd in protect unprotect; do
    # dev protected with anything more than protect applies: nothing is written, dev or main.
    protect_stubs protected unprotected
    protection_full() { echo '{"owner-extra":true}'; }
    rc=0; out="$( ("cmd_$cmd") 2>&1)" || rc=$?
    assert_exit 2 "$rc" "$cmd, dev protected differently"
    assert_contains "$out" "dev is protected, but not exactly as protect applies it"
    assert_eq "$(cat "$T_TMP/owner")" "" "$cmd's writes with dev protected differently"
    # main's protection unreadable, dev in either state: dev isn't changed either.
    protect_stubs unprotected protected
    protection_full() { if [[ "$1" == main ]]; then echo error; else want_protection true; fi; }
    rc=0; out="$( ("cmd_$cmd") 2>&1)" || rc=$?
    assert_exit 2 "$rc" "$cmd, main's protection unreadable"
    assert_contains "$out" "main is protected, but not exactly as protect applies it"
    assert_eq "$(cat "$T_TMP/owner")" "" "$cmd's writes with main's protection unreadable"
    for s in error missing; do
      protect_stubs protected "$s"
      rc=0; out="$( ("cmd_$cmd") 2>&1)" || rc=$?
      assert_exit 2 "$rc" "$cmd, main reads $s"
      assert_contains "$out" "main reads $s"
      assert_eq "$(cat "$T_TMP/owner")" "" "$cmd's writes while main reads $s"
    done
    for s in 1 error; do
      protect_stubs protected unprotected
      RULESETS="$s"
      ruleset_count() { echo "$RULESETS"; }
      rc=0; out="$( ("cmd_$cmd") 2>&1)" || rc=$?
      assert_exit 2 "$rc" "$cmd, rulesets $s"
      assert_contains "$out" "only run while there is no ruleset"
      assert_eq "$(cat "$T_TMP/owner")" "" "$cmd's writes with rulesets $s"
    done
  done
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

test_app_merge_needs_a_blocked_mergeable_pr_to_count_as_refused() {
  load
  PHASE=protected
  sleep() { :; }
  app_gh() { echo "X Pull request is not mergeable: the base branch policy prohibits the merge." >&2; return 1; }
  pr_view() {
    case "$2" in
      mergeable) echo MERGEABLE ;;
      *) echo "$FAKE_FACTS" ;;
    esac
  }
  FAKE_FACTS="OPEN MERGEABLE BLOCKED REVIEW_REQUIRED"
  app_merge B6 7 --squash
  assert_eq "$OBS" refused "blocked by protection"
  FAKE_FACTS="OPEN MERGEABLE CLEAN APPROVED"
  app_merge B6 7 --squash
  assert_eq "$OBS" inconclusive "open but not blocked: something else went wrong"
  # Blocked on GitHub, but the merge request itself failed for another reason: proves nothing.
  pr_view() {
    case "$2" in
      mergeable) echo MERGEABLE ;;
      *) echo "OPEN MERGEABLE BLOCKED REVIEW_REQUIRED" ;;
    esac
  }
  app_gh() { echo "HTTP 503 Service Unavailable" >&2; return 1; }
  app_merge B6 7 --squash
  assert_eq "$OBS" inconclusive "a failed request with a blocked PR"
  app_gh() { echo "gh: API rate limit exceeded; base branch policy prohibits the merge" >&2; return 1; }
  app_merge B6 7 --squash
  assert_eq "$OBS" inconclusive "a rate limit with a policy-looking message"
  pr_view() { return 1; }
  app_merge B6 7 --squash
  assert_eq "$OBS" inconclusive "state unreadable (network)"
  assert_contains "$LAST_OUT" "never settled"
  # Round 109: the stand-in merges with no answer in GitHub's words (no HTTP status) are writes of
  # unknown outcome; a stand-in run's end is no clean-up.
  assert_contains "$(unknown_writes)" "app gh pr merge 7 --repo $REPO (failed: status 1);" "a merge that failed (rule (b): never taken as refused)"
  end_stand_in_run
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
  # A stand-in run's token: its end is no clean-up (round 74: nor a request to GitHub).
  end_stand_in_run
}

test_app_gh_passes_the_token_only_in_the_environment() {
  load
  fake_tools
  TOKEN="$(fake_token)"
  WORK="$T_TMP/work"
  GITHUB_TOKEN=should-be-unset app_gh api user --jq .login >/dev/null
  assert_eq "$(grep '^gh-token-set:' "$FAKE_LOG")" "gh-token-set:yes"
  assert_eq "$(grep '^gh-github-token-set:' "$FAKE_LOG")" "gh-github-token-set:" "GITHUB_TOKEN reached the app's gh"
  assert_eq "$(grep '^gh-config-dir:' "$FAKE_LOG")" "gh-config-dir:/var/empty" "the owner's gh config (round 109: always /var/empty)"
  assert_not_contains "$(grep '^gh-args:' "$FAKE_LOG")" "$TOKEN" "token in gh's arguments"
  # A stand-in run's token: its end is no clean-up (round 74: nor a request to GitHub).
  end_stand_in_run
}

test_owner_gh_never_uses_a_token_variable() {
  load
  fake_tools
  GH_TOKEN=leaked GITHUB_TOKEN=leaked GH_CONFIG_DIR=/elsewhere owner_gh api user --jq .login >/dev/null
  assert_eq "$(grep '^gh-token-set:' "$FAKE_LOG")" "gh-token-set:" "GH_TOKEN reached the owner's gh"
  assert_eq "$(grep '^gh-github-token-set:' "$FAKE_LOG")" "gh-github-token-set:" "GITHUB_TOKEN reached the owner's gh"
  assert_eq "$(grep '^gh-config-dir:' "$FAKE_LOG")" "gh-config-dir:" "GH_CONFIG_DIR redirected the owner's gh"
}

test_app_git_is_isolated_from_the_owners_git_config() {
  load
  fake_tools
  TOKEN="$(fake_token)"
  WORK="$T_TMP/work"
  mkdir -p "$WORK"
  GIT_COMMON_DIR=/tmp/x GIT_TEMPLATE_DIR=/tmp/y GIT_DIR=/tmp/z app_git status
  local log
  log="$(cat "$FAKE_LOG")"
  assert_contains "$log" "git-global:/dev/null nosystem:1 prompt:0 askpass:/usr/bin/false home:/var/empty"
  assert_eq "$(grep '^git-leaked:' "$FAKE_LOG")" "git-leaked:" "a GIT_* variable reached the app's git"
  assert_contains "$log" "-c credential.helper= "
  assert_contains "$log" "-c core.hooksPath=/dev/null"
  assert_not_contains "$log" "$TOKEN" "token in git's arguments"
  # A stand-in run's token: its end is no clean-up (round 74: nor a request to GitHub).
  end_stand_in_run
}

test_capture_redacts_tool_output() {
  load
  fake_tools
  TOKEN="$(fake_token)"
  WORK="$T_TMP/work"
  mkdir -m 700 "$WORK"
  capture app_gh api -X DELETE repos/x/y || true
  assert_not_contains "$LAST_OUT" "$TOKEN"
  assert_contains "$LAST_OUT" "[REDACTED]"
  # A stand-in run's token: its end is no clean-up (round 74: nor a request to GitHub).
  end_stand_in_run
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

# --- The GitHub App (plan section 4, revised 2026-11-01) ------------------------------------------

app_fixture() { # GET /app for the owner's throwaway app (its own permissions, as GitHub lists them)
  printf '{"id":123456,"slug":"frg26-test-app","owner":{"login":"Thebigtuna88"},"permissions":{"contents":"write","issues":"write","metadata":"read","pull_requests":"write"}}'
}

installations_fixture() { # GET /app/installations: one installation, the four permissions
  printf '[{"id":77,"account":{"login":"Thebigtuna88"},"repository_selection":"selected","suspended_at":null,"permissions":{"contents":"write","issues":"write","metadata":"read","pull_requests":"write"}}]'
}

token_fixture() { # POST …/access_tokens: a token for exactly what mint_token asks for
  printf '{"token":"%s","expires_at":"2026-11-01T12:00:00Z","repository_selection":"selected","permissions":{"contents":"write","issues":"write","metadata":"read","pull_requests":"write"},"repositories":[{"full_name":"Thebigtuna88/forge-frg26-throwaway"}]}' "$(fake_token)"
}

app_stubs() { # the JWT calls answer from the fixtures above (or $T_TMP/<name>.json when present)
  load
  APP_ID=123456
  WORK="$T_TMP/work"
  mkdir -m 700 "$WORK"
  make_jwt() { JWT=jwt-stand-in; }
  jwt_call() {
    echo "$1 $2" >>"$T_TMP/jwt-calls"
    [[ -n "${3:-}" ]] && printf '%s\n' "$3" >"$T_TMP/last-body.json" # round 109: the body itself, no file
    LAST_HTTP=200
    case "$1 $2" in
      "GET app") LAST_OUT="$(cat "$T_TMP/app.json" 2>/dev/null || app_fixture)" ;;
      "GET app/installations"*) LAST_OUT="$(cat "$T_TMP/inst.json" 2>/dev/null || installations_fixture)" ;;
      "POST app/installations/77/access_tokens")
        LAST_HTTP=201
        LAST_OUT="$(cat "$T_TMP/token.json" 2>/dev/null || token_fixture)"
        ;;
      *) LAST_HTTP=404; LAST_OUT='{"message":"Not Found"}'; return 1 ;;
    esac
  }
  app_gh() { echo "$*" >>"$T_TMP/app-gh.log"; }
  : >"$T_TMP/jwt-calls"
  : >"$T_TMP/app-gh.log"
}

test_load_app_accepts_an_app_id_and_a_key() {
  load
  app_files 123456
  SECRETS="$FRG26_SECRETS" APP_KEY="$FRG26_APP_KEY"
  ( load_app ) || _t_fail "a valid app id and key were refused"
}

test_load_app_refusals() {
  load
  local out rc
  app_files 123456 644
  SECRETS="$FRG26_SECRETS" APP_KEY="$FRG26_APP_KEY"
  rc=0; out="$( load_app 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "app.env mode 644"
  assert_contains "$out" "must be mode 600"

  app_files 123456 600 644
  rc=0; out="$( load_app 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "key mode 644"
  assert_contains "$out" "must be mode 600"

  app_files 'abc'
  rc=0; out="$( load_app 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "an app id that isn't a number"

  app_files 123456
  printf 'not a key\n' >"$T_TMP/app.pem"
  rc=0; out="$( load_app 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "a key file that isn't a private key"
  assert_contains "$out" "not a private key"

  rm -f "$T_TMP/app.pem"
  app_files 123456
  rm -f "$T_TMP/app.pem"
  ln -s /etc/hosts "$T_TMP/app.pem"
  rc=0; out="$( load_app 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "a symlinked key"

  rm -f "$T_TMP/app.pem"
  app_files 123456
  chmod 755 "$T_TMP"
  rc=0; out="$( load_app 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "secrets folder not mode 700"
  assert_contains "$out" "must be mode 700"
  chmod 700 "$T_TMP"
}

b64url_decode() { # <text>
  local s
  s="$(printf '%s' "$1" | tr '_-' '/+')"
  while (( ${#s} % 4 )); do s="$s="; done
  printf '%s' "$s" | base64 -D
}

test_jwt_is_rs256_short_lived_and_signed_by_the_key() {
  # GitHub: signed with RS256, "no more than 10 minutes into the future" (plan 4.2).
  load
  app_files 123456
  SECRETS="$FRG26_SECRETS" APP_KEY="$FRG26_APP_KEY"
  WORK="$T_TMP/work"
  mkdir -m 700 "$WORK"
  load_app
  local before after h p s payload iat exp
  before="$(date +%s)"
  make_jwt
  after="$(date +%s)"
  IFS=. read -r h p s <<<"$JWT"
  assert_eq "$(b64url_decode "$h")" '{"alg":"RS256","typ":"JWT"}' "JWT header"
  payload="$(b64url_decode "$p")"
  assert_eq "$(jq -r .iss <<<"$payload")" 123456 "issuer"
  iat="$(jq -r .iat <<<"$payload")"
  exp="$(jq -r .exp <<<"$payload")"
  (( iat <= before )) || _t_fail "issued in the future ($iat > $before)"
  (( exp <= after + 600 )) || _t_fail "valid more than 10 minutes ($exp > $after + 600)"
  (( exp > after )) || _t_fail "already expired"
  printf '%s.%s' "$h" "$p" >"$T_TMP/signed"
  b64url_decode "$s" >"$T_TMP/sig"
  openssl rsa -in "$T_TMP/app.pem" -pubout -out "$T_TMP/pub.pem" 2>/dev/null
  assert_contains "$(openssl dgst -sha256 -verify "$T_TMP/pub.pem" -signature "$T_TMP/sig" "$T_TMP/signed" 2>&1)" "Verified OK" "signature"
  # Round 109: the JWT stays in memory; no header file holds it.
  assert_eq "$(ls -A "$WORK")" "" "a file made for the JWT"
}

test_jwt_call_keeps_the_jwt_out_of_arguments() {
  load
  fake_tools
  WORK="$T_TMP/work"
  mkdir -m 700 "$WORK"
  JWT="header.payload.signature-not-real"
  jwt_call POST app/installations/77/access_tokens '{"x":1}' || _t_fail "a 201 answer was a failure"
  local args
  args="$(grep '^curl-args:' "$FAKE_LOG")"
  assert_contains "$args" "curl-args:-q " "the user curlrc must not apply (-q comes first)"
  # Round 109: the headers, the JWT among them, come on curl's standard input; the body (no secret
  # in it) is an argument.
  assert_contains "$args" "-H @-"
  assert_contains "$args" "--proto =https"
  assert_contains "$args" "https://api.github.com/app/installations/77/access_tokens"
  assert_contains "$args" '--data-binary {"x":1}'
  assert_contains "$(grep '^curl-stdin:' "$FAKE_LOG")" "curl-stdin:Authorization: Bearer $JWT" "the JWT on curl's standard input"
  assert_not_contains "$args" "$JWT" "the JWT in curl's arguments"
  assert_eq "$(ls -A "$WORK")" "" "a file left in the work folder"
  assert_eq "$LAST_HTTP" 201
  assert_eq "$LAST_OUT" '{"fake":"answer"}'
  export FAKE_HTTP=401
  if jwt_call GET app; then _t_fail "a 401 answer passed"; fi
}

test_app_identity_needs_the_owners_app_and_one_selected_installation() {
  app_stubs
  need_app_identity >/dev/null 2>&1 || _t_fail "the owner's app was refused"
  assert_eq "$INSTALLATION_ID" 77
  assert_eq "$APP_BOT" "frg26-test-app[bot]"
  local name json rc
  # Round 20, C1: the app's own permissions too (a change awaiting the installation's approval).
  for name in "someone else's app|app|.owner.login = \"someone\"" \
    "the app asks for an extra permission|app|.permissions.administration = \"read\"" \
    "the app asks for a wider permission|app|.permissions.metadata = \"write\"" \
    "the app lists no permissions|app|del(.permissions)" \
    "another app id|app|.id = 999" \
    "two installations|inst|. + ." \
    "all repositories|inst|.[0].repository_selection = \"all\"" \
    "an extra permission|inst|.[0].permissions.administration = \"read\"" \
    "a missing permission|inst|del(.[0].permissions.issues)" \
    "a suspended installation|inst|.[0].suspended_at = \"2026-11-01T00:00:00Z\""; do
    IFS='|' read -r name json filter <<<"$name"
    rm -f "$T_TMP/app.json" "$T_TMP/inst.json"
    if [[ "$json" == app ]]; then app_fixture | jq -c "$filter" >"$T_TMP/app.json"
    else installations_fixture | jq -c "$filter" >"$T_TMP/inst.json"; fi
    rc=0; (need_app_identity) >/dev/null 2>&1 || rc=$?
    assert_exit 2 "$rc" "$name"
  done
}

test_mint_asks_for_exactly_the_throwaway_and_four_permissions() {
  app_stubs
  INSTALLATION_ID=77
  mint_token >/dev/null 2>&1 || _t_fail "a token for exactly what was asked was refused"
  assert_eq "$TOKEN" "$(fake_token)"
  assert_eq "$(jq -S -c . "$T_TMP/last-body.json")" '{"permissions":{"contents":"write","issues":"write","metadata":"read","pull_requests":"write"},"repositories":["forge-frg26-throwaway"]}' "the token request"
  assert_eq "$(cat "$T_TMP/app-gh.log")" "" "a good token was revoked"
  end_stand_in_run
}

# Round 31 (the owner's run, 2026-11-06): GitHub now issues stateless tokens; mint must take them.
test_mint_takes_githubs_stateless_token_format() {
  app_stubs
  INSTALLATION_ID=77
  token_fixture | jq -c --arg t "$(new_token)" '.token = $t' >"$T_TMP/token.json"
  [[ $(new_token | wc -c) -gt 500 ]] || _t_fail "the stand-in is not about 520 characters"
  mint_token >/dev/null 2>&1 || _t_fail "a stateless token for exactly what was asked was refused"
  assert_eq "$TOKEN" "$(new_token)"
  assert_contains "$OUTSTANDING" "$(new_token)" "the token is revoked on exit"
  assert_eq "$(cat "$T_TMP/app-gh.log")" "" "a good token was revoked"
  end_stand_in_run
}

# Round 31: a token GitHub issued but the script refuses is still revoked, and never shown.
test_a_token_mint_refuses_is_still_revoked() {
  local name tok rc out
  for name in "an unexpected character|ghs_abc!def$(printf 'Q%.0s' $(seq 1 30))" "another prefix|ghx_$(printf 'Q%.0s' $(seq 1 40))"; do
    IFS='|' read -r name tok <<<"$name"
    app_stubs
    INSTALLATION_ID=77
    token_fixture | jq -c --arg t "$tok" '.token = $t' >"$T_TMP/token.json"
    rc=0; out="$(mint_token 2>&1)" || rc=$?
    assert_exit 2 "$rc" "$name"
    assert_not_contains "$out" "$tok" "the token printed ($name)"
    assert_eq "$(cat "$T_TMP/app-gh.log")" "api -X DELETE installation/token" "revoked ($name)"
  done
  # Round 32 (C1, SEC-1): when the first revocation fails, the exit clean-up tries again.
  app_stubs
  INSTALLATION_ID=77
  tok="ghx_$(printf 'Q%.0s' $(seq 1 40))"
  token_fixture | jq -c --arg t "$tok" '.token = $t' >"$T_TMP/token.json"
  app_gh() { echo "${TOKEN:0:8} $*" >>"$T_TMP/app-gh.log"; [[ -f "$T_TMP/deleted-once" ]] || { : >"$T_TMP/deleted-once"; return 1; }; }
  # The real run's exit clean-up calls revoke_outstanding; die exits the subshell, so the trap runs.
  rc=0; out="$(trap revoke_outstanding EXIT; mint_token 2>&1)" || rc=$?
  assert_exit 2 "$rc" "a refused token whose revocation failed"
  assert_eq "$(grep -c "^ghx_QQQQ api -X DELETE installation/token$" "$T_TMP/app-gh.log")" 2 "the first revocation of a refused token fails, then the exit retries it"
  assert_not_contains "$out" "$tok" "the token printed (failed revocation)"
  # Control: an answer with no token at all has nothing to revoke.
  app_stubs
  INSTALLATION_ID=77
  token_fixture | jq -c 'del(.token)' >"$T_TMP/token.json"
  rc=0; out="$(mint_token 2>&1)" || rc=$?
  assert_exit 2 "$rc" "no token"
  assert_contains "$out" "holds no installation token"
  assert_eq "$(cat "$T_TMP/app-gh.log")" "" "a revocation with no token"
}

test_mint_throws_away_a_token_with_more_than_asked() {
  # Plan 4.2 step 3: a token with more than was asked for is revoked, never used.
  local name filter rc out
  for name in "an extra permission|.permissions.administration = \"write\"" \
    "a wider permission|.permissions.metadata = \"write\"" \
    "another repository|.repositories += [{\"full_name\":\"Thebigtuna88/forge\"}]" \
    "every repository|.repository_selection = \"all\""; do
    IFS='|' read -r name filter <<<"$name"
    app_stubs
    INSTALLATION_ID=77
    token_fixture | jq -c "$filter" >"$T_TMP/token.json"
    rc=0; out="$(mint_token 2>&1)" || rc=$?
    assert_exit 2 "$rc" "$name"
    assert_contains "$out" "revoked"
    assert_not_contains "$out" "$(fake_token)" "the token printed ($name)"
    assert_eq "$(cat "$T_TMP/app-gh.log")" "api -X DELETE installation/token" "revoked ($name)"
  done
  app_stubs
  INSTALLATION_ID=77
  token_fixture | jq -c '.token = "not-an-installation-token"' >"$T_TMP/token.json"
  rc=0; (mint_token) >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "a token that isn't an installation token"
}

test_the_installation_reaches_only_the_throwaway() {
  # Plan item 9 (test A2's precondition): the installation itself, not only the token, is limited
  # to the throwaway repo. Read with a token minted for the whole installation, then revoked.
  app_stubs
  INSTALLATION_ID=77
  app_gh() {
    echo "$*" >>"$T_TMP/app-gh.log"
    case "$*" in "api installation/repositories"*) cat "$T_TMP/repos.txt" ;; esac
  }
  printf 'Thebigtuna88/forge-frg26-throwaway\n' >"$T_TMP/repos.txt"
  local rc=0
  (need_installation_scope) >/dev/null 2>&1 || rc=$?
  assert_exit 0 "$rc" "only the throwaway"
  assert_eq "$(jq -c . "$T_TMP/last-body.json")" "{}" "the whole-installation token request"
  assert_contains "$(cat "$T_TMP/app-gh.log")" "api -X DELETE installation/token"
  printf 'Thebigtuna88/forge-frg26-throwaway\nThebigtuna88/forge\n' >"$T_TMP/repos.txt"
  : >"$T_TMP/app-gh.log"
  rc=0; (need_installation_scope) >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "installed on another repo too"
  assert_contains "$(cat "$T_TMP/app-gh.log")" "api -X DELETE installation/token" "revoked after a refusal too"
}

# Round 51 (SEC-1): closing the Terminal (HUP), Ctrl-C (INT) or a kill (TERM) ends the script through
# its clean-up too, so tokens are revoked and checked: with the shell the handoffs use (/bin/bash -p),
# whether the signal comes while it runs or while it waits on a command (a gh call).
test_a_termination_signal_still_runs_the_clean_up() {
  local sig want out rc
  for sig in HUP:129 INT:130 TERM:143; do
    want="${sig#*:}" sig="${sig%%:*}"
    rc=0
    out="$(/bin/bash -p -c 'source "$1"; cleanup() { echo "cleanup-ran"; }; kill -s "$2" $$; sleep 2; echo not-stopped' _ "$GT" "$sig" 2>&1)" || rc=$?
    assert_exit "$want" "$rc" "SIG$sig"
    assert_contains "$out" "cleanup-ran" "SIG$sig"
    assert_not_contains "$out" "not-stopped" "SIG$sig"
    rc=0
    out="$(/bin/bash -p -c 'source "$1"; cleanup() { echo "cleanup-ran"; }; me=$$; ( /bin/sleep 1; kill -s "$2" $me ) & /bin/sleep 3; echo not-stopped' _ "$GT" "$sig" 2>&1)" || rc=$?
    assert_exit "$want" "$rc" "SIG$sig while waiting on a command"
    assert_contains "$out" "cleanup-ran" "SIG$sig while waiting on a command"
    assert_not_contains "$out" "not-stopped" "SIG$sig while waiting on a command"
  done
}

test_the_token_is_revoked_on_exit() {
  load
  TOKEN="$(fake_token)"
  # Registered as request_token does: its expiry as GitHub gave it (round 74: without it, HTTP 401
  # can't confirm the revocation).
  ISSUED=" token1=$TOKEN"
  ISSUED_META="token1 {\"expires_at\":\"$(date -u -v+50M +%Y-%m-%dT%H:%M:%SZ)\"}
"
  WORK=""
  app_gh() {
    echo "$*" >>"$T_TMP/app-gh.log"
    [[ "$*" != "api repos/$REPO --jq .full_name" ]] || { echo "gh: Bad credentials (HTTP 401)" >&2; return 1; }
  }
  local out rc=0
  out="$(cleanup)" || rc=$?
  assert_exit 0 "$rc" "a token revoked and confirmed"
  # Round 72: revoked, then confirmed by a read (HTTP 401).
  assert_eq "$(cat "$T_TMP/app-gh.log")" "api -X DELETE installation/token
api repos/$REPO --jq .full_name"
  assert_contains "$out" "CLEANUP DONE: tokens confirmed revoked (HTTP 401): token1;"
  end_stand_in_run
}

test_redact_hides_the_jwt_too() {
  load
  JWT="aaa.bbb.ccc"
  local out
  out="$(say "sent $JWT")"
  assert_not_contains "$out" "$JWT"
  assert_contains "$out" "[REDACTED]"
}

test_codeowners_attacks_name_the_app() {
  load
  APP_BOT="frg26-test-app[bot]"
  PHASE=open
  RUN_ID=r1
  CLONE="$T_TMP/clone"
  mkdir -p "$CLONE/.github" "$CLONE/docs"
  fresh_from() { :; }
  app_git() { :; }
  push_branch() { :; }
  app_pr() { return 1; }
  ( codeowners_pr B3 github ) >/dev/null 2>&1 || true
  assert_contains "$(cat "$CLONE/.github/CODEOWNERS")" "* @frg26-test-app[bot]"
}

test_m4_tries_adding_the_app_as_a_ruleset_bypass() {
  # With a helper account, adding it as a bypass was skipped when the ruleset used the admin role.
  # An app has a proven form whichever role the ruleset uses: an Integration actor (plan 6, M4).
  load
  APP_ID=123456
  PHASE=ruleset
  WORK="$T_TMP/work"
  mkdir -p "$WORK"
  owner_gh() {
    case "$*" in
      "api repos/$REPO/rulesets --jq .[0].id") echo 9 ;;
      "api repos/$REPO/rulesets/9") printf '{"id":9,"name":"main: only the owner","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["refs/heads/main"],"exclude":[]}},"rules":[{"type":"deletion"}],"bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]}' ;;
    esac
  }
  admin_attempts() { printf '%s\n' "$@" >"$T_TMP/attempts"; }
  local out
  out="$(t_M4)"
  assert_not_contains "$out" "skipped"
  assert_contains "$(cat "$T_TMP/attempts")" "$WORK/ruleset-app.json"
  assert_eq "$(jq -c '.bypass_actors' "$WORK/ruleset-app.json")" '[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"},{"actor_id":123456,"actor_type":"Integration","bypass_mode":"always"}]'
}

test_the_helper_commands_are_gone() {
  # D9: FORGE no longer uses the helper account; its commands and secrets file are not read.
  local usage
  usage="$(grep 'die "usage: github-throwaway.sh' "$GT")"
  assert_contains "$usage" "check-app"
  assert_not_contains "$usage" "invite"
  assert_not_contains "$usage" "accept"
  assert_not_contains "$usage" "check-helper"
  assert_not_contains "$usage" "diagnose"
  assert_eq "$(grep -c 'helper.env\|HELPER_TOKEN\|HELPER_LOGIN' "$GT" || true)" "0" "the helper's secrets are still read"
}

# --- Kind P: forbidden by GitHub from the outset, each with a control (plan section 6) ----------

test_a_permission_test_needs_a_refusal_and_a_working_control() {
  load
  FAILS=0
  local out
  out="$(record_p A6 refused ok "403"; echo "fails=$FAILS")"
  assert_contains "$out" "RESULT A6 permissions PASS attempt=refused control=ok"
  assert_contains "$out" "fails=0"
  # A refusal whose control failed proves nothing: the request may simply have been malformed.
  out="$(record_p A6 refused failed "403"; echo "fails=$FAILS")"
  assert_contains "$out" "RESULT A6 permissions FAIL"
  out="$(record_p A6 allowed ok "200"; echo "fails=$FAILS")"
  assert_contains "$out" "RESULT A6 permissions FAIL"
  out="$(record_p A6 inconclusive ok "HTTP 502"; echo "fails=$FAILS")"
  assert_contains "$out" "RESULT A6 permissions FAIL"
  assert_contains "$out" "fails=1"
}

test_classify_push_perm() {
  load
  LAST_RC=1
  # Round 112 (owner): git's words of a refusal are not enough (round112-plan.md's proposal is pending).
  LAST_OUT="remote: Permission to Thebigtuna88/forge-frg26-throwaway-2.git denied to frg26-test-app[bot].
fatal: unable to access 'https://github.com/Thebigtuna88/forge-frg26-throwaway-2.git/': The requested URL returned error: 403"
  assert_eq "$(classify_push_perm)" inconclusive "permission denied"
  LAST_OUT="! [remote rejected] HEAD -> x (refusing to allow a GitHub App to create or update workflow \`.github/workflows/x.yml\` without \`workflows\` permission)"
  assert_eq "$(classify_push_perm)" inconclusive "the workflows permission"
  LAST_OUT="fatal: unable to access 'https://github.com/x/': Could not resolve host: github.com"
  assert_eq "$(classify_push_perm)" inconclusive "a network error"
  LAST_OUT="remote: error: GH006: Protected branch update failed"
  assert_eq "$(classify_push_perm)" inconclusive "a protection refusal is not a permission refusal"
  LAST_RC=0
  assert_eq "$(classify_push_perm)" allowed
}

p_stubs() { # app and owner calls are logged; answers come from $T_TMP/answers (pattern|rc|text)
  load
  PHASE=permissions
  FAILS=0
  RUN_ID=r1
  APP_ID=123456
  INSTALLATION_ID=77
  CLONE="$T_TMP/clone"
  WORK="$T_TMP/work"
  mkdir -p "$CLONE" "$WORK"
  : >"$T_TMP/calls"
  : >"$T_TMP/answers"
  answer() { # <who> <args…>
    local who="$1" line pat rc text
    shift
    echo "$who $*" >>"$T_TMP/calls"
    while IFS='|' read -r pat rc text; do
      [[ -n "$pat" ]] || continue
      if [[ "$who $*" == *$pat* ]]; then
        # @<file>: that file's bytes exactly (round 112: a whole gh api -i answer, gh_reply's)
        if [[ "$text" == @* ]]; then cat "$T_TMP/${text#@}"; elif [[ -n "$text" ]]; then printf '%s\n' "$text"; fi
        return "$rc"
      fi
    done <"$T_TMP/answers"
    return 0
  }
  app_gh() { answer app_gh "$@"; }
  app_git() { answer app_git "$@"; }
  owner_gh() { answer owner_gh "$@"; }
  # Round 115: the app's attempt goes through curl; its stand-in answers as the gh-era stand-ins did
  # (app_gh's answer for the same arguments; gh's exit 1 for a refusal), then gives curl's own report:
  # the answer's own status, no redirect, TLS verified, the address asked. An answer with exit 0 and no
  # status line is GitHub's 200 with it as the body ({} for nothing); words without an HTTP answer and a
  # failure are a transfer that failed (curl 56).
  attempt_send() {
    local LC_ALL=C rc=0 st b
    app_gh api "$@" >"$T_TMP/sent.out" || rc=$?
    st="$(head -n 1 "$T_TMP/sent.out" | sed -n 's/^HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p')"
    if [[ $rc -eq 0 && -z "$st" ]]; then
      b="$(cat "$T_TMP/sent.out")"
      [[ -n "$b" ]] || b='{}'
      printf 'HTTP/2 200\r\nContent-Length: %s\r\n\r\n%s' "${#b}" "$b" >"$T_TMP/sent.out"
    fi
    st="$(head -n 1 "$T_TMP/sent.out" | sed -n 's/^HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p')"
    cat "$T_TMP/sent.out"
    [[ -n "$st" ]] || return 56
    printf '\n@@FRG26-CURL %s 0 0 https://api.github.com/%s' "$st" "$AT_PATH"
    if [[ $rc -le 1 ]]; then return 0; fi
    return "$rc"
  }
  fresh_from() { :; }
  add_commit() { echo "commit $1" >>"$T_TMP/calls"; }
  sleep() { :; }
}

# A gh api -i answer as GitHub gives it (round 112), to $T_TMP/<file>: by default a complete 403 for an
# operation that needs administration=write. Each change alters it: status=<line>, body=<text>,
# drop=<header name>, add=<header line>, len=<a Content-Length of its own>, cut (no blank line after the
# headers, no body), raw=<the whole output> (no status line).
gh_reply() { # <file> [change…]
  local LC_ALL=C f="$T_TMP/$1" status="HTTP/2.0 403 Forbidden" raw="" len="" cut="" c h
  local body='{"message":"Resource not accessible by integration","documentation_url":"https://docs.github.com/rest","status":"403"}'
  local heads=("Content-Type: application/json" "X-Accepted-Github-Permissions: administration=write"
    "X-Github-Request-Id: C0DE:1A2B:3C4D5E:6F7A8B:9C0D1E2F" "X-Ratelimit-Remaining: 4979" "X-Ratelimit-Resource: core")
  shift
  for c in "$@"; do
    case "$c" in
      status=*) status="${c#status=}" ;;
      body=*) body="${c#body=}" ;;
      raw=*) raw="${c#raw=}" ;;
      len=*) len="${c#len=}" ;;
      cut) cut=1 ;;
      add=*) heads+=("${c#add=}") ;;
      drop=*)
        local keep=()
        for h in "${heads[@]}"; do [[ "${h%%:*}" == "${c#drop=}" ]] || keep+=("$h"); done
        heads=(${keep[@]+"${keep[@]}"}) ;;
    esac
  done
  if [[ -n "$raw" ]]; then printf '%s' "$raw" >"$f"; return; fi
  {
    printf '%s\r\nContent-Length: %s\r\n' "$status" "${len:-${#body}}"
    for h in ${heads[@]+"${heads[@]}"}; do printf '%s\r\n' "$h"; done
    [[ -n "$cut" ]] || printf '\r\n%s' "$body"
  } >"$f"
}

# A page of a list as gh api -i prints it (round 118): GitHub's 200, its Content-Type, a Content-Length of
# <body>'s bytes (round 119) and each header line given, then an empty line and <body>.
gh_page() { # <body> [header line…]
  local LC_ALL=C b="$1" h
  shift
  printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: %s\r\n' "${#b}"
  for h in ${1+"$@"}; do printf '%s\r\n' "$h"; done
  printf '\r\n%s' "$b"
}

# A Link header's value in GitHub's form (round 118), naming each <rel> at <page>: its URLs on a host
# never asked, so a URL followed or printed shows.
gh_link() { # <rel>:<page>[,<rel>:<page>…]
  local l out="" IFS=,
  for l in $1; do out="$out, <https://links.example.invalid/repositories/1/list?per_page=100&page=${l#*:}>; rel=\"${l%%:*}\""; done
  printf '%s' "${out#, }"
}

a2_answers() { # the owner's reads A2 needs, then the given lines
  local a b
  # A2 reads the second throwaway's refs under with_timeout, whose watchdog needs the real sleep
  # (p_stubs makes it instant, which would stop every read at once).
  unset -f sleep
  a="$(printf 'a%.0s' $(seq 1 40))" b="$(printf 'b%.0s' $(seq 1 40))"
  # Round 118: each page as gh api -i prints it.
  gh_page "[{\"name\":\"frg26-a2\",\"commit\":{\"sha\":\"$a\"}}]" >"$T_TMP/page-heads"
  gh_page '[]' >"$T_TMP/page-end"
  {
    echo "owner_gh api repos/$REPO2/branches/main --jq .commit.sha|0|$a"
    echo "owner_gh api repos/$REPO/branches/dev --jq .commit.sha|0|$b"
    # Round 117: its branches and tags as their paged lists, each read through to an empty page.
    echo "owner_gh api -i repos/$REPO2/branches?per_page=100&page=1|0|@page-heads"
    echo "owner_gh api -i repos/$REPO2/branches?per_page=100&page=2|0|@page-end"
    echo "owner_gh api -i repos/$REPO2/tags?per_page=100&page=1|0|@page-end"
    echo "owner_gh api -i repos/$REPO2/tags?per_page=100&page=2|0|@page-end" # (a look-alike's list, read through)
    printf '%s\n' "$@"
  } >"$T_TMP/answers"
}

test_a2_tries_code_changes_on_a_repo_the_app_is_not_installed_on() {
  p_stubs
  # Round 112 (owner): a push that fails is inconclusive (its refusal can't yet be told from a
  # transport failure), so A2 stops there, by the stop rule, before its API attempts.
  a2_answers "app_git -C $T_TMP/clone push https://github.com/$REPO2.git|1|remote: Permission to $REPO2.git denied to frg26-test-app[bot]."
  local out calls
  WRITES_UNKNOWN="" WRITES_OUT=""
  t_A2 >"$T_TMP/out" 2>&1
  out="$(cat "$T_TMP/out")"
  assert_contains "$out" "RESULT A2 permissions FAIL attempt=inconclusive control=not run"
  calls="$(cat "$T_TMP/calls")"
  assert_contains "$calls" "app_git -C $T_TMP/clone push https://github.com/$REPO2.git HEAD:refs/heads/frg26-a2-r1"
  assert_contains "$(unknown_writes)" "app git push https://github.com/$REPO2.git HEAD:refs/heads/frg26-a2-r1" "the push named outcome unknown"
  assert_not_contains "$calls" "app_gh api -X PUT repos/$REPO2" "an API attempt after an inconclusive push"
  assert_not_contains "$calls" "push origin" "a control after an inconclusive push"
  # Owner 2026-11-15: no issue or PR is tried there any more.
  assert_not_contains "$calls" "repos/$REPO2/issues" "an issue on the second throwaway"
  assert_not_contains "$calls" "repos/$REPO2/pulls" "a PR on the second throwaway"
  # A write that got through to the other repo fails the test, and nothing more is tried there.
  a2_answers "app_git -C $T_TMP/clone push https://github.com/$REPO2.git|0|"
  : >"$T_TMP/calls"
  out="$(t_A2)"
  assert_contains "$out" "RESULT A2 permissions FAIL attempt=allowed"
  assert_not_contains "$(cat "$T_TMP/calls")" "-X PUT repos/$REPO2" "attempts after one got through"
  end_stand_in_run
}

# Round 70 (C1, SEC-1): only the exact branch counts; a look-alike branch or tag, with frg26-a2
# missing, would let the file attempt's "Branch not found" (404) pass as a refusal.
test_a2_needs_the_exact_branch_not_a_look_alike() {
  local a case heads tags out
  a="$(printf 'a%.0s' $(seq 1 40))"
  # Round 117: the branches and tags as their lists give them (a name and its commit).
  for case in "a look-alike branch|[{\"name\":\"main\",\"commit\":{\"sha\":\"$a\"}},{\"name\":\"x/refs/heads/frg26-a2\",\"commit\":{\"sha\":\"$a\"}}]|[]" \
    "a look-alike tag|[{\"name\":\"main\",\"commit\":{\"sha\":\"$a\"}}]|[{\"name\":\"refs/heads/frg26-a2\",\"commit\":{\"sha\":\"$a\"}}]" \
    "a tag named as the branch|[{\"name\":\"main\",\"commit\":{\"sha\":\"$a\"}}]|[{\"name\":\"frg26-a2\",\"commit\":{\"sha\":\"$a\"}}]"; do
    IFS='|' read -r name heads tags <<<"$case"
    p_stubs
    a2_answers "app_git -C $T_TMP/clone push https://github.com/$REPO2.git|1|remote: Permission to $REPO2.git denied to frg26-test-app[bot]." \
      "app_gh api -X PUT repos/$REPO2/|1|gh: Branch not found (HTTP 404)" \
      "app_gh api -X POST repos/$REPO2/|1|gh: Resource not accessible by integration (HTTP 403)"
    owner_gh() {
      case "$*" in
        "api -i repos/$REPO2/branches?per_page=100&page=1") echo "owner_gh $*" >>"$T_TMP/calls"; gh_page "$heads" ;;
        "api -i repos/$REPO2/tags?per_page=100&page=1") echo "owner_gh $*" >>"$T_TMP/calls"; gh_page "$tags" ;;
        "api repos/$REPO2/git/ref/tags/"*) printf '{"ref":"refs/tags/%s","object":{"type":"commit","sha":"%s"}}\n' "${*#"api repos/$REPO2/git/ref/tags/"}" "$a" ;;
        *) answer owner_gh "$@" ;;
      esac
    }
    out="$(t_A2)"
    assert_contains "$out" "RESULT A2 permissions FAIL attempt=setup-failed" "$name"
    assert_not_contains "$out" "permissions PASS" "$name"
    assert_not_contains "$(cat "$T_TMP/calls")" "app_git" "$name: an attempt without the branch"
    assert_contains "$(cat "$T_TMP/calls")" "owner_gh api -i repos/$REPO2/tags?per_page=100&page=1" "$name: the tags read"
    assert_not_contains "$(cat "$T_TMP/calls")" "matching-refs" "$name: the refs read by matching-refs"
  done
}

# Round 112: A2's API attempts (reached once a push can be shown refused) are settled against the second
# throwaway's whole branch and tag list read before them: a branch that appeared makes them inconclusive,
# every write still unknown; an unchanged list, with complete refusals, settles both.
test_a2_api_attempts_are_settled_only_against_the_second_throwaways_refs() {
  local case name more want
  for case in "unchanged|0|refused" "a branch appeared|1|inconclusive" \
    "an annotated tag, unchanged|same-tag|refused" "an annotated tag made again on the same commit|tag|inconclusive"; do
    IFS='|' read -r name more want <<<"$case"
    p_stubs
    gh_reply reply drop=X-Accepted-Github-Permissions "add=X-Accepted-Github-Permissions: contents=write"
    a2_answers "app_gh api -X PUT repos/$REPO2/|1|@reply" "app_gh api -X POST repos/$REPO2/|1|@reply"
    echo "$more" >"$T_TMP/more"
    # Round 117: the branches as their paged list gives them (round 115: as GitHub's JSON); the first
    # read is the baseline's, before the attempts.
    answer_refs() {
      local n=0 a
      a="$(printf 'a%.0s' $(seq 1 40))"
      [[ -f "$T_TMP/refs-reads" ]] && n="$(cat "$T_TMP/refs-reads")"
      echo $((n + 1)) >"$T_TMP/refs-reads"
      if [[ $n -ge 1 && "$(cat "$T_TMP/more")" == 1 ]]; then
        printf '[{"name":"frg26-a2","commit":{"sha":"%s"}},{"name":"sneaked","commit":{"sha":"0123456789abcdef0123456789abcdef01234567"}}]\n' "$a"
      else
        printf '[{"name":"frg26-a2","commit":{"sha":"%s"}}]\n' "$a"
      fi
    }
    # Round 117b: a tag v1 on the same commit throughout; "tag" makes it again (a new tag object) after
    # the baseline's lookup.
    answer_tag() {
      local n=0 o
      [[ -f "$T_TMP/tag-reads" ]] && n="$(cat "$T_TMP/tag-reads")"
      echo $((n + 1)) >"$T_TMP/tag-reads"
      o="$(printf 'c%.0s' $(seq 1 40))"
      if [[ $n -ge 1 && "$(cat "$T_TMP/more")" == tag ]]; then o="$(printf 'd%.0s' $(seq 1 40))"; fi
      printf '{"ref":"refs/tags/v1","object":{"type":"tag","sha":"%s"}}\n' "$o"
    }
    owner_gh() {
      case "$*" in
        "api -i repos/$REPO2/branches?per_page=100&page=1") echo "owner_gh $*" >>"$T_TMP/calls"; gh_page "$(answer_refs)" ;;
        "api -i repos/$REPO2/branches?per_page=100&page=2" | "api -i repos/$REPO2/tags?per_page=100&page=2") gh_page '[]' ;;
        "api -i repos/$REPO2/tags?per_page=100&page=1")
          if [[ "$(cat "$T_TMP/more")" == *tag ]]; then gh_page "[{\"name\":\"v1\",\"commit\":{\"sha\":\"$(printf 'b%.0s' $(seq 1 40))\"}}]"; else gh_page '[]'; fi ;;
        "api repos/$REPO2/git/ref/tags/v1") echo "owner_gh $*" >>"$T_TMP/calls"; answer_tag ;;
        *) answer owner_gh "$@" ;;
      esac
    }
    rm -f "$T_TMP/refs-reads" "$T_TMP/tag-reads"
    WRITES_UNKNOWN="" WRITES_OUT=""
    p_attempts api A2 app_gh api -X PUT "repos/$REPO2/contents/x.txt" -f message=m ";;" \
      app_gh api -X POST "repos/$REPO2/git/refs" -f ref=refs/heads/x -f sha=a >/dev/null 2>&1
    assert_eq "$OBS" "$want" "$name"
    if [[ "$want" == refused ]]; then
      assert_eq "$(unknown_writes)" "" "$name: a write still named outcome unknown"
    else
      assert_contains "$EV" "CHANGED since before the attempts" "$name"
      assert_contains "$(unknown_writes)" "app gh api PUT repos/$REPO2/contents/x.txt (" "$name: the file write named outcome unknown"
      assert_contains "$(unknown_writes)" "app gh api POST repos/$REPO2/git/refs (" "$name: the branch write named outcome unknown"
    fi
  done
  end_stand_in_run
}

test_a3_pushes_a_workflow_file_and_a_plain_file() {
  p_stubs
  # Round 112 (owner): a failed push is inconclusive until a completed rejection can be told from a
  # transport failure, so no control follows it.
  cat >"$T_TMP/answers" <<'EOF'
push origin HEAD:refs/heads/frg26/permissions/A3-wf-r1|1|! [remote rejected] HEAD -> frg26/permissions/A3-wf-r1 (refusing to allow a GitHub App to create or update workflow `.github/workflows/frg26-a3-r1.yml` without `workflows` permission)
EOF
  local out
  out="$(t_A3)"
  assert_contains "$out" "RESULT A3 permissions FAIL attempt=inconclusive control=not run"
  assert_contains "$(cat "$T_TMP/calls")" "commit .github/workflows/frg26-a3-r1.yml"
  assert_not_contains "$(cat "$T_TMP/calls")" "commit tests/permissions-A3-r1.txt" "a control after an inconclusive push"
  # A workflow file pushed is a FAIL, the control not run.
  : >"$T_TMP/answers"
  out="$(t_A3)"
  assert_contains "$out" "RESULT A3 permissions FAIL attempt=allowed control=not run"
}

test_a5_a_revoked_token_stops_working() {
  p_stubs
  TOKEN="$(fake_token)"
  local session="$TOKEN"
  mint_token() { TOKEN="ghs_second$(printf 'Q%.0s' $(seq 1 30))"; }
  revoke_token() { echo "revoke ${TOKEN:0:10}" >>"$T_TMP/calls"; REVOKED_TOKENS="$REVOKED_TOKENS $TOKEN"; TOKEN=""; }
  app_gh() {
    echo "app_gh ${TOKEN:0:10} $*" >>"$T_TMP/calls"
    if [[ " $REVOKED_TOKENS " == *" $TOKEN "* ]]; then echo "gh: Bad credentials (HTTP 401)" >&2; return 1; fi
    echo "$REPO"
  }
  local out
  out="$(t_A5)"
  assert_contains "$out" "RESULT A5 permissions PASS attempt=refused control=ok"
  assert_eq "$(cat "$T_TMP/calls")" "app_gh ghs_second api repos/$REPO --jq .full_name
revoke ghs_second
app_gh ghs_second api repos/$REPO --jq .full_name"
  t_A5 >/dev/null
  assert_eq "$TOKEN" "$session" "the session token after A5"
  # A stand-in run's token: its end is no clean-up (round 74: nor a request to GitHub).
  end_stand_in_run
}

test_a6_tries_settings_and_its_own_installation() {
  p_stubs
  gh_reply reply
  cat >"$T_TMP/answers" <<EOF
owner_gh api repos/$REPO --jq .id|0|4242
app_gh api -X PATCH repos/$REPO|1|@reply
app_gh api -X PUT user/installations/77/repositories/4242|1|@reply
EOF
  local out
  out="$(t_A6)"
  # Round 112 (owner): A6 stays inconclusive, so its control (the owner's same no-op) isn't run.
  assert_contains "$out" "RESULT A6 permissions FAIL attempt=inconclusive control=not run"
  local calls
  calls="$(cat "$T_TMP/calls")"
  assert_contains "$calls" "app_gh api -X PATCH repos/$REPO -f description=$MARKER"
  assert_contains "$calls" "app_gh api -X PUT user/installations/77/repositories/4242"
  end_stand_in_run
}

# A8's six reads, each answered by GitHub's complete refusal naming the permission its endpoint needs.
a8_replies() {
  local p
  for p in secrets=read actions_variables=read administration=read repository_hooks=read; do
    gh_reply "reply-${p%%=*}" drop=X-Accepted-Github-Permissions "add=X-Accepted-Github-Permissions: $p"
  done
  cat >"$T_TMP/answers" <<EOF
app_gh api repos/$REPO/actions/secrets|1|@reply-secrets
app_gh api repos/$REPO/actions/variables|1|@reply-actions_variables
app_gh api repos/$REPO/keys|1|@reply-administration
app_gh api repos/$REPO/invitations|1|@reply-administration
app_gh api repos/$REPO/hooks|1|@reply-repository_hooks
EOF
}

test_a8_tries_secrets_variables_keys_hooks_and_collaborators() {
  p_stubs
  a8_replies
  local out calls p
  out="$(t_A8)"
  assert_contains "$out" "RESULT A8 permissions PASS attempt=refused control=ok"
  calls="$(cat "$T_TMP/calls")"
  for p in actions/secrets actions/secrets/public-key actions/variables keys hooks; do
    assert_contains "$calls" "app_gh api repos/$REPO/$p"
  done
  assert_contains "$calls" "app_gh api repos/$REPO/invitations"
  assert_not_contains "$calls" "collaborators" "a collaborator write with no valid target or control (round 13, SEC-5)"
  for p in actions/secrets actions/secrets/public-key actions/variables keys hooks invitations; do
    assert_contains "$calls" "owner_gh api repos/$REPO/$p"
  done
  # Round 15, C2: each attempt has its own control; one failing fails A8.
  a8_replies
  printf 'owner_gh api repos/%s/actions/secrets/public-key|1|gh: HTTP 502\n' "$REPO" | cat - "$T_TMP/answers" >"$T_TMP/answers.new"
  mv "$T_TMP/answers.new" "$T_TMP/answers"
  out="$(t_A8)"
  assert_contains "$out" "RESULT A8 permissions FAIL attempt=refused control=failed"
  assert_not_contains "$calls" "owner_gh api -X" "the control writes"
}

test_s1_reads_secrets_and_the_workflow_token() {
  p_stubs
  cat >"$T_TMP/answers" <<EOF
owner_gh api repos/$REPO/actions/secrets --jq .total_count|0|0
owner_gh api repos/$REPO/actions/permissions/workflow --jq .default_workflow_permissions|0|read
owner_gh api repos/$REPO/actions/permissions/workflow --jq .can_approve_pull_request_reviews|0|false
EOF
  local out
  out="$(t_S1; echo "fails=$FAILS")"
  assert_contains "$out" "RESULT S1 permissions PASS"
  printf 'owner_gh api repos/%s/actions/permissions/workflow --jq .default_workflow_permissions|0|write\n' "$REPO" >"$T_TMP/a2"
  cat "$T_TMP/answers" >>"$T_TMP/a2"
  mv "$T_TMP/a2" "$T_TMP/answers"
  out="$(t_S1; echo "fails=$FAILS")"
  assert_contains "$out" "RESULT S1 permissions FAIL"
  assert_contains "$out" "fails=1"
}

test_permission_tests_stop_at_the_first_failure() {
  load
  need_owner() { :; }
  assert_throwaway() { :; }
  assert_second() { :; }
  app_session() { :; }
  need_allowance() { :; }
  app_git() { :; }
  app_rate() { return 1; }
  owner_gh() { :; }
  WORK="$T_TMP/work"
  mkdir -p "$WORK"
  local id
  for id in $P_TEST_ORDER; do eval "t_$id() { echo \"RAN $id\"; record_p $id refused ok stand-in; }"; done
  local out rc=0
  out="$(cmd_ptests 2>&1)" || rc=$?
  assert_exit 0 "$rc"
  for id in $P_TEST_ORDER; do assert_contains "$out" "RAN $id"; done
  assert_contains "$out" "PERMISSION TESTS: ALL PASS"
  t_A3() { echo "RAN A3"; record_p A3 allowed ok stand-in; }
  rc=0; out="$(cmd_ptests 2>&1)" || rc=$?
  assert_exit 1 "$rc"
  assert_contains "$out" "STOPPED after A3"
  assert_not_contains "$out" "RAN A2" "a test after the failure"
}

test_permission_tests_cover_the_plan() {
  load
  assert_eq "$P_TEST_ORDER" "S1 A6 A8 A5 A3 A2 A11 A12"
  local id
  for id in $P_TEST_ORDER; do assert_eq "$(type -t "t_$id")" function "t_$id"; done
}

test_a11_and_a12_are_readings_not_results() {
  p_stubs
  printf 'app_gh api repos/%s/commits/main/check-runs|1|gh: Resource not accessible by integration (HTTP 403)\n' "$REPO" >"$T_TMP/answers"
  local out
  out="$(t_A11; echo "fails=$FAILS")"
  assert_contains "$out" "READING A11 check-runs: HTTP 403"
  assert_contains "$out" "READING A11 status: allowed"
  assert_contains "$out" "fails=0"
  out="$(t_A12; echo "fails=$FAILS")"
  assert_contains "$out" "READING A12 gh issue create: works"
  assert_contains "$out" "READING A12 gh run list: works"
  assert_contains "$out" "fails=0"
}

test_the_second_throwaways_branch_is_ahead_of_main() {
  # Round 15, SEC-1: a PR from a branch equal to main can't be opened by anyone, so a refusal would
  # prove nothing. The branch is made first, the commit goes on it. Since 2026-11-15 A2 writes a
  # file on that branch instead, so it checks the branch is there.
  load
  : >"$T_TMP/owner"
  owner_gh() {
    echo "$*" >>"$T_TMP/owner"
    case "$*" in
      "api repos/$REPO2") [[ -f "$T_TMP/made" ]] || return 1 ;;
      # Each write answered as GitHub does (round 111: an unexpected answer stops the command).
      "repo create"*) touch "$T_TMP/made"; echo "https://github.com/$REPO2" ;;
      *"/git/refs "*) printf '{"ref":"refs/heads/%s"}\n' "$A2_BRANCH" ;;
      *"/contents/a2.txt "*) printf '{"content":{"path":"a2.txt"}}\n' ;;
      *"--jq [.full_name"*) printf '%s\t%s\t%s\tfalse\n' "$REPO2" "$OWNER" "$MARKER2" ;;
      *"--jq .default_branch") echo main ;;
      *"--jq .commit.sha") printf 'e%.0s' $(seq 1 40); echo ;;
    esac
  }
  need_owner() { :; }
  cmd_create_second >/dev/null
  local refs contents
  refs="$(grep -n "git/refs" "$T_TMP/owner" | cut -d: -f1)"
  contents="$(grep -n "contents/a2.txt" "$T_TMP/owner" | cut -d: -f1)"
  [[ -n "$refs" && -n "$contents" && "$refs" -lt "$contents" ]] || _t_fail "the branch must be made before its commit"
  assert_contains "$(grep "contents/a2.txt" "$T_TMP/owner")" "branch=frg26-a2"
  p_stubs
  a2_answers
  gh_page "[{\"name\":\"main\",\"commit\":{\"sha\":\"$(printf 'a%.0s' $(seq 1 40))\"}}]" >"$T_TMP/page-heads"
  local out
  out="$(t_A2)"
  assert_contains "$out" "RESULT A2 permissions FAIL attempt=setup-failed" "frg26-a2 missing"
  assert_not_contains "$(cat "$T_TMP/calls")" "app_git" "an attempt without the branch"
}

test_assert_second_refuses_another_repo() {
  load
  owner_gh() { printf '%s\t%s\t%s\tfalse\n' "$REPO2" "$OWNER" "something else"; }
  local rc=0
  (assert_second) >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "another description"
  owner_gh() { printf '%s\t%s\t%s\tfalse\n' "$REPO2" "$OWNER" "$MARKER2"; }
  rc=0; (assert_second) || rc=$?
  assert_exit 0 "$rc" "the second throwaway"
}

test_a_permission_run_closes_its_test_issues() {
  load
  owner_gh() {
    echo "$*" >>"$T_TMP/owner"
    case "$*" in
      *"/issues?state=open"*) printf '11\n12\n' ;;
      "api repos/$REPO/issues/"*" --jq .state") echo closed ;;
    esac
  }
  : >"$T_TMP/owner"
  FAILS=0
  RUN_ID=20261102T010203Z-77
  local out
  out="$(sweep_issues; echo "fails=$FAILS")"
  assert_contains "$(cat "$T_TMP/owner")" "issue close 11 --repo $REPO"
  assert_contains "$(cat "$T_TMP/owner")" "issue close 12 --repo $REPO"
  # Round 102: each read back by its number.
  assert_contains "$(cat "$T_TMP/owner")" "api repos/$REPO/issues/11 --jq .state"
  assert_contains "$(cat "$T_TMP/owner")" "api repos/$REPO/issues/12 --jq .state"
  assert_contains "$(grep "repos/$REPO/issues" "$T_TMP/owner")" "20261102T010203Z-77" "only this run's issues are closed"
  # Round 13, SEC-4: the second throwaway is only read; an issue there is reported, never closed.
  assert_contains "$(cat "$T_TMP/owner")" "repos/$REPO2/issues?state=open"
  # Only this run's there: the A2 evidence (#1-#3) stays open and must not fail every run.
  assert_contains "$(grep "repos/$REPO2/issues" "$T_TMP/owner")" "20261102T010203Z-77" "only this run's issues there count"
  assert_not_contains "$(cat "$T_TMP/owner")" "--repo $REPO2" "an owner write to the second throwaway"
  assert_contains "$out" "CLEANUP FAIL"
  assert_contains "$out" "fails=1"
}

# --- S2: the Environment (plan 4.4) ----------------------------------------------------------

# shellcheck disable=SC2016 # the workflow's own text, searched for literally
test_s2_workflow_prints_only_the_values_length() {
  load
  local wf
  wf="$(s2_workflow)"
  assert_contains "$wf" 'environment: frg26-test'
  assert_contains "$wf" 'echo "FRG26-S2 value length ${#V}"'
  assert_contains "$wf" 'permissions: {}'
  assert_not_contains "$wf" 'echo "$V"' "the value itself is printed"
  assert_eq "$(grep -c 'secrets\.' <<<"$wf")" 1 "secrets the workflow reads"
}

test_env_setup_makes_exactly_the_environment_the_plan_names() {
  owner_cmd_stubs
  verify_phase() { :; }
  owner_uid() { echo 42; }
  env_summary() { want_env; }
  local rc=0
  cmd_env_setup >/dev/null 2>&1 || rc=$?
  assert_exit 0 "$rc"
  assert_eq "$(jq -S -c . "$WORK/env.json")" '{"deployment_branch_policy":{"custom_branch_policies":true,"protected_branches":false},"prevent_self_review":true,"reviewers":[{"id":42,"type":"User"}],"wait_timer":0}'
  assert_contains "$(cat "$T_TMP/owner")" "api -X PUT repos/$REPO/environments/frg26-test --input $WORK/env.json"
  assert_contains "$(cat "$T_TMP/owner")" "secret set FRG26_DUMMY --env frg26-test --repo $REPO --body frg26-dummy-not-a-secret"
  env_summary() { echo "false User:$OWNER false true branch:main"; }
  rc=0; (cmd_env_setup) >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "an Environment that lets the owner approve their own run"
}

# Round 31, C1: only a successful read of the branch policies may decide whether to add main.
test_env_setup_writes_nothing_more_when_the_policy_read_fails() {
  owner_cmd_stubs
  verify_phase() { :; }
  env_summary() { want_env; }
  owner_gh() { echo "$*" >>"$T_TMP/owner"
    if [[ "$1 $2" == "api repos/$REPO/environments/frg26-test/deployment-branch-policies" ]]; then
      [[ -f "$T_TMP/policies" ]] || return 1
      cat "$T_TMP/policies"
    fi
    owner_answer "$@"; }
  local rc=0 out
  out="$(cmd_env_setup 2>&1)" || rc=$?
  assert_exit 2 "$rc" "a failed policy read"
  assert_contains "$out" "can't read the Environment's branch policies"
  assert_not_contains "$(cat "$T_TMP/owner")" "-X POST" "a policy added after a failed read"
  assert_not_contains "$(cat "$T_TMP/owner")" "secret set" "the dummy value stored after a failed read"
  # Controls: main already listed adds nothing; an empty listing adds main once.
  echo main >"$T_TMP/policies"; : >"$T_TMP/owner"
  rc=0; cmd_env_setup >/dev/null 2>&1 || rc=$?
  assert_exit 0 "$rc"
  assert_not_contains "$(cat "$T_TMP/owner")" "-X POST" "a second main policy"
  : >"$T_TMP/policies"; : >"$T_TMP/owner"
  rc=0; cmd_env_setup >/dev/null 2>&1 || rc=$?
  assert_exit 0 "$rc"
  assert_eq "$(grep -c -- '-X POST' "$T_TMP/owner")" 1 "policies added to an empty listing"
}

s2_stubs() {
  p_stubs
  eid=9
  env_id() { echo 9; }
  run_log_value() { cat "$T_TMP/log-$1" 2>/dev/null || echo no; }
  wait_run() { RUN="$(cat "$T_TMP/run-$1" 2>/dev/null)"; [[ -n "$RUN" ]]; }
  approve_run() { echo "approve $1 $2" >>"$T_TMP/calls"; LAST_RC=0; LAST_OUT=ok
    if [[ -f "$T_TMP/refuse-$1-$2" ]]; then LAST_RC=1; LAST_OUT="$(cat "$T_TMP/refuse-$1-$2")"; return 1; fi; }
  cancel_waiting_runs() { :; }
}

test_s2b_the_app_cannot_approve_its_own_deployment() {
  # Round 112: GitHub's complete refusal of the app's attempt, its run read the same before and after it.
  s2d_stubs
  s2b_fixtures
  local out
  WRITES_UNKNOWN="" WRITES_OUT=""
  t_S2b >"$T_TMP/s2b.out" 2>&1
  out="$(cat "$T_TMP/s2b.out")"
  assert_contains "$out" "RESULT S2b permissions PASS attempt=refused control=ok"
  assert_contains "$(cat "$T_TMP/calls")" "app_gh api -X POST repos/$REPO/actions/runs/501/pending_deployments -F environment_ids[]=9 -f state=approved"
  assert_contains "$(cat "$T_TMP/calls")" "approve owner_gh 501"
  assert_contains "$(cat "$T_TMP/calls")" "app_git -C $T_TMP/clone push origin HEAD:refs/heads/main"
  assert_not_contains "$(unknown_writes)" "app gh api POST repos/$REPO/actions/runs/501/pending_deployments (" "the attempt, read back as before it"
  # The control fails when the job never got the value after the owner's approval.
  s2b_fixtures
  rm -f "$T_TMP/log-501"
  out="$(t_S2b)"
  assert_contains "$out" "RESULT S2b permissions FAIL attempt=refused control=failed"
  # The app approving its own run is a FAIL however the rest goes.
  s2b_fixtures
  : >"$T_TMP/answers"
  out="$(t_S2b)"
  assert_contains "$out" "RESULT S2b permissions FAIL attempt=allowed"
  end_stand_in_run
}

# GitHub's answer to the owner's approval of their own run, 2026-11-20 (part 0's environment-tests.log).
S2D_422='{"message":"Validation Failed","errors":"No pending deployment requests to approve or reject","documentation_url":"https://docs.github.com/rest/actions/workflow-runs#review-pending-deployments-for-a-workflow-run","status":"422"}'
S2D_GH_ERR="gh: No pending deployment requests to approve or reject (Validation Failed)"
# Headers as gh api -i prints them; @LEN@ becomes the body's length in bytes.
S2D_HEADERS='Content-Length: @LEN@\r\nContent-Type: application/json\r\nSet-Cookie: session=not-kept\r\nX-Github-Request-Id: C0DE:1A2B:3C4D5E:6F7A8B:9C0D1E2F\r\nX-Ratelimit-Remaining: 4979\r\nX-Ratelimit-Resource: core'

run_json() { # <id> <status> <sha> <actor> — a workflow run as GitHub returns it (fields S2 reads, and one it must not keep)
  printf '{"id":%s,"status":"%s","head_sha":"%s","actor":{"login":"%s"},"event":"push","head_branch":"main","name":"frg26-s2","head_commit":{"message":"a commit"}}\n' "$1" "$2" "$3" "$4"
}

# S2's GitHub (rounds 78-80): each owner read answers from a file, S2d's run 502 (deployment 7001) from
# $T_TMP/gh, S2b's run 501 (deployment 6001) from $T_TMP/gh-b: <what>, or <what>.<n> for its n-th
# call (1 before the approval, 2 after it); <file>.rc is its status, <file>.err its error output.
s2d_stubs() {
  s2_stubs
  S2_OWNER_SHA="$(printf 'b%.0s' $(seq 1 40))"
  S2B_SHA="$(printf 'a%.0s' $(seq 1 40))"
  APP_BOT="frg26-test-app[bot]"
  echo "502 waiting null Thebigtuna88" >"$T_TMP/run-$S2_OWNER_SHA"
  owner_gh() {
    local k n f d="$T_TMP/gh" r=502 s="$S2_OWNER_SHA" p=7001
    echo "owner_gh $*" >>"$T_TMP/calls"
    if [[ "$*" == *"/runs/501"* || "$*" == *"sha=$S2B_SHA&"* || "$*" == *"/deployments/6001/"* ]]; then d="$T_TMP/gh-b" r=501 s="$S2B_SHA" p=6001; fi
    case "$*" in
      "api -i -X POST repos/$REPO/actions/runs/$r/pending_deployments -H Accept-Encoding: identity "*) k=post ;;
      "api repos/$REPO/actions/runs/$r") k=run ;;
      "api repos/$REPO/actions/runs/$r/pending_deployments") k=pending ;;
      "api repos/$REPO/deployments?sha=$s&environment=frg26-test&per_page=100") k=deployments ;;
      "api repos/$REPO/deployments/$p/statuses?per_page=100" | "api -i repos/$REPO/deployments/$p/statuses?per_page=100") k=statuses ;;
      "api repos/$REPO/actions/runs/$r/approvals") k=approvals ;;
      *) return 0 ;;
    esac
    n=$(($(cat "$d/$k.n" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$d/$k.n"
    f="$d/$k.$n"
    [[ -f "$f" ]] || f="$d/$k"
    [[ ! -f "$f.err" ]] || cat "$f.err" >&2
    # The statuses with -i, as gh api -i prints them: 200 OK and Content-Type, then <file>.head's
    # header lines (\r\n-ended), a blank line and the body; or <file>.raw in place of all of it.
    if [[ "$k" == statuses && "$2" == -i && -f "$f.raw" ]]; then
      cat "$f.raw"
    elif [[ "$k" == statuses && "$2" == -i ]]; then
      printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n'
      cat "$f.head" 2>/dev/null
      printf '\r\n'
      cat "$f" 2>/dev/null
    else
      cat "$f" 2>/dev/null
    fi
    return "$(cat "$f.rc" 2>/dev/null || echo 0)"
  }
  s2d_fixtures
}

# S2d's run bound in every part, GitHub's 2026-11-20 answer as gh api -i prints it (with one header
# that must not be kept), S2b's control and readings ok, and an empty call log. Each case of a table
# starts from these.
s2d_fixtures() {
  S2B_OWNER_APPROVAL=ok
  S2B_READINGS=ok
  rm -rf "$T_TMP/gh"
  mkdir -p "$T_TMP/gh"
  : >"$T_TMP/calls"
  run_json 502 waiting "$S2_OWNER_SHA" Thebigtuna88 >"$T_TMP/gh/run"
  echo '[{"environment":{"id":9,"name":"frg26-test"},"wait_timer":0,"current_user_can_approve":false,"reviewers":[{"type":"User","reviewer":{"login":"Thebigtuna88","id":42}}]}]' >"$T_TMP/gh/pending"
  printf '[{"id":7001,"sha":"%s","environment":"frg26-test","task":"deploy","payload":{},"description":"a deployment"}]\n' "$S2_OWNER_SHA" >"$T_TMP/gh/deployments"
  echo '[{"id":1,"state":"waiting","created_at":"2026-11-20T01:30:40Z","description":"waiting"}]' >"$T_TMP/gh/statuses"
  echo '[]' >"$T_TMP/gh/approvals"
  s2d_post_answer 'HTTP/2.0 422 Unprocessable Entity' 1 "$S2D_422" "$S2D_GH_ERR"
}

# S2b's run (the app's, 501) as GitHub would show it: before the app's attempt (.1, its baseline,
# round 112) and after it (.2) waiting, the owner able to approve it; then (.3) approved by the owner
# for the Environment, and its deployment started. The app's attempt gets GitHub's complete refusal.
s2b_fixtures() {
  local n
  rm -rf "$T_TMP/gh-b"
  mkdir -p "$T_TMP/gh-b"
  for n in 1 2; do
    run_json 501 waiting "$S2B_SHA" "frg26-test-app[bot]" >"$T_TMP/gh-b/run.$n"
    echo '[{"environment":{"id":9,"name":"frg26-test"},"current_user_can_approve":true,"reviewers":[{"type":"User","reviewer":{"login":"Thebigtuna88"}}]}]' >"$T_TMP/gh-b/pending.$n"
    echo '[{"state":"waiting","created_at":"2026-11-20T01:30:40Z"}]' >"$T_TMP/gh-b/statuses.$n"
    echo '[]' >"$T_TMP/gh-b/approvals.$n"
  done
  run_json 501 completed "$S2B_SHA" "frg26-test-app[bot]" >"$T_TMP/gh-b/run.3"
  echo '[]' >"$T_TMP/gh-b/pending.3"
  printf '[{"id":6001,"sha":"%s","environment":"frg26-test"}]\n' "$S2B_SHA" >"$T_TMP/gh-b/deployments"
  echo '[{"state":"success","created_at":"2026-11-20T01:31:10Z"},{"state":"in_progress","created_at":"2026-11-20T01:31:00Z"},{"state":"waiting","created_at":"2026-11-20T01:30:40Z"}]' >"$T_TMP/gh-b/statuses.3"
  echo '[{"state":"approved","user":{"login":"Thebigtuna88"},"environments":[{"id":9}],"comment":"FRG-26 S2 approval attempt"}]' >"$T_TMP/gh-b/approvals.3"
  can_approve() { echo true; }
  app_git() { echo "app_git $*" >>"$T_TMP/calls"; [[ "$*" == *rev-parse* ]] && printf 'a%.0s' $(seq 1 40) && echo; return 0; }
  echo "501 waiting null frg26-test-app[bot]" >"$T_TMP/run-$S2B_SHA"
  gh_reply reply-s2b drop=X-Accepted-Github-Permissions "add=X-Accepted-Github-Permissions: deployments=write"
  echo "app_gh api -X POST repos/$REPO/actions/runs/501/pending_deployments|1|@reply-s2b" >"$T_TMP/answers"
  echo yes >"$T_TMP/log-501"
}

# The attempt's answer as gh api -i prints it: the status line, the headers, a blank line, the body
# as GitHub sent it (no newline added). @LEN@ in the headers becomes the body's length in bytes.
s2d_post_answer() { # <status line, or "" for none> <exit status> <body> <error output> [<headers, \r\n-joined>]
  local LC_ALL=C h="${5-$S2D_HEADERS}"
  h="${h//@LEN@/${#3}}"
  if [[ -n "$1" ]]; then
    printf '%s\r\n%b\r\n\r\n%s' "$1" "$h" "$3" >"$T_TMP/gh/post"
  else
    printf '%s' "$3" >"$T_TMP/gh/post"
  fi
  echo "$2" >"$T_TMP/gh/post.rc"
  printf '%s\n' "$4" >"$T_TMP/gh/post.err"
}

approvals_sent() { grep -c -- "-X POST repos/$REPO/actions/runs/502/pending_deployments" "$T_TMP/calls"; }

# Rounds 78-80: GitHub's answer is kept only as the fields the checks need (its own status line, three
# headers of their form, the body's kind and known words, whether it is shown complete), each reading
# is bound to the run, commit, Environment and deployment, and with every criterion met S2d passes
# only as "refused in this tested configuration".
test_s2d_keeps_what_the_checks_need_and_refuses_only_in_this_configuration() {
  s2d_stubs
  local out
  out="$(t_S2d)"
  assert_contains "$out" "RESULT S2d permissions PASS attempt=refused control=ok :: self-approval refused in this tested configuration (Environment frg26-test, Prevent self-review on, Thebigtuna88 its only reviewer): a complete HTTP 422 answer whose errors are GitHub's words of 2026-11-20, request C0DE:1A2B:3C4D5E:6F7A8B:9C0D1E2F; deployment 7001 pending before and after, no approval recorded; S2b's control ok and its readings show an approval taking effect. GitHub's words support this; they don't prove the refusal's cause"
  assert_not_contains "$out" "guarantee"
  assert_contains "$out" "S2D before run: 502 waiting $S2_OWNER_SHA Thebigtuna88 push main frg26-s2"
  assert_contains "$out" "S2D before pending_deployments: 1 9 frg26-test false User:Thebigtuna88"
  assert_contains "$out" "S2D before deployments: 1 7001 $S2_OWNER_SHA frg26-test"
  assert_contains "$out" "S2D before deployment 7001 statuses: waiting"
  assert_contains "$out" "S2D before approvals: 0 "
  assert_contains "$out" "S2D before: bound: run 502, commit $S2_OWNER_SHA, Environment frg26-test (9), deployment 7001"
  assert_contains "$out" "S2D approval: HTTP 422 (exit 1); request id C0DE:1A2B:3C4D5E:6F7A8B:9C0D1E2F; x-ratelimit-remaining 4979; x-ratelimit-resource core; answer: error, message Validation Failed, errors GitHub's words of 2026-11-20; completion: Content-Length ${#S2D_422} matches the body; gh's error line: repeats"
  assert_not_contains "$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')" "set-cookie" "a header that isn't one of the three"
  assert_not_contains "$out" "not-kept"
  assert_not_contains "$out" "docs.github.com" "the documentation link"
  assert_not_contains "$out" "a commit" "the run's commit message"
  assert_not_contains "$out" "a deployment" "the deployment's description"
  assert_contains "$out" "S2D after: bound: the same run, commit, Environment and deployment, still pending, no approval"
  assert_eq "$(approvals_sent)" 1 "approvals sent"
  assert_contains "$(cat "$T_TMP/calls")" "-H Accept-Encoding: identity" "the attempt asks for the body as sent"
  assert_eq "$(grep -c "api repos/$REPO/actions/runs/502/approvals" "$T_TMP/calls")" 2 "approvals read before and after"
  assert_contains "$(cat "$T_TMP/calls")" "owner_gh api -i -X POST repos/$REPO/actions/runs/502/cancel"
}

# Rounds 79-80: each criterion for a refusal on its own; without it S2d is inconclusive, and says which.
test_s2d_is_inconclusive_when_any_criterion_fails() {
  s2d_stubs
  local cases ran=0 name status headers body setup missing out
  read -r -d '' cases <<'EOF' || true
no request id|HTTP/2.0 422 Unprocessable Entity|Content-Length: @LEN@\r\nX-Ratelimit-Remaining: 4979|S2D_422|:|no x-github-request-id of its form
a request id of another form|HTTP/2.0 422 Unprocessable Entity|Content-Length: @LEN@\r\nX-Github-Request-Id: not-a-request-id-secretword\r\nX-Ratelimit-Remaining: 4979|S2D_422|:|no x-github-request-id of its form
a request id of two groups|HTTP/2.0 422 Unprocessable Entity|Content-Length: @LEN@\r\nX-Github-Request-Id: ABCD:1234\r\nX-Ratelimit-Remaining: 4979\r\nX-Ratelimit-Resource: core|S2D_422|:|no x-github-request-id of its form
no rate-limit resource|HTTP/2.0 422 Unprocessable Entity|Content-Length: @LEN@\r\nX-Github-Request-Id: C0DE:1A2B:3C4D5E:6F7A8B:9C0D1E2F\r\nX-Ratelimit-Remaining: 4979|S2D_422|:|x-ratelimit-resource '', not one of GitHub's listed resources
a rate-limit resource not on GitHub's list|HTTP/2.0 422 Unprocessable Entity|Content-Length: @LEN@\r\nX-Github-Request-Id: C0DE:1A2B:3C4D5E:6F7A8B:9C0D1E2F\r\nX-Ratelimit-Remaining: 4979\r\nX-Ratelimit-Resource: secretword_core|S2D_422|:|x-ratelimit-resource '[other]', not one of GitHub's listed resources
no quota header|HTTP/2.0 422 Unprocessable Entity|Content-Length: @LEN@\r\nX-Github-Request-Id: C0DE:1A2B:3C4D5E:6F7A8B:9C0D1E2F|S2D_422|:|x-ratelimit-remaining '', not above 0
no quota left|HTTP/2.0 422 Unprocessable Entity|Content-Length: @LEN@\r\nX-Github-Request-Id: C0DE:1A2B:3C4D5E:6F7A8B:9C0D1E2F\r\nX-Ratelimit-Remaining: 0|S2D_422|:|rate-limit signs: x-ratelimit-remaining 0;
a retry-after header|HTTP/2.0 422 Unprocessable Entity|Content-Length: @LEN@\r\nX-Github-Request-Id: C0DE:1A2B:3C4D5E:6F7A8B:9C0D1E2F\r\nX-Ratelimit-Remaining: 4979\r\nRetry-After: 60|S2D_422|:|rate-limit signs: a retry-after header;
a secondary rate limit's words|HTTP/2.0 422 Unprocessable Entity||{"message":"You have exceeded a secondary rate limit","errors":"No pending deployment requests to approve or reject"}|:|rate-limit signs: rate-limit words;
other words|HTTP/2.0 422 Unprocessable Entity||{"message":"Validation Failed","errors":"Invalid environment id"}|:|the errors are not GitHub's words of 2026-11-20 (their text is not kept)
the words as a message only|HTTP/2.0 422 Unprocessable Entity||{"message":"No pending deployment requests to approve or reject"}|:|the errors are not GitHub's words of 2026-11-20 (their text is not kept)
a 403 with the words|HTTP/2.0 403 Forbidden||S2D_422|:|HTTP 403, not 422; rate-limit signs: HTTP 403;
a 404 with the words|HTTP/2.0 404 Not Found||S2D_422|:|HTTP 404, not 422
no Content-Length|HTTP/2.0 422 Unprocessable Entity|X-Github-Request-Id: C0DE:1A2B:3C4D5E:6F7A8B:9C0D1E2F\r\nX-Ratelimit-Remaining: 4979|S2D_422|:|the answer is not shown complete (no Content-Length: completion can't be told)
a body shorter than its Content-Length|HTTP/2.0 422 Unprocessable Entity|Content-Length: 9999\r\nX-Github-Request-Id: C0DE:1A2B:3C4D5E:6F7A8B:9C0D1E2F\r\nX-Ratelimit-Remaining: 4979|S2D_422|:|the answer is not shown complete (the body is
two Content-Lengths|HTTP/2.0 422 Unprocessable Entity|Content-Length: @LEN@\r\nContent-Length: @LEN@\r\nX-Github-Request-Id: C0DE:1A2B:3C4D5E:6F7A8B:9C0D1E2F\r\nX-Ratelimit-Remaining: 4979|S2D_422|:|a Content-Length not of its form, or more than one
a compressed body|HTTP/2.0 422 Unprocessable Entity|Content-Length: @LEN@\r\nContent-Encoding: gzip\r\nX-Github-Request-Id: C0DE:1A2B:3C4D5E:6F7A8B:9C0D1E2F\r\nX-Ratelimit-Remaining: 4979|S2D_422|:|a content or transfer encoding: the length can't be checked
a chunked body|HTTP/2.0 422 Unprocessable Entity|Content-Length: @LEN@\r\nTransfer-Encoding: chunked\r\nX-Github-Request-Id: C0DE:1A2B:3C4D5E:6F7A8B:9C0D1E2F\r\nX-Ratelimit-Remaining: 4979|S2D_422|:|a content or transfer encoding: the length can't be checked
gh exit status 2|HTTP/2.0 422 Unprocessable Entity||S2D_422|echo 2 >"$T_TMP/gh/post.rc"|the answer is not shown complete (gh exit status 2); gh's exit status 2, not 1
gh's error line in other words|HTTP/2.0 422 Unprocessable Entity||S2D_422|echo "gh: connection reset by peer" >"$T_TMP/gh/post.err"|gh's error line doesn't repeat GitHub's words (other)
no error line from gh|HTTP/2.0 422 Unprocessable Entity||S2D_422|: >"$T_TMP/gh/post.err"|gh's error line doesn't repeat GitHub's words (none)
S2b's control failed|HTTP/2.0 422 Unprocessable Entity||S2D_422|S2B_OWNER_APPROVAL=failed|S2b's control was not ok
S2b's readings never made|HTTP/2.0 422 Unprocessable Entity||S2D_422|S2B_READINGS=""|S2b's readings don't show an approval taking effect (not read)
S2b's readings show no approval|HTTP/2.0 422 Unprocessable Entity||S2D_422|S2B_READINGS="after it: no approval"|S2b's readings don't show an approval taking effect (after it: no approval)
EOF
  while IFS='|' read -r name status headers body setup missing; do
    ran=$((ran + 1))
    s2d_fixtures
    [[ "$body" != S2D_422 ]] || body="$S2D_422"
    [[ -n "$headers" ]] || headers="$S2D_HEADERS"
    s2d_post_answer "$status" 1 "$body" "$S2D_GH_ERR" "$headers"
    eval "$setup"
    out="$(t_S2d)"
    assert_contains "$out" "RESULT S2d permissions FAIL attempt=inconclusive" "$name"
    assert_not_contains "$out" "S2d permissions PASS" "$name"
    assert_contains "$out" "inconclusive: " "$name"
    assert_contains "$out" "$missing" "$name"
    assert_contains "$out" "S2D after: bound: " "$name: only this criterion is missing"
    assert_not_contains "$out" "secretword" "$name: a header's text"
  done <<<"$cases"
  assert_eq "$ran" 24 "cases run"
  # A request that timed out (in this shell or one it started) ends the run before S2d records anything
  # (round 109: noted in the run's memory, never a file).
  s2d_fixtures
  out="$(STOP_LINES="owner gh api -i -X POST got no answer within its 20s"$'\n'; t_S2d 2>&1)"
  assert_not_contains "$out" "RESULT S2d" "a result after a timeout"
}

# Round 78: no approval is sent unless GitHub's state before it is bound in every part.
test_s2d_sends_no_approval_unless_githubs_state_is_bound_first() {
  s2d_stubs
  local cases ran=0 name setup why out
  read -r -d '' cases <<'EOF' || true
no pending deployment|echo '[]' >"$T_TMP/gh/pending"|pending deployments '0 null null null ', not '1 9 frg26-test false User:Thebigtuna88'
two pending deployments|echo '[{"environment":{"id":9,"name":"frg26-test"},"current_user_can_approve":false,"reviewers":[{"type":"User","reviewer":{"login":"Thebigtuna88"}}]},{"environment":{"id":10,"name":"other"}}]' >"$T_TMP/gh/pending"|pending deployments '2 9 frg26-test false User:Thebigtuna88', not '1 9 frg26-test false User:Thebigtuna88'
another Environment|echo '[{"environment":{"id":10,"name":"frg26-test"},"current_user_can_approve":false,"reviewers":[{"type":"User","reviewer":{"login":"Thebigtuna88"}}]}]' >"$T_TMP/gh/pending"|pending deployments '1 10 frg26-test false User:Thebigtuna88', not '1 9 frg26-test false User:Thebigtuna88'
an Environment of another name|echo '[{"environment":{"id":9,"name":"secretword-name"},"current_user_can_approve":false,"reviewers":[{"type":"User","reviewer":{"login":"Thebigtuna88"}}]}]' >"$T_TMP/gh/pending"|pending deployments '1 9 [other] false User:Thebigtuna88', not '1 9 frg26-test false User:Thebigtuna88'
the owner may approve|echo '[{"environment":{"id":9,"name":"frg26-test"},"current_user_can_approve":true,"reviewers":[{"type":"User","reviewer":{"login":"Thebigtuna88"}}]}]' >"$T_TMP/gh/pending"|pending deployments '1 9 frg26-test true User:Thebigtuna88', not '1 9 frg26-test false User:Thebigtuna88'
another reviewer|echo '[{"environment":{"id":9,"name":"frg26-test"},"current_user_can_approve":false,"reviewers":[{"type":"User","reviewer":{"login":"Thebigtuna88"}},{"type":"Team","reviewer":{"login":"admins"}}]}]' >"$T_TMP/gh/pending"|pending deployments '1 9 frg26-test false User:Thebigtuna88,Team:[other]', not '1 9 frg26-test false User:Thebigtuna88'
a run on another commit|run_json 502 waiting "$(printf 'c%.0s' $(seq 1 40))" Thebigtuna88 >"$T_TMP/gh/run"|run '502 waiting [other] Thebigtuna88 push main frg26-s2', not '502 waiting $S2_OWNER_SHA Thebigtuna88 push main frg26-s2'
a run no longer waiting|run_json 502 completed "$S2_OWNER_SHA" Thebigtuna88 >"$T_TMP/gh/run"|run '502 completed $S2_OWNER_SHA
a run by the app|run_json 502 waiting "$S2_OWNER_SHA" "frg26-test-app[bot]" >"$T_TMP/gh/run"|run '502 waiting $S2_OWNER_SHA [other] push main
a run on another branch|run_json 502 waiting "$S2_OWNER_SHA" Thebigtuna88 >"$T_TMP/gh/run"; sed -i '' 's/"main"/"secretword-branch"/' "$T_TMP/gh/run"|run '502 waiting $S2_OWNER_SHA Thebigtuna88 push [other] frg26-s2'
no deployment|echo '[]' >"$T_TMP/gh/deployments"|deployments '0 null null null', not '1  $S2_OWNER_SHA frg26-test'
two deployments|printf '[{"id":7001,"sha":"%s","environment":"frg26-test"},{"id":7002,"sha":"%s","environment":"frg26-test"}]\n' "$S2_OWNER_SHA" "$S2_OWNER_SHA" >"$T_TMP/gh/deployments"|deployments '2 7001 $S2_OWNER_SHA frg26-test', not '1 7001 $S2_OWNER_SHA frg26-test'
a deployment that started|echo '[{"id":2,"state":"in_progress"},{"id":1,"state":"waiting"}]' >"$T_TMP/gh/statuses"|deployment 7001 states in_progress,waiting: it started or ended
an approval already recorded|echo '[{"state":"approved","user":{"login":"Thebigtuna88"}}]' >"$T_TMP/gh/approvals"|approvals '1 approved:Thebigtuna88:', not '0 '
a failed run read|echo 1 >"$T_TMP/gh/run.rc"|the run read failed
a failed pending read|echo 1 >"$T_TMP/gh/pending.rc"|the pending_deployments read failed
a pending read that isn't JSON|echo 'gh: not json' >"$T_TMP/gh/pending"|the pending_deployments read failed
a failed deployments read|echo 1 >"$T_TMP/gh/deployments.rc"|the deployments read failed
a failed statuses read|echo 1 >"$T_TMP/gh/statuses.rc"|the deployment 7001 statuses read failed
a failed approvals read|echo 1 >"$T_TMP/gh/approvals.rc"|the approvals read failed
EOF
  while IFS='|' read -r name setup why; do
    ran=$((ran + 1))
    s2d_fixtures
    eval "$setup"
    why="$(eval "printf '%s' \"$why\"")"
    out="$(t_S2d)"
    assert_contains "$out" "RESULT S2d permissions FAIL attempt=inconclusive control=ok" "$name"
    assert_not_contains "$out" "S2d permissions PASS" "$name"
    assert_contains "$out" "S2D before: NOT bound: " "$name"
    assert_contains "$out" "$why" "$name"
    assert_contains "$out" "inconclusive: no approval sent, GitHub's state before the attempt is not bound" "$name"
    assert_not_contains "$out" "secretword" "$name: a field's text"
    assert_eq "$(approvals_sent)" 0 "approvals sent: $name"
    assert_contains "$(cat "$T_TMP/calls")" "owner_gh api -i -X POST repos/$REPO/actions/runs/502/cancel" "$name"
  done <<<"$cases"
  assert_eq "$ran" 20 "cases run"
}

# Rounds 78-80: an answer that isn't the one expected never passes; one that GitHub accepted is allowed.
test_s2d_an_unexpected_answer_never_passes() {
  s2d_stubs
  local cases ran=0 name status rc body err want http answer out
  read -r -d '' cases <<'EOF' || true
accepted|HTTP/2.0 200 OK|0|[{"id":7001,"environment":"frg26-test"}]||allowed|200|a list of 1, ids 7001
accepted, another 2xx|HTTP/2.0 201 Created|0|[]||allowed|201|a list of 0, ids none
no status line (gh without -i)||1|{"message":"Validation Failed"}|gh: Validation Failed (HTTP 422)|inconclusive|unknown|error, message Validation Failed, errors none
a rate limit|HTTP/2.0 429 Too Many Requests|1|{"message":"API rate limit exceeded for user ID 1."}|gh: API rate limit exceeded (HTTP 429)|inconclusive|429|error, message API rate limit exceeded, errors none
a server error|HTTP/2.0 500 Internal Server Error|1|{"message":"Server Error"}|gh: Server Error (HTTP 500)|inconclusive|500|error, message Server Error, errors none
a refusal in the words the old tests guessed|HTTP/2.0 422 Unprocessable Entity|1|{"message":"Can't approve your own deployment"}|gh: Can't approve your own deployment (HTTP 422)|inconclusive|422|error, message [other], errors none
a refusal with exit 0|HTTP/2.0 422 Unprocessable Entity|0|{"message":"Validation Failed"}||allowed|422|error, message Validation Failed, errors none
not JSON|HTTP/2.0 502 Bad Gateway|1|<html>bad gateway</html>|gh: HTTP 502|inconclusive|502|not JSON (not kept)
EOF
  while IFS='|' read -r name status rc body err want http answer; do
    ran=$((ran + 1))
    s2d_fixtures
    s2d_post_answer "$status" "$rc" "$body" "$err"
    out="$(t_S2d)"
    assert_contains "$out" "RESULT S2d permissions FAIL attempt=$want control=ok" "$name"
    assert_not_contains "$out" "S2d permissions PASS" "$name"
    assert_contains "$out" "S2D approval: HTTP $http (exit $rc);" "$name"
    assert_contains "$out" "answer: $answer;" "$name"
  done <<<"$cases"
  assert_eq "$ran" 8 "cases run"
  # An answer cut before the end of its headers: GitHub's status can't be told.
  s2d_fixtures
  printf 'HTTP/2.0 422 Unprocessable Entity\r\nX-Github-Request-Id: C0DE:1A2B:3C4D5E:6F7A8B:9C0D1E2F\r\n' >"$T_TMP/gh/post"
  out="$(t_S2d)"
  assert_contains "$out" "S2D approval: HTTP unknown (exit 1);" "an answer cut before its body"
  assert_contains "$out" "completion: cut before the end of its headers" "an answer cut before its body"
  assert_contains "$out" "RESULT S2d permissions FAIL attempt=inconclusive control=ok" "an answer cut before its body"
}

# Round 78: what is read back after the attempt must still be bound, the same deployment included.
test_s2d_an_incomplete_read_back_never_passes() {
  s2d_stubs
  local cases ran=0 name setup why want out
  read -r -d '' cases <<'EOF' || true
no longer pending|echo '[]' >"$T_TMP/gh/pending.2"|pending deployments '0 null null null ', not '1 9 frg26-test false User:Thebigtuna88'|inconclusive
the run went on|run_json 502 completed "$S2_OWNER_SHA" Thebigtuna88 >"$T_TMP/gh/run.2"|run '502 completed $S2_OWNER_SHA|inconclusive
another deployment|printf '[{"id":7002,"sha":"%s","environment":"frg26-test"}]\n' "$S2_OWNER_SHA" >"$T_TMP/gh/deployments.2"|deployments '1 7002 $S2_OWNER_SHA frg26-test', not '1 7001 $S2_OWNER_SHA frg26-test'|inconclusive
the deployment started|echo '[{"id":2,"state":"in_progress"},{"id":1,"state":"waiting"}]' >"$T_TMP/gh/statuses.2"|deployment 7001 states in_progress,waiting: it started or ended|allowed
an approval recorded|echo '[{"state":"approved","user":{"login":"Thebigtuna88"}}]' >"$T_TMP/gh/approvals.2"|approvals '1 approved:Thebigtuna88:', not '0 '|allowed
a failed approvals read|: >"$T_TMP/gh/approvals.2"; echo 1 >"$T_TMP/gh/approvals.2.rc"|the approvals read failed|inconclusive
a failed pending read|: >"$T_TMP/gh/pending.2"; echo 1 >"$T_TMP/gh/pending.2.rc"|the pending_deployments read failed|inconclusive
EOF
  while IFS='|' read -r name setup why want; do
    ran=$((ran + 1))
    s2d_fixtures
    eval "$setup"
    why="$(eval "printf '%s' \"$why\"")"
    out="$(t_S2d)"
    assert_contains "$out" "RESULT S2d permissions FAIL attempt=$want control=ok" "$name"
    assert_not_contains "$out" "S2d permissions PASS" "$name"
    assert_contains "$out" "S2D before: bound: " "$name"
    assert_contains "$out" "S2D after: NOT bound: " "$name"
    assert_contains "$out" "$why" "$name"
    assert_eq "$(approvals_sent)" 1 "approvals sent: $name"
  done <<<"$cases"
  assert_eq "$ran" 7 "cases run"
}

# Rounds 78-80: S2d's record never holds a credential: not this run's tokens, not text shaped like a
# GitHub token or a JWT, and not any other secret in a field it doesn't need (a deployment's payload or
# description, a status's description, an approval's comment, a commit message, an error's message,
# errors or link, gh's error text, an accepted answer's body).
test_s2d_keeps_credentials_out_of_its_record() {
  s2d_stubs
  local other out secret
  secret="$(printf 'sk_%s_%s' live "$(printf 'Q%.0s' $(seq 1 24))")"
  TOKEN="$(new_token)"
  other="$(fake_token)"
  # In the readings, an error answer and gh's error text.
  run_json 502 waiting "$S2_OWNER_SHA" Thebigtuna88 | sed "s/a commit/$secret $other/" >"$T_TMP/gh/run"
  printf '[{"id":7001,"sha":"%s","environment":"frg26-test","payload":{"api_key":"%s"},"description":"%s"}]\n' "$S2_OWNER_SHA" "$secret" "$TOKEN" >"$T_TMP/gh/deployments"
  printf '[{"id":1,"state":"waiting","created_at":"2026-11-20T01:30:40Z","description":"%s","log_url":"https://example.com/%s"}]\n' "$secret" "$secret" >"$T_TMP/gh/statuses"
  printf '[{"environment":{"id":9,"name":"frg26-test"},"current_user_can_approve":false,"reviewers":[{"type":"User","reviewer":{"login":"Thebigtuna88"}}],"note":"%s"}]\n' "$secret" >"$T_TMP/gh/pending"
  s2d_post_answer 'HTTP/2.0 422 Unprocessable Entity' 1 "{\"message\":\"$secret\",\"errors\":\"$secret $TOKEN and $other\",\"documentation_url\":\"https://docs.github.com/$secret\"}" "gh: $secret $other (HTTP 422)"
  out="$(t_S2d)"
  assert_contains "$out" "S2D approval: HTTP 422 (exit 1);"
  assert_contains "$out" "answer: error, message [other], errors other text (not kept)"
  assert_contains "$out" "gh's error line: other"
  assert_not_contains "$out" "$secret" "a non-GitHub credential (readings, error answer, gh's text)"
  assert_not_contains "$out" "$TOKEN" "this run's token"
  assert_not_contains "$out" "$other" "a token-shaped text"
  assert_not_contains "$out" "eyJ" "a part of a JWT"
  # In an accepted answer's body, and an approval's comment read back after it.
  s2d_fixtures
  s2d_post_answer 'HTTP/2.0 200 OK' 0 "[{\"id\":7001,\"environment\":\"frg26-test\",\"payload\":{\"api_key\":\"$secret\"},\"description\":\"$secret\"}]" ""
  printf '[{"state":"approved","user":{"login":"Thebigtuna88"},"environments":[{"id":9}],"comment":"%s"}]\n' "$secret" >"$T_TMP/gh/approvals.2"
  out="$(t_S2d)"
  assert_contains "$out" "RESULT S2d permissions FAIL attempt=allowed control=ok"
  assert_contains "$out" "answer: a list of 1, ids 7001;"
  assert_not_contains "$out" "$secret" "a non-GitHub credential (an accepted answer, an approval's comment)"
  end_stand_in_run
}

# Round 79, criterion 6: S2b's readings around the owner's approval must show it taking effect, or S2d
# can't pass; S2b's own verdict doesn't depend on them.
test_s2b_readings_must_show_the_owners_approval_or_s2d_cannot_pass() {
  s2d_stubs
  local cases ran=0 name setup why out
  read -r -d '' cases <<'EOF' || true
the approval shows|:|ok|
no approval recorded|echo '[]' >"$T_TMP/gh-b/approvals.3"|after it: approvals '0 ': no approval by Thebigtuna88 for Environment 9|
an approval for another Environment|echo '[{"state":"approved","user":{"login":"Thebigtuna88"},"environments":[{"id":10}]}]' >"$T_TMP/gh-b/approvals.3"|no approval by Thebigtuna88 for Environment 9|
the deployment never started|echo '[{"state":"waiting"}]' >"$T_TMP/gh-b/statuses.3"|deployment 6001 states 'waiting': no sign it started|
still pending after it|cp "$T_TMP/gh-b/pending.1" "$T_TMP/gh-b/pending.3"|pending deployments '1 9 frg26-test true User:Thebigtuna88', not '0 null null null '|
another deployment after it|printf '[{"id":6002,"sha":"%s","environment":"frg26-test"}]\n' "$S2B_SHA" >"$T_TMP/gh-b/deployments.3"|deployments '1 6002 $S2B_SHA frg26-test', not '1 6001 $S2B_SHA frg26-test'|
GitHub showed no deployment|echo '[]' >"$T_TMP/gh-b/deployments"|the app's run is not bound before its attempt|FAIL attempt=setup-failed
the owner could not approve it|echo '[{"environment":{"id":9,"name":"frg26-test"},"current_user_can_approve":false,"reviewers":[{"type":"User","reviewer":{"login":"Thebigtuna88"}}]}]' >"$T_TMP/gh-b/pending.2"|its run read back: not as before the attempt (pending deployments '1 9 frg26-test false User:Thebigtuna88'|FAIL attempt=inconclusive control=not run
a failed read after it|: >"$T_TMP/gh-b/approvals.3"; echo 1 >"$T_TMP/gh-b/approvals.3.rc"|after it: the approvals read failed|
EOF
  # Round 112: S2b reads its run before the app's attempt too (its baseline), and the reading before the
  # owner's approval is that attempt's read-back: S2b's own verdict depends on those two, never on the
  # readings after the owner's approval.
  local verdict
  while IFS='|' read -r name setup why verdict; do
    ran=$((ran + 1))
    s2d_fixtures
    s2b_fixtures
    eval "$setup"
    why="$(eval "printf '%s' \"$why\"")"
    FAILS=0
    t_S2b >"$T_TMP/s2b.out" 2>&1
    out="$(cat "$T_TMP/s2b.out")"
    assert_contains "$out" "RESULT S2b permissions ${verdict:-PASS attempt=refused control=ok}" "$name: S2b's own verdict"
    [[ -n "$verdict" ]] || assert_contains "$out" "S2B before run: 501 waiting $S2B_SHA frg26-test-app[bot] push main frg26-s2" "$name"
    assert_contains "$out" "$why" "$name"
    assert_not_contains "$out" "FRG-26 S2 approval attempt" "$name: an approval's comment"
    out="$(t_S2d)"
    if [[ "$why" == ok ]]; then
      assert_eq "$S2B_READINGS" ok "$name"
      assert_contains "$out" "RESULT S2d permissions PASS attempt=refused control=ok" "$name"
    else
      [[ "$S2B_READINGS" != ok ]] || _t_fail "$name: S2B_READINGS is ok"
      assert_contains "$out" "RESULT S2d permissions FAIL attempt=inconclusive control=ok" "$name"
      assert_contains "$out" "S2b's readings don't show an approval taking effect" "$name"
    fi
  done <<<"$cases"
  assert_eq "$ran" 9 "cases run"
  # Round 110: its S2d writes stay outcome unknown (stand-in answers); a stand-in run's end is no clean-up.
  end_stand_in_run
}

# One fixture field set: <file> under $T_TMP/gh (or gh-b), a jq filter in which $c is <value>.
s2_put() { # <file> <jq filter> <value>
  jq -c --arg c "$3" "$2" "$1" >"$1.new"
  mv "$1.new" "$1"
}

# Round 81 (SEC-1 and C1 of review-lens round 78): every field S2 keeps is a value from GitHub's
# documented list or the one value wanted, else "[other]", and a number only when GitHub sent a
# number. A credential-shaped value in any of them is never recorded, and never binds a reading.
test_s2_keeps_only_listed_or_matching_values() {
  s2d_stubs
  local low mixed hex cases ran=0 name file filter kind v out
  # Credentials of other services, built at run time (no key-shaped text sits here): one of
  # lowercase words, one of letters and digits, one of hex digits.
  low="$(printf 'sk_%s_%s' live "$(printf 'q%.0s' $(seq 1 24))")"
  mixed="$(printf 'AKIA%s' "$(printf 'Q%.0s' $(seq 1 16))")"
  hex="$(printf 'deadbeef%.0s' 1 2 3 4 5)"
  read -r -d '' cases <<'EOF' || true
a run status not on GitHub's list|run|.status = $c|low
a run on another commit|run|.head_sha = $c|hex
a run by another actor|run|.actor.login = $c|mixed
a run actor that isn't an object|run|.actor = $c|low
a run of another event|run|.event = $c|low
a run on another branch|run|.head_branch = $c|low
a run of another workflow|run|.name = $c|low
a run id as text|run|.id = "502"|none
an Environment of another name|pending|.[0].environment.name = $c|low
an Environment id as text|pending|.[0].environment.id = "9"|none
can-approve as text|pending|.[0].current_user_can_approve = "false"|none
a reviewer type not on GitHub's list|pending|.[0].reviewers[0].type = $c|mixed
another reviewer|pending|.[0].reviewers[0].reviewer.login = $c|mixed
pending deployments that aren't a list|pending|{note: $c}|low
a deployment on another commit|deployments|.[0].sha = $c|hex
a deployment for another Environment|deployments|.[0].environment = $c|low
a deployment id as text|deployments|.[0].id = "7001"|none
a status state not on GitHub's list|statuses|.[0].state = $c|low
a status time not of its form|statuses|.[0].created_at = $c|low
an approval in words not on GitHub's list|approvals|[{state: $c, user: {login: $c}, environments: [{id: $c}]}]|low
an approval by another login|approvals|[{state: "approved", user: {login: $c}, environments: [{id: 9}]}]|mixed
EOF
  while IFS='|' read -r name file filter kind; do
    ran=$((ran + 1))
    s2d_fixtures
    v=""
    case "$kind" in low) v="$low" ;; mixed) v="$mixed" ;; hex) v="$hex" ;; esac
    s2_put "$T_TMP/gh/$file" "$filter" "$v"
    out="$(t_S2d)"
    assert_contains "$out" "RESULT S2d permissions FAIL attempt=inconclusive control=ok" "$name"
    assert_not_contains "$out" "S2d permissions PASS" "$name"
    assert_contains "$out" "S2D before: NOT bound: " "$name"
    assert_eq "$(approvals_sent)" 0 "approvals sent: $name"
    [[ -z "$v" ]] || assert_not_contains "$out" "$v" "$name: the credential"
  done <<<"$cases"
  assert_eq "$ran" 21 "cases run"
  # In the attempt's headers: a request id of hex digits only, a rate-limit resource of lowercase words.
  s2d_fixtures
  s2d_post_answer 'HTTP/2.0 422 Unprocessable Entity' 1 "$S2D_422" "$S2D_GH_ERR" "Content-Length: @LEN@\r\nX-Github-Request-Id: $hex\r\nX-Ratelimit-Remaining: 4979\r\nX-Ratelimit-Resource: $low"
  out="$(t_S2d)"
  assert_contains "$out" "S2D approval: HTTP 422 (exit 1); request id [other]; x-ratelimit-remaining 4979; x-ratelimit-resource [other];"
  assert_contains "$out" "no x-github-request-id of its form"
  assert_contains "$out" "x-ratelimit-resource '[other]', not one of GitHub's listed resources"
  assert_contains "$out" "RESULT S2d permissions FAIL attempt=inconclusive control=ok"
  assert_not_contains "$out" "$hex" "a request id of hex digits"
  assert_not_contains "$out" "$low" "a rate-limit resource"
  # In an accepted answer's ids.
  s2d_fixtures
  s2d_post_answer 'HTTP/2.0 200 OK' 0 "[{\"id\":\"$low\"},{\"id\":7001}]" ""
  out="$(t_S2d)"
  assert_contains "$out" "answer: a list of 2, ids [other],7001;"
  assert_contains "$out" "RESULT S2d permissions FAIL attempt=allowed control=ok"
  assert_not_contains "$out" "$low" "an accepted answer's id"
  # In S2b: GitHub's word on whether the owner can approve.
  s2d_fixtures
  s2b_fixtures
  can_approve() { printf '%s\n' "$low"; }
  FAILS=0
  t_S2b >"$T_TMP/s2b.out" 2>&1
  out="$(cat "$T_TMP/s2b.out")"
  assert_contains "$out" "GitHub says the owner can approve it: [other]"
  assert_contains "$out" "RESULT S2b permissions FAIL attempt=refused control=failed"
  assert_not_contains "$out" "$low" "S2b: can-approve's text"
  # And the run's actor, read back after the app's attempt (round 112: its read-back, so S2b is then
  # inconclusive).
  s2d_fixtures
  s2b_fixtures
  # shellcheck disable=SC2016 # jq's own $c
  s2_put "$T_TMP/gh-b/run.2" '.actor.login = $c' "$mixed"
  FAILS=0
  t_S2b >"$T_TMP/s2b.out" 2>&1
  out="$(cat "$T_TMP/s2b.out")"
  assert_contains "$out" "RESULT S2b permissions FAIL attempt=inconclusive control=not run"
  assert_contains "$out" "S2B before run: 501 waiting $S2B_SHA [other] push main frg26-s2"
  [[ "$S2B_READINGS" != ok ]] || _t_fail "S2B_READINGS is ok with another actor"
  assert_not_contains "$out" "$mixed" "S2b: the run's actor"
  # Round 110: its S2d writes stay outcome unknown (stand-in answers); a stand-in run's end is no clean-up.
  end_stand_in_run
}

# Round 81 (C1 of review-lens round 78): the deployment must be shown waiting. Its statuses are on
# GitHub's list, none of them started or ended, and the latest, told by created_at (the list's order
# isn't documented), is waiting, queued or pending. Queued or pending stand only with the rest of
# the reading: the run waiting, the owner's review pending for this Environment, no approval.
test_s2d_needs_githubs_positive_evidence_of_waiting() {
  s2d_stubs
  local cases ran=0 name statuses setup want why out
  read -r -d '' cases <<'EOF' || true
waiting|[{"state":"waiting","created_at":"2026-11-20T01:30:40Z"}]|:|bound|statuses: waiting; latest waiting
queued|[{"state":"queued","created_at":"2026-11-20T01:30:40Z"}]|:|bound|statuses: queued; latest queued
pending|[{"state":"pending","created_at":"2026-11-20T01:30:40Z"}]|:|bound|statuses: pending; latest pending
waiting, listed before the queued one it followed|[{"state":"waiting","created_at":"2026-11-20T01:30:41Z"},{"state":"queued","created_at":"2026-11-20T01:30:40Z"}]|:|bound|statuses: waiting,queued; latest waiting
waiting, listed after the queued one it followed|[{"state":"queued","created_at":"2026-11-20T01:30:40Z"},{"state":"waiting","created_at":"2026-11-20T01:30:41Z"}]|:|bound|statuses: queued,waiting; latest waiting
the same state at the same second|[{"state":"waiting","created_at":"2026-11-20T01:30:40Z"},{"state":"waiting","created_at":"2026-11-20T01:30:40Z"}]|:|bound|latest waiting
no status|[]|:|not|deployment 7001 has no status: GitHub doesn't show it waiting
statuses that aren't a list|{"state":"waiting"}|:|not|deployment 7001's statuses are not a list
a state not on GitHub's list|[{"state":"deploying","created_at":"2026-11-20T01:30:40Z"}]|:|not|deployment 7001 states '[other]': a state not on GitHub's list
no state|[{"created_at":"2026-11-20T01:30:40Z"}]|:|not|deployment 7001 states 'null': a state not on GitHub's list
a state as a number|[{"state":1,"created_at":"2026-11-20T01:30:40Z"}]|:|not|deployment 7001 states '[other]': a state not on GitHub's list
a started one among them|[{"state":"waiting","created_at":"2026-11-20T01:30:41Z"},{"state":"in_progress","created_at":"2026-11-20T01:30:40Z"}]|:|not|deployment 7001 states waiting,in_progress: it started or ended
no time|[{"state":"waiting"}]|:|not|deployment 7001's latest status can't be told by its time
a time not of its form|[{"state":"waiting","created_at":"2026-11-20 01:30:40"}]|:|not|deployment 7001's latest status can't be told by its time
a time as a number|[{"state":"waiting","created_at":1763602240}]|:|not|deployment 7001's latest status can't be told by its time
two states at the same second|[{"state":"queued","created_at":"2026-11-20T01:30:40Z"},{"state":"waiting","created_at":"2026-11-20T01:30:40Z"}]|:|not|deployment 7001's latest status can't be told by its time
queued, nothing pending review|[{"state":"queued","created_at":"2026-11-20T01:30:40Z"}]|echo '[]' >"$T_TMP/gh/pending"|not|pending deployments '0 null null null ', not
queued, the run not waiting|[{"state":"queued","created_at":"2026-11-20T01:30:40Z"}]|run_json 502 queued "$S2_OWNER_SHA" Thebigtuna88 >"$T_TMP/gh/run"|not|run '502 queued $S2_OWNER_SHA
pending, the review not the owner's|[{"state":"pending","created_at":"2026-11-20T01:30:40Z"}]|s2_put "$T_TMP/gh/pending" '.[0].reviewers[0].reviewer.login = $c' someone-else|not|User:[other]', not
queued, an approval already recorded|[{"state":"queued","created_at":"2026-11-20T01:30:40Z"}]|echo '[{"state":"approved","user":{"login":"Thebigtuna88"},"environments":[{"id":9}]}]' >"$T_TMP/gh/approvals"|not|approvals '1 approved:Thebigtuna88:9', not '0 '
EOF
  while IFS='|' read -r name statuses setup want why; do
    ran=$((ran + 1))
    s2d_fixtures
    printf '%s\n' "$statuses" >"$T_TMP/gh/statuses"
    eval "$setup"
    why="$(eval "printf '%s' \"$why\"")"
    out="$(t_S2d)"
    if [[ "$want" == bound ]]; then
      assert_contains "$out" "S2D before: bound: " "$name"
      assert_contains "$out" "$why" "$name"
      assert_contains "$out" "RESULT S2d permissions PASS attempt=refused control=ok" "$name"
    else
      assert_contains "$out" "S2D before: NOT bound: " "$name"
      assert_contains "$out" "$why" "$name"
      assert_contains "$out" "RESULT S2d permissions FAIL attempt=inconclusive control=ok" "$name"
      assert_not_contains "$out" "S2d permissions PASS" "$name"
      assert_eq "$(approvals_sent)" 0 "approvals sent: $name"
    fi
  done <<<"$cases"
  assert_eq "$ran" 20 "cases run"
  # Read back after the attempt, the same rule: a status of no known state, or no status, is not bound.
  s2d_fixtures
  echo '[{"state":"deploying","created_at":"2026-11-20T01:30:41Z"},{"state":"waiting","created_at":"2026-11-20T01:30:40Z"}]' >"$T_TMP/gh/statuses.2"
  out="$(t_S2d)"
  assert_contains "$out" "S2D after: NOT bound: deployment 7001 states '[other],waiting': a state not on GitHub's list"
  assert_contains "$out" "RESULT S2d permissions FAIL attempt=inconclusive control=ok"
  s2d_fixtures
  echo '[]' >"$T_TMP/gh/statuses.2"
  out="$(t_S2d)"
  assert_contains "$out" "S2D after: NOT bound: deployment 7001 has no status: GitHub doesn't show it waiting"
  assert_contains "$out" "RESULT S2d permissions FAIL attempt=inconclusive control=ok"
  # After the owner's approval in S2b, a state not on GitHub's list keeps S2b's readings from showing it.
  s2d_fixtures
  s2b_fixtures
  echo '[{"state":"success","created_at":"2026-11-20T01:31:10Z"},{"state":"deploying","created_at":"2026-11-20T01:31:00Z"}]' >"$T_TMP/gh-b/statuses.3"
  FAILS=0
  t_S2b >"$T_TMP/s2b.out" 2>&1
  out="$(cat "$T_TMP/s2b.out")"
  assert_contains "$out" "deployment 6001 states 'success,[other]': a state not on GitHub's list"
  [[ "$S2B_READINGS" != ok ]] || _t_fail "S2B_READINGS is ok with a state not on GitHub's list"
  # Round 110: its S2d writes stay outcome unknown (stand-in answers); a stand-in run's end is no clean-up.
  end_stand_in_run
}

# Round 82 (C1 of review-lens round 79): the statuses are read as one page of up to 100, so a started
# status, or the latest, may be on another. 100 or more on the page, or a Link header (GitHub sends
# one only when the list has more pages), leaves the reading not bound, before and after the attempt
# and in S2b's readings. The Link header's value is never said.
test_s2_statuses_past_one_page_are_not_bound() {
  s2d_stubs
  local cases ran=0 name count head want why out secret
  secret="sk_live_$(printf 'q%.0s' $(seq 1 24))"
  read -r -d '' cases <<'EOF' || true
99 statuses|99||bound|S2D before deployment 7001 statuses: waiting,
one status|1||bound|statuses: waiting; latest waiting
100 statuses|100||not|deployment 7001's statuses may go on past this page (100 of them): not all are shown
101 statuses|101||not|deployment 7001's statuses may go on past this page (101 of them): not all are shown
a Link header to the next page|1|Link: <https://api.github.com/repositories/1/deployments/7001/statuses?per_page=100&page=2>; rel="next"|not|deployment 7001's statuses may go on past this page (a Link header): not all are shown
a Link header in lower case|1|link: <https://api.github.com/x>; rel="last"|not|(a Link header)
a Link header holding a credential|1|Link: <https://api.github.com/x?k=@SECRET@>; rel="next"|not|(a Link header)
100 statuses and a Link header|100|Link: <https://api.github.com/x>; rel="next"|not|(100 of them; a Link header)
a status other than 200|1|@STATUS@|not|the deployment 7001 statuses read failed
headers cut before their end|1|@CUT@|not|the deployment 7001 statuses read failed
EOF
  while IFS='|' read -r name count head want why; do
    ran=$((ran + 1))
    s2d_fixtures
    jq -nc --argjson n "$count" '[range($n) | {state: "waiting", created_at: "2026-11-20T01:30:40Z"}]' >"$T_TMP/gh/statuses"
    case "$head" in
      @STATUS@) printf 'HTTP/2.0 304 Not Modified\r\n\r\n%s' "$(cat "$T_TMP/gh/statuses")" >"$T_TMP/gh/statuses.raw" ;;
      @CUT@) printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\nX-Github-Request-Id: C0DE' >"$T_TMP/gh/statuses.raw" ;;
      ?*) printf '%s\r\n' "${head//@SECRET@/$secret}" >"$T_TMP/gh/statuses.head" ;;
    esac
    out="$(t_S2d)"
    if [[ "$want" == bound ]]; then
      assert_contains "$out" "S2D before: bound: " "$name"
      assert_contains "$out" "$why" "$name"
      assert_contains "$out" "RESULT S2d permissions PASS attempt=refused control=ok" "$name"
    else
      assert_contains "$out" "S2D before: NOT bound: " "$name"
      assert_contains "$out" "$why" "$name"
      assert_contains "$out" "RESULT S2d permissions FAIL attempt=inconclusive control=ok" "$name"
      assert_not_contains "$out" "S2d permissions PASS" "$name"
      assert_eq "$(approvals_sent)" 0 "approvals sent: $name"
    fi
    assert_not_contains "$out" "$secret" "the Link header's value: $name"
    assert_not_contains "$out" "api.github.com" "the Link header's value: $name"
  done <<<"$cases"
  assert_eq "$ran" 10 "cases run"
  # Read back after the attempt, the same rule.
  s2d_fixtures
  jq -nc '[range(100) | {state: "waiting", created_at: "2026-11-20T01:30:40Z"}]' >"$T_TMP/gh/statuses.2"
  out="$(t_S2d)"
  assert_contains "$out" "S2D after: NOT bound: deployment 7001's statuses may go on past this page (100 of them)"
  assert_contains "$out" "RESULT S2d permissions FAIL attempt=inconclusive control=ok"
  s2d_fixtures
  cp "$T_TMP/gh/statuses" "$T_TMP/gh/statuses.2"
  printf 'Link: <https://api.github.com/x>; rel="next"\r\n' >"$T_TMP/gh/statuses.2.head"
  out="$(t_S2d)"
  assert_contains "$out" "S2D after: NOT bound: deployment 7001's statuses may go on past this page (a Link header)"
  assert_contains "$out" "RESULT S2d permissions FAIL attempt=inconclusive control=ok"
  # After the owner's approval in S2b, more pages keep S2b's readings from showing it took effect.
  s2d_fixtures
  s2b_fixtures
  printf 'Link: <https://api.github.com/x>; rel="next"\r\n' >"$T_TMP/gh-b/statuses.3.head"
  FAILS=0
  t_S2b >"$T_TMP/s2b.out" 2>&1
  out="$(cat "$T_TMP/s2b.out")"
  assert_contains "$out" "deployment 6001's statuses may go on past this page (a Link header)"
  [[ "$S2B_READINGS" != ok ]] || _t_fail "S2B_READINGS is ok with more pages of statuses"
  # Round 110: its S2d writes stay outcome unknown (stand-in answers); a stand-in run's end is no clean-up.
  end_stand_in_run
}

test_s2a_a_feature_branch_never_gets_the_value() {
  s2_stubs
  app_git() { [[ "$*" == *rev-parse* ]] && printf 'c%.0s' $(seq 1 40) && echo; return 0; }
  local sha
  sha="$(printf 'c%.0s' $(seq 1 40))"
  echo "503 completed failure frg26-test-app[bot]" >"$T_TMP/run-$sha"
  deploy_job() { cat "$T_TMP/job-$1" 2>/dev/null || echo error; }
  policy_rejected() { [[ -f "$T_TMP/policy-$1" ]]; }
  echo "9001 0 failure" >"$T_TMP/job-503"
  touch "$T_TMP/policy-9001"
  local out
  out="$(t_S2a)"
  assert_contains "$out" "RESULT S2a permissions PASS attempt=refused"
  # Round 13, C3/SEC-1: a run that failed for another reason proves nothing.
  echo "9001 3 failure" >"$T_TMP/job-503"
  out="$(t_S2a)"
  assert_contains "$out" "RESULT S2a permissions FAIL attempt=inconclusive" "a job that ran and failed"
  echo "9001 0 failure" >"$T_TMP/job-503"
  rm -f "$T_TMP/policy-9001"
  out="$(t_S2a)"
  assert_contains "$out" "RESULT S2a permissions FAIL attempt=inconclusive" "no branch-policy rejection from GitHub"
  touch "$T_TMP/policy-9001"
  echo "503 waiting null frg26-test-app[bot]" >"$T_TMP/run-$sha"
  out="$(t_S2a)"
  assert_contains "$out" "RESULT S2a permissions FAIL attempt=allowed" "a feature branch waiting to deploy"
  echo "503 completed success frg26-test-app[bot]" >"$T_TMP/run-$sha"
  echo "9001 1 success" >"$T_TMP/job-503"
  echo yes >"$T_TMP/log-503"
  out="$(t_S2a)"
  assert_contains "$out" "RESULT S2a permissions FAIL attempt=allowed" "a feature branch that got the value"
}

test_an_unreadable_run_log_is_not_an_absent_value() {
  # Round 13, C3/SEC-1: run_log_value tells "no such line" from "the log couldn't be read".
  load
  owner_gh() { echo "  deploy  Report  FRG26-S2 value length 24"; }
  assert_eq "$(run_log_value 5)" yes
  owner_gh() { echo "  deploy  Report  nothing here"; }
  assert_eq "$(run_log_value 5)" no
  owner_gh() { echo "failed to get run log: HTTP 404" >&2; return 1; }
  assert_eq "$(run_log_value 5)" error
}

# S2c's three attempts, each answered by GitHub's complete refusal naming its endpoint's permission
# (round 112), then <extra> answer lines; the Environment's state reads the same each time.
s2c_replies() { # [extra answer line…]
  local p
  for p in administration=write environments=read environments=write; do
    gh_reply "reply-$p" drop=X-Accepted-Github-Permissions "add=X-Accepted-Github-Permissions: $p"
  done
  {
    printf '%s\n' "$@"
    echo "app_gh api -X PUT repos/$REPO/environments/frg26-test|1|@reply-administration=write"
    echo "app_gh api repos/$REPO/environments/frg26-test/secrets/public-key|1|@reply-environments=read"
    echo "app_gh api -X DELETE repos/$REPO/environments/frg26-test/secrets/|1|@reply-environments=write"
  } >"$T_TMP/answers"
  state_environment() { echo '{"the Environment":"as it was"}'; }
}

test_s2c_the_app_cannot_change_the_environment() {
  s2_stubs
  WORK="$T_TMP/work"
  owner_uid() { echo 42; }
  s2c_replies
  env_summary() { want_env; }
  local out calls
  WRITES_UNKNOWN="" WRITES_OUT=""
  t_S2c >"$T_TMP/out" 2>&1
  out="$(cat "$T_TMP/out")"
  assert_contains "$out" "RESULT S2c permissions PASS attempt=refused control=ok"
  # Round 112: the DELETE, read back unchanged, is settled; the PUT is a no-op no read can show, so its
  # outcome stays unknown however it was refused.
  assert_contains "$(unknown_writes)" "app gh api PUT repos/$REPO/environments/frg26-test (" "the no-op PUT named outcome unknown"
  assert_not_contains "$(unknown_writes)" "app gh api DELETE repos/$REPO/environments/frg26-test/secrets/FRG26_DISPOSABLE (" "the DELETE read back unchanged"
  calls="$(cat "$T_TMP/calls")"
  # Round 15, SEC-2: the app's write is the same no-op update the owner then makes as the control.
  assert_contains "$calls" "app_gh api -X PUT repos/$REPO/environments/frg26-test --input $WORK/env.json"
  assert_contains "$calls" "owner_gh api -X PUT repos/$REPO/environments/frg26-test --input $WORK/env.json"
  assert_eq "$(jq -c .prevent_self_review "$WORK/env.json")" true "the attempt weakens the Environment"
  assert_contains "$calls" "owner_gh api repos/$REPO/environments/frg26-test/secrets/public-key"
  # A disposable secret: the owner makes it, the app tries to delete it, the owner deletes it.
  assert_contains "$calls" "owner_gh secret set FRG26_DISPOSABLE --env frg26-test --repo $REPO"
  assert_contains "$calls" "app_gh api -X DELETE repos/$REPO/environments/frg26-test/secrets/FRG26_DISPOSABLE"
  assert_contains "$calls" "owner_gh api -X DELETE repos/$REPO/environments/frg26-test/secrets/FRG26_DISPOSABLE"
  assert_not_contains "$calls" "secrets/FRG26_DUMMY" "the real dummy value is never a target"
  s2c_replies "owner_gh api -X DELETE|1|gh: HTTP 500"
  out="$(t_S2c)"
  assert_contains "$out" "RESULT S2c permissions FAIL attempt=refused control=failed"
  end_stand_in_run
}

test_environment_tests_cover_the_plan() {
  load
  assert_eq "$S2_TEST_ORDER" "S2b S2d S2a S2c"
  local id
  for id in $S2_TEST_ORDER; do assert_eq "$(type -t "t_$id")" function "t_$id"; done
}

# --- Held tokens and revocation (plan 4.3) -----------------------------------------------------

held_stubs() {
  load
  app_files 123456
  SECRETS="$FRG26_SECRETS" APP_KEY="$FRG26_APP_KEY"
  HELD="$T_TMP/held-tokens.env"
  STATE="$T_TMP/frg26-state"
  # Steps run in subshells here, which don't run the exit clean-up that releases the lock: the lock
  # counts as held, and is tested on its own (test_only_one_step_uses_the_held_tokens_at_a_time).
  HELD_LOCKED=1
  WORK="$T_TMP/work"
  mkdir -p "$WORK"
  need_owner() { :; }
  assert_throwaway() { :; }
  : >"$T_TMP/calls"
}

test_a_held_token_is_kept_private_and_used_once() {
  held_stubs
  app_session() { TOKEN="ghs_session$(printf 'S%.0s' $(seq 1 30))"; }
  mint_token() { TOKEN="$(fake_token)"; }
  local out
  out="$(cmd_hold_token age 2>&1)"
  assert_not_contains "$out" "$(fake_token)" "the held token printed"
  assert_file_mode "$HELD" 600
  assert_eq "$(sed -n 1p "$HELD")" "HELD_AGE=$(fake_token)" "held tokens are VAR=value lines (ho_redact_file can hide them)"
  assert_contains "$(sed -n 2p "$HELD")" "HELD_AGE_AT=" "its issue time, in the same file (written whole)"
  app_gh() { echo "$REPO"; }
  revoke_token() { echo "revoke" >>"$T_TMP/calls"; TOKEN=""; }
  use_held age
  assert_eq "$HELD_RESULT" works
  assert_eq "$(cat "$T_TMP/calls")" "revoke" "a held token that still works is revoked after its check"
  assert_eq "$(grep -c '^HELD_AGE=' "$HELD")" 0 "the held token is removed after its check"
  assert_eq "$(grep -c '^HELD_AGE_AT=' "$HELD")" 0 "its issue time is removed too"
  local rc=0
  (cmd_hold_token nonsense) >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "an unknown held-token name"
}

test_a4_needs_a_token_over_an_hour_old() {
  held_stubs
  printf 'HELD_AGE=%s\n' "$(fake_token)" >"$HELD"; printf 'HELD_AGE_AT=%s\n' "$(( $(date +%s) - 600 ))" >>"$HELD"
  chmod 600 "$HELD"
  local rc=0 out
  out="$(cmd_token_age_check 2>&1)" || rc=$?
  assert_exit 2 "$rc" "a token ten minutes old"
  assert_contains "$out" "not over an hour old yet"
  printf 'HELD_AGE=%s\n' "$(fake_token)" >"$HELD"; printf 'HELD_AGE_AT=%s\n' "$(( $(date +%s) - 3700 ))" >>"$HELD"
  app_session() { TOKEN="ghs_session$(printf 'S%.0s' $(seq 1 30))"; }
  app_gh() { if [[ "$TOKEN" == ghs_session* ]]; then echo "$REPO"; else echo "gh: Bad credentials (HTTP 401)" >&2; return 1; fi; }
  rc=0; out="$(cmd_token_age_check 2>&1)" || rc=$?
  assert_exit 0 "$rc"
  assert_contains "$out" "RESULT A4 permissions PASS attempt=refused control=ok"
}

test_a9_the_deleted_keys_jwt_is_refused_and_the_new_keys_works() {
  held_stubs
  openssl genrsa -out "$T_TMP/app-new.pem" 2048 2>/dev/null
  chmod 600 "$T_TMP/app-new.pem"
  local old_key="$APP_KEY"
  jwt_call() {
    echo "jwt $1 $2 $([[ "$APP_KEY_SIGNED" == "$old_key" ]] && echo old || echo new)" >>"$T_TMP/jwt-calls"
    if [[ "$APP_KEY_SIGNED" == "$old_key" ]]; then LAST_HTTP=401; LAST_OUT='{"message":"A JSON web token could not be decoded"}'; return 1; fi
    case "$1 $2" in
      "POST app/installations/77/access_tokens") LAST_HTTP=201; LAST_OUT="$(token_fixture)" ;;
      *) LAST_HTTP=200; LAST_OUT='{"id":123456}' ;;
    esac
  }
  make_jwt() { APP_KEY_SIGNED="$APP_KEY"; JWT=jwt.stand-in.value; }
  need_app_identity() { INSTALLATION_ID=77; }
  printf 'HELD_KEYOLD=%s\n' "$(fake_token)" >"$HELD"; printf 'HELD_KEYOLD_AT=%s\n' "$(date +%s)" >>"$HELD"
  chmod 600 "$HELD"
  app_gh() { echo "gh: Bad credentials (HTTP 401)" >&2; return 1; }
  local out rc=0
  out="$(cmd_key_check 2>&1)" || rc=$?
  assert_exit 0 "$rc"
  assert_contains "$out" "RESULT A9 permissions PASS attempt=refused control=ok"
  # Round 19, C2: the attempt and the control are token requests, signed with each key.
  assert_contains "$(cat "$T_TMP/jwt-calls")" "jwt POST app/installations/77/access_tokens old"
  assert_contains "$(cat "$T_TMP/jwt-calls")" "jwt POST app/installations/77/access_tokens new"
  assert_contains "$out" "READING A9b a token issued before the key was deleted"
  assert_contains "$out" "HTTP 401"
  [[ -f "$T_TMP/app.pem" && ! -f "$T_TMP/app-new.pem" ]] || _t_fail "the new key did not become app.pem"
}

test_e1_records_the_suspension_and_needs_the_control() {
  held_stubs
  jwt_call() {
    case "$1 $2" in
      "GET app/installations"*) LAST_HTTP=200; LAST_OUT='[{"id":77,"account":{"login":"Thebigtuna88"},"suspended_at":"2026-11-02T00:00:00Z"}]' ;;
      "POST app/installations/77/access_tokens") LAST_HTTP=403; LAST_OUT='{"message":"This installation has been suspended"}'; return 1 ;;
    esac
  }
  make_jwt() { JWT=x; }
  printf 'HELD_SUSPEND=%s\n' "$(fake_token)" >"$HELD"; printf 'HELD_SUSPEND_AT=%s\n' "$(date +%s)" >>"$HELD"
  chmod 600 "$HELD"
  app_gh() { echo "gh: Bad credentials (HTTP 401)" >&2; return 1; }
  local out
  out="$(cmd_suspend_check 2>&1)"
  assert_contains "$out" "E1 a new token while suspended: refused"
  assert_contains "$out" "READING E1 a token issued before the suspension"
  assert_eq "$(state_get E1)" "refused HTTP-403"
  app_session() { TOKEN="ghs_control$(printf 'C%.0s' $(seq 1 30))"; }
  revoke_token() { echo "revoke ${TOKEN:0:11}" >>"$T_TMP/calls"; TOKEN=""; }
  local rc=0
  out="$(cmd_unsuspend_check 2>&1)" || rc=$?
  assert_exit 0 "$rc"
  assert_contains "$out" "RESULT E1 permissions PASS attempt=refused control=ok"
  # Round 13, C1/SEC-3: the control ran in a subshell; its token must not outlive it.
  assert_contains "$(cat "$T_TMP/calls")" "revoke ghs_control" "the control's token was revoked"
  app_session() { die "the app's installation is suspended"; }
  rc=0; out="$(cmd_unsuspend_check 2>&1)" || rc=$?
  assert_exit 1 "$rc" "no control after unsuspending"
  assert_contains "$out" "RESULT E1 permissions FAIL"
}

test_a_held_token_is_revoked_whatever_its_read_says() {
  # Round 13, C4/SEC-6: revocation is tried whatever the read says. The token is removed only once
  # that is settled (revoked, or refused as bad credentials); an unreachable or rate-limited GitHub
  # stops the step and keeps the token for a retry.
  held_stubs
  local rc out
  put_held() { printf 'HELD_SUSPEND=%s\n' "$(fake_token)" >"$HELD"; printf 'HELD_SUSPEND_AT=%s\n' "$(date +%s)" >>"$HELD"; chmod 600 "$HELD"; }
  revoke_token() { echo "revoke" >>"$T_TMP/calls"; TOKEN=""; return "${REVOKE_RC:-0}"; }

  put_held
  app_gh() { echo "gh: This installation has been suspended (HTTP 403)" >&2; return 1; }
  REVOKE_RC=1
  use_held suspend >/dev/null
  assert_eq "$HELD_RESULT" "HTTP 403"
  assert_eq "$(cat "$T_TMP/calls")" "revoke" "revocation tried after a refused read"
  assert_contains "$(cat "$HELD")" "HELD_SUSPEND=" "kept: not revoked, and it may work again"

  : >"$T_TMP/calls"
  REVOKE_RC=0
  use_held suspend >/dev/null
  assert_eq "$(cat "$T_TMP/calls")" "revoke"
  assert_eq "$(grep -c HELD_SUSPEND "$HELD")" 0 "removed once revoked"

  put_held
  app_gh() { echo "gh: HTTP 503 Service Unavailable" >&2; return 1; }
  REVOKE_RC=1
  rc=0; out="$(use_held suspend 2>&1)" || rc=$?
  assert_exit 2 "$rc" "GitHub unavailable"
  assert_contains "$out" "kept"
  assert_contains "$(cat "$HELD")" "HELD_SUSPEND=" "kept after a server error"

  app_gh() { echo "gh: API rate limit exceeded (HTTP 403)" >&2; return 1; }
  rc=0; out="$(use_held suspend 2>&1)" || rc=$?
  assert_exit 2 "$rc" "a rate limit is not GitHub's answer about the token"
  assert_contains "$(cat "$HELD")" "HELD_SUSPEND=" "kept after a rate limit"

  # Final (the installation or the app is gone): removed even when revocation can't be confirmed.
  app_gh() { echo "gh: Not Found (HTTP 404)" >&2; return 1; }
  REVOKE_RC=1
  use_held suspend final >/dev/null
  assert_eq "$(grep -c HELD_SUSPEND "$HELD")" 0 "removed after a final check"
}

test_suspend_check_does_not_count_a_rate_limit_as_a_refusal() {
  # Round 13, class check of C2/SEC-2: a rate-limited 403 is not GitHub refusing a suspended app.
  held_stubs
  make_jwt() { JWT=x; }
  jwt_call() {
    case "$1 $2" in
      "GET app/installations"*) LAST_HTTP=200; LAST_OUT='[{"id":77,"account":{"login":"Thebigtuna88"},"suspended_at":"2026-11-02T00:00:00Z"}]' ;;
      "POST app/installations/77/access_tokens") LAST_HTTP=403; LAST_OUT='{"message":"API rate limit exceeded for installation ID 77."}'; return 1 ;;
    esac
  }
  printf 'HELD_SUSPEND=%s\n' "$(fake_token)" >"$HELD"
  printf 'HELD_SUSPEND_AT=%s\n' "$(date +%s)" >>"$HELD"
  chmod 600 "$HELD"
  app_gh() { echo "gh: Bad credentials (HTTP 401)" >&2; return 1; }
  cmd_suspend_check >/dev/null 2>&1
  assert_eq "$(state_get E1)" "inconclusive HTTP-403"
}

test_unsuspend_check_keeps_a_token_it_could_not_revoke() {
  # Round 14, SEC-1: after unsuspending the installation exists, so the held token is not "final":
  # if it can't be revoked, it stays held and the step fails.
  held_stubs
  printf 'HELD_SUSPEND=%s\n' "$(fake_token)" >"$HELD"
  printf 'HELD_SUSPEND_AT=%s\n' "$(date +%s)" >>"$HELD"
  chmod 600 "$HELD"
  state_set E1 "refused HTTP-403"
  state_set E1_HELD ok
  app_session() { :; }
  app_gh() { echo "$REPO"; }
  revoke_token() { TOKEN=""; return 1; }
  local rc=0 out
  out="$(cmd_unsuspend_check 2>&1)" || rc=$?
  assert_exit 2 "$rc" "a working token that couldn't be revoked"
  assert_contains "$(cat "$HELD")" "HELD_SUSPEND=" "the token was discarded"
  revoke_token() { echo "revoke" >>"$T_TMP/calls"; TOKEN=""; return 0; }
  rc=0; out="$(cmd_unsuspend_check 2>&1)" || rc=$?
  assert_exit 0 "$rc"
  assert_eq "$(grep -c HELD_SUSPEND "$HELD")" 0 "removed once revoked"
}

# Round 31: a stateless token survives the held file's write and read.
test_a_held_token_in_githubs_stateless_format_reads_back() {
  held_stubs
  held_write age "$(new_token)" || _t_fail "the held file was not written"
  local got
  got="$(held_get age)" || _t_fail "the held token did not read back"
  assert_eq "${got%% *}" "$(new_token)"
}

test_holding_a_name_again_settles_the_earlier_token_first() {
  # Round 14, SEC-2: a retried hold-token must not abandon the token it held before.
  held_stubs
  app_session() { TOKEN="ghs_session$(printf 'S%.0s' $(seq 1 30))"; }
  mint_token() { TOKEN="ghs_newheld$(printf 'N%.0s' $(seq 1 30))"; }
  printf 'HELD_AGE=%s\n' "$(fake_token)" >"$HELD"
  printf 'HELD_AGE_AT=%s\n' "$(date +%s)" >>"$HELD"
  chmod 600 "$HELD"
  app_gh() { echo "$REPO"; }
  revoke_token() { echo "revoke ${TOKEN:0:8}" >>"$T_TMP/calls"; TOKEN=""; return "${REVOKE_RC:-0}"; }
  local rc=0
  cmd_hold_token age >/dev/null 2>&1 || rc=$?
  assert_exit 0 "$rc"
  assert_eq "$(cat "$T_TMP/calls")" "revoke ghs_ZZZZ" "the earlier token was revoked first"
  assert_contains "$(cat "$HELD")" "HELD_AGE=ghs_newheld"
  # If the earlier token can't be settled, nothing new is held and the step fails.
  printf 'HELD_AGE=%s\n' "$(fake_token)" >"$HELD"
  printf 'HELD_AGE_AT=%s\n' "$(date +%s)" >>"$HELD"
  : >"$T_TMP/calls"
  REVOKE_RC=1
  rc=0
  (cmd_hold_token age) >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc"
  assert_eq "$(grep '^HELD_AGE=' "$HELD")" "HELD_AGE=$(fake_token)" "the earlier token was replaced while still unsettled"
  end_stand_in_run
}

test_an_unreliable_read_still_tries_to_revoke_the_held_token() {
  # Round 14, C2: revocation is tried even when the read was unreliable. Revoked: removed (that
  # reading is lost, the step fails). Not revoked: kept for a retry, the step fails.
  held_stubs
  put_held() { printf 'HELD_AGE=%s\n' "$(fake_token)" >"$HELD"; printf 'HELD_AGE_AT=%s\n' "$(date +%s)" >>"$HELD"; chmod 600 "$HELD"; }
  revoke_token() { echo "revoke" >>"$T_TMP/calls"; TOKEN=""; return "${REVOKE_RC:-0}"; }
  app_gh() { echo "gh: HTTP 503 Service Unavailable" >&2; return 1; }
  local rc out
  put_held
  REVOKE_RC=0
  rc=0; out="$(use_held age 2>&1)" || rc=$?
  assert_exit 2 "$rc"
  assert_eq "$(cat "$T_TMP/calls")" "revoke" "revocation tried after an unreliable read"
  assert_eq "$(grep -c HELD_AGE "$HELD")" 0 "a revoked token is removed"
  assert_contains "$out" "revoked"
  : >"$T_TMP/calls"
  put_held
  REVOKE_RC=1
  rc=0; out="$(use_held age 2>&1)" || rc=$?
  assert_exit 2 "$rc"
  assert_eq "$(cat "$T_TMP/calls")" "revoke"
  assert_contains "$(cat "$HELD")" "HELD_AGE=" "kept when it couldn't be revoked"
}

test_environment_cleanup_confirms_no_run_still_waits() {
  # Round 14, C4: listing every page, cancelling, and confirming none still waits; any failure fails.
  load
  sleep() { :; }
  : >"$T_TMP/owner"
  owner_gh() {
    echo "$*" >>"$T_TMP/owner"
    case "$*" in
      *"actions/runs?per_page=100"*) [[ -f "$T_TMP/list-fails" ]] && return 1
        if [[ -f "$T_TMP/cancelled" && ! -f "$T_TMP/stuck" ]]; then return 0; fi
        printf '701\n702\n' ;;
      *"/cancel"*) touch "$T_TMP/cancelled" ;;
    esac
  }
  local rc=0
  cancel_waiting_runs >/dev/null || rc=$?
  assert_exit 0 "$rc" "both runs cancelled"
  assert_contains "$(cat "$T_TMP/owner")" "--paginate"
  assert_contains "$(cat "$T_TMP/owner")" "actions/runs/701/cancel"
  assert_contains "$(cat "$T_TMP/owner")" "actions/runs/702/cancel"
  rm -f "$T_TMP/cancelled"
  touch "$T_TMP/stuck"
  rc=0; cancel_waiting_runs >/dev/null || rc=$?
  assert_exit 1 "$rc" "a run that still waits"
  rm -f "$T_TMP/stuck"
  touch "$T_TMP/list-fails"
  rc=0; cancel_waiting_runs >/dev/null || rc=$?
  assert_exit 1 "$rc" "an unreadable list"
  # Round 73 (C2): each failure is kept for the clean-up's last line.
  assert_contains "$CLEANUP_UNDONE" "cancelling the waiting S2 runs"
  end_stand_in_run
}

test_cleanup_waits_for_the_runs_this_run_started() {
  # Round 22, C2: a run still queued (not yet waiting) when env-tests stops must not be missed: the
  # clean-up gives each commit env-tests made time to register its run, then cancels every
  # unfinished S2 run, whatever its status.
  load
  sleep() { :; }
  S2_SHAS="$(printf 'a%.0s' $(seq 1 40))"
  : >"$T_TMP/owner"
  owner_gh() {
    echo "$*" >>"$T_TMP/owner"
    case "$*" in
      *"head_sha="*)
        local n
        n=$(grep -c 'head_sha=' "$T_TMP/owner")
        [[ $n -ge 3 ]] && echo "901 queued null Thebigtuna88"
        ;;
      *"actions/runs?per_page=100"*)
        if [[ $(grep -c 'head_sha=' "$T_TMP/owner") -ge 3 && ! -f "$T_TMP/cancelled" ]]; then echo 901; fi
        ;;
      *"/cancel"*) touch "$T_TMP/cancelled" ;;
    esac
    return 0
  }
  local rc=0
  cancel_waiting_runs >/dev/null || rc=$?
  assert_exit 0 "$rc"
  assert_contains "$(cat "$T_TMP/owner")" "actions/runs/901/cancel" "the queued run was not cancelled"
  [[ $(grep -c 'head_sha=' "$T_TMP/owner") -ge 3 ]] || _t_fail "the clean-up did not wait for the run to register"
  assert_not_contains "$(cat "$T_TMP/owner")" "status=waiting" "only waiting runs were listed"
}

test_the_workflow_commit_is_known_from_its_own_answer() {
  # Round 24, SEC-1: the owner's workflow commit is read from the write's own answer, not from a
  # later read of main that could fail after the run had started.
  local out rc=0 sha
  sha="$(printf 'f%.0s' $(seq 1 40))"
  out="$(load
    need_owner() { :; }
    assert_throwaway() { :; }
    app_session() { :; }
    verify_phase() { :; }
    need_allowance() { :; }
    env_summary() { want_env; }
    app_git() { :; }
    owner_gh() {
      # (pattern) form: bash 3.2 misparses a bare "pattern)" inside $( ).
      case "$*" in
        (*"contents/.github/workflows/frg26-s2.yml"*) echo "$sha" ;;
        (*"branches/main"*) return 1 ;;
      esac
      return 0
    }
    WORK="$T_TMP/work"
    mkdir -p "$WORK"
    for id in $S2_TEST_ORDER; do eval "t_$id() { record_p $id refused ok stand-in; }"; done
    cancel_waiting_runs() { echo "CLEANUP S2_SHAS=$S2_SHAS UNKNOWN=${S2_UNKNOWN:-no}"; }
    cmd_env_tests 2>&1)" || rc=$?
  assert_exit 0 "$rc"
  assert_contains "$out" "CLEANUP S2_SHAS= $sha UNKNOWN=no"
}

test_an_unknown_workflow_commit_fails_the_cleanup() {
  # Round 24, SEC-1: a workflow commit that may have happened, but whose sha isn't known, can't be
  # reconciled: the clean-up still cancels what it sees, and fails.
  load
  sleep() { :; }
  S2_UNKNOWN=1
  S2_SHAS=""
  : >"$T_TMP/owner"
  owner_gh() { echo "$*" >>"$T_TMP/owner"; return 0; }
  local rc=0 out
  out="$(cancel_waiting_runs)" || rc=$?
  assert_exit 1 "$rc"
  assert_contains "$out" "unknown"
  assert_contains "$(cat "$T_TMP/owner")" "actions/runs?per_page=100" "it still cancels what it sees"
}

test_an_unseen_run_does_not_stop_the_visible_ones_being_cancelled() {
  # Round 25, SEC-1: one commit's run that never showed still fails the clean-up, but only after every
  # visible unfinished run was cancelled and confirmed.
  load
  sleep() { :; }
  S2_SHAS="$(printf 'b%.0s' $(seq 1 40))"
  : >"$T_TMP/owner"
  owner_gh() {
    echo "$*" >>"$T_TMP/owner"
    case "$*" in
      *"head_sha="*) return 1 ;;
      *"actions/runs?per_page=100"*) if [[ ! -f "$T_TMP/cancelled" ]]; then echo 902; fi ;;
      *"/cancel"*) touch "$T_TMP/cancelled" ;;
    esac
    return 0
  }
  local rc=0 out
  out="$(cancel_waiting_runs)" || rc=$?
  assert_exit 1 "$rc"
  assert_contains "$out" "never appeared"
  assert_contains "$(cat "$T_TMP/owner")" "actions/runs/902/cancel" "a visible run was left"
}

test_the_apps_s2_commits_are_recorded_before_they_are_pushed() {
  # Round 25, C2: GitHub can accept a push (and start its run) although the push reports a failure,
  # so S2b's and S2a's commits are recorded for the clean-up before they are pushed.
  local id out
  for id in S2b S2a; do
    out="$(s2_stubs
      # Not named sha: the local sha in t_S2b and t_S2a would hide it from this stand-in.
      fake_sha="$(printf 'c%.0s' $(seq 1 40))"
      app_git() {
        case "$*" in
          (*rev-parse*) echo "$fake_sha" ;;
          (*push*) echo "fatal: the remote end hung up unexpectedly" >&2; return 1 ;;
        esac
        return 0
      }
      S2_SHAS=""
      "t_$id" >/dev/null 2>&1
      echo "SHAS=$S2_SHAS")"
    assert_contains "$out" "SHAS= $(printf 'c%.0s' $(seq 1 40))" "$id's commit after a failed push"
  done
}

test_environment_tests_fail_when_their_cleanup_fails() {
  load
  need_owner() { :; }
  assert_throwaway() { :; }
  app_session() { :; }
  verify_phase() { :; }
  need_allowance() { :; }
  env_summary() { want_env; }
  put_file() { :; }
  owner_gh() { printf '%s\n' "$(printf 'd%.0s' $(seq 1 40))"; }
  app_git() { :; }
  WORK="$T_TMP/work"
  mkdir -p "$WORK"
  local id
  for id in $S2_TEST_ORDER; do eval "t_$id() { record_p $id refused ok stand-in; }"; done
  cancel_waiting_runs() { return 1; }
  local rc=0 out
  out="$(cmd_env_tests 2>&1)" || rc=$?
  assert_exit 1 "$rc"
  assert_not_contains "$out" "ENVIRONMENT TESTS: ALL PASS"
  cancel_waiting_runs() { return 0; }
  rc=0; out="$(cmd_env_tests 2>&1)" || rc=$?
  assert_exit 0 "$rc"
  assert_contains "$out" "ENVIRONMENT TESTS: ALL PASS"
}

test_a_held_token_that_cannot_be_stored_is_revoked() {
  # Round 15, C1/SEC-3: if its record can't be written, the newly held token is revoked at once, and
  # no partial record is left.
  held_stubs
  mkdir -m 700 "$T_TMP/ro"
  HELD="$T_TMP/ro/held-tokens.env"
  chmod 500 "$T_TMP/ro"
  app_session() { TOKEN="ghs_session$(printf 'S%.0s' $(seq 1 30))"; }
  mint_token() { TOKEN="ghs_newheld$(printf 'N%.0s' $(seq 1 30))"; }
  revoke_token() { echo "revoke ${TOKEN:0:11}" >>"$T_TMP/calls"; TOKEN=""; return 0; }
  local rc=0 out
  out="$(cmd_hold_token age 2>&1)" || rc=$?
  chmod 700 "$T_TMP/ro"
  assert_exit 2 "$rc"
  assert_contains "$(cat "$T_TMP/calls")" "revoke ghs_newheld" "the unstored token was revoked"
  assert_contains "$out" "revoked"
  [[ ! -e "$HELD" ]] || _t_fail "a partial held record was left"
}

test_an_incomplete_held_record_is_never_dropped_unrevoked() {
  # Round 15, C1: a token line without its time (written by hand, or by an older version) stops
  # hold-token instead of being replaced.
  held_stubs
  app_session() { TOKEN="ghs_session$(printf 'S%.0s' $(seq 1 30))"; }
  mint_token() { TOKEN="ghs_newheld$(printf 'N%.0s' $(seq 1 30))"; }
  printf 'HELD_AGE=%s\n' "$(fake_token)" >"$HELD"
  chmod 600 "$HELD"
  local rc=0
  (cmd_hold_token age) >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc"
  assert_eq "$(cat "$HELD")" "HELD_AGE=$(fake_token)" "the incomplete record was replaced"
}

test_key_check_keeps_the_new_key_aside_while_the_old_token_is_unsettled() {
  # Round 16, SEC-1: if the keyold token still works and can't be revoked, key-check stops before
  # the new key replaces app.pem, so running it again can settle the token.
  held_stubs
  openssl genrsa -out "$T_TMP/app-new.pem" 2048 2>/dev/null
  chmod 600 "$T_TMP/app-new.pem"
  local old_key="$APP_KEY"
  jwt_call() {
    echo "jwt $1 $2 $([[ "$APP_KEY_SIGNED" == "$old_key" ]] && echo old || echo new)" >>"$T_TMP/jwt-calls"
    if [[ "$APP_KEY_SIGNED" == "$old_key" ]]; then LAST_HTTP=401; LAST_OUT='{"message":"A JSON web token could not be decoded"}'; return 1; fi
    case "$1 $2" in
      "POST app/installations/77/access_tokens") LAST_HTTP=201; LAST_OUT="$(token_fixture)" ;;
      *) LAST_HTTP=200; LAST_OUT='{"id":123456}' ;;
    esac
  }
  make_jwt() { APP_KEY_SIGNED="$APP_KEY"; JWT=jwt.stand-in.value; }
  need_app_identity() { INSTALLATION_ID=77; }
  printf 'HELD_KEYOLD=%s\nHELD_KEYOLD_AT=%s\n' "$(fake_token)" "$(date +%s)" >"$HELD"
  chmod 600 "$HELD"
  app_gh() { echo "$REPO"; }
  revoke_token() { TOKEN=""; return 1; }
  local rc=0
  (cmd_key_check) >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "an old-key token still working and unrevoked"
  [[ -f "$T_TMP/app-new.pem" ]] || _t_fail "the new key replaced app.pem before the old token was settled"
  assert_contains "$(cat "$HELD")" "HELD_KEYOLD=" "the unsettled token was dropped"
  # Run again, the revocation now works: settled, then the new key becomes app.pem.
  revoke_token() { TOKEN=""; return 0; }
  rc=0
  (cmd_key_check) >/dev/null 2>&1 || rc=$?
  assert_exit 0 "$rc" "the retry"
  [[ -f "$T_TMP/app.pem" && ! -f "$T_TMP/app-new.pem" ]] || _t_fail "the retry did not install the new key"
}

# Round 38, C1: S2a passes, but the clean-up after it fails: that counts, so S2c (which writes a
# disposable secret) never runs. Control: the clean-up works and FAILS stays 0.
test_a_failed_cleanup_after_s2a_stops_the_environment_tests() {
  s2_stubs
  app_git() { [[ "$*" == *rev-parse* ]] && printf 'c%.0s' $(seq 1 40) && echo; return 0; }
  local sha out
  sha="$(printf 'c%.0s' $(seq 1 40))"
  echo "503 completed failure frg26-test-app[bot]" >"$T_TMP/run-$sha"
  deploy_job() { echo "9001 0 failure"; }
  policy_rejected() { :; }
  cancel_waiting_runs() { echo "CLEANUP FAIL stand-in"; return 1; }
  out="$(FAILS=0; t_S2a; echo "fails=$FAILS")"
  assert_contains "$out" "RESULT S2a permissions PASS attempt=refused"
  assert_contains "$out" "fails=1" "a failed clean-up after a passing S2a"
  cancel_waiting_runs() { :; }
  out="$(FAILS=0; t_S2a; echo "fails=$FAILS")"
  assert_contains "$out" "fails=0" "a clean-up that worked"
}

test_s2a_reads_the_annotation_of_the_jobs_check_run() {
  # Round 16, C1: an Actions job id is not a check-run id; the check run comes from check_run_url.
  load
  owner_gh() {
    echo "$*" >>"$T_TMP/owner"
    local q="" path=""
    while [[ $# -gt 0 ]]; do
      case "$1" in --jq) q="$2"; shift ;; repos/*) path="$1" ;; esac
      shift
    done
    case "$path" in
      */actions/runs/503/jobs) jq -r "$q" <<<'{"jobs":[{"id":111,"name":"deploy","conclusion":"failure","steps":[],"check_run_url":"https://api.github.com/repos/x/y/check-runs/222"}]}' ;;
      */check-runs/222/annotations) jq -r "$q" <<<'[{"message":"Branch \"frg26-s2-a-1\" is not allowed to deploy to frg26-test due to environment protection rules."}]' ;;
      *) return 1 ;;
    esac
  }
  : >"$T_TMP/owner"
  assert_eq "$(deploy_job 503)" "222 0 failure" "the deploy job's check-run id, steps run, conclusion"
  policy_rejected 222 || _t_fail "the branch-policy annotation was not found"
  assert_not_contains "$(cat "$T_TMP/owner")" "check-runs/111" "the job id used as a check-run id"
}

test_an_error_in_env_tests_still_cancels_waiting_runs() {
  # Round 16, C2: once the owner's workflow commit has started a run, any exit cancels waiting runs.
  local out rc=0
  out="$(load
    need_owner() { :; }
    assert_throwaway() { :; }
    app_session() { :; }
    verify_phase() { :; }
    need_allowance() { :; }
    env_summary() { want_env; }
    put_file() { :; }
    owner_gh() { return 1; }
    cancel_waiting_runs() { echo "CANCELLED-WAITING-RUNS"; }
    WORK="$T_TMP/work"
    mkdir -p "$WORK"
    cmd_env_tests 2>&1)" || rc=$?
  assert_exit 2 "$rc"
  assert_contains "$out" "adding the S2 workflow"
  assert_contains "$out" "CANCELLED-WAITING-RUNS"
}

test_a_rejected_second_token_leaves_the_session_token_to_the_exit() {
  # Round 17, C2: when a second token (A5, hold-token) is rejected, the session token minted before
  # it is still revoked on exit.
  local out
  out="$(app_stubs
    INSTALLATION_ID=77
    app_gh() { echo "app_gh ${TOKEN:0:12} $*" >>"$T_TMP/app-gh.log"; }
    mint_token >/dev/null
    token_fixture | jq -c '.token = "ghs_second'"$(printf 'Q%.0s' $(seq 1 30))"'" | .permissions.administration = "write"' >"$T_TMP/token.json"
    mint_token 2>&1)" || true
  assert_contains "$out" "revoked"
  assert_contains "$(cat "$T_TMP/app-gh.log")" "app_gh ghs_secondQQ api -X DELETE installation/token" "the rejected token"
  assert_contains "$(cat "$T_TMP/app-gh.log")" "app_gh ghs_ZZZZZZZZ api -X DELETE installation/token" "the session token, on exit"
}

test_a_held_token_is_not_revoked_on_exit_but_the_session_is() {
  held_stubs
  app_stubs
  HELD="$T_TMP/held-tokens.env"
  need_owner() { :; }
  assert_throwaway() { :; }
  app_session() { INSTALLATION_ID=77; mint_token; }
  need_installation_scope() { :; }
  app_gh() { echo "app_gh ${TOKEN:0:12} $*" >>"$T_TMP/app-gh.log"; }
  local n=0
  jwt_call() {
    LAST_HTTP=201
    n=$((n + 1))
    printf '%s' "$(token_fixture | jq -c --arg t "ghs_tok${n}$(printf 'T%.0s' $(seq 1 30))" '.token = $t')" >"$T_TMP/ans"
    LAST_OUT="$(cat "$T_TMP/ans")"
  }
  (cmd_hold_token age; cleanup) >/dev/null 2>&1
  assert_contains "$(cat "$T_TMP/app-gh.log")" "app_gh ghs_tok1TTTT api -X DELETE installation/token" "the session token"
  assert_not_contains "$(cat "$T_TMP/app-gh.log")" "ghs_tok2" "the held token was revoked on exit"
  assert_contains "$(cat "$HELD")" "HELD_AGE=ghs_tok2"
}

test_suspend_check_stops_if_its_observation_cannot_be_stored() {
  # Round 17, C1: suspend-check's observation is what unsuspend-check judges; if it can't be stored
  # (or an old one cleared) the step fails, so no stale observation can be judged.
  held_stubs
  make_jwt() { JWT=x; }
  jwt_call() {
    case "$1 $2" in
      "GET app/installations"*) LAST_HTTP=200; LAST_OUT='[{"id":77,"account":{"login":"Thebigtuna88"},"suspended_at":"2026-11-02T00:00:00Z"}]' ;;
      "POST app/installations/77/access_tokens") LAST_HTTP=201; LAST_OUT="$(token_fixture)" ;;
    esac
  }
  app_gh() { echo "gh: Bad credentials (HTTP 401)" >&2; return 1; }
  printf 'HELD_SUSPEND=%s\nHELD_SUSPEND_AT=%s\n' "$(fake_token)" "$(date +%s)" >"$HELD"
  chmod 600 "$HELD"
  mkdir -m 700 "$T_TMP/ro"
  printf 'E1 refused HTTP-403\n' >"$T_TMP/ro/frg26-state"
  STATE="$T_TMP/ro/frg26-state"
  chmod 500 "$T_TMP/ro"
  local rc=0
  (cmd_suspend_check) >/dev/null 2>&1 || rc=$?
  chmod 700 "$T_TMP/ro"
  assert_exit 2 "$rc" "an observation that couldn't be stored"
  rc=0
  STATE="$T_TMP/frg26-state"
  printf 'E1 refused HTTP-403\n' >"$STATE"
  (cmd_suspend_check) >/dev/null 2>&1 || rc=$?
  assert_eq "$(state_get E1)" "allowed HTTP-201" "the stored observation is this run's"
}

test_a_held_token_near_expiry_gives_no_revocation_reading() {
  # Round 18, C1: a refused token close to its hour proves nothing about uninstalling (or a key's
  # deletion, a suspension, the app's deletion): expiry alone could explain it. Such a reading is
  # INCONCLUSIVE and the step fails; a fresh refused token, or one that still works, is a reading.
  held_stubs
  make_jwt() { JWT=jwt.stand-in.value; }
  jwt_call() { LAST_HTTP=200; LAST_OUT='[]'; }
  app_gh() { echo "gh: Bad credentials (HTTP 401)" >&2; return 1; }
  put() { printf 'HELD_UNINSTALL=%s\nHELD_UNINSTALL_AT=%s\n' "$(fake_token)" "$(( $(date +%s) - $1 ))" >"$HELD"; chmod 600 "$HELD"; }
  local rc out
  put 3500
  rc=0; out="$(cmd_uninstall_check 2>&1)" || rc=$?
  assert_exit 1 "$rc" "a refused token 58 minutes old"
  assert_contains "$out" "READING E2 INCONCLUSIVE"
  # The age is read a moment after it was written: a second or two may have passed.
  [[ "$out" =~ "the token was 350"[0-9]" s old" ]] || _t_fail "the token's age in: $out"
  put 600
  rc=0; out="$(cmd_uninstall_check 2>&1)" || rc=$?
  assert_exit 0 "$rc" "a refused token 10 minutes old"
  [[ "$out" =~ "READING E2 a token issued before the uninstall: HTTP 401 (issued 60"[0-9]" s earlier)" ]] || _t_fail "the reading in: $out"
  put 3500
  app_gh() { echo "$REPO"; }
  rc=0; out="$(cmd_uninstall_check 2>&1)" || rc=$?
  assert_exit 0 "$rc" "an old token that still works is a reading"
  assert_contains "$out" "works"
}

test_a_held_record_that_cannot_be_removed_stops_the_step() {
  # Round 18, C2: a settled token whose record can't be removed must not let the step succeed (a
  # later check could reuse it).
  held_stubs
  mkdir -m 700 "$T_TMP/ro"
  HELD="$T_TMP/ro/held-tokens.env"
  printf 'HELD_AGE=%s\nHELD_AGE_AT=%s\n' "$(fake_token)" "$(date +%s)" >"$HELD"
  chmod 600 "$HELD"
  chmod 500 "$T_TMP/ro"
  app_gh() { echo "gh: Bad credentials (HTTP 401)" >&2; return 1; }
  local rc=0 out
  out="$(use_held age 2>&1)" || rc=$?
  chmod 700 "$T_TMP/ro"
  assert_exit 2 "$rc"
  assert_contains "$out" "couldn't remove the held record"
}

test_a_final_check_keeps_a_token_that_still_works_and_cannot_be_revoked() {
  # Round 19, SEC-1: "final" (uninstall, deletion) settles only a token that is refused; one that
  # still works stays held if it can't be revoked, and the step fails after its reading.
  held_stubs
  make_jwt() { JWT=jwt.stand-in.value; }
  jwt_call() { LAST_HTTP=200; LAST_OUT='[]'; }
  printf 'HELD_UNINSTALL=%s\nHELD_UNINSTALL_AT=%s\n' "$(fake_token)" "$(date +%s)" >"$HELD"
  chmod 600 "$HELD"
  app_gh() { echo "$REPO"; }
  revoke_token() { TOKEN=""; return 1; }
  local rc=0 out
  out="$(cmd_uninstall_check 2>&1)" || rc=$?
  assert_exit 2 "$rc" "a working token that couldn't be revoked"
  assert_contains "$out" "READING E2 a token issued before the uninstall: works"
  assert_contains "$(cat "$HELD")" "HELD_UNINSTALL=" "the working token's record was removed"
  revoke_token() { TOKEN=""; return 0; }
  rc=0; out="$(cmd_uninstall_check 2>&1)" || rc=$?
  assert_exit 0 "$rc" "revoked this time"
  assert_eq "$(grep -c HELD_UNINSTALL "$HELD")" 0
}

test_only_one_step_uses_the_held_tokens_at_a_time() {
  # Round 19, C1: the held file's read-modify-write is serialized: a step that finds another one
  # holding the lock stops before touching any token, and the lock is released when a step ends.
  held_stubs
  # Registered as request_token does, with GitHub's expiry (round 74: the clean-up confirms the
  # session token's revocation only with it).
  app_session() {
    TOKEN="ghs_session$(printf 'S%.0s' $(seq 1 30))" OUTSTANDING="$OUTSTANDING $TOKEN" ISSUED="$ISSUED token1=$TOKEN"
    ISSUED_META="token1 {\"expires_at\":\"$(date -u -v+50M +%Y-%m-%dT%H:%M:%SZ)\"}
"
  }
  mint_token() { TOKEN="ghs_newheld$(printf 'N%.0s' $(seq 1 30))"; }
  # As GitHub: a read with a token revoked earlier gets HTTP 401 (the exit clean-up's check).
  app_gh() {
    echo "app_gh $*" >>"$T_TMP/calls"
    if [[ "$*" == "api -X DELETE installation/token" ]]; then echo "$TOKEN" >>"$T_TMP/revoked"; fi
    if [[ "$*" == "api repos/$REPO --jq .full_name" ]] && grep -qxF "$TOKEN" "$T_TMP/revoked" 2>/dev/null; then
      echo "gh: Bad credentials (HTTP 401)" >&2
      return 1
    fi
  }
  HELD_LOCKED=""
  mkdir "$HELD.lock"
  local rc=0 out
  out="$(cmd_hold_token age 2>&1)" || rc=$?
  assert_exit 2 "$rc" "a second step while the lock is held"
  assert_contains "$out" "another FRG-26 step"
  [[ ! -e "$HELD" ]] || _t_fail "a held record was written without the lock"
  rmdir "$HELD.lock"
  rc=0
  (cmd_hold_token age; cleanup) >/dev/null 2>&1 || rc=$?
  assert_exit 0 "$rc"
  [[ ! -e "$HELD.lock" ]] || _t_fail "the lock was left behind"
  assert_contains "$(cat "$HELD")" "HELD_AGE=ghs_newheld"
}

test_an_inconclusive_e1_reading_survives_a_retry() {
  # Round 21, C1: an inconclusive held-token reading is stored, so retrying unsuspend-check (or
  # running it after suspend-check stopped) can't pass on the new-token record alone; E1 completes
  # only after a whole new suspension cycle gives a reading.
  held_stubs
  app_session() { :; }
  state_set E1 "refused HTTP-403"
  local rc out
  for held in inconclusive pending ""; do
    if [[ -n "$held" ]]; then state_set E1_HELD "$held"; else
      grep -v '^E1_HELD ' "$STATE" >"$STATE.x"; mv "$STATE.x" "$STATE"
    fi
    rc=0; out="$(cmd_unsuspend_check 2>&1)" || rc=$?
    assert_exit 1 "$rc" "E1_HELD '${held:-missing}'"
    assert_contains "$out" "E1 again" "E1_HELD '${held:-missing}'"
  done
  state_set E1_HELD ok
  state_set E1_AFTER none
  rc=0; out="$(cmd_unsuspend_check 2>&1)" || rc=$?
  assert_exit 0 "$rc" "a conclusive reading"
  # suspend-check stores its reading's state: a near-expiry refusal is "inconclusive".
  make_jwt() { JWT=jwt.stand-in.value; }
  jwt_call() {
    case "$1 $2" in
      "GET app/installations"*) LAST_HTTP=200; LAST_OUT='[{"id":77,"account":{"login":"Thebigtuna88"},"suspended_at":"2026-11-02T00:00:00Z"}]' ;;
      "POST app/installations/77/access_tokens") LAST_HTTP=403; LAST_OUT='{"message":"suspended"}'; return 1 ;;
    esac
  }
  app_gh() { echo "gh: Bad credentials (HTTP 401)" >&2; return 1; }
  printf 'HELD_SUSPEND=%s\nHELD_SUSPEND_AT=%s\n' "$(fake_token)" "$(( $(date +%s) - 3500 ))" >"$HELD"
  chmod 600 "$HELD"
  (cmd_suspend_check) >/dev/null 2>&1 || true
  assert_eq "$(state_get E1_HELD)" inconclusive
}

test_unsuspend_check_marks_e1_pending_before_using_the_held_token() {
  # Round 22, SEC-1: with a held token to read again, E1_HELD is "pending" before it is used; if that
  # can't be written nothing is used, and an earlier "ok" can't survive a run that read the token.
  held_stubs
  app_session() { :; }
  state_set E1 "refused HTTP-403"
  state_set E1_HELD ok
  printf 'HELD_SUSPEND=%s\nHELD_SUSPEND_AT=%s\n' "$(fake_token)" "$(( $(date +%s) - 3500 ))" >"$HELD"
  chmod 600 "$HELD"
  app_gh() { echo "gh: Bad credentials (HTTP 401)" >&2; return 1; }
  local rc=0
  (cmd_unsuspend_check) >/dev/null 2>&1 || rc=$?
  assert_exit 1 "$rc" "a near-expiry reading"
  assert_eq "$(state_get E1_AFTER)" inconclusive
  assert_eq "$(state_get E1_HELD)" ok "the suspension's own reading was overwritten"
  rc=0
  (cmd_unsuspend_check) >/dev/null 2>&1 || rc=$?
  assert_exit 1 "$rc" "the retry, with the held token gone"
  # A state file that can't be written: the held token is not used.
  printf 'HELD_SUSPEND=%s\nHELD_SUSPEND_AT=%s\n' "$(fake_token)" "$(date +%s)" >"$HELD"
  state_set() { return 1; }
  rc=0
  (cmd_unsuspend_check) >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "an unwritable state file"
  assert_contains "$(cat "$HELD")" "HELD_SUSPEND=" "the held token was used without its pending mark"
}

test_unsuspending_never_overwrites_the_suspensions_reading() {
  # Round 23, C2: a token that works after unsuspending says nothing about what the suspension did:
  # an inconclusive suspension reading still means doing E1 again.
  held_stubs
  app_session() { :; }
  state_set E1 "refused HTTP-403"
  state_set E1_HELD inconclusive
  state_set E1_AFTER none
  printf 'HELD_SUSPEND=%s\nHELD_SUSPEND_AT=%s\n' "$(fake_token)" "$(date +%s)" >"$HELD"
  chmod 600 "$HELD"
  app_gh() { echo "$REPO"; }
  revoke_token() { TOKEN=""; return 0; }
  local rc=0 out
  out="$(cmd_unsuspend_check 2>&1)" || rc=$?
  assert_exit 1 "$rc" "an inconclusive suspension reading, then a working token"
  assert_eq "$(state_get E1_HELD)" inconclusive
  assert_eq "$(state_get E1_AFTER)" ok
  assert_contains "$out" "E1 again"
}

test_cleanup_fails_when_a_started_run_never_shows() {
  # Round 23, C1/SEC-1: a commit env-tests made whose run never appears within the minute is not
  # "nothing to cancel": it may appear later and wait for approval, so the clean-up fails.
  load
  sleep() { :; }
  S2_SHAS="$(printf 'b%.0s' $(seq 1 40))"
  owner_gh() { return 0; }
  local rc=0 out
  out="$(cancel_waiting_runs)" || rc=$?
  assert_exit 1 "$rc" "a run that never registered"
  assert_contains "$out" "never appeared"
  owner_gh() { return 1; }
  rc=0; out="$(cancel_waiting_runs)" || rc=$?
  assert_exit 1 "$rc" "runs that can't be read"
}

test_a_failed_revocation_is_reported_and_retried_on_exit() {
  # Round 26, SEC-1: a rejected (overprivileged) token whose revocation fails is not reported as
  # revoked, and stays on the list the exit clean-up revokes.
  local out
  out="$(app_stubs
    INSTALLATION_ID=77
    app_gh() {
      echo "app_gh ${TOKEN:0:12} $*" >>"$T_TMP/app-gh.log"
      [[ "$TOKEN" == ghs_secondQQ* ]] && return 1
      return 0
    }
    mint_token >/dev/null
    token_fixture | jq -c '.token = "ghs_second'"$(printf 'Q%.0s' $(seq 1 30))"'" | .permissions.administration = "write"' >"$T_TMP/token.json"
    mint_token 2>&1)" || true
  assert_not_contains "$out" "it was revoked" "a failed revocation reported as done"
  assert_contains "$out" "until it expires"
  # Round 72: the exit clean-up tries again, then once more as its last try, and never claims it.
  (($(grep -c 'app_gh ghs_secondQQ api -X DELETE installation/token' "$T_TMP/app-gh.log") >= 2)) || _t_fail "the exit clean-up did not retry it"
  assert_contains "$out" "TOKEN token2 NOT confirmed revoked"
}

test_key_check_installs_the_new_key_at_the_configured_path() {
  # Round 26, C1: the replacement key goes where FRG26_APP_KEY points, not always to app.pem.
  held_stubs
  mv "$T_TMP/app.pem" "$T_TMP/custom.pem"
  APP_KEY="$T_TMP/custom.pem"
  openssl genrsa -out "$T_TMP/app-new.pem" 2048 2>/dev/null
  chmod 600 "$T_TMP/app-new.pem"
  local want old_key="$APP_KEY"
  want="$(shasum -a 256 <"$T_TMP/app-new.pem")"
  jwt_call() {
    if [[ "$APP_KEY_SIGNED" == "$old_key" && "$(shasum -a 256 <"$old_key")" != "$want" ]]; then LAST_HTTP=401; LAST_OUT='{"message":"bad"}'; return 1; fi
    case "$1 $2" in
      "POST app/installations/77/access_tokens") LAST_HTTP=201; LAST_OUT="$(token_fixture)" ;;
      *) LAST_HTTP=200; LAST_OUT='{"id":123456}' ;;
    esac
  }
  make_jwt() { APP_KEY_SIGNED="$APP_KEY"; JWT=jwt.stand-in.value; }
  need_app_identity() { INSTALLATION_ID=77; }
  printf 'HELD_KEYOLD=%s\nHELD_KEYOLD_AT=%s\n' "$(fake_token)" "$(date +%s)" >"$HELD"
  chmod 600 "$HELD"
  app_gh() { echo "gh: Bad credentials (HTTP 401)" >&2; return 1; }
  local rc=0
  (cmd_key_check) >/dev/null 2>&1 || rc=$?
  assert_exit 0 "$rc"
  assert_eq "$(shasum -a 256 <"$T_TMP/custom.pem")" "$want" "the configured key path holds the new key"
  [[ ! -e "$T_TMP/app.pem" && ! -e "$T_TMP/app-new.pem" ]] || _t_fail "the new key went somewhere else"
}

test_a_token_issued_while_suspended_is_retried_on_exit() {
  # Round 27, SEC-1: a token the suspended installation issues anyway is on the exit clean-up's list
  # before its revocation, so a failed revocation is tried again on exit.
  local out
  out="$(held_stubs
    make_jwt() { JWT=jwt.stand-in.value; }
    jwt_call() {
      case "$1 $2" in
        ("GET app/installations"*) LAST_HTTP=200; LAST_OUT='[{"id":77,"account":{"login":"Thebigtuna88"},"suspended_at":"2026-11-02T00:00:00Z"}]' ;;
        ("POST app/installations/77/access_tokens") LAST_HTTP=201; LAST_OUT="$(token_fixture)" ;;
      esac
    }
    printf 'HELD_SUSPEND=%s\nHELD_SUSPEND_AT=%s\n' "ghs_heldtoken$(printf 'H%.0s' $(seq 1 30))" "$(date +%s)" >"$HELD"
    chmod 600 "$HELD"
    app_gh() {
      echo "app_gh ${TOKEN:0:12} $*" >>"$T_TMP/app-gh.log"
      [[ "$*" == *DELETE* ]] && return 1
      echo "gh: Bad credentials (HTTP 401)" >&2
      return 1
    }
    trap cleanup EXIT
    cmd_suspend_check 2>&1)" || true
  assert_contains "$out" "a new token while suspended: allowed"
  assert_eq "$(grep -c "app_gh $(fake_token | cut -c1-12) api -X DELETE installation/token" "$T_TMP/app-gh.log")" 2 "the issued token was not retried on exit"
}

# Round 33, C1: the other two token requests revoke whatever GitHub issued, not only ghs_ tokens.
test_suspend_check_revokes_an_issued_token_of_any_form() {
  local out
  out="$(held_stubs
    make_jwt() { JWT=jwt.stand-in.value; }
    jwt_call() {
      case "$1 $2" in
        ("GET app/installations"*) LAST_HTTP=200; LAST_OUT='[{"id":77,"account":{"login":"Thebigtuna88"},"suspended_at":"2026-11-02T00:00:00Z"}]' ;;
        ("POST app/installations/77/access_tokens") LAST_HTTP=201; LAST_OUT="$(token_fixture | jq -c --arg t "ghx_$(printf 'Q%.0s' $(seq 1 40))" '.token = $t')" ;;
      esac
    }
    printf 'HELD_SUSPEND=%s\nHELD_SUSPEND_AT=%s\n' "ghs_heldtoken$(printf 'H%.0s' $(seq 1 30))" "$(date +%s)" >"$HELD"
    chmod 600 "$HELD"
    app_gh() {
      echo "app_gh ${TOKEN:0:8} $*" >>"$T_TMP/app-gh.log"
      [[ "$*" == *DELETE* ]] && return 1
      echo "gh: Bad credentials (HTTP 401)" >&2
      return 1
    }
    trap cleanup EXIT
    cmd_suspend_check 2>&1)" || true
  assert_contains "$out" "a new token while suspended: allowed"
  assert_eq "$(grep -c "^app_gh ghx_QQQQ api -X DELETE installation/token$" "$T_TMP/app-gh.log")" 2 "the issued ghx_ token revoked, and retried on exit"
  assert_not_contains "$out" "ghx_QQQQ" "the token printed"
}

test_key_check_revokes_an_issued_token_of_any_form() {
  local out
  out="$(held_stubs
    openssl genrsa -out "$T_TMP/app-new.pem" 2048 2>/dev/null
    chmod 600 "$T_TMP/app-new.pem"
    local old_key="$APP_KEY"
    # Only the request signed with the deleted key gets the odd token; the control (new key) gets a normal one,
    # which mint revokes on its own.
    jwt_call() {
      case "$1 $2" in
        ("POST app/installations/77/access_tokens")
          LAST_HTTP=201
          if [[ "$APP_KEY_SIGNED" == "$old_key" ]]; then LAST_OUT="$(token_fixture | jq -c --arg t "ghx_$(printf 'Q%.0s' $(seq 1 40))" '.token = $t')"
          else LAST_OUT="$(token_fixture)"; fi ;;
        (*) LAST_HTTP=200; LAST_OUT='{"id":123456}' ;;
      esac
    }
    make_jwt() { APP_KEY_SIGNED="$APP_KEY"; JWT=jwt.stand-in.value; }
    need_app_identity() { INSTALLATION_ID=77; }
    printf 'HELD_KEYOLD=%s\nHELD_KEYOLD_AT=%s\n' "$(fake_token)" "$(date +%s)" >"$HELD"
    chmod 600 "$HELD"
    app_gh() {
      echo "app_gh ${TOKEN:0:8} $*" >>"$T_TMP/app-gh.log"
      [[ "$*" == *DELETE* ]] && return 1
      echo "gh: Bad credentials (HTTP 401)" >&2
      return 1
    }
    trap cleanup EXIT
    cmd_key_check 2>&1)" || true
  assert_contains "$out" "RESULT A9 permissions FAIL attempt=allowed"
  assert_contains "$(cat "$T_TMP/app-gh.log")" "app_gh ghx_QQQQ api -X DELETE installation/token" "the old key's ghx_ token revoked"
  assert_not_contains "$out" "ghx_QQQQ" "the token printed"
}

# Round 35, C1 / SEC-1: a control mints in a subshell whose output is hidden; a token it could not
# revoke is still reported, and the control result is unchanged.
test_a_controls_token_that_cannot_be_revoked_is_reported() {
  load
  local tok rc out
  tok="ghs_control$(printf 'C%.0s' $(seq 1 30))"
  # Registered as request_token does, named after its control (round 109: a record names only its
  # control's own tokens), with its expiry (round 74).
  mint_ok() {
    TOKEN="$tok" OUTSTANDING="$OUTSTANDING $tok" ISSUED="$ISSUED $CONTROL_ID-token=$tok"
    ISSUED_META="$CONTROL_ID-token {\"expires_at\":\"$(date -u -v+50M +%Y-%m-%dT%H:%M:%SZ)\"}
"
  }
  mint_bad() { mint_ok; die "refused"; }
  app_gh() { echo "${TOKEN:0:11} $*" >>"$T_TMP/app-gh.log"; return 1; }
  : >"$T_TMP/app-gh.log"
  rc=0; out="$(control_token mint_ok 2>&1)" || rc=$?
  assert_exit 0 "$rc" "a control that minted, revocation failed"
  assert_contains "$out" "a control's token could not be revoked"
  assert_not_contains "$out" "$tok" "the token printed"
  assert_contains "$(cat "$T_TMP/app-gh.log")" "ghs_control api -X DELETE installation/token"
  rc=0; out="$(control_token mint_bad 2>&1)" || rc=$?
  assert_exit 1 "$rc" "a control that failed, revocation failed"
  assert_contains "$out" "a control's token could not be revoked"
  # Controls: revocation works, and a read with the token then gets HTTP 401 (round 73: only that
  # confirms it), so nothing is reported either way.
  app_gh() {
    echo "${TOKEN:0:11} $*" >>"$T_TMP/app-gh.log"
    if [[ "$*" == "api -X DELETE installation/token" ]]; then echo "$TOKEN" >>"$T_TMP/revoked-ctl"; fi
    if [[ "$*" == "api repos/$REPO --jq .full_name" ]] && grep -qxF "$TOKEN" "$T_TMP/revoked-ctl" 2>/dev/null; then
      echo "gh: Bad credentials (HTTP 401)" >&2
      return 1
    fi
  }
  rc=0; out="$(control_token mint_ok 2>&1)" || rc=$?
  assert_exit 0 "$rc" "a control that minted"
  assert_eq "$out" "" "output from a control that settled"
  rc=0; out="$(control_token mint_bad 2>&1)" || rc=$?
  assert_exit 1 "$rc" "a control that failed"
  assert_eq "$out" "" "output from a failed control that settled"
  # Both controls (A9 and E1) use it; no control hides its own clean-up any more.
  assert_eq "$(grep -c 'if control_token ' "$GT")" 2 "controls using control_token"
  assert_eq "$(grep -c 'trap revoke_outstanding EXIT' "$GT")" 0 "a control trap that hides its clean-up"
}

test_s2c_changes_nothing_after_an_attempt_that_got_through() {
  # Round 28, C1: the stop rule. After an S2c attempt that wasn't refused, nothing more is written:
  # the disposable dummy secret is left for the owner, and the evidence says so.
  s2_stubs
  WORK="$T_TMP/work"
  owner_uid() { echo 42; }
  printf 'app_gh api -X PUT|0|{}\n' >"$T_TMP/answers"
  env_summary() { want_env; }
  local out
  out="$(t_S2c)"
  assert_contains "$out" "RESULT S2c permissions FAIL attempt=allowed"
  assert_not_contains "$(cat "$T_TMP/calls")" "owner_gh api -X DELETE" "an owner write after the failed attempt"
  assert_contains "$out" "FRG26_DISPOSABLE is left"
}

test_controls_stop_at_their_first_failure() {
  # Round 29, C1/SEC-1: the stop rule holds for controls too: after a control fails, no later control
  # (a write among them) runs.
  s2_stubs
  WORK="$T_TMP/work"
  owner_uid() { echo 42; }
  s2c_replies "owner_gh api -X PUT repos/$REPO/environments|1|gh: HTTP 502"
  env_summary() { want_env; }
  local out
  out="$(t_S2c)"
  assert_contains "$out" "RESULT S2c permissions FAIL attempt=refused control=failed"
  assert_not_contains "$(cat "$T_TMP/calls")" "owner_gh api -X DELETE" "the disposable secret was deleted after a failed control"
  # A2's controls follow only a push shown refused, which can't be yet (round 112): see
  # test_a2_tries_code_changes_on_a_repo_the_app_is_not_installed_on.
  end_stand_in_run
}

test_delete_check_needs_githubs_own_answer_that_the_app_is_gone() {
  # Round 13, C5/SEC-7: an outage or a server error is not proof that the app was deleted.
  held_stubs
  make_jwt() { JWT=x; }
  printf 'HELD_DELETE=%s\n' "$(fake_token)" >"$HELD"
  printf 'HELD_DELETE_AT=%s\n' "$(date +%s)" >>"$HELD"
  chmod 600 "$HELD"
  app_gh() { echo "gh: Bad credentials (HTTP 401)" >&2; return 1; }
  local rc out code
  for code in 500 502 ""; do
    jwt_call() { LAST_HTTP="$FAKE_CODE"; LAST_OUT='{"message":"oops"}'; return 1; }
    FAKE_CODE="$code"
    rc=0; out="$(cmd_delete_check 2>&1)" || rc=$?
    assert_exit 2 "$rc" "HTTP '${code:-none}'"
    assert_contains "$(cat "$HELD")" "HELD_DELETE=" "the held token was used after HTTP '${code:-none}'"
  done
  FAKE_CODE=404
  rc=0; out="$(cmd_delete_check 2>&1)" || rc=$?
  assert_exit 0 "$rc" "HTTP 404"
  assert_contains "$out" "the app's own key now gets HTTP 404"
}

test_e2_and_e3_record_what_issued_tokens_do() {
  held_stubs
  make_jwt() { JWT=x; }
  jwt_call() {
    case "$1 $2" in
      "GET app/installations"*) LAST_HTTP=200; LAST_OUT='[]' ;;
      "GET app") LAST_HTTP=404; LAST_OUT='{"message":"Integration not found"}'; return 1 ;;
    esac
  }
  printf 'HELD_UNINSTALL=%s\nHELD_DELETE=%s\n' "$(fake_token)" "$(fake_token)" >"$HELD"
  printf 'HELD_UNINSTALL_AT=%s\nHELD_DELETE_AT=%s\n' "$(date +%s)" "$(date +%s)" >>"$HELD"
  chmod 600 "$HELD"
  app_gh() { echo "gh: Bad credentials (HTTP 401)" >&2; return 1; }
  local out
  out="$(cmd_uninstall_check 2>&1)"
  assert_contains "$out" "READING E2 a token issued before the uninstall: HTTP 401"
  out="$(cmd_delete_check 2>&1)"
  assert_contains "$out" "READING E3 a token issued before the app was deleted: HTTP 401"
  assert_contains "$out" "the app's own key now gets HTTP 404"
}

# --- A2 investigation (owner-approved 2026-11-11): a2-probe ----------------------------------------

# A stand-in GitHub for a2-probe. Token n (1 whole, 2 full, 3 P1, 4 P2) is issued with exactly the
# permissions asked for, unless $T_TMP/extra-<n> holds a jq filter applied to GitHub's answer; app
# calls are logged with the token's tag (tok<n>). A revoked token gets HTTP 401 (unless
# $T_TMP/revoked-still-works), and $T_TMP/reach-tok<n> replaces what that token reaches. Other
# answers come from $T_TMP/answers: pattern|status|text, text read with printf %b, first match wins.
# The second throwaway's branches and tags live in $T_TMP/refs; $T_TMP/refs-change makes the app's
# branch attempt there add one.
probe_stubs() {
  load
  APP_ID=123456
  INSTALLATION_ID=77
  APP_SLUG=frg26-test-app
  APP_BOT="frg26-test-app[bot]"
  WORK="$T_TMP/work"
  # A fresh folder for each run, as make_work makes one: the clean-up no longer deletes it (owner,
  # round 96), so a test's earlier run would otherwise leave its records there.
  rm -rf "$WORK"
  mkdir -m 700 "$WORK"
  # A test may set up several runs: no stand-in state carries over from the one before.
  rm -f "$T_TMP/revoked" "$T_TMP/revoked-still-works" "$T_TMP/refs-change" "$T_TMP"/delete-fails-* "$T_TMP"/delete-lies-* \
    "$T_TMP"/extra-* "$T_TMP"/fail-* "$T_TMP"/reach-* "$T_TMP"/request-*.json
  : >"$T_TMP/calls"
  : >"$T_TMP/answers"
  echo 0 >"$T_TMP/minted"
  printf 'refs/heads/frg26-a2 %s\nrefs/heads/main %s\n' "$(printf 'a%.0s' $(seq 1 40))" "$(printf 'b%.0s' $(seq 1 40))" >"$T_TMP/refs"
  need_owner() { :; }
  assert_throwaway() { :; }
  assert_second() { :; }
  load_app() { :; }
  need_app_identity() { :; }
  make_jwt() { JWT=jwt-stand-in; }
  jwt_call() {
    local n p
    n=$(($(cat "$T_TMP/minted") + 1))
    echo "$n" >"$T_TMP/minted"
    printf '%s\n' "$3" >"$T_TMP/request-$n.json" # round 109: the body itself, no file
    if [[ -f "$T_TMP/fail-$n" ]]; then LAST_HTTP=502; LAST_OUT='{"message":"Server Error"}'; return 1; fi
    p="$(printf '%s' "$3" | jq -c '.permissions // empty')"
    [[ -n "$p" ]] || p="$WANT_PERMS"
    LAST_HTTP=201
    # GitHub issues each token for an hour: here it expires 59 minutes from now ($T_TMP/expires-<n>).
    command date -u -v+59M +%Y-%m-%dT%H:%M:%SZ >"$T_TMP/expires-$n"
    LAST_OUT="$(jq -n -c --arg t "$(printf 'gh%s_tok%s' s "$n")$(printf 'Q%.0s' $(seq 1 30))" --argjson p "$p" --arg r "$REPO" \
      --arg e "$(cat "$T_TMP/expires-$n")" \
      '{token: $t, expires_at: $e, repository_selection: "selected", permissions: $p, repositories: [{full_name: $r, id: 1}]}')"
    if [[ -f "$T_TMP/extra-$n" ]]; then LAST_OUT="$(jq -c "$(cat "$T_TMP/extra-$n")" <<<"$LAST_OUT")"; fi
  }
  probe_answer() { # <logged call>
    local pat rc text
    while IFS='|' read -r pat rc text; do
      [[ -n "$pat" ]] || continue
      if [[ "$1" == *$pat* ]]; then
        [[ -n "$text" ]] && printf '%b\n' "$text"
        return "$rc"
      fi
    done <"$T_TMP/answers"
    return 0
  }
  app_gh() {
    local tag="${TOKEN:4:4}"
    echo "app_gh $tag $*" >>"$T_TMP/calls"
    # GitHub's own state: only a DELETE that succeeded revokes (round 48, C1), never the script's
    # lists. $T_TMP/delete-fails-<tag> holds how many DELETEs of that token fail first.
    if grep -qx "$tag" "$T_TMP/revoked" 2>/dev/null && [[ ! -f "$T_TMP/revoked-still-works" ]]; then
      echo "gh: Bad credentials (HTTP 401)" >&2
      return 1
    fi
    if [[ -f "$T_TMP/refs-change" && "$*" == *"repos/$REPO2/git/refs"* ]]; then echo "refs/heads/frg26-probe-r1 $(printf 'c%.0s' $(seq 1 40))" >>"$T_TMP/refs"; fi
    case "$*" in
      "api -X DELETE installation/token")
        local left
        left="$(cat "$T_TMP/delete-fails-$tag" 2>/dev/null || echo 0)"
        if [[ "$left" -gt 0 ]]; then
          echo $((left - 1)) >"$T_TMP/delete-fails-$tag"
          echo "gh: Server Error (HTTP 502)" >&2
          return 1
        fi
        # $T_TMP/delete-lies-<tag>: GitHub answers the DELETE as done, but the token keeps working.
        [[ -f "$T_TMP/delete-lies-$tag" ]] || echo "$tag" >>"$T_TMP/revoked"
        return 0
        ;;
      "api installation/repositories"*) cat "$T_TMP/reach-$tag" 2>/dev/null || echo "$REPO"; return 0 ;;
      "api rate_limit") rate_fixture 0; return 0 ;;
    esac
    probe_answer "app_gh $tag $*"
  }
  owner_gh() {
    echo "owner_gh $*" >>"$T_TMP/calls"
    case "$*" in
      *"repos/$REPO2/git/matching-refs/heads"*) grep '^refs/heads/' "$T_TMP/refs"; return 0 ;;
      *"repos/$REPO2/git/matching-refs/tags"*) grep '^refs/tags/' "$T_TMP/refs"; return 0 ;;
    esac
    probe_answer "owner_gh $*"
  }
  date() { if [[ "${1:-}" == -u && "${2:-}" == +%Y%m%dT%H%M%SZ ]]; then echo r1; else command date "$@"; fi; }
  cat >"$T_TMP/answers" <<EOF
owner_gh api repos/$REPO2/branches/main --jq .commit.sha|0|$(printf 'b%.0s' $(seq 1 40))
owner_gh api repos/$REPO/branches/dev --jq .commit.sha|0|$(printf 'd%.0s' $(seq 1 40))
owner_gh api repos/$REPO2/compare/main...frg26-a2 --jq .ahead_by|0|1
owner_gh api repos/$REPO2/issues|0|kept-object
app_gh tok2 api -i -X PUT repos/$REPO2/contents/|1|$(probe_reply 'HTTP/2.0 403 Forbidden' contents=write '{"message":"Resource not accessible by integration"}')
app_gh tok2 api -i -X POST repos/$REPO2/git/refs|1|$(probe_reply 'HTTP/2.0 403 Forbidden' contents=write '{"message":"Resource not accessible by integration"}')
app_gh tok2 api -X POST repos/$REPO/git/refs|0|{}
app_gh tok2 api -X PUT repos/$REPO/contents/|0|{}
app_gh tok2 api -i -X POST repos/$REPO2/issues/1/comments|0|$(probe_reply 'HTTP/2.0 201 Created' - '{"id":901}')
app_gh tok2 api -i -X POST repos/$REPO2/pulls|0|$(probe_reply 'HTTP/2.0 201 Created' - '{"number":3}')
app_gh tok3 api -i -X POST repos/$REPO2/issues|1|$(probe_reply 'HTTP/2.0 403 Forbidden' issues=write '{"message":"Resource not accessible by integration"}')
app_gh tok4 api -i -X POST repos/$REPO2/issues|0|$(probe_reply 'HTTP/2.0 201 Created' - '{"number":4}')
EOF
}

# A complete gh api -i answer for probe_answer (escaped for its %b): <permission> named in
# x-accepted-github-permissions (- for none), GitHub's Content-Length right (round 112).
probe_reply() { # <status line> <permission or -> <body>
  local LC_ALL=C p=""
  [[ "$2" == - ]] || p="X-Accepted-Github-Permissions: $2\\r\\n"
  printf '%s\\r\\nContent-Length: %s\\r\\n%sX-Github-Request-Id: C0DE:1A2B:3C4D5E:6F7A8B:9C0D1E2F\\r\\nX-Ratelimit-Remaining: 4979\\r\\nX-Ratelimit-Resource: core\\r\\n\\r\\n%s' \
    "$1" "${#3}" "$p" "$3"
}

run_probe() { # a2-probe as the owner's run has it: the script's exit clean-up runs (a subshell has no trap)
  (
    trap cleanup EXIT
    cmd_a2_probe
  ) 2>&1
}

probe_answer_first() { # <line> — put an answer ahead of the defaults (the first match wins)
  printf '%s\n' "$1" | cat - "$T_TMP/answers" >"$T_TMP/answers.new"
  mv "$T_TMP/answers.new" "$T_TMP/answers"
}

test_a2_probe_runs_each_attempt_with_its_own_token_and_keeps_what_got_through() {
  probe_stubs
  local out rc=0 calls
  out="$(run_probe)" || rc=$?
  assert_exit 0 "$rc" "a probe whose code changes were refused"
  calls="$(cat "$T_TMP/calls")"
  # Four tokens, each asked for exactly what its attempts need, each limited to the throwaway.
  assert_eq "$(jq -S -c . "$T_TMP/request-1.json")" '{}' "the whole-installation token"
  assert_eq "$(jq -S -c . "$T_TMP/request-2.json")" "{\"permissions\":$WANT_PERMS,\"repositories\":[\"$REPO_NAME\"]}" "the full token"
  assert_eq "$(jq -S -c . "$T_TMP/request-3.json")" "{\"permissions\":{\"contents\":\"write\",\"metadata\":\"read\"},\"repositories\":[\"$REPO_NAME\"]}" "P1's token: no Issues"
  assert_eq "$(jq -S -c . "$T_TMP/request-4.json")" "{\"permissions\":{\"metadata\":\"read\"},\"repositories\":[\"$REPO_NAME\"]}" "P2's token: metadata only"
  assert_contains "$out" "TOKEN P1 issued: {\"expires_at\":\"$(cat "$T_TMP/expires-3")\",\"permissions\":{\"contents\":\"write\",\"metadata\":\"read\"},\"repositories\":[\"$REPO\"],\"repository_selection\":\"selected\"}"
  assert_contains "$out" "TOKEN P1 expires $(cat "$T_TMP/expires-3"), in 5" "the expiry checked and shown"
  # Round 52 (owner): the tokens are named, confirmed or not, and never shown.
  assert_contains "$out" "TOKENS 4 issued; confirmed revoked: whole full P1 P2; NOT confirmed: none"
  assert_contains "$out" "TOKEN P2 reaches (GET /installation/repositories): $REPO"
  # Each token is revoked, and a read with it afterwards gets HTTP 401.
  assert_eq "$(printf '%s\n' "$out" | grep -c 'revoked: a read with it now gets HTTP 401')" 4 "revocations confirmed"
  assert_not_contains "$out" "gh$(printf s)_tok" "a token printed"
  # 9a refused, with its controls on the throwaway; then the readings, GitHub's answers kept.
  assert_contains "$out" "RESULT P5 code changes refused"
  assert_contains "$calls" "app_gh tok2 api -X POST repos/$REPO/git/refs -f ref=refs/heads/frg26/probe/P5-r1"
  assert_contains "$out" "X-Accepted-Github-Permissions: issues=write"
  assert_contains "$out" "READING P1 an issue, with a token without Issues (contents write, metadata read): refused (HTTP 403)"
  assert_contains "$out" "READING P2 an issue, with a token with metadata read only: allowed"
  assert_contains "$out" "READING P3 a comment on issue #1: allowed"
  assert_contains "$out" "READING P4 a PR from $A2_BRANCH into main: allowed"
  # Every object an attempt made is read back by its number, and nothing is closed or deleted.
  assert_contains "$out" "KEPT comment 901: kept-object"
  assert_contains "$out" "KEPT pr 3: kept-object"
  assert_contains "$out" "KEPT issue 4: kept-object"
  assert_contains "$calls" "owner_gh api repos/$REPO2/issues/comments/901"
  assert_eq "$(printf '%s\n' "$calls" | grep '^owner_gh' | grep -c -e ' -X ' -e ' close ' || true)" 0 "an owner write"
  assert_eq "$(printf '%s\n' "$calls" | grep 'DELETE' | grep -vc 'api -X DELETE installation/token$' || true)" 0 "a delete other than a token's"
  assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "A2 PROBE: DONE: code changes refused"
  assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "readings P3=allowed P4=allowed P1=refused P2=allowed;"
}

test_a2_probe_stops_when_a_code_change_is_not_refused() {
  local name line out rc calls
  load
  for name in "a file got through|app_gh tok2 api -i -X PUT repos/$REPO2/contents/|0|$(probe_reply 'HTTP/2.0 201 Created' - '{}')|GOT THROUGH" \
    "a branch got through|app_gh tok2 api -i -X POST repos/$REPO2/git/refs|0|$(probe_reply 'HTTP/2.0 201 Created' - '{}')|GOT THROUGH" \
    "a refusal for another reason|app_gh tok2 api -i -X PUT repos/$REPO2/contents/|1|gh: Invalid request (HTTP 422)|proves nothing"; do
    IFS='|' read -r name line <<<"$name"
    probe_stubs
    probe_answer_first "${line%|*}"
    rc=0; out="$(run_probe)" || rc=$?
    assert_exit 1 "$rc" "$name"
    assert_contains "$out" "PROBE STOP: P5" "$name"
    assert_contains "$out" "${line##*|}" "$name"
    calls="$(cat "$T_TMP/calls")"
    assert_not_contains "$calls" "issues/1/comments" "a public attempt after $name"
    assert_not_contains "$calls" "app_gh tok3" "another token after $name"
    assert_contains "$out" "TOKEN full revoked: a read with it now gets HTTP 401" "$name"
    assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "A2 PROBE: STOPPED" "$name"
  done
}

# Round 49 (C1): a reading GitHub gave no answer to (an error, a rate limit) is not a reading: the
# run stops there, as the owner's, and never ends DONE.
test_a2_probe_stops_at_a_reading_with_no_answer() {
  local name line out rc calls
  load
  for name in "P3 gets a server error|app_gh tok2 api -i -X POST repos/$REPO2/issues/1/comments|1|gh: Server Error (HTTP 502)|PROBE STOP: P3|repos/$REPO2/pulls" \
    "P1 is rate limited|app_gh tok3 api -i -X POST repos/$REPO2/issues|1|gh: API rate limit exceeded (HTTP 403)|PROBE STOP: P1|app_gh tok4"; do
    IFS='|' read -r name line <<<"$name"
    probe_stubs
    probe_answer_first "$(printf '%s' "$line" | cut -d'|' -f1-3)"
    rc=0; out="$(run_probe)" || rc=$?
    assert_exit 1 "$rc" "$name"
    assert_contains "$out" "$(printf '%s' "$line" | cut -d'|' -f4)" "$name"
    calls="$(cat "$T_TMP/calls")"
    assert_not_contains "$calls" "$(printf '%s' "$line" | cut -d'|' -f5)" "an attempt after $name"
    assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "A2 PROBE: STOPPED" "$name"
    assert_not_contains "$out" "A2 PROBE: DONE" "$name"
  done
}

test_a2_probe_needs_its_code_change_controls() {
  probe_stubs
  probe_answer_first "app_gh tok2 api -X POST repos/$REPO/git/refs|1|gh: Server Error (HTTP 502)"
  local out rc=0
  out="$(run_probe)" || rc=$?
  assert_exit 1 "$rc" "a failed control"
  assert_contains "$out" "PROBE STOP: control"
  assert_not_contains "$(cat "$T_TMP/calls")" "issues/1/comments" "a public attempt after a failed control"
}

test_a2_probe_stops_when_the_second_throwaways_branches_change() {
  probe_stubs
  : >"$T_TMP/refs-change"
  local out rc=0
  out="$(run_probe)" || rc=$?
  assert_exit 1 "$rc" "a branch appeared after refused attempts"
  assert_contains "$out" "PROBE STOP: $REPO2's branches or tags changed"
  assert_contains "$out" "refs/heads/frg26-probe-r1"
  assert_not_contains "$(cat "$T_TMP/calls")" "issues/1/comments" "a public attempt after a change"
}

# Round 71 (SEC-1): P5's file goes on frg26-a2, so with that branch missing its "Branch not found"
# (HTTP 404) would pass for a refusal. Only the branch itself counts, never a look-alike branch or
# tag: the run stops before any token is asked for.
test_a2_probe_needs_the_exact_branch_not_a_look_alike() {
  local case name refs out rc a
  load
  a="$(printf 'a%.0s' $(seq 1 40))"
  for case in "a look-alike branch|refs/heads/main $a\nrefs/heads/x/refs/heads/frg26-a2 $a" \
    "a look-alike tag|refs/heads/main $a\nrefs/tags/refs/heads/frg26-a2 $a"; do
    IFS='|' read -r name refs <<<"$case"
    probe_stubs
    printf '%b\n' "$refs" >"$T_TMP/refs"
    probe_answer_first "app_gh tok2 api -i -X PUT repos/$REPO2/contents/|1|HTTP/2.0 404 Not Found\n\n{\"message\":\"Branch not found\"}\ngh: Branch not found (HTTP 404)"
    rc=0; out="$(run_probe)" || rc=$?
    assert_exit 1 "$rc" "$name"
    assert_contains "$out" "PROBE STOP: can't read $REPO2's branches and tags, or $A2_BRANCH is missing" "$name"
    assert_not_contains "$out" "RESULT P5" "$name"
    assert_eq "$(cat "$T_TMP/minted")" 0 "tokens asked for with $name"
    assert_not_contains "$(cat "$T_TMP/calls")" "app_gh" "an attempt with $name"
    assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "A2 PROBE: STOPPED" "$name"
  done
}

test_a2_probe_checks_each_tokens_scope_before_using_it() {
  probe_stubs
  printf '%s\nThebigtuna88/forge\n' "$REPO" >"$T_TMP/reach-tok3"
  local out rc=0 calls
  out="$(run_probe)" || rc=$?
  assert_exit 1 "$rc" "a token that reaches another repo"
  assert_contains "$out" "PROBE STOP: token P1 reaches more than $REPO"
  assert_contains "$out" "TOKEN P1 revoked: a read with it now gets HTTP 401"
  calls="$(cat "$T_TMP/calls")"
  assert_not_contains "$calls" "app_gh tok3 api -i" "an attempt with that token"
  assert_contains "$out" "KEPT comment 901" "objects made before the stop are read back"
  # A token GitHub issued with more permissions than asked is revoked, never used.
  probe_stubs
  echo '.permissions.issues = "write"' >"$T_TMP/extra-3"
  rc=0; out="$(run_probe)" || rc=$?
  assert_exit 2 "$rc" "P1's token with Issues"
  assert_contains "$out" "carries more than was asked"
  calls="$(cat "$T_TMP/calls")"
  assert_contains "$calls" "app_gh tok3 api -X DELETE installation/token"
  assert_not_contains "$calls" "app_gh tok3 api -i" "an attempt with that token"
  # Round 47 (C1, SEC-1): that token's revocation is checked too, on the way out after the error.
  assert_contains "$calls" "app_gh tok3 api repos/$REPO --jq .full_name" "the rejected token's revocation was not checked"
  assert_contains "$out" "TOKEN P1 revoked: a read with it now gets HTTP 401"
  assert_contains "$out" "KEPT comment 901" "objects made before the error are read back"
  assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "A2 PROBE: STOPPED by an error"
}

# Round 47 (C2): a token request that fails after objects were made still reads them back.
test_a2_probe_reads_back_what_it_made_when_a_later_token_request_fails() {
  probe_stubs
  : >"$T_TMP/fail-3"
  local out rc=0
  out="$(run_probe)" || rc=$?
  assert_exit 2 "$rc" "P1's token request refused"
  # Round 56 (C1, SEC-1): a 502 is no clear refusal: GitHub may have issued a token never received.
  assert_contains "$out" "the token request got no usable answer (HTTP 502"
  assert_contains "$out" "TOKEN P1 possibly issued, never received"
  assert_contains "$out" "KEPT comment 901"
  assert_contains "$out" "KEPT pr 3"
  assert_eq "$(printf '%s\n' "$out" | grep -c 'revoked: a read with it now gets HTTP 401')" 2 "the two tokens issued, both checked"
  assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "A2 PROBE: STOPPED by an error"
  assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "possibly issued, never received: P1"
}

# Round 56 (C1, SEC-1): how mint reads a token request that didn't end cleanly. The real jwt_call,
# with a stand-in curl.
mint_with_curl() { # <body> <curl's stderr> <http status> <curl's status>
  load
  APP_ID=123456
  INSTALLATION_ID=77
  WORK="$T_TMP/work"
  mkdir -p "$WORK"
  : >"$WORK/jwt.hdr"
  : >"$T_TMP/app-gh.log"
  CURL_BODY="$1" CURL_ERR="$2" CURL_HTTP="$3" CURL_RC="$4"
  curl() { printf '%s' "$CURL_BODY"; [[ -z "$CURL_ERR" ]] || echo "$CURL_ERR" >&2; printf '\nHTTP %s' "$CURL_HTTP"; return "$CURL_RC"; }
  app_gh() { echo "${TOKEN:0:8} $*" >>"$T_TMP/app-gh.log"; }
}

test_mint_takes_a_token_from_an_answer_whose_transfer_failed() {
  local tok out rc=0
  tok="$(new_token)"
  mint_with_curl "{\"token\":\"$tok\",\"expires_at\":\"2026-11-12T12:00:00Z\",\"permissions\":{\"metadata\":\"read\"}}" "curl: (28) Operation timed out" 201 28
  out="$(MINT_LABEL=P2; trap revoke_outstanding EXIT; mint '{"repositories":["forge-frg26-throwaway"],"permissions":{"metadata":"read"}}' narrowed '{"metadata":"read"}' 2>&1)" || rc=$?
  assert_exit 2 "$rc" "a transfer that failed after the token arrived"
  assert_contains "$out" "did not end cleanly"
  assert_contains "$(cat "$T_TMP/app-gh.log")" "${tok:0:8} api -X DELETE installation/token" "the token that arrived was not revoked"
  assert_not_contains "$out" "$tok" "the token printed"
}

test_mint_reports_a_token_request_with_no_complete_answer() {
  local out rc=0
  mint_with_curl "" "curl: (28) Operation timed out" 000 28
  local before after
  before="$(date +%s)"
  out="$( (MINT_LABEL=P1; trap 'printf "unreceived=[%s]\n" "$UNRECEIVED"' EXIT; mint '{"repositories":["forge-frg26-throwaway"],"permissions":{"metadata":"read"}}' narrowed '{"metadata":"read"}') 2>&1)" || rc=$?
  after="$(date +%s)"
  assert_exit 2 "$rc" "no answer"
  assert_contains "$out" "GitHub may have issued one this run never received"
  # Owner, 2026-11-23 (was round 56's latest expiry): the record keeps when the request was sent, by
  # this Mac's clock, and no expiry is stated: GitHub may have issued it at a time this run can't know.
  local line sent
  line="$(printf '%s\n' "$out" | sed -n 's/^unreceived=\[P1 \([^ ]*\) .*/\1/p')"
  sent="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$line" +%s 2>/dev/null)" || sent=""
  [[ "$sent" =~ ^[0-9]+$ && $sent -ge $((before - 1)) && $sent -le $((after + 1)) ]] \
    || _t_fail "the recorded time '$line' is not when the request was sent"
  assert_contains "$out" "the request was sent at $line by this Mac's clock" "the request's time in mint's message"
  assert_not_contains "$out" "at the latest" "a deadline in mint's message"
  assert_contains "$out" 'unreceived=[P1 '"$line"' {"repositories":["forge-frg26-throwaway"],"permissions":{"metadata":"read"}}'
  # Never asked again: one token request, in request_token, which mint calls once (round 60).
  assert_eq "$(grep -c 'access_tokens' <<<"$(declare -f request_token)")" 1 "request_token asks for a token more than once"
  assert_eq "$(grep -c 'request_token' <<<"$(declare -f mint)")" 1 "mint asks for a token more than once"
  # A clear refusal (4xx) issued nothing: not reported as possibly issued.
  mint_with_curl '{"message":"Validation Failed"}' "" 422 0
  rc=0
  out="$(MINT_LABEL=P1; mint '{"permissions":{"metadata":"read"}}' narrowed '{"metadata":"read"}' 2>&1)" || rc=$?
  assert_exit 2 "$rc" "a refusal"
  assert_contains "$out" "GitHub refused the token request (HTTP 422)"
  assert_not_contains "$out" "may have issued"
}

# Round 58 (C1, SEC-1): a signal while a received token is being registered waits until the
# registration is whole, then ends the run through the clean-up.
test_a_signal_during_token_registration_waits_until_it_is_whole() {
  local sig want out rc
  for sig in HUP:129 INT:130 TERM:143; do
    want="${sig#*:}" sig="${sig%%:*}"
    rc=0
    out="$(/bin/bash -p -c 'sig="$2"; source "$1"; cleanup() { echo "cleanup with $REGISTERED"; }; REGISTERED=none; defer_signals; kill -s "$sig" $$; REGISTERED=half; REGISTERED=whole; resume_signals; echo after' _ "$GT" "$sig" 2>&1)" || rc=$?
    assert_exit "$want" "$rc" "SIG$sig"
    assert_contains "$out" "cleanup with whole" "SIG$sig"
    assert_not_contains "$out" "after" "SIG$sig"
  done
  # Without a signal, nothing changes.
  rc=0
  out="$(/bin/bash -p -c 'source "$1"; cleanup() { :; }; defer_signals; resume_signals; echo after' _ "$GT" 2>&1)" || rc=$?
  assert_exit 0 "$rc" "no signal"
  assert_contains "$out" "after"
  # In request_token (the one token request, round 60), everything from before the request is sent
  # to the token's registration is inside (round 59: the answer is in hand once curl returns).
  local body
  body="$(source "$GT"; declare -f request_token)"
  body="$(printf '%s\n' "$body" | awk '/defer_signals/ { on = 1 } on { print } /resume_signals/ { exit }')"
  assert_contains "$body" "jwt_call POST" "the token request outside the deferred section"
  # shellcheck disable=SC2016 # the literal source text is what's searched for
  assert_contains "$body" 'meta="$(printf' "the answer's summary outside the deferred section"
  # shellcheck disable=SC2016 # the literal source text is what's searched for
  assert_contains "$body" 'ISSUED="$ISSUED' "ISSUED outside the deferred section"
  # shellcheck disable=SC2016 # as above
  assert_contains "$body" 'ISSUED_META="$ISSUED_META' "ISSUED_META outside the deferred section"
  # shellcheck disable=SC2016 # as above
  assert_contains "$body" 'OUTSTANDING="$OUTSTANDING' "OUTSTANDING outside the deferred section"
  assert_contains "$body" 'PENDING_MINT=""' "the pending record cleared outside the deferred section"
}

# Round 59 (C1, SEC-1): a signal while the request is out, whose answer then holds a token: the
# token is registered, revoked and checked, not reported as never received.
test_a_signal_while_a_token_request_is_out_still_revokes_the_token_it_brings() {
  local out rc=0
  out="$(/bin/bash -p -c '
    source "$1"
    D="$2"; WORK="$D/work"; mkdir -p "$WORK"; APP_ID=123456; INSTALLATION_ID=77; : >"$WORK/jwt.hdr"
    tok="$(printf "gh%s_" s)$(printf "Q%.0s" $(seq 1 40))"
    curl() { /bin/sleep 2; printf "{\"token\":\"%s\",\"expires_at\":\"2026-11-12T23:00:00Z\",\"repository_selection\":\"selected\",\"permissions\":{\"metadata\":\"read\"},\"repositories\":[{\"full_name\":\"Thebigtuna88/forge-frg26-throwaway\"}]}\nHTTP 201" "$tok"; }
    app_gh() {
      echo "app_gh $*" >>"$D/calls"
      case "$*" in
        "api -X DELETE installation/token") : >"$D/revoked"; return 0 ;;
        *) if [ -f "$D/revoked" ]; then echo "gh: Bad credentials (HTTP 401)" >&2; return 1; fi ;;
      esac
    }
    PROBE_ACTIVE=1 MINT_LABEL=P1
    ( /bin/sleep 1; kill -TERM $$ ) &
    mint "{\"repositories\":[\"forge-frg26-throwaway\"],\"permissions\":{\"metadata\":\"read\"}}" narrowed "{\"metadata\":\"read\"}"
    echo continued' _ "$GT" "$T_TMP" 2>&1)" || rc=$?
  assert_exit 143 "$rc"
  assert_not_contains "$out" "continued"
  assert_contains "$(cat "$T_TMP/calls")" "api -X DELETE installation/token" "the token brought was never revoked"
  assert_contains "$out" "TOKEN P1 revoked: a read with it now gets HTTP 401"
  assert_not_contains "$out" "possibly issued"
  assert_not_contains "$out" "$(printf "gh%s_" s)QQQQ" "a token printed"
}

# Round 60 (C1): every command asks for a token through request_token, with all its safeguards
# (key-check and suspend-check had their own request).
test_every_token_request_goes_through_request_token() {
  local n
  n="$(grep -c 'access_tokens' "$GT")"
  assert_eq "$n" 1 "token requests in the script"
  assert_contains "$(source "$GT"; declare -f request_token)" "access_tokens" "the one request is not in request_token"
  assert_contains "$(source "$GT"; declare -f cmd_key_check)" "request_token" "key-check"
  assert_contains "$(source "$GT"; declare -f cmd_suspend_check)" "request_token" "suspend-check"
  assert_contains "$(source "$GT"; declare -f mint)" "request_token" "mint"
}

# Round 60 (C1): suspend-check, given an answer whose transfer failed after a whole token, revokes it.
test_suspend_check_revokes_a_token_from_a_broken_answer() {
  held_stubs
  local tok
  tok="$(new_token)"
  make_jwt() { JWT=x; }
  jwt_call() {
    case "$1 $2" in
      "GET app/installations"*) LAST_HTTP=200; LAST_OUT='[{"id":77,"account":{"login":"Thebigtuna88"},"suspended_at":"2026-11-12T00:00:00Z"}]' ;;
      "POST app/installations/77/access_tokens") LAST_HTTP=201; LAST_OUT="{\"token\":\"$tok\",\"expires_at\":"; JWT_ERR="curl: (28) Operation timed out"; return 1 ;;
    esac
  }
  app_gh() { echo "${TOKEN:0:8} $*" >>"$T_TMP/app-gh.log"; echo "gh: Bad credentials (HTTP 401)" >&2; return 1; }
  : >"$T_TMP/app-gh.log"
  local out
  out="$(cmd_suspend_check 2>&1)" || true
  assert_contains "$(cat "$T_TMP/app-gh.log")" "${tok:0:8} api -X DELETE installation/token" "the token in the broken answer was not revoked"
  assert_not_contains "$out" "$tok" "the token printed"
}

# Round 61 (C1): key-check and suspend-check stop on an answer that may mean a token never received,
# with the whole report (requested repositories, permissions, the latest expiry), and go no further.
test_key_check_and_suspend_check_stop_on_a_token_possibly_issued() {
  local cmd out rc
  for cmd in cmd_suspend_check cmd_key_check; do
    held_stubs
    make_jwt() { JWT=jwt-stand-in-r61; }
    jwt_with() { :; }
    load_app() { :; }
    need_app_identity() { INSTALLATION_ID=77; }
    : >"$T_TMP/app-new.pem"
    chmod 600 "$T_TMP/app-new.pem"
    APP_KEY="$T_TMP/app.pem"
    jwt_call() {
      case "$1 $2" in
        "GET app/installations"*) LAST_HTTP=200; LAST_OUT='[{"id":77,"account":{"login":"Thebigtuna88"},"suspended_at":"2026-11-12T00:00:00Z"}]' ;;
        "POST app/installations/77/access_tokens") LAST_HTTP=201; LAST_OUT='{}' ;;
      esac
    }
    control_token() { echo "control" >>"$T_TMP/calls"; }
    use_held() { echo "use_held" >>"$T_TMP/calls"; }
    rc=0
    out="$("$cmd" 2>&1)" || rc=$?
    assert_exit 2 "$rc" "$cmd"
    assert_contains "$out" "possibly issued, never received" "$cmd"
    assert_contains "$out" "repositories forge-frg26-throwaway; permissions $WANT_PERMS" "$cmd"
    assert_contains "$out" "its expiry is unknown" "$cmd"
    assert_not_contains "$out" "at the latest" "$cmd"
    assert_eq "$(cat "$T_TMP/calls")" "" "$cmd went on after the answer"
  done
}

# Round 61 (SEC-1): a control (run hidden) whose token request may have issued a token never
# received is reported by the caller, which stops.
test_a_controls_token_possibly_issued_is_reported_and_stops_the_run() {
  load
  WORK="$T_TMP/work"
  mkdir -p "$WORK"
  app_gh() { :; }
  # shellcheck disable=SC2089 # the record is text (JSON), never run or split
  a_control() { UNRECEIVED='P9 2026-11-12T23:00:00Z {"repositories":["forge-frg26-throwaway"],"permissions":{"metadata":"read"}}
'; die "the token request got no usable answer"; }
  local out rc=0
  out="$(control_token a_control 2>&1; echo "went on")" || rc=$?
  assert_exit 2 "$rc"
  # Round 110: only its status travels, so the token is named as request_token names it, in general
  # words: at most what the installation reaches, its send time not passed on.
  assert_contains "$out" "TOKEN control1-token1 possibly issued, never received"
  assert_contains "$out" "repositories every repository the installation is on; permissions the installation's $WANT_PERMS"
  assert_contains "$out" "its expiry is unknown"
  assert_contains "$out" "its control doesn't pass on when the request was sent"
  assert_not_contains "$out" "went on"
}

# Round 62 (C1, SEC-1), then round 110: a control holds no pipe or file to hand anything over
# through; one that closes every descriptor it has still reports by its exit status, and the caller
# still stops for a token possibly never received. No file is left behind.
test_a_control_that_closes_its_descriptors_still_reports_by_its_status() {
  load
  WORK="$T_TMP/work"
  mkdir -p "$WORK"
  app_gh() { :; }
  # shellcheck disable=SC2089 # the record is text (JSON), never run or split
  lost_record() { exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-; UNRECEIVED='P9 2026-11-12T23:00:00Z {"permissions":{"metadata":"read"}}
'; die "the token request got no usable answer"; }
  local out rc=0
  out="$(control_token lost_record 2>&1; echo "went on")" || rc=$?
  assert_exit 2 "$rc"
  assert_contains "$out" "TOKEN control1-token1 possibly issued, never received"
  # Owner, 2026-11-24 (round 98): its issue time is unknown, so no expiry is stated from the request.
  assert_contains "$out" "its expiry is unknown: GitHub gives such a token one hour from when it issues it" "the expiry of a token never received"
  assert_not_contains "$out" "within an hour of the request" "an expiry stated from the request"
  assert_not_contains "$out" "went on"
  assert_eq "$(find "$WORK" -name 'control.*')" "" "a control's record file left behind"
}

# Round 64 (C1): a control's token it couldn't revoke is reported when a stop comes during the
# control. Round 74: the stop acts at once; the clean-up collects the control's record.
test_a_controls_unrevoked_token_is_reported_when_a_stop_comes_during_it() {
  local out rc=0
  out="$(/bin/bash -p -c '
    source "$1"; WORK="$2"; mkdir -p "$WORK"
    app_gh() { return 1; }
    cleanup() { control_collect; echo "parent cleanup"; }
    a_control() { OUTSTANDING="$(printf "gh%s_" s)QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"; kill -TERM $$; return 0; }
    control_token a_control
    echo continued' _ "$GT" "$T_TMP/work" 2>&1)" || rc=$?
  assert_exit 143 "$rc"
  assert_contains "$out" "a control's token could not be revoked"
  assert_not_contains "$out" "continued"
}

# Round 64, the same class: a record the control could not hand over is reported when a stop comes
# during the control too (round 74: by the clean-up).
test_a_lost_control_record_is_reported_when_a_stop_comes_during_it() {
  local out rc=0
  out="$(/bin/bash -p -c '
    source "$1"; WORK="$2"; mkdir -p "$WORK"
    app_gh() { :; }
    cleanup() { control_collect; echo "parent cleanup"; }
    a_control() { exec 3>&-; UNRECEIVED="P9 2026-11-12T23:00:00Z {}
"; kill -TERM $$; exit 2; }
    control_token a_control
    echo continued' _ "$GT" "$T_TMP/work" 2>&1)" || rc=$?
  assert_exit 143 "$rc"
  # Round 110: reported by its status (bit 8), in general words.
  assert_contains "$out" "control1-token1 possibly issued, never received"
  assert_not_contains "$out" "continued"
}

# Round 65 (C1): a signal that reaches a control while its exit clean-up runs (closing the window
# signals every process) doesn't cut it short: a token it couldn't revoke is still reported.
test_a_signal_during_a_controls_clean_up_still_reports_its_token() {
  local out rc=0
  out="$(/bin/bash -p -c '
    source "$1"; WORK="$2"; mkdir -p "$WORK"
    a_control() {
      OUTSTANDING=" dummy-token"
      resume_signals
      # The signal arrives while the control settles its token (round 73: settle_tokens), which then
      # does not confirm it.
      settle_tokens() { /bin/sh -c "kill -TERM \$PPID"; /bin/sleep 1; }
      sleep() { :; }
      return 0
    }
    control_token a_control; echo "control_token status=$?"' _ "$GT" "$T_TMP/work" 2>&1)" || rc=$?
  assert_contains "$out" "a control's token could not be revoked" "the unrevoked token went unreported"
  # The control got its token (status 0), as control_token reports it, with the warning.
  assert_contains "$out" "control_token status=0"
}

# Round 63 (C1): a signal while a control runs never loses the record it hands over: the clean-up
# (round 74: which collects the control's record) still reports it whole.
test_a_signal_while_a_controls_record_comes_in_keeps_it() {
  local out rc=0
  out="$(/bin/bash -p -c '
    source "$1"; WORK="$2"; mkdir -p "$WORK"
    app_gh() { :; }
    cleanup() { control_collect; echo "CLEANUP REPORTED=<$UNRECEIVED_LABELS>"; }
    a_control() { UNRECEIVED="P9 2026-11-12T23:00:00Z {}
"; kill -TERM $$; /bin/sleep 1; exit 2; }
    control_token a_control
    echo continued' _ "$GT" "$T_TMP/work" 2>&1)" || rc=$?
  assert_exit 143 "$rc"
  # Round 110: by its status, in general words (its own label and send time don't travel).
  assert_contains "$out" "TOKEN control1-token1 possibly issued, never received"
  assert_contains "$out" "CLEANUP REPORTED=< control1-token1>"
  assert_not_contains "$out" "continued"
}

# Round 60 (SEC-1): a signal as an attempt succeeds waits until GitHub's answer is shown and the
# object it made is recorded, so the clean-up still reads it back.
test_a_signal_as_an_attempt_succeeds_keeps_the_object_it_made() {
  local out rc=0
  out="$(/bin/bash -p -c '
    source "$1"; WORK="$2"
    cleanup() { echo "EXIT: PROBE_MADE=[$PROBE_MADE]"; }
    with_timeout() { shift; "$@"; }
    app_gh() { kill -TERM $$; printf "HTTP/2.0 201 Created\n\n{\"number\":42}\n"; }
    probe_issue P1 "without Issues"
    echo continued' _ "$GT" "$T_TMP" 2>&1)" || rc=$?
  assert_exit 143 "$rc"
  assert_contains "$out" "EXIT: PROBE_MADE=[ issue:42]"
  assert_contains "$out" '{"number":42}' "GitHub's answer not shown"
  assert_not_contains "$out" "continued"
}

# Round 68 (C1, SEC-1): a stop during P5's control branch request acts once the branch is reported,
# before the control file request starts: a stop starts no new test action.
test_a_stop_during_the_p5_control_branch_starts_no_file_write() {
  local out rc=0
  out="$(/bin/bash -p -c '
    source "$1"; WORK="$2"; RUN_ID=t1
    cleanup() { echo "EXIT"; }
    with_timeout() { shift; "$@"; }
    call_secs() { echo 20; }
    probe_attempt() { OBS=refused; }
    probe_refs_same() { return 0; }
    owner_gh() { echo 0123456789abcdef0123456789abcdef01234567; }
    app_gh() {
      echo "app_gh $*" >>"$WORK/p5-calls"
      case "$*" in *"-X POST repos/$REPO/git/refs"*) kill -TERM $$ ;; esac
      echo "{}"
    }
    probe_code
    echo continued' _ "$GT" "$T_TMP" 2>&1)" || rc=$?
  assert_exit 143 "$rc"
  assert_contains "$out" "CONTROL P5 branch: the app created the branch frg26/probe/P5-t1 on Thebigtuna88/forge-frg26-throwaway"
  assert_contains "$(cat "$T_TMP/p5-calls")" "-X POST repos/Thebigtuna88/forge-frg26-throwaway/git/refs -f ref=refs/heads/frg26/probe/P5-t1"
  assert_not_contains "$(cat "$T_TMP/p5-calls")" "-X PUT repos/Thebigtuna88/forge-frg26-throwaway/contents" "the file write started after the stop"
  assert_not_contains "$out" "continued"
}

# Round 58 (C2): only HTTP 401 confirms a revocation, not the words "Bad credentials".
test_only_http_401_confirms_a_revocation() {
  probe_stubs
  app_gh() { echo "gh: Bad credentials (HTTP 502)" >&2; return 1; }
  if token_refused "$(printf 'gh%s_tokZ' s)"; then _t_fail "a 502 saying Bad credentials confirmed a revocation"; fi
  app_gh() { echo "gh: Bad credentials (HTTP 401)" >&2; return 1; }
  token_refused "$(printf 'gh%s_tokZ' s)" || _t_fail "HTTP 401 did not confirm a revocation"
}

# Round 57 (C2, SEC-1): a 2xx answer without a readable token is no clear refusal either.
test_mint_reports_a_2xx_answer_without_a_token_as_possibly_issued() {
  local out rc=0
  mint_with_curl '{}' "" 201 0
  # shellcheck disable=SC2090 # UNRECEIVED is text (JSON), only printed
  out="$( (MINT_LABEL=P2; trap 'printf "unreceived=[%s]\n" "$UNRECEIVED"' EXIT; mint '{"permissions":{"metadata":"read"}}' narrowed '{"metadata":"read"}') 2>&1)" || rc=$?
  assert_exit 2 "$rc" "a 2xx without a token"
  assert_contains "$out" "holds no installation token"
  assert_contains "$out" "GitHub may have issued"
  assert_contains "$out" "unreceived=[P2 "
}

# Round 57 (C3, SEC-2): after a failed transfer, a failed revocation is not reported as done.
test_mint_says_so_when_revoking_a_token_from_a_failed_transfer_fails() {
  local tok out rc=0
  tok="$(new_token)"
  mint_with_curl "{\"token\":\"$tok\"}" "curl: (28) Operation timed out" 201 28
  app_gh() { echo "${TOKEN:0:8} $*" >>"$T_TMP/app-gh.log"; return 1; }
  out="$(MINT_LABEL=P2; mint '{"permissions":{"metadata":"read"}}' narrowed '{"metadata":"read"}' 2>&1)" || rc=$?
  assert_exit 2 "$rc"
  assert_not_contains "$out" "it was revoked"
  assert_contains "$out" "revoking it failed"
}

# Round 57 (C1): the request is recorded before it is sent, so a signal while it is out still reaches
# the clean-up's report as a token possibly issued.
test_a_signal_during_a_token_request_is_reported_as_possibly_issued() {
  local out rc=0
  out="$(/bin/bash -p -c '
    source "$1"
    WORK="$2"; APP_ID=123456; INSTALLATION_ID=77; : >"$WORK/jwt.hdr"
    curl() { /bin/sleep 2; printf "{}\nHTTP 201"; }
    app_gh() { :; }
    PROBE_ACTIVE=1 MINT_LABEL=P1
    ( /bin/sleep 1; kill -TERM $$ ) &
    mint "{\"repositories\":[\"forge-frg26-throwaway\"],\"permissions\":{\"metadata\":\"read\"}}" narrowed "{\"metadata\":\"read\"}"
    echo continued' _ "$GT" "$T_TMP" 2>&1)" || rc=$?
  assert_not_contains "$out" "continued"
  assert_contains "$out" "TOKEN P1 possibly issued, never received"
  assert_contains "$out" "repositories forge-frg26-throwaway; permissions {\"metadata\":\"read\"}"
  assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "possibly issued, never received: P1"
}

test_the_clean_up_reports_a_token_possibly_issued_and_never_received() {
  probe_stubs
  ISSUED=""
  UNRECEIVED='P1 2026-11-12T13:01:00Z {"permissions":{"contents":"write","metadata":"read"},"repositories":["forge-frg26-throwaway"]}
whole 2026-11-12T12:31:00Z {}
'
  PROBE_END=""
  local out
  out="$(probe_finish 2; echo "rc=$PROBE_RC"; echo "$PROBE_SUMMARY")"
  assert_contains "$out" "TOKEN P1 possibly issued, never received"
  assert_contains "$out" "it carries at most: repositories forge-frg26-throwaway; permissions {\"contents\":\"write\",\"metadata\":\"read\"}"
  assert_contains "$out" "its expiry is unknown: GitHub gives such a token one hour from when it issues it, and this run doesn't know whether or when that was (the request was sent at 2026-11-12T13:01:00Z by this Mac's clock)"
  assert_contains "$out" "TOKEN whole possibly issued, never received"
  assert_contains "$out" "it carries at most: repositories every repository the installation is on; permissions the installation's $WANT_PERMS"
  assert_contains "$out" "This run does not ask for it again"
  assert_contains "$out" "possibly issued, never received: P1 whole"
  assert_contains "$out" "rc=2"
  end_stand_in_run
}

# Round 47 (C1): a revocation GitHub didn't confirm is tried again on the way out, then checked.
test_a2_probe_retries_and_checks_a_revocation_that_failed() {
  probe_stubs
  echo 1 >"$T_TMP/delete-fails-tok2"
  local out rc=0 calls
  out="$(run_probe)" || rc=$?
  assert_exit 1 "$rc" "a failed revocation"
  assert_contains "$out" "TOKEN full revocation FAILED"
  calls="$(cat "$T_TMP/calls")"
  # Round 48 (C1): the retry revokes it (a second DELETE), and only then does a read get 401.
  assert_eq "$(printf '%s\n' "$calls" | grep -c '^app_gh tok2 api -X DELETE installation/token$')" 2 "the failed revocation was not retried"
  assert_eq "$(printf '%s\n' "$calls" | grep -A1 '^app_gh tok2 api -X DELETE installation/token$' | tail -n 1)" "app_gh tok2 api repos/$REPO --jq .full_name" "the read right after the retry"
  assert_contains "$out" "TOKEN full revoked: a read with it now gets HTTP 401"
  assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "4 of 4 tokens revoked (confirmed)"
  # A token whose every DELETE fails still works: reported, and the run does not pass.
  probe_stubs
  echo 99 >"$T_TMP/delete-fails-tok2"
  rc=0; out="$(run_probe)" || rc=$?
  assert_exit 1 "$rc" "a token that could never be revoked"
  assert_contains "$out" "TOKEN full still answers a read after its revocation was tried"
  assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "3 of 4 tokens revoked (confirmed), NOT confirmed: full"
}

# Round 50 (C1): a token mint refused, whose DELETE GitHub answered as done but which still works,
# is revoked again when the run settles, and is left for the exit clean-up to try once more.
test_a2_probe_revokes_again_a_token_that_still_works_after_a_confirmed_delete() {
  probe_stubs
  echo '.permissions.issues = "write"' >"$T_TMP/extra-3"
  : >"$T_TMP/delete-lies-tok3"
  local out rc=0 calls
  out="$(run_probe)" || rc=$?
  assert_exit 2 "$rc" "P1's token with Issues"
  calls="$(cat "$T_TMP/calls")"
  assert_eq "$(printf '%s\n' "$calls" | grep -c '^app_gh tok3 api -X DELETE installation/token$')" 3 "mint's DELETE, the settling one, the exit clean-up's"
  assert_contains "$out" "TOKEN P1 still answers a read after its revocation was tried"
  assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "A2 PROBE: STOPPED by an error"
  assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "NOT confirmed: P1"
}

# --- The clean-up contract (round 52, owner-approved) ---

# A second Ctrl-C, closing the window or a kill during the clean-up no longer cuts it short.
test_the_clean_up_finishes_despite_a_signal_during_it() {
  local sig out rc
  for sig in HUP INT TERM; do
    rc=0
    out="$(/bin/bash -p -c 'sig="$2"; source "$1"; PROBE_ACTIVE=1; probe_finish() { echo finish-start; kill -s "$sig" $$; echo finish-end; PROBE_SUMMARY=summary-printed; PROBE_RC=1; }; kill -s "$sig" $$; sleep 2' _ "$GT" "$sig" 2>&1)" || rc=$?
    assert_contains "$out" "finish-start" "SIG$sig"
    assert_contains "$out" "finish-end" "a second SIG$sig cut the clean-up short"
    assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "summary-printed" "SIG$sig"
    assert_exit 1 "$rc" "SIG$sig: the probe's own status"
  done
}

test_with_timeout_stops_a_command_that_hangs() {
  load
  WORK="$T_TMP/work"
  mkdir -m 700 "$WORK"
  local rc=0 start
  start="$(date +%s)"
  with_timeout 1 /bin/sleep 10 || rc=$?
  assert_exit 124 "$rc" "a hang"
  (($(date +%s) - start <= 4)) || _t_fail "with_timeout 1 took $(($(date +%s) - start))s"
  rc=0
  with_timeout 5 /bin/sh -c 'exit 3' || rc=$?
  assert_exit 3 "$rc" "a command's own status"
  # Inside a command substitution, as capture runs it: the watchdog doesn't hold it open.
  start="$(date +%s)"
  assert_eq "$(with_timeout 10 echo quick)" quick
  (($(date +%s) - start <= 2)) || _t_fail "the watchdog held a command substitution open"
  # The same while TERM is ignored, as it is during the clean-up (and in what it starts).
  start="$(date +%s)"
  rc=0
  (trap '' HUP INT TERM; with_timeout 1 /bin/sleep 10) || rc=$?
  assert_exit 124 "$rc" "a hang during the clean-up"
  (($(date +%s) - start <= 4)) || _t_fail "with_timeout 1 took $(($(date +%s) - start))s with TERM ignored"
  start="$(date +%s)"
  assert_eq "$(trap '' HUP INT TERM; with_timeout 10 echo quick)" quick
  (($(date +%s) - start <= 2)) || _t_fail "with TERM ignored, a quick command waited $(($(date +%s) - start))s for its watchdog"
}

# Round 67 (C1): a signal to the whole process group (as closing the window sends) doesn't kill
# the watchdog, so a command that ignores it is still stopped in time. The case runs in its own
# process group (a new session), so the signal reaches nothing else.
test_with_timeout_survives_a_signal_to_the_process_group() {
  local out
  # shellcheck disable=SC2016 # the inner script is single-quoted on purpose: the inner bash expands it
  out="$(/usr/bin/python3 -c 'import os, sys; os.setsid(); os.execv("/bin/bash", ["/bin/bash", "-p", "-c"] + sys.argv[1:])' '
    source "$1"; WORK="$2"; mkdir -p "$WORK"
    trap : TERM
    slow() { trap "" TERM; /bin/sleep 6; }
    ( /bin/sleep 1; kill -TERM -- -$$ ) &
    SECONDS=0; with_timeout 2 slow; echo "rc=$? after=$SECONDS"' _ "$GT" "$T_TMP/work" 2>&1)"
  local secs
  secs="$(printf '%s\n' "$out" | sed -n 's/^rc=124 after=\([0-9]*\)$/\1/p')"
  [[ "$secs" =~ ^[0-9]+$ && $secs -le 4 ]] || _t_fail "the watchdog died with the group signal: $out"
}

# Round 66 (C1): a caught signal interrupts bash's wait while the command still runs; with_timeout
# keeps waiting under the same watchdog instead of taking that for the command's end.
test_with_timeout_waits_on_through_a_caught_signal() {
  local out
  out="$(/bin/bash -p -c '
    source "$1"; WORK="$2"; mkdir -p "$WORK"
    trap "echo SIGNAL_HELD" TERM
    ( /bin/sleep 1; kill -TERM $$ ) &
    SECONDS=0; with_timeout 20 /bin/sleep 3; echo "ran rc=$? after=$SECONDS"
    ( /bin/sleep 1; kill -TERM $$ ) &
    SECONDS=0; with_timeout 2 /bin/sleep 9; echo "stopped rc=$? after=$SECONDS"
    echo "jobs=[$(jobs -r)]"' _ "$GT" "$T_TMP/work" 2>&1)"
  assert_contains "$out" "SIGNAL_HELD"
  local secs
  secs="$(printf '%s\n' "$out" | sed -n 's/^ran rc=0 after=\([0-9]*\)$/\1/p')"
  [[ "$secs" =~ ^[0-9]+$ && $secs -ge 3 ]] || _t_fail "the command was left after the signal: $out"
  secs="$(printf '%s\n' "$out" | sed -n 's/^stopped rc=124 after=\([0-9]*\)$/\1/p')"
  [[ "$secs" =~ ^[0-9]+$ && $secs -ge 2 && $secs -le 4 ]] || _t_fail "the timeout did not hold through the signal: $out"
  assert_contains "$out" "jobs=[]" "a command left running"
}

# Round 53 (C1, SEC-1): app_gh and owner_gh are functions whose subshell execs gh. The timeout must
# stop gh itself, or it keeps the command substitution (capture) open until it ends.
test_with_timeout_stops_the_real_command_under_a_function() {
  load
  WORK="$T_TMP/work"
  mkdir -m 700 "$WORK"
  gh_shaped() { (exec /bin/sleep 6); }
  nested() { (/bin/sh -c '/bin/sleep 6; echo late') ; }
  local f start out rc
  for f in gh_shaped nested; do
    start="$(date +%s)"
    rc=0
    out="$(trap '' HUP INT TERM; with_timeout 1 "$f"; echo "rc=$?")" || rc=$?
    assert_contains "$out" "rc=124" "$f"
    assert_not_contains "$out" "late" "$f"
    (($(date +%s) - start <= 3)) || _t_fail "$f: capture returned after $(($(date +%s) - start))s, not about 1s"
  done
}

# Round 72 (SEC-1): every other command's clean-up, with budgets short enough to test: a copy of
# the script with only its budget lines changed (CALL_SECS 1, REVOKE_SECS 3, CLEANUP_SECS 6, and
# from round 74 CONTROL_SECS 12). Three tokens of the run's own, none revoked yet: token1 in use,
# tokens 2 and 3 set aside. $T_TMP/hang lists what never answers: "app <n>" (every call with token
# n), "app all", "call <text>" (an app call containing it) or "owner <text>" (an owner call
# containing it). Other calls answer at once: nothing open, and a read with a revoked token gets
# HTTP 401, unless $T_TMP/works lists that token's number. $T_TMP/delete-fails lists tokens whose
# revocation GitHub refuses, $T_TMP/expired tokens a read gets HTTP 401 with anyway (expired). A
# token request (a control's) is answered with token 4. Each token's expiry, as GitHub gives it
# when it issues it: $T_TMP/expiry-<n> (seconds from now, or "none"), else 50 minutes ahead.
cleanup_stubs() {
  short_copy
  WORK="$T_TMP/work"
  # A fresh folder for each run, as make_work makes one (the clean-up no longer deletes it, round 96).
  rm -rf "$WORK"
  mkdir -m 700 "$WORK"
  : >"$T_TMP/calls"
  : >"$T_TMP/timeline"
  : >"$T_TMP/revoked"
  : >"$T_TMP/hang"
  : >"$T_TMP/works"
  : >"$T_TMP/delete-fails"
  : >"$T_TMP/expired"
  rm -f "$T_TMP"/expiry-*
  INSTALLATION_ID=77
  app_gh() {
    local n="${TOKEN:11:1}" h
    echo "app_gh $n $*" >>"$T_TMP/calls"
    echo "$(date +%s) app_gh $n $*" >>"$T_TMP/timeline"
    if grep -qx -e "app $n" -e "app all" "$T_TMP/hang"; then /bin/sleep 600; return 1; fi
    while IFS= read -r h; do
      if [[ "$h" == "call "* && "$*" == *"${h#call }"* ]]; then /bin/sleep 600; return 1; fi
    done <"$T_TMP/hang"
    case "$*" in
      "api -X DELETE installation/token")
        if grep -qx "$n" "$T_TMP/delete-fails"; then echo "gh: Server Error (HTTP 502)" >&2; return 1; fi
        echo "$n" >>"$T_TMP/revoked" ;;
      "api repos/$REPO --jq .full_name")
        if grep -qx "$n" "$T_TMP/expired" || { grep -qx "$n" "$T_TMP/revoked" && ! grep -qx "$n" "$T_TMP/works"; }; then
          echo "gh: Bad credentials (HTTP 401)" >&2
          return 1
        fi
        echo "$REPO" ;;
      "api installation/repositories"*) echo "$REPO" ;;
    esac
    return 0
  }
  jwt_call() {
    LAST_HTTP=201
    LAST_OUT="$(stub_meta 4 | jq -c --arg t "$(cleanup_token 4)" --argjson p "$WANT_PERMS" --arg r "$REPO" \
      '{token: $t, expires_at, repository_selection: "selected", permissions: $p, repositories: [{full_name: $r}]}')"
  }
  owner_gh() {
    local h
    echo "owner_gh $*" >>"$T_TMP/calls"
    while IFS= read -r h; do
      if [[ "$h" == "owner "* && "$*" == *"${h#owner }"* ]]; then /bin/sleep 600; return 1; fi
    done <"$T_TMP/hang"
    return 0
  }
}

# The script with only its budget lines changed, sourced: CALL_SECS 1, REVOKE_SECS 3, CLEANUP_SECS 6,
# CONTROL_SECS 12 (round 74), PUSH_SECS 2 and CLONE_SECS 3 (round 75).
short_copy() { # [-e <sed expression>…] — a test's own changes to the copy, after the short budgets
  local short="$T_TMP/github-throwaway-short.sh"
  sed -e 's/^readonly CALL_SECS=20 /readonly CALL_SECS=1 /' -e 's/^readonly REVOKE_SECS=90 /readonly REVOKE_SECS=3 /' \
    -e 's/^readonly CLEANUP_SECS=180 /readonly CLEANUP_SECS=6 /' -e 's/^readonly CONTROL_SECS=240 /readonly CONTROL_SECS=12 /' \
    -e 's/^readonly PUSH_SECS=60 /readonly PUSH_SECS=2 /' -e 's/^readonly CLONE_SECS=120 /readonly CLONE_SECS=3 /' \
    -e "s#^readonly APP_API_CURL=\"/usr/bin/curl\" #readonly APP_API_CURL=\"$T_TMP/bin/curl\" #" "$@" "$GT" >"$short"
  # shellcheck source=tests/permissions/github-throwaway.sh
  source "$short"
  # The clean-up runs in each stopped run's own subshell; here, the exit trap sourcing installs
  # would end a test that crashed with the clean-up's status, which can be 0 (a crash reported as
  # a pass, round 74).
  trap - EXIT
  assert_eq "$CALL_SECS ${REVOKE_SECS:-none} $CLEANUP_SECS" "1 3 6" "the short budgets"
}

cleanup_token() { printf 'gh%s_cleanup%s%s' s "$1" "$(printf 'Q%.0s' $(seq 1 30))"; }

stub_meta() { # <n> — what GitHub said when it issued token n, without the token: its expiry
  local e=3000
  [[ ! -f "$T_TMP/expiry-$1" ]] || e="$(cat "$T_TMP/expiry-$1")"
  if [[ "$e" == none ]]; then printf '{"expires_at":null}'; return; fi
  printf '{"expires_at":"%s"}' "$(date -u -r $(($(date +%s) + e)) +%Y-%m-%dT%H:%M:%SZ)"
}

# The clean-up of a run that stopped with status <rc>, after <set-up> (shell code) has run, and
# then <after> (shell code, with the three tokens in place). One still running after 20s is killed
# (status 137). Sets OUT, RC and SECS.
stopped_run_cleanup() { # <rc> <set-up> [after]
  local pid start t1 t2 t3
  t1="$(cleanup_token 1)" t2="$(cleanup_token 2)" t3="$(cleanup_token 3)"
  start="$(date +%s)"
  # shellcheck disable=SC2030 # the stopped run's state belongs to its own subshell
  (
    # The stop traps a real run has from the script's top level (round 75): a subshell starts with
    # them reset, and bash's own handling of TERM then acts at once even inside a command
    # substitution, which a real run never does.
    if declare -F stop_traps >/dev/null; then stop_traps; fi
    eval "$2"
    TOKEN="$t1"
    OUTSTANDING=" $t1 $t2 $t3"
    ISSUED=" token1=$t1 token2=$t2 token3=$t3"
    ISSUED_META="token1 $(stub_meta 1)
token2 $(stub_meta 2)
token3 $(stub_meta 3)
"
    MINTED=3
    trap cleanup EXIT
    eval "${3:-}"
    exit "$1"
  ) >"$T_TMP/cleanup.out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && (($(date +%s) - start < 20)); do /bin/sleep 0.2; done
  if kill -0 "$pid" 2>/dev/null; then kill_tree "$pid"; fi
  RC=0
  wait "$pid" 2>/dev/null || RC=$?
  SECS=$(($(date +%s) - start))
  OUT="$(cat "$T_TMP/cleanup.out")"
}

test_a_hung_tidy_up_call_never_keeps_the_tokens_from_their_revocation() {
  local case name setup hang n first_owner last_app
  for case in "a hung PR list|SWEEP_ON_EXIT=1 PHASE=open|owner pulls?state=open" \
    "a hung issue list|SWEEP_ON_EXIT=1 PHASE=permissions|owner issues?state=open" \
    "a hung S2 run list|CANCEL_ON_EXIT=1 S2_SHAS=$(printf 'e%.0s' $(seq 1 40))|owner actions/runs"; do
    IFS='|' read -r name setup hang <<<"$case"
    cleanup_stubs
    echo "$hang" >"$T_TMP/hang"
    stopped_run_cleanup 1 "$setup"
    assert_exit 1 "$RC" "$name: the run's own status (137: still running after 20s)"
    ((SECS <= CLEANUP_SECS + 3)) || _t_fail "$name: the clean-up took ${SECS}s, over its ${CLEANUP_SECS}s cap"
    for n in 1 2 3; do
      assert_contains "$(cat "$T_TMP/calls")" "app_gh $n api -X DELETE installation/token" "$name: token$n's revocation"
      assert_contains "$OUT" "TOKEN token$n revoked: a read with it now gets HTTP 401" "$name"
    done
    # Every revocation and its check before the tidy-up's first call.
    first_owner="$(grep -n '^owner_gh' "$T_TMP/calls" | head -n 1 | cut -d: -f1)"
    last_app="$(grep -n '^app_gh' "$T_TMP/calls" | tail -n 1 | cut -d: -f1)"
    [[ -n "$first_owner" && -n "$last_app" && $last_app -lt $first_owner ]] || _t_fail "$name: the tidy-up ran before the tokens were settled"
    assert_contains "$(printf '%s\n' "$OUT" | tail -n 1)" "CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none; not done:" "$name"
    assert_not_contains "$OUT" "CLEANUP DONE" "$name"
    assert_not_contains "$OUT" "$(cleanup_token 1)" "$name: a token printed"
  done
  # Control: nothing hangs, the run had passed.
  cleanup_stubs
  stopped_run_cleanup 0 "SWEEP_ON_EXIT=1 PHASE=open"
  assert_exit 0 "$RC" "a clean-up with nothing left undone"
  assert_contains "$(printf '%s\n' "$OUT" | tail -n 1)" "CLEANUP DONE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none; nothing left undone"
}

test_hung_revocations_end_by_the_cap_and_name_each_tokens_state() {
  local out_tokens
  # One token's calls hang: the others are still revoked and confirmed, that one named as not.
  cleanup_stubs
  echo "app 2" >"$T_TMP/hang"
  stopped_run_cleanup 0 ""
  assert_exit 1 "$RC" "an unconfirmed token: no success claimed (137: still running after 20s)"
  ((SECS <= CLEANUP_SECS + 3)) || _t_fail "one hung token: the clean-up took ${SECS}s, over its ${CLEANUP_SECS}s cap"
  assert_contains "$(cat "$T_TMP/calls")" "app_gh 2 api -X DELETE installation/token" "token2's revocation"
  assert_contains "$OUT" "TOKEN token1 revoked: a read with it now gets HTTP 401"
  assert_contains "$OUT" "TOKEN token3 revoked: a read with it now gets HTTP 401"
  assert_contains "$(printf '%s\n' "$OUT" | tail -n 1)" "CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): token1 token3; NOT confirmed: token2;"
  # Everything hangs, the tidy-up too: each token's revocation is still tried, and the clean-up
  # ends by its cap naming every token as not confirmed and the tidy-up as not done.
  cleanup_stubs
  printf 'app all\nowner pulls?state=open\n' >"$T_TMP/hang"
  stopped_run_cleanup 1 "SWEEP_ON_EXIT=1 PHASE=open"
  assert_exit 1 "$RC" "everything hung (137: still running after 20s)"
  ((SECS <= CLEANUP_SECS + 3)) || _t_fail "everything hung: the clean-up took ${SECS}s, over its ${CLEANUP_SECS}s cap"
  for n in 1 2 3; do
    assert_contains "$(cat "$T_TMP/calls")" "app_gh $n api -X DELETE installation/token" "everything hung: token$n's revocation"
  done
  assert_not_contains "$OUT" "revoked: a read with it now gets HTTP 401" "everything hung"
  out_tokens="$(printf '%s\n' "$OUT" | tail -n 1)"
  assert_contains "$out_tokens" "CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): none; NOT confirmed: token1 token2 token3; not done: closing the open test PRs" "everything hung"
  assert_not_contains "$OUT" "CLEANUP DONE" "everything hung"
}

# call_secs gives 0 once: the first time it runs after <n> calls in $T_TMP/calls contain <text>, as it
# does when the clock's second turns over between a check of the deadline and the request's own
# reading of it. After cleanup_stubs (which sources the script afresh).
turnover_after() { # <text> <n>
  TURN_TEXT="$1" TURN_N="$2"
  rm -f "$T_TMP/turned"
  eval "$(declare -f call_secs | sed '1s/^call_secs/real_call_secs/')"
  call_secs() {
    if [[ ! -f "$T_TMP/turned" && $(grep -cF -- "$TURN_TEXT" "$T_TMP/calls") -ge $TURN_N ]]; then
      : >"$T_TMP/turned"
      printf 0
      return
    fi
    real_call_secs "$@"
  }
}

# Waits for the start of the clock's next second (and 50 ms), so that a 1 s request's turn falls
# where the case puts it, not past a deadline by where in its second the clean-up started.
second_start() { perl -MTime::HiRes=time,sleep -e '$t = time; sleep(1 - ($t - int($t)) + 0.05)'; }

# Round 83 (the round 81 failure, fixes.md "Revocation-cap failure investigation"): the clean-up read
# the clock twice per request, once to check the deadline and once for the request's time. A
# turnover between the two gave a request 0 s: it was never sent, yet counted as a try, so the token
# waited behind the retries and its revocation could go unsent while others were retried, and the
# record named a failure or a timeout. Now the time is read once, and 0 s means not tried or not
# checked, named so.
test_a_request_given_no_time_is_not_counted_as_sent() {
  local t t1 t2 t3 out deletes notes after_sweep
  t1="$(cleanup_token 1)" t2="$(cleanup_token 2)" t3="$(cleanup_token 3)"
  # Everything hangs; no time for token3's first try: it is tried in the second share, ahead of the
  # retries, and no failure or timeout is named for a request never sent.
  cleanup_stubs
  turnover_after "api -X DELETE installation/token" 2
  printf 'app all\nowner pulls?state=open\n' >"$T_TMP/hang"
  second_start
  stopped_run_cleanup 1 "SWEEP_ON_EXIT=1 PHASE=open"
  [[ -f "$T_TMP/turned" ]] || _t_fail "everything hung: the turnover never came"
  ((SECS <= CLEANUP_SECS + 3)) || _t_fail "everything hung: the clean-up took ${SECS}s, over its ${CLEANUP_SECS}s cap"
  assert_contains "$(cat "$T_TMP/calls")" "app_gh 3 api -X DELETE installation/token" "everything hung: token3's revocation sent"
  after_sweep="$(sed -n '/^owner_gh api --paginate .*pulls?state=open/,$p' "$T_TMP/calls" | grep -m 1 'api -X DELETE installation/token')"
  assert_eq "$after_sweep" "app_gh 3 api -X DELETE installation/token" "everything hung: the first revocation after the tidy-up"
  assert_contains "$OUT" "TOKEN token3 revocation not tried: the clean-up's share for tokens (3s) was used up"
  deletes="$(grep -c 'api -X DELETE installation/token' "$T_TMP/calls")"
  notes="$(grep -c 'note: revoking a token failed or timed out' <<<"$OUT")"
  assert_eq "$notes" "$deletes" "everything hung: a failure or timeout named for each revocation sent, and only those"
  assert_contains "$(printf '%s\n' "$OUT" | tail -n 1)" "NOT confirmed: token1 token2 token3;" "everything hung"
  # Nothing hangs; no time for token1's first check: it is named not checked yet, never "no answer",
  # and checked after the tidy-up.
  cleanup_stubs
  turnover_after "api -X DELETE installation/token" 3
  stopped_run_cleanup 0 ""
  [[ -f "$T_TMP/turned" ]] || _t_fail "a check: the turnover never came"
  assert_not_contains "$OUT" "TOKEN token1 NOT confirmed revoked" "a check never sent"
  assert_contains "$OUT" "TOKEN token1 not checked yet: the clean-up's share for tokens (3s) was used up"
  assert_contains "$OUT" "TOKEN token1 revoked: a read with it now gets HTTP 401"
  assert_contains "$(printf '%s\n' "$OUT" | tail -n 1)" "CLEANUP DONE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none"
  # a2-probe's settling: no time for token2's revocation, then none for token1's check. Neither is
  # reported as a revocation tried that a read still answers.
  cleanup_stubs
  turnover_after "app_gh 1 api repos/$REPO --jq .full_name" 1
  out="$(
    ISSUED=" whole=$t1 full=$t2" PROBE_CONFIRMED="" OUTSTANDING=" $t1 $t2"
    CLEANUP_DEADLINE=$(($(date +%s) + 6))
    probe_settle_tokens
    for t in $OUTSTANDING; do echo "still to settle: token${t:11:1}"; done
  )"
  assert_not_contains "$(cat "$T_TMP/calls")" "app_gh 2 api -X DELETE" "a2-probe: token2's revocation given no time"
  assert_not_contains "$(cat "$T_TMP/calls")" "app_gh 2 api repos/" "a2-probe: token2 read without a revocation"
  assert_not_contains "$out" "TOKEN full still answers a read after its revocation was tried" "a2-probe: a revocation never sent"
  assert_contains "$out" "TOKEN full not checked: the clean-up's time cap (6s) was reached"
  assert_contains "$out" "still to settle: token2" "a2-probe"
  cleanup_stubs
  turnover_after "app_gh 1 api -X DELETE installation/token" 1
  out="$(
    ISSUED=" whole=$t1" PROBE_CONFIRMED="" OUTSTANDING=" $t1"
    CLEANUP_DEADLINE=$(($(date +%s) + 6))
    probe_settle_tokens
  )"
  assert_not_contains "$(cat "$T_TMP/calls")" "app_gh 1 api repos/" "a2-probe: token1's check given no time"
  assert_not_contains "$out" "still answers a read after its revocation was tried" "a2-probe: a check never sent"
  assert_contains "$out" "TOKEN whole revocation tried, not checked: the clean-up's time cap (6s) was reached"
  # revoke_outstanding: no time for the current token's revocation (named not sent, never failed or
  # timed out; the token stays outstanding, so the loop after it tries it again), or for the next
  # one's (the time is up: it and the rest stay to settle).
  cleanup_stubs
  turnover_after "api -X DELETE installation/token" 0
  out="$(
    TOKEN="$t1" OUTSTANDING=" $t1"
    CLEANUP_DEADLINE=$(($(date +%s) + 6))
    revoke_outstanding
  )"
  assert_not_contains "$out" "revoking a token failed or timed out" "revoke_outstanding: the current token's revocation never sent"
  assert_contains "$out" "note: a token's revocation was not sent: the clean-up's time cap was reached"
  cleanup_stubs
  turnover_after "api -X DELETE installation/token" 1
  # shellcheck disable=SC2030 # the clean-up's state belongs to its own subshell
  out="$(
    TOKEN="$t1" OUTSTANDING=" $t1 $t2 $t3"
    CLEANUP_DEADLINE=$(($(date +%s) + 6))
    revoke_outstanding
    for t in $OUTSTANDING; do echo "still to settle: token${t:11:1}"; done
  )"
  assert_not_contains "$(cat "$T_TMP/calls")" "app_gh 2 api -X DELETE" "revoke_outstanding: token2 given no time"
  assert_not_contains "$out" "revoking a token failed or timed out" "revoke_outstanding: a revocation never sent"
  assert_contains "$out" "still to settle: token2" "revoke_outstanding"
  assert_contains "$out" "still to settle: token3" "revoke_outstanding: the time is up for the rest too"
  # Its last line (round 84, review-lens round 80, C1 = SEC-1): every token still outstanding counted
  # once, as sent and not confirmed or as never sent, never a never-sent one as "could not be revoked".
  assert_contains "$out" "note: 2 token(s) of this run still outstanding: 0 with a revocation request sent and not confirmed, 2 with none sent (the clean-up's time cap was reached)"
  assert_not_contains "$out" "could not be revoked" "revoke_outstanding: revocations never sent"
  # token1's revocation fails twice (as the current token, then in the loop), then the time is up:
  # one token sent and not confirmed (counted once, not per try), two never sent.
  cleanup_stubs
  echo 1 >"$T_TMP/delete-fails"
  turnover_after "api -X DELETE installation/token" 2
  out="$(
    TOKEN="$t1" OUTSTANDING=" $t1 $t2 $t3"
    CLEANUP_DEADLINE=$(($(date +%s) + 6))
    revoke_outstanding
  )"
  assert_eq "$(grep -c 'app_gh 1 api -X DELETE installation/token' "$T_TMP/calls")" 2 "revoke_outstanding: token1 tried twice"
  assert_contains "$out" "note: 3 token(s) of this run still outstanding: 1 with a revocation request sent and not confirmed, 2 with none sent (the clean-up's time cap was reached)"
  # token2's revocation was sent before (and failed); now the cap has passed: it is still a token
  # whose request was sent, and token1 one whose request never was.
  cleanup_stubs
  echo 2 >"$T_TMP/delete-fails"
  out="$(
    CLEANUP_DEADLINE=$(($(date +%s) + 6))
    TOKEN="$t2" OUTSTANDING=" $t1 $t2"
    revoke_token || true
    CLEANUP_DEADLINE=$(($(date +%s) - 1))
    revoke_outstanding
  )"
  assert_eq "$(grep -c 'api -X DELETE installation/token' "$T_TMP/calls")" 1 "revoke_outstanding: nothing sent past the cap"
  assert_contains "$out" "note: 2 token(s) of this run still outstanding: 1 with a revocation request sent and not confirmed, 1 with none sent (the clean-up's time cap was reached)"
  # All revoked: no line.
  cleanup_stubs
  # shellcheck disable=SC2030 # the clean-up's state belongs to its own subshell
  out="$(
    TOKEN="$t1" OUTSTANDING=" $t1 $t2"
    CLEANUP_DEADLINE=$(($(date +%s) + 6))
    revoke_outstanding
  )"
  assert_not_contains "$out" "still outstanding" "revoke_outstanding: every token revoked"
}

# Round 73 (C1, SEC-1): a control's token stays in its control, which revokes it and confirms the
# revocation with a read (HTTP 401), retrying within its own share; the run is told only its name
# and its state, and names it in the clean-up's last line. A control that ends without telling
# leaves it NOT confirmed. The control never touches the run's own tokens.
test_a_controls_token_is_confirmed_in_its_control_and_named_in_the_last_line() {
  local case name works hang after rc_want want n
  for case in "confirmed||||0|CLEANUP DONE: tokens confirmed revoked (HTTP 401): token1 token2 token3 control1-token4; NOT confirmed: none; nothing left undone" \
    "still works after its revocation|4|||1|CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: control1-token4;" \
    "its checks hang||app 4||1|CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: control1-token4;" \
    "the control ends without telling|||vanish|1|CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: control1 (no result);"; do
    IFS='|' read -r name works hang after rc_want want <<<"$case"
    cleanup_stubs
    printf '%s\n' "$works" >"$T_TMP/works"
    printf '%s\n' "$hang" >"$T_TMP/hang"
    control_cmd() { request_token '{}'; }
    # Killed outright, so its exit trap never runs (bash 3.2 has no BASHPID: a child kills it).
    vanish_cmd() { request_token '{}'; /bin/sh -c 'kill -KILL $PPID'; /bin/sleep 1; }
    if [[ "$after" == vanish ]]; then after="control_token vanish_cmd || true"; else after="control_token control_cmd || true"; fi
    stopped_run_cleanup 0 "" "$after"
    assert_exit "$rc_want" "$RC" "$name: the run's status (137: still running after 20s)"
    ((SECS <= REVOKE_SECS + CLEANUP_SECS + 3)) || _t_fail "$name: took ${SECS}s, over the control's ${REVOKE_SECS}s and the clean-up's ${CLEANUP_SECS}s"
    assert_contains "$(printf '%s\n' "$OUT" | tail -n 1)" "$want" "$name"
    assert_not_contains "$OUT" "$(cleanup_token 4)" "$name: the control's token printed"
    for n in 1 2 3; do
      assert_eq "$(grep -c "^app_gh $n api -X DELETE installation/token" "$T_TMP/calls")" 1 "$name: the run's token$n revoked by the control too"
    done
    if [[ "$after" != *vanish* ]]; then
      assert_contains "$(cat "$T_TMP/calls")" "app_gh 4 api repos/$REPO --jq .full_name" "$name: the control's token checked by a read"
    fi
  done
  # Retried within the control's share: more than once, never past it.
  cleanup_stubs
  echo 4 >"$T_TMP/works"
  stopped_run_cleanup 0 "" "control_token control_cmd || true"
  n="$(grep -c '^app_gh 4 api -X DELETE installation/token' "$T_TMP/calls")"
  ((n >= 2 && n <= 3)) || _t_fail "the control's revocation tried $n times, not 2 or 3"
}

# Round 73 (C2): a tidy-up that fails on a normal finish (cmd_tests, cmd_ptests, env-tests tidy up
# themselves) is named in the last line too, which then never says DONE.
test_a_tidy_up_failure_on_a_normal_finish_is_in_the_last_line() {
  local case name setup hang want
  for case in "test PRs%sweep_prs || true%owner pulls?state=open%closing the open test PRs" \
    "test issues%RUN_ID=r1; sweep_issues%owner issues?state=open%closing the test issues" \
    "S2 runs%sleep() { :; }; S2_SHAS=$(printf 'e%.0s' $(seq 1 40)); cancel_waiting_runs || true%owner actions/runs?per_page=100%cancelling the waiting S2 runs"; do
    IFS='%' read -r name setup hang want <<<"$case"
    cleanup_stubs
    echo "$hang" >"$T_TMP/hang"
    stopped_run_cleanup 1 "$setup"
    assert_exit 1 "$RC" "$name (137: still running after 20s)"
    assert_contains "$OUT" "CLEANUP FAIL" "$name"
    assert_contains "$(printf '%s\n' "$OUT" | tail -n 1)" "CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none; not done:" "$name"
    assert_contains "$(printf '%s\n' "$OUT" | tail -n 1)" "$want" "$name"
    assert_not_contains "$OUT" "CLEANUP DONE" "$name"
  done
}

# Round 74 (C1, SEC-1): every request a control makes has a time limit (E1's control reads what the
# whole installation reaches), and so does the control as a whole.
test_every_request_a_control_makes_is_bounded() {
  load
  local f bad
  for f in app_session load_app need_app_identity make_jwt need_installation_scope mint mint_token request_token \
    revoke_token control_exit settle_tokens token_refused revocation_judged; do
    bad="$(declare -f "$f" | grep -E '(^|[^_a-z])(app_gh|owner_gh|gh|curl) ' | grep -v 'with_timeout' || true)"
    assert_eq "$bad" "" "$f: a request without a time limit"
  done
  # shellcheck disable=SC2016 # the literal source text is what's searched for
  assert_contains "$(declare -f jwt_call)" '--max-time "$CALL_SECS"' "the app's own requests"
  end_stand_in_run
}

# Round 74 (C1, SEC-1): a control that hangs can't hold the run: a hung request ends by its limit; a
# control whose work outlasts its share is told to stop and still settles its token; one that
# can't be stopped is stopped outright at CONTROL_SECS, its token NOT confirmed, the clean-up
# INCOMPLETE. The run's own tokens are settled either way.
test_a_hanging_control_is_bounded_and_its_token_settled() {
  local case name hang cmd rc_want want note
  scope_cmd() { need_installation_scope; }
  loop_cmd() { request_token '{}'; while :; do with_timeout "$CALL_SECS" /bin/sleep 600; done; }
  stuck_cmd() { request_token '{}'; /bin/sleep 600; }
  # A request of the control's that hangs stops the run too, once the control has settled its token
  # (round 75, C1).
  for case in "its installation read hangs|call installation/repositories|scope_cmd|2|CLEANUP DONE: tokens confirmed revoked (HTTP 401): token1 token2 token3 control1-token4; NOT confirmed: none; nothing left undone|STOPPED: a request of control1's got no answer within its limit" \
    "its work outlasts its share||loop_cmd|0|CLEANUP DONE: tokens confirmed revoked (HTTP 401): token1 token2 token3 control1-token4; NOT confirmed: none; nothing left undone|control1's work took longer than its share" \
    "it can't be told to stop||stuck_cmd|1|CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: control1 (no result);|control1 did not end in time and was stopped outright"; do
    IFS='|' read -r name hang cmd rc_want want note <<<"$case"
    cleanup_stubs
    assert_eq "${CONTROL_SECS:-none}" 12 "the short budget for a control"
    printf '%s\n' "$hang" >"$T_TMP/hang"
    stopped_run_cleanup 0 "" "control_token $cmd || true"
    assert_exit "$rc_want" "$RC" "$name: the run's status (137: still running after 20s)"
    ((SECS <= ${CONTROL_SECS:-0} + CLEANUP_SECS + 3)) || _t_fail "$name: took ${SECS}s, over the control's ${CONTROL_SECS:-unset}s and the clean-up's ${CLEANUP_SECS}s"
    assert_contains "$(printf '%s\n' "$OUT" | tail -n 1)" "$want" "$name"
    [[ -z "$note" ]] || assert_contains "$OUT" "$note" "$name"
    assert_not_contains "$OUT" "$(cleanup_token 4)" "$name: the control's token printed"
  done
}

# Round 74 (C1, SEC-1): a stop during a control reaches the run's clean-up at once and starts no
# new test action; the control is told to stop and settles its own token meanwhile, and the whole
# ends within the clean-up's cap. A control that can't be told to stop is stopped outright by that
# cap, its token NOT confirmed.
test_a_stop_during_a_control_reaches_the_clean_up_at_once() {
  local case name cmd rc_want want first
  loop_cmd() { request_token '{}'; while :; do with_timeout "$CALL_SECS" /bin/sleep 600; done; }
  stuck_cmd() { request_token '{}'; /bin/sleep 600; }
  for case in "the control is told to stop|loop_cmd|143|CLEANUP DONE: tokens confirmed revoked (HTTP 401): token1 token2 token3 control1-token4; NOT confirmed: none; nothing left undone" \
    "the control can't be told to stop|stuck_cmd|143|CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: control1 (no result);"; do
    IFS='|' read -r name cmd rc_want want <<<"$case"
    cleanup_stubs
    # shellcheck disable=SC2016 # run inside the stopped run: $PPID there is the run itself
    stopped_run_cleanup 0 "" '/bin/sh -c "/bin/sleep 1; date +%s >$T_TMP/stop-at; kill -TERM \$PPID" & control_token '"$cmd"'; echo "NEXT TEST ACTION"'
    assert_exit "$rc_want" "$RC" "$name: the run's status (137: still running after 20s)"
    ((SECS <= 1 + CLEANUP_SECS + 3)) || _t_fail "$name: ${SECS}s, over the clean-up's ${CLEANUP_SECS}s after the stop"
    assert_not_contains "$OUT" "NEXT TEST ACTION" "$name: a test action after the stop"
    first="$(grep -m 1 'app_gh 1 api -X DELETE installation/token' "$T_TMP/timeline" | cut -d' ' -f1)"
    if [[ -z "$first" ]] || (($(cat "$T_TMP/stop-at") + 2 < first)); then
      _t_fail "$name: the clean-up's first revocation came at ${first:-never}, not within 2s of the stop at $(cat "$T_TMP/stop-at")"
    fi
    assert_contains "$(printf '%s\n' "$OUT" | tail -n 1)" "$want" "$name"
  done
}

# Round 74 (SEC-2): an expired token gets HTTP 401 too. A revocation is confirmed only once GitHub
# answered it as done and a read then got HTTP 401 at least a minute before the token's recorded
# expiry; otherwise the token is NOT confirmed, with why, and the clean-up INCOMPLETE.
test_a_401_near_or_after_expiry_never_confirms_a_revocation() {
  local case name setup rc_want line want
  for case in "a failed revocation, then expiry|echo 2 >\$T_TMP/delete-fails; echo 2 >\$T_TMP/expired; echo -120 >\$T_TMP/expiry-2|1|TOKEN token2 NOT confirmed revoked: expired, revocation not confirmed|NOT confirmed: token2 (expired, revocation not confirmed);" \
    "revoked, under a minute before expiry|echo 30 >\$T_TMP/expiry-2|1|TOKEN token2 NOT confirmed revoked: expired, revocation not confirmed|NOT confirmed: token2 (expired, revocation not confirmed);" \
    "a failed revocation, a 401 before expiry|echo 2 >\$T_TMP/delete-fails; echo 2 >\$T_TMP/expired|1|TOKEN token2 NOT confirmed revoked: a read with it gets HTTP 401, but GitHub never answered a revocation of it as done|NOT confirmed: token2 (revocation never answered as done);" \
    "a control's token: a failed revocation, then expiry|echo 4 >\$T_TMP/delete-fails; echo 4 >\$T_TMP/expired; echo -120 >\$T_TMP/expiry-4; AFTER=1|1|note: a control's token could not be revoked, or its revocation not confirmed: control1-token4 (and any later token of control1's; why is not passed on)|NOT confirmed: control1-token4;" \
    "control: revoked, 90s before expiry|echo 90 >\$T_TMP/expiry-2|0|TOKEN token2 revoked: a read with it now gets HTTP 401|CLEANUP DONE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none;"; do
    IFS='|' read -r name setup rc_want line want <<<"$case"
    cleanup_stubs
    AFTER=""
    eval "$setup"
    control_cmd() { request_token '{}'; }
    stopped_run_cleanup 0 "" "${AFTER:+control_token control_cmd || true}"
    assert_exit "$rc_want" "$RC" "$name: the run's status (137: still running after 20s)"
    assert_contains "$OUT" "$line" "$name"
    assert_contains "$(printf '%s\n' "$OUT" | tail -n 1)" "$want" "$name"
    [[ $rc_want -eq 0 ]] || assert_contains "$(printf '%s\n' "$OUT" | tail -n 1)" "CLEANUP INCOMPLETE" "$name"
  done
}

# Round 74 (SEC-2): a token whose expiry isn't known is never confirmed revoked: HTTP 401 may be its
# expiry.
test_a_token_with_an_unknown_expiry_is_never_confirmed() {
  local case name setup after want
  for case in "no expiry in GitHub's answer%echo none >\$T_TMP/expiry-2%%token2 (expiry unknown, revocation not confirmed)" \
    "a token with no record%:%TOKEN=\$(cleanup_token 5)%unnamed (expiry unknown, revocation not confirmed)" \
    "a control's token with no expiry%echo none >\$T_TMP/expiry-4%control_token control_cmd || true%NOT confirmed: control1-token4;"; do
    IFS='%' read -r name setup after want <<<"$case"
    cleanup_stubs
    eval "$setup"
    control_cmd() { request_token '{}'; }
    stopped_run_cleanup 0 "" "$after"
    assert_exit 1 "$RC" "$name: the run's status (137: still running after 20s)"
    assert_contains "$(printf '%s\n' "$OUT" | tail -n 1)" "CLEANUP INCOMPLETE" "$name"
    assert_contains "$(printf '%s\n' "$OUT" | tail -n 1)" "$want" "$name"
    assert_not_contains "$OUT" "CLEANUP DONE" "$name"
  done
}

# Round 53 (C2, SEC-2): each request gets at most what is left of the clean-up's budget, and the
# deadline is checked again between a revocation and its check.
test_the_clean_up_stays_within_its_deadline_when_calls_hang() {
  probe_stubs
  app_gh() { echo "app_gh ${TOKEN:4:4} $*" >>"$T_TMP/calls"; exec /bin/sleep 30; }
  ISSUED=" whole=$(printf 'gh%s_tokA' s) full=$(printf 'gh%s_tokB' s)"
  PROBE_END="done"
  local start out
  start="$(date +%s)"
  CLEANUP_DEADLINE=$((start + 3))
  out="$(probe_finish 0)"
  (($(date +%s) - start <= 6)) || _t_fail "the clean-up ran $(($(date +%s) - start))s past a 3s budget"
  assert_contains "$out" "NOT confirmed: whole full"
  assert_eq "$(call_secs)" 0 "no time left after the deadline"
  CLEANUP_DEADLINE=$(($(date +%s) + 5))
  out="$(call_secs)"
  [[ "$out" == 5 || "$out" == 4 ]] || _t_fail "the budget left, under CALL_SECS: got $out, want 4 or 5"
  CLEANUP_DEADLINE=""
  assert_eq "$(call_secs)" "$CALL_SECS" "outside the clean-up"
  end_stand_in_run
}

test_every_revocation_and_check_is_given_call_secs() {
  probe_stubs
  with_timeout() { echo "with_timeout $1 ${*:2}" >>"$T_TMP/timeouts"; shift; "$@"; }
  local out
  out="$(run_probe)"
  assert_contains "$(cat "$T_TMP/timeouts")" "with_timeout $CALL_SECS app_gh api -X DELETE installation/token"
  assert_contains "$(cat "$T_TMP/timeouts")" "with_timeout $CALL_SECS app_gh api repos/$REPO --jq .full_name"
  assert_contains "$(cat "$T_TMP/timeouts")" "with_timeout $CALL_SECS owner_gh api repos/$REPO2/issues/comments/901"
  assert_eq "$(grep -c 'api -X DELETE installation/token' "$T_TMP/calls")" "$(grep -c 'api -X DELETE installation/token' "$T_TMP/timeouts")" "a revocation without a time limit"
}

# Past the cap, what's left is named as not done, and the summary says which tokens aren't confirmed.
test_the_clean_up_names_what_its_time_cap_left_out() {
  probe_stubs
  ISSUED=" whole=$(printf 'gh%s_tokA' s) full=$(printf 'gh%s_tokB' s)"
  PROBE_CONFIRMED=" $(printf 'gh%s_tokA' s)"
  PROBE_MADE=" issue:7"
  PROBE_END="done"
  CLEANUP_DEADLINE=1
  local out
  out="$(probe_finish 0; echo "rc=$PROBE_RC"; echo "$PROBE_SUMMARY")"
  assert_contains "$out" "TOKEN full not checked: the clean-up's time cap (${CLEANUP_SECS}s) was reached"
  assert_contains "$out" "KEPT issue 7: not read back, the clean-up's time cap"
  assert_contains "$out" "confirmed revoked: whole; NOT confirmed: full"
  assert_contains "$out" "rc=1"
  assert_contains "$out" "NOT confirmed: full"
  assert_not_contains "$(cat "$T_TMP/calls")" "DELETE" "a revocation after the cap"
  end_stand_in_run
}

# Round 55 (C1, SEC-1): every request a2-probe makes is bounded, not only the clean-up's, so a hang
# can't keep a stop signal (deferred by bash until the request returns) from reaching the clean-up.
test_every_request_of_a2_probe_is_bounded() {
  local section bad
  section="$(awk '/^# --- A2 investigation/ { on = 1 } on { print } on && /^cmd_a2_probe\(\)/ { c = 1 } c && /^}$/ { exit }' "$GT")"
  [[ -n "$section" ]] || _t_fail "the a2-probe section was not found"
  bad="$(printf '%s\n' "$section" | grep -E '(^|[^_a-z])(app_gh|owner_gh) ' | grep -vE '^[[:space:]]*#' | grep -v 'with_timeout' || true)"
  assert_eq "$bad" "" "a request of a2-probe without a time limit"
  # shellcheck disable=SC2016 # the literal source text is what's searched for
  assert_contains "$(grep -A3 '^app_rate()' "$GT")" 'with_timeout "$(call_secs)" app_gh api rate_limit' "the allowance read"
  # shellcheck disable=SC2016 # as above
  assert_contains "$(grep -A3 '^jwt_call()' "$GT")" '--max-time "$CALL_SECS"' "the token request"
}

test_a_stop_signal_during_a_hung_request_reaches_the_clean_up_in_time() {
  local out rc=0
  out="$(/bin/bash -p -c 'source "$1"; WORK="$2"; cleanup() { echo "cleanup after $SECONDS s"; }; app_gh() { exec /bin/sleep 30; }; CLEANUP_DEADLINE=$(($(date +%s) + 3)); SECONDS=0; ( /bin/sleep 1; kill -TERM $$ ) & probe_attempt P3 -X POST repos/x/issues; echo continued' _ "$GT" "$T_TMP" 2>&1)" || rc=$?
  assert_exit 143 "$rc"
  assert_not_contains "$out" "continued"
  local secs
  secs="$(printf '%s\n' "$out" | sed -n 's/^cleanup after \([0-9]*\) s$/\1/p')"
  [[ "$secs" =~ ^[0-9]+$ && $secs -le 5 ]] || _t_fail "the clean-up began after '${secs:-never}' s, not within the request's limit (3 s): $out"
}

# Round 55 (SEC-1): a stop revokes first; the stop's branch-and-tag comparison runs afterwards, in the
# bounded clean-up.
test_a_stop_revokes_before_it_reads_the_second_throwaways_branches() {
  probe_stubs
  probe_answer_first "app_gh tok2 api -i -X PUT repos/$REPO2/contents/|0|$(probe_reply 'HTTP/2.0 201 Created' - '{}')"
  local out rc=0 calls del refs
  out="$(run_probe)" || rc=$?
  assert_exit 1 "$rc" "a code change got through"
  calls="$(cat "$T_TMP/calls")"
  del="$(printf '%s\n' "$calls" | grep -n '^app_gh tok2 api -X DELETE installation/token$' | head -n 1 | cut -d: -f1)"
  refs="$(printf '%s\n' "$calls" | grep -n 'matching-refs/heads' | tail -n 1 | cut -d: -f1)"
  [[ -n "$del" && -n "$refs" && $del -lt $refs ]] || _t_fail "the stop read the branches (line ${refs:-none}) before revoking the token (line ${del:-none})"
  assert_contains "$out" "REFS $REPO2 unchanged"
}

# Round 54 (C1): a read-back the time cap left out is a problem: the run can't end DONE.
test_a_read_back_left_out_by_the_time_cap_is_a_problem() {
  probe_stubs
  ISSUED=" whole=$(printf 'gh%s_tokA' s)"
  PROBE_CONFIRMED=" $(printf 'gh%s_tokA' s)"
  PROBE_REVOKED=1 MINTED=1
  PROBE_MADE=" issue:42"
  PROBE_END="done"
  CLEANUP_DEADLINE=1
  local out
  out="$(probe_finish 0; echo "rc=$PROBE_RC"; echo "$PROBE_SUMMARY")"
  assert_contains "$out" "KEPT issue 42: not read back"
  assert_contains "$out" "rc=1"
  assert_contains "$out" "A2 PROBE: DONE WITH 1 PROBLEM(S)"
  end_stand_in_run
}

# Round 54 (SEC-1): a token mint refused is still described when it isn't confirmed revoked:
# GitHub's answer when it was issued (without the token), whether its expiry was checked, and what
# it still reaches.
test_an_unconfirmed_token_mint_refused_is_still_described() {
  probe_stubs
  echo '.permissions.issues = "write" | del(.expires_at)' >"$T_TMP/extra-3"
  echo 99 >"$T_TMP/delete-fails-tok3"
  local out rc=0
  out="$(run_probe)" || rc=$?
  assert_exit 2 "$rc" "P1's token refused by mint"
  assert_contains "$out" "TOKEN P1 NOT confirmed revoked. When it was issued GitHub said: {\"expires_at\":null,\"permissions\":{\"contents\":\"write\",\"issues\":\"write\",\"metadata\":\"read\"}"
  assert_contains "$out" "TOKEN P1 expiry checked within the hour: no"
  assert_contains "$out" "TOKEN P1 still reaches (GET /installation/repositories): $REPO"
  assert_not_contains "$out" "gh$(printf s)_tok" "a token printed"
  # A confirmed one needs no description; one whose expiry was checked says so.
  assert_not_contains "$out" "TOKEN whole NOT confirmed"
  probe_stubs
  echo 99 >"$T_TMP/delete-fails-tok2"
  rc=0; out="$(run_probe)" || rc=$?
  assert_contains "$out" "TOKEN full expiry checked within the hour: yes"
}

# The owner: each token's expiry is checked, not assumed.
test_a2_probe_checks_each_tokens_expiry() {
  local name filter out rc
  load
  for name in "three hours|.expires_at = \"$(date -u -v+3H +%Y-%m-%dT%H:%M:%SZ)\"" \
    "already expired|.expires_at = \"$(date -u -v-1M +%Y-%m-%dT%H:%M:%SZ)\"" \
    "no expiry|del(.expires_at)"; do
    IFS='|' read -r name filter <<<"$name"
    probe_stubs
    echo "$filter" >"$T_TMP/extra-2"
    rc=0; out="$(run_probe)" || rc=$?
    assert_exit 1 "$rc" "$name"
    assert_contains "$out" "PROBE STOP: token full's expiry" "$name"
    assert_not_contains "$(cat "$T_TMP/calls")" "app_gh tok2 api -i" "an attempt with a token expiring $name"
    assert_contains "$out" "TOKEN full revoked: a read with it now gets HTTP 401" "$name"
  done
}

test_a2_probe_reports_a_token_that_still_works_after_revocation() {
  probe_stubs
  : >"$T_TMP/revoked-still-works"
  printf '%s\n' "app_gh tok1 api repos/$REPO --jq .full_name|0|$REPO" "app_gh tok2 api repos/$REPO --jq .full_name|0|$REPO" \
    "app_gh tok3 api repos/$REPO --jq .full_name|0|$REPO" "app_gh tok4 api repos/$REPO --jq .full_name|0|$REPO" >>"$T_TMP/answers"
  local out rc=0
  out="$(run_probe)" || rc=$?
  assert_exit 1 "$rc" "revoked tokens that still work"
  assert_contains "$out" "TOKEN whole revoked, but a read with it did not get HTTP 401"
  assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "A2 PROBE: DONE WITH"
}

test_mint_checks_the_permissions_it_was_asked_for() {
  app_stubs
  INSTALLATION_ID=77
  token_fixture | jq -c '.permissions = {"metadata":"read"}' >"$T_TMP/token.json"
  mint '{"repositories":["forge-frg26-throwaway"],"permissions":{"metadata":"read"}}' narrowed '{"metadata":"read"}' >/dev/null 2>&1 \
    || _t_fail "a token for exactly the permissions asked for was refused"
  local rc=0
  (mint '{"repositories":["forge-frg26-throwaway"],"permissions":{"metadata":"read"}}' narrowed '{"contents":"write","metadata":"read"}') >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "permissions other than asked"
  assert_eq "$MINT_ANSWER" "{\"expires_at\":\"2026-11-01T12:00:00Z\",\"permissions\":{\"metadata\":\"read\"},\"repositories\":[\"$REPO\"],\"repository_selection\":\"selected\"}" "GitHub's answer without the token"
  end_stand_in_run
}

# Round 75 (C1): every GitHub request goes through owner_gh, app_gh, app_git or app_curl, each
# bounded where it starts (an API call 20s, a push or fetch 60s, a clone 120s, a local git command
# 20s), and none runs inside a command substitution or a pipeline or sleeps in the foreground (bash
# holds a stop until those end), a2-probe's own code aside. tests/lib/request-scan.py reads the
# script; a canary shows what it catches.
test_no_request_bypasses_the_wrappers_or_holds_a_stop() {
  local out want
  out="$(python3 -I "$SCAN" "$GT")" || _t_fail "the scan did not run"
  assert_eq "$(printf '%s\n' "$out" | grep -v '^functions:')" "" "a request outside the wrappers, or one that holds a stop"
  assert_contains "$out" " verify_phase " "a function that makes requests through others"
  # shellcheck disable=SC2016 # the canary is script text for the scan, never run
  printf '%s\n' 'owner_gh() { :; }' 'reads() { owner_gh api x; }' 'a() { x="$(owner_gh api y)"; }' 'b() { reads | head -n 1; }' \
    'c() { gh api z; }' 'd() { sleep 3; }' 'e() { y="$(reads)"; }' 'f() { /usr/bin/curl https://x; }' >"$T_TMP/canary.sh"
  out="$(python3 -I "$SCAN" "$T_TMP/canary.sh")"
  for want in "held 3:" "held 4:" "raw 5:" "sleep 6:" "held 7:" "raw 8:"; do assert_contains "$out" "$want" "the canary"; done
  load
  assert_eq "$CALL_SECS ${PUSH_SECS:-none} ${CLONE_SECS:-none}" "20 60 120" "the stated limits"
  if declare -F git_secs >/dev/null; then
    assert_eq "$(git_secs -C d clone -q u d) $(git_secs -C d push origin HEAD) $(git_secs -C d fetch -q) $(git_secs -C d commit -q -m m)" "120 60 60 20" "app git's limit by what it does"
  else
    _t_fail "no git_secs: app git has no limit by what it does"
  fi
  # shellcheck disable=SC2016 # the literal source text is what's searched for
  for want in 'owner_gh() { with_timeout "$(call_secs)" owner_gh_run "$@"; }' 'app_gh() { with_timeout "$(call_secs)" app_gh_run "$@"; }' \
    'app_git() { with_timeout "$(git_secs "$@")" app_git_run "$@"; }' 'app_curl() { with_timeout $((CALL_SECS + 5)) curl "$@"; }' \
    'app_api_curl() { with_timeout "$(call_secs)" app_api_curl_run "$@"; }'; do
    grep -qxF -- "$want" <(sed 's/ *# .*$//' "$GT") || _t_fail "not bounded where it starts: $want"
  done
  end_stand_in_run
}

# Round 75 (C1): the real identities, with stand-in gh, git and curl on PATH. Each logs its call with
# the time to $T_TMP/tools; one whose call contains the text in $T_TMP/hang-on never answers: it waits
# on a child of its own, a sleep of <seconds>. Otherwise each answers at once: a revocation as done, a
# read with a revoked token HTTP 401, mergeability MERGEABLE, anything else with nothing.
request_tools() { # <seconds>
  local t
  # A fresh work folder for each run, as make_work makes one (the clean-up no longer deletes it, round 96).
  [[ "$WORK" != "$T_TMP"/* ]] || rm -rf "$WORK"
  mkdir -p "$T_TMP/bin" "$WORK/home" "$WORK/clone"
  for t in gh git curl; do
    cat >"$T_TMP/bin/$t" <<EOF
#!/bin/bash
# Its folder written in (round 115): the app's attempt runs the fixed curl with an empty environment.
[[ -n "\${T_TMP:-}" ]] || T_TMP="$T_TMP"
printf '%s $t %s\n' "\$(date +%s)" "\$*" >>"\$T_TMP/tools"
h="\$(cat "\$T_TMP/hang-on" 2>/dev/null)"
if [[ -n "\$h" && "$t \$*" == *"\$h"* ]]; then /bin/sleep "\$(cat "\$T_TMP/child")" & wait; exit 1; fi
EOF
  done
  cat >>"$T_TMP/bin/curl" <<'EOF'
# Round 115: the app's attempt through the fixed curl (a copy's APP_API_CURL is this stand-in). A call
# containing the text in fd-probe notes its arguments, its environment (bash's own PWD, SHLVL, _ and
# OLDPWD aside), the hash of the token on its standard input (never the token), every descriptor it
# has open (round 116: all /dev/fd lists, above 254 too; aside: the listing's own, closed once it is
# read, and the one bash opens on this script to read it, 255, shown by lsof to be this file), its pid,
# the process table and lsof's view, then answers with $T_TMP/reply and curl's own report. No
# redirection before the descriptor checks, so the probe adds none of its own.
p="$(cat "$T_TMP/fd-probe" 2>/dev/null)"
if [[ -n "$p" && "$*" == *"$p"* ]]; then
  r="" o=""
  if [[ -p /dev/fd/0 ]]; then r="${r}0 pipe;"; elif [[ /dev/fd/0 -ef /dev/null ]]; then r="${r}0 null;"; else r="${r}0 other;"; fi
  if [[ -p /dev/fd/1 ]]; then r="${r}1 pipe;"; else r="${r}1 other;"; fi
  if [[ /dev/fd/2 -ef /dev/null ]]; then r="${r}2 null;"; else r="${r}2 other;"; fi
  own="$(/usr/sbin/lsof -nP -a -p $$ -d 255 -Fn 2>/dev/null | sed -n 's/^n//p')"
  for f in /dev/fd/*; do
    n="${f##*/}"
    [[ ! ("$n" == 255 && -n "$own" && "$own" -ef "$0") ]] || continue
    if [[ "$n" -gt 2 && -e /dev/fd/$n ]]; then o="$o $n"; fi
  done
  for n in $(printf '%s\n' $o | sort -n); do r="${r}$n open;"; done
  e="$(env | sed -E '/^(PWD|SHLVL|_|OLDPWD)=/d' | sort | tr '\n' ' ')"
  a=""
  while IFS= read -r l; do
    case "$l" in "Authorization: Bearer "*) a="Authorization: Bearer sha256:$(printf '%s' "${l#Authorization: Bearer }" | shasum -a 256 | cut -d' ' -f1)" ;; esac
  done
  printf '%s\n' "$*" >"$T_TMP/probe-args"
  printf '%s\n' "$r" >"$T_TMP/probe-fds"
  printf '%s\n' "${e% }" >"$T_TMP/probe-env"
  printf '%s\n' "$a" >"$T_TMP/probe-auth"
  echo "$$" >"$T_TMP/probe-pid"
  /bin/ps -ax -o pid= -o ppid= >"$T_TMP/probe-ps" 2>&1
  /usr/sbin/lsof -nP -w >"$T_TMP/probe-lsof" 2>&1
  st="$(head -n 1 "$T_TMP/reply" | sed -n 's/^HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p')"
  cat "$T_TMP/reply"
  printf '\n@@FRG26-CURL %s 0 0 %s' "$st" "${*: -1}"
  exit 0
fi
EOF
  cat >>"$T_TMP/bin/gh" <<'EOF'
# Round 114: a call containing the text in fd-probe notes what it was given (its arguments, its
# descriptors 0-30, its pid, the process table and lsof's view of every process), then answers with
# $T_TMP/reply. No redirection before the checks, so the probe adds no descriptor of its own.
p="$(cat "$T_TMP/fd-probe" 2>/dev/null)"
if [[ -n "$p" && "gh $*" == *"$p"* ]]; then
  r=""
  if [[ /dev/fd/0 -ef /dev/null ]]; then r="${r}0 null;"; else r="${r}0 other;"; fi
  if [[ -p /dev/fd/1 ]]; then r="${r}1 pipe;"; else r="${r}1 other;"; fi
  if [[ /dev/fd/2 -ef /dev/null ]]; then r="${r}2 null;"; else r="${r}2 other;"; fi
  for n in 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    if [[ -e /dev/fd/$n ]]; then r="${r}$n open;"; fi
  done
  printf '%s\n' "$*" >"$T_TMP/probe-args"
  printf '%s\n' "$r" >"$T_TMP/probe-fds"
  echo "$$" >"$T_TMP/probe-pid"
  ps -ax -o pid= -o ppid= >"$T_TMP/probe-ps" 2>&1
  lsof -nP -w >"$T_TMP/probe-lsof" 2>&1
  cat "$T_TMP/reply"
  exit 1
fi
# Each answered call's gh settings folder, with the call (round 108): app gh's; empty for the owner's.
printf '%s %s\n' "${GH_CONFIG_DIR:-}" "$*" >>"$T_TMP/gh-config"
# A write whose call contains the text in write-fails is refused, in GitHub's words (round 110).
w="$(cat "$T_TMP/write-fails" 2>/dev/null)"
if [[ -n "$w" && "gh $*" == *"$w"* ]]; then echo "gh: Conflict (HTTP 409)" >&2; exit 1; fi
case "$*" in
  "api -X DELETE installation/token") printf '%s\n' "$GH_TOKEN" >>"$T_TMP/revoked" ;;
  "api repos/$FAKE_REPO --jq .full_name")
    if grep -qxF -- "$GH_TOKEN" "$T_TMP/revoked" 2>/dev/null; then echo "gh: Bad credentials (HTTP 401)" >&2; exit 1; fi
    echo "$FAKE_REPO" ;;
  *"--jq .mergeable") echo MERGEABLE ;;
  # A tidy-up's lists and read-backs (round 77), from files a test writes: the open issues and PRs,
  # a PR's state (OPEN at the first read, then pr-state), the S2 runs of a commit, and the
  # unfinished ones (runs-1 at the first list, then runs-2).
  *"repos/$FAKE_REPO/issues?state=open"*) cat "$T_TMP/open-issues" 2>/dev/null ;;
  *"repos/$FAKE_REPO/pulls?state=open"*) cat "$T_TMP/open-prs" 2>/dev/null ;;
  # A test issue (round 102): its create answers with create-url and ends with create-rc (0 if
  # none); its state, read by its number, is issue-state-<n>, closed if none is written.
  "issue create "*) cat "$T_TMP/create-url" 2>/dev/null; exit "$(cat "$T_TMP/create-rc" 2>/dev/null || echo 0)" ;;
  # A comment answered with its address, as gh prints it (round 110: its expected answer).
  "issue comment "*) echo "https://github.com/$FAKE_REPO/issues/$3#issuecomment-1" ;;
  "api repos/$FAKE_REPO/issues/"*" --jq .state") cat "$T_TMP/issue-state-${2##*/}" 2>/dev/null || echo closed ;;
  # A write's answer (round 109): patch-out, ending with patch-rc (0 if none); with patch-unlink, the
  # request's output file is removed before into reads it (round 110).
  "api -X PATCH "*)
    cat "$T_TMP/patch-out" 2>/dev/null
    [[ ! -f "$T_TMP/patch-unlink" ]] || rm -f "$T_TMP"/work/out.*
    exit "$(cat "$T_TMP/patch-rc" 2>/dev/null || echo 0)" ;;
  "pr view "*"--json state --jq .state")
    if [[ -f "$T_TMP/pr-viewed" ]]; then cat "$T_TMP/pr-state"; else : >"$T_TMP/pr-viewed"; echo OPEN; fi ;;
  *"actions/runs?head_sha="*) [[ ! -f "$T_TMP/runs-1" ]] || echo 1 ;;
  *"actions/runs?per_page=100"*)
    if [[ -f "$T_TMP/runs-listed" ]]; then cat "$T_TMP/runs-2" 2>/dev/null; else : >"$T_TMP/runs-listed"; cat "$T_TMP/runs-1" 2>/dev/null; fi ;;
esac
EOF
  chmod +x "$T_TMP/bin/gh" "$T_TMP/bin/git" "$T_TMP/bin/curl"
  echo "$1" >"$T_TMP/child"
  : >"$T_TMP/tools"
  : >"$T_TMP/gh-config"
  : >"$T_TMP/revoked"
  : >"$T_TMP/hang-on"
  rm -f "$T_TMP/open-issues" "$T_TMP/open-prs" "$T_TMP/pr-viewed" "$T_TMP/pr-state" "$T_TMP/runs-1" "$T_TMP/runs-2" "$T_TMP/runs-listed" \
    "$T_TMP/create-url" "$T_TMP/create-rc" "$T_TMP"/issue-state-* "$T_TMP/patch-out" "$T_TMP/patch-rc" "$T_TMP/patch-unlink" "$T_TMP/write-fails" \
    "$T_TMP/fd-probe" "$T_TMP"/probe-*
  export T_TMP FAKE_REPO="$REPO"
  PATH="$T_TMP/bin:$PATH"
}

still_running() { pgrep -f "sleep $1\$" || true; } # <seconds> — a stand-in's child, by its sleep

# Round 75 (C1): a request that never answers is stopped at its limit with every process under it;
# the run starts no further test action and goes to its clean-up, which says why first. A write is
# named there, its outcome unknown, and is never sent again (the merge, which a test expecting
# "allowed" would otherwise try three times). One case for each kind of request.
test_a_request_that_hangs_stops_at_its_limit_and_stops_the_run() {
  local case name call hang limit kind child last
  child=$(((RANDOM % 900 + 100) * 100)) # this run's own, so no other run's leftover is mistaken for it
  for case in "an owner read, its output used|assert_throwaway|owner.login|CALL_SECS|read" \
    "an app API write|capture app_gh api -X PATCH repos/\$REPO -f description=x|-X PATCH|CALL_SECS|write" \
    "an app gh write|app_pr dev b1 B1|pr create|CALL_SECS|write" \
    "a merge a test would retry|app_merge B16 5 --squash|pr merge|CALL_SECS|write" \
    "an owner write in the run's own shell|owner_gh api -X PUT repos/\$REPO/contents/x -f message=m >/dev/null 2>&1|-X PUT|CALL_SECS|write" \
    "a push|push_branch b1|push -q origin|PUSH_SECS|write" \
    "a clone|app_git clone -q https://github.com/\$REPO.git \$WORK/c2| clone -q https:|CLONE_SECS|read" \
    "a fetch|fresh_from dev b1|fetch -q --prune|PUSH_SECS|read" \
    "a local git command|add_commit tests/x.txt hello|add -- tests/x.txt|CALL_SECS|read" \
    "the app's own request|jwt_call GET app|api.github.com/app|CALL_SECS + 5|read"; do
    IFS='|' read -r name call hang limit kind <<<"$case"
    child=$((child + 1))
    short_copy
    WORK="$T_TMP/work"
    request_tools "$child"
    printf '%s\n' "$hang" >"$T_TMP/hang-on"
    limit=$((limit))
    stopped_run_cleanup 0 "PHASE=open CLONE=\$WORK/clone" "$call; echo NEXT TEST ACTION; owner_gh api next-action"
    assert_exit 2 "$RC" "$name: the run's status (137: still running after 20s)"
    ((SECS + 1 >= limit && SECS <= limit + 3)) || _t_fail "$name: ended after ${SECS}s, not at its ${limit}s limit"
    assert_contains "$OUT" "got no answer within its ${limit}s" "$name"
    assert_contains "$OUT" "the run starts no further test action" "$name"
    assert_not_contains "$OUT" "NEXT TEST ACTION" "$name: a test action after the timeout"
    assert_not_contains "$(cat "$T_TMP/tools")" "next-action" "$name: a request after the timeout"
    assert_eq "$(grep -cF -- "$hang" "$T_TMP/tools")" 1 "$name: how often the request was sent"
    assert_eq "$(still_running "$child")" "" "$name: a process the request started still runs"
    last="$(printf '%s\n' "$OUT" | tail -n 1)"
    if [[ "$kind" == write ]]; then
      assert_contains "$OUT" "(a write: its outcome is unknown; it may have taken effect, and it is not tried again)" "$name"
      assert_contains "$last" "CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none; writes with outcome unknown (not retried, not reconciled: check them on GitHub):" "$name"
      assert_contains "$last" "(no answer within ${limit}s);" "$name"
    else
      assert_eq "$last" "CLEANUP DONE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none; nothing left undone" "$name"
      assert_not_contains "$OUT" "outcome is unknown" "$name"
    fi
  done
}

# Round 75 (C1): a stop (TERM to the run alone) while any kind of request is out acts at once: the
# request is stopped with every process under it, no further test action starts, and the clean-up's
# first revocation comes within 2s; a write the stop cut short is named, its outcome unknown. With the
# real limits (20s and more), so a stop held until the request ended would show.
test_a_stop_during_any_request_reaches_the_clean_up_at_once() {
  local case name call hang kind child first last
  child=$(((RANDOM % 900 + 100) * 100)) # as above
  for case in "an owner read, its output used|assert_throwaway|owner.login|read" \
    "a read in a function whose output is used|verify_phase open|branches/dev|read" \
    "an app API write|capture app_gh api -X PATCH repos/\$REPO -f description=x|-X PATCH|write" \
    "an owner write in the run's own shell|owner_gh api -X PUT repos/\$REPO/contents/x -f message=m >/dev/null 2>&1|-X PUT|write" \
    "a push|push_branch b1|push -q origin|write" \
    "a clone|app_git clone -q https://github.com/\$REPO.git \$WORK/c2| clone -q https:|read" \
    "the app's own request|jwt_call GET app|api.github.com/app|read" \
    "a wait between polls|nap \$child||read" \
    "a tidy-up's issue close (round 77)|echo 11 >\$T_TMP/open-issues; RUN_ID=r1; sweep_issues|issue close 11 |write"; do
    IFS='|' read -r name call hang kind <<<"$case"
    child=$((child + 1))
    load
    end_stand_in_run
    WORK="$T_TMP/work"
    request_tools "$child"
    printf '%s\n' "$hang" >"$T_TMP/hang-on"
    # shellcheck disable=SC2016 # run inside the stopped run: $PPID there is the run itself
    stopped_run_cleanup 0 "PHASE=open CLONE=\$WORK/clone" '/bin/sh -c "/bin/sleep 1; date +%s >$T_TMP/stop-at; kill -TERM \$PPID" & '"$call"'; echo "NEXT TEST ACTION"'
    assert_exit 143 "$RC" "$name: the run's status (137: still running after 20s)"
    ((SECS <= 4)) || _t_fail "$name: ended ${SECS}s after it began; the stop came at 1s"
    assert_not_contains "$OUT" "NEXT TEST ACTION" "$name: a test action after the stop"
    first="$(grep -m 1 'gh api -X DELETE installation/token' "$T_TMP/tools" | cut -d' ' -f1)"
    if [[ -z "$first" ]] || (($(cat "$T_TMP/stop-at") + 2 < first)); then
      _t_fail "$name: the clean-up's first revocation came at ${first:-never}, not within 2s of the stop at $(cat "$T_TMP/stop-at")"
    fi
    [[ -z "$hang" ]] || assert_eq "$(grep -cF -- "$hang" "$T_TMP/tools")" 1 "$name: how often the request was sent"
    assert_eq "$(still_running "$child")" "" "$name: a process the request started still runs"
    last="$(printf '%s\n' "$OUT" | tail -n 1)"
    if [[ "$kind" == write ]]; then
      assert_contains "$last" "CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none; writes with outcome unknown (not retried, not reconciled: check them on GitHub):" "$name"
      assert_contains "$last" "(cut short by the stop);" "$name"
      assert_not_contains "$last" "(no answer within" "$name: a stop named as a timeout"
    else
      assert_eq "$last" "CLEANUP DONE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none; nothing left undone" "$name"
    fi
    # Round 77: the write named with its repository and object.
    [[ "$hang" != "issue close 11 " ]] || assert_contains "$last" " owner gh issue close 11 --repo $REPO (cut short by the stop);" "$name"
  done
}

# Round 76 (C1, SEC-1), an accepted limit for stage 1 commands only, not the production broker
# (owner, 2026-11-18): a stop while a token request is out waits for its answer, at most curl's own
# CALL_SECS, or CALL_SECS + 5 if curl fails to stop (app_curl's backstop; the real limits, 20 and 25
# seconds, are checked above). Then no test action starts and the clean-up runs. A token in the
# answer is registered and its revocation tried and checked; an answer without one is reported as a
# token possibly issued, with the most it can carry and its latest expiry, and the clean-up is
# INCOMPLETE.
test_a_stop_during_a_token_request_waits_only_for_its_answer() {
  local case name mode rc_want max want child t4
  child=$(((RANDOM % 900 + 100) * 100)) # as above
  for case in "curl ends at its own limit|limit|143|CALL_SECS|possibly issued, never received: token4" \
    "curl fails to stop|hang|2|CALL_SECS + 5|possibly issued, never received: token4" \
    "the answer brings a token|token|143|CALL_SECS|CLEANUP DONE: tokens confirmed revoked (HTTP 401): token1 token2 token3 token4;"; do
    IFS='|' read -r name mode rc_want max want <<<"$case"
    child=$((child + 1))
    short_copy
    WORK="$T_TMP/work"
    request_tools "$child"
    max=$((max))
    t4="$(cleanup_token 4)"
    # The stand-in curl: honours --max-time (ends with curl's own timeout, status 28), never
    # answers, or answers after a second with a token.
    cat >"$T_TMP/bin/curl" <<EOF
#!/bin/bash
printf '%s curl %s\n' "\$(date +%s)" "\$*" >>"\$T_TMP/tools"
case "$mode" in
  limit) while [[ \$# -gt 0 && "\$1" != --max-time ]]; do shift; done; /bin/sleep "\$2"; exit 28 ;;
  hang) /bin/sleep "$child" & wait; exit 1 ;;
  token) /bin/sleep 1; printf '{"token":"%s","expires_at":"%s","repository_selection":"selected","permissions":%s,"repositories":[{"full_name":"%s"}]}\nHTTP 201' "$t4" "\$(date -u -v+50M +%Y-%m-%dT%H:%M:%SZ)" '$WANT_PERMS' "$REPO" ;;
esac
EOF
    chmod +x "$T_TMP/bin/curl"
    # shellcheck disable=SC2016 # run inside the stopped run: $PPID there is the run itself
    stopped_run_cleanup 0 "INSTALLATION_ID=77; : >\$WORK/jwt.hdr" '/bin/sh -c "/bin/sleep 0.3; date +%s >$T_TMP/stop-at; kill -TERM \$PPID" & mint_token; echo "NEXT TEST ACTION"'
    assert_exit "$rc_want" "$RC" "$name: the run's status (137: still running after 20s)"
    ((SECS <= max + 3)) || _t_fail "$name: ${SECS}s, over the hold's ${max}s and the clean-up's few"
    assert_not_contains "$OUT" "NEXT TEST ACTION" "$name: a test action after the stop"
    assert_eq "$(grep -c 'curl ' "$T_TMP/tools")" 1 "$name: token requests sent"
    assert_contains "$(printf '%s\n' "$OUT" | tail -n 1)" "$want" "$name"
    if [[ "$mode" != token ]]; then
      assert_contains "$OUT" "TOKEN token4 possibly issued, never received" "$name"
      assert_contains "$OUT" "it carries at most: repositories forge-frg26-throwaway; permissions $WANT_PERMS" "$name"
      assert_contains "$OUT" "its expiry is unknown" "$name: its expiry, unknown"
      assert_not_contains "$OUT" "at the latest" "$name: no deadline"
      assert_contains "$(printf '%s\n' "$OUT" | tail -n 1)" "CLEANUP INCOMPLETE" "$name"
    else
      assert_contains "$OUT" "TOKEN token4 revoked: a read with it now gets HTTP 401" "$name"
    fi
    assert_eq "$(still_running "$child")" "" "$name: a process the request started still runs"
  done
}

# Rounds 76 (C3) and 77: a tidy-up's write that gets no answer in time (closing a test issue or PR,
# cancelling an S2 run) is stopped at its one limit with every process under it, never sent again,
# and doesn't stop the run. A read-back that shows the final state settles it, and is reported; any
# other is named in the last line with its repository and object, its outcome unknown, as a timeout
# (not a stop), and the clean-up is INCOMPLETE. The last case runs in the clean-up itself, to its cap.
# Round 102: an issue is read back by its number too (closed unless issue-state-<n> says otherwise).
test_a_tidy_up_write_that_times_out_is_settled_or_its_outcome_unknown() {
  local case name prep setup call hang exit_rc rc_want child last unknown undo said sha closed left
  child=$(((RANDOM % 900 + 100) * 100)) # as above
  sha="$(printf 'e%.0s' $(seq 1 40))"
  for case in "an issue close, read back open%echo 11 >\$T_TMP/open-issues; echo 12 >>\$T_TMP/open-issues; echo open >\$T_TMP/issue-state-11%RUN_ID=r1%sweep_issues%issue close 11 %0%1" \
    "an issue close, read back closed%echo 11 >\$T_TMP/open-issues%RUN_ID=r1%sweep_issues%issue close 11 %0%0" \
    "a PR close, read back closed%echo 5 >\$T_TMP/open-prs; echo CLOSED >\$T_TMP/pr-state%%sweep_prs%pr close 5 %0%0" \
    "a PR close, read back open%echo 5 >\$T_TMP/open-prs; echo OPEN >\$T_TMP/pr-state%%sweep_prs || true%pr close 5 %0%1" \
    "an S2 cancel, read back finished%echo 9001 >\$T_TMP/runs-1; : >\$T_TMP/runs-2%S2_SHAS=$sha%cancel_waiting_runs%runs/9001/cancel%0%0" \
    "an S2 cancel in the clean-up, still unfinished at its cap%echo 9001 >\$T_TMP/runs-1; echo 9001 >\$T_TMP/runs-2%CANCEL_ON_EXIT=1 S2_SHAS=$sha%%runs/9001/cancel%1%1"; do
    IFS='%' read -r name prep setup call hang exit_rc rc_want <<<"$case"
    child=$((child + 1))
    short_copy
    WORK="$T_TMP/work"
    request_tools "$child"
    eval "$prep"
    printf '%s\n' "$hang" >"$T_TMP/hang-on"
    stopped_run_cleanup "$exit_rc" "$setup" "${call:+$call; echo NEXT STEP}"
    assert_exit "$rc_want" "$RC" "$name: the run's status (137: still running after 20s)"
    ((SECS <= CLEANUP_SECS + 3)) || _t_fail "$name: ended after ${SECS}s; the write's limit is 1s, the clean-up's cap ${CLEANUP_SECS}s"
    assert_eq "$(grep -cF -- "$hang" "$T_TMP/tools")" 1 "$name: how often the write was sent"
    assert_eq "$(still_running "$child")" "" "$name: a process the write started still runs"
    assert_not_contains "$OUT" "the run starts no further test action" "$name: a tidy-up's timeout stopped the run"
    [[ -z "$call" ]] || assert_contains "$OUT" "NEXT STEP" "$name: a tidy-up's timeout stopped the run"
    assert_not_contains "$OUT" "cut short by the stop" "$name: a timeout named as a stop"
    unknown="" undo="" said="" closed="" left=""
    case "$name" in
      *"issue close, read back open")
        unknown="owner gh issue close 11 --repo $REPO (no answer within 1s; read back: open)" undo="closing the test issues"
        said="CLEANUP FAIL issue #11 in $REPO: its close got no answer within 1s, so its outcome is unknown (not tried again; read back: open): check it on GitHub"
        closed="; test issues read back closed: #12" left="; test issues not read back closed: #11"
        assert_eq "$(grep -c 'gh issue close 12 ' "$T_TMP/tools")" 1 "$name: the next issue's close"
        assert_contains "$OUT" "CLEANUP closed test issue #12 in $REPO; read back: closed" "$name: the next issue" ;;
      *"issue close, read back closed")
        said="CLEANUP issue #11 in $REPO: its close got no answer within 1s; read back: closed"
        closed="; test issues read back closed: #11" ;;
      *"read back closed") said="CLEANUP PR #5 in $REPO: its close got no answer within 1s; read back: CLOSED" ;;
      *"read back open")
        unknown="owner gh pr close 5 --repo $REPO (no answer within 1s; read back: OPEN)" undo="closing the open test PRs"
        said="CLEANUP FAIL PR #5 may still be open (state OPEN)" ;;
      *"read back finished") said="CLEANUP S2 run 9001 in $REPO: its cancel got no answer within 1s; read back: no longer unfinished" ;;
      *)
        unknown="owner gh api POST repos/$REPO/actions/runs/9001/cancel (no answer within 1s; read back: still unfinished)" undo="cancelling the waiting S2 runs"
        said="CLEANUP FAIL the clean-up's time cap (${CLEANUP_SECS}s) was reached before the S2 runs in $REPO were cancelled" ;;
    esac
    assert_contains "$OUT" "$said" "$name"
    last="$(printf '%s\n' "$OUT" | tail -n 1)"
    if [[ -n "$unknown" ]]; then
      assert_contains "$last" "CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none$closed; writes with outcome unknown (not retried, not reconciled: check them on GitHub): $unknown$left; not done: $undo (CLEANUP FAIL above);" "$name"
    else
      assert_eq "$last" "CLEANUP DONE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none$closed; nothing left undone" "$name"
      assert_not_contains "$OUT" "outcome is unknown" "$name"
    fi
  done
}

# A short run with the stand-in tools (request_tools): A12's create answers with issue #129, and the
# issue and PR lists answer, with nothing open (a missing list file would be an error).
issue_run() { # <child seconds>
  short_copy
  WORK="$T_TMP/work"
  request_tools "$1"
  echo "https://github.com/$REPO/issues/129" >"$T_TMP/create-url"
  : >"$T_TMP/open-issues"
  : >"$T_TMP/open-prs"
}

# A stop (TERM) to the shell that calls this, which its trap acts on as soon as the call returns. Run
# in the run's own shell: the stand-in sh's parent is that shell (bash 3.2 has no BASHPID).
stop_here() { /bin/sh -c 'kill -TERM $PPID'; }

keep_as_orig() { eval "orig_$1() $(declare -f "$1" | tail -n +2)"; } # <function>: kept as orig_<function>

# The end of cmd_ptests: SWEEP_ON_EXIT is cleared, then the run tidies up itself.
final_sweep() {
  SWEEP_ON_EXIT=""
  sweep_prs
  sweep_issues
}

# Round 102 (owner, 2026-11-24): part 0's A12 issue (#129) stayed open while its step said CLEANUP
# DONE: the list that should have found it didn't show it, or a close didn't take, and nothing was
# read back. Each issue a create returns is tracked by its number, closed at most once with any the
# list finds, and read back by that number; only one read back closed counts, and the last line
# names each. A create with no answer, or answered without a number, stays a write with outcome
# unknown, whatever is closed later. The second throwaway is only read. Review-lens rounds 92 (C1 =
# SEC-3) and 93 (C2 = SEC-1): a create that fails is outcome unknown too, whatever its answer says
# (no refusal is taken from its text). Round 93 (C1): if that record can't be written, the create
# stays pending, still named, and the clean-up is INCOMPLETE. Round 109: the record is in the run's
# memory, so it can't fail to be written; those two cases are gone.
test_a_runs_test_issues_are_closed_once_and_read_back_by_number() {
  local case name prep setup after hang rc_want child last done_line incomplete unknown
  child=$(((RANDOM % 900 + 100) * 100)) # as above
  for case in "the list misses the created issue%%%t_A12; sweep_issues%%0" \
    "the list finds it too, two sweeps%echo 129 >\$T_TMP/open-issues%%t_A12; sweep_issues; sweep_issues%%0" \
    "its close answered, read back open%echo open >\$T_TMP/issue-state-129%%t_A12; sweep_issues%%1" \
    "its read-back gets no answer%%%t_A12; sweep_issues%issues/129 --jq .state%1" \
    "its create gets no answer, the issue made%echo 129 >\$T_TMP/open-issues%SWEEP_ON_EXIT=1%t_A12; echo NEXT TEST ACTION%issue create %2" \
    "its create gets no answer, nothing found%%SWEEP_ON_EXIT=1%t_A12; echo NEXT TEST ACTION%issue create %2" \
    "its create's answer quotes a refusal%echo 'GraphQL: Resource not accessible by integration (createIssue)' >\$T_TMP/create-url; echo 1 >\$T_TMP/create-rc%%t_A12; sweep_issues%%1" \
    "its create fails with an HTTP 403 alone%echo 'HTTP 403: Forbidden (https://api.github.com/graphql)' >\$T_TMP/create-url; echo 1 >\$T_TMP/create-rc%%t_A12; sweep_issues%%1" \
    "its create's connection fails%echo 'Post https://api.github.com/graphql: unexpected EOF' >\$T_TMP/create-url; echo 1 >\$T_TMP/create-rc%%t_A12; sweep_issues%%1" \
    "its create's refusal ends abnormally%echo 'GraphQL: Resource not accessible by integration (createIssue)' >\$T_TMP/create-url; echo 2 >\$T_TMP/create-rc%%t_A12; sweep_issues%%1" \
    "the list fails, the recorded issue still closed%rm -f \$T_TMP/open-issues%%t_A12; sweep_issues%%1" \
    "its create answered without a number%echo 'Creating issue' >\$T_TMP/create-url%%t_A12; sweep_issues%%1" \
    "its create answered with another repository's address%echo 'https://github.com/someone/else/issues/129' >\$T_TMP/create-url%%t_A12; sweep_issues%%1"; do
    IFS='%' read -r name prep setup after hang rc_want <<<"$case"
    child=$((child + 1))
    issue_run "$child"
    eval "$prep"
    printf '%s\n' "$hang" >"$T_TMP/hang-on"
    stopped_run_cleanup 0 "PHASE=permissions RUN_ID=r1 $setup" "$after"
    assert_exit "$rc_want" "$RC" "$name: the run's status (137: still running after 20s)"
    ((SECS <= CLEANUP_SECS + 3)) || _t_fail "$name: ended after ${SECS}s; a call's limit is 1s, the clean-up's cap ${CLEANUP_SECS}s"
    assert_eq "$(still_running "$child")" "" "$name: a process a request started still runs"
    assert_eq "$(grep -c 'gh issue create ' "$T_TMP/tools")" 1 "$name: creates sent"
    assert_not_contains "$(cat "$T_TMP/tools")" "--repo $REPO2" "$name: a write to the second throwaway"
    assert_eq "$(grep -c "repos/$REPO2/issues/[0-9]" "$T_TMP/tools")" 0 "$name: a second-throwaway issue read by number"
    last="$(printf '%s\n' "$OUT" | tail -n 1)"
    done_line="CLEANUP DONE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none; test issues read back closed: #129; nothing left undone"
    incomplete="CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none; test issues not read back closed: #129; not done: closing the test issues (CLEANUP FAIL above);"
    unknown="writes with outcome unknown (not retried, not reconciled: check them on GitHub): app gh issue create --repo $REPO"
    case "$name" in
      "the list misses"*)
        assert_eq "$(grep -c 'gh issue close 129 ' "$T_TMP/tools")" 1 "$name: closes of #129"
        assert_contains "$(cat "$T_TMP/tools")" "gh api repos/$REPO/issues/129 --jq .state" "$name: read back by its number"
        assert_contains "$OUT" "CLEANUP closed test issue #129 in $REPO; read back: closed" "$name"
        assert_eq "$last" "$done_line" "$name" ;;
      *"two sweeps")
        assert_eq "$(grep -c 'gh issue close 129 ' "$T_TMP/tools")" 1 "$name: closes of #129"
        assert_eq "$(grep -c "gh api repos/$REPO/issues/129 --jq .state" "$T_TMP/tools")" 2 "$name: read-backs of #129"
        assert_eq "$last" "$done_line" "$name" ;;
      *"read back open")
        assert_eq "$(grep -c 'gh issue close 129 ' "$T_TMP/tools")" 1 "$name: closes of #129"
        assert_contains "$OUT" "CLEANUP FAIL issue #129 in $REPO may still be open (read back: open): close it on GitHub" "$name"
        # Round 110 (rule (b)): not read back closed, its close stays a write of unknown outcome too.
        assert_contains "$last" "owner gh issue close 129 --repo $REPO (" "$name: its close named outcome unknown"
        assert_contains "$last" "${incomplete#*NOT confirmed: none; }" "$name" ;;
      *"read-back gets no answer")
        assert_eq "$(grep -c 'gh issue close 129 ' "$T_TMP/tools")" 1 "$name: closes of #129"
        assert_eq "$(grep -c "gh api repos/$REPO/issues/129 --jq .state" "$T_TMP/tools")" 1 "$name: read-backs of #129"
        assert_contains "$OUT" "CLEANUP FAIL issue #129 in $REPO may still be open (read back: unreadable): close it on GitHub" "$name"
        assert_contains "$last" "owner gh issue close 129 --repo $REPO (" "$name: its close named outcome unknown"
        assert_contains "$last" "${incomplete#*NOT confirmed: none; }" "$name" ;;
      *"the issue made")
        assert_not_contains "$OUT" "NEXT TEST ACTION" "$name: a test action after the timeout"
        assert_eq "$(grep -c 'gh issue close 129 ' "$T_TMP/tools")" 1 "$name: closes of #129"
        assert_contains "$OUT" "CLEANUP closed test issue #129 in $REPO; read back: closed" "$name"
        assert_contains "$last" "CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none; test issues read back closed: #129; $unknown (no answer within 1s);" "$name" ;;
      *"nothing found")
        assert_not_contains "$OUT" "NEXT TEST ACTION" "$name: a test action after the timeout"
        assert_eq "$(grep -c 'gh issue close ' "$T_TMP/tools")" 0 "$name: closes"
        assert_contains "$last" "CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none; $unknown (no answer within 1s);" "$name" ;;
      *"quotes a refusal" | *"HTTP 403 alone" | *"connection fails" | *"ends abnormally")
        assert_eq "$(grep -c 'gh issue close ' "$T_TMP/tools")" 0 "$name: closes"
        assert_contains "$OUT" "READING A12 gh issue create: fails" "$name"
        assert_contains "$last" "CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none; $unknown (failed, with no issue number: it may have been made);" "$name" ;;
      "the list fails"*)
        assert_eq "$(grep -c 'gh issue close 129 ' "$T_TMP/tools")" 1 "$name: closes of #129"
        assert_contains "$OUT" "CLEANUP FAIL could not list the open issues in $REPO" "$name"
        assert_contains "$last" "CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none; test issues read back closed: #129; not done: closing the test issues (CLEANUP FAIL above);" "$name" ;;
      # Round 111 (review-lens round 99, C1): an answer that isn't the new issue's address here is
      # not one of the run's issues (it may not be the run's), and nothing is done on it.
      *"another repository's address")
        assert_eq "$(grep -c 'gh issue close ' "$T_TMP/tools")" 0 "$name: closes"
        assert_not_contains "$(cat "$T_TMP/tools")" "issue comment" "$name: a comment on an issue not shown to be the run's"
        assert_not_contains "$(cat "$T_TMP/tools")" "issue view" "$name: a view of an issue not shown to be the run's"
        assert_contains "$last" "CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none; $unknown (" "$name"
        assert_contains "$last" "app gh issue create --repo $REPO (answered, not with a new issue's address in $REPO);" "$name" ;;
      *)
        assert_eq "$(grep -c 'gh issue close ' "$T_TMP/tools")" 0 "$name: closes"
        assert_not_contains "$(cat "$T_TMP/tools")" "issue comment" "$name: a comment on an unknown issue"
        assert_contains "$last" "CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none; $unknown (answered without an issue number);" "$name" ;;
    esac
    if [[ "$rc_want" == 0 ]]; then assert_contains "$last" "CLEANUP DONE" "$name"; else assert_not_contains "$OUT" "CLEANUP DONE" "$name"; fi
  done
}

# Review-lens round 92 (C2 = SEC-1, SEC-2), owner 2026-11-24: a stop at each step of a test issue's
# record never ends in a false CLEANUP DONE. The create is pending from before it is sent until its
# number is kept (one command); a stop before its number is kept leaves it outcome unknown. A stop
# before the run's issue sweep has ended (the final one, after SWEEP_ON_EXIT is cleared, included)
# has it resumed in the clean-up, within its cap: a close already started is never sent again, only
# read back, and a read back closed settles it. Any issue the run made or closed that isn't read back
# closed makes the clean-up INCOMPLETE.
test_a_stop_at_each_issue_step_never_ends_in_a_false_done() {
  local case name after rc_want child last done_line unknown closes
  child=$(((RANDOM % 900 + 100) * 100)) # as above
  done_line="CLEANUP DONE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none; test issues read back closed: #129; nothing left undone"
  for case in "before the create is sent" "as the create's answer comes, the list shows it" \
    "as the create's answer comes, the list misses it" "during the create" "after its number is kept" \
    "at the start of the final sweep" "after a close is started, before it is sent" \
    "after a close is sent, before its read-back" "during a close" \
    "a listed issue's close sent, the resumed list omits it"; do
    name="$case"
    child=$((child + 1))
    issue_run "$child"
    after="t_A12; final_sweep"
    rc_want=143
    case "$name" in
      "before the create is sent")
        keep_as_orig try_reading
        try_reading() { if [[ "$2" == "gh issue create" ]]; then stop_here; fi; orig_try_reading "$@"; } ;;
      "as the create's answer comes"*)
        [[ "$name" == *"misses it" ]] || echo 129 >"$T_TMP/open-issues"
        keep_as_orig try_reading
        try_reading() { orig_try_reading "$@"; if [[ "$2" == "gh issue create" ]]; then stop_here; fi; } ;;
      "during the create")
        echo "issue create " >"$T_TMP/hang-on"
        # shellcheck disable=SC2016 # run inside the stopped run: $PPID there is the run itself
        after='/bin/sh -c "/bin/sleep 0.3; kill -TERM \$PPID" & t_A12; final_sweep' ;;
      "after its number is kept")
        keep_as_orig try_reading
        try_reading() { if [[ "$2" == "gh issue comment" ]]; then stop_here; fi; orig_try_reading "$@"; } ;;
      "at the start of the final sweep")
        keep_as_orig sweep_prs
        sweep_prs() { stop_here; orig_sweep_prs; } ;;
      # Round 110: the close goes through capture (its answer stored and checked), whose job runs
      # owner_gh in a subshell; the stop is made where capture runs, in the run's own shell.
      "after a close is started"*)
        echo open >"$T_TMP/issue-state-129"
        keep_as_orig capture
        capture() {
          if [[ "$*" == "owner_gh issue close 129 "* ]]; then echo started >>"$T_TMP/close-calls"; stop_here; return 1; fi
          orig_capture "$@"
        } ;;
      "after a close is sent"*)
        keep_as_orig capture
        capture() {
          local rc=0
          orig_capture "$@" || rc=$?
          if [[ "$*" == "owner_gh issue close 129 "* ]]; then echo sent >>"$T_TMP/close-calls"; stop_here; fi
          return "$rc"
        } ;;
      "during a close")
        echo "issue close 129 " >"$T_TMP/hang-on"
        keep_as_orig capture
        capture() {
          if [[ "$*" == "owner_gh issue close 129 "* ]]; then
            echo sent >>"$T_TMP/close-calls"
            /bin/sh -c '/bin/sleep 0.3; kill -TERM $PPID' &
          fi
          orig_capture "$@"
        } ;;
      "a listed issue's close sent"*)
        # Round 93 (C3 = SEC-2): #77, found only by the list, is closed; the stop comes before its
        # read-back, and the list the resumed sweep reads no longer shows it.
        echo 77 >"$T_TMP/open-issues"
        keep_as_orig capture
        capture() {
          local rc=0
          orig_capture "$@" || rc=$?
          if [[ "$*" == "owner_gh issue close 77 "* ]]; then
            echo sent >>"$T_TMP/close-calls"
            : >"$T_TMP/open-issues"
            stop_here
          fi
          return "$rc"
        } ;;
    esac
    : >"$T_TMP/close-calls"
    stopped_run_cleanup 0 "PHASE=permissions RUN_ID=r1 SWEEP_ON_EXIT=1" "$after; echo NEXT STEP"
    assert_exit "$rc_want" "$RC" "$name: the run's status (137: still running after 20s)"
    ((SECS <= CLEANUP_SECS + 3)) || _t_fail "$name: ended after ${SECS}s; the clean-up's cap is ${CLEANUP_SECS}s"
    assert_not_contains "$OUT" "NEXT STEP" "$name: the run went on after the stop"
    assert_eq "$(still_running "$child")" "" "$name: a process a request started still runs"
    assert_not_contains "$(cat "$T_TMP/tools")" "--repo $REPO2" "$name: a write to the second throwaway"
    last="$(printf '%s\n' "$OUT" | tail -n 1)"
    unknown="writes with outcome unknown (not retried, not reconciled: check them on GitHub): app gh issue create --repo $REPO"
    closes="$(grep -c 'gh issue close 129 ' "$T_TMP/tools")"
    case "$name" in
      "before the create is sent")
        assert_eq "$(grep -c 'gh issue create ' "$T_TMP/tools")" 0 "$name: creates sent"
        assert_contains "$last" "CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none; $unknown (no complete answer registered: it may have been made);" "$name" ;;
      *"the list shows it")
        assert_eq "$closes" 1 "$name: closes of #129"
        assert_contains "$last" "CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none; test issues read back closed: #129; $unknown (no complete answer registered: it may have been made);" "$name" ;;
      *"the list misses it")
        assert_eq "$closes" 0 "$name: closes of #129"
        assert_contains "$last" "CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none; $unknown (no complete answer registered: it may have been made);" "$name" ;;
      "during the create")
        assert_eq "$(grep -c 'gh issue create ' "$T_TMP/tools")" 1 "$name: creates sent"
        assert_contains "$last" "CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none; $unknown (cut short by the stop);" "$name"
        assert_eq "$(grep -o 'app gh issue create' <<<"$last" | wc -l | tr -d ' ')" 1 "$name: the create named once" ;;
      "after its number is kept" | "at the start of the final sweep")
        assert_eq "$closes" 1 "$name: closes of #129"
        assert_eq "$last" "$done_line" "$name" ;;
      "after a close is started"*)
        assert_eq "$closes" 0 "$name: a close started but never sent is not sent later"
        assert_contains "$OUT" "CLEANUP FAIL issue #129 in $REPO may still be open (its close was started earlier in this run, not sent again; read back: open): close it on GitHub" "$name"
        assert_contains "$last" "CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none; test issues not read back closed: #129; not done: closing the test issues (CLEANUP FAIL above);" "$name" ;;
      "a listed issue's close sent"*)
        assert_eq "$closes" 1 "$name: closes of #129"
        assert_eq "$(grep -c 'gh issue close 77 ' "$T_TMP/tools")" 1 "$name: closes of #77 (never sent again)"
        assert_contains "$(cat "$T_TMP/tools")" "gh api repos/$REPO/issues/77 --jq .state" "$name: #77 read back by its number"
        assert_contains "$OUT" "CLEANUP issue #77 in $REPO: its close was started earlier in this run (not sent again); read back: closed" "$name"
        assert_eq "$last" "CLEANUP DONE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none; test issues read back closed: #129 #77; nothing left undone" "$name" ;;
      *)
        assert_eq "$closes" 1 "$name: closes of #129 (never sent again)"
        assert_contains "$OUT" "CLEANUP issue #129 in $REPO: its close was started earlier in this run (not sent again); read back: closed" "$name"
        assert_eq "$last" "$done_line" "$name" ;;
    esac
    case "$name" in
      "at the start of the final sweep" | "after a close"* | "during a close" | "a listed issue's"*)
        assert_contains "$OUT" "PHASE permissions: stopped before its test issues were swept; sweeping them now" "$name: the sweep resumed" ;;
    esac
    case "$name" in
      "after a close"* | "during a close" | "a listed issue's"*) assert_eq "$(wc -l <"$T_TMP/close-calls" | tr -d ' ')" 1 "$name: closes started (the watched issue)" ;;
    esac
  done
}

# Owner, 2026-11-24 (review-lens rounds 95-97), and round 109: the clean-up relies on no folder. The
# run's work folder gone, replaced or unreadable before the clean-up, or gone, replaced or unwritable
# during it, changes nothing it reports: every token is revoked and confirmed within the cap. The
# folder, or what replaced it, is never deleted or written to, its contents untouched, and no fresh
# folder is made. A token whose confirming read gets no answer stays NOT confirmed, the clean-up
# INCOMPLETE.
test_a_lost_or_replaced_work_folder_changes_nothing_the_clean_up_reports() {
  local case name before lose child last n
  child=$(((RANDOM % 900 + 100) * 100)) # as above
  for case in "removed before it%rm -rf \$WORK%" \
    "replaced before it%rm -rf \$WORK; mkdir \$WORK; echo keep >\$WORK/keep%" \
    "unreadable before it%chmod 000 \$WORK%" \
    "removed during it%%rm -rf \"\$WORK\"" \
    "replaced during it%%rm -rf \"\$WORK\"; mkdir \"\$WORK\"; echo keep >\"\$WORK/keep\"" \
    "unwritable during it%%chmod 500 \"\$WORK\"" \
    "removed, no answer to the confirming reads%rm -rf \$WORK%"; do
    IFS='%' read -r name before lose <<<"$case"
    child=$((child + 1))
    short_copy
    WORK="$T_TMP/work"
    request_tools "$child"
    mkdir -p "$T_TMP/tmpd"
    [[ "$name" != *"no answer"* ]] || printf '%s\n' '--jq .full_name' >"$T_TMP/hang-on"
    # The change during the clean-up comes once it has begun.
    LOSE="$lose"
    keep_as_orig settle_register
    settle_register() { eval "$LOSE"; orig_settle_register; }
    stopped_run_cleanup 0 "WORK_MADE=\$WORK; TMPDIR=$T_TMP/tmpd" "$before"
    chmod -R u+rwx "$T_TMP/work" 2>/dev/null
    ((SECS <= REVOKE_SECS + CLEANUP_SECS + 3)) || _t_fail "$name: ended after ${SECS}s"
    last="$(printf '%s\n' "$OUT" | tail -n 1)"
    n="$(grep -c 'gh api -X DELETE installation/token' "$T_TMP/tools")"
    ((n >= 3)) || _t_fail "$name: revocations sent: $n, not every token's"
    if [[ "$name" == *"no answer"* ]]; then
      assert_exit 1 "$RC" "$name: the run's status (137: still running after 20s)"
      assert_not_contains "$OUT" "revoked: a read with it now gets HTTP 401" "$name: a revocation claimed confirmed"
      assert_contains "$last" "CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): none; NOT confirmed: token1 token2 token3;" "$name"
    else
      assert_exit 0 "$RC" "$name: the run's status (137: still running after 20s)"
      assert_eq "$last" "CLEANUP DONE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none; nothing left undone" "$name"
    fi
    case "$name" in
      "replaced"*)
        assert_eq "$(ls -A "$WORK")" "keep" "$name: the replacement's contents"
        assert_eq "$(cat "$WORK/keep")" "keep" "$name: the replacement's file" ;;
      "unreadable"* | "unwritable"*) assert_eq "$(ls -A "$WORK")" "$(ls -A "$T_TMP/work")" "$name" ;;
    esac
    # Never deleted (owner, round 96), and said so; no fresh folder made.
    assert_contains "$OUT" "CLEANUP this run's work folder $WORK is not deleted: it stays, private, for you to remove later once approved (nothing in it is shown)" "$name"
    assert_eq "$(ls -A "$T_TMP/tmpd")" "" "$name: a folder or file made in TMPDIR"
    assert_eq "$(grep -E 'installation/token$|--jq \.full_name$' "$T_TMP/gh-config" | grep -vc '^/var/empty ' || true)" 0 "$name: app gh calls with settings from a folder"
    rm -rf "$T_TMP/work" "$T_TMP/tmpd"
  done
}

timeout_case() { # <name> — in a subshell: the folder as named, then a hang, owner_gh's, and an own status
  local rc late
  WORK="$T_TMP/work" STOPS_HELD="" TMPDIR="$T_TMP/tmpd"
  case "$1" in
    "no folder") WORK=""; chmod 500 "$T_TMP/tmpd" ;;
    "a missing folder") WORK="$T_TMP/gone" ;;
    "an unwritable folder") chmod 500 "$T_TMP/work" ;;
    *"in the clean-up"*) WORK="" STOPS_HELD=1; chmod 500 "$T_TMP/tmpd" ;;
  esac
  rc=0; with_timeout 1 /bin/sleep 10 || rc=$?
  echo "hang rc=$rc timed=[$TIMED_OUT]"
  owner_gh_run() { /bin/sleep 10; }
  CLEANUP_DEADLINE=$(($(date +%s) + 60)) late=""
  owner_gh api -X POST "repos/$REPO/actions/runs/1/cancel" >/dev/null 2>&1 || late="$TIMED_OUT"
  echo "owner_gh late=[$late]"
  rc=0; with_timeout 5 /bin/sh -c 'exit 3' || rc=$?
  echo "own rc=$rc timed=[$TIMED_OUT]"
}
# Review-lens round 97 (SEC-1, SEC-3), owner 2026-11-25: a timeout is told by the command's own
# status, never by a file: the watchdog stops it with KILL. So it is reported (124, TIMED_OUT) with a
# usable folder, none, or one that can't be used, and reaches owner_gh's caller as the clean-up's
# writes use it (late="$TIMED_OUT"). A command's own status is kept, and no file is made.
test_a_timeout_is_told_by_its_status_with_or_without_a_folder() {
  local name out
  short_copy
  for name in "a usable folder" "no folder" "a missing folder" "an unwritable folder" "no folder in the clean-up"; do
    rm -rf "$T_TMP/work" "$T_TMP/tmpd"
    mkdir -m 700 "$T_TMP/work" "$T_TMP/tmpd"
    out="$(timeout_case "$name")"
    chmod 700 "$T_TMP/work" "$T_TMP/tmpd"
    assert_contains "$out" "hang rc=124 timed=[1]" "$name: a hang"
    assert_contains "$out" "owner_gh late=[1]" "$name: owner_gh's caller"
    assert_contains "$out" "own rc=3 timed=[]" "$name: a command's own status"
    assert_eq "$(ls -A "$T_TMP/tmpd")" "" "$name: a file left in TMPDIR"
  done
  assert_not_contains "$(declare -f with_timeout)" "timeout-" "with_timeout makes a mark file"
}

# Review-lens round 97 (SEC-3), owner 2026-11-25: with the run's folder gone before the clean-up, an
# S2 cancellation with no answer is still told as a timeout: it is sent once, never again at the
# polls that follow, and named (round 109: from the run's memory); the tokens are still revoked, and
# the clean-up ends within its cap, INCOMPLETE.
test_a_cancel_with_no_answer_is_sent_once_with_no_usable_folder() {
  local child sha last n
  child=$(((RANDOM % 900 + 100) * 100)) # as above
  sha="$(printf 'e%.0s' $(seq 1 40))"
  short_copy
  WORK="$T_TMP/work"
  request_tools "$child"
  echo 9001 >"$T_TMP/runs-1"
  echo 9001 >"$T_TMP/runs-2"
  echo runs/9001/cancel >"$T_TMP/hang-on"
  stopped_run_cleanup 1 "WORK_MADE=\$WORK; CANCEL_ON_EXIT=1 S2_SHAS=$sha" "rm -rf \$WORK"
  assert_exit 1 "$RC" "the run's status (137: still running after 20s)"
  ((SECS <= REVOKE_SECS + CLEANUP_SECS + 3)) || _t_fail "ended after ${SECS}s"
  assert_eq "$(grep -cF runs/9001/cancel "$T_TMP/tools")" 1 "how often the cancel was sent"
  assert_eq "$(still_running "$child")" "" "a process the cancel started still runs"
  n="$(grep -c 'gh api -X DELETE installation/token' "$T_TMP/tools")"
  ((n >= 3)) || _t_fail "revocations sent: $n, not every token's"
  last="$(printf '%s\n' "$OUT" | tail -n 1)"
  assert_contains "$last" "CLEANUP INCOMPLETE:" "the summary"
  assert_contains "$last" "owner gh api POST repos/$REPO/actions/runs/9001/cancel (no answer within 1s; read back: still unfinished);" "the cancel's record"
  assert_contains "$last" "not done: cancelling the waiting S2 runs (CLEANUP FAIL above);" "the summary"
}

# Review-lens round 97 (C1, C2 = SEC-1), owner 2026-11-25: where stops are ignored (a clean-up) or held
# (round 109: a token request), into holds each answer in memory: no file is made, read or removed,
# in the work folder or anywhere, and with no folder at all the request is still sent. Its status and
# error output are kept. Elsewhere, into still uses a private file in the work folder, so a stop acts
# at once (round 75).
test_the_clean_up_holds_each_answer_in_memory() {
  local v rc held
  load
  for held in STOPS_HELD DEFERRING; do
    rm -rf "$T_TMP/work" "$T_TMP/tmpd"
    WORK="$T_TMP/work"
    mkdir -m 700 "$WORK" "$T_TMP/tmpd"
    TMPDIR="$T_TMP/tmpd" STOPS_HELD="" DEFERRING=""
    printf -v "$held" '%s' 1
    rc=0
    # shellcheck disable=SC2016 # the inner script is single-quoted on purpose: sh expands it
    into v /bin/sh -c 'ls -A "$1"; echo -; ls -A "$2"; echo err >&2; exit 3' _ "$WORK" "$T_TMP/tmpd" 2>"$T_TMP/err" || rc=$?
    assert_exit 3 "$rc" "$held: the command's status"
    assert_eq "$v" "-" "$held: the folders while it ran (a file made for its answer)"
    assert_eq "$(cat "$T_TMP/err")" err "$held: its error output"
    into -2 v /bin/sh -c 'echo out; echo err >&2'
    assert_eq "$v" "out"$'\n'"err" "$held: -2: both"
    WORK=""
    rc=0
    into v /bin/sh -c 'echo sent' || rc=$?
    assert_exit 0 "$rc" "$held: no folder: the command's status"
    assert_eq "$v" sent "$held: no folder: its answer"
    capture /bin/sh -c 'echo answer'
    assert_eq "$LAST_OUT" answer "$held: capture, no folder"
    assert_eq "$(ls -A "$T_TMP/tmpd")" "" "$held: a file left in TMPDIR"
  done
  WORK="$T_TMP/work" STOPS_HELD="" DEFERRING=""
  # shellcheck disable=SC2016 # as above
  into v /bin/sh -c 'ls -A "$1"' _ "$WORK"
  assert_contains "$v" "out." "outside the clean-up: its private file"
  assert_eq "$(ls -A "$WORK")" "" "outside the clean-up: its file removed"
  end_stand_in_run
}

# Round 119 (review-lens round 105, C2; owner): into -b keeps every byte of an answer, its trailing
# newlines too, through its private file or held in memory; the status is the command's, apart from the
# answer. In memory, an answer whose end can't be told (the job ended the shell it ran in before its
# end mark) is unread, never taken as whole. Without -b, into is unchanged: trailing newlines dropped.
test_into_b_keeps_every_byte_of_an_answer() {
  local v rc mode
  load
  quit() { printf 'part\n\n'; exit 4; }
  for mode in file STOPS_HELD DEFERRING; do
    rm -rf "$T_TMP/work"
    mkdir -m 700 "$T_TMP/work"
    WORK="$T_TMP/work" STOPS_HELD="" DEFERRING=""
    [[ "$mode" == file ]] || printf -v "$mode" '%s' 1
    rc=0
    into -b v printf 'a\n\n\r\n' || rc=$?
    assert_exit 0 "$rc" "$mode: the command's status"
    assert_eq "$v" $'a\n\n\r\n' "$mode: every byte"
    rc=0
    into -b v /bin/sh -c 'printf "x\n"; exit 3' || rc=$?
    assert_exit 3 "$rc" "$mode: a failure's status"
    assert_eq "$v" $'x\n' "$mode: a failure's answer, kept apart from its status"
    into -b v printf ''
    assert_eq "$v" "" "$mode: an empty answer"
    into -b v printf 'ends in a dot.'
    assert_eq "$v" "ends in a dot." "$mode: an answer ending in a dot"
    into v printf 'a\n\n'
    assert_eq "$v" a "$mode: without -b, trailing newlines dropped"
    rc=0
    into -b v quit || rc=$?
    assert_exit 4 "$rc" "$mode: a job ending its shell: the status"
    if [[ "$mode" == file ]]; then
      assert_eq "$v" $'part\n\n' "$mode: a job ending its shell: its file whole"
    else
      assert_eq "$v" "" "$mode: a job ending its shell: unread, not cut"
    fi
    assert_eq "$(ls -A "$T_TMP/work")" "" "$mode: a file left"
  done
  STOPS_HELD="" DEFERRING=""
  end_stand_in_run
}

# Review-lens round 94 (C1 = SEC-1), owner 2026-11-24: a create still pending is named whether or not
# the work folder is there, never an empty list. Round 109: the records are the run's memory, so a
# folder there or gone adds nothing and loses nothing.
test_a_pending_create_or_a_lost_work_folder_is_never_an_empty_list() {
  load
  end_stand_in_run
  local out rc pending where
  pending="writes with outcome unknown (not retried, not reconciled: check them on GitHub): app gh issue create --repo $REPO (no complete answer registered: it may have been made);"
  for where in "" "$T_TMP/gone" "$T_TMP/here"; do
    [[ "$where" != "$T_TMP/here" ]] || mkdir -p "$where"
    WORK="$where" WORK_MADE="$where" PENDING_CREATE="app gh issue create --repo $REPO"
    rc=0; out="$(cleanup_summary)" || rc=$?
    assert_exit 1 "$rc" "${where:-no folder}: a create pending"
    assert_contains "$out" "CLEANUP INCOMPLETE: tokens confirmed revoked (HTTP 401): none; NOT confirmed: none; $pending" "${where:-no folder}"
    PENDING_CREATE=""
    rc=0; out="$(cleanup_summary)" || rc=$?
    assert_exit 0 "$rc" "${where:-no folder}: nothing pending"
    assert_eq "$out" "" "${where:-no folder}: nothing to report"
  done
}

# Review-lens round 92 (C3 = SEC-4): an issue or PR is this run's only if its title ends with this
# run's id in its own parentheses; another run's id that starts with it, or contains it, is not.
# shellcheck disable=SC2016 # sweep_issues' own source text is searched for literally
test_the_issue_selectors_match_the_exact_run_id() {
  load
  local json
  json='[{"number":1,"title":"FRG-26 A12 (20261124T194646Z-12)"},
    {"number":2,"title":"FRG-26 A12 (20261124T194646Z-123)"},
    {"number":3,"title":"FRG-26 A12 (x20261124T194646Z-12)"},
    {"number":4,"title":"FRG-26 A12 (20261124T194646Z-12) again"},
    {"number":5,"title":"FRG-26 A12 (20261124T194646Z-1)"},
    {"number":6,"title":"FRG-26 A2 probe P4 (20261124T194646Z-12)","pull_request":{"url":"x"}},
    {"number":7,"title":"Other (20261124T194646Z-12)"}]'
  RUN_ID=20261124T194646Z-12
  assert_eq "$(jq -r "$(run_issues_jq)" <<<"$json" | tr '\n' ' ')" "1 " "this run's issues in the throwaway"
  assert_eq "$(jq -r "$(run_items_jq)" <<<"$json" | tr '\n' ' ')" "1 6 " "this run's issues and PRs in the second throwaway"
  RUN_ID=20261124T194646Z-1
  assert_eq "$(jq -r "$(run_issues_jq)" <<<"$json" | tr '\n' ' ')" "5 " "a run whose id prefixes another's"
  # Both sweeps use them.
  assert_contains "$(declare -f sweep_issues)" '--jq "$(run_issues_jq)"'
  assert_contains "$(declare -f sweep_issues)" '--jq "$(run_items_jq)"'
  end_stand_in_run
}

# Owner, 2026-11-23 (review-lens round 90, C1 = SEC-1): a token request with no complete answer may have been
# issued at a time this run can't know, so no wall-clock expiry is stated for it, only that it lasts an hour from
# its issue; the record keeps when the request was sent, by this Mac's clock. An expiry GitHub returned is kept
# exactly as GitHub gave it.
test_an_unreceived_tokens_expiry_is_unknown_and_a_received_ones_is_githubs() {
  local out rc=0 tok sent at before after
  mint_with_curl "" "curl: (28) Operation timed out" 000 28
  before="$(date +%s)"
  out="$( (MINT_LABEL=P1; trap 'declare -p UNRECEIVED' EXIT; mint '{"repositories":["forge-frg26-throwaway"],"permissions":{"metadata":"read"}}' narrowed '{"metadata":"read"}') 2>&1)" || rc=$?
  after="$(date +%s)"
  assert_exit 2 "$rc" "no answer"
  sent="$(printf '%s\n' "$out" | sed -n 's/^declare -- UNRECEIVED="P1 \([^ ]*\) .*/\1/p')"
  at="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$sent" +%s 2>/dev/null)" || at=""
  [[ "$at" =~ ^[0-9]+$ && $at -ge $((before - 1)) && $at -le $((after + 1)) ]] \
    || _t_fail "the record's time '$sent' is not when the request was sent"
  assert_contains "$out" "if so its expiry is unknown: one hour from when GitHub issued it (the request was sent at $sent by this Mac's clock)" "mint's message"
  assert_not_contains "$out" "at the latest" "a deadline in mint's message"
  tok="$(new_token)"
  mint_with_curl "{\"token\":\"$tok\",\"expires_at\":\"2026-11-12T13:37:00Z\",\"permissions\":{\"metadata\":\"read\"},\"repository_selection\":\"selected\",\"repositories\":[{\"full_name\":\"$REPO\"}]}" "" 201 0
  out="$( (MINT_LABEL=P3; trap revoke_outstanding EXIT; mint '{"repositories":["forge-frg26-throwaway"],"permissions":{"metadata":"read"}}' narrowed '{"metadata":"read"}'; printf 'answer=%s\nmeta=%s\n' "$MINT_ANSWER" "$ISSUED_META") 2>&1)" || rc=$?
  assert_contains "$out" 'answer={"expires_at":"2026-11-12T13:37:00Z",' "GitHub's expiry, as GitHub gave it"
  assert_contains "$out" 'meta=P3 {"expires_at":"2026-11-12T13:37:00Z",' "GitHub's expiry, kept for the clean-up"
  assert_not_contains "$out" "$tok" "the token printed"
}

# The same for the clean-up's report (after the test above in this file: its quoted record would otherwise
# reach the trap there in shellcheck's reading, SC2089/SC2090).
test_an_unreceived_tokens_expiry_is_unknown_in_the_clean_ups_report() {
  local out
  probe_stubs
  ISSUED=""
  UNRECEIVED='P1 2026-11-12T12:01:00Z {"permissions":{"metadata":"read"},"repositories":["forge-frg26-throwaway"]}
'
  PROBE_END=""
  out="$(probe_finish 2; echo "$PROBE_SUMMARY")"
  assert_contains "$out" "TOKEN P1 possibly issued, never received"
  assert_contains "$out" "its expiry is unknown: GitHub gives such a token one hour from when it issues it, and this run doesn't know whether or when that was (the request was sent at 2026-11-12T12:01:00Z by this Mac's clock)" "the clean-up's report"
  assert_not_contains "$out" "at the latest" "a deadline in the clean-up's report"
  assert_not_contains "$out" "expires by" "a deadline in the clean-up's report"
  end_stand_in_run
}

# Round 109 (owner, 2026-11-25): a write's pending state is kept in the run's own shell, never in a
# file: noted before it is sent, and named in the last line, the clean-up INCOMPLETE, unless settled;
# nothing about it is in the work folder, so removing the folder before the clean-up loses nothing.
# Round 110 (owner: rule (b)): it is settled only by status 0 with the answer its caller declared it
# expects (write_checked); a write with none declared stays unknown even at status 0, and so does one
# that failed, even with GitHub's own refusal, or whose answer is empty, not as expected, or can't be
# read back. Only an authoritative read-back resolves it.
test_a_write_is_pending_in_the_run_until_a_validated_answer_is_stored() {
  local case name call answer rc rc_want unknown last child
  child=$(((RANDOM % 900 + 100) * 100)) # as above
  for case in "answered as expected|checked|{\"full_name\":\"REPO_NAME\"}|0|0|" \
    "answered, nothing expected declared|plain|{\"full_name\":\"REPO_NAME\"}|0|1|answered; no expected answer to check it against" \
    "answered, not as expected|checked|{\"full_name\":\"other\"}|0|1|answered, not as expected" \
    "a malformed answer|checked|not json|0|1|answered, not as expected" \
    "an empty answer|checked||0|1|an empty answer" \
    "its answer lost before it was read|lost|{\"full_name\":\"REPO_NAME\"}|0|1|its answer could not be read" \
    "refused in GitHub's words|checked|gh: Resource not accessible by integration (HTTP 403)|1|1|failed: status 1" \
    "a transport error|plain|error connecting to api.github.com|1|1|failed: status 1"; do
    IFS='|' read -r name call answer rc rc_want unknown <<<"$case"
    child=$((child + 1))
    short_copy
    WORK="$T_TMP/work"
    request_tools "$child"
    CHECK="json:.full_name == \"$REPO\""
    answer="${answer//REPO_NAME/$REPO}"
    printf '%s\n' "$answer" >"$T_TMP/patch-out"
    echo "$rc" >"$T_TMP/patch-rc"
    [[ "$call" != lost ]] || : >"$T_TMP/patch-unlink"
    [[ -z "$unknown" ]] || unknown="app gh api PATCH repos/$REPO ($unknown)"
    if [[ "$call" == plain ]]; then
      call="capture app_gh api -X PATCH repos/\$REPO -f description=x || true"
    else
      call="write_checked \"\$CHECK\" app_gh api -X PATCH repos/\$REPO -f description=x || true"
    fi
    stopped_run_cleanup 0 "" "$call; rm -rf \$WORK"
    assert_exit "$rc_want" "$RC" "$name: the run's status (137: still running after 20s)"
    last="$(printf '%s\n' "$OUT" | tail -n 1)"
    assert_eq "$(grep -c 'gh api -X PATCH' "$T_TMP/tools")" 1 "$name: how often the write was sent"
    if [[ -n "$unknown" ]]; then
      assert_contains "$last" "CLEANUP INCOMPLETE:" "$name"
      assert_contains "$last" "writes with outcome unknown (not retried, not reconciled: check them on GitHub): $unknown;" "$name"
    else
      assert_eq "$last" "CLEANUP DONE: tokens confirmed revoked (HTTP 401): token1 token2 token3; NOT confirmed: none; nothing left undone" "$name"
    fi
    rm -rf "$T_TMP/work"
  done
}

# Round 109: a request with no answer within its limit still stops the run, the request named, and a
# write among them named outcome unknown, with no record written to the work folder: no timed-out,
# unsettled or out-write file. The same for a read inside a function run through into.
test_a_request_with_no_answer_stops_the_run_and_writes_no_record() {
  local case name call hang rest child last f
  child=$(((RANDOM % 900 + 100) * 100)) # as above
  for case in "a write|capture app_gh api -X PATCH repos/\$REPO -f description=x|-X PATCH|app gh api PATCH repos/\$REPO (no answer within 1s);" \
    "a read inside a function|into v branch_state dev|branches/dev|"; do
    IFS='|' read -r name call hang rest <<<"$case"
    child=$((child + 1))
    short_copy
    WORK="$T_TMP/work"
    request_tools "$child"
    printf '%s\n' "$hang" >"$T_TMP/hang-on"
    eval "rest=\"$rest\""
    stopped_run_cleanup 0 "" "$call; echo NEXT TEST ACTION"
    assert_exit 2 "$RC" "$name: the run's status (137: still running after 20s)"
    assert_contains "$OUT" "STOPPED:" "$name"
    assert_not_contains "$OUT" "NEXT TEST ACTION" "$name: a test action after the timeout"
    for f in "$WORK"/timed-out "$WORK"/unsettled "$WORK"/out-write.*; do
      [[ ! -e "$f" ]] || _t_fail "$name: a record file in the work folder: ${f##*/}"
    done
    last="$(printf '%s\n' "$OUT" | tail -n 1)"
    [[ -z "$rest" ]] || assert_contains "$last" "$rest" "$name"
    rm -rf "$T_TMP/work"
  done
}

# Round 109: a write a stop cuts short is named from the run's own memory, even with the work folder
# removed while it was out.
test_a_write_cut_short_by_a_stop_is_named_from_the_runs_memory() {
  local child last
  child=$(((RANDOM % 900 + 100) * 100)) # as above
  short_copy
  WORK="$T_TMP/work"
  request_tools "$child"
  printf '%s\n' "-X PATCH" >"$T_TMP/hang-on"
  # shellcheck disable=SC2016 # run inside the stopped run: $PPID there is the run itself
  stopped_run_cleanup 0 "" '/bin/sh -c "/bin/sleep 0.5; rm -rf $WORK; kill -TERM \$PPID" & capture app_gh api -X PATCH repos/$REPO -f description=x; echo NEXT TEST ACTION'
  assert_exit 143 "$RC" "the run's status (137: still running after 20s)"
  assert_not_contains "$OUT" "NEXT TEST ACTION"
  last="$(printf '%s\n' "$OUT" | tail -n 1)"
  assert_contains "$last" "CLEANUP INCOMPLETE:"
  assert_contains "$last" "app gh api PATCH repos/$REPO (cut short by the stop);" "the write cut short"
  assert_not_contains "$last" "can't be read" "a record read from a folder"
}

# Round 109, then round 110 (owner, 2026-11-25): a control's result is decided only by its own exit
# status, which its wrapper (the only holder of the pipe, running no program) writes as its second and
# last line; the control holds no pipe at all. So a "report" its own code or a program it starts
# writes to any descriptor changes nothing: the decision stays what its real status says. A control
# that dies before its clean-up has no result; one whose command fails still reports its tokens.
test_a_controls_result_counts_only_whole_and_well_formed_through_its_pipe() {
  local case name cmd works rc_want want bad
  for case in "well formed|good_cmd||0|NOT confirmed: none;|" \
    "its token still works|good_cmd|4|1|NOT confirmed: control1-token4;|control1-token4" \
    "its own code writes a forged report to every descriptor|self_forge_cmd|4|1|NOT confirmed: control1-token4;|control1-token4" \
    "a program it starts writes a forged report|forge_cmd|4|1|NOT confirmed: control1-token4;|control1-token4" \
    "its command fails|fail_cmd||0|NOT confirmed: none;|" \
    "it dies before it reports|vanish_cmd||1|NOT confirmed: control1 (no result);|control1-token4"; do
    IFS='|' read -r name cmd works rc_want want bad <<<"$case"
    cleanup_stubs
    printf '%s\n' "$works" >"$T_TMP/works"
    : >"$T_TMP/leak"
    mkdir -p "$T_TMP/bin"
    # shellcheck disable=SC2016 # the stand-in's own lines are single-quoted on purpose: it expands them
    printf '%s\n' '#!/bin/bash' \
      'for n in 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do' \
      '  [[ -p /dev/fd/$n ]] || continue' \
      '  { echo "CONTROL control1 status 81" >&$n; } 2>/dev/null && echo "gh fd $n" >>"$T_TMP/leak"' \
      'done' 'exit 0' >"$T_TMP/bin/gh"
    chmod 700 "$T_TMP/bin/gh"
    export T_TMP
    good_cmd() { request_token '{}'; ls -A "$WORK" >"$T_TMP/during"; }
    self_forge_cmd() {
      local n
      request_token '{}'
      for n in 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        [[ -p /dev/fd/$n ]] || continue
        { echo "CONTROL control1 status 81" >&"$n"; } 2>/dev/null && echo "control fd $n" >>"$T_TMP/self"
      done
      return 0
    }
    forge_cmd() { request_token '{}'; PATH="$T_TMP/bin:$PATH" with_timeout 5 app_gh_run api rate_limit >/dev/null 2>&1; }
    fail_cmd() { request_token '{}'; return 9; }
    vanish_cmd() { request_token '{}'; /bin/sh -c 'kill -KILL $PPID'; /bin/sleep 1; }
    : >"$T_TMP/self"
    stopped_run_cleanup 0 "" "control_token $cmd || true"
    assert_exit "$rc_want" "$RC" "$name: the run's status (137: still running after 20s)"
    ((SECS <= REVOKE_SECS + CLEANUP_SECS + 3)) || _t_fail "$name: took ${SECS}s"
    assert_contains "$(printf '%s\n' "$OUT" | tail -n 1)" "$want" "$name"
    [[ -z "$bad" ]] || assert_not_contains "$(printf '%s\n' "$OUT" | tail -n 1 | sed 's/NOT confirmed:.*//')" "$bad" "$name: confirmed"
    case "$name" in
      "well formed") assert_eq "$(grep -c '^control\.' "$T_TMP/during" || true)" 0 "$name: a control's record file in the work folder" ;;
      "a program"*) assert_eq "$(cat "$T_TMP/leak")" "" "$name: a started program had a pipe open to write to" ;;
      "its own code"*) assert_eq "$(cat "$T_TMP/self")" "" "$name: the control's own shell had a pipe open to write to" ;;
    esac
  done
}

# Round 109 (owner, 2026-11-25): the app's JWT never reaches a file or an argument: it goes to curl on
# its standard input, through a pipe. A token request's answer, which holds the new token, is held in
# memory, never in a file, even while curl runs; nothing is left in the work folder or the temp folder.
test_the_jwt_and_a_token_answer_never_reach_a_file_or_an_argument() {
  local tok
  load
  app_files 123456
  SECRETS="$FRG26_SECRETS" APP_KEY="$FRG26_APP_KEY"
  WORK="$T_TMP/work"
  mkdir -m 700 "$WORK" "$T_TMP/tmpd"
  TMPDIR="$T_TMP/tmpd"
  load_app
  INSTALLATION_ID=77
  tok="$(new_token)"
  mkdir -p "$T_TMP/bin"
  # shellcheck disable=SC2016 # as above
  printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$@" >"$T_TMP/curl-args"' 'cat >"$T_TMP/curl-stdin"' \
    'printf "%s" "$CURL_BODY"' '/bin/sleep 0.3' \
    'grep -rl -- "$CURL_TOK" "$T_TMP/work" "$T_TMP/tmpd" >"$T_TMP/curl-during" 2>/dev/null' \
    'printf "\nFRG26-ERR \nHTTP 201"' >"$T_TMP/bin/curl"
  chmod 700 "$T_TMP/bin/curl"
  export T_TMP CURL_TOK="$tok" CURL_BODY="{\"token\":\"$tok\",\"expires_at\":\"2026-11-25T23:00:00Z\",\"permissions\":{\"metadata\":\"read\"},\"repository_selection\":\"selected\",\"repositories\":[{\"full_name\":\"$REPO\"}]}"
  PATH="$T_TMP/bin:$PATH"
  make_jwt
  request_token '{"repositories":["forge-frg26-throwaway"],"permissions":{"metadata":"read"}}'
  assert_eq "$REQ_TOKEN" yes "the token was taken from the answer"
  assert_eq "$TOKEN" "$tok" "the token"
  assert_not_contains "$(cat "$T_TMP/curl-args")" "$JWT" "the JWT in curl's arguments"
  assert_not_contains "$(cat "$T_TMP/curl-args")" "$tok" "the token in curl's arguments"
  assert_contains "$(cat "$T_TMP/curl-args")" "@-" "curl reads its headers from its standard input"
  assert_contains "$(cat "$T_TMP/curl-stdin")" "Authorization: Bearer $JWT" "the JWT on curl's standard input"
  assert_eq "$(cat "$T_TMP/curl-during")" "" "a file held the token while curl ran"
  assert_eq "$(ls -A "$WORK")" "" "files left in the work folder"
  assert_eq "$(ls -A "$T_TMP/tmpd")" "" "files left in the temp folder"
  assert_eq "$(grep -rl -e "$JWT" -e "$tok" "$WORK" "$T_TMP/tmpd" 2>/dev/null || true)" "" "a file holding the JWT or the token"
  end_stand_in_run
}

# Round 109 (owner, 2026-11-25): app git has no password helper file and no home folder in the work
# folder. The token reaches git only for a request to GitHub (clone, fetch, push), and only as a setting
# in git's environment (http.https://github.com/.extraheader), never as an argument; a local git
# command gets no token at all. HOME is /var/empty; git's own prompt for a password is /usr/bin/false.
test_app_git_gets_the_token_only_for_requests_to_github_never_as_an_argument() {
  local log want
  load
  mkdir -p "$T_TMP/bin"
  # shellcheck disable=SC2016 # the stand-in's own lines are single-quoted on purpose: it expands them
  printf '%s\n' '#!/bin/bash' \
    'printf "args:%s\n" "$*" >>"$T_TMP/git.log"' \
    'printf "home:%s askpass:%s count:%s key:%s value:%s\n" "${HOME:-}" "${GIT_ASKPASS:-}" "${GIT_CONFIG_COUNT:-}" "${GIT_CONFIG_KEY_0:-}" "${GIT_CONFIG_VALUE_0:-}" >>"$T_TMP/git.log"' \
    'if env | grep -v "^FAKE_TOKEN=" | grep -qF -- "$FAKE_TOKEN"; then echo "token-in-env:yes" >>"$T_TMP/git.log"; else echo "token-in-env:no" >>"$T_TMP/git.log"; fi' >"$T_TMP/bin/git"
  chmod 700 "$T_TMP/bin/git"
  TOKEN="$(fake_token)"
  export T_TMP FAKE_TOKEN="$TOKEN"
  PATH="$T_TMP/bin:$PATH"
  WORK="$T_TMP/work"
  mkdir -m 700 "$WORK"
  app_git -C "$WORK" rev-parse HEAD
  log="$(cat "$T_TMP/git.log")"
  assert_contains "$log" "home:/var/empty askpass:/usr/bin/false count: key: value:" "a local command"
  assert_contains "$log" "token-in-env:no" "a local command: the token in git's environment"
  : >"$T_TMP/git.log"
  app_git -C "$WORK" push -q origin HEAD:refs/heads/b1
  log="$(cat "$T_TMP/git.log")"
  want="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"
  assert_contains "$log" "home:/var/empty askpass:/usr/bin/false count:1 key:http.https://github.com/.extraheader value:$want" "a push"
  assert_contains "$log" "token-in-env:no" "a push: the raw token in git's environment"
  assert_contains "$log" "-c core.askPass=/usr/bin/false" "a push: git's prompt"
  assert_not_contains "$(grep '^args:' "$T_TMP/git.log")" "$TOKEN" "the token in git's arguments"
  assert_not_contains "$(grep '^args:' "$T_TMP/git.log")" "${want#AUTHORIZATION: basic }" "the encoded token in git's arguments"
  [[ ! -e "$WORK/askpass" && ! -e "$WORK/home" ]] || _t_fail "a password helper or home folder in the work folder"
  assert_not_contains "$(declare -f make_work)" "askpass" "make_work writes a password helper"
  end_stand_in_run
}

# Round 109 (owner, 2026-11-25): app gh always takes its settings from the system's empty, read-only
# /var/empty (checked with gh 2.102.0, offline: evidence 267), in the run and in its clean-up alike.
test_app_gh_always_takes_its_settings_from_var_empty() {
  local child
  child=$(((RANDOM % 900 + 100) * 100)) # as above
  short_copy
  WORK="$T_TMP/work"
  request_tools "$child"
  stopped_run_cleanup 0 "" "capture app_gh api repos/\$REPO --jq .full_name || true"
  assert_exit 0 "$RC" "the run's status (137: still running after 20s)"
  assert_eq "$(grep -E 'installation/token$|--jq \.full_name$' "$T_TMP/gh-config" | grep -vc '^/var/empty ' || true)" 0 "app gh calls with settings from elsewhere"
  [[ ! -e "$WORK/gh-app" ]] || _t_fail "a gh settings folder in the work folder"
  assert_not_contains "$(declare -f make_work)" "gh-app" "make_work makes a gh settings folder"
}

# Round 109 (owner, 2026-11-25): no credential reaches an argument, a log or a file the run keeps: the
# run's tokens (and git's encoded form of each) appear in no tool's arguments, nowhere in the run's
# output, and in no file left in the work folder. Not proof of isolation: what this run's own code does
# with them, with stand-in tools.
test_no_credential_reaches_an_argument_a_log_or_a_kept_file() {
  local child n t enc f
  child=$(((RANDOM % 900 + 100) * 100)) # as above
  short_copy
  WORK="$T_TMP/work"
  request_tools "$child"
  stopped_run_cleanup 0 "" "capture app_gh api repos/\$REPO --jq .full_name || true; capture app_git -C \$WORK/clone push -q origin HEAD:refs/heads/b1 || true"
  for n in 1 2 3; do
    t="$(cleanup_token "$n")"
    enc="$(printf 'x-access-token:%s' "$t" | base64 | tr -d '\n')"
    assert_not_contains "$(cat "$T_TMP/tools")" "$t" "token$n in a tool's arguments"
    assert_not_contains "$(cat "$T_TMP/tools")" "$enc" "token$n, encoded, in a tool's arguments"
    assert_not_contains "$OUT" "$t" "token$n in the run's output"
    f="$(grep -rl -e "$t" -e "$enc" "$WORK" 2>/dev/null || true)"
    assert_eq "$f" "" "token$n in a file left in the work folder"
  done
}

# Round 110 (owner, 2026-11-25): a control's decision comes only from its wrapper's status line, the
# control's real exit status as control_exit encodes it (64 marker, 32 its command failed, 16 every
# token it was issued confirmed, 8 a token possibly issued and never received, 4 a request with no
# answer in time, 2 a write of unknown outcome, 1 one token issued, named as request_token names it).
# Anything else on the pipe (a cut line, another line, a status without the marker, a signal's
# status, bits that disagree, nothing) is no result.
test_a_controls_decision_comes_only_from_its_wrappers_status_line() {
  local case name lines partial want
  load
  end_stand_in_run
  for case in "clean, one token%CONTROL control1 status 81%%yes:control1-token4" \
    "clean, its command failed%CONTROL control1 status 113%%yes:control1-token4" \
    "one token not confirmed%CONTROL control1 status 65%%no:control1-token4" \
    "a request with no answer in time%CONTROL control1 status 69%%stop" \
    "a token possibly never received%CONTROL control1 status 73%%unrec" \
    "a write of unknown outcome%CONTROL control1 status 82%%write" \
    "its token not confirmed, yet no token%CONTROL control1 status 64%%none" \
    "a cut line%CONTROL control1 status 81%1%none" \
    "a line before the status%CONTROL control1 token4 confirmed|CONTROL control1 status 81%%none" \
    "a status without the marker%CONTROL control1 status 17%%none" \
    "a signal's status%CONTROL control1 status 137%%none" \
    "another control's status%CONTROL control2 status 81%%none" \
    "nothing%%%none"; do
    IFS='%' read -r name lines partial want <<<"$case"
    CONTROL_NAME=control1 CONTROL_MINTED_AT=3 CONTROL_PENDING=" control1" CONTROL_CONFIRMED="" CONTROL_UNCONFIRMED=""
    CONTROL_UNREC="" UNRECEIVED="" STOP_LINES="" WRITES_UNKNOWN="" CONTROL_PARTIAL="$partial"
    CONTROL_LINES="$(printf '%s' "$lines" | tr '|' '\n')"
    [[ -z "$CONTROL_LINES" ]] || CONTROL_LINES="$CONTROL_LINES"$'\n'
    control_judge control1 >/dev/null
    CONTROL_PENDING="$(printf '%s' "$CONTROL_PENDING" | tr -s ' ')"
    [[ "$CONTROL_PENDING" != " " ]] || CONTROL_PENDING=""
    case "$want" in
      yes:*) assert_eq "$CONTROL_CONFIRMED|$CONTROL_UNCONFIRMED|$CONTROL_PENDING" " ${want#yes:}||" "$name" ;;
      no:*) assert_eq "$CONTROL_CONFIRMED|$CONTROL_UNCONFIRMED|$CONTROL_PENDING" "| ${want#no:}|" "$name" ;;
      stop) assert_contains "$STOP_LINES" "a request of control1's got no answer within its limit" "$name"
        assert_eq "$CONTROL_CONFIRMED" "" "$name" ;;
      unrec) assert_contains "$UNRECEIVED" "control1-token5 unknown {}" "$name"
        assert_eq "$CONTROL_CONFIRMED" "" "$name" ;;
      write) assert_contains "$WRITES_UNKNOWN" "control1's writes" "$name" ;;
      none) assert_eq "$CONTROL_CONFIRMED|$CONTROL_UNCONFIRMED|$CONTROL_PENDING" "|| control1" "$name: no result" ;;
    esac
  done
}

# Round 110 (owner: "don't claim the pipe is exclusive until that is demonstrated"): while a control
# runs, the one process holding its pipe's write end is its wrapper; the control itself and what it
# starts hold neither end. Shown with lsof: the run's read end (fd 8) names its peer, and every
# process is listed that has that peer open.
test_only_the_wrapper_holds_a_controls_pipe() {
  local peer holders
  cleanup_stubs
  hold_cmd() { request_token '{}'; /bin/sleep 3 3>&- 8<&-; }
  # shellcheck disable=SC2016 # run inside the stopped run: $PPID there is the run itself
  stopped_run_cleanup 0 "" '/bin/sh -c "echo \$PPID" >$T_TMP/run-pid; (/bin/sleep 1.5; lsof -nP -a -p "$(cat $T_TMP/run-pid)" -d 8 >$T_TMP/lsof-8 2>&1; lsof -nP -w >$T_TMP/lsof-all 2>&1) 3>&- 8<&- & ck=$!; control_token hold_cmd || true; wait $ck'
  assert_exit 0 "$RC" "the run's status (137: still running after 20s)"
  peer="$(awk '$4 ~ /^8/ && $5 == "PIPE" { print $NF }' "$T_TMP/lsof-8" | sed 's/^->//')"
  [[ "$peer" == 0x* ]] || _t_fail "the run's fd 8 is not a pipe: $(cat "$T_TMP/lsof-8")"
  holders="$(awk -v p="$peer" '$5 == "PIPE" && $6 == p { print $1 " " $2 }' "$T_TMP/lsof-all" | sort -u)"
  assert_eq "$(printf '%s\n' "$holders" | grep -c .)" 1 "the processes holding the pipe's write end: $holders"
  assert_contains "$holders" "bash" "the one holder is the wrapper (a bash subshell)"
}

# Round 110 (owner: "test every external-program path"): every program found on PATH that the
# control's code, the token request, the clean-up's token work and the run's own handling of a control
# run is replaced by a stand-in that notes any pipe it holds on fds 3-20 and whether it can read fd 8,
# then runs the real one. A control is run through to its end; no stand-in held a pipe there.
test_no_program_on_a_controls_paths_holds_a_pipe() {
  local f w p words list="" missing=""
  cleanup_stubs
  words="$(for f in control_token control_start control_wait control_read control_end control_judge control_exit control_begin \
    control_collect request_token settle_register settle_list settle_tokens revoke_token token_refused revocation_judged expiry_of \
    kind_of unconfirmed_why outstanding_drop say redact into into_req into_settle capture with_timeout kill_tree nap pause call_secs \
    in_time call_budget write_out write_done write_unknown one_line answer_expected write_checked write_resolved stop_requests job_wait jobs_drop timeout_check \
    request_timed_out stop_note request_what request_writes defer_signals resume_signals; do declare -f "$f"; done |
    tr ';|&(){}`$' '\n' | sed -E 's/^[[:space:]]+//; s/^(if|then|else|elif|while|until|do|done|for|in|case|esac|!|local|export|time|exec)[[:space:]]+//' |
    awk '{ print $1 }' | grep -E '^[a-z][a-z0-9_-]*$' | sort -u)"
  mkdir -p "$T_TMP/sbin"
  for w in $words; do
    [[ "$(type -t "$w")" == file ]] || continue
    p="$(type -P "$w")"
    list="$list $w"
    # shellcheck disable=SC2016 # the stand-in's own lines are single-quoted on purpose: it expands them
    printf '%s\n' '#!/bin/bash' \
      'for n in 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do' \
      '  [[ -p /dev/fd/$n ]] && echo "'"$w"' holds a pipe on fd $n" >>"$T_TMP/leak"' \
      'done' \
      '{ : <&8; } 2>/dev/null && echo "'"$w"' can read fd 8" >>"$T_TMP/leak"' \
      "exec $p \"\$@\"" >"$T_TMP/sbin/$w"
    chmod 700 "$T_TMP/sbin/$w"
  done
  for w in date jq sed grep sleep pgrep; do [[ " $list " == *" $w "* ]] || missing="$missing $w"; done
  assert_eq "$missing" "" "programs the paths use, not found by the scan"
  : >"$T_TMP/leak"
  export T_TMP
  good_cmd() { request_token '{}'; }
  PATH="$T_TMP/sbin:$PATH" stopped_run_cleanup 0 "" "control_token good_cmd || true"
  assert_exit 0 "$RC" "the run's status (137: still running after 20s)"
  assert_contains "$(printf '%s\n' "$OUT" | tail -n 1)" "control1-token4; NOT confirmed: none;" "the control's token"
  assert_eq "$(sort -u "$T_TMP/leak")" "" "programs that held a pipe or the run's end of a control's"
}

# Round 110: bash 3.2 keeps a copy of a descriptor it redirects for a builtin or a function call on fd
# 10 or above, and doesn't close it for the programs it starts (round 109 showed a forged line got
# through). Where into holds the answer in memory, what it runs gets no copy of fds 3 or 8; nor does a
# command with_timeout or nap starts.
test_a_redirected_call_leaves_no_hidden_copy_of_a_descriptor() {
  local held v
  load
  end_stand_in_run
  WORK="$T_TMP/work"
  mkdir -m 700 "$WORK"
  for held in STOPS_HELD DEFERRING; do
    : >"$T_TMP/rec"
    exec 3>"$T_TMP/rec"
    STOPS_HELD="" DEFERRING=""
    printf -v "$held" '%s' 1
    # Only fds open as the program starts (its own shell's copies, made by a redirection there, don't
    # count).
    # shellcheck disable=SC2016 # the inner script is single-quoted on purpose: sh expands it
    into v /bin/sh -c 'o=""; for n in 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -e /dev/fd/$n ] && o="$o $n"; done; for n in $o; do eval "echo forged on $n >&$n"; done; echo ok'
    exec 3>&-
    assert_eq "$v" ok "$held: the command ran"
    assert_eq "$(cat "$T_TMP/rec")" "" "$held: a program reached fd 3 or a copy of it"
  done
  STOPS_HELD="" DEFERRING=""
  : >"$T_TMP/rec"
  exec 3>"$T_TMP/rec"
  # shellcheck disable=SC2016 # as above
  with_timeout 5 /bin/sh -c 'o=""; for n in 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -e /dev/fd/$n ] && o="$o $n"; done; for n in $o; do eval "echo forged on $n >&$n"; done'
  exec 3>&-
  assert_eq "$(cat "$T_TMP/rec")" "" "with_timeout: a program reached fd 3 or a copy of it"
}

# Round 110 (owner): every write sent directly goes through the checked helper (write_checked, or
# capture where a read-back settles it), never as a bare runner call whose answer is thrown away.
test_direct_writes_go_through_the_checked_helper() {
  local f bad
  load
  end_stand_in_run
  for f in put_file cmd_create cmd_create_second repo_settings cmd_reset owner_approve cmd_env_setup s2d_criteria \
    close_if_open close_issue cancel_waiting_runs cmd_ruleset; do
    bad="$(declare -f "$f" | grep -E '(^|[^_a-z])(owner_gh|app_gh|app_git) ' |
      grep -E -- '-X (POST|PUT|PATCH|DELETE)| -f | -F | push | pr (close|review|merge|create)| issue (close|create)| secret set' |
      grep -vE 'write_checked|capture |into |p_attempts|p_controls|admin_attempts|try_reading|request_what |unsettled_write ' || true)"
    assert_eq "$bad" "" "$f: a write not through the checked helper"
  done
  assert_contains "$(declare -f protection_write)" "write_checked" "protection_write"
  assert_contains "$(declare -f put_file_commit)" "--jq .commit.sha" "put_file_commit: its answer, the commit's sha"
}

# Round 110 (owner: rule (b), and "test each operation's expected response"): each direct write
# settles only on its own operation's expected answer (status 0 is not enough); any other answer, an
# empty one or a failure leaves it outcome unknown. With owner_gh standing in, answering as told.
test_each_direct_write_settles_only_on_its_expected_answer() {
  local case name call good out
  load
  end_stand_in_run
  WORK="$T_TMP/work"
  mkdir -m 700 "$WORK"
  owner_gh() { printf '%s\n' "$ANSWER"; return "${ANSWER_RC:-0}"; }
  die() { return 1; } # a failed setup write's die, kept from ending the test
  # shellcheck disable=SC2016 # each call is expanded when it runs
  for case in "put_file%put_file a.txt hello%{\"content\":{\"path\":\"a.txt\"},\"commit\":{\"sha\":\"$(printf 'a%.0s' $(seq 1 40))\"}}" \
    "put_file_commit%into S2_OWNER_SHA put_file_commit a.txt hello%$(printf 'b%.0s' $(seq 1 40))" \
    "repo_settings%repo_settings%{\"full_name\":\"$REPO\",\"default_branch\":\"$DEFAULT_BRANCH\"}" \
    "a branch made%write_checked \"json:.ref == \\\"refs/heads/dev\\\"\" owner_gh api -X POST repos/\$REPO/git/refs -f ref=refs/heads/dev -f sha=x%{\"ref\":\"refs/heads/dev\"}" \
    "a run cancelled%write_checked status:202 owner_gh api -i -X POST repos/\$REPO/actions/runs/1/cancel%HTTP/2.0 202 Accepted"; do
    IFS='%' read -r name call good <<<"$case"
    for out in good empty other failed; do
      WRITES_UNKNOWN="" WRITES_OUT="" ANSWER_RC=0
      case "$out" in
        good) ANSWER="$good" ;;
        empty) ANSWER="" ;;
        other) ANSWER='{"message":"something else"}' ;;
        failed) ANSWER="$good" ANSWER_RC=1 ;;
      esac
      eval "$call" >/dev/null 2>&1 || true
      if [[ "$out" == good ]]; then
        assert_eq "$(unknown_writes)$WRITES_OUT" "" "$name: answered as expected"
      else
        assert_contains "$(unknown_writes)" "(" "$name, $out: not named outcome unknown"
      fi
    done
  done
}

# Round 110 (owner: rule (b)): a tidy-up's write that fails (an answer that isn't success) is never
# sent again and is settled only by its read-back: a close read back closed, a cancel whose run the
# list no longer shows. One the read-back doesn't settle stays outcome unknown.
test_a_failed_tidy_up_write_is_settled_only_by_its_read_back() {
  local case name prep setup call hang rc_want last unknown child sha
  child=$(((RANDOM % 900 + 100) * 100)) # as above
  sha="$(printf 'e%.0s' $(seq 1 40))"
  for case in "an issue close refused, read back closed%echo 11 >\$T_TMP/open-issues%RUN_ID=r1%sweep_issues%issue close 11 %0%" \
    "an issue close refused, read back open%echo 11 >\$T_TMP/open-issues; echo open >\$T_TMP/issue-state-11%RUN_ID=r1%sweep_issues%issue close 11 %1%owner gh issue close 11 --repo \$REPO" \
    "an S2 cancel refused, read back finished%echo 9001 >\$T_TMP/runs-1; : >\$T_TMP/runs-2%S2_SHAS=$sha%cancel_waiting_runs%runs/9001/cancel%0%" \
    "an S2 cancel refused, still unfinished%echo 9001 >\$T_TMP/runs-1; echo 9001 >\$T_TMP/runs-2%CANCEL_ON_EXIT=1 S2_SHAS=$sha%%runs/9001/cancel%1%owner gh api POST repos/\$REPO/actions/runs/9001/cancel"; do
    IFS='%' read -r name prep setup call hang rc_want unknown <<<"$case"
    child=$((child + 1))
    short_copy
    WORK="$T_TMP/work"
    request_tools "$child"
    eval "$prep"
    printf '%s\n' "$hang" >"$T_TMP/write-fails"
    eval "unknown=\"$unknown\""
    stopped_run_cleanup "$rc_want" "$setup" "${call:+$call; echo NEXT STEP}"
    assert_exit "$rc_want" "$RC" "$name: the run's status (137: still running after 20s)"
    assert_eq "$(grep -cF -- "$hang" "$T_TMP/tools")" 1 "$name: how often the write was sent"
    last="$(printf '%s\n' "$OUT" | tail -n 1)"
    if [[ -n "$unknown" ]]; then
      assert_contains "$last" "CLEANUP INCOMPLETE:" "$name"
      assert_contains "$last" "$unknown (" "$name: the write named outcome unknown"
    else
      assert_contains "$last" "CLEANUP DONE:" "$name"
    fi
  done
}

# Round 111 (review-lens round 99, C1; owner: "unexpected write responses must stop dependent actions
# and remain unknown"): a checked write fails unless it settled on its expected answer, its command's
# own status kept in LAST_RC; what follows it doesn't run; and every checked write's caller stops on
# that failure.
test_an_unexpected_write_answer_stops_what_depends_on_it() {
  local case name want rc out f bad
  load
  end_stand_in_run
  WORK="$T_TMP/work"
  mkdir -m 700 "$WORK"
  : >"$T_TMP/owner"
  owner_gh() { echo "$*" >>"$T_TMP/owner"; printf '%s\n' "$ANSWER"; return "$ANSWER_RC"; }
  for case in 'expected|{"name":"main"}|0|0' 'another answer|{"name":"x"}|0|1' 'empty||0|1' 'failed|{"name":"main"}|1|1'; do
    IFS='|' read -r name ANSWER ANSWER_RC want <<<"$case"
    WRITES_UNKNOWN="" WRITES_OUT=""
    rc=0
    write_checked 'json:.name == "main"' owner_gh api -X POST "repos/$REPO/branches/x/rename" -f new_name=main >/dev/null 2>&1 || rc=$?
    assert_eq "$((rc != 0))" "$want" "write_checked, $name: failed"
    assert_eq "$LAST_RC" "$ANSWER_RC" "write_checked, $name: LAST_RC is its command's own status"
    if [[ "$want" == 1 ]]; then assert_contains "$(unknown_writes)" "owner gh api POST repos/$REPO/branches/x/rename (" "$name: named outcome unknown"; fi
  done
  # A setup write answered otherwise: the command stops there, with nothing after it sent.
  ANSWER='{"message":"moved"}' ANSWER_RC=0
  : >"$T_TMP/owner"
  out="$(
    die() { printf 'DIED: %s\n' "$*"; unknown_writes; exit 2; }
    put_file a.txt hello
    echo AFTER
    put_file b.txt hello
  )"
  assert_contains "$out" "DIED: adding a.txt failed"
  assert_contains "$out" "owner gh api PUT repos/$REPO/contents/a.txt (answered, not as expected)"
  assert_not_contains "$out" "AFTER" "a step after the unexpected answer"
  assert_eq "$(grep -c 'contents/' "$T_TMP/owner")" 1 "writes sent after the unexpected answer"
  # Every checked write's caller stops on its failure; only the S2 cancel goes on (its record waits
  # for the list, which settles it).
  for f in $(grep -oE '^[a-z_0-9]+\(\)' "$GT" | tr -d '()'); do
    [[ "$f" != write_checked ]] || continue
    # shellcheck disable=SC2016 # protection_write's own $code, as declare -f prints it
    bad="$(declare -f "$f" | grep -E '(^|[^_a-z])write_checked ' | grep -vE '\|\| die|^ *write_checked .*\$code' || true)"
    [[ "$f" != s2_cancel ]] || bad="$(printf '%s\n' "$bad" | grep -vF '/cancel' || true)"
    assert_eq "$bad" "" "$f: a checked write whose caller goes on after its failure"
  done
  # shellcheck disable=SC2016 # the function's own text
  assert_contains "$(declare -f protection_write | tail -n 2)" 'write_checked "status:$code"' "protection_write: its status is the function's"
}

# Round 111 (review-lens round 99, SEC-2; owner: "record each S2 cancel before dispatch so a stop
# cannot allow a resend"): a run's S2 cancel is sent at most once in that run: across its tidy-ups
# (S2d's own, each test's, the final one, the clean-up's), and after a stop before or after it goes
# out. One recorded but never answered, or not read back finished, stays outcome unknown.
test_an_s2_cancel_is_sent_at_most_once_in_a_run() {
  local case name call hook sent last child sha
  child=$(((RANDOM % 900 + 100) * 100)) # as above
  sha="$(printf 'e%.0s' $(seq 1 40))"
  short_cap() { CLEANUP_DEADLINE=$(($(date +%s) + 3)); } # a tidy-up during the run, ended within 3s
  for case in "two tidy-ups in one run%short_cap; cancel_waiting_runs; CLEANUP_DEADLINE=''%%1" \
    "S2d's cancel, then the clean-up%s2_cancel 9001%%1" \
    "a stop as a cancel is started, before it is sent%cancel_waiting_runs%before%0" \
    "a stop after a cancel is sent, before its answer is kept%cancel_waiting_runs%after%1"; do
    IFS='%' read -r name call hook sent <<<"$case"
    child=$((child + 1))
    short_copy
    WORK="$T_TMP/work"
    request_tools "$child"
    echo 9001 >"$T_TMP/runs-1"
    echo 9001 >"$T_TMP/runs-2"
    case "$hook" in
      before)
        keep_as_orig capture
        capture() { if [[ "$*" == *"/cancel"* ]]; then stop_here; fi; orig_capture "$@"; } ;;
      after)
        keep_as_orig capture
        capture() {
          local rc=0
          orig_capture "$@" || rc=$?
          if [[ "$*" == *"/cancel"* ]]; then stop_here; fi
          return "$rc"
        } ;;
    esac
    stopped_run_cleanup 1 "CANCEL_ON_EXIT=1 S2_SHAS=$sha" "$call; echo NEXT STEP"
    assert_eq "$(grep -cF runs/9001/cancel "$T_TMP/tools")" "$sent" "$name: how often the cancel was sent"
    last="$(printf '%s\n' "$OUT" | tail -n 1)"
    assert_contains "$last" "CLEANUP INCOMPLETE:" "$name"
    assert_contains "$last" "owner gh api POST repos/$REPO/actions/runs/9001/cancel (" "$name: the cancel named outcome unknown"
    assert_contains "$last" "not done: cancelling the waiting S2 runs" "$name"
    if [[ -n "$hook" ]]; then assert_not_contains "$OUT" "NEXT STEP" "$name: the run went on after the stop"; fi
  done
  load
  end_stand_in_run
  assert_contains "$(declare -f t_S2d)" "s2_cancel " "t_S2d: its cancel goes through the run's record"
  assert_not_contains "$(declare -f cancel_waiting_runs)" "LATE=" "cancel_waiting_runs: a record of its own"
}

# Round 112 (review-lens round 99, C2; owner): an app's API attempt counts as refused only on GitHub's
# complete answer (status line, headers' end, Content-Length matching, gh exit 1), a 403 (or a 404 to a
# read), a request id of its form, no rate-limit sign, and the permission this operation needs named by
# GitHub (x-accepted-github-permissions). gh's words and GitHub's message never decide; the body's
# text is never kept; and an attempt that may write stays outcome unknown however it was answered.
test_an_api_refusal_needs_a_complete_answer_attributable_to_its_operation() {
  local case name changes rc want c
  local -a ch
  for case in "complete, its operation's permission named||1|refused" \
    "gh's exit 0|status=HTTP/2.0 200 OK|0|allowed" \
    "gh's words alone, no status line|raw=gh: Resource not accessible by integration (HTTP 403)|1|inconclusive" \
    "cut before its headers end|cut|1|inconclusive" \
    "a body shorter than its Content-Length|len=999|1|inconclusive" \
    "a transfer encoding|add=Transfer-Encoding: chunked|1|inconclusive" \
    "gh's exit 2||2|inconclusive" \
    "no request id|drop=X-Github-Request-Id|1|inconclusive" \
    "a request id not of its form|drop=X-Github-Request-Id;add=X-Github-Request-Id: from-elsewhere|1|inconclusive" \
    "no x-ratelimit-remaining|drop=X-Ratelimit-Remaining|1|inconclusive" \
    "x-ratelimit-remaining 0|drop=X-Ratelimit-Remaining;add=X-Ratelimit-Remaining: 0|1|inconclusive" \
    "an x-ratelimit-resource not on GitHub's list|drop=X-Ratelimit-Resource;add=X-Ratelimit-Resource: other|1|inconclusive" \
    "a retry-after header|add=Retry-After: 60|1|inconclusive" \
    "HTTP 429|status=HTTP/2.0 429 Too Many Requests|1|inconclusive" \
    "rate-limit words in its body|body={\"message\":\"You have exceeded a secondary rate limit\"}|1|inconclusive" \
    "another operation's permission|drop=X-Accepted-Github-Permissions;add=X-Accepted-Github-Permissions: contents=write|1|inconclusive" \
    "no permission named|drop=X-Accepted-Github-Permissions|1|inconclusive" \
    "a 404 to a write|status=HTTP/2.0 404 Not Found|1|inconclusive" \
    "a 422|status=HTTP/2.0 422 Unprocessable Entity|1|inconclusive" \
    "a body with text of its own|body={\"message\":\"CANARY-not-kept\"}|1|refused"; do
    IFS='|' read -r name changes rc want <<<"$case"
    p_stubs
    IFS=';' read -r -a ch <<<"$changes"
    gh_reply reply ${ch[@]+"${ch[@]}"}
    echo "app_gh api -X PATCH repos/$REPO -f description=x|$rc|@reply" >"$T_TMP/answers"
    WRITES_UNKNOWN="" WRITES_OUT=""
    app_attempt -X PATCH "repos/$REPO" -f description=x >/dev/null 2>&1
    assert_eq "$OBS" "$want" "$name"
    assert_contains "$(cat "$T_TMP/calls")" "app_gh api -X PATCH repos/$REPO -f description=x" "$name: the attempt sent"
    assert_contains "$(unknown_writes)" "app gh api PATCH repos/$REPO (" "$name: the attempt named outcome unknown"
    assert_not_contains "$LAST_OUT" "CANARY" "$name: the body's text kept"
  done
  # A read's 404, with its operation's permission named, may be a refusal (its control shows the path).
  for c in "status=HTTP/2.0 404 Not Found|secrets=read|refused" "status=HTTP/2.0 404 Not Found|administration=read|inconclusive"; do
    IFS='|' read -r changes name want <<<"$c"
    p_stubs
    gh_reply reply "$changes" drop=X-Accepted-Github-Permissions "add=X-Accepted-Github-Permissions: $name"
    echo "app_gh api repos/$REPO/actions/secrets|1|@reply" >"$T_TMP/answers"
    WRITES_UNKNOWN="" WRITES_OUT=""
    app_attempt "repos/$REPO/actions/secrets" >/dev/null 2>&1
    assert_eq "$OBS" "$want" "a read's 404 naming $name"
    assert_eq "$(unknown_writes)" "" "a read noted as a write"
  done
}

# Round 112 (owner): an unchanged read-back never makes a refusal or clears a write alone. A write's note
# goes only with its complete refusal, the test's state read back unchanged against the baseline read
# before the first attempt, and a write that would have shown against it; a no-op (a protection DELETE on
# an unprotected branch) stays unknown. A state changed or unreadable makes the test inconclusive.
test_a_refused_write_is_settled_only_with_its_baseline_read_back_unchanged() {
  local case name reads want unknown resolved
  for case in "read back unchanged|false false|PASS expected=refused observed=refused|DELETE|PUT" \
    "changed since its baseline|false true|FAIL expected=refused observed=inconclusive|PUT DELETE|" \
    "its baseline unreadable|error false|FAIL expected=refused observed=inconclusive|PUT DELETE|" \
    "its read-back unreadable|false error|FAIL expected=refused observed=inconclusive|PUT DELETE|"; do
    IFS='|' read -r name reads want unknown resolved <<<"$case"
    p_stubs
    PHASE=open
    gh_reply reply
    echo "$reads" >"$T_TMP/protected-reads"
    owner_gh() {
      echo "owner_gh $*" >>"$T_TMP/calls"
      local n r
      case "$*" in
        "api repos/$REPO/branches/dev")
          n=$(($(cat "$T_TMP/protected-n" 2>/dev/null || echo 0) + 1))
          echo "$n" >"$T_TMP/protected-n"
          r="$(cut -d' ' -f"$n" "$T_TMP/protected-reads")"
          if [[ "$r" == error ]]; then echo "gh: HTTP 502" >&2; return 1; fi
          printf '{"name":"dev","protected":%s}\n' "$r" ;;
        "api repos/$REPO/branches/dev/protection")
          echo '{"enforce_admins":{"enabled":false},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}' ;;
      esac
    }
    rm -f "$T_TMP/protected-n"
    printf '{"required_status_checks":null,"enforce_admins":false,"required_pull_request_reviews":null,"restrictions":null}\n' >"$WORK/weak.json"
    cat >"$T_TMP/answers" <<EOF
app_gh api -X PUT repos/$REPO/branches/dev/protection|1|@reply
app_gh api -X DELETE repos/$REPO/branches/dev/protection|1|@reply
EOF
    WRITES_UNKNOWN="" WRITES_OUT=""
    admin_attempts B12 -X PUT "repos/$REPO/branches/dev/protection" --input "$WORK/weak.json" ";;" \
      -X DELETE "repos/$REPO/branches/dev/protection" >"$T_TMP/out" 2>&1
    assert_contains "$(cat "$T_TMP/out")" "RESULT B12 open $want" "$name"
    for m in $unknown; do
      assert_contains "$(unknown_writes)" "app gh api $m repos/$REPO/branches/dev/protection (" "$name: $m named outcome unknown"
    done
    for m in $resolved; do
      assert_not_contains "$(unknown_writes)" "app gh api $m repos/$REPO/branches/dev/protection (" "$name: $m still named outcome unknown"
    done
  done
  end_stand_in_run
}

# Round 112 (owner 2026-11-25): A6 stays inconclusive, its writes outcome unknown, however complete its
# refusals: no read can show its no-op writes (the description it has; the repository the installation
# has) unchanged.
test_a6_stays_inconclusive_whatever_its_answers() {
  p_stubs
  gh_reply reply
  cat >"$T_TMP/answers" <<EOF
owner_gh api repos/$REPO --jq .id|0|4242
app_gh api -X PATCH repos/$REPO|1|@reply
app_gh api -X PUT user/installations/77/repositories/4242|1|@reply
EOF
  WRITES_UNKNOWN="" WRITES_OUT=""
  t_A6 >"$T_TMP/out" 2>&1
  assert_contains "$(cat "$T_TMP/out")" "RESULT A6 permissions FAIL attempt=inconclusive"
  assert_contains "$(unknown_writes)" "app gh api PATCH repos/$REPO (" "A6's PATCH named outcome unknown"
  assert_not_contains "$(cat "$T_TMP/calls")" "owner_gh api -X PATCH" "a control after an inconclusive attempt"
  end_stand_in_run
}

# Round 112 (owner): until a completed remote rejection can be told from a transport failure (proposed,
# round112-plan.md), a push that fails is inconclusive and its write outcome unknown, whatever git says.
test_a_refused_looking_push_stays_inconclusive() {
  p_stubs
  cat >"$T_TMP/answers" <<'EOF'
push origin HEAD:refs/heads/frg26/permissions/A3-wf-r1|1|! [remote rejected] HEAD -> frg26/permissions/A3-wf-r1 (refusing to allow a GitHub App to create or update workflow `.github/workflows/frg26-a3-r1.yml` without `workflows` permission)
EOF
  WRITES_UNKNOWN="" WRITES_OUT=""
  t_A3 >"$T_TMP/out" 2>&1
  assert_contains "$(cat "$T_TMP/out")" "RESULT A3 permissions FAIL attempt=inconclusive"
  assert_contains "$(unknown_writes)" "app git push origin HEAD:refs/heads/frg26/permissions/A3-wf-r1" "the push named outcome unknown"
  assert_not_contains "$(cat "$T_TMP/calls")" "A3-plain" "a control after an inconclusive attempt"
  LAST_RC=1
  LAST_OUT="remote: Permission to $REPO2.git denied to frg26-test-app[bot]."
  assert_eq "$(classify_push_perm)" inconclusive "git's words of a permission refusal"
  LAST_RC=0
  assert_eq "$(classify_push_perm)" allowed
  end_stand_in_run
}

# Round 113 (review-lens round 100, C2 = SEC-3, SEC-4; owner chose (a)): an app attempt's answer is held
# in memory, from the gh process the attempt started, never through a file; its end is marked, so an
# answer lost or cut off (its job ended before it was whole) is never complete, whatever it holds.
test_an_app_attempts_answer_is_held_in_memory_whole_or_not_at_all() {
  local case name how want
  p_stubs
  assert_not_contains "$(declare -f app_attempt app_attempt_run)" "attempt.out" "a file for the answer"
  # shellcheck disable=SC2016 # the function's own text
  assert_not_contains "$(declare -f app_attempt_run)" '>"$WORK' "a file for the answer"
  # shellcheck disable=SC2016 # each is run as written, in the stand-in
  for case in "whole|cat \"\$T_TMP/reply\"|refused" \
    "lost: nothing came|return 1|inconclusive" \
    "cut off in a tidy-up: its job ended after the whole reply, before its end|cat \"\$T_TMP/reply\"; /bin/sh -c 'kill -KILL \$PPID'|inconclusive"; do
    IFS='|' read -r name how want <<<"$case"
    p_stubs
    gh_reply reply
    eval "app_gh() { echo \"app_gh \$*\" >>\"\$T_TMP/calls\"; $how; return 1; }"
    WRITES_UNKNOWN="" WRITES_OUT="" TIDY_UP=""
    [[ "$name" != *tidy-up* ]] || TIDY_UP=1 # where a request ended by KILL doesn't stop the run
    app_attempt -X PATCH "repos/$REPO" -f description=x >/dev/null 2>&1
    TIDY_UP=""
    assert_eq "$OBS" "$want" "$name"
    [[ "$name" != *tidy-up* ]] || assert_contains "$AV_WHY" "cut off before its end" "$name"
    assert_eq "$(find "$WORK" -type f | wc -l | tr -d ' ')" 0 "$name: a file left in the work folder"
    assert_contains "$(unknown_writes)" "app gh api PATCH repos/$REPO (" "$name: the attempt named outcome unknown"
  done
  # Cut off in a test step: no answer within its limit (a KILL is taken so), so the run stops there,
  # with no verdict, the attempt named outcome unknown.
  p_stubs
  gh_reply reply
  # shellcheck disable=SC2016 # run in the stand-in
  app_gh() { echo "app_gh $*" >>"$T_TMP/calls"; cat "$T_TMP/reply"; /bin/sh -c 'kill -KILL $PPID'; }
  local rc=0 out
  out="$( (trap 'unknown_writes >"$T_TMP/unknown"' EXIT; app_attempt -X PATCH "repos/$REPO" -f description=x; echo "VERDICT $OBS") 2>&1)" || rc=$?
  assert_exit 2 "$rc" "the run's status after an attempt cut off"
  assert_not_contains "$out" "VERDICT" "a verdict on an answer cut off"
  assert_contains "$(cat "$T_TMP/unknown")" "app gh api PATCH repos/$REPO (" "the attempt named outcome unknown"
  end_stand_in_run
}

# Round 114 (review-lens round 100's C3 = SEC-1, item 1; owner): an attempt's answer is taken only from
# the program its own job starts (round 115: the fixed curl), given exactly that attempt's method and
# path: its standard input the headers' pipe (round 115), its standard output the answer's pipe, its
# error output /dev/null, and no other descriptor; the answer pipe's write end is held only by that
# program and the job's own shells, never by the run's shell or anything else. lsof's view is
# supporting evidence from this test, not proof against every way another process could interfere.
test_an_app_attempts_answer_comes_only_from_the_gh_its_job_started() {
  local gh run dev holders h anc p
  short_copy
  WORK="$T_TMP/work"
  request_tools 0
  gh_reply reply
  echo "https://api.github.com/repos/$REPO" >"$T_TMP/fd-probe"
  # shellcheck disable=SC2016 # run inside the stopped run: $PPID there is the run itself
  stopped_run_cleanup 0 "PHASE=permissions CLONE=\$WORK/clone" \
    '/bin/sh -c "echo \$PPID" >$T_TMP/run-pid; app_attempt -X PATCH "repos/$REPO" -f description=x; echo "VERDICT $OBS"'
  assert_contains "$OUT" "VERDICT refused" "the attempt judged on the answer curl gave"
  assert_contains " $(cat "$T_TMP/probe-args") " " -X PATCH " "what curl was asked: its method"
  assert_contains " $(cat "$T_TMP/probe-args") " " https://api.github.com/repos/$REPO " "what curl was asked: its address"
  assert_eq "$(cat "$T_TMP/probe-fds")" "0 pipe;1 pipe;2 null;" "curl's descriptors"
  gh="$(cat "$T_TMP/probe-pid")" run="$(cat "$T_TMP/run-pid")"
  dev="$(awk -v p="$gh" '$2 == p && $4 ~ /^1[uw]?$/ && $5 == "PIPE" { print $6 }' "$T_TMP/probe-lsof")"
  [[ "$dev" == 0x* ]] || _t_fail "gh's fd 1 is not a pipe in lsof's view: $(awk -v p="$gh" '$2 == p' "$T_TMP/probe-lsof" | head -n 5)"
  holders="$(awk -v d="$dev" '$5 == "PIPE" && $6 == d { print $2 }' "$T_TMP/probe-lsof" | sort -u | tr '\n' ' ')"
  [[ " $holders " == *" $gh "* ]] || _t_fail "lsof doesn't show gh holding the answer's write end: holders '$holders'"
  # gh's ancestors, up to (not including) the run's own shell: the job that started it.
  anc="" p="$gh"
  while [[ -n "$p" && "$p" != "$run" && "$p" != 1 ]]; do
    anc="$anc $p"
    p="$(awk -v c="$p" '$1 == c { print $2 }' "$T_TMP/probe-ps")"
  done
  [[ "$p" == "$run" ]] || _t_fail "gh is not under the run's shell ($run): ancestors$anc"
  for h in $holders; do
    [[ " $anc " == *" $h "* ]] || _t_fail "a process outside the attempt's job holds the answer's write end: $h ($(awk -v p="$h" '$2 == p { print $1; exit }' "$T_TMP/probe-lsof"))"
  done
  [[ " $holders " != *" $run "* ]] || _t_fail "the run's own shell holds the answer's write end"
}

# Round 114 (owner: test partial output and child failure): an answer that isn't the whole of one
# program's own output, as it ended, is never complete: cut short, followed by its failure, or added to by
# a process it left behind after its end. Round 115: the program is curl, so the stand-in is the
# transport itself, with curl's own report where curl would give one.
test_an_app_attempts_answer_partial_or_added_to_is_never_complete() {
  local case name how
  # shellcheck disable=SC2016 # each is run as written, in the stand-in
  for case in "half the reply, then curl fails (18)|head -c 120 \"\$T_TMP/reply\"; return 18" \
    "the whole reply and its report, then curl exits 56|cat \"\$T_TMP/reply\"; curl_report; return 56" \
    "the whole reply and its report, then a process it left writes more|cat \"\$T_TMP/reply\"; curl_report; (/bin/sleep 0.2; echo more) & return 0" \
    "a process it left writes first, then the reply and its report|(echo before) ; cat \"\$T_TMP/reply\"; curl_report; return 0"; do
    IFS='|' read -r name how <<<"$case"
    p_stubs
    gh_reply reply
    curl_report() { printf '\n@@FRG26-CURL 403 0 0 https://api.github.com/%s' "$AT_PATH"; }
    eval "attempt_send() { echo \"attempt_send \$*\" >>\"\$T_TMP/calls\"; $how; }"
    WRITES_UNKNOWN="" WRITES_OUT=""
    app_attempt -X PATCH "repos/$REPO" -f description=x >/dev/null 2>&1
    assert_eq "$OBS" inconclusive "$name"
    assert_contains "$(unknown_writes)" "app gh api PATCH repos/$REPO (" "$name: the attempt named outcome unknown"
  done
  end_stand_in_run
}

# Round 114 (owner: "the fixed method/path this attempt starts"): an attempt is sent only in its one
# fixed form: -X <method> (required with fields), exactly one endpoint path (no URL, no host, no query,
# not graphql), and only -f/-F/--input fields; anything else stops before it is sent, so what gh is
# asked is exactly the method and path it is judged for.
test_an_app_attempt_is_sent_only_in_its_fixed_form() {
  local case name args rc
  for case in "two endpoints|-X PATCH repos/\$REPO repos/\$REPO2" \
    "no endpoint|-X PATCH -f description=x" \
    "a full URL|-X PATCH https://example.com/repos/\$REPO" \
    "graphql|-X POST graphql -f query=x" \
    "a query string|repos/\$REPO/hooks?per_page=1" \
    "another host|--hostname example.com repos/\$REPO/hooks" \
    "a paginated read|--paginate repos/\$REPO/hooks" \
    "its own -i|-i repos/\$REPO/hooks" \
    "its own header|-H Accept: x repos/\$REPO/hooks" \
    "a second method|-X PATCH -X DELETE repos/\$REPO" \
    "fields without a method|repos/\$REPO -f description=x" \
    "a method not of its list|-X patch repos/\$REPO" \
    "a jq filter|repos/\$REPO/hooks --jq .[0]"; do
    IFS='|' read -r name args <<<"$case"
    p_stubs
    rc=0
    eval "(app_attempt $args) >\"\$T_TMP/out\" 2>&1" || rc=$?
    assert_exit 2 "$rc" "$name"
    assert_not_contains "$(cat "$T_TMP/calls")" "app_gh" "$name: sent"
  done
  # The forms its callers use are accepted as they are.
  p_stubs
  printf '{"enforce_admins":false}\n' >"$WORK/weak.json"
  app_attempt "repos/$REPO/actions/secrets" >/dev/null 2>&1
  app_attempt -X PUT "repos/$REPO/branches/dev/protection" --input "$WORK/weak.json" >/dev/null 2>&1
  app_attempt -X POST "repos/$REPO/actions/runs/1/pending_deployments" -F "environment_ids[]=9" -f state=approved >/dev/null 2>&1
  assert_eq "$(grep -c '^app_gh api' "$T_TMP/calls")" 3 "the callers' forms sent"
  end_stand_in_run
}

# Round 115 (review-lens round 101, C1 = SEC-2; owner): each part of a baseline is read on its own and
# must parse as GitHub's JSON of its kind, of the expected type, with its required fields; a read that
# fails, answers nothing, or answers anything else leaves the whole baseline unreadable. No word in an
# answer decides it.
test_each_baseline_part_is_validated_on_its_own() {
  local case name reader answer rc want
  # <name>|<reader and args>|<the owner's answer, one JSON text>|<its status>|<0 readable, 1 not>
  for case in "an unprotected branch|state_protection dev|{\"name\":\"dev\",\"protected\":false}|0|0" \
    "a branch read failing|state_protection dev|{\"name\":\"dev\",\"protected\":false}|1|1" \
    "a branch read answering nothing|state_protection dev||0|1" \
    "a branch read not JSON|state_protection dev|not json|0|1" \
    "a branch read of another branch|state_protection dev|{\"name\":\"main\",\"protected\":false}|0|1" \
    "a branch read without its protected flag|state_protection dev|{\"name\":\"dev\"}|0|1" \
    "a branch read whose flag isn't a boolean|state_protection dev|{\"name\":\"dev\",\"protected\":\"false\"}|0|1" \
    "the word error as a value|state_repo|@repo .description = \"error\"|0|0" \
    "the repository, its settings whole|state_repo|@repo .|0|0" \
    "the repository read answering nothing|state_repo||0|1" \
    "another repository|state_repo|@repo .full_name = \"someone/else\"|0|1" \
    "the repository without its default branch|state_repo|@repo del(.default_branch)|0|1" \
    "the repository as a list|state_repo|[]|0|1" \
    "no rulesets|state_rulesets|[]|0|0" \
    "the rulesets read answering nothing|state_rulesets||0|1" \
    "the rulesets as an object|state_rulesets|{}|0|1" \
    "a ruleset without a number id|state_rulesets|[{\"id\":\"5\"}]|0|1" \
    "the Environment's read answering nothing|state_environment||0|1" \
    "the second throwaway's refs answering nothing|state_refs2||0|1" \
    "the second throwaway's refs, a branch with no commit|state_refs2|[{\"name\":\"frg26-a2\",\"commit\":{}}]|0|1"; do
    IFS='|' read -r name reader answer rc want <<<"$case"
    p_stubs
    answer="${answer//@REPO@/$REPO}"
    # @repo <jq>: the repository's settings whole (repo_answer), changed by <jq>
    if [[ "$answer" == "@repo "* ]]; then answer="$(repo_answer | jq -c "${answer#@repo }")"; fi
    printf '%s' "$answer" >"$T_TMP/state-answer"
    echo "$rc" >"$T_TMP/state-rc"
    # Round 118: a list's page (asked with -i) is that answer as gh api -i prints it.
    owner_gh() {
      echo "owner_gh $*" >>"$T_TMP/calls"
      if [[ "$1 $2" == "api -i" ]]; then gh_page "$(cat "$T_TMP/state-answer")"; else cat "$T_TMP/state-answer"; fi
      return "$(cat "$T_TMP/state-rc")"
    }
    local got=0 out
    # shellcheck disable=SC2086 # the reader and its arguments
    out="$($reader)" || got=$?
    if [[ "$want" == 0 ]]; then
      assert_exit 0 "$got" "$name: read as a state"
      jq -e . >/dev/null 2>&1 <<<"$out" || _t_fail "$name: its state is not JSON: $out"
    else
      [[ "$got" != 0 ]] || _t_fail "$name: read as a state: $out"
    fi
  done
  # A baseline any part of which is unreadable is unreadable whole, and settles nothing.
  p_stubs
  PHASE=open
  owner_gh() {
    case "$*" in
      "api -i repos/$REPO/rulesets?per_page=100&page=1") gh_page '[]' ;;
      "api repos/$REPO") return 0 ;; # the repository's settings: answered with nothing
    esac
  }
  attempt_baseline B13
  assert_eq "$ATTEMPT_BASE_OK" "" "B13's baseline with its repository part empty"
  OBS=refused EV="" ATTEMPT_WRITES="PATCH repos/$REPO"$'\n'
  WRITES_UNKNOWN="" WRITES_OUT=""
  write_unknown "app gh api PATCH repos/$REPO" "answered HTTP 403: refused, not read back"
  attempts_settle B13
  assert_eq "$OBS" inconclusive "a refusal with an unreadable baseline"
  assert_contains "$(unknown_writes)" "app gh api PATCH repos/$REPO (" "the PATCH cleared"
  end_stand_in_run
}

# Round 115 (review-lens round 101, C2; owner): the ruleset is read back by the id its create answered
# with, and every field submitted (name, target, enforcement, conditions, each rule with its
# parameters, each bypass actor) must equal the read-back, normalised; GitHub's own extra fields aside.
# Anything else, or a read-back that fails, leaves the write outcome unknown.
test_the_ruleset_is_settled_only_on_every_field_it_was_sent() {
  local case name change want rc out
  for case in "the same, in GitHub's order, with GitHub's own fields|.|0" \
    "another name|.name = \"main: anyone\"|2" \
    "evaluate, not active|.enforcement = \"evaluate\"|2" \
    "a rule more|.rules += [{\"type\":\"creation\"}]|2" \
    "a rule's parameter changed|.rules[2].parameters.update_allows_fetch_and_merge = true|2" \
    "a bypass actor more|.bypass_actors += [{\"actor_id\":5,\"actor_type\":\"RepositoryRole\",\"bypass_mode\":\"always\"}]|2" \
    "its bypass mode changed|.bypass_actors[0].bypass_mode = \"pull_request\"|2" \
    "an excluded branch|.conditions.ref_name.exclude = [\"refs/heads/x\"]|2" \
    "another target|.target = \"tag\"|2" \
    "unreadable|@fail|2"; do
    IFS='|' read -r name change want <<<"$case"
    owner_cmd_stubs
    verify_phase() { :; }
    app_gh() { rate_fixture 4000; }
    die() { printf 'DIED: %s\n' "$*"; unknown_writes; exit 2; }
    echo "$change" >"$T_TMP/change"
    owner_gh() {
      echo "$*" >>"$T_TMP/owner"
      case "$*" in
        *"-X POST repos/$REPO/rulesets"*) echo '{"id":7,"name":"main: only the owner"}' ;;
        "api repos/$REPO/rulesets/7")
          [[ "$(cat "$T_TMP/change")" != @fail ]] || { echo "gh: HTTP 502" >&2; return 1; }
          # GitHub's copy: its own fields added, keys and rules in another order.
          ruleset_json User 1 | jq -c '{id: 7, source: "x/y", source_type: "Repository", node_id: "RRS_1", _links: {}, created_at: "t", updated_at: "t",
            current_user_can_bypass: "always", rules: (.rules | reverse), bypass_actors, conditions, enforcement, target, name}' |
            jq -c "$(cat "$T_TMP/change")" ;;
      esac
    }
    rc=0
    out="$({ cmd_ruleset && unknown_writes; } 2>&1)" || rc=$?
    assert_exit "$want" "$rc" "$name"
    if [[ "$want" == 0 ]]; then
      assert_not_contains "$out" "POST repos/$REPO/rulesets (" "$name: still named outcome unknown"
    else
      assert_contains "$out" "owner gh api POST repos/$REPO/rulesets (" "$name: settled"
    fi
  done
}

# Round 115 (owner: the curl transport): what each caller's fields become as the body the app's attempt
# sends: -f a string, -F a number, true, false or null (else a string), name[] a list; --input a JSON
# object file, alone. Anything else is refused before anything is sent.
test_an_app_attempts_body_is_built_from_its_fields_exactly() {
  local case name args want got rc
  p_stubs
  printf '{"b": [1, 2], "a": "x"}\n' >"$WORK/in.json"
  printf 'not json\n' >"$WORK/bad.json"
  printf '[1]\n' >"$WORK/list.json"
  for case in "no fields|-X DELETE repos/\$REPO/branches/dev/protection|" \
    "a string|-X PATCH repos/\$REPO -f 'description=a \"quoted\" line'|{\"description\":\"a \\\"quoted\\\" line\"}" \
    "a string with = and a newline|-X PATCH repos/\$REPO -f \$'description=x=y\\nz'|{\"description\":\"x=y\\nz\"}" \
    "three strings|-X PUT repos/\$REPO2/contents/f.txt -f message=m -f content=Zm9v -f branch=b|{\"branch\":\"b\",\"content\":\"Zm9v\",\"message\":\"m\"}" \
    "a typed list and strings|-X POST repos/\$REPO/actions/runs/1/pending_deployments -F environment_ids[]=9 -f state=approved -f comment=c|{\"comment\":\"c\",\"environment_ids\":[9],\"state\":\"approved\"}" \
    "typed values|-X PATCH repos/\$REPO -F a=true -F b=false -F c=null -F d=12 -F e=x1|{\"a\":true,\"b\":false,\"c\":null,\"d\":12,\"e\":\"x1\"}" \
    "a JSON file|-X PUT repos/\$REPO/environments/e --input \$WORK/in.json|{\"a\":\"x\",\"b\":[1,2]}"; do
    IFS='|' read -r name args want <<<"$case"
    eval "attempt_form $args" || _t_fail "$name: not in its form"
    got=""
    eval "attempt_body $args" || _t_fail "$name: no body"
    got="$ATTEMPT_BODY"
    [[ -z "$got" ]] || got="$(jq -S -c . <<<"$got")"
    assert_eq "$got" "$want" "$name"
  done
  for case in "a file not JSON|-X PUT repos/\$REPO/environments/e --input \$WORK/bad.json" \
    "a file not an object|-X PUT repos/\$REPO/environments/e --input \$WORK/list.json" \
    "a file and fields|-X PUT repos/\$REPO/environments/e --input \$WORK/in.json -f a=b" \
    "a field read from a file|-X PATCH repos/\$REPO -F description=@\$WORK/in.json" \
    "a nested key|-X PATCH repos/\$REPO -f a[b]=c" \
    "a field with no name|-X PATCH repos/\$REPO -f =c" \
    "a field with no =|-X PATCH repos/\$REPO -f description"; do
    IFS='|' read -r name args <<<"$case"
    rc=0
    eval "attempt_body $args" >/dev/null 2>&1 || rc=$?
    [[ $rc -ne 0 ]] || _t_fail "$name: a body was built"
  done
  end_stand_in_run
}

# Round 115 (owner: the curl transport): the app's attempt goes through the fixed /usr/bin/curl, to
# https://api.github.com/<its path> only, with verified HTTPS (never -k), no redirect, no proxy and no
# curl settings of anyone's (-q first; nothing of the run's environment: no proxy, CA or curl
# variables), no retry, and the token only on curl's standard input (a pipe): never an argument, a
# file, the environment, the answer kept or the output. With a stand-in at the fixed path in a copy of
# the script, since the real one would reach GitHub.
test_an_app_attempt_goes_through_the_system_curl_alone() {
  local args envs tok
  short_copy
  WORK="$T_TMP/work"
  request_tools 0
  gh_reply reply
  echo "https://api.github.com/repos/$REPO" >"$T_TMP/fd-probe"
  # shellcheck disable=SC2016 # run inside the stopped run
  stopped_run_cleanup 0 "PHASE=permissions CLONE=\$WORK/clone; export https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9 CURL_HOME=$T_TMP SSL_CERT_FILE=$T_TMP/ca.pem CURL_CA_BUNDLE=$T_TMP/ca.pem SSLKEYLOGFILE=$T_TMP/keys" \
    'app_attempt -X PATCH "repos/$REPO" -f description=x; echo "VERDICT $OBS"; echo "OUT $LAST_OUT"'
  tok="$(cleanup_token 1)"
  assert_contains "$OUT" "VERDICT refused" "the attempt judged on curl's answer"
  args="$(cat "$T_TMP/probe-args")"
  assert_eq "${args%% *}" "-q" "curl's first argument (no .curlrc)"
  for want in "--proto =https" "--max-redirs 0" "--noproxy *" "-H @-" "-X PATCH" "--include" "-H Accept-Encoding: identity" \
    "--data-binary {\"description\":\"x\"}" "https://api.github.com/repos/$REPO"; do
    assert_contains " $args " " $want " "curl's arguments"
  done
  for want in " -k " " --insecure " " -L " " --location " " --retry" " -K " " --config "; do
    assert_not_contains " $args " "$want" "curl's arguments"
  done
  assert_eq "$(tr ' ' '\n' <<<"$args" | grep -c '^https://')" 1 "the one destination"
  # The stand-in is a bash script, and bash makes PWD, SHLVL and _ of its own: those aside, all it got.
  envs="$(cat "$T_TMP/probe-env")"
  assert_eq "$envs" "HOME=/var/empty PATH=/usr/bin:/bin" "curl's environment, whole"
  assert_eq "$(cat "$T_TMP/probe-auth")" "Authorization: Bearer sha256:$(printf '%s' "$tok" | shasum -a 256 | cut -d' ' -f1)" "the token, on curl's standard input"
  assert_not_contains "$args" "$tok" "the token in curl's arguments"
  assert_not_contains "$OUT" "$tok" "the token in the run's output"
  assert_eq "$(grep -rlF -- "$tok" "$WORK" 2>/dev/null)" "" "the token in a file in the work folder"
  assert_eq "$(cat "$T_TMP/probe-fds")" "0 pipe;1 pipe;2 null;" "curl's descriptors"
  assert_eq "$(grep -c 'api.github.com' "$T_TMP/tools")" 1 "how often the attempt was sent (no retry)"
}

# The transport's stand-in: $T_TMP/reply, then curl's report ($T_TMP/curl-meta; by default the reply's own
# status, no redirect, TLS verified, the address asked; "none" for no report), and curl's status
# ($T_TMP/curl-rc).
curl_stand_in() {
  attempt_send() {
    local m st
    echo "attempt_send $*" >>"$T_TMP/calls"
    cat "$T_TMP/reply"
    m="$(cat "$T_TMP/curl-meta")"
    if [[ -z "$m" ]]; then
      st="$(head -n 1 "$T_TMP/reply" | sed -n 's/^HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p')"
      m="$st 0 0 https://api.github.com/$AT_PATH"
    fi
    [[ "$m" == none ]] || printf '\n@@FRG26-CURL %s' "$m"
    return "$(cat "$T_TMP/curl-rc")"
  }
}

# Round 115 (owner: test redirects, malformed or empty answers, partial transfers, unexpected
# destinations): curl's own report (-w: GitHub's status, the redirects followed, TLS verification, the
# address it ended at) must agree with the answer and with the one request; anything else, or curl
# failing, is never a refusal and never settles a write.
test_an_app_attempt_through_curl_needs_curls_own_report_to_agree() {
  local case name changes rc meta want
  local -a ch
  for case in "complete, as sent|||0|refused" \
    "a 200|status=HTTP/2 200||0|allowed" \
    "a redirect, not followed|status=HTTP/2 301;add=Location: https://api.github.com/repositories/1|301 0 0 @URL@|0|inconclusive" \
    "a redirect curl says it followed||403 1 0 @URL@|0|inconclusive" \
    "an address other than the one asked||403 0 0 https://api.github.com/repos/someone/else|0|inconclusive" \
    "an address on another host||403 0 0 https://example.com/repos/@REPO@|0|inconclusive" \
    "TLS not verified||403 0 1 @URL@|0|inconclusive" \
    "a status other than the answer's||404 0 0 @URL@|0|inconclusive" \
    "no report of curl's||none|0|inconclusive" \
    "a report not of its form||403 x 0 @URL@|0|inconclusive" \
    "a partial transfer (curl 18)|len=999||18|inconclusive" \
    "a transfer cut (curl 56)|||56|inconclusive" \
    "curl timing out (28)|||28|inconclusive" \
    "an empty answer|raw=|000 0 0 @URL@|7|inconclusive" \
    "an answer not HTTP|raw=garbage||0|inconclusive"; do
    IFS='|' read -r name changes meta rc want <<<"$case"
    p_stubs
    IFS=';' read -r -a ch <<<"$changes"
    gh_reply reply ${ch[@]+"${ch[@]}"}
    meta="${meta//@URL@/https://api.github.com/repos/$REPO}"
    meta="${meta//@REPO@/$REPO}"
    printf '%s' "$meta" >"$T_TMP/curl-meta"
    echo "$rc" >"$T_TMP/curl-rc"
    curl_stand_in
    WRITES_UNKNOWN="" WRITES_OUT=""
    app_attempt -X PATCH "repos/$REPO" -f description=x >/dev/null 2>&1
    assert_eq "$OBS" "$want" "$name"
    assert_eq "$(grep -c '^attempt_send' "$T_TMP/calls")" 1 "$name: sent once"
    assert_contains "$(unknown_writes)" "app gh api PATCH repos/$REPO (" "$name: the attempt named outcome unknown"
  done
  end_stand_in_run
}

# Round 113 (owner, 2026-11-25: accepted for these stage 1 API attempts only): a stop while an app
# attempt is out is held until its answer is in, at most the request's own limit, then acted on: the
# attempt is judged and named, no further test action starts, and the bounded clean-up runs.
test_a_stop_during_an_app_attempt_waits_for_its_answer_then_ends_the_run() {
  local last
  short_copy
  WORK="$T_TMP/work"
  request_tools 0.6 # its answer (none) comes 0.6s in, after the stop at 0.3s, inside its 1s limit
  echo "https://api.github.com/repos/$REPO" >"$T_TMP/hang-on"
  # shellcheck disable=SC2016 # run inside the stopped run: $PPID there is the run itself
  stopped_run_cleanup 0 "PHASE=permissions CLONE=\$WORK/clone" \
    '/bin/sh -c "/bin/sleep 0.3; kill -TERM \$PPID" & app_attempt -X PATCH "repos/$REPO" -f description=x; echo NEXT TEST ACTION; owner_gh api next-action'
  assert_exit 143 "$RC" "the run's status (137: still running after 20s)"
  ((SECS <= CLEANUP_SECS + 3)) || _t_fail "ended after ${SECS}s; the clean-up's cap is ${CLEANUP_SECS}s"
  assert_not_contains "$OUT" "NEXT TEST ACTION" "a test action after the stop"
  assert_not_contains "$(cat "$T_TMP/tools")" "next-action" "a request after the stop"
  assert_eq "$(grep -cF -- "https://api.github.com/repos/$REPO" "$T_TMP/tools")" 1 "how often the attempt was sent"
  last="$(printf '%s\n' "$OUT" | tail -n 1)"
  assert_contains "$last" "CLEANUP INCOMPLETE:" "the attempt left unknown"
  # Its answer was waited for and judged (not cut short by the stop).
  assert_contains "$last" "app gh api PATCH repos/$REPO (answered HTTP unknown (curl exit 1): inconclusive, not read back)" "the attempt judged before the stop"
}

# Round 113 (review-lens round 100, C1 = SEC-2; owner): a baseline with any part unreadable is unreadable
# whole, however the rest reads. Round 115: each part checked on its own (a failed read, or an answer
# that isn't its kind of JSON), and the same failure before and after settles nothing either.
test_a_baseline_with_a_failed_part_is_unreadable_whole() {
  local case name id phase fail
  for case in "B13, its repository settings unreadable|B13|open|repo" \
    "B13, its repository settings not of their kind|B13|open|repo-kind" \
    "B13, one ruleset unreadable|B13|open|one-ruleset" \
    "M4 in the ruleset phase, main's protection unreadable|M4|ruleset|protection"; do
    IFS='|' read -r name id phase fail <<<"$case"
    p_stubs
    PHASE="$phase"
    echo "$fail" >"$T_TMP/fail"
    owner_gh() {
      echo "owner_gh $*" >>"$T_TMP/calls"
      local f
      f="$(cat "$T_TMP/fail")"
      case "$*" in
        "api -i repos/$REPO/rulesets?per_page=100&page=1") gh_page '[{"id":5}]' ;;
        "api -i repos/$REPO/rulesets?per_page=100&page=2") gh_page '[]' ;;
        "api repos/$REPO/rulesets/5")
          if [[ "$f" == one-ruleset ]]; then echo "gh: HTTP 502" >&2; return 1; fi
          echo '{"id":5,"name":"r","enforcement":"active","target":"branch","rules":[]}' ;;
        "api repos/$REPO")
          if [[ "$f" == repo ]]; then echo "gh: HTTP 502" >&2; return 1; fi
          if [[ "$f" == repo-kind ]]; then echo '"error"'; return 0; fi
          repo_answer ;;
        "api repos/$REPO/branches/main")
          if [[ "$f" == protection ]]; then echo "gh: HTTP 502" >&2; return 1; fi
          echo '{"name":"main","protected":false}' ;;
      esac
    }
    WRITES_UNKNOWN="" WRITES_OUT=""
    attempt_baseline "$id"
    assert_eq "$ATTEMPT_BASE_OK" "" "$name: the baseline read as whole"
    OBS=refused EV="" ATTEMPT_WRITES="POST repos/$REPO/rulesets"$'\n'
    write_unknown "app gh api POST repos/$REPO/rulesets" "answered HTTP 403: refused, not read back"
    attempts_settle "$id"
    assert_eq "$OBS" inconclusive "$name"
    assert_contains "$(unknown_writes)" "app gh api POST repos/$REPO/rulesets (" "$name: the write cleared"
  done
  end_stand_in_run
}

# GitHub's answer for the repository: every setting its baseline compares, and fields of GitHub's own.
repo_answer() {
  printf '{"id":1,"full_name":"%s","private":false,"description":"m","homepage":null,"default_branch":"main","visibility":"public","archived":false,"allow_auto_merge":false,"allow_merge_commit":true,"allow_squash_merge":true,"allow_rebase_merge":true,"delete_branch_on_merge":false,"has_issues":true,"has_wiki":false,"has_projects":false}\n' "$REPO"
}

# Round 116 (review-lens round 102, C1; owner): an answer is shown complete and consistent before it is
# classed allowed or refused. Through curl, a 2xx cut, failed, unreported, or disagreeing with curl's own
# report is inconclusive, as a 403 would be; through gh (a2-probe), gh's exit must agree with GitHub's
# status too. An incomplete 2xx to a2-probe still keeps the number GitHub gave, for the clean-up.
test_an_answer_is_complete_and_consistent_before_it_is_allowed_or_refused() {
  local case name changes meta rc want
  local -a ch
  for case in "a whole 200|status=HTTP/2 200;body={}||0|allowed" \
    "a whole 204|status=HTTP/2 204;body=||0|allowed" \
    "a 200 cut (curl 18)|status=HTTP/2 200;len=999||18|inconclusive" \
    "a whole 200, then curl fails (56)|status=HTTP/2 200||56|inconclusive" \
    "a 200 shorter than its Content-Length|status=HTTP/2 200;len=999||0|inconclusive" \
    "a 200 in a transfer encoding|status=HTTP/2 200;add=Transfer-Encoding: chunked||0|inconclusive" \
    "a 200 cut before its headers end|status=HTTP/2 200;cut||0|inconclusive" \
    "a 200 curl reports as a 403|status=HTTP/2 200|403 0 0 @URL@|0|inconclusive" \
    "a 200 after a redirect curl followed|status=HTTP/2 200|200 1 0 @URL@|0|inconclusive" \
    "a 200 with TLS not verified|status=HTTP/2 200|200 0 1 @URL@|0|inconclusive" \
    "a 200 from another address|status=HTTP/2 200|200 0 0 https://api.github.com/repos/someone/else|0|inconclusive" \
    "a 200 with no report of curl's|status=HTTP/2 200|none|0|inconclusive" \
    "a 200 whose report isn't of its form|status=HTTP/2 200|200 x 0 @URL@|0|inconclusive"; do
    IFS='|' read -r name changes meta rc want <<<"$case"
    p_stubs
    IFS=';' read -r -a ch <<<"$changes"
    gh_reply reply ${ch[@]+"${ch[@]}"}
    printf '%s' "${meta//@URL@/https://api.github.com/repos/$REPO}" >"$T_TMP/curl-meta"
    echo "$rc" >"$T_TMP/curl-rc"
    curl_stand_in
    WRITES_UNKNOWN="" WRITES_OUT=""
    app_attempt -X PATCH "repos/$REPO" -f description=x >/dev/null 2>&1
    assert_eq "$OBS" "$want" "through curl, $name"
    assert_contains "$(unknown_writes)" "app gh api PATCH repos/$REPO (" "$name: the attempt named outcome unknown"
  done
  # Through gh: its exit (0 for GitHub's 2xx, 1 for an HTTP error) must agree with the status.
  for case in "gh exit 0, a whole 200|status=HTTP/2.0 200 OK|0|allowed" \
    "gh exit 1, a whole 403||1|refused" \
    "gh exit 0, a 200 cut|status=HTTP/2.0 200 OK;len=999|0|inconclusive" \
    "gh exit 0, a 200 in a transfer encoding|status=HTTP/2.0 200 OK;add=Transfer-Encoding: chunked|0|inconclusive" \
    "gh exit 0, no status line|raw={}|0|inconclusive" \
    "gh exit 0, a whole 403||0|inconclusive" \
    "gh exit 1, a whole 200|status=HTTP/2.0 200 OK|1|inconclusive" \
    "gh exit 0, a whole 302|status=HTTP/2.0 302 Found|0|inconclusive"; do
    IFS='|' read -r name changes rc want <<<"$case"
    p_stubs
    IFS=';' read -r -a ch <<<"$changes"
    gh_reply reply ${ch[@]+"${ch[@]}"}
    http_answer "$(cat "$T_TMP/reply")" "$rc"
    LAST_RC=$rc
    api_verdict administration=write 1
    assert_eq "$OBS" "$want" "through gh, $name"
  done
  # a2-probe: an issue made, its answer short of its Content-Length: inconclusive, its number kept.
  p_stubs
  gh_reply reply "status=HTTP/2.0 201 Created" 'body={"number":5}' len=999 "drop=X-Accepted-Github-Permissions" "add=X-Accepted-Github-Permissions: issues=write"
  probe_run() { echo "probe_run $*" >>"$T_TMP/calls"; cat "$T_TMP/reply"; }
  PROBE_MADE="" PROBE_LABEL=tok3
  probe_attempt "an issue" issue .number -X POST "repos/$REPO2/issues" -f title=t >/dev/null 2>&1
  assert_eq "$OBS" inconclusive "a2-probe's issue, its answer incomplete"
  assert_contains "$PROBE_MADE" "issue:5" "the issue's number kept for the clean-up"
  end_stand_in_run
}

# A page of a paged list for the next test, to $T_TMP/<kind>-<n>: <kind> rs (rulesets, a list) or bp (the
# branch policies, with their total_count); <spec> <a>-<b> the entries with ids a to b (bp: <a>-<b>/<total>),
# "end" an empty page (bp: end/<total>), "fail" a read that fails, anything else that text as the page.
list_page() { # <kind> <n> <spec>
  local f="$T_TMP/$1-$2" a b t
  case "$3" in
    fail) rm -f "$f" ;;
    end) echo '[]' >"$f" ;;
    end/*) jq -c -n --argjson t "${3#end/}" '{total_count: $t, branch_policies: []}' >"$f" ;;
    [0-9]*-[0-9]*)
      a="${3%%-*}" b="${3#*-}"
      t="${b#*/}" b="${b%%/*}"
      if [[ "$1" == rs ]]; then
        jq -c -n --argjson a "$a" --argjson b "$b" '[range($a; $b + 1) | {id: ., name: "r\(.)"}]' >"$f"
      else
        jq -c -n --argjson a "$a" --argjson b "$b" --argjson t "$t" '{total_count: $t, branch_policies: [range($a; $b + 1) | {id: ., name: "b\(.)", type: "branch"}]}' >"$f"
      fi ;;
    *) printf '%s\n' "$3" >"$f" ;;
  esac
}

# The same page as gh api -i prints it (round 118), to $T_TMP/<kind>-<n>.raw: list_page's body for <spec>
# (none for "fail": that read fails) in GitHub's 200, changed by each <change>: link=<rel>:<page>,… (a
# Link header in GitHub's form, gh_link's), name=<that header's name>, hdr=<a header line>, status=<line>,
# cut (no empty line after the headers, no body), raw=<the whole answer, as printf %b reads it>, rc=<gh's
# exit status>. In a change, + is a space. Round 119: a Content-Length of the body's bytes unless a cl
# change or nocl is given: cl (one of the body's bytes), cl=<n>, cl=+<k> or cl=-<k> (the body's bytes
# and k more or fewer), each a Content-Length of its own; nocl, none; nl, a newline more at the body's end.
list_answer() { # <kind> <n> <spec> [change…]
  local LC_ALL=C f="$T_TMP/$1-$2" c v body status="HTTP/2.0 200 OK" lname=Link links="" cut="" raw="" nocl=""
  local -a heads=("Content-Type: application/json; charset=utf-8") cls=()
  rm -f "$f.raw" "$f.rc"
  list_page "$1" "$2" "$3"
  [[ -f "$f" ]] || return 0
  body="$(cat "$f")"
  shift 3
  for c in ${1+"$@"}; do
    v="${c#*=}" v="${v//+/ }"
    case "$c" in
      link=*) links="$v" ;;
      name=*) lname="$v" ;;
      hdr=*) heads+=("$v") ;;
      cl | cl=*) cls+=("$c") ;;
      nocl) nocl=1 ;;
      nl) body="$body"$'\n' ;;
      status=*) status="$v" ;;
      cut) cut=1 ;;
      raw=*) raw="$v" ;;
      rc=*) echo "$v" >"$f.rc" ;;
    esac
  done
  if [[ -n "$raw" ]]; then printf '%b' "$raw" >"$f.raw"; return 0; fi
  [[ ${#cls[@]} -gt 0 || -n "$nocl" ]] || cls=(cl)
  for c in ${cls[@]+"${cls[@]}"}; do
    case "$c" in
      cl) v="${#body}" ;;
      cl=+*) v=$((${#body} + ${c#cl=+})) ;;
      cl=-*) v=$((${#body} - ${c#cl=-})) ;;
      *) v="${c#cl=}" ;;
    esac
    heads+=("Content-Length: $v")
  done
  [[ -z "$links" ]] || heads+=("$lname: $(gh_link "$links")")
  {
    printf '%s\r\n' "$status"
    for c in "${heads[@]}"; do printf '%s\r\n' "$c"; done
    [[ -n "$cut" ]] || printf '\r\n%s' "$body"
  } >"$f.raw"
}

# A case's pages, "<n>=<spec>[!<change>…] …", each written by list_answer; a page with no link= or nolink
# change names the next page as GitHub would, when the case has one with entries (not end, end/<t> or []).
list_answers() { # <kind> <pages>
  local i j p n spec next
  local -a part ch more
  read -r -a part <<<"$2"
  for ((i = 0; i < ${#part[@]}; i++)); do
    p="${part[$i]}" n="${p%%=*}"
    IFS='!' read -r -a ch <<<"${p#*=}"
    spec="${ch[0]}" more=()
    for ((j = 1; j < ${#ch[@]}; j++)); do more+=("${ch[$j]}"); done
    next=""
    if [[ $((i + 1)) -lt ${#part[@]} ]]; then next="${part[$((i + 1))]#*=}" next="${next%%!*}"; fi
    if [[ " ${more[*]-} " != *" link="* && " ${more[*]-} " != *" nolink "* && -n "$next" && "$next" != end* && "$next" != '[]' ]]; then
      more+=("link=next:$((n + 1))")
    fi
    list_answer "$1" "$n" "$spec" ${more[@]+"${more[@]}"}
  done
}

# Round 116 (review-lens round 102, C2 = SEC-1, C3; owner): a list GitHub gives in pages is read whole:
# each page asked at an address built on the fixed endpoint (per_page=100&page=<n>; never a Link URL of
# GitHub's, never gh's --paginate). Bounded: 10 pages (so 1,000 entries), and no page or ruleset asked
# once 60s have passed. A page missing, malformed, over-full or repeating an entry, or (the branch
# policies) a total_count that changes between pages or differs from the unique entries collected,
# leaves the baseline unreadable.
# Round 117 (review-lens round 103, SEC-1, C2; owner): read through to an empty page, never ending at a
# short one (a short page in the middle can't hide later ones); 10 pages with entries (so exactly 1,000
# read) and the empty one that ends them; an entry on an 11th page, or no empty page in time, unreadable.
# Round 118: each page as gh api -i prints it, naming the next page as GitHub would (list_answers).
test_a_paged_list_is_read_whole_at_its_own_addresses() {
  local case name kind pages step want asked full="" fbp="" all="" short="" i got out n p
  for i in 1 2 3 4 5 6 7 8 9 10; do
    full="$full $i=$(((i - 1) * 100 + 1))-$((i * 100))" all="$all $i"
    fbp="$fbp $i=$(((i - 1) * 100 + 1))-$((i * 100))/1000" short="$short $i=$i-$i"
  done
  # <name>|<kind>|<n>=<spec> for each page|<seconds each page read takes>|<entries read, or unreadable>|<pages asked>
  for case in "one page, not full, then the empty one|rs|1=1-2 2=end|0|2|1 2" \
    "no rulesets: the first page empty|rs|1=end|0|0|1" \
    "two pages|rs|1=1-100 2=101-101 3=end|0|101|1 2 3" \
    "a full page, then an empty one|rs|1=1-100 2=end|0|100|1 2" \
    "a short page in the middle|rs|1=1-40 2=41-45 3=46-145 4=end|0|145|1 2 3 4" \
    "a short page, the page after it failing|rs|1=1-2 2=fail|0|unreadable|1 2" \
    "a second page that fails|rs|1=1-100 2=fail|0|unreadable|1 2" \
    "the empty page that ends the list failing|rs|1=1-100 2=101-150 3=fail|0|unreadable|1 2 3" \
    "a second page not a list|rs|1=1-100 2={}|0|unreadable|1 2" \
    "a second page repeating an entry|rs|1=1-100 2=100-100|0|unreadable|1 2" \
    "the first page again|rs|1=1-100 2=1-100|0|unreadable|1 2" \
    "a short page again|rs|1=1-2 2=1-2|0|unreadable|1 2" \
    "a page with more than a page's entries|rs|1=1-101|0|unreadable|1" \
    "an entry whose id isn't a whole number|rs|1=[{\"id\":1.5}]|0|unreadable|1" \
    "exactly 1,000 entries: ten full pages, then the empty one|rs|${full# } 11=end|0|1000|${all# } 11" \
    "an entry on an 11th page|rs|${full# } 11=1001-1001|0|unreadable|${all# } 11" \
    "ten short pages, then an 11th with an entry|rs|${short# } 11=11-11|0|unreadable|${all# } 11" \
    "60s passed before the third page|rs|1=1-100 2=101-200 3=201-201|30|unreadable|1 2" \
    "60s passed before the empty page that ends the list|rs|1=1-100 2=101-150 3=end|30|unreadable|1 2" \
    "the same, in time|rs|1=1-100 2=101-200 3=201-201 4=end|0|201|1 2 3 4" \
    "60s passed before its rulesets were read by id|rs|1=1-2 2=end|30|unreadable|1 2" \
    "branch policies, one page|bp|1=1-2/2 2=end/2|0|2|1 2" \
    "branch policies, none|bp|1=end/0|0|0|1" \
    "branch policies, two pages|bp|1=1-100/101 2=101-101/101 3=end/101|0|101|1 2 3" \
    "branch policies, a short page in the middle|bp|1=1-3/5 2=4-5/5 3=end/5|0|5|1 2 3" \
    "branch policies, exactly 1,000|bp|${fbp# } 11=end/1000|0|1000|${all# } 11" \
    "a total_count above the entries|bp|1=1-2/3 2=end/3|0|unreadable|1 2" \
    "a total_count below the entries|bp|1=1-2/1 2=end/1|0|unreadable|1 2" \
    "a total_count changing between pages|bp|1=1-100/101 2=101-101/102|0|unreadable|1 2" \
    "a total_count changing on the empty page|bp|1=1-2/2 2=end/3|0|unreadable|1 2" \
    "an entry twice, the total_count counting both|bp|1={\"total_count\":2,\"branch_policies\":[{\"id\":1,\"name\":\"b1\"},{\"id\":1,\"name\":\"b1\"}]}|0|unreadable|1" \
    "a total_count not a number|bp|1={\"total_count\":\"2\",\"branch_policies\":[{\"id\":1,\"name\":\"b1\"},{\"id\":2,\"name\":\"b2\"}]}|0|unreadable|1" \
    "a page without its list|bp|1={\"total_count\":0}|0|unreadable|1" \
    "a second page that fails|bp|1=1-100/101 2=fail|0|unreadable|1 2" \
    "the empty page that ends the policies failing|bp|1=1-2/2 2=fail|0|unreadable|1 2"; do
    IFS='|' read -r name kind pages step want asked <<<"$case"
    paged_case
  done
  end_stand_in_run
}

# One case of the paged-list tests, from its name, kind, pages, step, want and asked: the clock moves only
# as GitHub answers a page (or a ruleset by id), by <step> seconds. What the reader printed, its errors
# too, is in $T_TMP/paged-out.
paged_case() {
  local got=0 out="" n p
  p_stubs
  rm -f "$T_TMP"/rs-* "$T_TMP"/bp-*
  list_answers "$kind" "$pages"
  echo 0 >"$T_TMP/clock"
  echo "$step" >"$T_TMP/step"
  date() { if [[ "$*" == +%s ]]; then cat "$T_TMP/clock"; else command date "$@"; fi; }
  owner_gh() {
    local a="$*" k rc=0
    echo "owner_gh $a" >>"$T_TMP/calls"
    # A page asked without -i: its body alone, as gh prints it then.
    case "${a/api -i /api }" in
      "api repos/$REPO/rulesets?per_page=100&page="*) k=rs ;;
      "api repos/$REPO/environments/$ENV_NAME/deployment-branch-policies?per_page=100&page="*) k=bp ;;
      "api repos/$REPO/rulesets/"*)
        printf '{"id":%s,"name":"r","enforcement":"active","target":"branch","rules":[]}\n' "${a##*/}"
        return 0 ;;
      "api repos/$REPO/environments/$ENV_NAME") printf '{"name":"%s","protection_rules":[],"updated_at":"t"}\n' "$ENV_NAME"; return 0 ;;
      "api repos/$REPO/environments/$ENV_NAME/secrets/$DISPOSABLE_NAME") printf '{"name":"%s","created_at":"t","updated_at":"t"}\n' "$DISPOSABLE_NAME"; return 0 ;;
      *) echo "gh: HTTP 404" >&2; return 1 ;;
    esac
    echo $(($(cat "$T_TMP/clock") + $(cat "$T_TMP/step"))) >"$T_TMP/clock"
    k="$T_TMP/$k-${a##*page=}"
    [[ -f "$k.raw" ]] || { echo "gh: HTTP 502" >&2; return 1; }
    [[ ! -f "$k.rc" ]] || rc="$(cat "$k.rc")"
    if [[ "$a" == "api -i "* ]]; then cat "$k.raw"; else cat "$k"; fi
    return "$rc"
  }
  if [[ "$kind" == rs ]]; then
    (state_rulesets) >"$T_TMP/paged-out" 2>&1 || got=$?
    n="$(jq length "$T_TMP/paged-out" 2>/dev/null)"
  else
    (state_environment) >"$T_TMP/paged-out" 2>&1 || got=$?
    n="$(jq '.policies | length' "$T_TMP/paged-out" 2>/dev/null)"
  fi
  out="$(cat "$T_TMP/paged-out")"
  if [[ "$want" == unreadable ]]; then
    [[ "$got" != 0 ]] || _t_fail "$name: read as a state"
  else
    assert_exit 0 "$got" "$name: read as a state"
    assert_eq "$n" "$want" "$name: the entries read"
  fi
  p="$(sed -n -E 's/^owner_gh api -i repos\/[^?]+\?per_page=100&page=([0-9]+)$/\1/p' "$T_TMP/calls" | tr '\n' ' ')"
  assert_eq "${p% }" "$asked" "$name: the pages asked"
  assert_eq "$(grep -c 'page=' "$T_TMP/calls")" "$(wc -w <<<"$asked" | tr -d ' ')" "$name: a page asked at another address"
  assert_not_contains "$(cat "$T_TMP/calls")" "--paginate" "$name: gh following GitHub's links"
  assert_not_contains "$(cat "$T_TMP/calls")" "links.example" "$name: a Link URL asked"
  assert_not_contains "$out" "links.example" "$name: a Link URL printed"
  unset -f date
}

# Round 118 (review-lens round 104, SEC-1; owner): each page is read with its headers (gh api -i), its
# Link header read for its page numbers only, never followed or printed. A page counts only when gh
# exits 0 with GitHub's 200, its headers whole (each a name and a value, ended by an empty line) and its
# body one JSON value of its kind: an array or object, which a cut answer can't be, as the bracket that
# closes it ends it. A Content-Length, where there is one, must be the body's bytes (unless an encoding
# is named). At most one Link (any case), in GitHub's form: <URL>; rel="next|prev|first|last" (any case),
# each once, its URL with one page=<n> and at most one per_page=100. The pages must agree: next names
# n+1, prev n-1, first 1, last the list's last page with entries; a page names a next page exactly when
# the page after it has entries, and the empty page that ends the list names none. Anything else, the
# baseline unreadable.
# Round 119 (review-lens round 105, C1 = SEC-1, C2, C3; owner): one JSON value is a parsing check, not
# proof the answer is whole; gh's exit 0 stays required. Every page needs one Content-Length, exactly its
# body's bytes as gh printed them, trailing newlines too (into -b keeps them); none, or another number,
# unreadable, so a cut that still parses is refused. A Content-Encoding other than identity, or any
# Transfer-Encoding (any case), unreadable. A Link URL's query exactly page=<n> and at most one
# per_page=100, in either order, nothing else: the only parameters the reader sends.
test_a_lists_pages_must_agree_with_their_headers() {
  local case name kind pages step=0 want asked u l1 l2
  # Each Link's form is tested on a one-page list, whose page 1 may name itself first and last: read
  # whole when the form is right (the first cases), unreadable for that form alone when it isn't.
  u='https://links.example.invalid/repositories/1/list'
  l1="Link:+<$u?per_page=100&page=1>;+rel=\"first\"" l2="<$u?per_page=100&page=1>;+rel=\"last\""
  # <name>|<kind>|<pages, as list_answers reads them>|<entries read, or unreadable>|<pages asked>
  for case in "no Link on one page|rs|1=1-2 2=end|2|1 2" \
    "next, then prev, first and last on the pages after|rs|1=1-100!link=next:2,last:2 2=101-101!link=prev:1,first:1,last:2 3=end!link=prev:2,first:1,last:2|101|1 2 3" \
    "the header named link|rs|1=1-100!name=link 2=101-101 3=end|101|1 2 3" \
    "the header named LINK|rs|1=1-100!name=LINK 2=101-101 3=end|101|1 2 3" \
    "rel in capitals|rs|1=1-100!link=NEXT:2 2=101-101 3=end|101|1 2 3" \
    "a Content-Length of the body's bytes|rs|1=1-2!cl 2=end!cl|2|1 2" \
    "Content-Encoding identity|rs|1=1-2!hdr=Content-Encoding:+identity 2=end|2|1 2" \
    "a body ending in a newline its Content-Length counts|rs|1=1-2!nl 2=end!nl|2|1 2" \
    "a body ending in two newlines its Content-Length counts|rs|1=1-2!nl!nl 2=end|2|1 2" \
    "branch policies, bodies ending in a newline counted|bp|1=1-2/2!nl 2=end/2!nl|2|1 2" \
    "a trailing newline its Content-Length doesn't count|rs|1=1-2!nl!cl=-1 2=end|unreadable|1" \
    "the empty page's trailing newline not counted|rs|1=1-2 2=end!nl!cl=-1|unreadable|1 2" \
    "two trailing newlines, one counted|rs|1=1-2!nl!nl!cl=-1 2=end|unreadable|1" \
    "a Content-Length counting a newline the body lacks|rs|1=1-2!cl=+1 2=end|unreadable|1" \
    "a Content-Length written out|rs|1=1-2!cl=43 2=end|2|1 2" \
    "the same with a leading zero|rs|1=1-2!cl=043 2=end|unreadable|1" \
    "no Content-Length|rs|1=1-2!nocl 2=end|unreadable|1" \
    "the empty page that ends the list with no Content-Length|rs|1=1-2 2=end!nocl|unreadable|1 2" \
    "an empty first page with no Content-Length|rs|1=end!nocl|unreadable|1" \
    "branch policies, no Content-Length|bp|1=1-2/2!nocl 2=end/2|unreadable|1" \
    "a cut answer still one JSON value: an empty page short of its length|rs|1=1-2 2=end!cl=+20|unreadable|1 2" \
    "the same, gzip named|rs|1=1-2 2=end!cl=+20!hdr=Content-Encoding:+gzip|unreadable|1 2" \
    "the same, with gh failing|rs|1=1-2 2=end!rc=1|unreadable|1 2" \
    "a Content-Length unlike the body, an encoding named|rs|1=1-2!cl=7!hdr=Content-Encoding:+gzip 2=end|unreadable|1" \
    "gzip named, the length the body's|rs|1=1-2!hdr=Content-Encoding:+gzip 2=end|unreadable|1" \
    "br named, in lower case|rs|1=1-2!hdr=content-encoding:+br 2=end|unreadable|1" \
    "gzip named, in capitals|rs|1=1-2!hdr=CONTENT-ENCODING:+gzip 2=end|unreadable|1" \
    "an empty Content-Encoding|rs|1=1-2!hdr=Content-Encoding: 2=end|unreadable|1" \
    "identity, then gzip|rs|1=1-2!hdr=Content-Encoding:+identity!hdr=Content-Encoding:+gzip 2=end|unreadable|1" \
    "Transfer-Encoding chunked|rs|1=1-2!hdr=Transfer-Encoding:+chunked 2=end|unreadable|1" \
    "transfer-encoding identity, in lower case|rs|1=1-2!hdr=transfer-encoding:+identity 2=end|unreadable|1" \
    "on the empty page, Transfer-Encoding chunked|rs|1=1-2 2=end!hdr=Transfer-Encoding:+chunked|unreadable|1 2" \
    "an empty page naming a next page|rs|1=1-100 2=end!link=next:3|unreadable|1 2" \
    "an empty page naming a next page, link in lower case|rs|1=1-100 2=end!name=link!link=next:3|unreadable|1 2" \
    "an empty page naming a next page, rel in mixed case|rs|1=1-100 2=end!link=Next:3|unreadable|1 2" \
    "an empty first page naming a next page|rs|1=end!link=next:2|unreadable|1" \
    "branch policies, an empty page naming a next page|bp|1=1-100/100 2=end/100!link=next:3|unreadable|1 2" \
    "entries after a page that named no next page|rs|1=1-40!nolink 2=41-45 3=end|unreadable|1 2" \
    "branch policies, entries after a page that named no next|bp|1=1-3/5!nolink 2=4-5/5 3=end/5|unreadable|1 2" \
    "a page naming a next page, then an empty one|rs|1=1-2!link=next:2 2=end|unreadable|1 2" \
    "next naming page 3 from page 1|rs|1=1-100!link=next:3 2=101-101 3=end|unreadable|1" \
    "prev on the first page|rs|1=1-2!link=prev:1 2=end|unreadable|1" \
    "prev naming another page|rs|1=1-100 2=101-101!link=prev:2 3=end|unreadable|1 2" \
    "first naming page 2|rs|1=1-100!link=next:2,first:2 2=101-101 3=end|unreadable|1" \
    "last naming a page past the list's end|rs|1=1-100!link=next:2,last:3 2=101-101 3=end|unreadable|1 2 3" \
    "last naming the empty page|rs|1=1-2 2=end!link=prev:1,last:2|unreadable|1 2" \
    "last on an empty first page|rs|1=end!link=last:1|unreadable|1" \
    "first and last on a one-page list|rs|1=1-2!hdr=$l1,+$l2 2=end|2|1 2" \
    "first alone, without per_page or spaces|rs|1=1-2!hdr=Link:<$u?page=1>;rel=\"first\" 2=end|2|1 2" \
    "two Link headers|rs|1=1-100!link=next:2!hdr=link:+<$u?page=2>;+rel=\"next\" 2=101-101 3=end|unreadable|1" \
    "two Link headers on a one-page list|rs|1=1-2!hdr=$l1!hdr=link:+$l2 2=end|unreadable|1" \
    "rel twice|rs|1=1-2!hdr=$l1,+<$u?page=1>;+rel=\"first\" 2=end|unreadable|1" \
    "a rel GitHub doesn't give|rs|1=1-2!link=alternate:1 2=end|unreadable|1" \
    "two rels in one|rs|1=1-2!hdr=Link:+<$u?page=1>;+rel=\"first+last\" 2=end|unreadable|1" \
    "no angle brackets|rs|1=1-2!hdr=Link:+$u?page=1;+rel=\"first\" 2=end|unreadable|1" \
    "rel not quoted|rs|1=1-2!hdr=Link:+<$u?page=1>;+rel=first 2=end|unreadable|1" \
    "a trailing comma|rs|1=1-2!hdr=$l1, 2=end|unreadable|1" \
    "two links without a comma|rs|1=1-2!hdr=$l1+$l2 2=end|unreadable|1" \
    "a URL with no query|rs|1=1-2!hdr=Link:+<$u>;+rel=\"first\" 2=end|unreadable|1" \
    "a URL with no page|rs|1=1-2!hdr=Link:+<$u?per_page=100>;+rel=\"first\" 2=end|unreadable|1" \
    "a URL with two pages|rs|1=1-2!hdr=Link:+<$u?page=1&page=1>;+rel=\"first\" 2=end|unreadable|1" \
    "a URL with two page sizes|rs|1=1-2!hdr=Link:+<$u?per_page=100&per_page=100&page=1>;+rel=\"first\" 2=end|unreadable|1" \
    "a URL with another page size|rs|1=1-2!hdr=Link:+<$u?per_page=30&page=1>;+rel=\"first\" 2=end|unreadable|1" \
    "page 0|rs|1=1-2!hdr=Link:+<$u?page=0>;+rel=\"first\" 2=end|unreadable|1" \
    "a page not a number|rs|1=1-2!hdr=Link:+<$u?page=1x>;+rel=\"first\" 2=end|unreadable|1" \
    "a Link with nothing in it|rs|1=1-2!hdr=Link: 2=end|unreadable|1" \
    "a URL with a space|rs|1=1-2!hdr=Link:+<$u?a=b+c&page=1>;+rel=\"first\" 2=end|unreadable|1" \
    "page, then per_page|rs|1=1-2!hdr=Link:+<$u?page=1&per_page=100>;+rel=\"first\" 2=end|2|1 2" \
    "a URL with another parameter|rs|1=1-2!hdr=Link:+<$u?page=1&sort=asc>;+rel=\"first\" 2=end|unreadable|1" \
    "a URL with another parameter first|rs|1=1-2!hdr=Link:+<$u?direction=desc&per_page=100&page=1>;+rel=\"first\" 2=end|unreadable|1" \
    "another parameter after page and per_page|rs|1=1-2!hdr=Link:+<$u?page=1&per_page=100&x=1>;+rel=\"first\" 2=end|unreadable|1" \
    "another parameter before page and per_page|rs|1=1-2!hdr=Link:+<$u?x=1&page=1&per_page=100>;+rel=\"first\" 2=end|unreadable|1" \
    "another parameter after per_page and page|rs|1=1-2!hdr=Link:+<$u?per_page=100&page=1&x=1>;+rel=\"first\" 2=end|unreadable|1" \
    "a URL with an encoded second page|rs|1=1-2!hdr=Link:+<$u?page=1&%70age=9>;+rel=\"first\" 2=end|unreadable|1" \
    "a URL with an encoded page size|rs|1=1-2!hdr=Link:+<$u?per%5Fpage=30&page=1>;+rel=\"first\" 2=end|unreadable|1" \
    "a page number encoded|rs|1=1-2!hdr=Link:+<$u?page=%31>;+rel=\"first\" 2=end|unreadable|1" \
    "a per_page with no value|rs|1=1-2!hdr=Link:+<$u?page=1&per_page>;+rel=\"first\" 2=end|unreadable|1" \
    "a per_page with no =|rs|1=1-2!hdr=Link:+<$u?per_page&page=1>;+rel=\"first\" 2=end|unreadable|1" \
    "an empty part between|rs|1=1-2!hdr=Link:+<$u?page=1&&per_page=100>;+rel=\"first\" 2=end|unreadable|1" \
    "an empty part at the end|rs|1=1-2!hdr=Link:+<$u?page=1&>;+rel=\"first\" 2=end|unreadable|1" \
    "an empty part at the start|rs|1=1-2!hdr=Link:+<$u?&page=1>;+rel=\"first\" 2=end|unreadable|1" \
    "a part with no name|rs|1=1-2!hdr=Link:+<$u?page=1&=1>;+rel=\"first\" 2=end|unreadable|1" \
    "a second question mark|rs|1=1-2!hdr=Link:+<$u?page=1?x=1>;+rel=\"first\" 2=end|unreadable|1" \
    "a fragment|rs|1=1-2!hdr=Link:+<$u?page=1#x>;+rel=\"first\" 2=end|unreadable|1" \
    "a next page's URL with page alone|rs|1=1-100!nolink!hdr=Link:+<$u?page=2>;+rel=\"next\" 2=101-101 3=end|101|1 2 3" \
    "another parameter on a next page's URL|rs|1=1-100!nolink!hdr=Link:+<$u?page=2&q=1>;+rel=\"next\" 2=101-101 3=end|unreadable|1" \
    "no empty line after the headers|rs|1=1-2!cut|unreadable|1" \
    "the body cut short|rs|1=[{\"id\":1},{\"id\":2|unreadable|1" \
    "an empty page cut short|rs|1=1-2 2=[|unreadable|1 2" \
    "an empty body|rs|1=1-2 2=!cl=0|unreadable|1 2" \
    "no status line|rs|1=1-2!raw=[{\"id\":1}] 2=end|unreadable|1" \
    "HTTP 206|rs|1=1-2!status=HTTP/2.0+206+Partial+Content 2=end|unreadable|1" \
    "HTTP 304|rs|1=1-2!status=HTTP/2.0+304+Not+Modified 2=end|unreadable|1" \
    "a 200 with gh failing|rs|1=1-2!rc=1 2=end|unreadable|1" \
    "a 200 with gh timed out|rs|1=1-2!rc=124 2=end|unreadable|1" \
    "a header line without a colon|rs|1=1-2!hdr=X-Note 2=end|unreadable|1" \
    "a folded header line|rs|1=1-2!hdr=+continued 2=end|unreadable|1" \
    "a header name not of its form|rs|1=1-2!hdr=X+Y:+1 2=end|unreadable|1" \
    "a Content-Length longer than the body|rs|1=1-2!cl=500 2=end|unreadable|1" \
    "a Content-Length shorter than the body|rs|1=1-2!cl=3 2=end|unreadable|1" \
    "two Content-Lengths|rs|1=1-2!cl!cl 2=end|unreadable|1" \
    "a Content-Length not a number|rs|1=1-2!cl=7x 2=end|unreadable|1" \
    "a Content-Length not a number, an encoding named|rs|1=1-2!cl=7x!hdr=Content-Encoding:+gzip 2=end|unreadable|1" \
    "a body not JSON|rs|1=nope|unreadable|1" \
    "two JSON values|rs|1=[]!raw=HTTP/2.0+200+OK\r\n\r\n[]+[]|unreadable|1"; do
    IFS='|' read -r name kind pages want asked <<<"$case"
    paged_case
  done
  end_stand_in_run
}

# Round 117 (review-lens round 103, C1 = SEC-2; owner): A2's branches and tags are read from their own
# lists, which GitHub documents as paged (per_page, page), each whole through the bounded reader (an
# empty page ends it; never matching-refs, whose pages GitHub doesn't document, nor gh's --paginate);
# each entry a name, not seen before, with a commit. t_A2's own before-and-after read is the same one.
# Round 117b (owner): each listed tag is then looked up once by its exact ref (git/ref/tags/<name>): the
# answer must be that ref, of kind commit (then the list's commit) or tag, with a 40-hex id, and its kind
# and id are kept, so an annotated tag made again on the same commit reads changed. A name outside the
# plain set (looked up never), more than 100 tags, a lookup that fails (a rate limit too: never asked
# again) or answers anything else, or one not asked within 60s of the tags list's start: unreadable.
test_a2s_branches_and_tags_are_read_from_their_paged_lists() {
  local case name heads tags refs want got out a b c p br t100 t101 w100 calls bad
  local -a part
  a="$(printf 'a%.0s' $(seq 1 40))" b="$(printf 'b%.0s' $(seq 1 40))" c="$(printf 'c%.0s' $(seq 1 40))"
  T() { printf '{"name":"%s","commit":{"sha":"%s"}}' "$1" "$2"; }       # a list entry
  R() { printf '{"ref":"refs/tags/%s","object":{"type":"%s","sha":"%s"}}' "$1" "$2" "$3"; } # a lookup's answer
  br="1=[$(T m "$a")] 2=[]"
  t100="$(jq -c -n --arg b "$b" '[range(1; 101) | {name: "t\(.)", commit: {sha: $b}}]')"
  t101="$(jq -c -n --arg b "$b" '[{name: "t101", commit: {sha: $b}}]')"
  w100="$(jq -S -c -n --arg a "$a" --arg b "$b" '{heads: [{ref: "refs/heads/m", sha: $a}], tags: ([range(1; 101) | {ref: "refs/tags/t\(.)", sha: $b, type: "commit", object: $b}] | sort_by(.ref))}')"
  # <name>|<branches page=JSON …>|<tags page=JSON …>|<tag=its lookup's answer …; @429 a rate limit, @auto
  # each a plain tag on b>|<the state, or unreadable (", none looked up": no lookup asked)>
  for case in "one branch, no tag|1=[$(T frg26-a2 "$a")] 2=[]|1=[]||{\"heads\":[{\"ref\":\"refs/heads/frg26-a2\",\"sha\":\"$a\"}],\"tags\":[]}" \
    "a branch and a plain tag of one name|1=[$(T v1 "$a")] 2=[]|1=[$(T v1 "$b")] 2=[]|v1=$(R v1 commit "$b")|{\"heads\":[{\"ref\":\"refs/heads/v1\",\"sha\":\"$a\"}],\"tags\":[{\"ref\":\"refs/tags/v1\",\"sha\":\"$b\",\"type\":\"commit\",\"object\":\"$b\"}]}" \
    "an annotated tag|$br|1=[$(T v1 "$b")] 2=[]|v1=$(R v1 tag "$c")|{\"heads\":[{\"ref\":\"refs/heads/m\",\"sha\":\"$a\"}],\"tags\":[{\"ref\":\"refs/tags/v1\",\"sha\":\"$b\",\"type\":\"tag\",\"object\":\"$c\"}]}" \
    "a tag name with a slash|$br|1=[$(T release/v1 "$b")] 2=[]|release/v1=$(R release/v1 commit "$b")|{\"heads\":[{\"ref\":\"refs/heads/m\",\"sha\":\"$a\"}],\"tags\":[{\"ref\":\"refs/tags/release/v1\",\"sha\":\"$b\",\"type\":\"commit\",\"object\":\"$b\"}]}" \
    "exactly 100 tags, each looked up|$br|1=$t100 2=[]|@auto|$w100" \
    "101 tags|$br|1=$t100 2=$t101 3=[]|@auto|unreadable, none looked up" \
    "a short page in the middle|1=[$(T m "$a")] 2=[$(T n "$b")] 3=[]|1=[]||{\"heads\":[{\"ref\":\"refs/heads/m\",\"sha\":\"$a\"},{\"ref\":\"refs/heads/n\",\"sha\":\"$b\"}],\"tags\":[]}" \
    "no branch|1=[]|1=[]||unreadable" \
    "a branch twice, on two pages|1=[$(T m "$a")] 2=[$(T m "$a")]|1=[]||unreadable" \
    "a tag twice|$br|1=[$(T t "$a"),$(T t "$a")]|t=$(R t commit "$a")|unreadable, none looked up" \
    "a branch without a name|1=[{\"commit\":{\"sha\":\"$a\"}}]|1=[]||unreadable" \
    "a branch whose name is empty|1=[$(T "" "$a")] 2=[]|1=[]||unreadable" \
    "a branch whose name isn't a string|1=[{\"name\":7,\"commit\":{\"sha\":\"$a\"}}] 2=[]|1=[]||unreadable" \
    "a branch without its commit|1=[{\"name\":\"m\"}] 2=[]|1=[]||unreadable" \
    "a tag whose commit isn't a commit id|$br|1=[$(T t main)] 2=[]||unreadable, none looked up" \
    "the branches' empty page failing|1=[$(T m "$a")]|1=[]||unreadable" \
    "the tags' read failing|$br|||unreadable" \
    "the tags as an object|$br|1={}||unreadable" \
    "a tag's lookup failing|$br|1=[$(T v1 "$b")] 2=[]||unreadable" \
    "a tag's lookup rate limited|$br|1=[$(T v1 "$b")] 2=[]|v1=@429|unreadable" \
    "a lookup naming another ref|$br|1=[$(T v1 "$b")] 2=[]|v1=$(R v2 commit "$b")|unreadable" \
    "a lookup answering a list, as a prefix match would|$br|1=[$(T v1 "$b")] 2=[]|v1=[$(R v1 commit "$b")]|unreadable" \
    "a plain tag on another commit than listed|$br|1=[$(T v1 "$b")] 2=[]|v1=$(R v1 commit "$c")|unreadable" \
    "a lookup of another kind of object|$br|1=[$(T v1 "$b")] 2=[]|v1=$(R v1 tree "$b")|unreadable" \
    "a lookup whose id isn't one|$br|1=[$(T v1 "$b")] 2=[]|v1=$(R v1 tag main)|unreadable" \
    "a lookup without its object|$br|1=[$(T v1 "$b")] 2=[]|v1={\"ref\":\"refs/tags/v1\"}|unreadable" \
    "a lookup not JSON|$br|1=[$(T v1 "$b")] 2=[]|v1=nope|unreadable"; do
    IFS='|' read -r name heads tags refs want <<<"$case"
    a2_list_case
  done
  # A name outside the plain set (letters, digits, . _ - and /, no .., no empty part) is never looked up.
  # (Round 118: the space as JSON's  , so the page stays one word of the case.)
  for bad in 'a b' 'v1?x' 'v%41' 'v#1' 'v~1' 'v:1' 'v^1' 'v*1' 'v[1' 'v\\1' 'v@{1' 'a..b' '/v1' 'v1/' 'a//b' 'v\n1' '.'; do
    name="a tag named $bad" heads="$br" tags="1=[$(T "$bad" "$b")] 2=[]" refs="@auto" want="unreadable, none looked up"
    a2_list_case
  done
  # Every lookup within 60s of the tags list's start: two tags, each request taking 20s; the second
  # lookup would begin 60s after it, so it is never asked.
  name="60s passed before the second tag's lookup" heads="$br" tags="1=[$(T v1 "$b"),$(T v2 "$b")] 2=[]" refs="@auto" want=unreadable
  a2_list_case 20
  assert_eq "$(grep -c 'git/ref/tags/' "$T_TMP/calls")" 1 "$name: the lookups asked"
  name="the same, in time" want="{\"heads\":[{\"ref\":\"refs/heads/m\",\"sha\":\"$a\"}],\"tags\":[{\"ref\":\"refs/tags/v1\",\"sha\":\"$b\",\"type\":\"commit\",\"object\":\"$b\"},{\"ref\":\"refs/tags/v2\",\"sha\":\"$b\",\"type\":\"commit\",\"object\":\"$b\"}]}"
  a2_list_case 0
  # An annotated tag made again on the same commit (a new tag object) reads changed.
  name="an annotated tag" heads="$br" tags="1=[$(T v1 "$b")] 2=[]" refs="v1=$(R v1 tag "$c")" want=state
  a2_list_case
  local first="$out"
  refs="v1=$(R v1 tag "$(printf 'd%.0s' $(seq 1 40))")"
  a2_list_case
  [[ -n "$first" && -n "$out" && "$first" != "$out" ]] || _t_fail "an annotated tag made again on the same commit read unchanged: $first"
  # t_A2 reads them the same way before its attempts (its own read, then the baseline's).
  p_stubs
  a2_answers "app_git -C $T_TMP/clone push https://github.com/$REPO2.git|0|"
  t_A2 >/dev/null 2>&1
  assert_not_contains "$(cat "$T_TMP/calls")" "matching-refs" "t_A2: its refs read by matching-refs"
  assert_contains "$(cat "$T_TMP/calls")" "owner_gh api -i repos/$REPO2/branches?per_page=100&page=1" "t_A2: its branches read"
  unset -f T R
  end_stand_in_run
}

# One case of the test above, from its name, heads, tags, refs and want; [step] the seconds each request
# takes (the clock moves only as GitHub answers). Leaves the state read in out.
a2_list_case() { # [step]
  local p k f
  local -a part
  p_stubs
  rm -f "$T_TMP"/heads-* "$T_TMP"/tags-* "$T_TMP"/ref-*
  # Round 118: each list's pages as gh api -i prints them (list_answers).
  [[ -z "$heads" ]] || list_answers heads "$heads"
  [[ -z "$tags" ]] || list_answers tags "$tags"
  part=()
  [[ -z "$refs" || "$refs" == @auto ]] || read -r -a part <<<"$refs"
  for p in ${part[@]+"${part[@]}"}; do f="${p%%=*}"; printf '%s\n' "${p#*=}" >"$T_TMP/ref-${f//\//%}"; done
  [[ "$refs" != @auto ]] || : >"$T_TMP/ref-auto"
  echo 0 >"$T_TMP/clock"
  echo "${1:-0}" >"$T_TMP/step"
  date() { if [[ "$*" == +%s ]]; then cat "$T_TMP/clock"; else command date "$@"; fi; }
  owner_gh() {
    local a="$*" k n
    echo "owner_gh $a" >>"$T_TMP/calls"
    echo $(($(cat "$T_TMP/clock") + $(cat "$T_TMP/step"))) >"$T_TMP/clock"
    case "$a" in
      "api -i repos/$REPO2/branches?per_page=100&page="* | "api -i repos/$REPO2/tags?per_page=100&page="*)
        k="${a#"api -i repos/$REPO2/"}" k="$T_TMP/${k%%\?*}-${a##*page=}"
        k="${k/branches-/heads-}"
        [[ -f "$k.raw" ]] || { echo "gh: HTTP 502" >&2; return 1; }
        cat "$k.raw"
        return 0 ;;
      "api repos/$REPO2/git/ref/tags/"*)
        n="${a#"api repos/$REPO2/git/ref/tags/"}"
        if [[ -f "$T_TMP/ref-auto" ]]; then
          jq -c -n --arg n "$n" --arg s "$(printf 'b%.0s' $(seq 1 40))" '{ref: "refs/tags/\($n)", object: {type: "commit", sha: $s}}'
          return 0
        fi
        k="ref-${n//\//%}"
        if [[ "$(cat "$T_TMP/$k" 2>/dev/null)" == @429 ]]; then echo "gh: API rate limit exceeded (HTTP 429)" >&2; return 1; fi ;;
      *) echo "gh: HTTP 404" >&2; return 1 ;;
    esac
    [[ -f "$T_TMP/$k" ]] || { echo "gh: HTTP 502" >&2; return 1; }
    cat "$T_TMP/$k"
  }
  local got=0
  out=""
  out="$(state_refs2)" || got=$?
  case "$want" in
    unreadable*) [[ "$got" != 0 ]] || _t_fail "$name: read as a state: $out" ;;
    state) assert_exit 0 "$got" "$name: read as a state" ;;
    *)
      assert_exit 0 "$got" "$name: read as a state"
      assert_eq "$out" "$(jq -S -c . <<<"$want")" "$name: the state" ;;
  esac
  [[ "$want" != *"none looked up"* ]] || assert_not_contains "$(cat "$T_TMP/calls")" "git/ref/" "$name: a tag looked up"
  assert_eq "$(grep 'git/ref/' "$T_TMP/calls" | sort | uniq -d)" "" "$name: a tag looked up twice"
  assert_not_contains "$(cat "$T_TMP/calls")" "matching-refs" "$name: read by matching-refs"
  assert_not_contains "$(cat "$T_TMP/calls")" "--paginate" "$name: gh following GitHub's links"
  unset -f date
}

# Round 116 (review-lens round 102, C4 = SEC-2; owner): every repository setting the baseline compares
# must be in GitHub's answer and of its type, so a setting missing is never read as null: only description
# and homepage may be null, and then only when GitHub says so. The state holds each, so a change to any
# shows.
test_every_compared_repository_setting_is_present_and_of_its_type() {
  local f bad base now
  local strings="default_branch visibility" nullable="description homepage"
  local booleans="archived allow_auto_merge allow_merge_commit allow_squash_merge allow_rebase_merge delete_branch_on_merge has_issues has_wiki has_projects"
  p_stubs
  owner_gh() { cat "$T_TMP/state-answer"; }
  repo_check() { # <jq change> — 0 if state_repo reads GitHub's settings, so changed, as a state
    repo_answer | jq -c "$1" >"$T_TMP/state-answer"
    state_repo >"$T_TMP/state-out"
  }
  repo_check . || _t_fail "the settings whole: unreadable"
  base="$(cat "$T_TMP/state-out")"
  assert_eq "$(jq -c keys <<<"$base")" \
    '["allow_auto_merge","allow_merge_commit","allow_rebase_merge","allow_squash_merge","archived","default_branch","delete_branch_on_merge","description","full_name","has_issues","has_projects","has_wiki","homepage","visibility"]' \
    "the settings the state holds"
  repo_check '.description = null | .homepage = null' || _t_fail "description and homepage null: unreadable"
  repo_check '.homepage = "https://example.com"' || _t_fail "a homepage: unreadable"
  for f in full_name $strings $nullable $booleans; do
    if repo_check "del(.$f)"; then _t_fail "$f missing: read as a state"; fi
  done
  for f in $strings; do
    for bad in null 1 true '[]'; do
      if repo_check ".$f = $bad"; then _t_fail "$f $bad: read as a state"; fi
    done
  done
  for f in $nullable; do
    for bad in 1 true '[]' '{}'; do
      if repo_check ".$f = $bad"; then _t_fail "$f $bad: read as a state"; fi
    done
  done
  for f in $booleans; do
    for bad in null '"true"' 1 '[]'; do
      if repo_check ".$f = $bad"; then _t_fail "$f $bad: read as a state"; fi
    done
  done
  if repo_check '.full_name = null'; then _t_fail "full_name null: read as a state"; fi
  # A change to any one shows.
  for f in $strings $nullable $booleans; do
    case " $booleans " in
      *" $f "*) repo_check ".$f |= not" ;;
      *) repo_check ".$f = \"other\"" ;;
    esac || _t_fail "$f changed: unreadable"
    now="$(cat "$T_TMP/state-out")"
    [[ "$now" != "$base" ]] || _t_fail "$f changed: the state the same"
  done
  repo_check '.description = null'
  [[ "$(cat "$T_TMP/state-out")" != "$base" ]] || _t_fail "description null: the state the same"
  end_stand_in_run
}

# Round 116 (review-lens round 102, C5; owner): curl gets none of the run's descriptors, whatever their
# numbers (above 254 too): only its input, its answer and /dev/null. The attempt's own shell lists every
# descriptor it has (/dev/fd) and closes each, in curl's path only: the run keeps its own.
test_curl_gets_no_descriptor_of_the_runs_whatever_its_number() {
  local n
  short_copy
  WORK="$T_TMP/work"
  request_tools 0
  gh_reply reply
  echo "https://api.github.com/repos/$REPO" >"$T_TMP/fd-probe"
  # shellcheck disable=SC2016 # run inside the stopped run
  stopped_run_cleanup 0 "PHASE=permissions CLONE=\$WORK/clone; ulimit -n 4096 2>/dev/null; exec 7>\$T_TMP/fd7 254>\$T_TMP/fd254 300>\$T_TMP/fd300 3000>\$T_TMP/fd3000" \
    'for n in 7 254 300 3000; do [[ -e /dev/fd/$n ]] && echo "BEFORE $n"; done
     /bin/bash -c "for n in 7 254 300 3000; do [[ -e /dev/fd/\$n ]] && echo CHILD \$n; done"
     app_attempt -X PATCH "repos/$REPO" -f description=x; echo "VERDICT $OBS"
     for n in 7 254 300 3000; do [[ -e /dev/fd/$n ]] && echo "AFTER $n"; done'
  for n in 7 254 300 3000; do
    assert_contains "$OUT" "BEFORE $n" "the run's descriptor $n open (ulimit -n $(ulimit -n))"
    assert_contains "$OUT" "CHILD $n" "descriptor $n passed to a program the run starts its usual way"
    assert_contains "$OUT" "AFTER $n" "the run's descriptor $n after the attempt"
  done
  assert_contains "$OUT" "VERDICT refused" "the attempt judged on curl's answer"
  assert_eq "$(cat "$T_TMP/probe-fds")" "0 pipe;1 pipe;2 null;" "curl's descriptors"
}

# Round 116 (owner): curl is never started when the attempt's shell can't list its own descriptors: no
# list, an empty one, an entry not a descriptor's number, or one without 0, 1 and 2. The attempt is
# inconclusive, never sent, and named outcome unknown. With the list's place changed in a copy.
test_curl_is_not_started_when_its_descriptors_cant_be_listed() {
  local case name spec e
  short_copy -e "s#^readonly FD_LIST=\"/dev/fd\" #readonly FD_LIST=\"$T_TMP/fd-list\" #"
  assert_eq "${FD_LIST:-}" "$T_TMP/fd-list" "the copy's descriptor list"
  WORK="$T_TMP/work"
  request_tools 0
  gh_reply reply
  for case in "no list|none" "an empty list|" "an entry not a number|0 1 2 x" "no 0, 1 and 2|5"; do
    IFS='|' read -r name spec <<<"$case"
    rm -rf "$T_TMP/fd-list"
    : >"$T_TMP/tools"
    if [[ "$spec" != none ]]; then
      mkdir "$T_TMP/fd-list"
      for e in $spec; do : >"$T_TMP/fd-list/$e"; done
    fi
    # shellcheck disable=SC2016 # run inside the stopped run
    stopped_run_cleanup 0 "PHASE=permissions CLONE=\$WORK/clone" \
      'app_attempt -X PATCH "repos/$REPO" -f description=x; echo "VERDICT $OBS"'
    assert_contains "$OUT" "VERDICT inconclusive" "$name"
    assert_not_contains "$(cat "$T_TMP/tools")" "api.github.com" "$name: curl started"
    assert_contains "$(printf '%s\n' "$OUT" | tail -n 1)" "app gh api PATCH repos/$REPO (" "$name: the attempt named outcome unknown"
  done
}

# Round 116 (owner): if a descriptor is still open once the attempt's shell has closed them, curl is never
# started. A real close can't fail in bash (closing a closed one succeeds), so the copy here has its closing
# switched off: the check that follows finds them open.
test_curl_is_not_started_when_a_descriptor_stays_open() {
  # shellcheck disable=SC2016 # the script's own text
  short_copy -e 's/eval "exec \$fd>&-"/:/'
  # shellcheck disable=SC2016 # the script's own text
  assert_not_contains "$(declare -f app_api_curl_run)" 'exec $fd>&-' "the copy's closing switched off"
  WORK="$T_TMP/work"
  request_tools 0
  gh_reply reply
  # shellcheck disable=SC2016 # run inside the stopped run
  stopped_run_cleanup 0 "PHASE=permissions CLONE=\$WORK/clone; exec 9>\$T_TMP/fd9" \
    'app_attempt -X PATCH "repos/$REPO" -f description=x; echo "VERDICT $OBS"'
  assert_contains "$OUT" "VERDICT inconclusive" "an attempt with a descriptor left open"
  assert_not_contains "$(cat "$T_TMP/tools")" "api.github.com" "curl started with a descriptor left open"
  assert_contains "$(printf '%s\n' "$OUT" | tail -n 1)" "app gh api PATCH repos/$REPO (" "the attempt named outcome unknown"
}

run_tests
