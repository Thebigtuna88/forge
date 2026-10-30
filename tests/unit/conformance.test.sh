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

# register [hook…]: write settings.json registering exactly these hooks for Bash, each blocking
# on failure with a 120-second timeout.
register() {
  local h list=()
  for h in "$@"; do
    list+=("$(jq -n --arg c "\"\$CLAUDE_PROJECT_DIR\"/.claude/hooks/$h.sh" \
      '{type: "command", command: $c, onFailure: "block", timeout: 120}')")
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

# fake_claude <output of claude --version>: a stand-in claude at $T_TMP/bin/claude.
fake_claude() {
  mkdir -p "$T_TMP/bin"
  printf '#!/bin/bash\nprintf "%%s\\n" %q\n' "$1" >"$T_TMP/bin/claude"
  chmod 755 "$T_TMP/bin/claude"
}

# conform [VAR=value…]: run conformance in H. Claude Code's version comes from a fake claude
# (2.1.302 unless the test made another), so the result doesn't depend on this machine. CI and
# GITHUB_ACTIONS are cleared (a run on GitHub Actions would otherwise skip the version check);
# a test sets them explicitly when it needs them.
conform() {
  [[ -x "$T_TMP/bin/claude" ]] || fake_claude "2.1.302 (Claude Code)"
  OUT="$(cd "$H" && env -u CI -u GITHUB_ACTIONS HOME="$T_TMP/home" \
    FORGE_TEST_CLAUDE="$T_TMP/bin/claude" "$@" "$H/.harness/bin/conformance" 2>&1)"
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

# conform_while_editing <file>: run conformance while this test appends to a live file mid-run
# (a slow setup keeps conformance busy). Nothing a case does can reach the live checkout now.
conform_while_editing() {
  local file="$1"
  shift
  printf 'sleep 3\n' >"$H/tests/conformance/sample-gate/allow/push-feature.setup.sh"
  (sleep 1 && printf 'edited\n' >>"$file") &
  OUT="$(cd "$H" && env HOME="$T_TMP/home" "$@" "$H/.harness/bin/conformance" 2>&1)"
  RC=$?
  wait
}

test_fails_when_a_live_file_changes() {
  mk_conf_harness
  printf 'charter\n' >"$H/CLAUDE.md"
  conform_while_editing "$H/CLAUDE.md"
  assert_exit 1 "$RC" "$OUT"
  assert_contains "$OUT" "changed while conformance ran"
}

test_hook_cannot_write_the_live_checkout() {
  mk_conf_harness sample-gate toucher
  printf 'charter\n' >"$H/CLAUDE.md"
  case_json toucher deny main 'git push origin main'
  mkdir -p "$H/tests/conformance/toucher/allow"
  jq -n --arg f "$H/CLAUDE.md" '{hook_event_name: "PreToolUse", tool_name: "Bash",
    tool_input: {command: "ls", file_path: $f}, cwd: "@ROOT@"}' >"$H/tests/conformance/toucher/allow/touch.json"
  expect_fail "toucher allow/touch.json: expected exit 0"
  assert_eq "$(cat "$H/CLAUDE.md")" "charter" "the hook's write was refused"
}

# xcrun's lookup cache lives in the user's temp folder, outside every sandbox; a hook that could
# write it would leave a change behind (FRG-6 review round 4). The test names a file of the
# cache's temporary form (xcrun_db-<letters>), never the cache itself, and removes it if made.
# Without the real temp folder the test would probe some other path, so it fails instead.
test_hook_cannot_write_the_xcrun_cache() {
  mk_conf_harness sample-gate toucher
  local ut="" f
  ut="$(getconf DARWIN_USER_TEMP_DIR)" || ut=""
  [[ "$ut" == /?*/ && -d "$ut" && -w "$ut" ]] || {
    _t_fail "can't find the user's temp folder (getconf DARWIN_USER_TEMP_DIR gave [$ut])"
    return 0
  }
  f="${ut}xcrun_db-forgetest$$"
  case_json toucher deny main 'git push origin main'
  mkdir -p "$H/tests/conformance/toucher/allow"
  jq -n --arg f "$f" '{hook_event_name: "PreToolUse", tool_name: "Bash",
    tool_input: {command: "ls", file_path: $f}, cwd: "@ROOT@"}' >"$H/tests/conformance/toucher/allow/touch.json"
  expect_fail "toucher allow/touch.json: expected exit 0"
  [[ ! -e "$f" ]] || _t_fail "the hook wrote $f"
  rm -f "$f"
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
  # Through conform, with its fake claude: run directly, this needed a real Claude Code, and passed
  # on GitHub's runner only while GITHUB_ACTIONS leaked into the unit tests (FRG-6, run 40652702756).
  conform TMPDIR="$T_TMP/a&b|c\\d"
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

# FRG-4 review round 1 (C3): the test stubs copied into a sandbox (the fake gh the hooks run there)
# are guarded like the copied hooks: a setup can't write them, and a hook that changes one fails.
test_setup_cannot_change_a_stub() {
  local how
  for how in 'printf "#!/bin/bash\nexit 0\n" >"$TMP/stubs/gh"' 'rm "$TMP/stubs/gh"' \
    'mv "$TMP/stubs" "$TMP/stubs.old"'; do
    rm -rf "${T_TMP:?}/code" "${T_TMP:?}/home"
    mk_conf_harness
    mkdir -p "$H/tests/stubs"
    cp "$FORGE_SRC/tests/stubs/gh" "$H/tests/stubs/gh"
    printf '%s\n' "$how" >"$H/tests/conformance/sample-gate/allow/push-feature.setup.sh"
    expect_fail "setup failed"
  done
}

test_fails_when_a_hook_changes_a_stub() {
  mk_conf_harness sample-gate toucher
  mkdir -p "$H/tests/stubs"
  cp "$FORGE_SRC/tests/stubs/gh" "$H/tests/stubs/gh"
  case_json toucher deny main 'git push origin main'
  touch_case '@TMP@/stubs/gh'
  expect_fail "toucher allow/touch.json: the sandbox copy of tests/stubs/gh differs from the live file"
}

# FRG-4 review round 11 (C1): a hook that swaps the stubs folder for a link to an identical copy
# fails too, though every stub file in it still matches.
test_fails_when_a_hook_links_the_stubs_folder() {
  mk_conf_harness sample-gate relinker
  mkdir -p "$H/tests/stubs" "$H/tests/conformance/relinker/allow"
  cp "$FORGE_SRC/tests/stubs/gh" "$H/tests/stubs/gh"
  case_json relinker deny main 'git push origin main'
  jq -n '{hook_event_name: "PreToolUse", tool_name: "Bash",
    tool_input: {command: "ls", file_path: "@TMP@/stubs"}, cwd: "@ROOT@"}' \
    >"$H/tests/conformance/relinker/allow/relink.json"
  expect_fail "relinker allow/relink.json: the sandbox copy of tests/stubs differs from the live file"
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
  mk_conf_harness
  printf 'charter\n' >"$H/CLAUDE.md"
  printf 'sleep 3\n' >"$H/tests/conformance/sample-gate/allow/push-feature.setup.sh"
  (sleep 1 && printf 'edited\n' >>"$H/CLAUDE.md") &
  OUT="$(cd "$H" && env HOME="$T_TMP/home" PERL5OPT='-MConfig;print("same  -\n");exit(0)' \
    "$H/.harness/bin/conformance" 2>&1)"
  RC=$?
  wait
  assert_exit 1 "$RC" "$OUT"
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
    $'true &&\nx="$(printf %s "$HR_CMD")"' $'false ||\nx="$(printf %s "$HR_CMD")"'; do
    rm -rf "${T_TMP:?}/code" "${T_TMP:?}/home"
    mk_conf_harness
    printf '%s\n' "$body" >>"$H/.claude/hooks/sample-gate.sh"
    expect_fail "part of a condition"
  done
  # A \ continuation joins the lines first, so this is one line, refused as a substitution
  # that isn't the whole value of an assignment.
  rm -rf "${T_TMP:?}/code" "${T_TMP:?}/home"
  mk_conf_harness
  printf '%s\n' $'printf x | \\\nx="$(printf %s "$HR_CMD")"' >>"$H/.claude/hooks/sample-gate.sh"
  expect_fail "a command substitution may only"
}

