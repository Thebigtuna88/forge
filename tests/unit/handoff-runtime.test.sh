#!/usr/bin/env bash
# Tests for .harness/lib/handoff.sh (spec 4.3, 10.3).
# shellcheck disable=SC2031 # each test sets and reads T_TMP inside its own subshell (assert.sh)
# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"
# shellcheck source=tests/lib/fixture.sh
source "$(dirname "$0")/../lib/fixture.sh"

ID=2026-01-01-test

test_refuses_without_a_terminal() {
  mk_harness
  mk_script "$ID" 'ho_check ok /usr/bin/true'
  local out rc
  out="$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CODEX_SANDBOX -u CODEX_SANDBOX_NETWORK_DISABLED \
    bash "$SCRIPT" </dev/null 2>&1)"
  rc=$?
  assert_exit 3 "$rc"
  assert_contains "$out" "no terminal attached"
  [[ ! -f "$H/work/owner/$ID/RESULT.txt" ]] || _t_fail "RESULT.txt written despite refusal"
}

test_refuses_inside_an_agent_session() {
  mk_harness
  mk_script "$ID" 'ho_check ok /usr/bin/true'
  pty_run_as_agent -- bash "$SCRIPT"
  assert_exit 3 "$RC"
  assert_contains "$OUT" "CLAUDECODE is set"
  [[ ! -f "$H/work/owner/$ID/RESULT.txt" ]] || _t_fail "RESULT.txt written despite refusal"
}

# Spec 4.3: refuse when a marker is set, even to the empty string.
test_refuses_an_agent_marker_set_to_empty() {
  mk_harness
  mk_script "$ID" 'ho_check ok /usr/bin/true'
  OUT="$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CODEX_SANDBOX_NETWORK_DISABLED CODEX_SANDBOX= \
    PATH="$STUBS:$PATH" python3 -I "$TESTLIB/ptyrun.py" -- bash "$SCRIPT")"
  RC=$?
  assert_exit 3 "$RC"
  assert_contains "$OUT" "CODEX_SANDBOX is set"
  [[ ! -f "$H/work/owner/$ID/RESULT.txt" ]] || _t_fail "RESULT.txt written despite refusal"
}

# Only a script frozen by `handoff ready` (read-only) may run.
test_refuses_a_writable_script() {
  mk_harness
  mk_script "$ID" 'ho_check ok /usr/bin/true'
  chmod u+w "$SCRIPT"
  pty_run -- bash "$SCRIPT"
  assert_exit 3 "$RC"
  assert_contains "$OUT" "still writable"
  [[ ! -f "$H/work/owner/$ID/RESULT.txt" ]] || _t_fail "RESULT.txt written despite refusal"
}

test_refuses_when_executed_directly() {
  mk_harness
  local rc
  pty_run -- bash "$H/.harness/lib/handoff.sh"
  rc=$RC
  assert_exit 3 "$rc"
  assert_contains "$OUT" "must be sourced"
}

test_refuses_id_that_does_not_match_folder() {
  mk_harness
  mk_script "$ID" 'ho_check ok /usr/bin/true'
  chmod u+w "$SCRIPT"
  sed -i '' "s/ho_begin \"$ID\"/ho_begin \"other-id\"/" "$SCRIPT"
  chmod 444 "$SCRIPT"
  pty_run -- bash "$SCRIPT"
  assert_exit 3 "$RC"
  assert_contains "$OUT" "does not match the handoff folder"
}

test_all_pass_gives_result_ok_and_saves_block() {
  mk_harness
  mk_script "$ID" 'ho_check first /usr/bin/true' 'ho_info second /bin/echo hello world'
  pty_run -- bash "$SCRIPT"
  assert_exit 0 "$RC"
  local result
  result="$(cat "$H/work/owner/$ID/RESULT.txt")"
  assert_contains "$result" "----- HANDOFF-RESULT BEGIN -----"
  assert_contains "$result" "id: $ID"
  assert_contains "$result" "script-sha256: $(shasum -a 256 "$SCRIPT" | awk '{print $1}')"
  assert_contains "$result" "runtime-sha256: $(shasum -a 256 "$H/.harness/lib/handoff.sh" | awk '{print $1}')"
  assert_contains "$result" "check first: PASS (no output)"
  assert_contains "$result" "check second: INFO hello world"
  assert_contains "$result" "result: OK"
  assert_contains "$result" "----- HANDOFF-RESULT END -----"
  assert_eq "$(cat "$T_TMP/clipboard")" "$result" "clipboard holds the block"
}

