# Decision: text sent to GitHub is scanned, and four more paths are the owner's

- **Date:** 2026-10-18
- **Decided by:** owner (Thebigtuna88), while approving the FRG-4 plan section
- **Status:** accepted

## Decision

1. **Text reaches GitHub only from places the gates can scan.** In every ticket and PR command
   the agent runs, a title goes in `--title` and longer text only in a file named by
   `--body-file`. The whole command and every body file are scanned by gitleaks with FORGE's
   rules before anything is sent. Inline `-b`/`--body`, `--fill` and editor modes are refused.
   At merge time, everything GitHub may write into the squash commit (the PR's title and body as
   they are then, its commit messages and authors) is scanned again.
2. **Four paths join the owner-only list** (`.harness/self-modification-paths.json`). The first
   three were decided with the plan section; the fourth during the build, asked as a scope
   change:
   - `CLAUDE.md`: the charter. A gate can't tell a rule change from a typo fix, so the whole
     file.
   - `.harness/bin/handoff`: its `verify` decides whether the owner's pasted evidence is
     accepted. Its runtime (`.harness/lib/handoff.sh`) was already owner-only; this file wasn't.
   - `docs/specs/`: the approved design.
   - `tests/stubs/`: the fake `gh` and the scene helper the merge gates' conformance cases run
     on. Changing them changes what those cases prove, as changing `tests/conformance/` (already
     owner-only) would.

## Why

FRG-4 is what lets the agent merge some PRs itself, so this is when to settle what stays the
owner's. The repository is public, so anything sent to GitHub (a title, a comment) is published
the moment it is sent, and a secret in it can't be taken back. Rule 10 already keeps secrets out
of git, but text sent through `gh` never passes a commit scan.

## Not added

- `docs/plans/` and `docs/decisions/`: almost every ticket adds to them, so every PR would
  become the owner's to merge.
- `.gitattributes` and `.gitmodules`: first proposed because a hook with Windows line endings
  might crash. Tested 2026-10-18: such a hook exits 2, which blocks; and submodules are already
  refused by the FRG-3 gates.