test_quoted_punctuation_is_not_a_group() {
  mk_conf_harness
  # Appended after hr_allow (never runs): only the source check reads these lines.
  printf '%s\n' "printf '%s\\n' '('" "echo '{'" 'echo "}" ")"' >>"$H/.claude/hooks/sample-gate.sh"
  conform
  assert_not_contains "$OUT" "may not define functions or open"
}

test_permitted_substitutions_pass_the_source_check() {
  mk_conf_harness
  # Appended after hr_allow (never runs): only the source check reads these lines.
  printf '%s\n' 'x="$(true)"' 'm="$(hr_md5 "$HR_FILE")"' 'k="$(printf %s "a b" | tr a b)"' \
    "echo 'it''s' # a comment with ( and {" 'if [[ "$x" == "(" ]]; then echo "{"; fi' \
    >>"$H/.claude/hooks/sample-gate.sh"
  conform
  assert_not_contains "$OUT" "may not define functions or open"
  assert_not_contains "$OUT" "a command substitution"
  assert_not_contains "$OUT" "part of a condition"
}

test_nested_or_spoofed_conditions_are_tracked() {
  local body
  for body in $'if\n  if true; then :; fi\n  x="$(printf %s "$HR_CMD")"\n  true\nthen\n  :\nfi' \
    $'if printf %s then\nx="$(printf %s "$HR_CMD")"\nthen\n  :\nfi' \
    $'while\n  until false; do break; done\n  x="$(printf %s "$HR_CMD")"\ndo\n  break\ndone'; do
    rm -rf "${T_TMP:?}/code" "${T_TMP:?}/home"
    mk_conf_harness
    printf '%s\n' "$body" >>"$H/.claude/hooks/sample-gate.sh"
    expect_fail "part of a condition"
  done
}

