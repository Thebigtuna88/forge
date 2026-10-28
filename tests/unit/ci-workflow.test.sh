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

# The job as written, from "jobs:" to the end of the file: every line but blank lines and
# whole-line comments, trailing comments kept (a "#" inside a quoted string could otherwise hide
# the rest of a line from the comparison).
raw_jobs() { awk '/^jobs:$/ {on = 1} on && !/^[[:space:]]*(#|$)/ {print}' "$WF" 2>/dev/null; }

# The reviewed job. Any change to a step, an added step or anything after the job must change this
# text too, so it gets reviewed (round 1: an `exit 0` before the suite or the scan passed every
# check that only looked for strings).
expected_jobs() {
  cat <<'JOB'
jobs:
  ci:
    name: ci
    runs-on: macos-26
    timeout-minutes: 240
    steps:
      - name: Check out the code (full history, no stored credentials)
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0
          persist-credentials: false
      - name: Install shellcheck 0.11.0 and gitleaks 8.30.1 (sha256 checked)
        run: |
          dl="$RUNNER_TEMP/dl"
          mkdir -p "$dl"
          cd "$dl"
          curl -fsSL --proto =https --proto-redir =https -o shellcheck.tar.xz \
            https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.darwin.aarch64.tar.xz
          curl -fsSL --proto =https --proto-redir =https -o gitleaks.tar.gz \
            https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_darwin_arm64.tar.gz
          shasum -a 256 -c - <<'SUMS'
          56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79  shellcheck.tar.xz
          b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5  gitleaks.tar.gz
          SUMS
          tar -xJf shellcheck.tar.xz shellcheck-v0.11.0/shellcheck
          tar -xzf gitleaks.tar.gz gitleaks
          rm -f /opt/homebrew/bin/shellcheck /opt/homebrew/bin/gitleaks
          install -m 0755 shellcheck-v0.11.0/shellcheck /opt/homebrew/bin/shellcheck
          install -m 0755 gitleaks /opt/homebrew/bin/gitleaks
      - name: Show the tools the tests will use
        run: |
          for t in bash python3 jq git shellcheck gitleaks; do
            printf '%-10s %s\n' "$t" "$(command -v "$t")"
          done
          printf 'bash       %s\n' "$BASH_VERSION"
          python3 --version
          jq --version
          git --version
          shellcheck --version
          gitleaks version
          [[ "$(command -v bash)" == /bin/bash ]]
          [[ "$(command -v python3)" == /usr/bin/python3 ]]
          [[ "$(command -v shellcheck)" == /opt/homebrew/bin/shellcheck ]]
          [[ "$(command -v gitleaks)" == /opt/homebrew/bin/gitleaks ]]
          [[ "$(shellcheck --version)" == *"version: 0.11.0"* ]]
          [[ "$(gitleaks version)" == 8.30.1 ]]
      - name: Scan the git history for secrets
        run: |
          [[ ! -e "$RUNNER_TEMP/no-ignore" ]]
          gitleaks git --config .harness/gitleaks.toml --gitleaks-ignore-path "$RUNNER_TEMP/no-ignore" \
            --ignore-gitleaks-allow --redact --no-banner --exit-code 1 .
      - name: Run the whole test suite (must end with ALL PASS)
        run: |
          /bin/bash tests/run.sh 2>&1 | tee "$RUNNER_TEMP/run.txt"
          [[ "$(tail -n 1 "$RUNNER_TEMP/run.txt")" == "ALL PASS" ]]
JOB
}

test_the_job_is_exactly_the_reviewed_one() {
  [[ -s "$WF" ]] || _t_fail "missing $WF"
  assert_eq "$(raw_jobs)" "$(expected_jobs)" "the jobs: block"
}

# The comparison itself must catch a skipped suite or scan, a weaker scan and an added step.
test_the_job_comparison_catches_bypasses() {
  [[ -s "$WF" ]] || _t_fail "missing $WF"
  local real="$WF" m
  m="$T_TMP/mutated.yml"
  awk 'index($0, "/bin/bash tests/run.sh") {print "          exit 0"} {print}' "$real" >"$m"
  WF="$m"
  [[ "$(raw_jobs)" != "$(expected_jobs)" ]] || _t_fail "exit 0 before the suite not caught"
  awk 'index($0, "gitleaks git --config") {print "          exit 0"} {print}' "$real" >"$m"
  [[ "$(raw_jobs)" != "$(expected_jobs)" ]] || _t_fail "exit 0 before the scan not caught"
  sed 's/--ignore-gitleaks-allow //' "$real" >"$m"
  [[ "$(raw_jobs)" != "$(expected_jobs)" ]] || _t_fail "gitleaks:allow comments allowed again, not caught"
  sed 's|^          /bin/bash tests/run.sh.*$|          echo "a #b"; exit 0|' "$real" >"$m"
  [[ "$(raw_jobs)" != "$(expected_jobs)" ]] || _t_fail "a command hidden after a quoted # not caught"
  grep -vF '[[ ! -e "$RUNNER_TEMP/no-ignore" ]]' "$real" >"$m"
  [[ "$(raw_jobs)" != "$(expected_jobs)" ]] || _t_fail "a planted ignore file allowed, not caught"
  { cat "$real"; printf '      - name: extra\n        run: echo hi\n'; } >"$m"
  [[ "$(raw_jobs)" != "$(expected_jobs)" ]] || _t_fail "an added step not caught"
  WF="$real"
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
  assert_contains "$b" "--ignore-gitleaks-allow" # round 1: no source-controlled exemptions
  # Round 2: before the suite, so no repository code has run, and with no ignore file present.
  assert_contains "$b" '[[ ! -e "$RUNNER_TEMP/no-ignore" ]]'
  local scan suite
  scan="$(printf '%s\n' "$b" | grep -n -- '- name: Scan the git history' | cut -d: -f1)"
  suite="$(printf '%s\n' "$b" | grep -n -- '- name: Run the whole test suite' | cut -d: -f1)"
  [[ -n "$scan" && -n "$suite" && "$scan" -lt "$suite" ]] ||
    _t_fail "the history scan must come before the suite (scan line [$scan], suite line [$suite])"
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
