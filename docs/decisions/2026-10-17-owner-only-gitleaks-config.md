# Decision: FORGE's secret-scan rules are owner-only

- Date: 2026-10-17
- Decided by: owner (Thebigtuna88), approving the FRG-3 section of
  `docs/plans/2026-10-16-phase-2.md`
- Status: accepted

## Context

The `secret-scan` gate (FRG-3) runs `gitleaks git --staged` before every commit. gitleaks looks
for rules in several places, including a `.gitleaks.toml` inside the repository being scanned, a
`.gitleaksignore` file and inline `gitleaks:allow` comments. Anyone who can edit the repository
could use those to switch the scan off.

## Decision

The gate always passes `--config .harness/gitleaks.toml` (gitleaks' default rules, owned by
FORGE). It points `--gitleaks-ignore-path` at an empty folder and passes
`--ignore-gitleaks-allow`. `.harness/gitleaks.toml` is added to
`.harness/self-modification-paths.json`.

## Consequences

- Loosening the secret-scan rules needs the owner's merge, just like weakening the gate.
- A false positive is fixed by a PR to `.harness/gitleaks.toml` (an allowlist entry), which the
  owner merges. It is never fixed in the scanned repository.