test_check_fails_on_nonzero_exit_and_info_never_fails() {
  mk_harness
  mk_script "$ID" 'ho_check bad /usr/bin/false' 'ho_info soft /usr/bin/false'
  pty_run -- bash "$SCRIPT"
  assert_exit 1 "$RC"
  local result
  result="$(cat "$H/work/owner/$ID/RESULT.txt")"
  assert_contains "$result" "check bad: FAIL exit 1"
  assert_contains "$result" "check soft: INFO exit 1"
  assert_contains "$result" "result: FAILED"
}

test_check_keeps_a_terminal_for_interactive_commands() {
  mk_harness
  mk_script "$ID" "ho_check tty /bin/bash -c '[ -t 0 ] && [ -t 1 ] && echo has-tty'"
  pty_run -- bash "$SCRIPT"
  assert_contains "$(cat "$H/work/owner/$ID/RESULT.txt")" "check tty: PASS has-tty"
}

test_confirm_yes_passes_and_no_fails() {
  mk_harness
  mk_script "$ID" 'ho_confirm yes "Did it work?"' 'ho_confirm no "Did it work?"'
  pty_run --answer y --answer n -- bash "$SCRIPT"
  local result
  result="$(cat "$H/work/owner/$ID/RESULT.txt")"
  assert_contains "$result" "check yes: PASS confirmed"
  assert_contains "$result" "check no: FAIL not confirmed"
  assert_contains "$result" "result: FAILED"
}

test_secret_is_stored_mode_600_and_never_shown() {
  mk_harness
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/.env"
  pty_run --answer 'SuperSecretValue123' -- bash "$SCRIPT"
  assert_exit 0 "$RC"
  assert_eq "$(cat "$H/.env")" "API_KEY=SuperSecretValue123"
  assert_file_mode "$H/.env" 600
  assert_not_contains "$OUT" "SuperSecretValue123" "screen"
  assert_not_contains "$(cat "$H/work/owner/$ID/RESULT.txt")" "SuperSecretValue123" "block"
  assert_not_contains "$(cat "$T_TMP/clipboard")" "SuperSecretValue123" "clipboard"
  if grep -rq SuperSecretValue123 "$H/work/owner/$ID/"; then _t_fail "secret found under the handoff folder"; fi
  assert_contains "$(cat "$H/work/owner/$ID/RESULT.txt")" "check key: PASS stored API_KEY in $H/.env (mode 600)"
}

test_secret_replaces_only_its_own_line() {
  mk_harness
  printf 'API_KEY=old\nOTHER=keep\n' >"$H/.env"
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/.env"
  pty_run --answer 'new-value' -- bash "$SCRIPT"
  assert_eq "$(sort "$H/.env")" "$(printf 'API_KEY=new-value\nOTHER=keep')"
  assert_file_mode "$H/.env" 600
}

test_secret_refuses_a_file_that_is_not_gitignored() {
  mk_harness
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/committed.env"
  pty_run --answer 'never-stored' -- bash "$SCRIPT"
  assert_exit 1 "$RC"
  [[ ! -e "$H/committed.env" ]] || _t_fail "secret file was created"
  assert_contains "$(cat "$H/work/owner/$ID/RESULT.txt")" "check key: FAIL refused: $H/committed.env is not gitignored"
}

test_secret_write_failure_is_a_fail() {
  mk_harness
  mkdir "$H/.env" # gitignored, but a directory: the move would land inside it
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/.env" 'ho_check after /usr/bin/true'
  pty_run --answer 'value-1' -- bash "$SCRIPT"
  assert_exit 1 "$RC"
  assert_contains "$(cat "$H/work/owner/$ID/RESULT.txt")" "check key: FAIL refused: $H/.env exists but is not a regular file"
  [[ -z "$(ls -A "$H/.env")" ]] || _t_fail "something was written inside the directory"
}