test_keywords_as_arguments_and_loop_bodies_are_fine() {
  mk_conf_harness
  printf '%s\n' "printf '%s\\n' if" 'x="$(printf ok)"' 'for f in a b; do' '  y="$(printf %s "$f")"' 'done' \
    'while true; do' '  z="$(printf ok)"' '  break' 'done' 'case "$x" in' '  ok)' '    w="$(printf ok)"' \
    '    ;;' 'esac' 'if true; then' '  v="$(printf ok)"' 'fi' >>"$H/.claude/hooks/sample-gate.sh"
  conform
  assert_not_contains "$OUT" "part of a condition"
  assert_not_contains "$OUT" "may not define functions or open"
}

test_tested_blocks_and_split_keywords_are_tracked() {
  local body
  for body in $'if true; then\nx="$(printf %s "$HR_CMD")"\ntrue\nfi || true' \
    $'true && if true; then\nx="$(printf %s "$HR_CMD")"\nfi' \
    $'for f in a; do\nx="$(printf %s "$f")"\ndone | cat' \
    $'if true; then\n  if true; then\n    x="$(printf %s "$HR_CMD")"\n  fi\nfi || true' \
    $'! while true; do\nx="$(printf %s "$HR_CMD")"\nbreak\ndone' \
    $'i\\\nf\nx="$(printf %s "$HR_CMD")"\nthen\n  :\nfi'; do
    rm -rf "${T_TMP:?}/code" "${T_TMP:?}/home"
    mk_conf_harness
    printf '%s\n' "$body" >>"$H/.claude/hooks/sample-gate.sh"
    expect_fail "part of a condition"
  done
}

test_redirection_or_time_cannot_hide_a_tested_block() {
  local body
  for body in $'if true; then\nx="$(printf %s "$HR_CMD")"\nfi >/dev/null || true' \
    $'while true; do\nx="$(printf %s "$HR_CMD")"\nbreak\ndone 2>&1 </dev/null | cat' \
    $'time -p case x in\n  x)\n    x="$(printf %s "$HR_CMD")"\n    ;;\nesac || true'; do
    rm -rf "${T_TMP:?}/code" "${T_TMP:?}/home"
    mk_conf_harness
    printf '%s\n' "$body" >>"$H/.claude/hooks/sample-gate.sh"
    expect_fail "part of a condition"
  done
}

test_comment_backslash_does_not_join_lines() {
  mk_conf_harness
  # shellcheck disable=SC1003 # the trailing backslash in the comment is the point of this case
  printf '%s\n' '# comment \' 'if true; then' 'x="$(printf %s "$HR_CMD")"' 'fi || true' \
    >>"$H/.claude/hooks/sample-gate.sh"
  expect_fail "part of a condition"
}

test_assignment_with_trailing_comment_passes() {
  mk_conf_harness
  printf '%s\n' 'sum="$(hr_md5 "$HR_FILE")" # checksum for review' >>"$H/.claude/hooks/sample-gate.sh"
  conform
  assert_not_contains "$OUT" "a command substitution may only"
}

test_fails_on_here_document_in_a_hook() {
  mk_conf_harness
  printf '%s\n' 'cat <<EOF' 'fi' 'EOF' >>"$H/.claude/hooks/sample-gate.sh"
  expect_fail "here-document"
}

test_allow_case_may_not_log_under_any_key() {
  mk_conf_harness
  jq '.hooks.PreToolUse[0].matcher = "Bash|BashAlt"' "$H/.claude/settings.json" >"$T_TMP/s.json"
  mv "$T_TMP/s.json" "$H/.claude/settings.json"
  # Runs under the default key "sample-gate", but the hook picks its "alt" part and observes.
  jq -n '{hook_event_name: "PreToolUse", tool_name: "BashAlt", tool_input: {command: "git push origin main"},
    cwd: "@ROOT@"}' >"$H/tests/conformance/sample-gate/allow/alt.json"
  printf '{"modes": {"sample-gate:alt": "observe"}}\n' >"$H/.harness/mode.json"
  expect_fail "sample-gate allow/alt.json: an allow case wrote a WOULD-DENY line"
}

test_substitution_body_must_be_simple() {
  local line
  for line in 'x="$(if (v="$HR_CMD"; hr_deny no); then :; fi; echo safe)"' 'x="$(true; printf ok)"' \
    'x="$(false || printf ok)"' 'x="$({ printf ok; })"' 'x="$(! false)"'; do
    rm -rf "${T_TMP:?}/code" "${T_TMP:?}/home"
    mk_conf_harness
    printf '%s\n' "$line" >>"$H/.claude/hooks/sample-gate.sh"
    expect_fail "simple command or a pipeline"
  done
}

