# shellcheck shell=bash
# shellcheck disable=SC2034 # H, HANDOFF, SCRIPT, OUT and RC are read by the test files
# Test fixtures: a throwaway harness copy with its own git repo, and a pty runner (spec 10.2).

FORGE_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TESTLIB="$FORGE_SRC/tests/lib"
STUBS="$FORGE_SRC/tests/stubs"

# mk_harness: copy the handoff runtime, its redaction filter and the tool into $T_TMP/h, a fresh
# git repo where work/, .env and .env.* are gitignored (as in the real repo). Sets H (harness
# root) and HANDOFF (the tool).
mk_harness() {
  H="$T_TMP/h"
  mkdir -p "$H/.harness/lib" "$H/.harness/bin"
  cp "$FORGE_SRC/.harness/lib/handoff.sh" "$H/.harness/lib/"
  cp "$FORGE_SRC/.harness/lib/handoff_grammar.py" "$H/.harness/lib/"
  cp "$FORGE_SRC/.harness/lib/handoff_redact.py" "$H/.harness/lib/"
  cp "$FORGE_SRC/.harness/bin/handoff" "$H/.harness/bin/"
  git -C "$H" init -q
  printf 'work/\n.env\n.env.*\n' >"$H/.gitignore"
  HANDOFF="$H/.harness/bin/handoff"
}

# mk_script <id> <step lines…>: write a well-formed OWNER-RUN.sh directly (no lint/ready), and
# make it read-only and record it in a ready META.json, as `handoff ready` would (the runtime
# refuses anything else).
mk_script() {
  local id="$1" dir
  shift
  dir="$H/work/owner/$id"
  mkdir -p "$dir"
  rm -f "$dir/OWNER-RUN.sh"
  {
    printf '#!/usr/bin/env bash\n# HANDOFF: %s — test\nset -uo pipefail\n' "$id"
    printf '# shellcheck source=/dev/null\nsource "%s"\nho_begin "%s"\n' "$H/.harness/lib/handoff.sh" "$id"
    printf '%s\n' "$@"
    printf 'ho_end\n'
  } >"$dir/OWNER-RUN.sh"
  chmod 444 "$dir/OWNER-RUN.sh"
  jq -n --arg id "$id" --arg sha "$(shasum -a 256 "$dir/OWNER-RUN.sh" | awk '{print $1}')" \
    '{id: $id, state: "ready", script_sha256: $sha, readied: "2000-01-01T00:00:00Z"}' >"$dir/META.json"
  SCRIPT="$dir/OWNER-RUN.sh"
}

# record_paste <file>: what capture-owner-paste adds for a paste it saved (FRG-5): a line in the
# harness's .harness/state/pastes.log naming the file and its sha256.
record_paste() {
  local file="$1"
  mkdir -p "$H/.harness/state"
  printf '2026-01-01T00:00:00Z %s %s %s\n' "$(basename "$(dirname "$file")")" "${file#"$H"/}" \
    "$(shasum -a 256 "$file" | awk '{print $1}')" >>"$H/.harness/state/pastes.log"
}

# pty_run [--answer X]... -- <script>: run as the owner would, in a terminal, outside the agent.
# Sets OUT (terminal output) and RC (exit status).
pty_run() {
  OUT="$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CODEX_SANDBOX -u CODEX_SANDBOX_NETWORK_DISABLED \
    PATH="$STUBS:$PATH" STUB_CLIPBOARD="$T_TMP/clipboard" \
    python3 -I "$TESTLIB/ptyrun.py" "$@")"
  RC=$?
}

# pty_run_as_agent: same, but with the agent marker set.
pty_run_as_agent() {
  OUT="$(env CLAUDECODE=1 PATH="$STUBS:$PATH" STUB_CLIPBOARD="$T_TMP/clipboard" \
    python3 -I "$TESTLIB/ptyrun.py" "$@")"
  RC=$?
}
