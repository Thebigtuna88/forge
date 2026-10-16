# Decision: the owner's paste is captured by a hook, not written by the agent

- Date: 2026-10-16
- Decided by: owner (Thebigtuna88)
- Status: accepted (implementation in FRG-5)

## Context

The FRG-1 security review (codex, round 1, finding S1, severity blocker) showed that
`handoff verify` only checks that agent-writable files agree with each other. The agent writes
the paste file, can read the runtime and the script, and so could fabricate a matching
`RESULT.txt` and `PASTED-*.txt` without the owner running anything. Spec 11 already listed this
as limits L3 (terminal checks are a speed bump) and L4 (the agent writes the paste file).
Blockers can't be deferred, so the owner decided.

Options put to the owner:

- **A.** A `UserPromptSubmit` hook, which runs on the owner's own messages, saves any pasted
  HANDOFF-RESULT block itself; a guard stops the agent writing evidence files; verify accepts
  only hook-captured pastes.
- **B.** Accept L3/L4 as written: the owner's visible paste in the chat is the proof.
- **C.** Run the agent as a separate macOS user that can't touch handoff folders.

## Decision

**A**, built in FRG-5 (scope added to issue #5). FRG-1 merges with S1 accepted for the
bootstrap period, because handoffs A–C were pasted visibly in the chat.

## Consequences

- Until FRG-5 merges, the agent still saves pastes by hand, verbatim (charter, spec 4.1).
- After FRG-5, the paste file and `.harness/state/pastes.log` come only from the hook, so a
  fabricated paste has no matching hook record.
- Residual gap: an agent with a shell could still write those files through an indirect
  command (spec 11 L1). The hook makes forgery deliberate and visible, not impossible.
  Option C stays available as the stronger fix.