test_observe_reason_with_backslash_is_literal() {
  mk_conf_harness sample-gate reason-gate
  mkdir -p "$H/tests/conformance/reason-gate/deny"
  jq -n '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "git push origin main"},
    cwd: "@ROOT@", forge_reason: "path\\tname"}' >"$H/tests/conformance/reason-gate/deny/main.json"
  case_json reason-gate allow other 'ls'
  printf '{"modes": {"reason-gate": "observe"}}\n' >"$H/.harness/mode.json"
  conform
  assert_exit 0 "$RC" "$OUT"
}

test_arithmetic_prefix_cannot_hide_a_substitution() {
  mk_conf_harness
  printf '%s\n' 'x="$((echo "$HR_CMD") || echo safe)"' >>"$H/.claude/hooks/sample-gate.sh"
  expect_fail "the inside of a command substitution must be a simple command"
}

test_fails_on_eval_or_source_in_a_hook() {
  local line
  for line in "x=\"\$(eval 'f(){ false; echo survived; }; f || true')\"" 'x="$(sh -c "false; echo ok")"' \
    "eval 'if true; then :; fi'" 'source /dev/null' '. /dev/null' 'x="$(env sh -c true)"'; do
    rm -rf "${T_TMP:?}/code" "${T_TMP:?}/home"
    mk_conf_harness
    printf '%s\n' "$line" >>"$H/.claude/hooks/sample-gate.sh"
    expect_fail "sample-gate.sh line"
    assert_contains "$OUT" "eval" "message for: $line"
  done
}

test_git_programs_from_setup_run_in_the_hook_sandbox() {
  mk_conf_harness sample-gate status-gate
  case_json status-gate deny main 'git push origin main'
  case_json status-gate allow other 'ls'
  cat >"$H/tests/conformance/status-gate/allow/other.setup.sh" <<EOF
printf '#!/bin/sh\nprintf leaked > "%s/leak.txt"\nexit 1\n' >"\$TMP/fsmon"
chmod 755 "\$TMP/fsmon"
: >"\$ROOT/a"
git -C "\$ROOT" add a
git -C "\$ROOT" config core.fsmonitor "\$TMP/fsmon"
EOF
  sed -i '' "s|%s/leak.txt|$T_TMP/leak.txt|" "$H/tests/conformance/status-gate/allow/other.setup.sh"
  conform
  [[ ! -e "$T_TMP/leak.txt" ]] || _t_fail "a git program from setup wrote outside the sandbox"
}

test_command_names_must_be_plain_and_allowed() {
  local pair line want
  for pair in "e\"va\"l \"hr_allow\"|plain word" "\"eval\" \"\$HR_CMD\"|plain word" \
    "sour\\ce \"\$HR_FILE\"|plain word" "command eval \"\$HR_CMD\"|may not run" \
    "builtin source \"\$HR_FILE\"|may not run" "set +e|may not run" "trap - ERR|may not run" \
    "FOO=1 eval x|may not run" ">/dev/null eval x|may not run" "bash -c true|may not run" \
    "unset _HR_TMPD|may not run" \
    "x=\"\$(b\"as\"h -c 'false; true')\"|inside of a command substitution" \
    "x=\"\$(FOO=1 bash -c 'false; true')\"|inside of a command substitution" \
    "x=\"\$(\"bash\" -c 'false; true')\"|inside of a command substitution" \
    "x=\"\$(>/dev/null bash -c 'false; true')\"|inside of a command substitution" \
    "x=\"\$(/usr/bin/arch /bin/bash -c 'false; true')\"|inside of a command substitution"; do
    line="${pair%|*}"
    want="${pair##*|}"
    rm -rf "${T_TMP:?}/code" "${T_TMP:?}/home"
    mk_conf_harness
    printf '%s\n' "$line" >>"$H/.claude/hooks/sample-gate.sh"
    expect_fail "sample-gate.sh line"
    assert_contains "$OUT" "$want" "for: $line"
  done
}

test_redirection_targets_are_not_command_names() {
  mk_conf_harness
  printf '%s\n' 'printf hello > "$HR_ROOT/output"' 'echo hi >&2' 'printf x 2>"$HR_FILE"' \
    'printf x >>"$HR_ROOT/log" 2>&1' >>"$H/.claude/hooks/sample-gate.sh"
  conform
  assert_not_contains "$OUT" "plain word"
}

test_array_assignments_pass_the_source_check() {
  mk_conf_harness
  printf '%s\n' 'names=()' 'names+=("$HR_CMD")' 'more=(a "b c")' 'last="${names[${#names[@]} - 1]}"' \
    >>"$H/.claude/hooks/sample-gate.sh"
  conform
  assert_not_contains "$OUT" "may not define functions or open"
  assert_not_contains "$OUT" "plain word"
}

# --- FRG-20: a hook that fails blocks the command -----------------------------------------------

