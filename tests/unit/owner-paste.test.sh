#!/usr/bin/env bash
# Tests for FRG-5's hooks beyond what conformance can see: what capture-owner-paste writes (the
# paste byte for byte, its record in pastes.log), the hooks that fail open, and the gates that
# refuse without their owner-only lists (spec 4.5, 4.6, 5.3, 10.3).
# shellcheck disable=SC2031 # each test sets and reads T_TMP inside its own subshell (assert.sh)
# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"
# shellcheck source=tests/lib/fixture.sh
source "$(dirname "$0")/../lib/fixture.sh"

DEMO=2026-01-01-demo

# mk_hooks <base> <hook…>: the hook runtime, FRG-5's config files and the named real hooks at
# <base>/.harness and <base>/.claude/hooks (H stays <base>), in a git repo if there isn't one.
mk_hooks() {
  local base="$1" h
  shift
  H="$base"
  mkdir -p "$H/.harness/lib" "$H/.harness/state" "$H/.claude/hooks" "$T_TMP/home"
  cp "$FORGE_SRC/.harness/lib/hookrt.sh" "$H/.harness/lib/"
  cp "$FORGE_SRC/.harness/deploy-targets.json" "$FORGE_SRC/.harness/spend-limits.json" "$FORGE_SRC/.harness/mode.json" "$H/.harness/"
  for h in "$@"; do
    cp "$FORGE_SRC/.claude/hooks/$h.sh" "$H/.claude/hooks/"
    chmod 755 "$H/.claude/hooks/$h.sh"
  done
  [[ -d "$H/.git" ]] || git -C "$H" init -q -b dev
}

# ready_handoff <id>: a frozen handoff folder, as handoff ready leaves it.
ready_handoff() {
  mkdir -p "$H/work/owner/$1"
  jq -n --arg id "$1" '{id: $id, state: "ready"}' >"$H/work/owner/$1/META.json"
}

# hook <hook> <stdin text>: run it as Claude Code does. Sets RC, OUT and ERR.
hook() {
  OUT="$(cd "$H" && printf '%s' "$2" | env -i PATH="$PATH" HOME="$T_TMP/home" TMPDIR="$T_TMP" \
    CLAUDE_PROJECT_DIR="$H" "$H/.claude/hooks/$1.sh" 2>"$T_TMP/stderr")"
  RC=$?
  ERR="$(cat "$T_TMP/stderr")"
}

# prompt <text>: the UserPromptSubmit input for an owner message.
prompt() {
  jq -n --arg p "$1" --arg d "$H" '{session_id: "t", hook_event_name: "UserPromptSubmit", prompt: $p, cwd: $d}'
}

block() { # <id>: a well-formed result block (not a real run's)
  printf '%s\n' '----- HANDOFF-RESULT BEGIN -----' "id: $1" \
    "script-sha256: $(printf 'a%.0s' {1..64})" "runtime-sha256: $(printf 'b%.0s' {1..64})" \
    'at: 2026-01-01T00:00:00Z' 'check ok: PASS fine' 'result: OK' '----- HANDOFF-RESULT END -----'
}

pastes() { # the PASTED files of the demo handoff, one per line
  find "$H/work/owner/$DEMO" -name 'PASTED-*' | sort
}

