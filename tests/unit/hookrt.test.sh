#!/usr/bin/env bash
# Tests for .harness/lib/hookrt.sh (spec 5.2, 10.3), through the test-only hooks in
# tests/fixtures/hooks: sample-gate (denies a push to main), probe and misbehave.
# shellcheck disable=SC2031 # each test sets and reads T_TMP inside its own subshell (assert.sh)
# shellcheck disable=SC2016 # the commands under test are single-quoted on purpose
# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"
# shellcheck source=tests/lib/hookfix.sh
source "$(dirname "$0")/../lib/hookfix.sh"

expect_deny() { # <command> [cwd]
  gate "$@"
  assert_exit 2 "$RC" "should deny: $1"
}

expect_allow() { # <command> [cwd]
  gate "$@"
  assert_exit 0 "$RC" "should allow: $1 (stderr: $ERR)"
}

# --- mode.json: anything but a valid "observe" for this hook means enforce ------------------

test_enforce_denies_with_reason() {
  mk_hook_harness
  printf '{"modes": {}}\n' >"$H/.harness/mode.json"
  gate 'git push origin main'
  assert_exit 2 "$RC"
  assert_contains "$ERR" "BLOCKED by FORGE hook sample-gate: push to main"
  assert_contains "$ERR" "rule 9"
}

test_missing_mode_file_means_enforce() {
  mk_hook_harness
  expect_deny 'git push origin main'
}

test_malformed_mode_file_means_enforce() {
  mk_hook_harness
  printf '{"modes": {"sample-gate": "observe"' >"$H/.harness/mode.json"
  expect_deny 'git push origin main'
}

test_trailing_garbage_mode_file_means_enforce() {
  mk_hook_harness
  printf '{"modes": {"sample-gate": "observe"}} x\n' >"$H/.harness/mode.json"
  expect_deny 'git push origin main'
}

test_unknown_mode_value_means_enforce() {
  mk_hook_harness
  printf '{"modes": {"sample-gate": "off"}}\n' >"$H/.harness/mode.json"
  expect_deny 'git push origin main'
}

test_missing_mode_key_means_enforce() {
  mk_hook_harness
  printf '{"modes": {"some-other-hook": "observe"}}\n' >"$H/.harness/mode.json"
  expect_deny 'git push origin main'
}

test_wrong_mode_shape_means_enforce() {
  mk_hook_harness
  printf '{"modes": ["sample-gate", "observe"]}\n' >"$H/.harness/mode.json"
  expect_deny 'git push origin main'
}

test_observe_logs_and_allows() {
  mk_hook_harness
  printf '{"modes": {"sample-gate": "observe"}}\n' >"$H/.harness/mode.json"
  gate 'git push origin main'
  assert_exit 0 "$RC" "observe allows"
  local log
  log="$(cat "$H/.harness/observed.log")"
  assert_contains "$log" " sample-gate WOULD-DENY push to main :: git push origin main"
  [[ "$log" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\  ]] || _t_fail "no utc stamp: $log"
}

test_observe_log_is_one_line_per_denial() {
  mk_hook_harness
  printf '{"modes": {"sample-gate": "observe"}}\n' >"$H/.harness/mode.json"
  gate $'git status\ngit push origin main'
  assert_exit 0 "$RC"
  assert_eq "$(wc -l <"$H/.harness/observed.log" | tr -d ' ')" 1 "log lines"
  assert_contains "$(cat "$H/.harness/observed.log")" 'git status\ngit push origin main'
}

test_observe_without_writable_log_denies() {
  mk_hook_harness
  printf '{"modes": {"sample-gate": "observe"}}\n' >"$H/.harness/mode.json"
  mkdir "$H/.harness/observed.log"
  gate 'git push origin main'
  assert_exit 2 "$RC"
  assert_contains "$ERR" "observed.log"
}

test_observe_does_not_log_an_allow() {
  mk_hook_harness
  printf '{"modes": {"sample-gate": "observe"}}\n' >"$H/.harness/mode.json"
  gate 'git push origin feature/FRG-2-x'
  assert_exit 0 "$RC"
  [[ ! -e "$H/.harness/observed.log" ]] || _t_fail "allow was logged"
}

