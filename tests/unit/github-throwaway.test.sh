#!/usr/bin/env bash
# Tests for FRG-26 stage 1's tests/permissions/github-throwaway.sh, without GitHub: its guards,
# the expected-results table, token redaction and how it hands each identity to gh and git.
# Fake gh and git on PATH record what they're given; nothing reaches the network. The GitHub
# behaviour itself is tested only by the owner's handoff, on the throwaway repository.
# shellcheck disable=SC2031 # each test sets and reads T_TMP inside its own subshell (assert.sh)
# shellcheck disable=SC2034,SC2329 # variables and stand-in functions are read by the sourced script
# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"

GT="$(cd "$(dirname "$0")/.." && pwd)/permissions/github-throwaway.sh"

# A fake classic token, built at run time so no token-shaped text sits in the repository.
fake_token() { printf 'gh%s_%s' p "$(printf 'Z%.0s' $(seq 1 36))"; }

load() { # source the script (main doesn't run when sourced)
  # shellcheck source=tests/permissions/github-throwaway.sh
  source "$GT"
}

fake_tools() { # gh and git that log their arguments and identity-related environment
  mkdir -p "$T_TMP/bin"
  cat >"$T_TMP/bin/gh" <<'EOF'
#!/bin/bash
{
  printf 'gh-args:%s\n' "$*"
  printf 'gh-token-set:%s\n' "${GH_TOKEN:+yes}"
  printf 'gh-github-token-set:%s\n' "${GITHUB_TOKEN:+yes}"
} >>"$FAKE_LOG"
case "$*" in
  "api user --jq .login") printf '%s\n' "${FAKE_LOGIN:-someone}" ;;
  *) printf 'error: token %s rejected\n' "${GH_TOKEN:-none}" >&2; exit 1 ;;
esac
EOF
  cat >"$T_TMP/bin/git" <<'EOF'
#!/bin/bash
{
  printf 'git-args:%s\n' "$*"
  printf 'git-global:%s nosystem:%s prompt:%s askpass:%s\n' "${GIT_CONFIG_GLOBAL:-}" "${GIT_CONFIG_NOSYSTEM:-}" "${GIT_TERMINAL_PROMPT:-}" "${GIT_ASKPASS:+set}"
} >>"$FAKE_LOG"
EOF
  chmod +x "$T_TMP/bin/gh" "$T_TMP/bin/git"
  export FAKE_LOG="$T_TMP/fake.log"
  : >"$FAKE_LOG"
  PATH="$T_TMP/bin:$PATH"
}

secrets() { # <login> <token> [mode]
  printf 'HELPER_LOGIN=%s\nHELPER_TOKEN=%s\n' "$1" "$2" >"$T_TMP/helper.env"
  chmod "${3:-600}" "$T_TMP/helper.env"
  export FRG26_SECRETS="$T_TMP/helper.env"
}

test_refuses_inside_claude_code() {
  local out rc=0
  out="$(CLAUDECODE=1 bash "$GT" status 2>&1)" || rc=$?
  assert_exit 2 "$rc"
  assert_contains "$out" "never inside Claude Code"
}

test_expected_table_matches_the_plan() {
  load
  local id
  for id in B1 B2 B3 B4 B6 B7 B8 B9 B10 B14 M1 M3 M5; do
    assert_eq "$(expect "$id" open)" allowed "$id open"
    assert_eq "$(expect "$id" protected)" refused "$id protected"
    assert_eq "$(expect "$id" ruleset)" refused "$id ruleset"
  done
  for id in B5 B12 B13 M4; do
    assert_eq "$(expect "$id" open)" refused "$id open (platform rule)"
    assert_eq "$(expect "$id" ruleset)" refused "$id ruleset"
  done
  for id in B16 M6; do
    assert_eq "$(expect "$id" open)" allowed "$id open (control)"
    assert_eq "$(expect "$id" protected)" allowed "$id protected (control)"
    assert_eq "$(expect "$id" ruleset)" allowed "$id ruleset (control)"
  done
  assert_eq "$(expect B11 open)" any "B11 open"
  assert_eq "$(expect B11 protected)" refused "B11 protected"
  # M2 is the gap the ruleset closes: allowed with protection alone, refused with the ruleset.
  assert_eq "$(expect M2 open)" allowed "M2 open"
  assert_eq "$(expect M2 protected)" allowed "M2 protected"
  assert_eq "$(expect M2 ruleset)" refused "M2 ruleset"
}

test_record_and_setup_fail() {
  load
  PHASE=protected
  FAILS=0
  local out
  out="$(record B1 refused "GH006"; echo "fails=$FAILS")"
  assert_contains "$out" "RESULT B1 protected PASS"
  assert_contains "$out" "fails=0"
  out="$(record B1 allowed "pushed"; echo "fails=$FAILS")"
  assert_contains "$out" "RESULT B1 protected FAIL"
  assert_contains "$out" "fails=1"
  # A failed setup is never counted as a refusal, even where a refusal is expected.
  out="$(setup_fail B8 "could not advance dev"; echo "fails=$FAILS")"
  assert_contains "$out" "RESULT B8 protected FAIL"
  assert_contains "$out" "observed=setup-failed"
  assert_contains "$out" "fails=1"
}

