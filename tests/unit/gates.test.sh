#!/usr/bin/env bash
# Tests for the FRG-3 gates that conformance can't reach, because the runtime pins PATH: here the
# runtime copy's PATH line is edited to leave a tool out (spec 10.3).
# shellcheck disable=SC2031 # each test sets and reads T_TMP inside its own subshell (assert.sh)
# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"
# shellcheck source=tests/lib/hookfix.sh
source "$(dirname "$0")/../lib/hookfix.sh"

# mk_gate_harness <hook>: a harness at $T_TMP/code/forge (H) with the runtime, the real hook and
# FORGE's gitleaks rules, a repo with a staged clean file and a message file.
mk_gate_harness() {
  H="$T_TMP/code/forge"
  mkdir -p "$H/.harness/lib" "$H/.claude/hooks" "$T_TMP/home"
  cp "$FORGE_SRC/.harness/lib/hookrt.sh" "$H/.harness/lib/"
  cp "$FORGE_SRC/.harness/deploy-targets.json" "$FORGE_SRC/.harness/gitleaks.toml" "$H/.harness/"
  cp "$FORGE_SRC/.claude/hooks/$1.sh" "$H/.claude/hooks/"
  chmod 755 "$H/.claude/hooks/$1.sh"
  git -C "$H" init -q -b dev
  printf 'hello\n' >"$H/notes.txt"
  git -C "$H" add notes.txt
  printf 'FRG-9: a message\n' >"$T_TMP/msg"
}

# without_tool <tool>: point the runtime copy's PATH at a folder of the usual tools, minus <tool>.
without_tool() {
  local bin="$T_TMP/bin" t
  mkdir -p "$bin"
  for t in bash dirname cat python3 git jq date tr mktemp rm tail shasum md5 awk; do
    [[ "$t" == "$1" ]] || ln -s "$(command -v "$t")" "$bin/$t"
  done
  sed -i '' "s|^PATH=.*|PATH=$bin|" "$H/.harness/lib/hookrt.sh"
}

test_secret_scan_blocks_without_gitleaks() {
  mk_gate_harness secret-scan
  without_tool gitleaks
  run_hook secret-scan "$(bash_input "git commit -F $T_TMP/msg" "$H")"
  assert_exit 2 "$RC"
  assert_contains "$ERR" "BLOCKED by FORGE hook secret-scan: gitleaks is not installed"
}

test_secret_scan_allows_a_clean_commit_with_gitleaks() {
  mk_gate_harness secret-scan
  run_hook secret-scan "$(bash_input "git commit -F $T_TMP/msg" "$H")"
  assert_exit 0 "$RC" "clean commit: $ERR"
}

run_tests