test_mode_is_per_hook_key() {
  mk_hook_harness
  printf '{"modes": {"probe": "observe"}}\n' >"$H/.harness/mode.json"
  probe fields 'true'
  assert_contains "$OUT" "mode=observe"
  gate 'git push origin main'
  assert_exit 2 "$RC" "sample-gate still enforces"
}

# --- loading and failing closed --------------------------------------------------------------

test_missing_runtime_denies() {
  mk_hook_harness
  rm "$H/.harness/lib/hookrt.sh"
  gate 'ls'
  assert_exit 2 "$RC"
  assert_contains "$ERR" "hookrt failed to load"
}

test_runtime_that_does_not_load_denies() {
  mk_hook_harness
  : >"$H/.harness/lib/hookrt.sh"
  gate 'ls'
  assert_exit 2 "$RC"
  assert_contains "$ERR" "hookrt not loaded"
}

test_runtime_refuses_to_run_directly() {
  mk_hook_harness
  local rc=0
  bash "$H/.harness/lib/hookrt.sh" </dev/null >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc"
}

test_crash_or_no_decision_denies() {
  mk_hook_harness
  local how
  for how in unbound exit0 exit1 missing-command term fall-off-the-end; do
    run_hook misbehave "$(bash_input ls)" MISBEHAVE="$how"
    assert_exit 2 "$RC" "misbehave=$how"
  done
  assert_contains "$ERR" "ended without a decision"
}

test_missing_jq_denies() {
  mk_hook_harness
  local bin="$T_TMP/bin" tool
  mkdir "$bin"
  for tool in bash dirname cat python3 git date tr; do ln -s "$(command -v "$tool")" "$bin/$tool"; done
  run_hook probe "$(bash_input ls)" PATH="$bin"
  assert_exit 2 "$RC"
  assert_contains "$ERR" "jq is not installed"
}

test_missing_python3_denies() {
  mk_hook_harness
  local bin="$T_TMP/bin" tool
  mkdir "$bin"
  for tool in bash dirname cat jq git date tr; do ln -s "$(command -v "$tool")" "$bin/$tool"; done
  run_hook probe "$(bash_input ls)" PATH="$bin"
  assert_exit 2 "$RC"
  assert_contains "$ERR" "python3 is not installed"
}

test_bad_input_denies() {
  mk_hook_harness
  local input
  for input in '' 'not json' '[1, 2]' '"just a string"' \
    '{"tool_name": "Bash", "tool_input": {"command": 42}}' \
    '{"tool_name": "Bash", "tool_input": "git push"}' \
    '{"tool_name": "Bash", "tool_input": {"command": "ls\u0000; git push origin main"}}' \
    '{"tool_name": "Bash", "cwd": ["/"]}'; do
    run_hook probe "$input" PROBE=fields
    assert_exit 2 "$RC" "input: $input"
  done
}

test_fields_are_exposed() {
  mk_hook_harness
  run_hook probe "$(jq -n '{hook_event_name: "PreToolUse", tool_name: "Write",
    tool_input: {file_path: "/a/b.txt", content: "x"}, cwd: "/w"}')" PROBE=fields
  assert_exit 0 "$RC"
  assert_contains "$OUT" "event=PreToolUse|tool=Write|file=/a/b.txt|cwd=/w|mode=enforce|root=$H|worktrees=$T_TMP/code/forge-worktrees"
  run_hook probe "$(jq -n '{tool_name: "NotebookEdit", tool_input: {notebook_path: "/n.ipynb"}}')" PROBE=fields
  assert_contains "$OUT" "file=/n.ipynb"
}

test_command_keeps_trailing_newlines() {
  mk_hook_harness
  probe fields $'ls\n\n'
  assert_contains "$OUT" $'cmd=[ls\n\n]'
}

# --- hr_tokens ------------------------------------------------------------------------------

