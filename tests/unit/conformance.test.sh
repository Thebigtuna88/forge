#!/usr/bin/env bash
# Tests for .harness/bin/conformance (spec 5.5, 10.3), run against a throwaway harness built from
# the test-only hooks in tests/fixtures/hooks.
# shellcheck disable=SC2031 # each test sets and reads T_TMP inside its own subshell (assert.sh)
# shellcheck disable=SC2016 # setup scripts are single-quoted on purpose; they expand in the sandbox
# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"
# shellcheck source=tests/lib/hookfix.sh
source "$(dirname "$0")/../lib/hookfix.sh"

# mk_conf_harness [hook…]: a harness at $T_TMP/code/forge (H) with the runtime, conformance, an
# empty mode.json and the named fixture hooks (default: sample-gate), each registered in
# settings.json. sample-gate gets one deny and one allow case.
mk_conf_harness() {
  H="$T_TMP/code/forge"
  mkdir -p "$H/.harness/lib" "$H/.harness/bin" "$H/.claude/hooks" "$T_TMP/home"
  cp "$FORGE_SRC/.harness/lib/hookrt.sh" "$H/.harness/lib/"
  cp "$FORGE_SRC/.harness/bin/conformance" "$H/.harness/bin/"
  cp "$FORGE_SRC/.harness/deploy-targets.json" "$H/.harness/"
  printf '{"modes": {}}\n' >"$H/.harness/mode.json"
  local h
  [[ $# -gt 0 ]] || set -- sample-gate
  for h in "$@"; do
    cp "$FORGE_SRC/tests/fixtures/hooks/$h.sh" "$H/.claude/hooks/"
    chmod 755 "$H/.claude/hooks/$h.sh"
  done
  register "$@"
  case_json sample-gate deny push-main 'git push origin main'
  case_json sample-gate allow push-feature 'git push origin feature/FRG-2-a'
}

# register [hook…]: write settings.json registering exactly these hooks for Bash.
register() {
  local h list=()
  for h in "$@"; do
    list+=("$(jq -n --arg c "\"\$CLAUDE_PROJECT_DIR\"/.claude/hooks/$h.sh" '{type: "command", command: $c}')")
  done
  if [[ ${#list[@]} -eq 0 ]]; then
    printf '{"hooks": {}}\n' >"$H/.claude/settings.json"
  else
    printf '%s\n' "${list[@]}" | jq -s '{hooks: {PreToolUse: [{matcher: "Bash", hooks: .}]}}' >"$H/.claude/settings.json"
  fi
}

# case_json <hook> <deny|allow> <name> <command> [cwd]
case_json() {
  mkdir -p "$H/tests/conformance/$1/$2"
  jq -n --arg c "$4" --arg d "${5:-@ROOT@}" \
    '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' \
    >"$H/tests/conformance/$1/$2/$3.json"
}

conform() {
  OUT="$(cd "$H" && env HOME="$T_TMP/home" "$H/.harness/bin/conformance" 2>&1)"
  RC=$?
}

expect_fail() { # <message substring>
  conform
  assert_exit 1 "$RC" "conformance should fail"
  assert_contains "$OUT" "$1"
  assert_contains "$OUT" "conformance: FAIL"
}

test_passes_on_a_good_harness() {
  mk_conf_harness
  conform
  assert_exit 0 "$RC" "conformance should pass: $OUT"
  [[ "$OUT" =~ hook\ +\|\ mode\ +\|\ deny\ cases\ \|\ allow\ cases\ \|\ result ]] || _t_fail "no table header: $OUT"
  [[ "$OUT" =~ sample-gate\ +\|\ enforce\ +\|\ 1\ +\|\ 1\ +\|\ PASS ]] || _t_fail "row missing: $OUT"
  assert_contains "$OUT" "conformance: PASS"
}

test_passes_with_no_hooks() {
  mk_conf_harness
  rm -rf "${H:?}/.claude/hooks"/* "${H:?}/tests/conformance"
  register
  conform
  assert_exit 0 "$RC" "no hooks yet is fine: $OUT"
  assert_contains "$OUT" "0 hooks"
}

test_observe_mode_passes_when_it_logs() {
  mk_conf_harness
  printf '{"modes": {"sample-gate": "observe"}}\n' >"$H/.harness/mode.json"
  conform
  assert_exit 0 "$RC" "$OUT"
  [[ "$OUT" =~ sample-gate\ +\|\ observe\ +\| ]] || _t_fail "mode column: $OUT"
  [[ ! -e "$H/.harness/observed.log" ]] || _t_fail "conformance wrote to the live observed.log"
}

test_fails_on_unregistered_hook() {
  mk_conf_harness
  register
  expect_fail "sample-gate.sh is not registered"
}

test_fails_on_registered_hook_that_is_missing() {
  mk_conf_harness
  register sample-gate ghost
  expect_fail "ghost.sh is registered but missing"
}

test_fails_on_unrecognised_registration() {
  mk_conf_harness
  jq '.hooks.PreToolUse[0].hooks += [{type: "command", command: "bash -c true"}]' \
    "$H/.claude/settings.json" >"$T_TMP/s.json"
  mv "$T_TMP/s.json" "$H/.claude/settings.json"
  expect_fail "unrecognised hook command"
}

test_fails_on_malformed_settings() {
  mk_conf_harness
  printf '{"hooks": ' >"$H/.claude/settings.json"
  expect_fail "settings.json"
}

test_fails_on_non_executable_hook() {
  mk_conf_harness
  chmod 644 "$H/.claude/hooks/sample-gate.sh"
  expect_fail "sample-gate.sh is not executable"
}

test_fails_on_shellcheck_error() {
  mk_conf_harness
  printf '\nunused_variable_frg2=1\n[ $1 = x ] && echo x\n' >>"$H/.claude/hooks/sample-gate.sh"
  expect_fail "shellcheck"
}

test_fails_on_non_hook_file_in_hooks_folder() {
  mk_conf_harness
  printf 'notes\n' >"$H/.claude/hooks/README.txt"
  expect_fail "README.txt"
}

test_fails_when_a_deny_case_is_allowed() {
  mk_conf_harness
  case_json sample-gate deny push-feature 'git push origin feature/FRG-2-b'
  expect_fail "deny/push-feature.json: expected exit 2"
}

test_fails_when_an_allow_case_is_denied() {
  mk_conf_harness
  case_json sample-gate allow push-main-too 'git push origin main'
  expect_fail "allow/push-main-too.json: expected exit 0"
}

test_fails_when_observe_does_not_log() {
  mk_conf_harness sample-gate always-allow
  case_json always-allow deny anything 'git push origin main'
  case_json always-allow allow other 'ls'
  printf '{"modes": {"always-allow": "observe"}}\n' >"$H/.harness/mode.json"
  expect_fail "always-allow"
  assert_contains "$OUT" "no WOULD-DENY line"
}

test_fails_on_hook_that_fails_open_on_bad_mode_file() {
  mk_conf_harness sample-gate lenient-gate
  case_json lenient-gate deny main 'git push origin main'
  case_json lenient-gate allow other 'ls'
  expect_fail "lenient-gate"
  assert_contains "$OUT" "malformed mode.json"
  assert_contains "$OUT" "missing mode.json"
}

test_fails_on_hook_without_cases() {
  mk_conf_harness sample-gate cwd-gate
  expect_fail "cwd-gate: no deny cases"
}

test_fails_on_cases_for_an_unknown_hook() {
  mk_conf_harness
  case_json nobody deny x 'ls'
  expect_fail "tests/conformance/nobody has no hook"
}

test_placeholders_point_into_the_sandbox() {
  mk_conf_harness sample-gate cwd-gate
  case_json cwd-gate deny in-main 'ls' '@ROOT@'
  case_json cwd-gate allow in-worktree 'ls' '@WORKTREES@/FRG-2-x'
  conform
  assert_exit 0 "$RC" "$OUT"
}

test_setup_script_runs_in_the_sandbox() {
  mk_conf_harness
  case_json sample-gate allow alias-st 'git st'
  # Without the alias, `git st` is an unknown git command and is denied, so this allow case
  # passes only if the setup ran in the sandbox's main checkout.
  printf 'git -C "$ROOT" config alias.st status\n' >"$H/tests/conformance/sample-gate/allow/alias-st.setup.sh"
  conform
  assert_exit 0 "$RC" "$OUT"
  assert_eq "$(git -C "$H" config --get alias.st 2>/dev/null)" "" "setup must not touch the live harness"
}

test_fails_when_a_sandbox_copy_is_changed() {
  mk_conf_harness
  printf 'printf "\\n# tampered\\n" >>"$ROOT/.claude/hooks/sample-gate.sh"\n' \
    >"$H/tests/conformance/sample-gate/allow/push-feature.setup.sh"
  expect_fail "differs from the live file"
}

test_fails_when_hooks_are_disabled() {
  local f
  for f in home/.claude/settings.json home/.claude/settings.local.json \
    code/forge/.claude/settings.local.json code/forge/.claude/settings.json; do
    rm -rf "${T_TMP:?}/code" "${T_TMP:?}/home"
    mk_conf_harness
    mkdir -p "$(dirname "$T_TMP/$f")"
    if [[ -f "$T_TMP/$f" ]]; then
      jq '. + {disableAllHooks: true}' "$T_TMP/$f" >"$T_TMP/x.json"
      mv "$T_TMP/x.json" "$T_TMP/$f"
    else
      printf '{"disableAllHooks": true}\n' >"$T_TMP/$f"
    fi
    expect_fail "disableAllHooks"
  done
}

test_disable_all_hooks_false_is_fine() {
  mk_conf_harness
  mkdir -p "$T_TMP/home/.claude"
  printf '{"disableAllHooks": false}\n' >"$T_TMP/home/.claude/settings.json"
  conform
  assert_exit 0 "$RC" "$OUT"
}

test_fails_on_unreadable_user_settings() {
  mk_conf_harness
  mkdir -p "$T_TMP/home/.claude"
  printf '{"disableAllHooks": tru' >"$T_TMP/home/.claude/settings.json"
  expect_fail "cannot read"
}

run_tests