test_capture_saves_the_block_byte_for_byte_and_records_it() {
  mk_hooks "$T_TMP/code/forge" capture-owner-paste
  ready_handoff "$DEMO"
  local raw expected file sha
  raw="$(block "$DEMO" | sed 's/^/  /; s/$/\r/')"
  expected="$raw"$'\n'
  hook capture-owner-paste "$(prompt $'<pasted_content id="7">\n'"$raw"$'\n</pasted_content id="7">\nthanks')"
  assert_exit 0 "$RC" "$ERR"
  assert_eq "$(pastes | wc -l | tr -d ' ')" 1 "one paste saved"
  file="$(pastes)"
  assert_eq "$(cat "$file"; printf .)" "$expected." "saved bytes"
  assert_contains "$OUT" "saved work/owner/$DEMO/$(basename "$file")"
  assert_contains "$OUT" "handoff verify $H/work/owner/$DEMO/$(basename "$file")"
  sha="$(shasum -a 256 "$file" | awk '{print $1}')"
  [[ "$(cat "$H/.harness/state/pastes.log")" =~ ^[0-9T:Z-]+\ $DEMO\ work/owner/$DEMO/PASTED-[0-9TZ-]+\.txt\ $sha$ ]] ||
    _t_fail "pastes.log line: $(cat "$H/.harness/state/pastes.log")"
  assert_file_mode "$file" 600
  assert_eq "$(stat -f '%l' "$file")" 1 "no second link left behind"
  assert_eq "$(find "$H/work/owner/$DEMO" -name '.PASTED-*' | wc -l | tr -d ' ')" 0 "temporary file removed"
}

# A paste never replaces another: with PASTED-<utc>.txt taken for this second and the next few,
# the hook saves PASTED-<utc>-2.txt and leaves the existing files as they were (review round 1:
# two runs could fall in different seconds, so this plants the collision).
# A paste that ends right at the END line is saved without an added line break (review round 2).
test_capture_adds_no_byte_to_a_paste_ending_at_the_end_line() {
  mk_hooks "$T_TMP/code/forge" capture-owner-paste
  ready_handoff "$DEMO"
  local raw
  raw="$(block "$DEMO")"
  hook capture-owner-paste "$(prompt "$raw")"
  assert_exit 0 "$RC" "$ERR"
  assert_eq "$(cat "$(pastes)"; printf .)" "$raw." "saved bytes"
}

test_capture_never_replaces_an_existing_paste() {
  mk_hooks "$T_TMP/code/forge" capture-owner-paste
  ready_handoff "$DEMO"
  local s
  for s in 0 1 2 3 4 5 6 7 8 9; do
    printf 'planted\n' >"$H/work/owner/$DEMO/PASTED-$(date -u -v+"$s"S +%Y%m%dT%H%M%SZ).txt"
  done
  hook capture-owner-paste "$(prompt "$(block "$DEMO")")"
  assert_exit 0 "$RC" "$ERR"
  assert_eq "$(pastes | grep -c -- '-2\.txt$')" 1 "saved under the -2 name"
  assert_eq "$(cat "$H"/work/owner/"$DEMO"/PASTED-*Z.txt | sort -u)" planted "existing pastes untouched"
  assert_contains "$OUT" "Z-2.txt"
}

test_capture_says_why_it_saved_nothing() {
  mk_hooks "$T_TMP/code/forge" capture-owner-paste
  ready_handoff "$DEMO"
  hook capture-owner-paste "$(prompt "$(block "$DEMO")"$'\n'"$(block "$DEMO")")"
  assert_exit 0 "$RC"
  assert_contains "$OUT" "not saved: a message must hold exactly one HANDOFF-RESULT block"
  hook capture-owner-paste "$(prompt "$(block 2026-01-01-other)")"
  assert_contains "$OUT" "not saved: no handoff folder work/owner/2026-01-01-other"
  jq '.state = "draft"' "$H/work/owner/$DEMO/META.json" >"$T_TMP/m" && cat "$T_TMP/m" >"$H/work/owner/$DEMO/META.json"
  hook capture-owner-paste "$(prompt "$(block "$DEMO")")"
  assert_contains "$OUT" "not saved: handoff $DEMO is a draft"
  hook capture-owner-paste "$(prompt "no block here")"
  assert_eq "$OUT" "" "a message without a block gets no note"
  assert_eq "$(pastes | wc -l | tr -d ' ')" 0 "nothing saved"
  [[ ! -e "$H/.harness/state/pastes.log" ]] || _t_fail "something was recorded"
}

