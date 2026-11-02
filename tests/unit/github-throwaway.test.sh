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

app_fixture() { # GET /app for the owner's throwaway app
  printf '{"id":123456,"slug":"frg26-test-app","owner":{"login":"Thebigtuna88"}}'
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
  for name in "someone else's app|app|.owner.login = \"someone\"" \
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
  assert_contains "$calls" "app_gh api -X PUT repos/$REPO/collaborators/$OWNER -f permission=push"
  for p in actions/secrets actions/variables keys hooks; do
    assert_contains "$calls" "owner_gh api repos/$REPO/$p"
  done
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
  sweep_issues
  assert_contains "$(cat "$T_TMP/owner")" "issue close 11 --repo $REPO"
  assert_contains "$(cat "$T_TMP/owner")" "issue close 12 --repo $REPO"
  assert_contains "$(cat "$T_TMP/owner")" "repos/$REPO2/issues?state=open"
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

s2_stubs() {
  p_stubs
  eid=9
  env_id() { echo 9; }
  run_log_has_value() { [[ "$(cat "$T_TMP/log-$1" 2>/dev/null)" == yes ]]; }
  wait_run() { RUN="$(cat "$T_TMP/run-$1" 2>/dev/null)"; [[ -n "$RUN" ]]; }
  approve_run() { echo "approve $1 $2" >>"$T_TMP/calls"; LAST_RC=0; LAST_OUT=ok
    if [[ -f "$T_TMP/refuse-$1-$2" ]]; then LAST_RC=1; LAST_OUT="$(cat "$T_TMP/refuse-$1-$2")"; return 1; fi; }
  cancel_waiting_runs() { :; }
}

test_s2b_the_app_cannot_approve_its_own_deployment() {
  s2_stubs
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
  echo "gh: Can't approve your own deployment (HTTP 422)" >"$T_TMP/refuse-owner_gh-502"
  local out
  S2B_OWNER_APPROVAL=ok
  out="$(t_S2d)"
  assert_contains "$out" "RESULT S2d permissions PASS attempt=refused control=ok"
  S2B_OWNER_APPROVAL=""
  out="$(t_S2d)"
  assert_contains "$out" "RESULT S2d permissions FAIL" "no S2b control"
}

test_s2a_a_feature_branch_never_gets_the_value() {
  s2_stubs
  app_git() { [[ "$*" == *rev-parse* ]] && printf 'c%.0s' $(seq 1 40) && echo; return 0; }
  local sha
  sha="$(printf 'c%.0s' $(seq 1 40))"
  echo "503 completed failure frg26-test-app[bot]" >"$T_TMP/run-$sha"
  local out
  out="$(t_S2a)"
  assert_contains "$out" "RESULT S2a permissions PASS attempt=refused"
  echo "503 waiting null frg26-test-app[bot]" >"$T_TMP/run-$sha"
  out="$(t_S2a)"
  assert_contains "$out" "RESULT S2a permissions FAIL attempt=allowed" "a feature branch waiting to deploy"
  echo "503 completed success frg26-test-app[bot]" >"$T_TMP/run-$sha"
  echo yes >"$T_TMP/log-503"
  out="$(t_S2a)"
  assert_contains "$out" "RESULT S2a permissions FAIL attempt=allowed" "a feature branch that got the value"
}

test_s2c_the_app_cannot_change_the_environment() {
  s2_stubs
  WORK="$T_TMP/work"
  printf 'app_gh api|1|gh: Resource not accessible by integration (HTTP 403)\n' >"$T_TMP/answers"
  env_summary() { want_env; }
  local out
  out="$(t_S2c)"
  assert_contains "$out" "RESULT S2c permissions PASS attempt=refused control=ok"
  assert_contains "$(cat "$T_TMP/calls")" "app_gh api -X PUT repos/$REPO/environments/frg26-test"
  assert_contains "$(cat "$T_TMP/calls")" "app_gh api -X DELETE repos/$REPO/environments/frg26-test/secrets/FRG26_DUMMY"
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
  HELD_TIMES="$T_TMP/held-times"
  STATE="$T_TMP/frg26-state"
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
  assert_file_mode "$HELD_TIMES" 600
  assert_eq "$(cat "$HELD")" "HELD_AGE=$(fake_token)" "held tokens are VAR=value lines (ho_redact_file can hide them)"
  assert_contains "$(cat "$HELD_TIMES")" "age "
  assert_not_contains "$(cat "$HELD_TIMES")" "ghs_" "a token beside the issue times"
  app_gh() { echo "$REPO"; }
  revoke_token() { echo "revoke" >>"$T_TMP/calls"; TOKEN=""; }
  use_held age
  assert_eq "$HELD_RESULT" works
  assert_eq "$(cat "$T_TMP/calls")" "revoke" "a held token that still works is revoked after its check"
  assert_eq "$(grep -c '^HELD_AGE=' "$HELD")" 0 "the held token is removed after its check"
  assert_eq "$(grep -c '^age ' "$HELD_TIMES")" 0 "its issue time is removed too"
  local rc=0
  (cmd_hold_token nonsense) >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "an unknown held-token name"
}

test_a4_needs_a_token_over_an_hour_old() {
  held_stubs
  printf 'HELD_AGE=%s\n' "$(fake_token)" >"$HELD"; printf 'age %s\n' "$(( $(date +%s) - 600 ))" >"$HELD_TIMES"
  chmod 600 "$HELD" "$HELD_TIMES"
  local rc=0 out
  out="$(cmd_token_age_check 2>&1)" || rc=$?
  assert_exit 2 "$rc" "a token ten minutes old"
  assert_contains "$out" "not over an hour old yet"
  printf 'HELD_AGE=%s\n' "$(fake_token)" >"$HELD"; printf 'age %s\n' "$(( $(date +%s) - 3700 ))" >"$HELD_TIMES"
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
    if [[ "$APP_KEY_SIGNED" == "$old_key" ]]; then LAST_HTTP=401; LAST_OUT='{"message":"A JSON web token could not be decoded"}'; return 1; fi
    LAST_HTTP=200; LAST_OUT='{"id":123456}'
  }
  make_jwt() { APP_KEY_SIGNED="$APP_KEY"; JWT=x; }
  need_app_identity() { :; }
  printf 'HELD_KEYOLD=%s\n' "$(fake_token)" >"$HELD"; printf 'keyold %s\n' "$(date +%s)" >"$HELD_TIMES"
  chmod 600 "$HELD" "$HELD_TIMES"
  app_gh() { echo "gh: Bad credentials (HTTP 401)" >&2; return 1; }
  local out rc=0
  out="$(cmd_key_check 2>&1)" || rc=$?
  assert_exit 0 "$rc"
  assert_contains "$out" "RESULT A9 permissions PASS attempt=refused control=ok"
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
  printf 'HELD_SUSPEND=%s\n' "$(fake_token)" >"$HELD"; printf 'suspend %s\n' "$(date +%s)" >"$HELD_TIMES"
  chmod 600 "$HELD" "$HELD_TIMES"
  app_gh() { echo "gh: Bad credentials (HTTP 401)" >&2; return 1; }
  local out
  out="$(cmd_suspend_check 2>&1)"
  assert_contains "$out" "E1 a new token while suspended: refused"
  assert_contains "$out" "READING E1 a token issued before the suspension"
  assert_eq "$(state_get E1)" "refused HTTP-403"
  app_session() { :; }
  local rc=0
  out="$(cmd_unsuspend_check 2>&1)" || rc=$?
  assert_exit 0 "$rc"
  assert_contains "$out" "RESULT E1 permissions PASS attempt=refused control=ok"
  app_session() { die "the app's installation is suspended"; }
  rc=0; out="$(cmd_unsuspend_check 2>&1)" || rc=$?
  assert_exit 1 "$rc" "no control after unsuspending"
  assert_contains "$out" "RESULT E1 permissions FAIL"
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
  printf 'uninstall %s\ndelete %s\n' "$(date +%s)" "$(date +%s)" >"$HELD_TIMES"
  chmod 600 "$HELD" "$HELD_TIMES"
  app_gh() { echo "gh: Bad credentials (HTTP 401)" >&2; return 1; }
  local out
  out="$(cmd_uninstall_check 2>&1)"
  assert_contains "$out" "READING E2 a token issued before the uninstall: HTTP 401"
  out="$(cmd_delete_check 2>&1)"
  assert_contains "$out" "READING E3 a token issued before the app was deleted: HTTP 401"
  assert_contains "$out" "the app's own key now gets HTTP 404"
}

run_tests
