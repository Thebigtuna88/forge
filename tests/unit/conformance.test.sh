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

# --- round 1 review fixes -----------------------------------------------------------------------

test_fails_when_registered_for_another_tool() {
  mk_conf_harness
  jq '.hooks.PreToolUse[0].matcher = "Read"' "$H/.claude/settings.json" >"$T_TMP/s.json"
  mv "$T_TMP/s.json" "$H/.claude/settings.json"
  expect_fail "not registered for PreToolUse/Bash"
}

test_fails_when_registered_for_another_event() {
  mk_conf_harness
  jq '{hooks: {PostToolUse: .hooks.PreToolUse}}' "$H/.claude/settings.json" >"$T_TMP/s.json"
  mv "$T_TMP/s.json" "$H/.claude/settings.json"
  expect_fail "not registered for PreToolUse/Bash"
}

test_fails_on_async_hook() {
  mk_conf_harness
  jq '.hooks.PreToolUse[0].hooks[0].async = true' "$H/.claude/settings.json" >"$T_TMP/s.json"
  mv "$T_TMP/s.json" "$H/.claude/settings.json"
  expect_fail "async"
}

test_setup_and_hooks_get_a_sandbox_home() {
  mk_conf_harness
  case_json sample-gate allow global-alias 'git frg2st'
  printf 'git config --global alias.frg2st status\n' >"$H/tests/conformance/sample-gate/allow/global-alias.setup.sh"
  conform
  assert_exit 0 "$RC" "the hook must see the sandbox's global alias: $OUT"
  [[ ! -e "$T_TMP/home/.gitconfig" ]] || _t_fail "setup wrote the caller's ~/.gitconfig"
}

test_setup_cannot_write_the_live_checkout() {
  mk_conf_harness
  printf 'printf " " >>"%s/.harness/mode.json"\n' "$H" >"$H/tests/conformance/sample-gate/allow/push-feature.setup.sh"
  expect_fail "setup failed"
  assert_eq "$(cat "$H/.harness/mode.json")" '{"modes": {}}' "live mode.json untouched"
}

test_fails_when_a_live_file_changes() {
  mk_conf_harness sample-gate toucher
  printf 'charter\n' >"$H/CLAUDE.md"
  case_json toucher deny main 'git push origin main'
  mkdir -p "$H/tests/conformance/toucher/allow"
  jq -n --arg f "$H/CLAUDE.md" '{hook_event_name: "PreToolUse", tool_name: "Bash",
    tool_input: {command: "ls", file_path: $f}, cwd: "@ROOT@"}' >"$H/tests/conformance/toucher/allow/touch.json"
  expect_fail "changed while conformance ran"
}


test_fails_when_observe_log_was_seeded() {
  mk_conf_harness sample-gate always-allow
  case_json always-allow deny anything 'git push origin main'
  case_json always-allow allow other 'ls'
  printf 'printf "2000-01-01T00:00:00Z always-allow WOULD-DENY seeded :: x\\n" >"$ROOT/.harness/observed.log"\n' \
    >"$H/tests/conformance/always-allow/deny/anything.setup.sh"
  printf '{"modes": {"always-allow": "observe"}}\n' >"$H/.harness/mode.json"
  expect_fail "setup failed"
  assert_contains "$OUT" "observed.log: Operation not permitted"
}

test_fails_on_hidden_or_stray_case_files() {
  mk_conf_harness
  case_json sample-gate deny .push-feature 'git push origin feature/FRG-2-c'
  expect_fail ".push-feature.json"
  rm "$H/tests/conformance/sample-gate/deny/.push-feature.json"
  printf 'x\n' >"$H/tests/conformance/sample-gate/deny/notes.txt"
  expect_fail "notes.txt"
}

test_fails_on_dot_dot_hook_file() {
  mk_conf_harness
  printf '#!/bin/bash\n' >"$H/.claude/hooks/..extra.sh"
  expect_fail "..extra.sh"
}

test_fails_on_symlinked_case() {
  mk_conf_harness
  mkdir -p "$H/tests/elsewhere"
  mv "$H/tests/conformance/sample-gate/deny/push-main.json" "$H/tests/elsewhere/"
  ln -s ../../../elsewhere/push-main.json "$H/tests/conformance/sample-gate/deny/push-main.json"
  expect_fail "symlink"
}

