#!/usr/bin/env bash
# Tests for .harness/lib/handoff.sh (spec 4.3, 10.3).
# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"
# shellcheck source=tests/lib/fixture.sh
source "$(dirname "$0")/../lib/fixture.sh"

ID=2026-01-01-test

test_refuses_without_a_terminal() {
  mk_harness
  mk_script "$ID" 'ho_check ok /usr/bin/true'
  local out rc
  out="$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT bash "$SCRIPT" </dev/null 2>&1)"
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
  sed -i '' "s/ho_begin \"$ID\"/ho_begin \"other-id\"/" "$SCRIPT"
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

run_tests