test_capture_does_not_follow_a_linked_paste_record() {
  mk_hooks "$T_TMP/code/forge" capture-owner-paste
  ready_handoff "$DEMO"
  printf 'old\n' >"$T_TMP/elsewhere.log"
  ln -s "$T_TMP/elsewhere.log" "$H/.harness/state/pastes.log"
  hook capture-owner-paste "$(prompt "$(block "$DEMO")")"
  assert_exit 0 "$RC"
  assert_contains "$OUT" "could not record it in .harness/state/pastes.log, so handoff verify will refuse it"
  assert_eq "$(cat "$T_TMP/elsewhere.log")" old "the link's target is untouched"
  assert_contains "$(cat "$H/.harness/observed.log")" "capture-owner-paste FAILED-OPEN"
}

# A record left unfinished by an earlier failure: the next record starts on a line of its own
# (review round 3).
test_capture_starts_a_record_after_an_unfinished_line() {
  mk_hooks "$T_TMP/code/forge" capture-owner-paste
  ready_handoff "$DEMO"
  printf 'cut short' >"$H/.harness/state/pastes.log"
  hook capture-owner-paste "$(prompt "$(block "$DEMO")")"
  assert_exit 0 "$RC" "$ERR"
  assert_eq "$(head -n 1 "$H/.harness/state/pastes.log")" "cut short unfinished"
  [[ "$(sed -n 2p "$H/.harness/state/pastes.log")" =~ ^[0-9T:Z-]+\ $DEMO\ work/owner/$DEMO/PASTED-[0-9TZ-]+\.txt\ [0-9a-f]{64}$ ]] ||
    _t_fail "second line: $(cat "$H/.harness/state/pastes.log")"
}

# An unfinished line that already holds four fields is closed with a fifth, so the next record
# can't turn it into one verify accepts (review round 4).
test_capture_never_completes_an_unfinished_record() {
  mk_hooks "$T_TMP/code/forge" capture-owner-paste
  ready_handoff "$DEMO"
  local old
  old="2026-01-01T00:00:00Z $DEMO work/owner/$DEMO/PASTED-1.txt $(printf 'c%.0s' {1..64})"
  printf '%s' "$old" >"$H/.harness/state/pastes.log"
  hook capture-owner-paste "$(prompt "$(block "$DEMO")")"
  assert_exit 0 "$RC" "$ERR"
  assert_eq "$(head -n 1 "$H/.harness/state/pastes.log")" "$old unfinished"
  assert_eq "$(awk 'NR == 1 { print NF }' "$H/.harness/state/pastes.log")" 5
}

# Running out of names for this second is a failed capture, logged FAILED-OPEN (review round 4).
test_capture_logs_running_out_of_names() {
  mk_hooks "$T_TMP/code/forge" capture-owner-paste
  ready_handoff "$DEMO"
  # Every name the hook could pick (PASTED-<second>.txt, then -2 … -99) is taken from now until 60 s
  # past the moment the filling ends: on a slow machine (a GitHub runner, FRG-6) a fixed ten-second
  # window ran out before the hook read the clock.
  local d="$H/work/owner/$DEMO" start t stamp
  start="$(date -u +%s)"
  t="$start"
  while [[ $t -lt $(($(date -u +%s) + 60)) ]]; do
    if [[ $(date -u +%s) -gt $((start + 300)) ]]; then
      _t_fail "taking the names fell behind the clock for 5 minutes"
      return
    fi
    stamp="$(date -u -r "$t" +%Y%m%dT%H%M%SZ)"
    touch "$d/PASTED-$stamp.txt" "$d/PASTED-$stamp-"{2..99}".txt"
    t=$((t + 1))
  done
  hook capture-owner-paste "$(prompt "$(block "$DEMO")")"
  assert_exit 0 "$RC" "$ERR"
  assert_contains "$OUT" "not saved: too many pastes this second"
  assert_contains "$(cat "$H/.harness/observed.log")" "capture-owner-paste FAILED-OPEN"
}

