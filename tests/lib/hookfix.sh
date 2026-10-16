# shellcheck shell=bash
# shellcheck disable=SC2034 # H, RC, OUT and ERR are read by the test files
# Hook fixtures (spec 10.2): a throwaway harness laid out like ~/code/forge, holding the hook
# runtime, the deploy config and the test-only hooks from tests/fixtures/hooks.

FORGE_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# mk_hook_harness: $T_TMP/code/forge (H) as a git repo on dev, with a sibling forge-worktrees/
# and a private HOME, so no real git config or Claude settings leak in.
mk_hook_harness() {
  H="$T_TMP/code/forge"
  mkdir -p "$H/.harness/lib" "$H/.claude/hooks" "$T_TMP/code/forge-worktrees" "$T_TMP/home"
  cp "$FORGE_SRC/.harness/lib/hookrt.sh" "$H/.harness/lib/"
  cp "$FORGE_SRC/.harness/deploy-targets.json" "$H/.harness/"
  cp "$FORGE_SRC"/tests/fixtures/hooks/*.sh "$H/.claude/hooks/"
  chmod 755 "$H"/.claude/hooks/*.sh
  git -C "$H" init -q -b dev
}

# bash_input <command> [cwd]: the JSON Claude Code sends a PreToolUse hook for a Bash call.
bash_input() {
  jq -n --arg c "$1" --arg d "${2:-$H}" \
    '{session_id: "t", hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}, cwd: $d}'
}

# run_hook <hook> <stdin>: run .claude/hooks/<hook>.sh from inside H with the given input.
# Sets RC, OUT and ERR. Extra environment (PROBE=…, PATH=…) can be passed with `env` by callers.
run_hook() {
  local hook="$1" input="$2"
  shift 2
  OUT="$(cd "$H" && printf '%s' "$input" | env HOME="$T_TMP/home" "$@" "$H/.claude/hooks/$hook.sh" 2>"$T_TMP/stderr")"
  RC=$?
  ERR="$(cat "$T_TMP/stderr")"
}

# gate <command> [cwd]: run sample-gate on a Bash command.
gate() { run_hook sample-gate "$(bash_input "$@")"; }

# probe <what> <command> [cwd]: run the probe hook with PROBE=<what>.
probe() {
  local what="$1"
  shift
  run_hook probe "$(bash_input "$@")" PROBE="$what"
}
