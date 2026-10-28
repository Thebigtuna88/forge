#!/usr/bin/env bash
# Tests for the harness CI workflow's shape (FRG-6, spec 10.2): what triggers it, what it may do,
# where its code and tools come from, and that it runs the whole suite. The workflow file is
# owner-only; these checks read it as text, so it is kept in one plain layout.
# shellcheck disable=SC2031 # each test sets and reads T_TMP inside its own subshell (assert.sh)
# shellcheck disable=SC2016 # the workflow's ${{ }} and $(...) text is matched literally
# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WF="$ROOT/.github/workflows/ci.yml"

# The workflow without comments (whole-line, and trailing after a space) and blank lines.
body() { sed -E 's/(^|[[:space:]])#.*$//' "$WF" 2>/dev/null | grep -v '^[[:space:]]*$'; }

# The lines of one top-level key's block: from "<key>:" up to the next top-level line.
block() { # <key>
  body | awk -v k="$1:" '$0 == k {on = 1; print; next} on && /^[^ ]/ {exit} on && NF {print}'
}

test_workflow_exists() {
  [[ -f "$WF" ]] || _t_fail "missing $WF"
}

test_triggers_are_exactly_pull_requests_and_pushes_to_dev_and_main() {
  local expected
  expected="$(printf '%s\n' 'on:' '  pull_request:' '    branches: [dev, main]' '  push:' \
    '    branches: [dev, main]')"
  assert_eq "$(block on)" "$expected" "the on: block"
}

test_no_other_trigger_anywhere() {
  local t b
  [[ -s "$WF" ]] || _t_fail "missing $WF"
  b="$(body)"
  for t in pull_request_target workflow_dispatch workflow_run workflow_call schedule \
    issue_comment repository_dispatch merge_group; do
    assert_not_contains "$b" "$t" "trigger $t"
  done
}

test_permissions_are_read_only_contents() {
  assert_eq "$(block permissions)" "$(printf '%s\n' 'permissions:' '  contents: read')"
  assert_eq "$(body | grep -c 'permissions:')" 1 "permissions: set once, at the top"
  assert_not_contains "$(body)" "write" "no write permission"
}

test_no_secrets_and_no_expressions_in_steps() {
  local b
  b="$(body)"
  assert_not_contains "$b" "secrets." "no secrets"
  assert_not_contains "$b" "GITHUB_TOKEN" "no token"
  # The only expression is the concurrency group; none reaches a run: step.
  assert_eq "$(printf '%s\n' "$b" | grep -c '\${{')" 1 "one expression"
  assert_eq "$(block concurrency)" \
    "$(printf '%s\n' 'concurrency:' '  group: ci-${{ github.ref }}' '  cancel-in-progress: true')"
}

test_one_job_named_ci_on_macos_26_with_a_time_limit() {
  local b
  b="$(body)"
  assert_eq "$(block jobs | grep -c '^  [^ ]')" 1 "one job under jobs:"
  assert_contains "$b" $'jobs:\n  ci:\n    name: ci\n    runs-on: macos-26\n    timeout-minutes: '
  assert_eq "$(printf '%s\n' "$b" | grep -c 'runs-on:')" 1 "one runs-on"
  assert_eq "$(printf '%s\n' "$b" | grep -Ec 'continue-on-error|if:')" 0 "no step skipped or ignored"
}

test_the_only_action_is_checkout_pinned_to_a_full_sha() {
  local uses
  uses="$(body | grep 'uses:')"
  assert_eq "$(printf '%s\n' "$uses" | wc -l | tr -d ' ')" 1 "one uses: line"
  [[ "$uses" =~ ^\ +uses:\ actions/checkout@[0-9a-f]{40}$ ]] ||
    _t_fail "uses: must be actions/checkout@<40 hex>, got [$uses]"
}

test_checkout_has_full_history_and_keeps_no_credentials() {
  local b
  b="$(body)"
  assert_contains "$b" "fetch-depth: 0"
  assert_contains "$b" "persist-credentials: false"
}

test_tools_are_pinned_and_checksum_verified() {
  local b
  b="$(body)"
  assert_contains "$b" "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.darwin.aarch64.tar.xz"
  assert_contains "$b" "https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_darwin_arm64.tar.gz"
  assert_contains "$b" "56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79  shellcheck.tar.xz"
  assert_contains "$b" "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5  gitleaks.tar.gz"
  assert_contains "$b" "shasum -a 256 -c"
  assert_not_contains "$b" "brew " "no unpinned Homebrew install"
}

# Every step uses the hooks' own PATH, so the suite gets /bin/bash 3.2 and Apple's python3 and
# jq, as on the owner's Mac.
test_steps_use_the_hooks_path() {
  local hooks_path
  hooks_path="$(grep -E '^PATH=' "$ROOT/.harness/lib/hookrt.sh" | head -n 1)"
  hooks_path="${hooks_path#PATH=}"
  [[ -n "$hooks_path" ]] || _t_fail "no PATH= line in hookrt.sh"
  assert_eq "$(block env)" "$(printf '%s\n' 'env:' "  PATH: $hooks_path")" "top-level env"
  assert_eq "$(body | grep -c 'PATH')" 1 "PATH set once, nowhere else"
  assert_contains "$(block defaults)" "shell: /bin/bash --noprofile --norc -euo pipefail {0}"
}

test_runs_the_whole_suite_and_needs_all_pass() {
  local b
  b="$(body)"
  assert_contains "$b" "/bin/bash tests/run.sh"
  assert_contains "$b" '[[ "$(tail -n 1 "$RUNNER_TEMP/run.txt")" == "ALL PASS" ]]'
}

test_scans_the_history_with_forge_rules_and_redacts() {
  local b
  b="$(body)"
  assert_contains "$b" "gitleaks git --config .harness/gitleaks.toml"
  assert_contains "$b" "--gitleaks-ignore-path"
  assert_contains "$b" "--redact"
  assert_contains "$b" "--exit-code 1"
}

test_says_it_does_not_block_merging_yet() {
  local f
  f="$(cat "$WF" 2>/dev/null)"
  assert_contains "$f" "does not technically block merging"
  assert_contains "$f" "FRG-34"
}

run_tests
