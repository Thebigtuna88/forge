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

test_capture_keeps_both_pastes_made_in_the_same_second() {
  mk_hooks "$T_TMP/code/forge" capture-owner-paste
  ready_handoff "$DEMO"
  hook capture-owner-paste "$(prompt "$(block "$DEMO")")"
  hook capture-owner-paste "$(prompt "$(block "$DEMO")")"
  assert_eq "$(pastes | wc -l | tr -d ' ')" 2 "two pastes saved"
  assert_eq "$(wc -l <"$H/.harness/state/pastes.log" | tr -d ' ')" 2 "two records"
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