test_redact_hides_the_token() {
  load
  TOKEN="$(fake_token)"
  local out
  out="$(say "remote said: bad credentials for $TOKEN (again $TOKEN)")"
  assert_not_contains "$out" "$TOKEN"
  assert_contains "$out" "[REDACTED]"
}

test_load_helper_accepts_a_classic_token() {
  load
  secrets frg-helper "$(fake_token)"
  SECRETS="$FRG26_SECRETS"
  ( load_helper token ) || _t_fail "a valid login and classic token were refused"
}

test_load_helper_refusals() {
  load
  local out rc
  secrets frg-helper "$(fake_token)" 644
  SECRETS="$FRG26_SECRETS"
  rc=0; out="$( load_helper token 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "mode 644"
  assert_contains "$out" "must be mode 600"

  secrets frg-helper "github_pat_$(printf 'Y%.0s' $(seq 1 40))"
  rc=0; out="$( load_helper token 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "fine-grained token"
  assert_contains "$out" "not a classic token"

  secrets thebigtuna88 "$(fake_token)"
  rc=0; out="$( load_helper token 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "owner as helper"
  assert_contains "$out" "must not be the owner"

  secrets 'bad;name' "$(fake_token)"
  rc=0; out="$( load_helper token 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "invalid login"

  rm -f "$T_TMP/helper.env"
  ln -s /etc/hosts "$T_TMP/helper.env"
  rc=0; out="$( load_helper token 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "symlinked secrets file"
}

test_helper_gh_passes_the_token_only_in_the_environment() {
  load
  fake_tools
  TOKEN="$(fake_token)"
  GITHUB_TOKEN=should-be-unset helper_gh api user --jq .login >/dev/null
  local log
  log="$(cat "$FAKE_LOG")"
  assert_contains "$log" "gh-token-set:yes"
  assert_eq "$(grep '^gh-github-token-set:' "$FAKE_LOG")" "gh-github-token-set:" "GITHUB_TOKEN reached the helper's gh"
  assert_not_contains "$log" "gh-args:api user --jq .login $TOKEN"
  assert_not_contains "$(grep '^gh-args:' "$FAKE_LOG")" "$TOKEN" "token in gh's arguments"
}

test_owner_gh_never_uses_a_token_variable() {
  load
  fake_tools
  GH_TOKEN=leaked GITHUB_TOKEN=leaked owner_gh api user --jq .login >/dev/null
  assert_eq "$(grep '^gh-token-set:' "$FAKE_LOG")" "gh-token-set:" "GH_TOKEN reached the owner's gh"
  assert_eq "$(grep '^gh-github-token-set:' "$FAKE_LOG")" "gh-github-token-set:" "GITHUB_TOKEN reached the owner's gh"
}

test_helper_git_is_isolated_from_the_owners_git_config() {
  load
  fake_tools
  TOKEN="$(fake_token)"
  HELPER=frg-helper
  WORK="$T_TMP/work"
  mkdir -p "$WORK"
  helper_git status
  local log
  log="$(cat "$FAKE_LOG")"
  assert_contains "$log" "git-global:/dev/null nosystem:1 prompt:0 askpass:set"
  assert_contains "$log" "-c credential.helper= "
  assert_not_contains "$log" "$TOKEN" "token in git's arguments"
}

test_capture_redacts_tool_output() {
  load
  fake_tools
  TOKEN="$(fake_token)"
  capture helper_gh api -X DELETE repos/x/y || true
  assert_not_contains "$LAST_OUT" "$TOKEN"
  assert_contains "$LAST_OUT" "[REDACTED]"
}

test_assert_throwaway_refuses_another_repo() {
  load
  owner_gh() { printf 'Thebigtuna88/forge-frg26-throwaway\tThebigtuna88\tsomething else\tfalse\n'; }
  local out rc=0
  out="$( assert_throwaway 2>&1 )" || rc=$?
  assert_exit 2 "$rc"
  assert_contains "$out" "is not the public throwaway repo"
  owner_gh() { printf 'Thebigtuna88/forge-frg26-throwaway\tThebigtuna88\t%s\ttrue\n' "$MARKER"; }
  rc=0; out="$( assert_throwaway 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "private repo"
  owner_gh() { printf 'Thebigtuna88/forge-frg26-throwaway\tThebigtuna88\t%s\tfalse\n' "$MARKER"; }
  rc=0; ( assert_throwaway ) || rc=$?
  assert_exit 0 "$rc" "the real throwaway repo"
}

test_only_the_throwaway_repo_is_named() {
  # Every repository the script names is the throwaway one: no other owner/name appears.
  local others
  others="$(grep -oE 'repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "$GT" | grep -v 'repos/x/y' || true)"
  assert_eq "$others" "" "a hard-coded repository other than \$REPO"
  assert_contains "$(grep -c 'Thebigtuna88/forge"' "$GT" || true)" "0" "FORGE itself is named"
}

run_tests
