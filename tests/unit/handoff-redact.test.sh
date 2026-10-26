#!/usr/bin/env bash
# Tests for .harness/lib/handoff_redact.py, the live redaction filter of handoff steps (FRG-14,
# spec 4.3): what it shows, what it holds back, and when.
# shellcheck disable=SC2031 # each test sets and reads T_TMP inside its own subshell (assert.sh)
# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"
# shellcheck source=tests/lib/fixture.sh
source "$(dirname "$0")/../lib/fixture.sh"

REDACT="$FORGE_SRC/.harness/lib/handoff_redact.py"

# feed <secrets, one per line> <log> <chunk>...: runs the filter with the secrets on fd 3, writes
# each chunk and waits 0.3 s, then prints "after <i>: [<everything shown so far>]". Then closes
# its input and prints "final: [<all shown>]" and "rc: <status>". With FEED_SIGINT=1 it sends
# SIGINT to the filter after the first chunk.
feed() {
  FEED_OUT="$(python3 -I - "$REDACT" "$@" <<'PY'
import os, select, signal, subprocess, sys, time
redact, secrets, log, chunks = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
r, w = os.pipe()
os.write(w, secrets.encode() + b"\n")
os.close(w)
os.dup2(r, 3)
p = subprocess.Popen(["/usr/bin/python3", "-I", redact, log], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, pass_fds=(3,))
os.close(3)
shown = b""

def drain(wait):
    global shown
    while select.select([p.stdout], [], [], wait)[0]:
        data = os.read(p.stdout.fileno(), 65536)
        if not data:
            return
        shown += data
        wait = 0.05

for i, chunk in enumerate(chunks, 1):
    p.stdin.write(chunk.encode())
    p.stdin.flush()
    time.sleep(0.3)
    drain(0)
    print("after %d: [%s]" % (i, shown.decode()))
    if i == 1 and os.environ.get("FEED_SIGINT") == "1":
        p.send_signal(signal.SIGINT)
        time.sleep(0.2)
p.stdin.close()
drain(2)
print("final: [%s]" % shown.decode())
print("rc: %d" % p.wait())
PY
)"
}

test_text_without_secrets_is_shown_at_once() {
  feed '%@+%@@%+' "$T_TMP/log" 'hello' ' world'
  assert_contains "$FEED_OUT" "after 1: [hello]"
  assert_contains "$FEED_OUT" "final: [hello world]"
  assert_contains "$FEED_OUT" "rc: 0"
}

test_a_secret_split_across_writes_is_redacted() {
  feed '%@+%@@%+' "$T_TMP/log" 'token %@+%' '@@%+ end'
  assert_contains "$FEED_OUT" "after 1: [token ]" # the possible start of the secret is held back
  assert_contains "$FEED_OUT" "final: [token [REDACTED] end]"
}

test_a_held_piece_is_shown_once_it_cannot_be_a_secret() {
  feed '%@+%@@%+' "$T_TMP/log" 'x %@+' 'Q'
  assert_contains "$FEED_OUT" "after 1: [x ]"
  assert_contains "$FEED_OUT" "after 2: [x %@+Q]"
}

test_a_held_piece_is_shown_when_the_step_ends() {
  feed '%@+%@@%+' "$T_TMP/log" 'x %@+'
  assert_contains "$FEED_OUT" "after 1: [x ]"
  assert_contains "$FEED_OUT" "final: [x %@+]"
}

# B starts with A: A alone must not be redacted early, leaving the rest of B on the screen.
test_a_secret_that_starts_another_is_held_until_it_is_clear() {
  feed $'%@%\n%@%+@+' "$T_TMP/log" '%@%' '+@+'
  assert_contains "$FEED_OUT" "after 1: []"
  assert_contains "$FEED_OUT" "final: [[REDACTED]]"
  feed $'%@%\n%@%+@+' "$T_TMP/log2" '%@%' 'Q'
  assert_contains "$FEED_OUT" "final: [[REDACTED]Q]"
}

# A complete secret whose end could start another secret: neither half may be shown early.
test_a_secret_straddling_the_held_piece_is_held_whole() {
  feed $'%@+@\n+@%%' "$T_TMP/log" 'z%@+@'
  assert_contains "$FEED_OUT" "after 1: [z]"
  assert_contains "$FEED_OUT" "final: [z[REDACTED]]"
}

test_no_secrets_means_plain_pass_through() {
  feed '' "$T_TMP/log" 'a%b' '@c'
  assert_contains "$FEED_OUT" "after 1: [a%b]"
  assert_contains "$FEED_OUT" "final: [a%b@c]"
}

test_the_log_holds_what_was_shown_and_is_private() {
  feed '%@+%@@%+' "$T_TMP/log" 'one %@+%@@%+ two'
  assert_contains "$FEED_OUT" "final: [one [REDACTED] two]"
  assert_eq "$(cat "$T_TMP/log")" "one [REDACTED] two"
  assert_file_mode "$T_TMP/log" 600
}

test_refuses_an_existing_log_or_a_symlink() {
  printf 'precious\n' >"$T_TMP/target"
  ln -s "$T_TMP/target" "$T_TMP/log"
  feed '%@+%@@%+' "$T_TMP/log" 'hello'
  [[ "$FEED_OUT" != *"rc: 0"* ]] || _t_fail "the filter accepted a symlinked log: $FEED_OUT"
  assert_contains "$FEED_OUT" "final: []"
  assert_eq "$(cat "$T_TMP/target")" precious
}

test_sigint_does_not_stop_the_filter() {
  FEED_SIGINT=1 feed '%@+%@@%+' "$T_TMP/log" 'before ' '%@+%@@%+ after'
  assert_contains "$FEED_OUT" "final: [before [REDACTED] after]"
  assert_contains "$FEED_OUT" "rc: 0"
}

test_needs_exactly_the_log_path() {
  local out rc=0
  out="$(python3 -I "$REDACT" 2>&1 </dev/null)" || rc=$?
  [[ $rc -ne 0 ]] || _t_fail "ran without a log path"
  assert_contains "$out" "usage"
}

run_tests