test_secret_temp_file_must_be_gitignored() {
  mk_harness
  printf 'only.env\n' >"$H/.gitignore" # the target is ignored, its temp file would not be
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/only.env"
  pty_run --answer 'value-2' -- bash "$SCRIPT"
  assert_exit 1 "$RC"
  assert_contains "$(cat "$H/work/owner/$ID/RESULT.txt")" "check key: FAIL could not write $H/only.env"
  [[ ! -e "$H/only.env" ]] || _t_fail "secret was written"
  local f
  for f in "$H"/*ho-tmp* "$H"/.*ho-tmp*; do [[ ! -e "$f" ]] || _t_fail "temp file left behind: $f"; done
}

test_secret_rejects_shell_characters() {
  mk_harness
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/.env"
  # shellcheck disable=SC2016 # literal on purpose: it must never be executed or stored
  pty_run --answer '$(touch '"$T_TMP"'/executed)' -- bash "$SCRIPT"
  assert_exit 1 "$RC"
  assert_contains "$(cat "$H/work/owner/$ID/RESULT.txt")" "check key: FAIL refused: the value has spaces, quotes or shell characters"
  [[ ! -e "$H/.env" ]] || _t_fail "unsafe value was stored"
  [[ ! -e "$T_TMP/executed" ]] || _t_fail "the value was executed"
}

test_secret_is_redacted_from_later_steps() {
  mk_harness
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/.env" "ho_info reveal /bin/cat $H/.env"
  pty_run --answer 'Leaky-Value-42' -- bash "$SCRIPT"
  local result
  result="$(cat "$H/work/owner/$ID/RESULT.txt")"
  assert_contains "$result" "check reveal: INFO API_KEY=[REDACTED]"
  if grep -rq Leaky-Value-42 "$H/work/owner/$ID/"; then _t_fail "secret found under the handoff folder"; fi
  assert_not_contains "$(cat "$T_TMP/clipboard")" "Leaky-Value-42" "clipboard"
}

test_handoff_files_are_private() {
  mk_harness
  mk_script "$ID" 'ho_check ok /usr/bin/true'
  pty_run -- bash "$SCRIPT"
  assert_file_mode "$H/work/owner/$ID" 700
  assert_file_mode "$H/work/owner/$ID/logs" 700
  assert_file_mode "$H/work/owner/$ID/RESULT.txt" 600
}

# shopt exists only inside bash (unlike command or type, which macOS also ships in /usr/bin).
test_check_runs_shell_builtins() {
  mk_harness
  mk_script "$ID" 'ho_check has-bash command -v bash' 'ho_check bash-only shopt -s nullglob'
  pty_run -- bash "$SCRIPT"
  assert_exit 0 "$RC" "$OUT"
  assert_contains "$(cat "$H/work/owner/$ID/RESULT.txt")" "check has-bash: PASS /"
  assert_contains "$(cat "$H/work/owner/$ID/RESULT.txt")" "check bash-only: PASS"
}

test_secret_with_surrounding_spaces_is_refused_not_trimmed() {
  mk_harness
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/.env"
  pty_run --answer '  Token-123  ' -- bash "$SCRIPT"
  assert_exit 1 "$RC"
  [[ ! -e "$H/.env" ]] || _t_fail "a value with spaces was stored (trimmed)"
}

test_secret_split_by_dashes_stays_redacted() {
  mk_harness
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/.env" "ho_info split /usr/bin/printf 'abc-----def\n'"
  pty_run --answer 'abcdef' -- bash "$SCRIPT"
  local result
  result="$(cat "$H/work/owner/$ID/RESULT.txt")"
  assert_contains "$result" "check split: INFO [REDACTED]"
  assert_not_contains "$result" "abcdef"
}

test_secret_rejects_a_tilde() {
  mk_harness
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/.env"
  pty_run --answer 'abc~def' -- bash "$SCRIPT"
  assert_exit 1 "$RC"
  [[ ! -e "$H/.env" ]] || _t_fail "a value with ~ was stored (bash would expand it)"
}

test_overlapping_secrets_are_redacted_whole() {
  mk_harness
  mk_script "$ID" "ho_secret_to_file short A $H/.env" "ho_secret_to_file long B $H/.env" \
    "ho_info reveal /usr/bin/sort $H/.env"
  pty_run --answer 'abc' --answer 'abcdef' -- bash "$SCRIPT"
  local result
  result="$(cat "$H/work/owner/$ID/RESULT.txt")"
  assert_contains "$result" "check reveal: INFO B=[REDACTED]"
  assert_not_contains "$result" "def"
}

test_refuses_shell_tracing() {
  mk_harness
  mk_script "$ID" 'ho_check ok /usr/bin/true'
  pty_run -- bash -x "$SCRIPT"
  assert_exit 3 "$RC"
  assert_contains "$OUT" "shell tracing"
  [[ ! -f "$H/work/owner/$ID/RESULT.txt" ]] || _t_fail "RESULT.txt written despite refusal"
}

test_refuses_symlinked_outputs() {
  mk_harness
  mk_script "$ID" 'ho_check ok /usr/bin/true'
  printf 'precious\n' >"$T_TMP/precious"
  ln -s "$T_TMP/precious" "$H/work/owner/$ID/RESULT.txt"
  pty_run -- bash "$SCRIPT"
  assert_exit 3 "$RC"
  assert_contains "$OUT" "symlink"
  assert_eq "$(cat "$T_TMP/precious")" precious
  rm "$H/work/owner/$ID/RESULT.txt"
  mkdir -p "$H/work/owner/$ID/logs"
  ln -s "$T_TMP/precious" "$H/work/owner/$ID/logs/ok.log"
  pty_run -- bash "$SCRIPT"
  assert_exit 0 "$RC" "$OUT"
  assert_eq "$(cat "$T_TMP/precious")" precious "a step log was written through a symlink"
  rm -rf "$H/work/owner/$ID/logs" "$H/work/owner/$ID/RESULT.txt"
  mkdir -p "$T_TMP/elsewhere"
  ln -s "$T_TMP/elsewhere" "$H/work/owner/$ID/logs"
  pty_run -- bash "$SCRIPT"
  assert_exit 3 "$RC"
  assert_contains "$OUT" "symlink"
  [[ -z "$(ls -A "$T_TMP/elsewhere")" ]] || _t_fail "logs were written through a symlinked folder"
}

test_refuses_when_the_folder_cannot_be_made_private() {
  mk_harness
  mk_script "$ID" 'ho_check ok /usr/bin/true'
  mkdir "$T_TMP/bin"
  # shellcheck disable=SC2016 # the stub's own $1
  printf '#!/bin/bash\n[[ "$1" == 700 ]] && exit 1\nexec /bin/chmod "$@"\n' >"$T_TMP/bin/chmod"
  /bin/chmod +x "$T_TMP/bin/chmod"
  OUT="$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CODEX_SANDBOX -u CODEX_SANDBOX_NETWORK_DISABLED \
    PATH="$T_TMP/bin:$STUBS:$PATH" STUB_CLIPBOARD="$T_TMP/clipboard" \
    python3 -I "$TESTLIB/ptyrun.py" -- bash "$SCRIPT")"
  RC=$?
  assert_exit 3 "$RC" "$OUT"
  assert_contains "$OUT" "could not make the handoff folder private"
}

test_steps_run_from_the_root_folder() {
  mk_harness
  mk_script "$ID" 'ho_check where /bin/pwd'
  OUT="$(cd "$H" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CODEX_SANDBOX \
    -u CODEX_SANDBOX_NETWORK_DISABLED PATH="$STUBS:$PATH" STUB_CLIPBOARD="$T_TMP/clipboard" \
    python3 -I "$TESTLIB/ptyrun.py" -- bash work/owner/"$ID"/OWNER-RUN.sh)"
  RC=$?
  assert_exit 0 "$RC" "$OUT"
  assert_contains "$(cat "$H/work/owner/$ID/RESULT.txt")" "check where: PASS /"$'\n'
}

test_unredactable_log_ends_the_run() {
  mk_harness
  # A step that prints the secret, then makes the log folder read-only so the log can't be replaced.
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/.env" \
    "ho_check leak /bin/bash -c 'cat $H/.env; chmod 500 $H/work/owner/$ID/logs'" 'ho_check after /usr/bin/true'
  pty_run --answer 'Secret-77' -- bash "$SCRIPT"
  chmod 700 "$H/work/owner/$ID/logs"
  assert_exit 1 "$RC"
  local result
  result="$(cat "$H/work/owner/$ID/RESULT.txt")"
  assert_contains "$result" "check _runtime: FAIL could not redact the log of step leak"
  assert_contains "$result" "result: FAILED"
  assert_not_contains "$result" "check after"
}

test_unsaved_result_is_not_reported_ok() {
  mk_harness
  mk_script "$ID" 'ho_check ok /usr/bin/true'
  mkdir -p "$H/work/owner/$ID/RESULT.txt" # a directory: the block cannot be saved
  pty_run -- bash "$SCRIPT"
  assert_exit 1 "$RC"
  assert_contains "$OUT" "Could not save"
  [[ ! -s "$T_TMP/clipboard" ]] || _t_fail "an unsaved block was copied to the clipboard"
}

# at: is when the run started, so a run begun before `handoff ready` cannot pass verify.
test_at_is_the_start_time() {
  mk_harness
  mk_script "$ID" 'ho_check wait /bin/sleep 3'
  local before at
  before="$(date -u +%s)"
  pty_run -- bash "$SCRIPT"
  at="$(sed -n 's/^at: //p' "$H/work/owner/$ID/RESULT.txt")"
  at="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$at" +%s)"
  [[ $((at - before)) -le 1 ]] || _t_fail "at is $((at - before))s after the start (end time, not start)"
}

# Interrupted while the secret's temp file exists: the EXIT trap removes it.
test_interrupted_secret_write_leaves_no_temp_file() {
  mk_harness
  mkdir "$T_TMP/slow"
  # A chmod that, for the temp file only, sends TERM to the owner's script and waits.
  # shellcheck disable=SC2016 # the stub's own $2, $PPID and $@
  printf '#!/bin/bash\ncase "$2" in *ho-tmp*) kill -TERM "$PPID"; sleep 2; exit 1 ;; esac\nexec /bin/chmod "$@"\n' \
    >"$T_TMP/slow/chmod"
  chmod +x "$T_TMP/slow/chmod"
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/.env"
  OUT="$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CODEX_SANDBOX -u CODEX_SANDBOX_NETWORK_DISABLED \
    PATH="$T_TMP/slow:$STUBS:$PATH" STUB_CLIPBOARD="$T_TMP/clipboard" \
    python3 -I "$TESTLIB/ptyrun.py" --answer 'Interrupted-9' -- bash "$SCRIPT")"
  RC=$?
  assert_exit 1 "$RC" "$OUT"
  local f
  for f in "$H"/.env.ho-tmp.*; do [[ ! -e "$f" ]] || _t_fail "temp file with the secret left behind: $f"; done
  assert_contains "$(cat "$H/work/owner/$ID/RESULT.txt")" "check _runtime: FAIL script exited with status 130"
}

test_interrupted_secret_write_reports_a_temp_file_it_cannot_remove() {
  mk_harness
  mkdir "$T_TMP/slow"
  # For the temp file only: make its folder read-only, then send TERM to the owner's script.
  # shellcheck disable=SC2016 # the stub's own $2, $PPID and $@
  printf '#!/bin/bash\ncase "$2" in *ho-tmp*) /bin/chmod 500 "$(dirname "$2")"; kill -TERM "$PPID"; sleep 2; exit 1 ;; esac\nexec /bin/chmod "$@"\n' \
    >"$T_TMP/slow/chmod"
  chmod +x "$T_TMP/slow/chmod"
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/.env"
  OUT="$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CODEX_SANDBOX -u CODEX_SANDBOX_NETWORK_DISABLED \
    PATH="$T_TMP/slow:$STUBS:$PATH" STUB_CLIPBOARD="$T_TMP/clipboard" \
    python3 -I "$TESTLIB/ptyrun.py" --answer 'Stuck-1' -- bash "$SCRIPT")"
  chmod 700 "$H"
  assert_contains "$(cat "$H/work/owner/$ID/RESULT.txt")" "check _runtime: FAIL could not remove the temp file $H/.env.ho-tmp."
}

test_secret_refuses_empty_input() {
  mk_harness
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/.env"
  pty_run --answer '' -- bash "$SCRIPT"
  assert_exit 1 "$RC"
  [[ ! -e "$H/.env" ]] || _t_fail "empty secret was stored"
  assert_contains "$(cat "$H/work/owner/$ID/RESULT.txt")" "check key: FAIL empty input"
}

test_abort_stops_before_later_steps() {
  mk_harness
  mk_script "$ID" 'ho_check bad /usr/bin/false || ho_abort' 'ho_check never /usr/bin/true'
  pty_run -- bash "$SCRIPT"
  assert_exit 1 "$RC"
  local result
  result="$(cat "$H/work/owner/$ID/RESULT.txt")"
  assert_contains "$result" "result: FAILED"
  assert_not_contains "$result" "check never"
}

test_crash_before_ho_end_still_reports_failed() {
  mk_harness
  # shellcheck disable=SC2016 # literal on purpose: the owner script must crash on it
  mk_script "$ID" 'ho_check ok /usr/bin/true' 'echo "$UNDEFINED_VARIABLE"'
  pty_run -- bash "$SCRIPT"
  assert_exit 1 "$RC"
  local result
  result="$(cat "$H/work/owner/$ID/RESULT.txt")"
  assert_contains "$result" "check _runtime: FAIL script exited with status"
  assert_contains "$result" "result: FAILED"
}

test_invalid_or_duplicate_step_names_fail() {
  mk_harness
  mk_script "$ID" 'ho_check Bad_Name /usr/bin/true'
  pty_run -- bash "$SCRIPT"
  assert_contains "$(cat "$H/work/owner/$ID/RESULT.txt")" "check _runtime: FAIL invalid step name"
  mk_script "$ID" 'ho_check same /usr/bin/true' 'ho_check same /usr/bin/true'
  pty_run -- bash "$SCRIPT"
  assert_contains "$(cat "$H/work/owner/$ID/RESULT.txt")" "check _runtime: FAIL duplicate step name"
}

test_evidence_is_one_clean_line() {
  mk_harness
  mk_script "$ID" "ho_info noisy /usr/bin/printf 'first\\nsecond -----END \\033[31mred\\033[0m\\tdone\\n\\n'"
  pty_run -- bash "$SCRIPT"
  assert_contains "$(cat "$H/work/owner/$ID/RESULT.txt")" "check noisy: INFO second END red done"
}

# gh queries the terminal's colours with OSC sequences (ESC ] … ST or BEL, or cut off); none of it is evidence.
test_evidence_drops_osc_sequences() {
  mk_harness
  mk_script "$ID" \
    "ho_info st /usr/bin/printf 'kept\\033]11;?\\033\\\\\\n'" \
    "ho_info bel /usr/bin/printf '\\033]0;title\\007also kept\\n'" \
    "ho_info only /usr/bin/printf '\\033]11;?\\033\\\\\\n'" \
    "ho_info cut /usr/bin/printf 'cut ok\\033]11;rgb:00\\n'"
  pty_run -- bash "$SCRIPT"
  local result
  result="$(cat "$H/work/owner/$ID/RESULT.txt")"
  assert_contains "$result" "check st: INFO kept"$'\n'
  assert_contains "$result" "check bel: INFO also kept"$'\n'
  assert_contains "$result" "check only: INFO (no output)"
  assert_contains "$result" "check cut: INFO cut ok"$'\n'
  assert_not_contains "$result" "11;?"
}

run_tests
