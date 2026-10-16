#!/usr/bin/env bash
# Tests for the test pty driver itself (spec 10.2): a timed-out run leaves nothing running.
# shellcheck disable=SC2031 # each test sets and reads T_TMP inside its own subshell (assert.sh)
# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"
# shellcheck source=tests/lib/fixture.sh
source "$(dirname "$0")/../lib/fixture.sh"

# The child ignores hang-ups (as nohup does), so only killing the whole group ends it.
test_timeout_kills_background_children() {
  local out pid
  # shellcheck disable=SC2016 # $! is expanded by the inner bash
  out="$(PTYRUN_TIMEOUT=1 python3 -I "$TESTLIB/ptyrun.py" -- /bin/bash -c \
    'trap "" HUP; sleep 300 & echo $! >"$0"; wait' "$T_TMP/pid")"
  assert_contains "$out" "killed after 1 s"
  pid="$(cat "$T_TMP/pid")"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    _t_fail "background child $pid survived the timeout"
  fi
}

run_tests