# A record with a second hard link could be edited under its other name (review round 1).
test_capture_refuses_a_hard_linked_paste_record() {
  mk_hooks "$T_TMP/code/forge" capture-owner-paste
  ready_handoff "$DEMO"
  : >"$H/.harness/state/pastes.log"
  ln "$H/.harness/state/pastes.log" "$T_TMP/alias.log"
  hook capture-owner-paste "$(prompt "$(block "$DEMO")")"
  assert_exit 0 "$RC"
  assert_contains "$OUT" "could not record it"
  assert_eq "$(cat "$T_TMP/alias.log")" "" "nothing recorded"
  assert_contains "$(cat "$H/.harness/observed.log")" "capture-owner-paste FAILED-OPEN"
}

# Even a runtime that can't load must not block the owner's message or every turn (round 1).
test_fail_open_hooks_allow_when_the_runtime_is_missing() {
  mk_hooks "$T_TMP/code/forge" capture-owner-paste gate-owner-handoff-form
  rm "$H/.harness/lib/hookrt.sh"
  hook capture-owner-paste "$(prompt "$(block "$DEMO")")"
  assert_exit 0 "$RC" "capture: $ERR"
  assert_contains "$OUT" "FORGE hook failed open: hookrt failed to load"
  hook gate-owner-handoff-form "$(jq -n '{hook_event_name: "Stop", stop_hook_active: false, last_assistant_message: "brew install jq", cwd: "/"}')"
  assert_exit 0 "$RC" "handoff form: $ERR"
}

# Settings in CLAUDE_CONFIG_DIR can switch the hooks off as well as ~/.claude's (round 1).
test_guard_protects_settings_in_claude_config_dir() {
  mk_hooks "$T_TMP/code/forge" guard-live-checkout
  mkdir -p "$T_TMP/cc"
  OUT="$(cd "$H" && jq -n --arg f "$T_TMP/cc/settings.json" --arg d "$H" \
    '{hook_event_name: "PreToolUse", tool_name: "Write", tool_input: {file_path: $f, content: "{}"}, cwd: $d}' |
    env -i PATH="$PATH" HOME="$T_TMP/home" TMPDIR="$T_TMP" CLAUDE_PROJECT_DIR="$H" CLAUDE_CONFIG_DIR="$T_TMP/cc" \
      "$H/.claude/hooks/guard-live-checkout.sh" 2>&1)"
  RC=$?
  assert_exit 2 "$RC" "$OUT"
  assert_contains "$OUT" "could switch the hooks off"
}

# A link in the main checkout to a huge folder (here the disk's root) can't be listed in full, so
# the guard refuses rather than guessing where a write lands (review round 5).
test_guard_refuses_when_the_links_cant_be_listed() {
  mk_hooks "$T_TMP/code/forge" guard-live-checkout
  ln -s / "$H/everything"
  OUT="$(cd "$H" && jq -n --arg f "$T_TMP/elsewhere.txt" --arg d "$H" \
    '{hook_event_name: "PreToolUse", tool_name: "Write", tool_input: {file_path: $f, content: "x"}, cwd: $d}' |
    env -i PATH="$PATH" HOME="$T_TMP/home" TMPDIR="$T_TMP" CLAUDE_PROJECT_DIR="$H" \
      "$H/.claude/hooks/guard-live-checkout.sh" 2>&1)"
  RC=$?
  assert_exit 2 "$RC" "$OUT"
  assert_contains "$OUT" "can't list the links in the main checkout"
}

