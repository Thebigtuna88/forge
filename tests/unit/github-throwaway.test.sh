#!/usr/bin/env bash
# Tests for FRG-26 stage 1's tests/permissions/github-throwaway.sh, without GitHub: its guards,
# the expected-results table, how attempts are judged, token redaction and how it hands each
# identity to gh and git. Fake gh and git on PATH record what they're given; nothing reaches the
# network. The GitHub behaviour itself is tested only by the owner's handoff, on the throwaway
# repository.
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
  printf 'gh-config-dir:%s\n' "${GH_CONFIG_DIR:-}"
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
  printf 'git-global:%s nosystem:%s prompt:%s askpass:%s home:%s\n' "${GIT_CONFIG_GLOBAL:-}" "${GIT_CONFIG_NOSYSTEM:-}" "${GIT_TERMINAL_PROMPT:-}" "${GIT_ASKPASS:+set}" "${HOME:-}"
  printf 'git-leaked:%s%s%s\n' "${GIT_COMMON_DIR:-}" "${GIT_TEMPLATE_DIR:-}" "${GIT_DIR:-}"
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

test_main_runs_when_given_as_a_string() {
  # The handoffs run the script as `bash -p -c "<script>" frg26 <command>`: main must run then
  # (shown here by the agent guard answering, before anything else happens).
  local out rc=0
  out="$(CLAUDECODE=1 /bin/bash -p -c "$(cat "$GT")" frg26 status 2>&1)" || rc=$?
  assert_exit 2 "$rc"
  assert_contains "$out" "never inside Claude Code"
}

test_script_survives_the_launchers_round_trip() {
  # The handoffs hash printf '%s\n' "$(the blob)": that must equal the file's own sha256, which
  # holds when the file has no NUL byte and ends with exactly one newline.
  local direct trip
  direct="$(shasum -a 256 <"$GT" | cut -d' ' -f1)"
  trip="$(printf '%s\n' "$(cat "$GT")" | shasum -a 256 | cut -d' ' -f1)"
  assert_eq "$trip" "$direct" "sha256 after the launcher's round trip"
  assert_eq "$(tr -d '\000' <"$GT" | wc -c | tr -d ' ')" "$(wc -c <"$GT" | tr -d ' ')" "a NUL byte"
}

test_sourcing_does_not_run_main() {
  local out rc=0
  out="$(CLAUDECODE=1 bash -c 'source "$1"; echo sourced-ok' _ "$GT" 2>&1)" || rc=$?
  assert_exit 0 "$rc"
  assert_contains "$out" "sourced-ok"
}

test_expected_table_matches_the_plan() {
  load
  local id
  for id in B1 B2 B3 B4a B4b B6 B7 B8 B9 B10 B14a B14b M1 M3 M5a M5b; do
    assert_eq "$(expect "$id" open)" allowed "$id open"
    assert_eq "$(expect "$id" protected)" refused "$id protected"
    assert_eq "$(expect "$id" ruleset)" refused "$id ruleset"
  done
  for id in B5 B12 B13 M4; do
    assert_eq "$(expect "$id" open)" refused "$id open (GitHub's fixed rule)"
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

test_every_test_in_the_run_has_an_expectation() {
  # The ids cmd_tests runs are exactly the ones the table above covers.
  local ran
  ran="$(grep -E '^  t_' "$GT" | tr ';' '\n' | sed -E 's/^ *t_//; s/ *$//' | LC_ALL=C sort | tr '\n' ' ')"
  assert_eq "$ran" "B1 B10 B11 B12 B13 B14a B14b B16 B2 B3 B4a B4b B5 B6 B7 B8 B9 M1 M2 M3 M4 M5a M5b M6 "
}

test_record_judges_results() {
  load
  PHASE=protected
  FAILS=0
  local out
  out="$(record B1 refused "GH006"; echo "fails=$FAILS")"
  assert_contains "$out" "RESULT B1 protected PASS"
  assert_contains "$out" "fails=0"
  out="$(record B1 allowed "pushed"; echo "fails=$FAILS")"
  assert_contains "$out" "RESULT B1 protected FAIL"
  # Inconclusive is never a pass, even where "any" result is acceptable.
  PHASE=open
  out="$(record B11 inconclusive "HTTP 503"; echo "fails=$FAILS")"
  assert_contains "$out" "RESULT B11 open FAIL"
  assert_contains "$out" "fails=1"
  PHASE=protected
  out="$(setup_fail B8 "could not advance dev"; echo "fails=$FAILS")"
  assert_contains "$out" "RESULT B8 protected FAIL"
  assert_contains "$out" "observed=setup-failed"
}

test_classify_push() {
  load
  LAST_RC=0 LAST_OUT="ok"
  assert_eq "$(classify_push)" allowed
  LAST_RC=1 LAST_OUT="remote: error: GH006: Protected branch update failed for refs/heads/dev."
  assert_eq "$(classify_push)" refused "GH006"
  LAST_RC=1 LAST_OUT="remote: error: GH013: Repository rule violations found for refs/heads/main."
  assert_eq "$(classify_push)" refused "GH013"
  LAST_RC=128 LAST_OUT="fatal: unable to access 'https://github.com/x/y.git/': Could not resolve host: github.com"
  assert_eq "$(classify_push)" inconclusive "network failure"
  LAST_RC=1 LAST_OUT="remote: Invalid username or token."
  assert_eq "$(classify_push)" inconclusive "bad credentials"
}

test_classify_api() {
  load
  LAST_RC=0 LAST_OUT="{}"
  assert_eq "$(classify_api)" allowed
  LAST_RC=1 LAST_OUT="gh: Not Found (HTTP 404)"
  assert_eq "$(classify_api)" refused "404"
  LAST_RC=1 LAST_OUT="gh: Must have admin rights to Repository. (HTTP 403)"
  assert_eq "$(classify_api)" refused "403"
  LAST_RC=1 LAST_OUT="gh: Validation Failed (HTTP 422)"
  assert_eq "$(classify_api)" inconclusive "422 is not an authorisation refusal"
  LAST_RC=1 LAST_OUT="HTTP 503 Service Unavailable"
  assert_eq "$(classify_api)" inconclusive "503"
}

test_helper_merge_needs_a_blocked_mergeable_pr_to_count_as_refused() {
  load
  PHASE=protected
  sleep() { :; }
  helper_gh() { echo "X Pull request is not mergeable: the base branch policy prohibits the merge." >&2; return 1; }
  pr_view() {
    case "$2" in
      mergeable) echo MERGEABLE ;;
      *) echo "$FAKE_FACTS" ;;
    esac
  }
  FAKE_FACTS="OPEN MERGEABLE BLOCKED REVIEW_REQUIRED"
  helper_merge B6 7 --squash
  assert_eq "$OBS" refused "blocked by protection"
  FAKE_FACTS="OPEN MERGEABLE CLEAN APPROVED"
  helper_merge B6 7 --squash
  assert_eq "$OBS" inconclusive "open but not blocked: something else went wrong"
  pr_view() { return 1; }
  helper_merge B6 7 --squash
  assert_eq "$OBS" inconclusive "state unreadable (network)"
  assert_contains "$LAST_OUT" "never settled"
}

