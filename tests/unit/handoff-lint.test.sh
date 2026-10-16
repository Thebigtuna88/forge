#!/usr/bin/env bash
# Tests for `handoff new`, `handoff lint` and `handoff ready` (spec 4.1, 4.4, 10.3).
# shellcheck disable=SC2031 # each test sets and reads T_TMP inside its own subshell (assert.sh)
# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"
# shellcheck source=tests/lib/fixture.sh
source "$(dirname "$0")/../lib/fixture.sh"

# new_with <step lines…>: `handoff new demo`, then insert the lines before the final ho_end.
new_with() {
  mk_harness
  "$HANDOFF" new demo "Demo handoff" >/dev/null || _t_fail "handoff new failed"
  ID="$(date -u +%Y-%m-%d)-demo"
  DIR="$H/work/owner/$ID"
  local body
  body="$(sed '$d' "$DIR/OWNER-RUN.sh")"
  { printf '%s\n' "$body" "$@"; printf 'ho_end\n'; } >"$DIR/OWNER-RUN.sh"
}

lint() {
  LINT_OUT="$("$HANDOFF" lint "$DIR/OWNER-RUN.sh" 2>&1)"
  LINT_RC=$?
}

expect_rejected() { # <reason substring> <step lines…>
  local reason="$1"
  shift
  new_with 'ho_check ok /usr/bin/true' "$@"
  lint
  assert_exit 1 "$LINT_RC" "lint should reject: $reason"
  assert_contains "$LINT_OUT" "$reason"
}

test_new_creates_skeleton_and_meta() {
  mk_harness
  local out
  out="$("$HANDOFF" new demo "Demo handoff")"
  local id dir
  id="$(date -u +%Y-%m-%d)-demo"
  dir="$H/work/owner/$id"
  assert_contains "$out" "created $dir/OWNER-RUN.sh"
  assert_contains "$(cat "$dir/OWNER-RUN.sh")" "source \"$H/.harness/lib/handoff.sh\""
  assert_contains "$(cat "$dir/OWNER-RUN.sh")" "ho_begin \"$id\""
  assert_eq "$(jq -r .state "$dir/META.json")" draft
  assert_eq "$(jq -r .runtime "$dir/META.json")" "$H/.harness/lib/handoff.sh"
}

test_new_rejects_bad_slug_and_existing_id() {
  mk_harness
  "$HANDOFF" new "Bad Slug" "x" >/dev/null 2>&1 && _t_fail "accepted a bad slug"
  "$HANDOFF" new demo "x" >/dev/null || _t_fail "first new failed"
  "$HANDOFF" new demo "x" >/dev/null 2>&1 && _t_fail "overwrote an existing handoff"
  return 0
}

test_clean_script_passes() {
  new_with 'ho_check ok /usr/bin/true || ho_abort' \
    'ho_info ver /bin/echo v1' \
    'ho_confirm finished "Is it done?" || ho_abort' \
    "ho_secret_to_file key API_KEY $T_TMP/h/.env || ho_abort" \
    'ho_check repo gh repo edit --enable-squash-merge --delete-branch-on-merge'
  lint
  assert_exit 0 "$LINT_RC" "clean script"
  assert_contains "$LINT_OUT" "LINT OK"
}

test_rejects_skeleton_without_steps() {
  new_with
  lint
  assert_exit 1 "$LINT_RC"
  assert_contains "$LINT_OUT" "no steps"
}