test_tokens_follow_shell_quoting() {
  mk_hook_harness
  probe tokens $'git commit -F "/tmp/a b.txt" \'x y\' p\\ush "ma"in'
  assert_eq "$OUT" "n=7 [git] [commit] [-F] [/tmp/a b.txt] [x y] [push] [main]"
}

test_tokens_unbalanced_quote_is_unparseable() {
  mk_hook_harness
  probe tokens 'git push "origin main'
  assert_eq "$OUT" "UNPARSEABLE"
}

test_tokens_empty_command() {
  mk_hook_harness
  probe tokens ''
  assert_eq "$OUT" "n=0"
}

# --- hr_guarded: does the command mention a guarded action? ----------------------------------

test_guarded_detection() {
  mk_hook_harness
  local c
  for c in 'git push origin x' 'git commit -F m' 'gh pr merge 3' 'gh api repos/a/b' \
    'gh repo view' 'gh workflow run deploy.yml' 'vercel deploy' 'xcrun altool --upload-app' \
    'echo "git push"' 'g"i"t p\ush origin x' 'GIT PUSH' 'cd x && git -C /y push' \
    $'git status\ngit push origin x' 'bash -c "git commit -F m"' '`git push`' \
    'x=$(printf pu)sh; git $x' 'git p origin main' 'git --exec-path=/x status' \
    'git -c alias.s=status s' 'gh m 3' 'ls node_modules/.bin/vercel'; do
    probe guarded "$c"
    assert_eq "$OUT" GUARDED "guarded: $c"
  done
}

test_plain_detection() {
  mk_hook_harness
  local c
  for c in 'ls -la' 'git status && git log --oneline -5' 'git log --grep fix | head' \
    'gh pr view 3 | head' 'gh issue list' 'echo hi > f.txt' 'git -C /x diff | wc -l' \
    'cat README.md' 'git merge dev' 'for f in *.sh; do echo "$f"; done' ''; do
    probe guarded "$c"
    assert_eq "$OUT" PLAIN "plain: $c"
  done
}

# --- hr_require_simple: a guarded command must be one plain command --------------------------

test_simple_guarded_commands_pass() {
  mk_hook_harness
  local c
  for c in 'git push -u origin feature/FRG-2-hook-runtime' 'git -C /x push origin feature/FRG-2-a' \
    'git commit -F /tmp/msg.txt' 'git log --grep commit' 'gh pr merge 3 --squash' \
    'gh api repos/Thebigtuna88/forge/pulls' 'vercel deploy' 'git -C ~/code/x push origin feature/FRG-2-a' \
    'git --no-pager -c color.ui=never push origin feature/FRG-2-a'; do
    expect_allow "$c"
  done
}

test_chained_or_expanded_guarded_commands_deny() {
  mk_hook_harness
  local c
  for c in 'cd /x && git push origin feature/FRG-2-a' 'git push origin feature/FRG-2-a; ls' \
    'git push origin feature/FRG-2-a || true' 'git push origin feature/FRG-2-a | cat' \
    'git push origin feature/FRG-2-a &' $'git push origin feature/FRG-2-a\nls' \
    'git push origin $(git branch --show-current)' 'git push origin `whoami`' \
    'git push origin $BRANCH' 'git commit -F m > /dev/null' 'git commit -F m < /dev/null' \
    'git push origin feature/*' 'git push origin {feature/FRG-2-a,main}' \
    'git push origin feature/FRG-2-a # main' 'git push origin feature/FRG-2-?' \
    'git -C ~- push origin feature/FRG-2-a' 'git push origin (main)' \
    'git log | grep commit' 'echo "git push"' 'env git push origin feature/FRG-2-a' \
    'command git push origin feature/FRG-2-a' 'bash -c "git push origin feature/FRG-2-a"' \
    'eval git push origin feature/FRG-2-a' 'GIT push origin feature/FRG-2-a' \
    'FOO=1 git push origin feature/FRG-2-a' '/usr/bin/git push origin feature/FRG-2-a' \
    "\$'\\x67it' push origin main" 'git push "origin'; do
    expect_deny "$c"
  done
}