test_placeholders_survive_odd_temp_paths() {
  mk_conf_harness sample-gate cwd-gate
  case_json cwd-gate deny in-main 'ls' '@ROOT@'
  case_json cwd-gate allow in-worktree 'ls' '@WORKTREES@/FRG-2-x'
  mkdir -p "$T_TMP/a&b|c\\d"
  OUT="$(cd "$H" && env HOME="$T_TMP/home" TMPDIR="$T_TMP/a&b|c\\d" "$H/.harness/bin/conformance" 2>&1)"
  RC=$?
  assert_exit 0 "$RC" "$OUT"
}

test_mode_column_shows_every_part() {
  mk_conf_harness
  jq '.hooks.PreToolUse[0].matcher = "Bash|BashAlt"' "$H/.claude/settings.json" >"$T_TMP/s.json"
  mv "$T_TMP/s.json" "$H/.claude/settings.json"
  mkdir -p "$H/tests/conformance/sample-gate/deny"
  jq -n '{hook_event_name: "PreToolUse", tool_name: "BashAlt", forge_mode_key: "sample-gate:alt",
    tool_input: {command: "git push origin main"}, cwd: "@ROOT@"}' \
    >"$H/tests/conformance/sample-gate/deny/alt.json"
  printf '{"modes": {"sample-gate:alt": "observe"}}\n' >"$H/.harness/mode.json"
  conform
  assert_exit 0 "$RC" "$OUT"
  [[ "$OUT" =~ sample-gate\ +\|\ enforce/observe\ +\| ]] || _t_fail "mode column: $OUT"
}

test_observe_line_must_name_the_case_key() {
  mk_conf_harness
  jq '.hooks.PreToolUse[0].matcher = "Bash|BashAlt"' "$H/.claude/settings.json" >"$T_TMP/s.json"
  mv "$T_TMP/s.json" "$H/.claude/settings.json"
  # The hook really logs under sample-gate:alt; a case claiming another key must not pass.
  jq -n '{hook_event_name: "PreToolUse", tool_name: "BashAlt", forge_mode_key: "sample-gate:other",
    tool_input: {command: "git push origin main"}, cwd: "@ROOT@"}' \
    >"$H/tests/conformance/sample-gate/deny/alt.json"
  printf '{"modes": {"sample-gate:alt": "observe", "sample-gate:other": "observe"}}\n' >"$H/.harness/mode.json"
  expect_fail "no WOULD-DENY line"
}

test_fails_when_hooks_disabled_in_claude_config_dir() {
  mk_conf_harness
  mkdir -p "$T_TMP/profile"
  printf '{"disableAllHooks": true}\n' >"$T_TMP/profile/settings.json"
  OUT="$(cd "$H" && env HOME="$T_TMP/home" CLAUDE_CONFIG_DIR="$T_TMP/profile" "$H/.harness/bin/conformance" 2>&1)"
  RC=$?
  assert_exit 1 "$RC"
  assert_contains "$OUT" "disableAllHooks is set in $T_TMP/profile/settings.json"
}

test_fails_when_managed_hooks_only() {
  mk_conf_harness
  mkdir -p "$T_TMP/home/.claude"
  printf '{"allowManagedHooksOnly": true}\n' >"$T_TMP/home/.claude/settings.json"
  expect_fail "allowManagedHooksOnly"
}

test_fails_when_main_checkout_disables_hooks() {
  mk_conf_harness
  local main="$T_TMP/main" wt="$T_TMP/wt"
  git init -q -b dev "$main"
  git -C "$main" -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
  git -C "$main" worktree add -q -b feature/FRG-2-t "$wt"
  cp -R "$H/." "$wt/"
  H="$wt"
  mkdir -p "$main/.claude"
  printf '{"disableAllHooks": true}\n' >"$main/.claude/settings.local.json"
  expect_fail "disableAllHooks is set in $main/.claude/settings.local.json"
}

test_registration_without_matcher_covers_every_tool() {
  mk_conf_harness
  jq 'del(.hooks.PreToolUse[0].matcher)' "$H/.claude/settings.json" >"$T_TMP/s.json"
  mv "$T_TMP/s.json" "$H/.claude/settings.json"
  conform
  assert_exit 0 "$RC" "$OUT"
}

test_fails_on_tool_case_without_tool_name() {
  mk_conf_harness
  jq 'del(.tool_name)' "$H/tests/conformance/sample-gate/deny/push-main.json" >"$T_TMP/c.json"
  mv "$T_TMP/c.json" "$H/tests/conformance/sample-gate/deny/push-main.json"
  expect_fail "tool_name"
}

