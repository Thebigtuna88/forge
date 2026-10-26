#!/usr/bin/env bash
# Tests for `handoff verify` (spec 4.5, 10.3): passes a genuine run, fails on each of checks 1–9.
# shellcheck disable=SC2031 # each test sets and reads T_TMP inside its own subshell (assert.sh)
# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"
# shellcheck source=tests/lib/fixture.sh
source "$(dirname "$0")/../lib/fixture.sh"

# genuine_run [answer for the confirm step]: new → steps → ready → owner run in a pty.
genuine_run() {
  local answer="${1:-y}"
  mk_harness
  "$HANDOFF" new demo "Demo handoff" >/dev/null
  ID="$(date -u +%Y-%m-%d)-demo"
  DIR="$H/work/owner/$ID"
  local body
  body="$(sed '$d' "$DIR/OWNER-RUN.sh")"
  {
    printf '%s\n' "$body"
    printf '%s\n' 'ho_check ok /usr/bin/true' 'ho_info ver /bin/echo v1.2.3' 'ho_confirm finished "Done?"'
    printf 'ho_end\n'
  } >"$DIR/OWNER-RUN.sh"
  "$HANDOFF" ready "$ID" >/dev/null || _t_fail "ready failed"
  pty_run --answer "$answer" -- bash "$DIR/OWNER-RUN.sh"
  PASTE="$DIR/PASTED-20260101T000000Z.txt"
}

paste_result() { cp "$DIR/RESULT.txt" "$PASTE"; }