test_quoting_tricks_still_reach_the_gate() {
  mk_hook_harness
  local c
  for c in 'git push origin main' 'g"i"t p\ush origin "ma"in' "git push origin 'HEAD:main'" \
    'git -C /x push origin refs/heads/main' 'git -C a -C b -c x.y=1 push origin main'; do
    expect_deny "$c"
    assert_contains "$ERR" "push to main" "reason for: $c"
  done
}

test_git_unknown_global_option_denies() {
  mk_hook_harness
  local c
  for c in '--git-dir=/x/.git push origin feature/FRG-2-a' '--exec-path=/tmp push origin feature/FRG-2-a' \
    '--work-tree /x push origin feature/FRG-2-a' '-c alias.p=push p origin feature/FRG-2-a' \
    '-c ALIAS.p=push p origin feature/FRG-2-a'; do
    expect_deny "git $c"
  done
}

test_gh_alias_or_extension_denies() {
  mk_hook_harness
  expect_deny 'gh co 3 && gh pr merge 3'
  expect_deny 'gh m 3'
  expect_deny 'gh --repo a/b pr merge 3'
}

# --- hr_git_sub -------------------------------------------------------------------------------

test_git_sub_skips_global_options() {
  mk_hook_harness
  probe git 'git -C a -C b -c x.y=1 --no-pager push -u origin f' /w
  assert_eq "$OUT" "sub=push|dir=/w/a/b|alias=0|args=[-u][origin][f]"
  probe git 'git -C /abs -C rel status' /w
  assert_eq "$OUT" "sub=status|dir=/abs/rel|alias=0|args="
  probe git 'git -C ~/x log' /w
  assert_eq "$OUT" "sub=log|dir=$T_TMP/home/x|alias=0|args="
  probe git 'git -C "" status' /w
  assert_eq "$OUT" "sub=status|dir=/w|alias=0|args="
}

test_git_sub_unknown_is_question_mark() {
  mk_hook_harness
  local c
  for c in 'git --git-dir=/x status' 'git frobnicate' 'git -c alias.s=status s' 'git' 'git -C'; do
    probe git "$c" "$H"
    assert_contains "$OUT" "sub=?|" "unknown: $c"
  done
}

test_git_alias_resolves_to_its_command() {
  mk_hook_harness
  git -C "$H" config alias.st 'status --short'
  git -C "$H" config alias.ss st
  probe git 'git st -b' "$H"
  assert_eq "$OUT" "sub=status|dir=$H|alias=1|args=[--short][-b]"
  probe git 'git ss' "$H"
  assert_eq "$OUT" "sub=status|dir=$H|alias=1|args=[--short]"
  gate 'git st' "$H"
  assert_exit 0 "$RC" "a plain alias to status is allowed"
}

test_git_alias_to_guarded_command_denies() {
  mk_hook_harness
  git -C "$H" config alias.p push
  git -C "$H" config alias.ci 'commit -m x'
  git -C "$H" config alias.sh '!git push origin main'
  expect_deny 'git p origin feature/FRG-2-a' "$H"
  assert_contains "$ERR" "alias"
  expect_deny 'git ci' "$H"
  expect_deny 'git sh' "$H"
  expect_deny 'git st && ls' "$H"
}

test_global_git_alias_is_seen() {
  mk_hook_harness
  git config --file "$T_TMP/home/.gitconfig" alias.p push
  expect_deny 'git p origin feature/FRG-2-a' "$H"
  assert_contains "$ERR" "alias"
}

# --- checksums --------------------------------------------------------------------------------

test_md5_and_sha256() {
  mk_hook_harness
  printf 'abc\n' >"$T_TMP/f"
  run_hook probe "$(jq -n --arg f "$T_TMP/f" '{tool_name: "Read", tool_input: {file_path: $f}}')" PROBE=sums
  assert_eq "$OUT" "md5=0bee89b07a248e27c83fc3d5951213c1 sha256=edeaaff3f1774ad2888673770c6d64097e391bc362d7d6fb34982ddf0efd18cb"
}

run_tests
