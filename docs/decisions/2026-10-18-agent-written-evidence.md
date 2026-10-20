# Decision: evidence the agent writes is a known limit, not something the gates can prove

- **Date:** 2026-10-18
- **Decided by:** owner (Thebigtuna88), during FRG-4's review (round 1, findings SEC-1 and SEC-3)
- **Status:** accepted

## Decision

Accept as a known limit (spec 11, L12):

1. **Review evidence can be forged by the agent.** `gate-merge-on-review` re-checks everything it
   can: `review.md`'s binding to the PR, the diff recomputed from GitHub's `dev` and head, each
   reply's sha256 and read-proof. That proves which code a review describes, not that a reviewer
   wrote it. The agent could write CLEAN replies and a matching `review.md` itself.
2. **A body file can be swapped after its scan.** A second command running at the same moment
   could replace a `--body-file` between `deny-repo-admin`'s scan and `gh` sending it.

## Why

The agent, the review runner and every file they use share one macOS user, so anything on disk
is within the agent's reach. That is the same family as the accepted L1 (commands hidden in
scripts) and L4 (the paste file). Both need a deliberately dishonest agent. The gates are
guardrails against mistakes and shortcuts, and both shortcuts break charter rules 3, 6 and 9.
The code can't close this; only a separate identity can.

## Mitigation now

- Every PR touching an owner-only path is merged by the owner (`gate-self-modification`).
- Review summaries are posted on the PR, so a lasting record exists on GitHub.
- Before FRG-4, nothing at all stopped `gh pr merge`, so the gate is a strict improvement.

## Stronger options later

Run the agent (and codex) as separate macOS users, or give the agent a GitHub machine account
whose merges need the owner's approval (spec 11, L2).

## Correction

The FRG-4 plan section said that until FRG-7, "no review file passes the gate." That holds only
for an honest agent: a hand-written `review.md` with real codex replies (as made by hand in
Phases 1–2) passes. So does a forged one, which is this limit.
