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

test_observe_with_trailing_newline_means_enforce() {
  mk_hook_harness
  printf '{"modes": {"sample-gate": "observe\\n"}}\n' >"$H/.harness/mode.json"
  expect_deny 'git push origin main'
}

test_two_mode_documents_mean_enforce() {
  mk_hook_harness
  printf '{"modes": {}}\n{"modes": {"sample-gate": "observe"}}\n' >"$H/.harness/mode.json"
  expect_deny 'git push origin main'
}

test_part_has_its_own_mode() {
  mk_hook_harness
  printf '{"modes": {"sample-gate:alt": "observe"}}\n' >"$H/.harness/mode.json"
  run_hook sample-gate "$(jq -n '{tool_name: "BashAlt", tool_input: {command: "git push origin main"}}')"
  assert_exit 0 "$RC" "the alt part observes"
  assert_contains "$(cat "$H/.harness/observed.log")" " sample-gate:alt WOULD-DENY push to main"
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

test_inherited_loaded_flag_does_not_skip_the_runtime() {
  mk_hook_harness
  : >"$H/.harness/lib/hookrt.sh"
  run_hook sample-gate "$(bash_input ls)" HOOKRT_LOADED=1
  assert_exit 2 "$RC"
}

test_inherited_private_state_is_ignored() {
  mk_hook_harness
  run_hook sample-gate "$(bash_input 'xcrun altool --upload-app && ls')" \
    _HR_LOADED=1 _HR_TOOLS=bogus _HR_GIT_CMDS=' status ' _HR_DECISION=allow
  assert_exit 2 "$RC" "deploy floor must still apply"
}

test_inherited_functions_are_not_used() {
  mk_hook_harness
  # A jq function that claims every mode.json says "observe" would turn a deny into an allow.
  local out rc=0
  out="$(cd "$H" && HOME="$T_TMP/home" /bin/bash -c '
    jq() { if [[ "$1" == -se ]]; then return 0; fi; command jq "$@"; }
    export -f jq
    bash_input() { command jq -n --arg c "$1" "{tool_name: \"Bash\", tool_input: {command: \$c}}"; }
    bash_input "git push origin main" | ./.claude/hooks/sample-gate.sh' 2>&1)" || rc=$?
  assert_exit 2 "$rc" "exported function must not be imported: $out"
}

test_bash_env_is_ignored() {
  mk_hook_harness
  printf 'exit 0\n' >"$T_TMP/benv.sh"
  run_hook sample-gate "$(bash_input 'git push origin main')" BASH_ENV="$T_TMP/benv.sh"
  assert_exit 2 "$RC"
}

test_hook_without_privileged_shebang_denies() {
  mk_hook_harness
  sed -i '' '1s|.*|#!/bin/bash|' "$H/.claude/hooks/probe.sh"
  probe fields 'ls'
  assert_exit 2 "$RC"
  assert_contains "$ERR" "#!/bin/bash -p"
}

test_inherited_path_cannot_replace_tools() {
  mk_hook_harness
  mkdir "$T_TMP/evil"
  printf '#!/bin/sh\nprintf .\n' >"$T_TMP/evil/jq"
  chmod 755 "$T_TMP/evil/jq"
  run_hook sample-gate "$(bash_input 'git push origin main')" PATH="$T_TMP/evil:$PATH"
  assert_exit 2 "$RC"
  assert_contains "$ERR" "push to main"
}

test_raw_nul_byte_in_input_denies() {
  mk_hook_harness
  local rc=0
  (cd "$H" && printf '{"tool_name":"Ba\000sh","tool_input":{"command":"git push origin main"}}' |
    HOME="$T_TMP/home" ./.claude/hooks/probe.sh >/dev/null 2>&1) || rc=$?
  assert_exit 2 "$rc"
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
  for how in unbound exit0 exit1 missing-command term usr1 quit error-then-allow false-then-allow \
    unset-decided exec-true exec-false command-exec builtin-exec subst-error-then-allow \
    local-subst-then-allow local-deny-then-allow arg-subst-then-allow pipe-subst-unset fall-off-the-end; do
    run_hook misbehave "$(bash_input ls)" MISBEHAVE="$how"
    assert_exit 2 "$RC" "misbehave=$how"
  done
  assert_contains "$ERR" "ended without a decision"
}

test_missing_jq_denies() {
  mk_hook_harness
  local bin="$T_TMP/bin" tool
  mkdir "$bin"
  for tool in bash dirname cat python3 git date tr mktemp rm; do ln -s "$(command -v "$tool")" "$bin/$tool"; done
  sed -i '' "s|^PATH=.*|PATH=$bin|" "$H/.harness/lib/hookrt.sh"
  run_hook probe "$(bash_input ls)"
  assert_exit 2 "$RC"
  assert_contains "$ERR" "jq is not installed"
}

test_missing_python3_denies() {
  mk_hook_harness
  local bin="$T_TMP/bin" tool
  mkdir "$bin"
  for tool in bash dirname cat jq git date tr mktemp rm; do ln -s "$(command -v "$tool")" "$bin/$tool"; done
  sed -i '' "s|^PATH=.*|PATH=$bin|" "$H/.harness/lib/hookrt.sh"
  run_hook probe "$(bash_input ls)"
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
    '{"tool_name": "Bash", "cwd": ["/"]}' '{"tool_name": false}' \
    '{"tool_name": "Bash", "tool_input": {"command": false}}' \
    '{"tool_name": "Write", "tool_input": {"file_path": false}}' \
    '{"tool_name": "Bash", "tool_input": {"command": "git push"}} {"tool_input": {"command": " origin main"}}'; do
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

test_worktrees_folder_from_a_worktree() {
  mk_hook_harness
  mkdir -p "$T_TMP/code/forge-worktrees"
  mv "$H" "$T_TMP/code/forge-worktrees/FRG-9-x"
  H="$T_TMP/code/forge-worktrees/FRG-9-x"
  probe fields 'ls'
  assert_contains "$OUT" "|root=$H|worktrees=$T_TMP/code/forge-worktrees"$'\n'"cmd="
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
    'gh repo edit' 'gh workflow run deploy.yml' 'vercel deploy' 'xcrun altool --upload-app' \
    'echo "git push"' 'g"i"t p\ush origin x' 'GIT PUSH' 'cd x && git -C /y push' \
    $'git status\ngit push origin x' 'bash -c "git commit -F m"' '`git push`' \
    'x=$(printf pu)sh; git $x' 'git p origin main' 'git --exec-path=/x status' \
    'git -c alias.s=status s' 'gh m 3' 'ls node_modules/.bin/vercel' \
    $'gi\\\nt pu\\\nsh origin main' '/usr/bin/g[i]t push origin main' 'g?t push origin main' \
    '{g,}it push origin main' "\$'\\x67it' \$'\\x70ush' origin main" 'ls; G*T push' \
    'echo `g?t push`' 'x=1 g[i]t push' 'env -i g[i]t push' '> f g?t push' '"$G" push' \
    '2>/dev/null /usr/bin/g[i]t push origin main' '/usr/bin/env /usr/bin/g[i]t push origin main' \
    'env -u FOO /usr/bin/g[i]t push origin main' 'exec -a x g?t push' 'coproc g?t push' \
    'nice -n 5 g?t push' 'ls; 3<f g?t push' 'cat <(g?t push origin main)' \
    'diff <(/usr/bin/g[i]t push origin main) /dev/null' 'tee >(g?t push) </dev/null' \
    "bash -c \$'git\\x20push\\x20origin\\x20main'" "sh -c \$'\\147it push'" \
    'arch -arm64 /usr/bin/g[i]t push origin main' 'xcrun g?t push' 'frobnicate -x /usr/bin/g[i]t push' \
    'frobnicate /usr/bin/{g,}it push' 'frobnicate /usr/bin/[g][i][t] push' \
    'find . -maxdepth 0 -exec /tmp/bin/??? push origin main \;' 'frobnicate /tmp/bin/??? push origin main' \
    'find . -exec /tmp/bin/??? {} \;' '/Library/Developer/CommandLineTools/usr/libexec/git-core/git-push origin main' \
    'git-commit -F m' 'git send-pack origin main' 'git http-push origin main' \
    'gh pr m???e 16 --squash' 'gh workflow r?n build.yml' 'gh pr $X 16' 'gh pr {merge,view} 16' \
    'ls; gh pr m*e 16' 'vercel dep[l]oy --pr?d' 'cd /x && git rebase dev' \
    'git checkout -b feature/FRG-3-a && ls' 'git branch -f x; ls' 'git update-ref -d refs/heads/main | cat' \
    'git cherry-pick abc && ls' 'git commit-tree abc' 'git worktree add -b x /y && ls' 'git switch -c x; ls' \
    'git filter-branch' 'git replace a b' 'git revert HEAD' 'git am p.patch' 'git merge dev && ls' \
    'cd /x; git reset --hard HEAD' 'git pull origin dev | cat' 'git fetch origin main:main && ls' \
    'git stash push && ls' 'git history split HEAD; ls' 'git replay x | cat' 'git config alias.x y && ls' \
    'git remote update && ls' 'git tag -a v1 -m x; ls' 'git init -b bad /tmp/x && ls' 'git clone -b x /y /z; ls' \
    '/Library/Developer/CommandLineTools/usr/libexec/git-core/git-remote update' 'git-tag -a v1 -m x' \
    'git-notes add -m x' 'echo x > .git/refs/heads/dev' 'cat .git/config' 'cd .git && ls' \
    'git log -1 --format=%H --output=/r/.git/refs/heads/dev HEAD~1' 'cp a /r/.git/packed-refs'; do
    probe guarded "$c"
    assert_eq "$OUT" GUARDED "guarded: $c"
  done
}

# FRG-4: gh is judged by its real command. Only the read-only commands, with the two words after
# gh written out, are plain; any other gh invocation, wherever gh may run, is guarded.
test_gh_guarded_detection() {
  mk_hook_harness
  local c
  for c in 'gh issue create --repo a/b --title x --body-file f' 'gh secret set X' 'gh auth status' \
    'gh auth token' 'gh pr comment 5 --body-file f' 'gh' 'gh pr' 'gh pr view5' 'gh co 5' \
    'echo repo delete a/b | xargs gh' 'xargs gh < args.txt' 'nice gh repo delete a/b' \
    'ssh host gh pr merge 5' 'gh pr view 5 && gh pr merge 5' 'gh pr view 5 | gh pr merge 5' \
    'frobnicate /tmp/bin/?? repo delete a/b' 'gh $X view 5' 'gh pr "$X" 5' 'GH repo delete a/b' \
    '/opt/homebrew/bin/gh repo delete a/b' 'which gh | cat' 'gh search' 'gh pr -R a/b merge 5' \
    'gh issue --repo a/b view 5' "sh -c 'gh pr merge 5'" 'gh run rerun 5' 'gh workflow run x' \
    'gh repo view && gh repo delete a/b' 'gh label create x' 'gh release create v1'; do
    probe guarded "$c"
    assert_eq "$OUT" GUARDED "guarded: $c"
  done
}

test_gh_reads_are_plain() {
  mk_hook_harness
  local c
  for c in 'gh pr view 5 --repo a/b | head' "gh pr view 5 --repo a/b --json files | jq '.files[].path'" \
    'gh issue list --repo a/b --state open' 'gh repo view a/b' 'gh pr diff 5 --repo a/b | wc -l' \
    'gh pr checks 5' 'gh pr status' 'gh run list --limit 3' 'gh run view 1 --log | tail -5' \
    'gh run watch 1' 'gh workflow list' 'gh workflow view ci.yml' 'gh release list' \
    'gh release view v1' 'gh label list' 'gh search issues x --repo a/b' 'gh status' 'gh browse' \
    "gh pr view 5 --json title --jq '.title | ascii_downcase'" 'which gh' 'brew upgrade gh' \
    'ls /opt/homebrew/bin/gh' 'gh issue view 5 --comments | grep -i repo'; do
    probe guarded "$c"
    assert_eq "$OUT" PLAIN "plain: $c"
  done
}

test_inherited_gh_variables_deny_guarded_gh_commands() {
  mk_hook_harness
  local v
  for v in GH_TOKEN=x GH_REPO=a/b GH_HOST=example.com GH_CONFIG_DIR="$T_TMP/x" GITHUB_TOKEN=x \
    GH_ENTERPRISE_TOKEN=x GITHUB_API_URL=https://example.com; do
    run_hook sample-gate "$(bash_input 'gh issue create --title x --body-file f' "$H")" "$v"
    assert_exit 2 "$RC" "guarded gh command with $v"
    assert_contains "$ERR" "the environment sets ${v%%=*}" "reason with $v"
  done
  run_hook sample-gate "$(bash_input 'gh pr view 5 --repo a/b' "$H")" GH_REPO=c/d
  assert_exit 0 "$RC" "a gh read isn't guarded"
}

test_fake_gh_only_inside_a_conformance_sandbox() {
  mk_hook_harness
  mkdir -p "$T_TMP/stubs"
  probe ghpath 'true'
  assert_not_contains "$OUT" "$T_TMP" "outside a sandbox, gh comes from PATH"
  mk_hook_harness "$T_TMP/forge-conformance.Ab3dE9/s12"
  probe ghpath 'true'
  assert_eq "$OUT" "gh=$T_TMP/forge-conformance.Ab3dE9/s12/stubs/gh" "inside a sandbox, its fake gh"
  local base
  for base in "$T_TMP/forge-conformance.Ab3dE/s1" "$T_TMP/forge-conformance.Ab3dE9/x1" \
    "$T_TMP/conformance.Ab3dE9/s1" "$T_TMP/forge-conformance.Ab3dE9/s1/extra"; do
    mk_hook_harness "$base"
    probe ghpath 'true'
    assert_not_contains "$OUT" "/stubs/gh" "not a sandbox: $base"
  done
}

test_plain_detection() {
  mk_hook_harness
  local c
  for c in 'ls -la' 'git status && git log --oneline -5' 'git log --grep fix | head' \
    'gh pr view 3 | head' 'gh issue list' 'echo hi > f.txt' 'git -C /x diff | wc -l' \
    'cat README.md' 'for f in *.sh; do echo "$f"; done' '' \
    'ls *.sh | wc -l' 'rm -rf build/* && ls' 'for f in a b; do bash "$f"; done' 'ls * | head' \
    'ls work/*/manual | head' 'find work -type f | head' 'for d in a b; do git -C "$d" status; done' \
    'git ls-files | wc -l' 'git diff --stat && git log -1' 'ls .github | head' 'cat .gitignore | head'; do
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
    'gh api repos/Thebigtuna88/forge/pulls' 'vercel deploy' \
    'git --no-pager -c color.ui=never push origin feature/FRG-2-a' \
    'git -c core.quotepath=false -c advice.detachedHead=false push origin feature/FRG-2-a' \
    'gh repo edit Thebigtuna88/forge' 'gh actions' 'gh copilot explain x' 'gh repo list' 'git merge dev' \
    'git pull --ff-only origin dev'; do
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
    'git -C ~/code/x push origin feature/FRG-2-a' 'git -C "~/x" push origin feature/FRG-2-a' \
    $'gi\\\nt pu\\\nsh origin feature/FRG-2-a' 'g?t push origin feature/FRG-2-a' \
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
    'git -C /x push origin refs/heads/main' 'git -C a -C b -c color.ui=never push origin main'; do
    expect_deny "$c"
    assert_contains "$ERR" "push to main" "reason for: $c"
  done
}

test_git_unknown_global_option_denies() {
  mk_hook_harness
  local c
  for c in '--git-dir=/x/.git push origin feature/FRG-2-a' '--exec-path=/tmp push origin feature/FRG-2-a' \
    '--work-tree /x push origin feature/FRG-2-a' '-c alias.p=push p origin feature/FRG-2-a' \
    '-c ALIAS.p=push p origin feature/FRG-2-a' "-c core.editor=\"sh -c 'git push origin main'\" config --edit" \
    '-c core.sshCommand=evil push origin feature/FRG-2-a' '-c x.y=1 push origin feature/FRG-2-a'; do
    expect_deny "git $c"
  done
}

test_git_internal_files_and_dashed_programs_deny() {
  mk_hook_harness
  expect_deny 'git log -1 --format=%H --output=/r/.git/refs/heads/dev HEAD'
  assert_contains "$ERR" "git's own files"
  expect_deny 'cat .git/config'
  expect_deny 'git-tag -a v1 -m x'
  expect_deny '/Library/Developer/CommandLineTools/usr/libexec/git-core/git-notes add -m x'
}

test_git_options_that_run_programs_deny() {
  mk_hook_harness
  local c
  for c in "git archive --remote=dev --exec='git push origin' HEAD" 'git archive --remote=stash --exec=git HEAD' \
    'git archive --rem=stash --ex=git HEAD' "git ls-remote --upload-pack='git commit' origin" \
    "git ls-remote -qu 'git commit' origin" "git grep '-Ogit tag -m x v1' -e y" \
    "git grep --open-files-in-pager='git commit' -e y" "git ls-remote -u 'git commit' origin" \
    "git grep -iO'git commit' -e y"; do
    probe guarded "$c"
    assert_eq "$OUT" GUARDED "guarded: $c"
    expect_deny "$c"
    assert_contains "$ERR" "runs another program" "reason for: $c"
  done
}

test_guarded_action_inside_an_argument_denies() {
  mk_hook_harness
  local c
  for c in "git config core.pager 'git push origin dev:main'" "git config core.pager 'git tag -m x v1'" \
    "git config core.pager 'GIT stash'" "git commit -F m --cleanup='git branch -D dev'"; do
    probe guarded "$c"
    assert_eq "$OUT" GUARDED "guarded: $c"
    expect_deny "$c"
    assert_contains "$ERR" "names a guarded action" "reason for: $c"
  done
  expect_allow 'git log --grep commit'
  expect_allow 'git push -u origin feature/FRG-3-git-gates'
  expect_allow 'git -C /x/forge-worktrees/FRG-3-git-gates merge --no-edit dev'
  expect_allow 'git commit -F /tmp/git-message.txt'
  expect_allow 'git commit --file=/tmp/git-notes.txt'
  expect_deny 'git config core.pager /Library/Developer/CommandLineTools/usr/libexec/git-core/git-stash'
  assert_contains "$ERR" "names a guarded action"
  expect_deny 'git config core.pager vercel'
  assert_contains "$ERR" "names a guarded action"
}

test_alias_expanded_arguments_are_checked() {
  mk_hook_harness
  git -C "$H" config alias.ag 'grep -Ogit -e marker'
  git -C "$H" config alias.ar 'archive --remote=stash'
  git -C "$H" config alias.cp "config core.pager 'git push origin dev:main'"
  expect_deny 'git ag'
  assert_contains "$ERR" "runs another program"
  expect_deny 'git ar --exec=git HEAD'
  assert_contains "$ERR" "runs another program"
  expect_deny 'git cp'
  assert_contains "$ERR" "names a guarded action"
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
  probe git 'git -C a -C b -c color.ui=never --no-pager push -u origin f' /w
  assert_eq "$OUT" "sub=push|dir=/w/a/b|alias=0|args=[-u][origin][f]"
  probe git 'git -C /abs -C rel status' /w
  assert_eq "$OUT" "sub=status|dir=/abs/rel|alias=0|args="
  probe git 'git -C ~/x log' /w
  assert_eq "$OUT" "sub=log|dir=|alias=0|args=" "a ~ directory is unknown (quoting is lost)"
  probe git 'git -C "~/x" log' /w
  assert_eq "$OUT" "sub=log|dir=|alias=0|args="
  probe git 'git -C / -C tmp status' /w
  assert_eq "$OUT" "sub=status|dir=/tmp|alias=0|args="
  probe git 'git -C "" status' /w
  assert_eq "$OUT" "sub=status|dir=/w|alias=0|args="
}

test_git_sub_unknown_is_question_mark() {
  mk_hook_harness
  local c
  for c in 'git --git-dir=/x status' 'git frobnicate' 'git -c alias.s=status s' 'git' 'git -C' \
    'git -c core.pager=less status'; do
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
  git -C "$H" config alias.sp send-pack
  git -C "$H" config alias.hp http-push
  git -C "$H" config alias.rb rebase
  git -C "$H" config alias.co checkout
  git -C "$H" config alias.ur update-ref
  expect_deny 'git p origin feature/FRG-2-a' "$H"
  assert_contains "$ERR" "alias"
  expect_deny 'git ci' "$H"
  expect_deny 'git sp origin main' "$H"
  assert_contains "$ERR" "alias"
  expect_deny 'git hp origin main' "$H"
  assert_contains "$ERR" "alias"
  local a
  for a in 'git rb dev' 'git co -b x' 'git ur -d refs/heads/main'; do
    expect_deny "$a" "$H"
    assert_contains "$ERR" "alias" "alias for: $a"
  done
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

test_checksum_of_option_like_name_denies() {
  mk_hook_harness
  local f what
  for what in md5 sha256; do
    for f in --help -sabc -a; do
      run_hook probe "$(jq -n --arg f "$f" '{tool_name: "Read", tool_input: {file_path: $f}}')" PROBE="$what"
      assert_exit 2 "$RC" "$what of '$f' (got: $OUT)"
    done
  done
}

test_inherited_perl_options_cannot_forge_checksums() {
  mk_hook_harness
  printf 'abc\n' >"$T_TMP/f"
  run_hook probe "$(jq -n --arg f "$T_TMP/f" '{tool_name: "Read", tool_input: {file_path: $f}}')" \
    PROBE=sha256 PERL5OPT='-MConfig;print("forged\n");exit(0)'
  assert_eq "$OUT" "sha256=edeaaff3f1774ad2888673770c6d64097e391bc362d7d6fb34982ddf0efd18cb"
}

test_inherited_git_exec_path_is_ignored() {
  mk_hook_harness
  mkdir "$T_TMP/gx"
  printf '#!/bin/sh\nexit 0\n' >"$T_TMP/gx/git-launch"
  chmod 755 "$T_TMP/gx/git-launch"
  run_hook sample-gate "$(bash_input 'git launch' "$H")" GIT_EXEC_PATH="$T_TMP/gx"
  assert_exit 2 "$RC" "git-launch is not one of git's own commands"
}

test_inherited_git_variables_deny_guarded_git_commands() {
  mk_hook_harness
  local v
  for v in GIT_INDEX_FILE="$T_TMP/other-index" GIT_AUTHOR_NAME=x GIT_DIR="$T_TMP/x" \
    GIT_CONFIG_COUNT=1 GIT_EDITOR=vim; do
    run_hook sample-gate "$(bash_input 'git commit -F /tmp/msg' "$H")" "$v"
    assert_exit 2 "$RC" "guarded git command with $v"
    assert_contains "$ERR" "the environment sets ${v%%=*}" "reason with $v"
  done
  run_hook sample-gate "$(bash_input 'git commit -F /tmp/msg' "$H")" GIT_EDITOR=true
  assert_exit 0 "$RC" "Claude Code's own GIT_EDITOR=true"
  run_hook sample-gate "$(bash_input 'git status' "$H")" GIT_INDEX_FILE="$T_TMP/other-index"
  assert_exit 0 "$RC" "a command that isn't guarded"
}

test_alias_expanded_git_paths_deny() {
  mk_hook_harness
  git -C "$H" config alias.rollback 'log -1 --format=%H --output=/r/.git/refs/heads/dev HEAD~1'
  expect_deny 'git rollback'
  assert_contains "$ERR" "git's own files"
}

test_attached_option_git_paths_deny() {
  mk_hook_harness
  local c
  for c in 'sort -o.git/refs/heads/dev /tmp/sha' 'tar -C.git -xf x.tar' 'cp -t.GIT/hooks x' \
    'sort -uo.git/packed-refs x' 'git log -1 --format=%H -- -o.git/x'; do
    expect_deny "$c"
    assert_contains "$ERR" "git's own files"
  done
  for c in 'ls -d /tmp/remote.git' 'cat .gitignore' 'git -C /x log -1 -- .git-blame-ignore-revs'; do
    expect_allow "$c"
  done
}

test_checksum_of_missing_file_denies() {
  mk_hook_harness
  run_hook probe "$(jq -n --arg f "$T_TMP/nope" '{tool_name: "Read", tool_input: {file_path: $f}}')" PROBE=sums
  assert_exit 2 "$RC"
}

run_tests