test_fails_on_symlinked_hooks_folder() {
  mk_conf_harness
  mv "$H/.claude/hooks" "$T_TMP/elsewhere-hooks"
  ln -s "$T_TMP/elsewhere-hooks" "$H/.claude/hooks"
  expect_fail "symlink"
}

test_fails_on_symlinked_runtime() {
  mk_conf_harness
  mv "$H/.harness/lib/hookrt.sh" "$T_TMP/hookrt.sh"
  ln -s "$T_TMP/hookrt.sh" "$H/.harness/lib/hookrt.sh"
  expect_fail "symlink"
}

test_fails_on_hook_without_privileged_shebang() {
  mk_conf_harness
  sed -i '' '1s|.*|#!/usr/bin/env bash|' "$H/.claude/hooks/sample-gate.sh"
  expect_fail "#!/bin/bash -p"
}

test_setup_cannot_undo_a_bad_mode_file() {
  mk_conf_harness sample-gate lenient-gate
  case_json lenient-gate deny main 'git push origin main'
  case_json lenient-gate allow other 'ls'
  printf 'printf %s >"$ROOT/.harness/mode.json"\n' "'{\"modes\": {}}'" \
    >"$H/tests/conformance/lenient-gate/deny/main.setup.sh"
  expect_fail "setup failed"
  assert_contains "$OUT" "mode.json: Operation not permitted"
}

test_setup_cannot_swap_the_hook() {
  mk_conf_harness sample-gate always-allow
  case_json always-allow deny anything 'git push origin main'
  case_json always-allow allow other 'ls'
  cat >"$H/tests/conformance/always-allow/deny/anything.setup.sh" <<'EOF'
cp "$ROOT/.claude/hooks/always-allow.sh" "$TMP/original"
printf '#!/bin/bash -p\ncp "%s" "%s"\nexit 2\n' "$TMP/original" "$ROOT/.claude/hooks/always-allow.sh" \
  >"$ROOT/.claude/hooks/always-allow.sh"
EOF
  expect_fail "setup failed"
  assert_contains "$OUT" "always-allow.sh: Operation not permitted"
}

# touch_case <path>: a toucher allow case whose hook appends to <path> (inside the sandbox).
touch_case() {
  mkdir -p "$H/tests/conformance/toucher/allow"
  jq -n --arg f "$1" '{hook_event_name: "PreToolUse", tool_name: "Bash",
    tool_input: {command: "ls", file_path: $f}, cwd: "@ROOT@"}' >"$H/tests/conformance/toucher/allow/touch.json"
}

test_fails_when_a_hook_changes_its_sandbox_copy() {
  mk_conf_harness sample-gate toucher
  case_json toucher deny main 'git push origin main'
  touch_case '@ROOT@/.claude/hooks/toucher.sh'
  expect_fail "toucher allow/touch.json: the sandbox copy of .claude/hooks/toucher.sh differs from the live file"
}

test_bad_mode_runs_check_the_mode_variant_survives() {
  mk_conf_harness sample-gate toucher
  mkdir -p "$H/tests/conformance/toucher/deny"
  jq -n '{hook_event_name: "PreToolUse", tool_name: "Bash",
    tool_input: {command: "git push origin main", file_path: "@ROOT@/.harness/mode.json"}, cwd: "@ROOT@"}' \
    >"$H/tests/conformance/toucher/deny/main.json"
  case_json toucher allow other 'ls'
  expect_fail "(missing mode.json): the sandbox copy of .harness/mode.json (should be missing)"
  assert_contains "$OUT" "(malformed mode.json): the sandbox copy of .harness/mode.json (the malformed variant)"
}

test_fails_on_deny_case_with_invalid_input() {
  mk_conf_harness
  jq '.tool_input.command = 42' "$H/tests/conformance/sample-gate/deny/push-main.json" >"$T_TMP/c.json"
  mv "$T_TMP/c.json" "$H/tests/conformance/sample-gate/deny/push-main.json"
  expect_fail "not valid hook input"
}

test_setup_cannot_redirect_the_runner_files() {
  # probe allows everything it can read; an unreadable (empty) input would make it deny.
  mk_conf_harness sample-gate probe
  case_json probe deny anything 'git push origin main'
  case_json probe allow other 'ls'
  printf 'ln -s /dev/null "$TMP/input.json"\nln -s /dev/null "$TMP/r/input.json" 2>/dev/null || true\n' \
    >"$H/tests/conformance/probe/deny/anything.setup.sh"
  expect_fail "probe deny/anything.json: expected exit 2 (enforce), got 0"
}