# verify <file>: record the paste as capture-owner-paste would (FRG-5), then verify it.
verify() {
  if [[ -f "$1" && ! -L "$1" && "$1" == "$H"/work/owner/* ]]; then record_paste "$1"; fi
  verify_unrecorded "$1"
}

verify_unrecorded() {
  VERIFY_OUT="$("$HANDOFF" verify "$1" 2>&1)"
  VERIFY_RC=$?
}

expect_fail() { # <check number> <file>
  verify "$2"
  assert_exit 1 "$VERIFY_RC" "verify should fail check $1"
  assert_contains "$VERIFY_OUT" "$1: "
  [[ ! -f "$DIR/VERIFIED.txt" ]] || _t_fail "VERIFIED.txt written on failure"
}

test_genuine_paste_verifies() {
  genuine_run
  paste_result
  verify "$PASTE"
  assert_exit 0 "$VERIFY_RC" "$VERIFY_OUT"
  assert_contains "$VERIFY_OUT" "VERIFIED: $ID"
  assert_contains "$(cat "$DIR/VERIFIED.txt")" "result: OK"
  assert_contains "$(cat "$DIR/VERIFIED.txt")" "pasted-file: PASTED-20260101T000000Z.txt"
  assert_eq "$(jq -r .state "$DIR/META.json")" verified
}

# ho_redact_file (FRG-14) is a declared step that must PASS, like ho_check.
test_redact_file_step_verifies() {
  mk_harness
  "$HANDOFF" new demo "Demo handoff" >/dev/null
  ID="$(date -u +%Y-%m-%d)-demo"
  DIR="$H/work/owner/$ID"
  printf 'TOKEN=%s\n' '%@+%@@%+' >"$H/.env.helper"
  local body
  body="$(sed '$d' "$DIR/OWNER-RUN.sh")"
  { printf '%s\n' "$body" "ho_redact_file hide $H/.env.helper || ho_abort" 'ho_check ok /usr/bin/true'; printf 'ho_end\n'; } >"$DIR/OWNER-RUN.sh"
  "$HANDOFF" ready "$ID" >/dev/null || _t_fail "ready failed"
  pty_run -- bash "$DIR/OWNER-RUN.sh"
  PASTE="$DIR/PASTED-20260101T000000Z.txt"
  paste_result
  verify "$PASTE"
  assert_exit 0 "$VERIFY_RC" "$VERIFY_OUT"
  assert_contains "$(cat "$DIR/VERIFIED.txt")" "check hide: PASS hiding 1 value from $H/.env.helper"
}

test_failed_redact_file_step_does_not_verify() {
  mk_harness
  "$HANDOFF" new demo "Demo handoff" >/dev/null
  ID="$(date -u +%Y-%m-%d)-demo"
  DIR="$H/work/owner/$ID"
  local body
  body="$(sed '$d' "$DIR/OWNER-RUN.sh")"
  { printf '%s\n' "$body" "ho_redact_file hide $H/.env.missing" 'ho_check ok /usr/bin/true'; printf 'ho_end\n'; } >"$DIR/OWNER-RUN.sh"
  "$HANDOFF" ready "$ID" >/dev/null || _t_fail "ready failed"
  pty_run -- bash "$DIR/OWNER-RUN.sh"
  PASTE="$DIR/PASTED-20260101T000000Z.txt"
  paste_result
  expect_fail 6 "$PASTE"
  assert_contains "$VERIFY_OUT" "step 'hide' did not pass"
}

test_paste_with_surrounding_text_crlf_and_indent_verifies() {
  genuine_run
  { printf 'here you go:\r\n'; sed 's/^/   /; s/$/\r/' "$DIR/RESULT.txt"; printf 'thanks\n'; } >"$PASTE"
  verify "$PASTE"
  assert_exit 0 "$VERIFY_RC" "$VERIFY_OUT"
}

test_second_verify_is_refused() {
  genuine_run
  paste_result
  verify "$PASTE"
  verify "$PASTE"
  assert_exit 1 "$VERIFY_RC"
  assert_contains "$VERIFY_OUT" "already verified"
}

test_check1_no_block() {
  genuine_run
  printf 'I ran it and it worked\n' >"$PASTE"
  expect_fail 1 "$PASTE"
}

test_check1_two_blocks() {
  genuine_run
  cat "$DIR/RESULT.txt" "$DIR/RESULT.txt" >"$PASTE"
  expect_fail 1 "$PASTE"
}

test_check2_unknown_id() {
  genuine_run
  mkdir -p "$H/work/owner/2026-01-01-nothing"
  cp "$DIR/RESULT.txt" "$H/work/owner/2026-01-01-nothing/PASTED-1.txt"
  expect_fail 2 "$H/work/owner/2026-01-01-nothing/PASTED-1.txt"
}

test_check2_never_readied() {
  genuine_run
  paste_result
  jq '.state = "draft"' "$DIR/META.json" >"$T_TMP/m" && cat "$T_TMP/m" >"$DIR/META.json"
  expect_fail 2 "$PASTE"
}

test_check3_script_changed_after_run() {
  genuine_run
  paste_result
  chmod u+w "$DIR/OWNER-RUN.sh"
  printf '# edited later\n' >>"$DIR/OWNER-RUN.sh"
  expect_fail 3 "$PASTE"
}

test_check4_runtime_changed_after_run() {
  genuine_run
  paste_result
  printf '# runtime updated\n' >>"$H/.harness/lib/handoff.sh"
  expect_fail 4 "$PASTE"
}

# The runtime pins its redaction filter (FRG-14), so a changed or missing filter fails check 4 too.
test_check4_redaction_filter_changed_after_run() {
  genuine_run
  paste_result
  printf '# filter updated\n' >>"$H/.harness/lib/handoff_redact.py"
  expect_fail 4 "$PASTE"
  assert_contains "$VERIFY_OUT" "redaction filter"
}

# Verify hashes the filter with /usr/bin/shasum in an empty environment, so a shasum on PATH that
# answers the pin can't hide a changed filter.
test_check4_redaction_filter_check_ignores_a_lying_shasum() {
  genuine_run
  paste_result
  local pin
  pin="$(sed -n 's/^HO_REDACT_SHA256=//p' "$H/.harness/lib/handoff.sh")"
  mkdir "$T_TMP/fake"
  # shellcheck disable=SC2016 # the fake's own $# and $@
  printf '#!/bin/bash\nif [ "$#" -ge 3 ]; then exec /usr/bin/shasum "$@"; fi\ncat >/dev/null\necho "%s  -"\n' "$pin" \
    >"$T_TMP/fake/shasum"
  chmod +x "$T_TMP/fake/shasum"
  printf '# filter updated\n' >>"$H/.harness/lib/handoff_redact.py"
  record_paste "$PASTE"
  VERIFY_OUT="$(env PATH="$T_TMP/fake:$PATH" "$HANDOFF" verify "$PASTE" 2>&1)"
  VERIFY_RC=$?
  assert_exit 1 "$VERIFY_RC" "verify should fail check 4"
  assert_contains "$VERIFY_OUT" "redaction filter"
}

test_check4_redaction_filter_missing_after_run() {
  genuine_run
  paste_result
  rm "$H/.harness/lib/handoff_redact.py"
  expect_fail 4 "$PASTE"
  assert_contains "$VERIFY_OUT" "redaction filter"
}

test_check5_declared_step_missing() {
  genuine_run
  grep -v '^check ver:' "$DIR/RESULT.txt" >"$PASTE"
  expect_fail 5 "$PASTE"
}

test_check5_undeclared_step_present() {
  genuine_run
  awk '/^result:/ { print "check extra: PASS injected" } { print }' "$DIR/RESULT.txt" >"$PASTE"
  expect_fail 5 "$PASTE"
}

test_check6_failed_step() {
  genuine_run n
  paste_result
  expect_fail 6 "$PASTE"
  assert_contains "$VERIFY_OUT" "6: step 'finished' did not pass"
}

test_check6_info_relabelled_as_pass() {
  genuine_run
  sed 's/^check ver: INFO/check ver: PASS/' "$DIR/RESULT.txt" >"$PASTE"
  expect_fail 6 "$PASTE"
}

test_check3_run_older_than_ready() {
  genuine_run
  paste_result
  jq '.readied = "2999-01-01T00:00:00Z"' "$DIR/META.json" >"$T_TMP/m" && cat "$T_TMP/m" >"$DIR/META.json"
  expect_fail 3 "$PASTE"
  assert_contains "$VERIFY_OUT" "older than handoff ready"
}

test_check4_runtime_path_in_meta_replaced() {
  genuine_run
  paste_result
  mkdir -p "$T_TMP/evil"
  cp "$H/.harness/lib/handoff.sh" "$T_TMP/evil/handoff.sh"
  jq --arg r "$T_TMP/evil/handoff.sh" '.runtime = $r' "$DIR/META.json" >"$T_TMP/m" && cat "$T_TMP/m" >"$DIR/META.json"
  expect_fail 4 "$PASTE"
  assert_contains "$VERIFY_OUT" "META.json names runtime"
}

test_check8_symlink_to_result_is_rejected() {
  genuine_run
  ln -s RESULT.txt "$PASTE"
  expect_fail 8 "$PASTE"
  assert_contains "$VERIFY_OUT" "not a symlink or hard link"
}

test_check8_hard_link_to_result_is_rejected() {
  genuine_run
  ln "$DIR/RESULT.txt" "$PASTE"
  expect_fail 8 "$PASTE"
  assert_contains "$VERIFY_OUT" "not a symlink or hard link"
}

# VERIFIED.txt is the record: a failed META.json update is only a warning, and never leaves
# the handoff in a state where it is marked verified without VERIFIED.txt.
test_verified_txt_is_the_record_if_meta_update_fails() {
  genuine_run
  paste_result
  mkdir "$T_TMP/bin"
  # shellcheck disable=SC2016 # the stub's own $*
  printf '#!/bin/bash\ncase "$*" in *verified*) exit 1 ;; esac\nexec /usr/bin/jq "$@"\n' >"$T_TMP/bin/jq"
  chmod +x "$T_TMP/bin/jq"
  record_paste "$PASTE"
  VERIFY_OUT="$(env PATH="$T_TMP/bin:$PATH" "$HANDOFF" verify "$PASTE" 2>&1)"
  VERIFY_RC=$?
  assert_exit 0 "$VERIFY_RC" "$VERIFY_OUT"
  assert_contains "$VERIFY_OUT" "VERIFIED.txt is the record"
  assert_contains "$(cat "$DIR/VERIFIED.txt")" "result: OK"
  verify "$PASTE"
  assert_contains "$VERIFY_OUT" "already verified"
  local before
  before="$(cat "$DIR/RESULT.txt")"
  pty_run --answer y -- bash "$DIR/OWNER-RUN.sh"
  assert_exit 3 "$RC" "a verified handoff ran again"
  assert_eq "$(cat "$DIR/RESULT.txt")" "$before" "RESULT.txt was overwritten"
}

test_check2_verified_txt_directory_is_refused() {
  genuine_run
  paste_result
  mkdir "$DIR/VERIFIED.txt"
  expect_fail 2 "$PASTE"
  assert_eq "$(jq -r .state "$DIR/META.json")" ready
}

test_check7_paste_edited() {
  genuine_run
  sed 's/v1.2.3/v9.9.9/' "$DIR/RESULT.txt" >"$PASTE"
  expect_fail 7 "$PASTE"
}

test_check7_result_file_missing() {
  genuine_run
  paste_result
  rm "$DIR/RESULT.txt"
  expect_fail 7 "$PASTE"
}

test_check8_result_txt_is_never_accepted() {
  genuine_run
  expect_fail 8 "$DIR/RESULT.txt"
}

test_check8_paste_outside_owner_folder() {
  genuine_run
  mkdir -p "$T_TMP/elsewhere/$ID"
  cp "$DIR/RESULT.txt" "$T_TMP/elsewhere/$ID/PASTED-1.txt"
  verify "$T_TMP/elsewhere/$ID/PASTED-1.txt"
  assert_exit 1 "$VERIFY_RC"
  [[ ! -f "$DIR/VERIFIED.txt" ]] || _t_fail "VERIFIED.txt written"
}

# 9. From FRG-5 on, a paste counts only if capture-owner-paste saved it: pastes.log names the file
# with its sha256 as it is now.
expect_fail_unrecorded() { # <file>
  verify_unrecorded "$1"
  assert_exit 1 "$VERIFY_RC" "verify should fail check 9"
  assert_contains "$VERIFY_OUT" "9: "
  [[ ! -f "$DIR/VERIFIED.txt" ]] || _t_fail "VERIFIED.txt written on failure"
}

test_check9_paste_the_hook_did_not_save() {
  genuine_run
  paste_result
  expect_fail_unrecorded "$PASTE"
  assert_contains "$VERIFY_OUT" "capture-owner-paste"
}

test_check9_paste_changed_after_it_was_saved() {
  genuine_run
  paste_result
  record_paste "$PASTE"
  printf '\n' >>"$PASTE"
  expect_fail_unrecorded "$PASTE"
}

test_check9_record_names_another_file() {
  genuine_run
  paste_result
  cp "$PASTE" "$DIR/PASTED-20260101T000001Z.txt"
  record_paste "$DIR/PASTED-20260101T000001Z.txt"
  expect_fail_unrecorded "$PASTE"
}

test_check9_linked_record_is_refused() {
  genuine_run
  paste_result
  record_paste "$PASTE"
  mv "$H/.harness/state/pastes.log" "$T_TMP/pastes.log"
  ln -s "$T_TMP/pastes.log" "$H/.harness/state/pastes.log"
  expect_fail_unrecorded "$PASTE"
}

run_tests
