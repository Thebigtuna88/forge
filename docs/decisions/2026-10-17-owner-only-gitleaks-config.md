# Decision: FORGE's secret-scan rules are owner-only

- Date: 2026-10-17
- Decided by: owner (Thebigtuna88), approving the FRG-3 section of
  `docs/plans/2026-10-16-phase-2.md`
- Status: accepted

## Context

The `secret-scan` gate (FRG-3) runs gitleaks before every commit. gitleaks looks
for rules in several places, including a `.gitleaks.toml` inside the repository being scanned, a
`.gitleaksignore` file and inline `gitleaks:allow` comments. Anyone who can edit the repository
could use those to switch the scan off.

## Decision

The gate reads the staged files as raw blobs from git's index and scans them, and the message
file, with `gitleaks dir`. It always passes `--config .harness/gitleaks.toml` (gitleaks' default
rules, owned by FORGE) and `--ignore-gitleaks-allow`, and it points `--gitleaks-ignore-path` at an
empty folder of its own. `.harness/gitleaks.toml` is added to
`.harness/self-modification-paths.json`.

## Consequences

- Loosening the secret-scan rules needs the owner's merge, just like weakening the gate.
- A false positive is fixed by a PR to `.harness/gitleaks.toml` (an allowlist entry), which the
  owner merges. It is never fixed in the scanned repository.