test_setup_cannot_symlink_the_hooks() {
  mk_conf_harness
  cat >"$H/tests/conformance/sample-gate/allow/push-feature.setup.sh" <<'EOF'
mkdir -p "$TMP/fake/.claude"
cp -R "$ROOT/.claude/hooks" "$TMP/fake/.claude/hooks"
rm -rf "$ROOT/.claude/hooks"
ln -s "$TMP/fake/.claude/hooks" "$ROOT/.claude/hooks"
EOF
  expect_fail "setup failed"
  assert_contains "$OUT" "Operation not permitted"
}

test_bash_env_cannot_fake_a_pass() {
  mk_conf_harness
  register
  printf 'echo "conformance: PASS"\nexit 0\n' >"$T_TMP/benv.sh"
  OUT="$(cd "$H" && env HOME="$T_TMP/home" BASH_ENV="$T_TMP/benv.sh" "$H/.harness/bin/conformance" 2>&1)"
  RC=$?
  assert_exit 1 "$RC" "$OUT"
}

test_fails_on_deny_case_with_nul_in_any_field() {
  mk_conf_harness sample-gate probe
  case_json probe allow other 'ls'
  mkdir -p "$H/tests/conformance/probe/deny"
  jq -n '{hook_event_name: "PreToolUse", tool_name: "Bash", cwd: "\u0000",
    tool_input: {command: "git push origin main"}}' >"$H/tests/conformance/probe/deny/nul.json"
  expect_fail "not valid hook input"
}

test_perl_options_cannot_hide_a_live_change() {
  mk_conf_harness sample-gate toucher
  printf 'charter\n' >"$H/CLAUDE.md"
  case_json toucher deny main 'git push origin main'
  mkdir -p "$H/tests/conformance/toucher/allow"
  jq -n --arg f "$H/CLAUDE.md" '{hook_event_name: "PreToolUse", tool_name: "Bash",
    tool_input: {command: "ls", file_path: $f}, cwd: "@ROOT@"}' >"$H/tests/conformance/toucher/allow/touch.json"
  OUT="$(cd "$H" && env HOME="$T_TMP/home" PERL5OPT='-MConfig;print("same  -\n");exit(0)' \
    "$H/.harness/bin/conformance" 2>&1)"
  RC=$?
  assert_exit 1 "$RC"
  assert_contains "$OUT" "changed while conformance ran"
}

test_setup_cannot_write_the_copies_at_all() {
  # The sandbox refuses the write itself (so a background child can't do it later either);
  # the case then runs against the untouched copy and passes.
  mk_conf_harness
  printf 'printf "\\n# x\\n" >>"$ROOT/.claude/hooks/sample-gate.sh" 2>/dev/null\nexit 0\n' \
    >"$H/tests/conformance/sample-gate/allow/push-feature.setup.sh"
  conform
  assert_exit 0 "$RC" "$OUT"
  assert_not_contains "$OUT" "setup changed"
}

test_setup_cannot_signal_outside_processes() {
  mk_conf_harness
  printf 'if kill -WINCH "$PPID" 2>/dev/null; then echo "could signal its parent" >&2; exit 1; fi\n' \
    >"$H/tests/conformance/sample-gate/allow/push-feature.setup.sh"
  conform
  assert_exit 0 "$RC" "$OUT"
}

test_fails_when_deny_comes_from_a_crash() {
  mk_conf_harness sample-gate crashy-gate
  case_json crashy-gate deny main 'git push origin main'
  case_json crashy-gate allow other 'ls'
  expect_fail "crashy-gate deny/main.json: exit 2 without a \"BLOCKED by FORGE hook crashy-gate:\" decision"
}

test_case_can_name_the_expected_reason() {
  mk_conf_harness
  jq '. + {forge_reason: "push to main"}' "$H/tests/conformance/sample-gate/deny/push-main.json" >"$T_TMP/c.json"
  mv "$T_TMP/c.json" "$H/tests/conformance/sample-gate/deny/push-main.json"
  conform
  assert_exit 0 "$RC" "$OUT"
  jq '.forge_reason = "some other reason"' "$H/tests/conformance/sample-gate/deny/push-main.json" >"$T_TMP/c.json"
  mv "$T_TMP/c.json" "$H/tests/conformance/sample-gate/deny/push-main.json"
  expect_fail "reason \"some other reason\""
}

