#!/usr/bin/env bash
# Tests for `handoff verify` (spec 4.5, 10.3): passes a genuine run, fails on each of checks 1–8.
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

verify() {
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

run_tests