# A folder in the main checkout that can be entered but not listed may hide a link, so the guard
# refuses rather than allowing with an incomplete map (review round 6).
test_guard_refuses_when_a_folder_cant_be_listed() {
  mk_hooks "$T_TMP/code/forge" guard-live-checkout
  printf 'x\n' >"$T_TMP/secret.txt"
  mkdir "$H/private"
  ln -s "$T_TMP/secret.txt" "$H/private/item"
  chmod 311 "$H/private"
  OUT="$(cd "$H" && jq -n --arg f "$T_TMP/secret.txt" --arg d "$H" \
    '{hook_event_name: "PreToolUse", tool_name: "Write", tool_input: {file_path: $f, content: "x"}, cwd: $d}' |
    env -i PATH="$PATH" HOME="$T_TMP/home" TMPDIR="$T_TMP" CLAUDE_PROJECT_DIR="$H" \
      "$H/.claude/hooks/guard-live-checkout.sh" 2>&1)"
  RC=$?
  chmod 755 "$H/private"
  assert_exit 2 "$RC" "$OUT"
  assert_contains "$OUT" "can't be listed"
}

# Since the owner's decision of 2026-10-27 the guard judges file tools only: a shell write into the
# main checkout is not its business (spec 11, L14; a shell-write checker is FRG-32), so it neither
# refuses nor logs one. The limit is open, not resolved.
test_guard_does_not_judge_shell_commands() {
  mk_hooks "$T_TMP/code/forge" guard-live-checkout
  hook guard-live-checkout "$(jq -n --arg c "echo x > $T_TMP/code/forge/CLAUDE.md" --arg d "$T_TMP/code/forge" \
    '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}, cwd: $d}')"
  assert_exit 0 "$RC" "$ERR"
  [[ ! -e "$H/.harness/observed.log" ]] || _t_fail "the guard logged a shell command: $(cat "$H/.harness/observed.log")"
}

# The deploy gate counts the runtime's own floor of tools even when the file leaves one out.
test_deploy_gate_keeps_the_tool_floor() {
  mk_hooks "$T_TMP/code/forge" gate-deploy-target
  printf '%s\n' '{"tools": ["fastlane"], "production": [["vercel", "--prod"]], "preview": []}' >"$H/.harness/deploy-targets.json"
  hook gate-deploy-target "$(jq -n --arg d "$H" '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "vercel --prod"}, cwd: $d}')"
  assert_exit 2 "$RC"
  assert_contains "$ERR" "matches a production pattern"
}

# Every provider but manual, and the payments section, must list hosts, key_vars and commands;
# a missing one is malformed, not empty (round 2).
test_spend_gate_refuses_missing_lists() {
  mk_hooks "$T_TMP/code/forge" gate-spend
  local cfg
  for cfg in '{"providers": {"openai": {}}, "payments": {"hosts": [], "key_vars": [], "commands": []}, "always_blocked": ["sk_live_"]}' \
    '{"providers": {"openai": {"hosts": ["api.openai.com"], "key_vars": [], "commands": []}}, "always_blocked": ["sk_live_"]}'; do
    printf '%s\n' "$cfg" >"$H/.harness/spend-limits.json"
    hook gate-spend "$(jq -n --arg d "$H" '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "curl https://api.stripe.com/v1/charges"}, cwd: $d}')"
    assert_exit 2 "$RC" "$cfg"
    assert_contains "$ERR" "can't read .harness/spend-limits.json"
  done
}

# A list set to null is malformed, not empty (round 1). Each starts from the live file with one
# list set to null, so nothing else about it is wrong (round 3).
test_spend_gate_refuses_null_lists() {
  mk_hooks "$T_TMP/code/forge" gate-spend
  local path
  for path in .providers.openai.hosts .providers.openai.key_vars .providers.openai.commands .payments.hosts .always_blocked; do
    jq "$path = null" "$FORGE_SRC/.harness/spend-limits.json" >"$H/.harness/spend-limits.json"
    hook gate-spend "$(jq -n --arg d "$H" '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "ls"}, cwd: $d}')"
    assert_exit 2 "$RC" "$path = null"
    assert_contains "$ERR" "can't read .harness/spend-limits.json"
  done
  cp "$FORGE_SRC/.harness/spend-limits.json" "$H/.harness/spend-limits.json"
  hook gate-spend "$(jq -n --arg d "$H" '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "ls"}, cwd: $d}')"
  assert_exit 0 "$RC" "the live file itself: $ERR"
}