test_fails_on_masked_command_substitution_in_a_hook() {
  mk_conf_harness sample-gate masked-gate
  case_json masked-gate deny main 'git push origin main'
  case_json masked-gate allow other 'ls'
  expect_fail "masked-gate.sh line"
  assert_contains "$OUT" "plain assignment"
}

test_fails_on_two_or_nested_substitutions_in_a_hook() {
  local line
  for line in 'x="$(true)" y="$(true)"' 'x="$(printf %s "$(printf %s "$HR_CMD")")"'; do
    rm -rf "${T_TMP:?}/code" "${T_TMP:?}/home"
    mk_conf_harness
    printf '%s\n' "$line" >>"$H/.claude/hooks/sample-gate.sh"
    expect_fail "sample-gate.sh line $(wc -l <"$H/.claude/hooks/sample-gate.sh" | tr -d ' '): a command substitution"
  done
}

test_standard_header_passes_the_source_check() {
  mk_conf_harness
  conform
  assert_not_contains "$OUT" "a command substitution may only"
}

test_observe_reason_is_read_from_the_reason_field() {
  # sample-gate logs "push to main :: git push origin main"; "origin" is only in the command part.
  mk_conf_harness
  printf '{"modes": {"sample-gate": "observe"}}\n' >"$H/.harness/mode.json"
  jq '. + {forge_reason: "origin"}' "$H/tests/conformance/sample-gate/deny/push-main.json" >"$T_TMP/c.json"
  mv "$T_TMP/c.json" "$H/tests/conformance/sample-gate/deny/push-main.json"
  expect_fail "the WOULD-DENY line lacks the reason"
}

test_fails_on_function_or_group_in_a_hook() {
  local body
  for body in $'check() {\n  x="$(printf %s "$HR_CMD")"\n}' 'function check { true; }' \
    $'{\n  x="$(printf %s "$HR_CMD")"\n} || true' $'true && (\n  x="$(printf %s "$HR_CMD")"\n)'; do
    rm -rf "${T_TMP:?}/code" "${T_TMP:?}/home"
    mk_conf_harness
    printf '%s\n' "$body" >>"$H/.claude/hooks/sample-gate.sh"
    expect_fail "may not define functions or open"
  done
}

test_fails_on_control_characters_in_settings() {
  mk_conf_harness
  jq '{hooks: {("PreToolUse\u001fBash\u001ffalse\u001f\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/sample-gate.sh\nBogus"):
    .hooks.PreToolUse}}' "$H/.claude/settings.json" >"$T_TMP/s.json"
  mv "$T_TMP/s.json" "$H/.claude/settings.json"
  expect_fail "settings.json is missing or malformed"
}

test_fails_on_group_hidden_behind_a_comment() {
  local body
  for body in $'if { # conditional group\nx="$(printf %s "$HR_CMD")"\n:; }; then :; fi' \
    $'if { # conditional group\nx="$(printf %s "$HR_CMD")"\ntrue; }; then\n  :\nfi' \
    $'while ( # subshell\nx="$(printf %s "$HR_CMD")"\nfalse ); do :; done'; do
    rm -rf "${T_TMP:?}/code" "${T_TMP:?}/home"
    mk_conf_harness
    printf '%s\n' "$body" >>"$H/.claude/hooks/sample-gate.sh"
    expect_fail "may not define functions or open"
  done
}

test_fails_on_substitution_inside_a_condition() {
  local body
  for body in $'if\nx="$(printf %s "$HR_CMD")"\nthen\n  :\nfi' $'while\nx="$(printf %s "$HR_CMD")"\ndo\n  break\ndone' \
    $'true &&\nx="$(printf %s "$HR_CMD")"' $'false ||\nx="$(printf %s "$HR_CMD")"' \
    $'printf x | \\\nx="$(printf %s "$HR_CMD")"'; do
    rm -rf "${T_TMP:?}/code" "${T_TMP:?}/home"
    mk_conf_harness
    printf '%s\n' "$body" >>"$H/.claude/hooks/sample-gate.sh"
    expect_fail "part of a condition"
  done
}

test_quoted_punctuation_is_not_a_group() {
  mk_conf_harness
  # Appended after hr_allow (never runs): only the source check reads these lines.
  printf '%s\n' "printf '%s\\n' '('" "echo '{'" 'echo "}" ")"' >>"$H/.claude/hooks/sample-gate.sh"
  conform
  assert_not_contains "$OUT" "may not define functions or open"
}

run_tests
