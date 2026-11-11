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

# A fake installation token, built at run time so no token-shaped text sits in the repository.
# GitHub's stateless format (ghs_APPID_JWT, about 520 characters, changelog 2026-04-24): base64url
# parts joined by dots, so - _ and . all appear.
new_token() { printf 'ghs_123456_eyJhbGciOiJSUzI1NiJ9.%s.%s' "$(printf 'eyJ-_x%.0s' $(seq 1 40))" "$(printf 'S1g_-n%.0s' $(seq 1 40))"; }
fake_token() { printf 'gh%s_%s' s "$(printf 'Z%.0s' $(seq 1 36))"; }

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
  cat >"$T_TMP/bin/curl" <<'EOF'
#!/bin/bash
printf 'curl-args:%s\n' "$*" >>"$FAKE_LOG"
printf '{"fake":"answer"}\nHTTP %s' "${FAKE_HTTP:-201}"
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

owner_cmd_stubs() { # an owner command's checks pass; its gh calls are logged to $T_TMP/owner
  load
  need_owner() { :; }
  assert_throwaway() { :; }
  load_app() { :; }
  need_app_identity() { :; }
  need_installation_scope() { :; }
  mint_token() { :; }
  owner_uid() { echo 1; }
  owner_gh() { echo "$*" >>"$T_TMP/owner"; }
  WORK="$T_TMP/work"
  mkdir -p "$WORK"
  : >"$T_TMP/owner"
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

test_ruleset_falls_back_only_after_a_clear_rejection() {
  # Round 8 C1: a lost answer after GitHub created the ruleset must not lead to a second one. The
  # Repository admin form is tried only when GitHub rejected the User form as invalid (HTTP 422)
  # and there is still no ruleset.
  owner_cmd_stubs
  verify_phase() { :; }
  app_gh() { rate_fixture 4000; }
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

protect_stubs() { # <dev state> <main state>: each branch reads that state; a protected one reads protect's own settings
  owner_cmd_stubs
  P_DEV="$1" P_MAIN="$2"
  branch_state() { if [[ "$1" == dev ]]; then echo "$P_DEV"; else echo "$P_MAIN"; fi; }
  ruleset_count() { echo 0; }
  protection_full() { if [[ "$1" == dev ]]; then want_protection true; else want_protection false; fi; }
  protection_of() { echo stub; }
  verify_phase() { # open: the real rule, on the stubbed reads; protected: logged
    if [[ "$1" == open ]]; then
      [[ "$P_DEV" == unprotected && "$P_MAIN" == unprotected && "$(ruleset_count)" == 0 ]] || die "phase open needs dev and main unprotected and no ruleset"
    else
      echo "verify $1" >>"$T_TMP/owner"
    fi
  }
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
}

test_protect_resumes_after_only_dev_was_protected() {
  # Round 41 C1: a run that protected dev and then failed on main can be run again; dev, already
  # protected exactly as protect applies it, is left as it is.
  protect_stubs protected unprotected
  local rc=0
  cmd_protect >/dev/null 2>&1 || rc=$?
  assert_exit 0 "$rc"
  assert_eq "$(cat "$T_TMP/owner")" "api -X PUT repos/$REPO/branches/main/protection --input $WORK/main.json
verify protected"
}

test_protect_changes_nothing_unless_each_branch_is_unprotected_or_exactly_protected() {
  local rc out
  # dev protected with anything more than protect applies: nothing is written, dev or main.
  protect_stubs protected unprotected
  protection_full() { echo '{"owner-extra":true}'; }
  rc=0; out="$(cmd_protect 2>&1)" || rc=$?
  assert_exit 2 "$rc" "dev protected differently"
  assert_contains "$out" "dev is protected, but not exactly as protect applies it"
  assert_eq "$(cat "$T_TMP/owner")" "" "writes with dev protected differently"
  # main protected differently, dev unprotected: dev isn't protected either.
  protect_stubs unprotected protected
  protection_full() { if [[ "$1" == main ]]; then echo error; else want_protection true; fi; }
  rc=0; out="$(cmd_protect 2>&1)" || rc=$?
  assert_exit 2 "$rc" "main's protection unreadable"
  assert_contains "$out" "main is protected, but not exactly as protect applies it"
  assert_eq "$(cat "$T_TMP/owner")" "" "writes with main's protection unreadable"
  local s
  for s in error missing; do
    protect_stubs unprotected "$s"
    rc=0; out="$(cmd_protect 2>&1)" || rc=$?
    assert_exit 2 "$rc" "main reads $s"
    assert_contains "$out" "main reads $s"
    assert_eq "$(cat "$T_TMP/owner")" "" "writes while main reads $s"
  done
  protect_stubs unprotected unprotected
  ruleset_count() { echo 1; }
  rc=0; out="$(cmd_protect 2>&1)" || rc=$?
  assert_exit 2 "$rc" "a ruleset"
  assert_contains "$out" "protect only runs while there is no ruleset"
  assert_eq "$(cat "$T_TMP/owner")" "" "writes with a ruleset"
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

test_app_gh_passes_the_token_only_in_the_environment() {
  load
  fake_tools
  TOKEN="$(fake_token)"
  WORK="$T_TMP/work"
  GITHUB_TOKEN=should-be-unset app_gh api user --jq .login >/dev/null
  assert_eq "$(grep '^gh-token-set:' "$FAKE_LOG")" "gh-token-set:yes"
  assert_eq "$(grep '^gh-github-token-set:' "$FAKE_LOG")" "gh-github-token-set:" "GITHUB_TOKEN reached the app's gh"
  assert_eq "$(grep '^gh-config-dir:' "$FAKE_LOG")" "gh-config-dir:$T_TMP/work/gh-app" "the owner's gh config"
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

test_app_git_is_isolated_from_the_owners_git_config() {
  load
  fake_tools
  TOKEN="$(fake_token)"
  WORK="$T_TMP/work"
  mkdir -p "$WORK"
  GIT_COMMON_DIR=/tmp/x GIT_TEMPLATE_DIR=/tmp/y GIT_DIR=/tmp/z app_git status
  local log
  log="$(cat "$FAKE_LOG")"
  assert_contains "$log" "git-global:/dev/null nosystem:1 prompt:0 askpass:set home:$T_TMP/work/home"
  assert_eq "$(grep '^git-leaked:' "$FAKE_LOG")" "git-leaked:" "a GIT_* variable reached the app's git"
  assert_contains "$log" "-c credential.helper= "
  assert_contains "$log" "-c core.hooksPath=/dev/null"
  assert_not_contains "$log" "$TOKEN" "token in git's arguments"
}

test_capture_redacts_tool_output() {
  load
  fake_tools
  TOKEN="$(fake_token)"
  WORK="$T_TMP/work"
  capture app_gh api -X DELETE repos/x/y || true
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
    [[ -n "${3:-}" ]] && cp "$3" "$T_TMP/last-body.json"
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
  assert_file_mode "$WORK/jwt.hdr" 600
  assert_contains "$(cat "$WORK/jwt.hdr")" "Authorization: Bearer $JWT"
}

test_jwt_call_keeps_the_jwt_out_of_arguments() {
  load
  fake_tools
  WORK="$T_TMP/work"
  mkdir -m 700 "$WORK"
  JWT="header.payload.signature-not-real"
  printf 'Authorization: Bearer %s\n' "$JWT" >"$WORK/jwt.hdr"
  printf '{"x":1}' >"$T_TMP/body.json"
  jwt_call POST app/installations/77/access_tokens "$T_TMP/body.json" || _t_fail "a 201 answer was a failure"
  local args
  args="$(grep '^curl-args:' "$FAKE_LOG")"
  assert_contains "$args" "curl-args:-q " "the user curlrc must not apply (-q comes first)"
  assert_contains "$args" "-H @$WORK/jwt.hdr"
  assert_contains "$args" "--proto =https"
  assert_contains "$args" "https://api.github.com/app/installations/77/access_tokens"
  assert_contains "$args" "--data-binary @$T_TMP/body.json"
  assert_not_contains "$args" "$JWT" "the JWT in curl's arguments"
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

test_the_token_is_revoked_on_exit() {
  load
  TOKEN="$(fake_token)"
  WORK=""
  app_gh() { echo "$*" >>"$T_TMP/app-gh.log"; }
  ( cleanup )
  assert_eq "$(cat "$T_TMP/app-gh.log")" "api -X DELETE installation/token"
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
  LAST_OUT="remote: Permission to Thebigtuna88/forge-frg26-throwaway-2.git denied to frg26-test-app[bot].
fatal: unable to access 'https://github.com/Thebigtuna88/forge-frg26-throwaway-2.git/': The requested URL returned error: 403"
  assert_eq "$(classify_push_perm)" refused "permission denied"
  LAST_OUT="! [remote rejected] HEAD -> x (refusing to allow a GitHub App to create or update workflow \`.github/workflows/x.yml\` without \`workflows\` permission)"
  assert_eq "$(classify_push_perm)" refused "the workflows permission"
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
        [[ -n "$text" ]] && printf '%s\n' "$text"
        return "$rc"
      fi
    done <"$T_TMP/answers"
    return 0
  }
  app_gh() { answer app_gh "$@"; }
  app_git() { answer app_git "$@"; }
  owner_gh() { answer owner_gh "$@"; }
  fresh_from() { :; }
  add_commit() { echo "commit $1" >>"$T_TMP/calls"; }
  sleep() { :; }
}

test_a2_tries_a_repo_the_app_is_not_installed_on() {
  p_stubs
  cat >"$T_TMP/answers" <<EOF
owner_gh api repos/$REPO2/compare/main...frg26-a2 --jq .ahead_by|0|1
app_git -C $T_TMP/clone push https://github.com/$REPO2.git|1|remote: Permission to $REPO2.git denied to frg26-test-app[bot].
app_gh api -X POST repos/$REPO2/|1|gh: Resource not accessible by integration (HTTP 403)
app_gh api -X POST repos/$REPO/issues|0|{"number":5}
app_gh api -X POST repos/$REPO/pulls|0|{"number":6}
EOF
  local out
  out="$(t_A2)"
  assert_contains "$out" "RESULT A2 permissions PASS attempt=refused control=ok"
  local calls
  calls="$(cat "$T_TMP/calls")"
  assert_contains "$calls" "app_git -C $T_TMP/clone push https://github.com/$REPO2.git HEAD:refs/heads/frg26-a2-r1"
  assert_contains "$calls" "app_gh api -X POST repos/$REPO2/issues"
  assert_contains "$calls" "app_gh api -X POST repos/$REPO2/pulls"
  assert_contains "$calls" "app_git -C $T_TMP/clone push origin HEAD:refs/heads/frg26/permissions/A2-r1"
  assert_contains "$calls" "app_gh api -X POST repos/$REPO/issues"
  assert_contains "$calls" "app_gh api -X POST repos/$REPO/pulls"
  # A write that got through to the other repo fails the test, and nothing more is tried there.
  cat >"$T_TMP/answers" <<EOF
owner_gh api repos/$REPO2/compare/main...frg26-a2 --jq .ahead_by|0|1
app_git -C $T_TMP/clone push https://github.com/$REPO2.git|0|
EOF
  : >"$T_TMP/calls"
  out="$(t_A2)"
  assert_contains "$out" "RESULT A2 permissions FAIL attempt=allowed"
  assert_not_contains "$(cat "$T_TMP/calls")" "repos/$REPO2/issues" "attempts after one got through"
}

test_a3_pushes_a_workflow_file_and_a_plain_file() {
  p_stubs
  cat >"$T_TMP/answers" <<'EOF'
push origin HEAD:refs/heads/frg26/permissions/A3-wf-r1|1|! [remote rejected] HEAD -> frg26/permissions/A3-wf-r1 (refusing to allow a GitHub App to create or update workflow `.github/workflows/frg26-a3-r1.yml` without `workflows` permission)
EOF
  local out
  out="$(t_A3)"
  assert_contains "$out" "RESULT A3 permissions PASS attempt=refused control=ok"
  assert_contains "$(cat "$T_TMP/calls")" "commit .github/workflows/frg26-a3-r1.yml"
  assert_contains "$(cat "$T_TMP/calls")" "commit tests/permissions-A3-r1.txt"
  # The plain file must push, or the refusal proves nothing.
  cat >"$T_TMP/answers" <<'EOF'
push origin HEAD:refs/heads/frg26/permissions/A3-wf-r1|1|! [remote rejected] (refusing to allow a GitHub App to create or update workflow `x` without `workflows` permission)
push origin HEAD:refs/heads/frg26/permissions/A3-plain-r1|1|fatal: unable to access: Could not resolve host
EOF
  out="$(t_A3)"
  assert_contains "$out" "RESULT A3 permissions FAIL attempt=refused control=failed"
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
}

test_a6_tries_settings_and_its_own_installation() {
  p_stubs
  cat >"$T_TMP/answers" <<EOF
owner_gh api repos/$REPO --jq .id|0|4242
app_gh api -X PATCH repos/$REPO|1|gh: Resource not accessible by integration (HTTP 403)
app_gh api -X PUT user/installations/77/repositories/4242|1|gh: Resource not accessible by integration (HTTP 403)
EOF
  local out
  out="$(t_A6)"
  assert_contains "$out" "RESULT A6 permissions PASS attempt=refused control=ok"
  local calls
  calls="$(cat "$T_TMP/calls")"
  # The control is the owner making the very same write, a no-op: the description it already has.
  assert_contains "$calls" "app_gh api -X PATCH repos/$REPO -f description=$MARKER"
  assert_contains "$calls" "owner_gh api -X PATCH repos/$REPO -f description=$MARKER"
  assert_contains "$calls" "app_gh api -X PUT user/installations/77/repositories/4242"
}

test_a8_tries_secrets_variables_keys_hooks_and_collaborators() {
  p_stubs
  cat >"$T_TMP/answers" <<EOF
app_gh api|1|gh: Resource not accessible by integration (HTTP 403)
EOF
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
  printf 'app_gh api|1|gh: Resource not accessible by integration (HTTP 403)\nowner_gh api repos/%s/actions/secrets/public-key|1|gh: HTTP 502\n' "$REPO" >"$T_TMP/answers"
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
  # prove nothing. The branch is made first, the commit goes on it, and A2 checks it is ahead.
  load
  : >"$T_TMP/owner"
  owner_gh() {
    echo "$*" >>"$T_TMP/owner"
    case "$*" in
      "api repos/$REPO2") [[ -f "$T_TMP/made" ]] || return 1 ;;
      "repo create"*) touch "$T_TMP/made" ;;
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
  printf 'owner_gh api repos/%s/compare/main...frg26-a2 --jq .ahead_by|0|0\n' "$REPO2" >"$T_TMP/answers"
  local out
  out="$(t_A2)"
  assert_contains "$out" "RESULT A2 permissions FAIL attempt=setup-failed" "a branch not ahead of main"
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
    esac
  }
  : >"$T_TMP/owner"
  FAILS=0
  RUN_ID=20261102T010203Z-77
  local out
  out="$(sweep_issues; echo "fails=$FAILS")"
  assert_contains "$(cat "$T_TMP/owner")" "issue close 11 --repo $REPO"
  assert_contains "$(cat "$T_TMP/owner")" "issue close 12 --repo $REPO"
  assert_contains "$(grep "repos/$REPO/issues" "$T_TMP/owner")" "20261102T010203Z-77" "only this run's issues are closed"
  # Round 13, SEC-4: the second throwaway is only read; an issue there is reported, never closed.
  assert_contains "$(cat "$T_TMP/owner")" "repos/$REPO2/issues?state=open"
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
    fi; }
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
  s2_stubs
  can_approve() { echo true; }
  app_git() { echo "app_git $*" >>"$T_TMP/calls"; [[ "$*" == *rev-parse* ]] && printf 'a%.0s' $(seq 1 40) && echo; return 0; }
  local sha
  sha="$(printf 'a%.0s' $(seq 1 40))"
  echo "501 waiting null frg26-test-app[bot]" >"$T_TMP/run-$sha"
  echo "gh: Resource not accessible by integration (HTTP 403)" >"$T_TMP/refuse-app_gh-501"
  echo yes >"$T_TMP/log-501"
  local out
  out="$(t_S2b)"
  assert_contains "$out" "RESULT S2b permissions PASS attempt=refused control=ok"
  assert_contains "$(cat "$T_TMP/calls")" "approve app_gh 501"
  assert_contains "$(cat "$T_TMP/calls")" "approve owner_gh 501"
  assert_contains "$(cat "$T_TMP/calls")" "app_git -C $T_TMP/clone push origin HEAD:refs/heads/main"
  # The control fails when the job never got the value after the owner's approval.
  rm -f "$T_TMP/log-501"
  out="$(t_S2b)"
  assert_contains "$out" "RESULT S2b permissions FAIL attempt=refused control=failed"
  # The app approving its own run is a FAIL however the rest goes.
  rm -f "$T_TMP/refuse-app_gh-501"
  out="$(t_S2b)"
  assert_contains "$out" "RESULT S2b permissions FAIL attempt=allowed"
}

test_s2d_self_review_is_refused_and_its_control_is_s2b() {
  s2_stubs
  S2_OWNER_SHA="$(printf 'b%.0s' $(seq 1 40))"
  echo "502 waiting null Thebigtuna88" >"$T_TMP/run-$S2_OWNER_SHA"
  can_approve() { cat "$T_TMP/can-$1" 2>/dev/null || echo error; }
  echo false >"$T_TMP/can-502"
  echo "gh: Can't approve your own deployment (HTTP 422)" >"$T_TMP/refuse-owner_gh-502"
  local out
  S2B_OWNER_APPROVAL=ok
  out="$(t_S2d)"
  assert_contains "$out" "RESULT S2d permissions PASS attempt=refused control=ok"
  S2B_OWNER_APPROVAL=""
  out="$(t_S2d)"
  assert_contains "$out" "RESULT S2d permissions FAIL" "no S2b control"
  # Round 13, C2/SEC-2: a request that never reached GitHub, or a rate limit, proves nothing.
  S2B_OWNER_APPROVAL=ok
  echo "gh: dial tcp: lookup api.github.com: no such host" >"$T_TMP/refuse-owner_gh-502"
  out="$(t_S2d)"
  assert_contains "$out" "RESULT S2d permissions FAIL attempt=inconclusive" "a network error"
  echo "gh: API rate limit exceeded (HTTP 403)" >"$T_TMP/refuse-owner_gh-502"
  out="$(t_S2d)"
  assert_contains "$out" "RESULT S2d permissions FAIL attempt=inconclusive" "a rate limit"
  # GitHub must itself say the owner can't approve this run (Prevent self-review).
  echo "gh: Can't approve your own deployment (HTTP 422)" >"$T_TMP/refuse-owner_gh-502"
  echo true >"$T_TMP/can-502"
  out="$(t_S2d)"
  assert_contains "$out" "RESULT S2d permissions FAIL attempt=inconclusive" "GitHub says the owner could approve"
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

test_s2c_the_app_cannot_change_the_environment() {
  s2_stubs
  WORK="$T_TMP/work"
  owner_uid() { echo 42; }
  printf 'app_gh api|1|gh: Resource not accessible by integration (HTTP 403)\n' >"$T_TMP/answers"
  env_summary() { want_env; }
  local out calls
  out="$(t_S2c)"
  assert_contains "$out" "RESULT S2c permissions PASS attempt=refused control=ok"
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
  printf 'app_gh api|1|gh: Resource not accessible by integration (HTTP 403)\nowner_gh api -X DELETE|1|gh: HTTP 500\n' >"$T_TMP/answers"
  out="$(t_S2c)"
  assert_contains "$out" "RESULT S2c permissions FAIL attempt=refused control=failed"
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
  app_session() { TOKEN="ghs_session$(printf 'S%.0s' $(seq 1 30))"; }
  mint_token() { TOKEN="ghs_newheld$(printf 'N%.0s' $(seq 1 30))"; }
  app_gh() { echo "app_gh $*" >>"$T_TMP/calls"; }
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
  assert_eq "$(grep -c 'app_gh ghs_secondQQ api -X DELETE installation/token' "$T_TMP/app-gh.log")" 2 "the exit clean-up did not retry it"
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
  mint_ok() { TOKEN="$tok"; OUTSTANDING="$OUTSTANDING $tok"; }
  mint_bad() { TOKEN="$tok"; OUTSTANDING="$OUTSTANDING $tok"; die "refused"; }
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
  # Controls: revocation works, so nothing is reported either way.
  app_gh() { echo "${TOKEN:0:11} $*" >>"$T_TMP/app-gh.log"; }
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
  printf 'app_gh api|1|gh: Resource not accessible by integration (HTTP 403)\nowner_gh api -X PUT repos/%s/environments|1|gh: HTTP 502\n' "$REPO" >"$T_TMP/answers"
  env_summary() { want_env; }
  local out
  out="$(t_S2c)"
  assert_contains "$out" "RESULT S2c permissions FAIL attempt=refused control=failed"
  assert_not_contains "$(cat "$T_TMP/calls")" "owner_gh api -X DELETE" "the disposable secret was deleted after a failed control"
  # A2: a failed push control stops the issue and PR controls.
  p_stubs
  cat >"$T_TMP/answers" <<EOF
owner_gh api repos/$REPO2/compare/main...frg26-a2 --jq .ahead_by|0|1
app_git -C $T_TMP/clone push https://github.com/$REPO2.git|1|remote: Permission to $REPO2.git denied to frg26-test-app[bot].
app_gh api -X POST repos/$REPO2/|1|gh: Resource not accessible by integration (HTTP 403)
app_git -C $T_TMP/clone push origin|1|fatal: unable to access: Could not resolve host
EOF
  out="$(t_A2)"
  assert_contains "$out" "RESULT A2 permissions FAIL attempt=refused control=failed"
  assert_not_contains "$(cat "$T_TMP/calls")" "app_gh api -X POST repos/$REPO/issues" "a control after the failed one"
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

run_tests
