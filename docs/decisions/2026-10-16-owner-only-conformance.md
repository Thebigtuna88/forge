# Decision: the conformance checker and its cases are owner-only

- Date: 2026-10-16
- Decided by: owner (Thebigtuna88), approving the FRG-2 section of
  `docs/plans/2026-10-16-phase-2.md`
- Status: accepted

## Context

Spec 2.2 lists the owner-only paths (rule 7): spend limits, deploy targets, `mode.json`, the
list itself, `.claude/hooks/`, `.claude/settings.json`, `.harness/lib/` and
`.github/workflows/`. `conformance` (spec 5.5) is what proves the hooks deny what they should,
and `tests/run.sh` relies on it for `ALL PASS`. The agent may merge any reviewed PR that touches
no owner-only path (spec 12).

## Decision

Add `.harness/bin/conformance` and `tests/conformance/` to
`.harness/self-modification-paths.json`.

## Consequences

- Weakening the checker, or deleting a "must deny" case, now needs the owner's merge, just like
  weakening a hook. Otherwise a broken gate could be made to look healthy without the owner.
- Every PR that adds or changes a conformance case (FRG-3, FRG-4, FRG-5 and later hook work) is
  owner-merged. Those PRs touch `.claude/hooks/` anyway, so this adds no new owner handoffs.
- `CLAUDE.md` rule 7 lists the two paths.
