#!/usr/bin/env bash
# TEMPORARY (FRG-6): one test that always fails, to show the CI run turns red. It touches nothing
# and prints no secret. Removed in the next commit.
# shellcheck disable=SC2031 # each test sets and reads T_TMP inside its own subshell (assert.sh)
# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

# tests/run.sh counts a file with no passing test as a second failure; this keeps the count at one.
test_a_passing_companion() {
  assert_eq 1 1
}

test_intentional_failure_to_show_ci_turns_red() {
  _t_fail "intentional failure (FRG-6): CI must turn red; removed in the next commit"
}

run_tests
