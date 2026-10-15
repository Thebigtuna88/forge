# FORGE

A governance harness for AI-assisted development. FORGE holds no product. It sets what the AI
agent (Claude Code) may do on its own, requires an independent adversarial review (codex)
before any code merges, carries memory between sessions, and turns anything that needs the
owner into a script the owner runs and whose output they paste back.

- **Design:** [`docs/specs/2026-10-15-harness-design.md`](docs/specs/2026-10-15-harness-design.md)
- **Plan:** [`docs/plans/2026-10-15-harness-plan.md`](docs/plans/2026-10-15-harness-plan.md)
- **Decisions:** [`docs/decisions/`](docs/decisions/)
- **Rules for the agent:** `CLAUDE.md`

Branches: `feature/FRG-<n>-<slug>` → `dev` (reviewed PRs) → `main` (owner only).

Resume a session by starting Claude Code in this folder and typing `CONTINUE FORGE`.