test_rejects_fake_block_marker() { expect_rejected "HANDOFF-RESULT" 'echo "----- HANDOFF-RESULT BEGIN -----"'; }
test_rejects_fake_check_line() { expect_rejected "evidence line" 'echo "check ok: PASS fine"'; }
test_rejects_fake_result_line() { expect_rejected "result: OK" 'echo "result: OK"'; }
test_rejects_fake_sha_line() { expect_rejected "script-sha256" 'echo "script-sha256: 00"'; }
test_rejects_writing_result_file() { expect_rejected "RESULT.txt" 'cp /dev/null RESULT.txt'; }
test_rejects_writing_verified_file() { expect_rejected "VERIFIED.txt" 'touch VERIFIED.txt'; }
test_rejects_clipboard_use() { expect_rejected "pbcopy" 'echo hi | pbcopy'; }
test_rejects_agent_marker_tampering() { expect_rejected "CLAUDECODE" 'export CLAUDECODE='; }
test_rejects_eval() { expect_rejected "eval" 'eval "echo hi"'; }
test_rejects_exec() { expect_rejected "exec" 'exec >/dev/null'; }
test_rejects_trap() { expect_rejected "trap" 'trap "" EXIT'; }
test_rejects_unset() { expect_rejected "unset" 'unset HOME'; }
test_rejects_alias_after_semicolon() { expect_rejected "alias" 'true; alias ho_check=true'; }
test_rejects_function_redefinition() { expect_rejected "redefining" 'ho_check() { :; }'; }
test_rejects_function_keyword_redefinition() { expect_rejected "redefining" 'function ho_end { :; }'; }
test_rejects_internal_calls() { expect_rejected "internals" '_ho_record PASS x y'; }
test_rejects_runtime_variable_assignment() { expect_rejected "runtime variables" '_HO_FAILED=0'; }
test_rejects_xtrace() { expect_rejected "xtrace" 'set -x'; }
test_rejects_second_source() { expect_rejected "exactly one file" 'source /etc/profile'; }
test_rejects_dot_source() { expect_rejected "exactly one file" '. /etc/profile'; }
test_rejects_duplicate_names() { expect_rejected "duplicate step name" 'ho_check ok /usr/bin/true'; }
test_rejects_invalid_names() { expect_rejected "invalid step name" 'ho_check Bad_Name /usr/bin/true'; }

# Allowlist grammar (spec 4.4): anything that is not a plain helper step is rejected.
test_rejects_source_after_separator() { expect_rejected "unquoted ';'" 'true; source /dev/null'; }
test_rejects_redefining_a_dependency() { expect_rejected "unquoted '('" 'script() { return 0; }'; }
test_rejects_quoted_eval() { expect_rejected "only ho_check, ho_info" "'eval' 'ho_end() { exit 0; }'"; }
test_rejects_split_evidence_name() { expect_rejected "RESULT.txt" "ho_check w cp /dev/null /x/'RESULT''.''txt'"; }
# shellcheck disable=SC2016 # literal on purpose: lint must reject the expansion
test_rejects_command_substitution() { expect_rejected "inside double quotes" 'ho_check w /bin/echo "$(id)"'; }
# shellcheck disable=SC2016 # literal on purpose: lint must reject the expansion
test_rejects_variable_expansion() { expect_rejected "unquoted '\$'" 'ho_check w /bin/echo $HOME'; }
test_rejects_redirection() { expect_rejected "unquoted '>'" 'ho_check w /usr/bin/true > /tmp/out'; }
test_rejects_assignment_prefix() { expect_rejected "only ho_check, ho_info" 'FOO=1 ho_check w /usr/bin/true'; }
test_rejects_anything_after_abort() { expect_rejected "may only be followed by ho_abort" 'ho_check w /usr/bin/true || true'; }

test_rejects_reading_a_secret_file() {
  new_with "ho_secret_to_file key API_KEY $T_TMP/h/.env || ho_abort" "ho_info reveal /bin/cat $T_TMP/h/.env"
  lint
  assert_exit 1 "$LINT_RC"
  assert_contains "$LINT_OUT" "reads the secret file"
}

test_fails_closed_without_shellcheck() {
  new_with 'ho_check ok /usr/bin/true'
  LINT_OUT="$(env PATH=/usr/bin:/bin "$HANDOFF" lint "$DIR/OWNER-RUN.sh" 2>&1)"
  LINT_RC=$?
  assert_exit 1 "$LINT_RC"
  assert_contains "$LINT_OUT" "shellcheck is not installed"
}

test_rejects_reading_a_secret_file_before_it_is_written() {
  new_with "ho_info snapshot /bin/cat $T_TMP/h/.env" "ho_secret_to_file key API_KEY $T_TMP/h/.env || ho_abort"
  lint
  assert_exit 1 "$LINT_RC"
  assert_contains "$LINT_OUT" "reads the secret file"
}

# Bootstrap (spec 4.9): the handoff that installs shellcheck may be readied without it.
test_shellcheck_install_handoff_passes_without_shellcheck() {
  new_with 'ho_check install-shellcheck brew install shellcheck || ho_abort'
  LINT_OUT="$(env PATH=/usr/bin:/bin "$HANDOFF" lint "$DIR/OWNER-RUN.sh" 2>&1)"
  LINT_RC=$?
  assert_exit 0 "$LINT_RC" "$LINT_OUT"
}

