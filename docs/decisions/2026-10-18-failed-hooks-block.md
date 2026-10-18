# Decision: a hook that fails blocks the command

- **Date:** 2026-10-18
- **Decided by:** owner (Thebigtuna88)
- **Status:** accepted (implementation in FRG-20, before FRG-4)

## Context

Claude Code blocks a tool call only when a `PreToolUse` hook exits 2. Its hooks documentation
(code.claude.com/docs/en/hooks, read 2026-10-18) says any other exit code, a hook that can't
start, and a hook that reaches its timeout (default 600 seconds) are non-blocking errors: the
call goes ahead. FORGE's runtime (`hookrt.sh`, FRG-2) already turns every failure *inside* a
running hook into exit 2, but it can't help a hook that never runs. Checked on this Mac: a hook
without execute permission exits 126 and a missing one 127, both non-blocking. A hook with
Windows line endings exits 2 (bash rejects `-p\r`), which already blocks.

Claude Code 2.1.295 added `"onFailure": "block"`. With it, failing to start, any exit code other
than 0 or 2, a timeout and invalid output all block the call, as exit 2 does. The field has no
effect on `Stop`, `SubagentStop`, `TaskCompleted` and `TeammateIdle` hooks, or on async hooks.

Found while planning FRG-4.

## Decision

- Every FORGE hook is registered with `"onFailure": "block"` and `"timeout": 120`.
- Conformance fails when a registered hook (other than the exempt events) lacks either, when a
  registration holds any other key (`async`, `asyncRewake`, `if`, …, which change whether a gate
  runs or blocks), or when any installed Claude Code (on `PATH`, `~/.local/bin`,
  `~/.claude/local`) is older than 2.1.295, none is found, or a version can't be read. Each
  `claude --version` runs in a sandbox that can't write files, send signals or start processes,
  with a 15-second limit (review rounds 1 and 3).
- A separate small ticket (FRG-20), merged before FRG-4, so the five FRG-3 gates are covered at
  once.

## Consequences

- A hook file made non-executable, deleted, stuck or killed now blocks every Bash command. That
  is loud and safe instead of quiet and open. Fixing it is an owner-merged PR (rule 9).
- The version check is skipped on GitHub Actions (both `CI` and `GITHUB_ACTIONS` true), which
  doesn't run Claude Code. Tests point it at a fake `claude` with `FORGE_TEST_CLAUDE`. Both are
  printed (`SKIP` / `NOTE`) and can only change conformance's report, not what a hook does.
  `tests/run.sh` clears `FORGE_TEST_CLAUDE` for its real run.
- Unregistering a hook or editing hook files in the main checkout is still FRG-5's
  main-folder guard (spec 5.3).

## Alternative not taken

Fold the change into FRG-4, which edits `settings.json` anyway. One fewer owner merge, but the
existing gates would stay exposed until FRG-4's much larger review finished.