# set_hook_field <jq assignment>: change sample-gate's registration, e.g. '.timeout = 600'.
set_hook_field() {
  jq ".hooks.PreToolUse[0].hooks[0] |= ($1)" "$H/.claude/settings.json" >"$T_TMP/s.json"
  mv "$T_TMP/s.json" "$H/.claude/settings.json"
}

test_fails_when_a_hook_does_not_block_on_failure() {
  mk_conf_harness
  set_hook_field 'del(.onFailure)'
  expect_fail 'sample-gate.sh (PreToolUse) lacks "onFailure": "block"'
}

test_fails_when_a_hook_continues_on_failure() {
  mk_conf_harness
  set_hook_field '.onFailure = "continue"'
  expect_fail 'lacks "onFailure": "block"'
}

test_fails_when_a_hook_has_no_timeout() {
  mk_conf_harness
  set_hook_field 'del(.timeout)'
  expect_fail 'sample-gate.sh (PreToolUse) needs a "timeout" of 1 to 120 seconds'
}

test_fails_on_a_timeout_outside_1_to_120_seconds() {
  local t
  for t in 600 121 0 -5 1.5 '"60"' null; do
    rm -rf "${T_TMP:?}/code" "${T_TMP:?}/home"
    mk_conf_harness
    set_hook_field ".timeout = $t"
    expect_fail 'needs a "timeout" of 1 to 120 seconds'
  done
}

test_timeouts_of_1_and_120_seconds_pass() {
  local t
  for t in 1 120; do
    rm -rf "${T_TMP:?}/code" "${T_TMP:?}/home"
    mk_conf_harness
    set_hook_field ".timeout = $t"
    conform
    assert_exit 0 "$RC" "timeout $t: $OUT"
  done
}

test_stop_hooks_need_no_onfailure() {
  # Claude Code ignores onFailure on Stop hooks (spec 4.6: the Stop hook fails open by design).
  mk_conf_harness
  jq --arg c "\"\$CLAUDE_PROJECT_DIR\"/.claude/hooks/sample-gate.sh" \
    '.hooks.Stop = [{hooks: [{type: "command", command: $c}]}]' \
    "$H/.claude/settings.json" >"$T_TMP/s.json"
  mv "$T_TMP/s.json" "$H/.claude/settings.json"
  conform
  assert_exit 0 "$RC" "$OUT"
  assert_not_contains "$OUT" "onFailure"
}

test_fails_when_claude_code_is_too_old() {
  mk_conf_harness
  fake_claude "2.1.294 (Claude Code)"
  expect_fail "Claude Code 2.1.294 is older than 2.1.295"
}

test_newer_claude_code_versions_pass() {
  local v
  for v in "2.1.295 (Claude Code)" "2.1.1000 (Claude Code)" "2.2.0 (Claude Code)" "3.0.0 (Claude Code)"; do
    rm -rf "${T_TMP:?}/code" "${T_TMP:?}/home" "${T_TMP:?}/bin"
    mk_conf_harness
    fake_claude "$v"
    conform
    assert_exit 0 "$RC" "version $v: $OUT"
  done
}

test_fails_when_claude_code_version_is_unreadable() {
  local v
  for v in "Claude Code" "" "2.1 (Claude Code)" "v2.1.302"; do
    rm -rf "${T_TMP:?}/code" "${T_TMP:?}/home" "${T_TMP:?}/bin"
    mk_conf_harness
    fake_claude "$v"
    expect_fail "can't read Claude Code's version"
  done
}

test_fails_when_claude_is_missing() {
  mk_conf_harness
  conform FORGE_TEST_CLAUDE="$T_TMP/no-such-claude"
  assert_exit 1 "$RC" "conformance should fail"
  assert_contains "$OUT" "Claude Code is not installed"
}

test_test_override_is_reported() {
  mk_conf_harness
  conform
  assert_exit 0 "$RC" "$OUT"
  assert_contains "$OUT" "NOTE Claude Code version read from FORGE_TEST_CLAUDE="
}

test_github_actions_skips_the_version_check() {
  mk_conf_harness
  conform FORGE_TEST_CLAUDE="$T_TMP/no-such-claude" CI=true GITHUB_ACTIONS=true
  assert_exit 0 "$RC" "$OUT"
  assert_contains "$OUT" "SKIP Claude Code version: GitHub Actions doesn't run Claude Code"
}

test_ci_alone_does_not_skip_the_version_check() {
  local env
  for env in CI=true GITHUB_ACTIONS=true; do
    rm -rf "${T_TMP:?}/code" "${T_TMP:?}/home"
    mk_conf_harness
    conform FORGE_TEST_CLAUDE="$T_TMP/no-such-claude" "$env"
    assert_exit 1 "$RC" "$env alone must not skip: $OUT"
  done
}

# --- FRG-20 review round 1 ---------------------------------------------------------------------