test_ready_rejects_an_id_outside_the_owner_folder() {
  new_with 'ho_check ok /usr/bin/true'
  mkdir -p "$H/work/other"
  cp "$DIR/OWNER-RUN.sh" "$DIR/META.json" "$H/work/other/"
  local out
  out="$("$HANDOFF" ready ../other 2>&1)" && _t_fail "ready accepted ../other"
  assert_contains "$out" "invalid handoff id"
  assert_eq "$(jq -r .state "$H/work/other/META.json")" draft
}

test_ready_rejects_a_foreign_runtime() {
  new_with 'ho_check ok /usr/bin/true'
  jq '.runtime = "/tmp/evil/handoff.sh"' "$DIR/META.json" >"$T_TMP/m" && cat "$T_TMP/m" >"$DIR/META.json"
  local out
  out="$("$HANDOFF" ready "$ID" 2>&1)" && _t_fail "ready accepted a foreign runtime"
  assert_contains "$out" "names a runtime other than"
}

test_paths_with_spaces_are_quoted() {
  mkdir -p "$T_TMP/my code"
  T_TMP="$T_TMP/my code" new_with 'ho_check ok /usr/bin/true'
  local out
  out="$("$HANDOFF" ready "$ID")" || _t_fail "ready failed: $out"
  assert_contains "$out" "  bash $(printf '%q' "$DIR/OWNER-RUN.sh")"
  assert_contains "$out" 'my\ code'
  assert_contains "$(cat "$DIR/OWNER-RUN.sh")" 'my\ code'
}

test_rejects_wrong_runtime_path() {
  new_with 'ho_check ok /usr/bin/true'
  sed -i '' "s#^source \".*\"#source \"/tmp/fake/handoff.sh\"#" "$DIR/OWNER-RUN.sh"
  lint
  assert_exit 1 "$LINT_RC"
  assert_contains "$LINT_OUT" "must contain exactly: source"
}

test_rejects_steps_before_begin() {
  new_with 'ho_check ok /usr/bin/true'
  awk '/^ho_begin/ && !moved { print "ho_info early /usr/bin/true"; moved=1 } { print }' \
    "$DIR/OWNER-RUN.sh" >"$T_TMP/s" && cat "$T_TMP/s" >"$DIR/OWNER-RUN.sh"
  lint
  assert_exit 1 "$LINT_RC"
  assert_contains "$LINT_OUT" "first helper call must be"
}

test_rejects_code_after_end() {
  new_with 'ho_check ok /usr/bin/true'
  printf 'echo after\n' >>"$DIR/OWNER-RUN.sh"
  lint
  assert_exit 1 "$LINT_RC"
  assert_contains "$LINT_OUT" "last line must be: ho_end"
}

test_rejects_wrong_shebang() {
  new_with 'ho_check ok /usr/bin/true'
  sed -i '' '1s/.*/#!\/bin\/sh/' "$DIR/OWNER-RUN.sh"
  lint
  assert_exit 1 "$LINT_RC"
  assert_contains "$LINT_OUT" "line 1 must be"
}

test_ready_refuses_a_failing_script() {
  new_with 'eval true'
  "$HANDOFF" ready "$ID" >/dev/null 2>&1 && _t_fail "ready accepted a failing script"
  assert_eq "$(jq -r .state "$DIR/META.json")" draft
}

test_ready_freezes_and_prints_exactly_two_lines() {
  new_with 'ho_check ok /usr/bin/true'
  local out
  out="$("$HANDOFF" ready "$ID")" || _t_fail "ready failed: $out"
  assert_eq "$(jq -r .state "$DIR/META.json")" ready
  assert_eq "$(jq -r .script_sha256 "$DIR/META.json")" "$(shasum -a 256 "$DIR/OWNER-RUN.sh" | awk '{print $1}')"
  [[ -w "$DIR/OWNER-RUN.sh" ]] && _t_fail "OWNER-RUN.sh is still writable"
  assert_contains "$out" "  bash $DIR/OWNER-RUN.sh"
  assert_contains "$out" "  paste back the HANDOFF-RESULT block"
  "$HANDOFF" ready "$ID" >/dev/null 2>&1 && _t_fail "readied twice"
  return 0
}

run_tests
