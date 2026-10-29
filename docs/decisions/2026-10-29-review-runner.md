# Decision: the review runner is codex only, owner-only, and keeps evidence beside the diff

- **Date:** 2026-10-28 and 2026-10-29 (two decisions that day)
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
4. **The `spend` lens reviews every PR** (2026-10-29, after FRG-7 review round 3). The detection
   that decided when it was required is removed. A CLEAN codex spend review is required on every
   PR, and both the runner and the merge gate refuse a computed lens list without `code`,
   `security` and `spend`, so neither a review nor an edit to the computation can leave it out.

## Why

1. The agent would write a subagent's instructions, the subagent is the same model family as the
   agent, and only the fingerprint check would vouch for it.
2. Otherwise a PR that only weakened a checklist or loosened the reply schema could have been
   merged by the agent, and every later review would be weaker.
3. The merge gate recomputes the diff from git alone, so evidence appended to the diff (as in the
   hand-run reviews) would make every real review fail it.
4. The detection guessed from paths, hosts, key names, tools and SDK packages. Each of review
   rounds 1, 2 and 3 found a provider or SDK it missed, and each fix closed one case; a list can't
   know every provider. Requiring the lens closes the whole class, at the cost of one more codex
   run per round (run alongside the others) and a little more of the Codex allowance. The same
   choice as FRG-4's gh reads (`2026-10-19-gh-reads-plain.md`): a smaller rule instead of patching
   trick by trick.

## Not changed

Known limit L12: the runner, its files, codex's home folder and the agent share one macOS user.
FRG-7 stops codex loading instruction files a PR plants (spec 6.3), not text in the reviewed
files trying to steer the reviewer (the prompt says it isn't instructions, which lowers that
risk without removing it), and not what the agent itself could change. It stays open until
FRG-27's tests pass.
