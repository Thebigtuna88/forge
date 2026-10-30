# Decision: harness CI runs on every PR, but isn't required until FRG-34

- **Date:** 2026-10-27
- **Decided by:** owner (Thebigtuna88)
- **Status:** in force from FRG-6's merge until FRG-34 (#34) is done
- **Related:** spec 11 L15; FRG-26 checkpoint; plan `docs/plans/2026-10-16-phase-2.md`, FRG-6

## Context

The plan had FRG-6 add the CI workflow and, through an owner handoff, make `ci` a required status
check on `dev` and `main`. That second part changes FORGE's branch protection on GitHub, and the
owner's limits allow no change to FORGE's settings before the FRG-26 checkpoint. FRG-26 also
plans its own change to `dev`'s protection (the owner's code-owner approval, D5).

## Decision

- **FRG-6** adds `.github/workflows/ci.yml` only. It changes no GitHub setting.
- **FRG-34** makes passing CI and the owner's approval required on `dev` and `main`, in one owner
  handoff after the FRG-26 checkpoint, keeping every existing protection rule (snapshot in #34).

## What this means until FRG-34

- **A failing CI run does not technically block merging** into `dev` or `main`. Nothing on GitHub
  requires the check. A red PR can still be merged by anyone who can merge today.
- What stands in the way: the owner merges every PR that touches an owner-only path; each
  owner-merge handoff checks the PR's CI result for the exact head being merged and stops
  (`ho_abort`) if it isn't green; and `bash tests/run.sh` → `ALL PASS` on the owner's Mac is
  still required before any merge (charter, Tests). Those are practice and scripts, not GitHub
  rules.
- **A green CI run never replaces the local run.** GitHub's runners have no Claude Code, so
  conformance prints `SKIP Claude Code version` there; the runner is also one macOS major version
  behind the owner's Mac.

## Alternatives not taken

- **Require the check now.** That changes FORGE's settings before the FRG-26 checkpoint, which
  the owner ruled out, and would change `dev`'s protection twice.
- **Wait with CI until FRG-34.** CI costs nothing on a public repository and shows breakage on
  GitHub's Macs now, so there's no reason to wait.
