#!/usr/bin/env bash
# Tests for .harness/lib/handoff_redact.py, the live redaction filter of handoff steps (FRG-14,
# spec 4.3): what it shows, what it holds back, and when.
# shellcheck disable=SC2031 # each test sets and reads T_TMP inside its own subshell (assert.sh)
# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"
# shellcheck source=tests/lib/fixture.sh
source "$(dirname "$0")/../lib/fixture.sh"

REDACT="$FORGE_SRC/.harness/lib/handoff_redact.py"

# feed <secrets, one per line> <log> <chunk>...: runs the filter with the secrets on fd 3 and
# writes each chunk in one write. It then waits until new output appears (up to 5 s) and goes on
# reading until none arrives for 0.3 s, and prints "after <i>: [<everything shown so far>]". Every
# chunk in these tests shows something, so new output proves the filter has read and judged the
# whole chunk, not just that time passed. Then it closes the filter's input and prints
# "final: [<all shown>]", "rc: <status>" and "stderr: [<its messages>]". With FEED_SIGINT=1 it sends SIGINT after the first
# chunk's output appears (the filter ignores SIGINT before it reads any output). The secret list
# ends with "#END", as the runtime sends it, unless FEED_NO_END=1.
feed() {
  FEED_OUT="$(python3 -I - "$REDACT" "$@" <<'PY'
import os, select, signal, subprocess, sys, time
redact, secrets, log, chunks = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
r, w = os.pipe()
os.write(w, secrets.encode() + b"\n" + (b"" if os.environ.get("FEED_NO_END") == "1" else b"#END\n"))
os.close(w)
os.dup2(r, 3)
p = subprocess.Popen(["/usr/bin/python3", "-I", redact, log], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, pass_fds=(3,))
os.close(3)
shown = b""

def drain(first_wait, then_wait):
    """Read until nothing arrives: first_wait for the first byte, then_wait for each next one."""
    global shown
    wait = first_wait
    while select.select([p.stdout], [], [], wait)[0]:
        data = os.read(p.stdout.fileno(), 65536)
        if not data:
            return
        shown += data
        wait = then_wait

for i, chunk in enumerate(chunks, 1):
    try:
        p.stdin.write(chunk.encode())
        p.stdin.flush()
    except BrokenPipeError:  # the filter has already exited
        pass
    drain(5, 0.3)
    print("after %d: [%s]" % (i, shown.decode()))
    if i == 1 and os.environ.get("FEED_SIGINT") == "1":
        p.send_signal(signal.SIGINT)
        time.sleep(0.2)
try:
    p.stdin.close()
except BrokenPipeError:
    pass
drain(5, 0.3)
print("final: [%s]" % shown.decode())
print("rc: %d" % p.wait())
print("stderr: [%s]" % p.stderr.read().decode().strip())
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
  feed $'%@%\n%@%+@+' "$T_TMP/log" 'x %@%' '+@+'
  assert_contains "$FEED_OUT" "after 1: [x ]"
  assert_contains "$FEED_OUT" "final: [x [REDACTED]]"
  feed $'%@%\n%@%+@+' "$T_TMP/log2" 'x %@%' 'Q'
  assert_contains "$FEED_OUT" "final: [x [REDACTED]Q]"
}

# A complete secret whose end could start another secret: no piece of either is shown.
test_a_secret_straddling_the_held_piece_stays_masked() {
  feed $'%@+@\n+@%%' "$T_TMP/log" 'z%@+@'
  assert_contains "$FEED_OUT" "after 1: [z[REDACTED]]"
  assert_contains "$FEED_OUT" "final: [z[REDACTED]]"
  assert_not_contains "$FEED_OUT" "+@]"
}

# Two secrets that overlap without one containing the other (A's end is B's start): every byte
# either covers is masked, in one write or split at the overlap.
test_overlapping_secrets_are_masked_together() {
  feed $'%@%@%@++\n%@++++@@' "$T_TMP/log" '%@%@%@++++@@ end'
  assert_contains "$FEED_OUT" "final: [[REDACTED] end]"
  feed $'%@%@%@++\n%@++++@@' "$T_TMP/log2" '%@%@%@++' '++@@ end'
  assert_contains "$FEED_OUT" "final: [[REDACTED] end]"
  feed $'%@++++@@\n%@%@%@++' "$T_TMP/log3" 'x %@%@%@++++@@'
  assert_contains "$FEED_OUT" "final: [x [REDACTED]]"
}

# A long run that matches a secret over and over is shown as one mask at once, not held until
# the end: what the filter holds stays below one secret's length.
test_a_long_run_of_matches_is_not_held() {
  feed '%%%%%%%%' "$T_TMP/log" "$(printf '%%%.0s' $(seq 1 3000))" 'Z'
  assert_contains "$FEED_OUT" "after 1: [[REDACTED]]"
  assert_contains "$FEED_OUT" "final: [[REDACTED]Z]"
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

# The refusal itself is checked (status 2 and its message), so a filter that can't start at all
# doesn't pass this test.
test_refuses_a_symlinked_log() {
  printf 'precious\n' >"$T_TMP/target"
  ln -s "$T_TMP/target" "$T_TMP/log"
  feed '%@+%@@%+' "$T_TMP/log" 'hello'
  assert_contains "$FEED_OUT" "rc: 2"
  assert_contains "$FEED_OUT" "stderr: [handoff_redact: cannot create the log $T_TMP/log:"
  assert_contains "$FEED_OUT" "final: []"
  assert_eq "$(cat "$T_TMP/target")" precious
}

test_refuses_an_existing_log() {
  printf 'old log\n' >"$T_TMP/log"
  feed '%@+%@@%+' "$T_TMP/log" 'hello'
  assert_contains "$FEED_OUT" "rc: 2"
  assert_contains "$FEED_OUT" "stderr: [handoff_redact: cannot create the log $T_TMP/log:"
  assert_contains "$FEED_OUT" "final: []"
  assert_eq "$(cat "$T_TMP/log")" "old log"
}

test_sigint_does_not_stop_the_filter() {
  FEED_SIGINT=1 feed '%@+%@@%+' "$T_TMP/log" 'before ' '%@+%@@%+ after'
  assert_contains "$FEED_OUT" "final: [before [REDACTED] after]"
  assert_contains "$FEED_OUT" "rc: 0"
}

# A secret list that doesn't end with "#END" may have been cut short: nothing is shown.
test_a_cut_short_secret_list_shows_nothing() {
  FEED_NO_END=1 feed '%@+%@@%+' "$T_TMP/log" 'token %@+%@@%+'
  assert_contains "$FEED_OUT" "final: []"
  assert_contains "$FEED_OUT" "stderr: [handoff_redact: the list of secrets was cut short; showing nothing]"
  [[ "$FEED_OUT" != *"rc: 0"* ]] || _t_fail "the filter accepted a list without #END: $FEED_OUT"
}

# "-" instead of a log path: the runtime's step banners, shown masked with no log.
test_no_log_mode_masks_and_writes_no_file() {
  feed '%@+%@@%+' "-" 'run /bin/echo %@+%@@%+'
  assert_contains "$FEED_OUT" "final: [run /bin/echo [REDACTED]]"
  assert_contains "$FEED_OUT" "rc: 0"
  [[ ! -e "-" && ! -e "$T_TMP/-" ]] || _t_fail "a file named - was written"
}

test_needs_exactly_the_log_path() {
  local out rc=0
  out="$(python3 -I "$REDACT" 2>&1 </dev/null)" || rc=$?
  [[ $rc -ne 0 ]] || _t_fail "ran without a log path"
  assert_contains "$out" "usage"
}

run_tests
