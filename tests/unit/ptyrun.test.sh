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

# script(1) puts each handoff step in its own session; those processes must not survive either.
test_timeout_kills_children_in_their_own_session() {
  cat >"$T_TMP/detach.py" <<'PY'
import os, signal, sys, time
if os.fork() == 0:
    os.setsid()
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    open(sys.argv[1], "w").write(str(os.getpid()))
    time.sleep(300)
else:
    time.sleep(300)
PY
  local out pid
  out="$(PTYRUN_TIMEOUT=2 python3 -I "$TESTLIB/ptyrun.py" -- python3 -I "$T_TMP/detach.py" "$T_TMP/pid")"
  assert_contains "$out" "killed after 2 s"
  pid="$(cat "$T_TMP/pid")"
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid"
    _t_fail "detached child $pid survived the timeout"
  fi
}

test_timeout_holds_when_the_child_closes_its_terminal() {
  local out start
  start="$(date +%s)"
  out="$(PTYRUN_TIMEOUT=1 python3 -I "$TESTLIB/ptyrun.py" -- /bin/bash -c \
    'exec >/dev/null 2>&1 </dev/null; sleep 30')"
  [[ $(($(date +%s) - start)) -lt 10 ]] || _t_fail "ptyrun waited for the child instead of timing out"
  assert_contains "$out" "[ptyrun: killed after 1 s" # "without output" or "without exiting"
}

# The parent exits first, so its detached child is re-parented before the driver returns.
test_detached_child_of_an_exited_parent_is_killed() {
  cat >"$T_TMP/orphan.py" <<'PY'
import os, signal, sys, time
if os.fork() == 0:
    os.setsid()
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    open(sys.argv[1], "w").write(str(os.getpid()))
    time.sleep(300)
else:
    time.sleep(0.5)
PY
  local out pid
  out="$(PTYRUN_TIMEOUT=5 python3 -I "$TESTLIB/ptyrun.py" -- python3 -I "$T_TMP/orphan.py" "$T_TMP/pid")"
  pid="$(cat "$T_TMP/pid")"
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid"
    _t_fail "detached child $pid outlived the driver after a normal exit"
  fi
}

# A pid seen earlier but now belonging to a different process must not be killed.
test_cleanup_checks_process_identity() {
  local out
  out="$(python3 -I - "$TESTLIB/ptyrun.py" <<'PY'
import importlib.util, signal, sys
spec = importlib.util.spec_from_file_location("ptyrun", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
sent = []
m.os.kill = lambda p, s: sent.append(("kill", p))
m.os.killpg = lambda p, s: sent.append(("killpg", p))
m.process_table = lambda: {12345: (1, "Thu Jan  1 00:00:02 2026")}
m.descendants = lambda root: set()
m.kill_all(10000, {(12345, "Thu Jan  1 00:00:01 2026")})
print(sent)
PY
)"
  assert_eq "$out" "[('killpg', 10000)]" "a reused pid was signalled"
}

run_tests