test_fails_on_keys_that_change_when_or_whether_a_hook_runs() {
  # asyncRewake runs the hook in the background (onFailure ignored); "if" skips it for commands
  # that don't match. Only type, command, onFailure and timeout are allowed (C1, SEC-1, SEC-2).
  local change
  for change in '.asyncRewake = true' '.if = "Bash(echo *)"' '.statusMessage = "x"' \
    '.shell = "bash"' '.once = true'; do
    rm -rf "${T_TMP:?}/code" "${T_TMP:?}/home"
    mk_conf_harness
    set_hook_field "$change"
    expect_fail "registration has keys FORGE does not allow"
  done
}

test_fails_on_unknown_matcher_group_keys() {
  mk_conf_harness
  jq '.hooks.PreToolUse[0].extra = true' "$H/.claude/settings.json" >"$T_TMP/s.json"
  mv "$T_TMP/s.json" "$H/.claude/settings.json"
  expect_fail "registration has keys FORGE does not allow (group \"extra\")"
}

test_inherited_ci_variables_do_not_skip_version_tests() {
  # C2: on GitHub Actions the test process inherits CI and GITHUB_ACTIONS.
  mk_conf_harness
  fake_claude "2.1.294 (Claude Code)"
  export CI=true GITHUB_ACTIONS=true
  expect_fail "Claude Code 2.1.294 is older than 2.1.295"
}

test_fails_when_claude_version_hangs() {
  # C3: a claude that never answers must not stall conformance.
  mk_conf_harness
  mkdir -p "$T_TMP/bin"
  printf '#!/bin/bash\nexec /bin/sleep 30\n' >"$T_TMP/bin/claude"
  chmod 755 "$T_TMP/bin/claude"
  expect_fail "did not answer"
}

test_version_check_cannot_write_files() {
  # SEC-3: the claude whose version is read runs in a sandbox that can't write files. It reports
  # an old version, so the result also proves it ran and was read (round 2, C4).
  mk_conf_harness
  mkdir -p "$T_TMP/bin"
  printf '#!/bin/bash\necho changed >>%q\necho made >%q\nprintf "2.1.294 (Claude Code)\\n"\n' \
    "$H/.harness/lib/hookrt.sh" "$T_TMP/made-by-claude" >"$T_TMP/bin/claude"
  chmod 755 "$T_TMP/bin/claude"
  local before
  before="$(shasum -a 256 "$H/.harness/lib/hookrt.sh")"
  expect_fail "Claude Code 2.1.294 is older than 2.1.295"
  assert_eq "$(shasum -a 256 "$H/.harness/lib/hookrt.sh")" "$before" "the version check changed hookrt.sh"
  [[ ! -e "$T_TMP/made-by-claude" ]] || _t_fail "the version check could write a file"
}

# --- FRG-20 review round 2 ---------------------------------------------------------------------

test_fails_on_an_empty_key_in_a_registration() {
  # C2: a key named "" is still a key FORGE doesn't allow.
  mk_conf_harness
  set_hook_field '.[""] = true'
  expect_fail "registration has keys FORGE does not allow"
}

test_fails_on_a_matcher_or_hooks_that_is_not_the_right_type() {
  # C3, SEC-1: false must not be read as a missing (match-all) matcher, or as no hooks at all.
  local change
  for change in '.hooks.PreToolUse[0].matcher = false' '.hooks.PreToolUse[0].matcher = null' \
    '.hooks.PreToolUse[0].matcher = 0' '.hooks = false' '.hooks = null'; do
    rm -rf "${T_TMP:?}/code" "${T_TMP:?}/home"
    mk_conf_harness
    jq "$change" "$H/.claude/settings.json" >"$T_TMP/s.json"
    mv "$T_TMP/s.json" "$H/.claude/settings.json"
    expect_fail ".claude/settings.json is missing or malformed"
  done
}

# probe_sleep: a link to /bin/sleep named inside this test's own folder ($S), so a process found
# by its path belongs to this test and no other run.
probe_sleep() {
  mkdir -p "$T_TMP/bin"
  S="$T_TMP/bin/probe-sleep"
  ln -sf /bin/sleep "$S"
}

# no_probe_processes: fail (and clean up) if any process of this test's probe-sleep is running.
no_probe_processes() {
  sleep 1
  if pgrep -f "$S" >/dev/null; then
    pkill -9 -f "$S"
    _t_fail "a process the probe started was left running: $1"
  fi
}

test_version_timeout_ends_the_probe() {
  # Round 2 C1: a claude that never answers is ended at the time limit.
  mk_conf_harness
  probe_sleep
  printf '#!/bin/bash\nexec %q 30\n' "$S" >"$T_TMP/bin/claude"
  chmod 755 "$T_TMP/bin/claude"
  expect_fail "did not answer"
  no_probe_processes "after the time limit"
}