# The owner's message must always reach the agent: a capture that fails says so and exits 0, and
# the failure is logged. Verify then refuses the paste, since it has no record.
test_capture_fails_open() {
  mk_hooks "$T_TMP/code/forge" capture-owner-paste
  hook capture-owner-paste "not json"
  assert_exit 0 "$RC" "a broken input must not block the owner's message"
  assert_contains "$OUT" "FORGE hook capture-owner-paste failed open"
  assert_contains "$(cat "$H/.harness/observed.log")" "capture-owner-paste FAILED-OPEN"
}

test_captured_paste_of_a_real_run_verifies() {
  mk_harness
  mk_hooks "$H" capture-owner-paste
  "$HANDOFF" new demo "Demo handoff" >/dev/null
  local id dir body file
  id="$(date -u +%Y-%m-%d)-demo"
  dir="$H/work/owner/$id"
  body="$(sed '$d' "$dir/OWNER-RUN.sh")"
  { printf '%s\n' "$body" 'ho_check ok /usr/bin/true'; printf 'ho_end\n'; } >"$dir/OWNER-RUN.sh"
  "$HANDOFF" ready "$id" >/dev/null || _t_fail "ready failed"
  pty_run -- bash "$dir/OWNER-RUN.sh"
  hook capture-owner-paste "$(prompt "here it is:"$'\n'"$(cat "$dir/RESULT.txt")")"
  assert_exit 0 "$RC" "$ERR"
  file="$(find "$dir" -name 'PASTED-*')"
  [[ -n "$file" ]] || _t_fail "nothing captured: $OUT"
  OUT="$("$HANDOFF" verify "$file" 2>&1)" || _t_fail "verify failed: $OUT"
  assert_contains "$OUT" "VERIFIED: $id"
}

# gate-owner-handoff-form fails open (spec 4.6): with no message to read it allows and logs.
test_handoff_form_fails_open_without_a_message() {
  mk_hooks "$T_TMP/code/forge" gate-owner-handoff-form
  printf '{"modes": {}}\n' >"$H/.harness/mode.json"
  hook gate-owner-handoff-form "$(jq -n '{hook_event_name: "Stop", stop_hook_active: false, cwd: "/"}')"
  assert_exit 0 "$RC" "$ERR"
  assert_contains "$(cat "$H/.harness/observed.log")" "gate-owner-handoff-form FAILED-OPEN"
}

# Fail-open is only for those two hooks: a gate still fails closed on input it can't read.
test_gates_still_fail_closed() {
  mk_hooks "$T_TMP/code/forge" gate-spend
  hook gate-spend "not json"
  assert_exit 2 "$RC" "gate-spend must deny input it can't read"
  [[ ! -e "$H/.harness/observed.log" ]] || _t_fail "a gate logged instead of denying"
}

test_spend_gate_refuses_without_its_list() {
  mk_hooks "$T_TMP/code/forge" gate-spend
  rm "$H/.harness/spend-limits.json"
  hook gate-spend "$(jq -n --arg d "$H" '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "ls"}, cwd: $d}')"
  assert_exit 2 "$RC"
  assert_contains "$ERR" "can't read .harness/spend-limits.json"
}

test_deploy_gate_refuses_without_its_list() {
  mk_hooks "$T_TMP/code/forge" gate-deploy-target
  rm "$H/.harness/deploy-targets.json"
  hook gate-deploy-target "$(jq -n --arg d "$H" '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "vercel deploy"}, cwd: $d}')"
  assert_exit 2 "$RC"
  assert_contains "$ERR" "can't read .harness/deploy-targets.json"
}

run_tests
