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

test_refuses_a_script_that_was_never_readied() {
  mk_harness
  mk_script "$ID" 'ho_check ok /usr/bin/true'
  jq '.state = "draft"' "$H/work/owner/$ID/META.json" >"$T_TMP/m" && cat "$T_TMP/m" >"$H/work/owner/$ID/META.json"
  pty_run -- bash "$SCRIPT"
  assert_exit 3 "$RC"
  assert_contains "$OUT" "not the one 'handoff ready' froze"
  jq '.state = "ready" | .script_sha256 = "0000"' "$H/work/owner/$ID/META.json" >"$T_TMP/m" \
    && cat "$T_TMP/m" >"$H/work/owner/$ID/META.json"
  pty_run -- bash "$SCRIPT"
  assert_exit 3 "$RC"
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
  # The secrets are made only of characters (% @ , +) that RESULT.txt never holds otherwise: not
  # in its hex checksums, its timestamp, the test folder's path or its wording. So the whole file
  # can be searched with no exemptions, and any piece of either secret shows up: the short one,
  # the long one, or the ",+," a short-first redaction would leave of the long one. (With letters,
  # a random checksum could hold them by chance, FRG-23.)
  [[ "$T_TMP" != *[%@,+]* ]] || _t_fail "the test folder's path ($T_TMP) holds % @ , or +; this test can't tell it from a leak"
  pty_run --answer '%@%' --answer '%@%,+,' -- bash "$SCRIPT"
  local result
  result="$(cat "$H/work/owner/$ID/RESULT.txt")"
  assert_contains "$result" "check long: PASS stored B in $H/.env (mode 600)"
  assert_contains "$result" "check reveal: INFO B=[REDACTED]"
  [[ "$result" != *[%@,+]* ]] || _t_fail "RESULT.txt holds a piece of a secret (% @ , or +): $result"
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

test_refuses_when_checksums_cannot_be_computed() {
  mk_harness
  mk_script "$ID" 'ho_check ok /usr/bin/true'
  mkdir "$T_TMP/bin"
  printf '#!/bin/bash\nexit 1\n' >"$T_TMP/bin/shasum"
  chmod +x "$T_TMP/bin/shasum"
  OUT="$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CODEX_SANDBOX -u CODEX_SANDBOX_NETWORK_DISABLED \
    PATH="$T_TMP/bin:$STUBS:$PATH" STUB_CLIPBOARD="$T_TMP/clipboard" \
    python3 -I "$TESTLIB/ptyrun.py" -- bash "$SCRIPT")"
  RC=$?
  assert_exit 3 "$RC" "$OUT"
  assert_contains "$OUT" "could not compute the sha256"
  [[ ! -e "$H/work/owner/$ID/logs/ok.log" ]] || _t_fail "a step ran without checksums"
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
  # It waits first, so the live filter has already created the log (if the folder were locked
  # before that, the filter's own refusal would end the run instead).
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/.env" \
    "ho_check leak /bin/bash -c 'cat $H/.env; sleep 1; chmod 500 $H/work/owner/$ID/logs'" 'ho_check after /usr/bin/true'
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

# --- Live redaction (FRG-14) ------------------------------------------------------------------
# The secrets are made only of % @ +, which the screen, logs and RESULT.txt never hold otherwise
# (as in FRG-23), so any piece of a secret anywhere is a leak. (Not ",": the screen prints
# "(stored, not shown)".)
SECRET='%@+%@@%+'
SECRET2='@@%%++@%'

no_secret_piece() { # <text> <where>
  [[ "$1" != *[%@+]* ]] || _t_fail "$2 holds a piece of a secret (% @ or +): ${1:0:600}"
}

# pty_run_bg [--answer X]... -- <script>: like pty_run, in the background (BG = its pid).
pty_run_bg() {
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CODEX_SANDBOX -u CODEX_SANDBOX_NETWORK_DISABLED \
    PATH="$STUBS:$PATH" STUB_CLIPBOARD="$T_TMP/clipboard" \
    python3 -I "$TESTLIB/ptyrun.py" "$@" >"$T_TMP/bg-out" 2>&1 &
  BG=$!
}

wait_for_file() { # <file>: up to 10 s
  local tries=100
  while [[ $tries -gt 0 ]]; do
    [[ -e "$1" ]] && return 0
    sleep 0.1
    tries=$((tries - 1))
  done
  return 1
}

test_live_secret_never_reaches_the_screen() {
  mk_harness
  [[ "$T_TMP" != *[%@+]* ]] || _t_fail "the test folder's path holds % @ or +"
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/.env" "ho_info reveal /bin/cat $H/.env"
  pty_run --answer "$SECRET" -- bash "$SCRIPT"
  assert_contains "$OUT" "API_KEY=[REDACTED]" "screen"
  no_secret_piece "$OUT" "the screen"
  no_secret_piece "$(cat "$H/work/owner/$ID/logs/reveal.log")" "the log"
  no_secret_piece "$(cat "$H/work/owner/$ID/RESULT.txt")" "RESULT.txt"
}

# script(1) buffers its log, so the step prints 200 kB after the secret: enough that, without live
# redaction, the raw secret would already be in the log mid-step. The step then waits until the
# test creates "release" (at most 20 s), so it is certainly still running when the log is read.
HOLD_STEP="cat \$0/.env; yes | head -c 200000; touch \$1/printed; n=200; while [ ! -e \$1/release ] && [ \$n -gt 0 ]; do sleep 0.1; n=\$((n-1)); done"

test_live_log_never_holds_the_secret_mid_step() {
  mk_harness
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/.env" "ho_info reveal /bin/bash -c '$HOLD_STEP' $H $T_TMP"
  pty_run_bg --answer "$SECRET" -- bash "$SCRIPT"
  wait_for_file "$T_TMP/printed" || _t_fail "the step never printed"
  sleep 0.5
  local log
  log="$(cat "$H/work/owner/$ID/logs/reveal.log" 2>/dev/null)"
  [[ ! -e "$H/work/owner/$ID/RESULT.txt" ]] || _t_fail "the run had already ended when the log was read"
  assert_contains "$log" "API_KEY=" "mid-step, the step's output is already in the log"
  no_secret_piece "$log" "mid-step, the log"
  touch "$T_TMP/release"
  wait "$BG"
}

test_live_log_of_a_killed_run_never_holds_the_secret() {
  mk_harness
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/.env" "ho_info reveal /bin/bash -c '$HOLD_STEP' $H $T_TMP"
  pty_run_bg --answer "$SECRET" -- bash "$SCRIPT"
  wait_for_file "$T_TMP/printed" || _t_fail "the step never printed"
  sleep 0.5
  local owner
  owner="$(pgrep -f "^bash $SCRIPT\$")"
  [[ -n "$owner" ]] || _t_fail "could not find the owner's script to kill"
  kill -KILL "$owner"
  touch "$T_TMP/release"
  wait "$BG"
  local log
  log="$(cat "$H/work/owner/$ID/logs/reveal.log" 2>/dev/null)"
  assert_contains "$log" "API_KEY=" "the step's output is in the log"
  no_secret_piece "$log" "after the run was killed, the log"
}

test_live_secret_split_across_writes_is_redacted() {
  mk_harness
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/.env" \
    "ho_info split /bin/bash -c 'v=\$(cut -d= -f2 $H/.env); echo -n \"\${v:0:4}\"; sleep 0.5; echo \"\${v:4}\"'"
  pty_run --answer "$SECRET" -- bash "$SCRIPT"
  assert_contains "$OUT" "[REDACTED]" "screen"
  no_secret_piece "$OUT" "the screen"
  no_secret_piece "$(cat "$H/work/owner/$ID/logs/split.log")" "the log"
  assert_contains "$(cat "$H/work/owner/$ID/RESULT.txt")" "check split: INFO [REDACTED]"
}

test_live_overlapping_secrets_are_redacted_whole() {
  mk_harness
  mk_script "$ID" "ho_secret_to_file short A $H/.env" "ho_secret_to_file long B $H/.env" \
    "ho_info split /bin/bash -c 'v=\$(grep ^B= $H/.env | cut -d= -f2); echo -n \"\${v:0:3}\"; sleep 0.5; echo \"\${v:3}\"'"
  # B starts with A: a short-first redaction would leave "+@+" of B on the screen.
  pty_run --answer '%@%' --answer '%@%+@+' -- bash "$SCRIPT"
  assert_contains "$OUT" "[REDACTED]" "screen"
  no_secret_piece "$OUT" "the screen"
  no_secret_piece "$(cat "$H/work/owner/$ID/logs/split.log")" "the log"
}

# The secrets reach the filter out-of-band: no process's command line and not the step's
# environment holds one. (They come from a file here, not from typed answers: ptyrun's own
# command line would hold an answer.)
test_live_secrets_are_not_on_command_lines_or_in_the_environment() {
  mk_harness
  printf 'HELPER_TOKEN=%s\n' "$SECRET" >"$H/.env.helper"
  mk_script "$ID" "ho_redact_file hide $H/.env.helper" \
    "ho_info probe /bin/bash -c 'ps -A -ww -o command= >$T_TMP/ps.txt; env >$T_TMP/env.txt'"
  pty_run -- bash "$SCRIPT"
  # Other processes' command lines and the environment may hold % @ + for their own reasons, so
  # these look for the secret and each half of it.
  local where text
  for where in ps env; do
    text="$(cat "$T_TMP/$where.txt")"
    assert_not_contains "$text" "$SECRET" "$where"
    assert_not_contains "$text" "${SECRET:0:4}" "$where (first half)"
    assert_not_contains "$text" "${SECRET:4}" "$where (second half)"
  done
  assert_contains "$(cat "$T_TMP/ps.txt")" "Live redaction filter for handoff steps" "the filter was running during the step"
}

# ho_begin keeps the checked filter text; replacing the file mid-run changes nothing.
test_live_filter_replaced_mid_run_changes_nothing() {
  mk_harness
  printf 'import os, sys\nos.write(1, os.read(0, 65536))\n' >"$T_TMP/copier.py"
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/.env" \
    "ho_check swap /bin/cp $T_TMP/copier.py $H/.harness/lib/handoff_redact.py" \
    "ho_info reveal /bin/cat $H/.env"
  pty_run --answer "$SECRET" -- bash "$SCRIPT"
  assert_exit 0 "$RC" "$OUT"
  assert_contains "$(cat "$H/.harness/lib/handoff_redact.py")" "os.read(0" "the file was replaced"
  assert_contains "$OUT" "API_KEY=[REDACTED]"
  no_secret_piece "$OUT" "the screen"
  no_secret_piece "$(cat "$H/work/owner/$ID/logs/reveal.log")" "the log"
}

# The filter runs on Apple's interpreter itself, not the /usr/bin/python3 shim, whose choice of
# interpreter follows DEVELOPER_DIR: with DEVELOPER_DIR pointing nowhere, the shim can't start
# anything, but the filter still runs. (No secrets here: collecting one needs git, which is a
# DEVELOPER_DIR shim too and would refuse.)
test_live_filter_does_not_depend_on_developer_dir() {
  mk_harness
  mk_script "$ID" 'ho_info plain /bin/echo hello world'
  # Only the owner's script gets the bad DEVELOPER_DIR (the test driver itself runs on the shim).
  pty_run -- /usr/bin/env DEVELOPER_DIR=/nonexistent bash "$SCRIPT"
  assert_exit 0 "$RC" "$OUT"
  assert_contains "$OUT" "hello world"
  assert_contains "$(cat "$H/work/owner/$ID/RESULT.txt")" "check plain: INFO hello world"
}

# The runtime runs only the reviewed filter: its sha256 is fixed in handoff.sh, so runtime-sha256
# in the evidence covers it too.
test_live_refuses_a_missing_or_changed_filter() {
  mk_harness
  mk_script "$ID" 'ho_check ok /usr/bin/true'
  mv "$H/.harness/lib/handoff_redact.py" "$T_TMP/filter.py"
  pty_run -- bash "$SCRIPT"
  assert_exit 3 "$RC"
  assert_contains "$OUT" "redaction filter"
  { cat "$T_TMP/filter.py"; printf '# changed\n'; } >"$H/.harness/lib/handoff_redact.py"
  pty_run -- bash "$SCRIPT"
  assert_exit 3 "$RC"
  assert_contains "$OUT" "redaction filter"
  [[ ! -f "$H/work/owner/$ID/RESULT.txt" ]] || _t_fail "RESULT.txt written despite the refusal"
}

# The filter's pin is checked with the checked interpreter, so a shasum on PATH that answers the
# pin for whatever it reads can't get a different filter accepted.
test_live_filter_pin_ignores_a_lying_shasum() {
  mk_harness
  local pin
  pin="$(sed -n 's/^HO_REDACT_SHA256=//p' "$H/.harness/lib/handoff.sh")"
  mkdir "$T_TMP/fake"
  # shellcheck disable=SC2016 # the fake's own $# and $@
  printf '#!/bin/bash\nif [ "$#" -ge 3 ]; then exec /usr/bin/shasum "$@"; fi\ncat >/dev/null\necho "%s  -"\n' "$pin" \
    >"$T_TMP/fake/shasum"
  chmod +x "$T_TMP/fake/shasum"
  printf 'import os\nos.write(1, os.read(0, 65536))\n' >"$H/.harness/lib/handoff_redact.py"
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/.env" "ho_info reveal /bin/cat $H/.env"
  OUT="$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CODEX_SANDBOX -u CODEX_SANDBOX_NETWORK_DISABLED \
    PATH="$T_TMP/fake:$STUBS:$PATH" STUB_CLIPBOARD="$T_TMP/clipboard" \
    python3 -I "$TESTLIB/ptyrun.py" --answer "$SECRET" -- bash "$SCRIPT")"
  RC=$?
  assert_exit 3 "$RC"
  assert_contains "$OUT" "redaction filter"
  no_secret_piece "$OUT" "the screen"
}

# The filter dies mid-step: the step's output is not shown raw, and the run ends FAILED. Only this
# fixture's filter is stopped, found by its log path (the [e] keeps the step's own command line,
# which holds the pattern, from matching).
test_live_redaction_failure_ends_the_run_and_shows_nothing() {
  mk_harness
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/.env" \
    "ho_info reveal /bin/bash -c 'pkill -TERM -f \"$H/work/owner/$ID/logs/rev[e]al.log\"; sleep 0.5; cat $H/.env; sleep 0.5'" \
    'ho_check after /usr/bin/true'
  pty_run --answer "$SECRET" -- bash "$SCRIPT"
  assert_exit 1 "$RC"
  local result
  result="$(cat "$H/work/owner/$ID/RESULT.txt")"
  assert_contains "$result" "check _runtime: FAIL live redaction failed in step reveal"
  assert_contains "$result" "result: FAILED"
  assert_not_contains "$result" "check after"
  no_secret_piece "$OUT" "the screen"
}

# Ctrl-C typed at a step's prompt reaches the step (script(1) keeps the terminal raw); the step
# fails, and nothing it printed before shows the secret. The prompt is built at run time: the
# runtime prints each step's command first, and a literal "[y/N] " there would be answered early.
test_live_ctrl_c_mid_step_fails_it_and_shows_nothing() {
  mk_harness
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/.env" \
    "ho_check stop /bin/bash -c 'cat $H/.env; p=\"[y/N\"; read -r -p \"Stop? \$p] \" a; sleep 5'"
  pty_run --answer "$SECRET" --answer $'\003' -- bash "$SCRIPT"
  assert_exit 1 "$RC"
  local result
  result="$(cat "$H/work/owner/$ID/RESULT.txt")"
  assert_contains "$result" "check stop: FAIL"
  assert_contains "$result" "result: FAILED"
  no_secret_piece "$OUT" "the screen"
  no_secret_piece "$(cat "$H/work/owner/$ID/logs/stop.log")" "the log"
}

test_live_step_prompt_without_newline_gets_its_answer() {
  mk_harness
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/.env" \
    "ho_check ask /bin/bash -c 'p=\"[y/N\"; read -r -p \"Go on? \$p] \" a; [ \"\$a\" = y ]'"
  pty_run --answer "$SECRET" --answer y -- bash "$SCRIPT"
  assert_exit 0 "$RC" "$OUT"
  assert_contains "$OUT" "Go on? [y/N] "
}

test_live_screen_codes_and_plain_output_pass_through() {
  mk_harness
  mk_script "$ID" "ho_info color /usr/bin/printf '\\033[31mred\\033[0m\\n'" 'ho_info plain /bin/echo hello world'
  pty_run -- bash "$SCRIPT"
  assert_exit 0 "$RC" "$OUT"
  assert_contains "$OUT" $'\033[31mred\033[0m'
  assert_contains "$OUT" "hello world"
  assert_contains "$(cat "$H/work/owner/$ID/logs/plain.log")" "hello world"
}

# --- ho_redact_file (FRG-14, Option A) --------------------------------------------------------

test_redact_file_hides_stored_values() {
  mk_harness
  printf 'HELPER_TOKEN=%s\nOTHER=%s\n' "$SECRET" "$SECRET2" >"$H/.env.helper"
  mk_script "$ID" "ho_redact_file hide $H/.env.helper" "ho_info reveal /bin/cat $H/.env.helper"
  pty_run -- bash "$SCRIPT"
  assert_exit 0 "$RC" "$OUT"
  local result
  result="$(cat "$H/work/owner/$ID/RESULT.txt")"
  assert_contains "$result" "check hide: PASS hiding 2 values from $H/.env.helper"
  assert_contains "$result" "check reveal: INFO OTHER=[REDACTED]"
  assert_contains "$OUT" "HELPER_TOKEN=[REDACTED]"
  no_secret_piece "$OUT" "the screen"
  no_secret_piece "$result" "RESULT.txt"
  no_secret_piece "$(cat "$H/work/owner/$ID/logs/reveal.log")" "the log"
  no_secret_piece "$(cat "$T_TMP/clipboard")" "the clipboard"
}

# A value that appears in the handoff's own text (its script, folder, id or checksums) couldn't be
# kept hidden: banners, questions, paths, the log path on the filter's command line and the
# block's header all come from that text. ho_redact_file refuses such a file and ends the run.
expect_own_text_refused() { # <value>
  printf 'TOKEN=%s\n' "$1" >"$H/.env.helper"
  pty_run -- bash "$SCRIPT"
  assert_exit 1 "$RC"
  local result
  result="$(cat "$H/work/owner/$ID/RESULT.txt")"
  assert_contains "$result" "check hide: FAIL refused: a value in $H/.env.helper appears in this handoff's own text"
  assert_contains "$OUT" "Stopping here"
  assert_not_contains "$result" "check deploy-prod-1"
}

test_redact_file_refuses_values_in_the_handoffs_own_text() {
  mk_harness
  mk_script "$ID" "ho_redact_file hide $H/.env.helper" "ho_confirm go 'Deploy to x$SECRET now?'" \
    'ho_check deploy-prod-1 /usr/bin/true'
  expect_own_text_refused "$SECRET"           # in a confirm question
  expect_own_text_refused deploy-prod-1       # a step name
  expect_own_text_refused work/owner          # part of the handoff's folder
  expect_own_text_refused "${ID:0:10}"        # part of the handoff's id
  expect_own_text_refused REDACTED            # inside the [REDACTED] marker
  expect_own_text_refused clipboard           # a fixed runtime message
  expect_own_text_refused bytearray           # the filter's text, on its command line
  expect_own_text_refused /logs/deploy-prod-1.log  # a step's log path, also on that line
  local py
  py="$(/usr/bin/readlink -f /Library/Developer/CommandLineTools/usr/bin/python3)"
  expect_own_text_refused "${py##*/Developer/}"    # the interpreter's path: the filter's argv[0]
  assert_not_contains "$OUT" "deploy-prod-1: /usr/bin/true" "the later step never ran"
}

# The same for a typed secret: refused, nothing stored, the run goes on.
test_secret_to_file_refuses_a_value_in_the_handoffs_own_text() {
  mk_harness
  mk_script "$ID" "ho_secret_to_file key API_KEY $H/.env" "ho_confirm go 'Deploy to x$SECRET now?'"
  pty_run --answer "$SECRET" --answer y -- bash "$SCRIPT"
  assert_exit 1 "$RC"
  assert_contains "$(cat "$H/work/owner/$ID/RESULT.txt")" "check key: FAIL refused: the value appears in this handoff's own text"
  [[ ! -e "$H/.env" ]] || _t_fail "the value was stored"
}

# Evidence is masked as a whole, not one secret at a time: B starts where A ends, and the step's
# output only joins them once its "-----" is removed from the evidence.
test_overlapping_secrets_in_evidence_are_masked_whole() {
  mk_harness
  mk_script "$ID" "ho_secret_to_file a A $H/.env" "ho_secret_to_file b B $H/.env" \
    "ho_info split /bin/echo %@%@%@-----++++@@"
  pty_run --answer '%@%@%@++' --answer '%@++++@@' -- bash "$SCRIPT"
  local result
  result="$(cat "$H/work/owner/$ID/RESULT.txt")"
  assert_contains "$result" "check split: INFO [REDACTED]"$'\n'
  assert_not_contains "$result" "++@@"
}

# Blank lines (spaces only) and Windows line endings in a stored secrets file are fine.
test_redact_file_accepts_blank_lines_and_crlf() {
  mk_harness
  printf 'TOKEN=%s\r\n   \r\n\nOTHER=%s\n' "$SECRET" "$SECRET2" >"$H/.env.helper"
  mk_script "$ID" "ho_redact_file hide $H/.env.helper" "ho_info reveal /bin/cat $H/.env.helper"
  pty_run -- bash "$SCRIPT"
  assert_exit 0 "$RC" "$OUT"
  assert_contains "$(cat "$H/work/owner/$ID/RESULT.txt")" "check hide: PASS hiding 2 values from $H/.env.helper"
  no_secret_piece "$OUT" "the screen"
}

# A refused ho_redact_file ends the run: later steps could use the values it was to hide.
expect_redact_file_refused() { # <file> <reason>
  mk_script "$ID" "ho_redact_file hide $1" 'ho_check after /usr/bin/true'
  pty_run -- bash "$SCRIPT"
  assert_exit 1 "$RC"
  local result
  result="$(cat "$H/work/owner/$ID/RESULT.txt")"
  assert_contains "$result" "check hide: FAIL refused: $2"
  assert_contains "$result" "result: FAILED"
  assert_not_contains "$result" "check after" "no later step runs"
  no_secret_piece "$OUT" "the screen"
  no_secret_piece "$result" "RESULT.txt"
}

test_redact_file_refuses_unsafe_or_unusable_files() {
  mk_harness
  printf 'TOKEN=%s\n' "$SECRET" >"$H/plain.txt"
  expect_redact_file_refused "$H/plain.txt" "$H/plain.txt is not gitignored"
  expect_redact_file_refused "relative/.env" "the file must be an absolute path"
  expect_redact_file_refused "$H/.env.missing" "$H/.env.missing does not exist"
  ln -s "$H/plain.txt" "$H/.env.link"
  expect_redact_file_refused "$H/.env.link" "$H/.env.link is not a regular file"
  printf 'TOKEN=%s\nSHORT=abc\n' "$SECRET" >"$H/.env.short"
  expect_redact_file_refused "$H/.env.short" "line 2 of $H/.env.short holds a value that can't be hidden safely"
  printf '# no values\n' >"$H/.env.empty"
  expect_redact_file_refused "$H/.env.empty" "no values in $H/.env.empty"
  # A path through a symlinked folder could lead outside the checked location.
  mkdir "$H/real"
  ln -s "$H/real" "$H/linkdir"
  printf 'TOKEN=%s\n' "$SECRET" >"$H/real/.env.x"
  expect_redact_file_refused "$H/linkdir/.env.x" "$H/linkdir/.env.x is reached through a symbolic link"
}

run_tests