test_version_probe_cannot_start_processes() {
  # Round 2 C1, round 3 C1/SEC-1: the probe may not start any process, so none can outlive it:
  # not a plain child, not one in its own process group, not one in a new session. Refused a
  # process, the fake's bash stops before printing its version, so the check fails closed. (The
  # real claude starts no process for --version.)
  local body
  probe_sleep
  for body in \
    "$(printf '%q 600 >/dev/null 2>&1 &' "$S")" \
    "$(printf 'set -m; %q 600 >/dev/null 2>&1 &' "$S")" \
    "$(printf '/usr/bin/perl -MPOSIX -e %q 2>/dev/null' \
      "if (!fork) { POSIX::setsid(); exec '$S', 600 }")"; do
    rm -rf "${T_TMP:?}/code" "${T_TMP:?}/home"
    mk_conf_harness
    printf '#!/bin/bash\n%s\nprintf "2.1.302 (Claude Code)\\n"\n' "$body" >"$T_TMP/bin/claude"
    chmod 755 "$T_TMP/bin/claude"
    expect_fail "can't read Claude Code's version"
    no_probe_processes "$body"
  done
}

test_fails_on_an_empty_or_odd_event_name() {
  # Round 3 C2: an event named "" (or anything but a plain word) is malformed, not skipped.
  local name
  for name in '""' '"Pre Tool"' '"PreToolUse\u0000"'; do
    rm -rf "${T_TMP:?}/code" "${T_TMP:?}/home"
    mk_conf_harness
    jq --arg c "\"\$CLAUDE_PROJECT_DIR\"/.claude/hooks/sample-gate.sh" \
      ".hooks[$name] = [{hooks: [{type: \"command\", command: \$c}]}]" \
      "$H/.claude/settings.json" >"$T_TMP/s.json"
    mv "$T_TMP/s.json" "$H/.claude/settings.json"
    expect_fail ".claude/settings.json is missing or malformed"
  done
}

test_fails_on_extra_keys_in_an_empty_matcher_group() {
  # Round 3 C3: a group's keys are checked even when its hooks list is empty.
  mk_conf_harness
  jq '.hooks.Stop = [{hooks: [], extra: true}]' "$H/.claude/settings.json" >"$T_TMP/s.json"
  mv "$T_TMP/s.json" "$H/.claude/settings.json"
  expect_fail "registration has keys FORGE does not allow (group \"extra\")"
}

test_fails_when_any_installed_claude_is_too_old() {
  # C4, SEC-4: the native install (~/.local/bin) is checked too, and every copy found must be new
  # enough, whichever one launched the session.
  mk_conf_harness
  mkdir -p "$T_TMP/home/.local/bin"
  printf '#!/bin/bash\nprintf "2.1.294 (Claude Code)\\n"\n' >"$T_TMP/home/.local/bin/claude"
  chmod 755 "$T_TMP/home/.local/bin/claude"
  conform FORGE_TEST_CLAUDE=
  assert_exit 1 "$RC" "an old ~/.local/bin/claude must fail: $OUT"
  assert_contains "$OUT" "$T_TMP/home/.local/bin/claude"
  assert_contains "$OUT" "2.1.294 is older than 2.1.295"
}

test_harness_toml_files_reach_the_sandbox() {
  mk_conf_harness sample-gate rules-gate
  printf 'title = "rules"\n' >"$H/.harness/rules.toml"
  case_json rules-gate deny main 'git push origin main'
  case_json rules-gate allow other 'ls'
  conform
  assert_exit 0 "$RC" "$OUT"
}

# --- FRG-5: the two hooks that fail open, and record cases ----------------------------------------

# mk_fail_open_harness: mk_conf_harness plus the real capture-owner-paste and
# gate-owner-handoff-form, registered as FORGE registers them (the capture hook without
# onFailure, so a failure never blocks the owner's message), each with cases.
mk_fail_open_harness() {
  mk_conf_harness
  local h
  for h in capture-owner-paste gate-owner-handoff-form; do
    cp "$FORGE_SRC/.claude/hooks/$h.sh" "$H/.claude/hooks/"
    chmod 755 "$H/.claude/hooks/$h.sh"
  done
  jq --arg c "\"\$CLAUDE_PROJECT_DIR\"/.claude/hooks/capture-owner-paste.sh" \
    --arg f "\"\$CLAUDE_PROJECT_DIR\"/.claude/hooks/gate-owner-handoff-form.sh" \
    '.hooks.UserPromptSubmit = [{hooks: [{type: "command", command: $c, timeout: 30}]}]
     | .hooks.Stop = [{hooks: [{type: "command", command: $f, timeout: 30}]}]' \
    "$H/.claude/settings.json" >"$T_TMP/s.json"
  mv "$T_TMP/s.json" "$H/.claude/settings.json"
  prompt_case allow no-block 'yes' false
  mkdir -p "$H/tests/conformance/gate-owner-handoff-form/deny" "$H/tests/conformance/gate-owner-handoff-form/allow"
  jq -n '{hook_event_name: "Stop", stop_hook_active: false, last_assistant_message: "```\nbrew install jq\n```", cwd: "@ROOT@"}' \
    >"$H/tests/conformance/gate-owner-handoff-form/deny/brew.json"
  jq -n '{hook_event_name: "Stop", stop_hook_active: false, last_assistant_message: "Done.", cwd: "@ROOT@"}' \
    >"$H/tests/conformance/gate-owner-handoff-form/allow/plain.json"
}