test_redact_hides_the_token() {
  load
  TOKEN="$(fake_token)"
  local out
  out="$(say "remote said: bad credentials for $TOKEN (again $TOKEN)")"
  assert_not_contains "$out" "$TOKEN"
  assert_contains "$out" "[REDACTED]"
  out="$( die "oops $TOKEN" 2>&1 )" || true
  assert_not_contains "$out" "$TOKEN" "die redacts too"
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

  secrets frg-helper "$(fake_token)"
  chmod 755 "$T_TMP"
  rc=0; out="$( load_helper token 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "secrets folder not mode 700"
  assert_contains "$out" "must be mode 700"
  chmod 700 "$T_TMP"

  rm -f "$T_TMP/helper.env"
  ln -s /etc/hosts "$T_TMP/helper.env"
  rc=0; out="$( load_helper token 2>&1 )" || rc=$?
  assert_exit 2 "$rc" "symlinked secrets file"
}

test_helper_gh_passes_the_token_only_in_the_environment() {
  load
  fake_tools
  TOKEN="$(fake_token)"
  WORK="$T_TMP/work"
  GITHUB_TOKEN=should-be-unset helper_gh api user --jq .login >/dev/null
  assert_eq "$(grep '^gh-token-set:' "$FAKE_LOG")" "gh-token-set:yes"
  assert_eq "$(grep '^gh-github-token-set:' "$FAKE_LOG")" "gh-github-token-set:" "GITHUB_TOKEN reached the helper's gh"
  assert_eq "$(grep '^gh-config-dir:' "$FAKE_LOG")" "gh-config-dir:$T_TMP/work/gh-helper" "the owner's gh config"
  assert_not_contains "$(grep '^gh-args:' "$FAKE_LOG")" "$TOKEN" "token in gh's arguments"
}

test_owner_gh_never_uses_a_token_variable() {
  load
  fake_tools
  GH_TOKEN=leaked GITHUB_TOKEN=leaked GH_CONFIG_DIR=/elsewhere owner_gh api user --jq .login >/dev/null
  assert_eq "$(grep '^gh-token-set:' "$FAKE_LOG")" "gh-token-set:" "GH_TOKEN reached the owner's gh"
  assert_eq "$(grep '^gh-github-token-set:' "$FAKE_LOG")" "gh-github-token-set:" "GITHUB_TOKEN reached the owner's gh"
  assert_eq "$(grep '^gh-config-dir:' "$FAKE_LOG")" "gh-config-dir:" "GH_CONFIG_DIR redirected the owner's gh"
}

test_helper_git_is_isolated_from_the_owners_git_config() {
  load
  fake_tools
  TOKEN="$(fake_token)"
  HELPER=frg-helper
  WORK="$T_TMP/work"
  mkdir -p "$WORK"
  GIT_COMMON_DIR=/tmp/x GIT_TEMPLATE_DIR=/tmp/y GIT_DIR=/tmp/z helper_git status
  local log
  log="$(cat "$FAKE_LOG")"
  assert_contains "$log" "git-global:/dev/null nosystem:1 prompt:0 askpass:set home:$T_TMP/work/home"
  assert_eq "$(grep '^git-leaked:' "$FAKE_LOG")" "git-leaked:" "a GIT_* variable reached the helper's git"
  assert_contains "$log" "-c credential.helper= "
  assert_contains "$log" "-c core.hooksPath=/dev/null"
  assert_not_contains "$log" "$TOKEN" "token in git's arguments"
}

test_capture_redacts_tool_output() {
  load
  fake_tools
  TOKEN="$(fake_token)"
  WORK="$T_TMP/work"
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
  others="$(grep -oE 'repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "$GT" || true)"
  assert_eq "$others" "" "a hard-coded repository other than \$REPO"
  assert_eq "$(grep -c 'Thebigtuna88/forge"' "$GT" || true)" "0" "FORGE itself is named"
}

run_tests
