# Decision: a stalled part 0 or restore step is an accepted limit, for FRG-26 stage 1 only

- **Date:** 2026-11-24
- **Decided by:** owner (Thebigtuna88), after review-lens rounds 85-91
- **Status:** accepted as a known limit, in the scope below only; closes review-lens round 86's
  finding 3 (code C3 = security SEC-2) for that scope
- **Follow-up:** FRG-38 (#38): a deadline for a step that hangs, added to its record by an owner
  handoff. Recording it doesn't authorize implementation.

## The limit

The handoff runtime (`.harness/lib/handoff.sh`, `_ho_run`) waits for each step with no deadline.
The FRG-26 script bounds its own work: each GitHub call 20 s, a push 60 s, a clone 120 s, and the
clean-up 180 s (`tests/permissions/github-throwaway.sh`, CALL_SECS and CLEANUP_SECS). Nothing bounds
the runtime's wait around a step. A step that neither ends nor fails leaves the run sitting at its
▶ line with no ✔ or ✘. That can happen, for example, when a leftover process holds the step's output
open, or when the live filter or a runtime helper blocks.

A stalled step is not a runtime failure, an interrupt, a closed window or an ended process, so the
limit accepted on 2026-11-22 doesn't cover it. Nothing in the run notices a stall: only the owner,
watching, can.

## Scope

Covered: the part 0 handoff (frg26-stage1-open) and its restore handoff (frg26-restore-protection),
in this stage 1 sequence, on the first throwaway's protection (forge-frg26-throwaway: dev, main and
its rulesets).

Not covered: FORGE itself, the broker, 5:00 and any other handoff, the age-token handoff included.
Extending this needs a separate decision.

## Recovery

1. A step's ▶ line shows for 30 minutes with no ✔ or ✘. That is a time to step in, not proof of a
   hang. Press Ctrl-C once, then wait 10 minutes: the clean-up takes up to about 3 minutes, and part
   0 may then put the protection back itself. A second stop is allowed, but it can cut the clean-up
   or the restoration short.
2. Leave the window as it is. Tell Claude Code how the run ended, and paste back the result if
   there is one.
3. Restart the Mac before the next FRG-26 handoff, always. A restart ends what runs on the Mac, but
   not writes GitHub already received.
4. Claude Code checks only GitHub, with read-only requests on the two throwaways. There is no
   automated local inspection. The run's logs and notes are kept for review later, by a separate
   decision. Missing evidence stays unknown.
5. Restoring:
   - without a pass, run the frozen restore handoff when Claude Code says;
   - after a pass, run it only if a fresh read shows the protection changed and the owner approves.
   These are procedural steps; the handoff can't check them.
6. If the restore fails, or its read-back doesn't confirm, the protection is unconfirmed. A recovery
   is proposed before anything else, and it is never called restored.
7. Leftovers found are reported to the owner: test PRs, issues, tokens not confirmed revoked.

## Risks accepted with it

- **Unbounded recovery.** There is no automatic timeout, and 30 minutes is not a bound. The first
  throwaway's protection may stay off until recovery confirms it.
- **Delayed GitHub writes.** Writes GitHub already received, the run's own or the app's B12 and M4
  attempts, can change the protection after any read-back, and a restart doesn't cancel them. Some
  writes (clean-up, probe, token requests) leave no in-flight note.
- **Snapshots.** Read-backs are separate reads, one after another, not one instant. Protect can
  overwrite a change that reaches GitHub after a branch's last read. A ruleset added and removed
  between two counts is seen by neither.
- **Partial protection.** A stop during protect can leave one branch protected and the other not.
- **Unknown token expiry.** A token requested during a hang may be issued and never received. Its
  expiry is unknown, an hour from an issue time the run can't know, and it can't be revoked from
  here. It carries at most what was requested.
- **Armed auto-merge.** A test PR can stay open with auto-merge armed (B11) when the clean-up is cut
  short.
- **Unidentified leftovers.** Not every leftover can be identified: a write left without an answer,
  a token never received, or a PR or issue made just before a check can be missed.

The app's private key and its tokens are real credentials. They are limited to the app's installation
and its four permissions, but they are not dummies. The throwaway repository holds no real code.

## Why accepted

The exposure is the first throwaway's protection. The recovery is defined, and is the same one used
for limit 1. A runtime deadline would shorten how long a hang goes unnoticed, but not the GitHub-side
risks above, which remain either way. It is deferred to FRG-38.

## Alternatives not taken

- A runtime step deadline before part 0: an owner-only change to `.harness/lib/` through its own PR
  and review. Deferred to FRG-38.
- A stage 1 design that never removes the protection: it would no longer test the open phase.
- Leaving stage 1 paused.