# prompt_case <deny|allow> <name> <prompt> <records: true|false> [setup script]
prompt_case() {
  local d="$H/tests/conformance/capture-owner-paste/$1"
  mkdir -p "$d"
  jq -n --arg p "$3" --argjson r "$4" '{hook_event_name: "UserPromptSubmit", prompt: $p, cwd: "@ROOT@", forge_records: $r}' >"$d/$2.json"
  if [[ -n "${5:-}" ]]; then printf '%s\n' "$5" >"$d/$2.setup.sh"; fi
}

READY_SETUP='mkdir -p "$ROOT/work/owner/2026-01-01-demo"
printf "{\"id\": \"2026-01-01-demo\", \"state\": \"ready\"}\n" >"$ROOT/work/owner/2026-01-01-demo/META.json"'
DEMO_BLOCK="$(printf '%s\n' '----- HANDOFF-RESULT BEGIN -----' 'id: 2026-01-01-demo' 'result: OK' '----- HANDOFF-RESULT END -----')"

test_fail_open_hooks_pass_when_registered_as_forge_does() {
  mk_fail_open_harness
  prompt_case allow one-block "$DEMO_BLOCK" true "$READY_SETUP"
  conform
  assert_exit 0 "$RC" "$OUT"
  [[ "$OUT" =~ capture-owner-paste\ +\|\ enforce\ +\|\ 0\ +\|\ 2\ +\|\ PASS ]] || _t_fail "capture row: $OUT"
}

test_fails_when_the_capture_hook_blocks_on_failure() {
  mk_fail_open_harness
  jq '.hooks.UserPromptSubmit[0].hooks[0].onFailure = "block"' "$H/.claude/settings.json" >"$T_TMP/s.json"
  mv "$T_TMP/s.json" "$H/.claude/settings.json"
  expect_fail 'capture-owner-paste.sh (UserPromptSubmit) must not have "onFailure": "block"'
}

test_fails_when_the_capture_hook_runs_on_another_event() {
  mk_fail_open_harness
  jq '.hooks.PreToolUse[0].hooks += .hooks.UserPromptSubmit[0].hooks | del(.hooks.UserPromptSubmit)' \
    "$H/.claude/settings.json" >"$T_TMP/s.json"
  mv "$T_TMP/s.json" "$H/.claude/settings.json"
  expect_fail "capture-owner-paste.sh may be registered only for UserPromptSubmit"
}

test_fails_when_the_handoff_form_hook_runs_on_another_event() {
  mk_fail_open_harness
  jq '.hooks.PreToolUse[0].hooks += [.hooks.Stop[0].hooks[0] + {onFailure: "block"}]' \
    "$H/.claude/settings.json" >"$T_TMP/s.json"
  mv "$T_TMP/s.json" "$H/.claude/settings.json"
  expect_fail "gate-owner-handoff-form.sh may be registered only for Stop"
}

test_fails_when_the_capture_hook_has_a_deny_case() {
  mk_fail_open_harness
  prompt_case deny refused 'no' false
  expect_fail "capture-owner-paste never denies"
}

test_fails_when_a_case_expects_a_record_that_is_not_made() {
  mk_fail_open_harness
  prompt_case allow lost "$DEMO_BLOCK" true
  expect_fail "capture-owner-paste allow/lost.json: expected the paste to be recorded in .harness/state/pastes.log"
}

# Round 1: the fail-open hooks load the runtime with a header that exits 0; no other hook may.
test_fails_when_a_fail_open_hook_uses_the_blocking_header() {
  mk_fail_open_harness
  sed -i '' 's/{ echo "FORGE hook failed open: hookrt failed to load"; exit 0; }/{ echo "hookrt failed to load" >\&2; exit 2; }/' \
    "$H/.claude/hooks/capture-owner-paste.sh"
  expect_fail "capture-owner-paste.sh fails open, so it must load the runtime with the fail-open header lines"
}

test_fails_when_a_gate_uses_the_fail_open_header() {
  mk_fail_open_harness
  sed -i '' 's/{ echo "hookrt failed to load" >&2; exit 2; }/{ echo "FORGE hook failed open: hookrt failed to load"; exit 0; }/' \
    "$H/.claude/hooks/sample-gate.sh"
  expect_fail "sample-gate.sh line"
}

test_fails_when_a_case_records_a_paste_it_should_not() {
  mk_fail_open_harness
  prompt_case allow extra "$DEMO_BLOCK" false "$READY_SETUP"
  expect_fail "capture-owner-paste allow/extra.json: expected no paste record"
}

run_tests
