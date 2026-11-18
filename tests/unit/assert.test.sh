#!/usr/bin/env bash
# Tests for the test runner itself, tests/lib/assert.sh (FRG-26 round 75): a test that crashed, or
# ended early or with another status through an exit or an exit trap, never counts as passing; a
# test that expects a command to fail still passes. Each case is a small test file run with the
# real runner.
# shellcheck disable=SC2031 # each test sets and reads T_TMP inside its own subshell (assert.sh)
# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

LIB="$(cd "$(dirname "$0")/../lib" && pwd)/assert.sh"

# Runs a test file holding <body> with the runner under test; sets OUT and RC.
run_fixture() { # <body>
  printf 'source "%s"\n%s\nrun_tests\n' "$LIB" "$1" >"$T_TMP/fixture.test.sh"
  RC=0
  OUT="$(/bin/bash "$T_TMP/fixture.test.sh" 2>&1)" || RC=$?
}

test_a_crash_or_an_early_exit_never_counts_as_passing() {
  local case name body why
  # shellcheck disable=SC2016 # the bodies are test code for the fixture, expanded there
  for case in 'crashed under an exit trap that exits 0|trap "exit 0" EXIT; set -u; echo "$NO_SUCH_VARIABLE_HERE"; assert_eq 1 1|crashed or exited before it returned (status 0)' \
    'exited 0 before its assertions|exit 0; assert_eq 1 2 never-reached|crashed or exited before it returned (status 0)' \
    'crashed without a trap|set -u; echo "$NO_SUCH_VARIABLE_HERE"|crashed or exited before it returned (status 1)' \
    'an exit trap changed its status after it returned|trap "exit 5" EXIT; assert_eq 1 1|ended with status 5 after it returned 0 (an exit trap?)' \
    'returned non-zero|return 4|test_case returned non-zero' \
    'an assertion failed|assert_eq 1 2 "one is not two"|one is not two: expected [2] got [1]'; do
    IFS='|' read -r name body why <<<"$case"
    run_fixture "test_case() { $body; }"
    assert_contains "$OUT" "not ok fixture::test_case" "$name"
    assert_not_contains "$OUT" "
ok fixture::test_case" "$name: counted as passing"
    [[ "$OUT" != "ok fixture::test_case"* ]] || _t_fail "$name: counted as passing"
    assert_contains "$OUT" "  # $why" "$name"
    assert_exit 1 "$RC" "$name: the file's status"
  done
}

test_a_test_that_expects_a_failure_still_passes() {
  # shellcheck disable=SC2016 # as above
  run_fixture 'test_expects_failures() {
  local rc=0
  (exit 3) || rc=$?
  assert_exit 3 "$rc" "a command that must fail"
  if ( set -u; echo "$NO_SUCH_VARIABLE_HERE" ) 2>/dev/null; then _t_fail "a crash in a subshell went unnoticed"; fi
  ! false
}
test_passes() { assert_eq 1 1; }'
  assert_eq "$OUT" "ok fixture::test_expects_failures
ok fixture::test_passes"
  assert_exit 0 "$RC" "every test passed"
}

run_tests
