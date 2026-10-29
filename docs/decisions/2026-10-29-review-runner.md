# Decision: the review runner is codex only, owner-only, and keeps evidence beside the diff

- **Date:** 2026-10-28 and 2026-10-29
- **Decided by:** owner (Thebigtuna88), one question at a time while approving the FRG-7 plan
- **Status:** accepted

## Decision

1. **Every lens is run by codex** (2026-10-28). The spec's fallback, a Claude subagent reviewing
   a non-code lens when codex is unavailable, isn't built, and `gate-merge-on-review` refuses a
   lens run by `subagent`. If codex is unavailable, the agent stops and asks the owner.
2. **`.harness/bin/review-lens` and the whole `.harness/lenses/` folder are owner-only**
   (2026-10-29). Future changes to the runner's command, its checklists and the reply schema need
   the owner's merge.
3. **Evidence goes in its own file beside the diff** (2026-10-29), with its own md5 and byte
   count. `verify` checks both files when there is evidence and rejects missing or mismatched
   evidence values; the merge gate's code-only diff comparison is unchanged. Fingerprint checks
   establish file consistency; they don't prove the reviewer read or understood the contents.

## Why

1. The agent would write a subagent's instructions, the subagent is the same model family as the
   agent, and only the fingerprint check would vouch for it.
2. Otherwise a PR that only weakened a checklist or loosened the reply schema could have been
   merged by the agent, and every later review would be weaker.
3. The merge gate recomputes the diff from git alone, so evidence appended to the diff (as in the
   hand-run reviews) would make every real review fail it.

## Not changed

Known limit L12: the runner, its files, codex's home folder and the agent share one macOS user.
FRG-7 stops codex loading instruction files a PR plants (spec 6.3), not text in the reviewed
files trying to steer the reviewer (the prompt says it isn't instructions, which lowers that
risk without removing it), and not what the agent itself could change. It stays open until
FRG-27's tests pass.
