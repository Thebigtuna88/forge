# FORGE — phased build plan

- **Status:** APPROVED by the owner, 2026-10-15
- **Date:** 2026-10-15
- **Spec:** `docs/specs/2026-10-15-harness-design.md` (APPROVED)

Phase 1 is planned step by step. Phases 2–7 are planned at ticket level, and each gets a
detailed addendum (`docs/plans/<date>-phase-<n>.md`) at its start, built on what earlier phases
taught. Every step that needs the owner is an owner handoff (spec section 4), never prose.

---

## Tickets (GitHub issues, created in this order so numbers match)

Issues and PRs share one counter on GitHub, so all twelve issues are created together, right
after the repo exists and **before any PR**. The agent checks that issue #n is titled `FRG-n`.

| Ticket | Title | Phase | Merged by |
|---|---|---|---|
| FRG-1 | Skeleton, charter and handoff runtime | 1 | owner |
| FRG-2 | Hook runtime, mode.json, settings.json, conformance framework | 2 | owner |
| FRG-3 | Git hooks: push, secret-scan, branch format, shared checkout, history rewrite | 2 | owner |
| FRG-4 | GitHub hooks: merge-on-review, self-modification, repo-admin | 2 | owner |
| FRG-5 | Other hooks: live checkout, deploy target, spend, owner-handoff form | 2 | owner |
| FRG-6 | Harness CI (macOS) + required check on dev | 2 | owner |
| FRG-7 | Review runner, reply schema, lens checklists | 3 | owner |
| FRG-8 | status, ticket, worktree, pr.sh, CONTINUE protocol | 4 | agent (if no owner-only paths) |
| FRG-9 | templates/web with all frontend gates and CI | 5 | owner (contains workflows) |
| FRG-10 | new-project scaffolder and projects.json | 5 | agent |
| FRG-11 | Spend: imagegen interface, manual provider, budget wrapper, ledger | 6 | owner |
| FRG-12 | Dry run: projects/dryrun end to end | 7 | umbrella; fixes get their own tickets |

---

## Phase 1 — Skeleton and handoff runtime (FRG-1)

No hooks exist yet, so during Phase 1 the rules hold by the charter alone. The agent follows
them exactly as if the hooks were live.

### 1.1 Local repository (agent)

1. `git init -b main` in `~/code/forge`.
2. Set the identity for this repo only: `user.name Thebigtuna88`,
   `user.email 124747244+Thebigtuna88@users.noreply.github.com` (GitHub's noreply address for
   account id 124747244, looked up from the public API).
3. Write `.gitignore` (`work/`, `projects/`, `.harness/state/`, `.harness/observed.log`,
   `.harness/ledger/`, `.claude/settings.local.json`, `.env*`, `.DS_Store`) and a short
   `README.md`.
4. Root commit (message via `-F`): spec, this plan, `docs/decisions/*`, `.gitignore`,
   `README.md`. Then `git branch dev` and `git switch dev`. The main checkout stays on `dev`
   from now on.

### 1.2 Worktree (agent)

`git worktree add -b feature/FRG-1-skeleton ~/code/forge-worktrees/FRG-1-skeleton dev`.
All Phase 1 code is written there.

### 1.3 Tests first (agent, in the worktree)

1. `tests/lib/assert.sh` (`assert_eq`, `assert_exit`, `assert_contains`, `assert_not_contains`).
2. `tests/run.sh`: shellcheck stage (FAILED with a clear message if shellcheck is missing),
   unit stage, `ALL PASS` / `FAILED (n)` line.
3. `tests/unit/handoff-runtime.test.sh`, `handoff-lint.test.sh`, `handoff-verify.test.sh`
   covering every row of spec 10.3 for handoffs. They run and **fail** first.

### 1.4 Runtime and commands (agent)

1. `.harness/lib/handoff.sh`: refusal checks, `ho_begin`, `ho_check`, `ho_info`,
   `ho_confirm`, `ho_secret_to_file`, `ho_abort`, `ho_end`; sha helpers; `pbcopy` with a
   fallback message if unavailable.
2. `.harness/bin/handoff`: `new`, `ready`, `lint`, `verify`, plus the skeleton template.
3. Tests go green, except the shellcheck stage until shellcheck is installed.

### 1.5 Charter (agent)

`CLAUDE.md`:
- the ten rules (spec section 3) and the command conventions (5.4);
- the owner-handoff protocol (the two-line handoff, never prose);
- "always start Claude Code in `~/code/forge`";
- the `CONTINUE FORGE` protocol (9.3) and the CONTINUE.md rewrite rule.

### 1.6 Handoff A — install tools (owner)

Runs from the worktree's runtime (bootstrap, spec 4.9).
- `ho_check` steps: `brew` present; `brew install gh pnpm gitleaks shellcheck`; install
  `codex` by whatever method its official docs give on that day (the agent checks just before
  writing the script); each tool's `--version`.

### 1.7 Handoff B — logins (owner)

- `gh auth login`: GitHub.com, HTTPS, browser, with scopes `repo`, `workflow`, `read:org`.
  Then `ho_check gh auth status`.
- Choosing codex billing: `ho_confirm` which one (ChatGPT plan or API key). The agent asks the
  owner this **one question** before writing the script, with live prices.
- `codex login` (or `--with-api-key` fed from `ho_secret_to_file`). With an API key, also
  `ho_confirm` that a monthly usage limit is set in the OpenAI dashboard. Then
  `ho_check codex login status`.

### 1.8 Handoff C — create the GitHub repo (owner)

- `gh repo create Thebigtuna88/forge --public --source ~/code/forge --remote origin`.
- `git -C ~/code/forge push origin main` and `git -C ~/code/forge push origin dev`.
- `gh repo edit --default-branch dev --delete-branch-on-merge --enable-squash-merge`, with merge
  commits and rebase merges disabled.
- Branch protection on `main` and `dev` via `gh api -X PUT …/protection` with a JSON file:
  require a PR (0 approvals), `enforce_admins: true`, no force-push, no deletion. **No required
  status check yet.** CI arrives in FRG-6, which adds it through its own handoff.
- `ho_check` each step, plus `gh api …/protection` reads that confirm the settings.

### 1.9 Issues (agent)

`gh issue create` ×12 in the order above. The agent verifies each issue number matches its
`FRG-n` title before any PR is opened.

### 1.10 Review and merge (agent → owner)

1. Push `feature/FRG-1-skeleton`, open the PR into `dev`.
2. Hand-run `codex exec --sandbox read-only` with the code and then the security checklist
   (drafts of the Phase 3 lens files) against the frozen diff. Save to
   `work/FRG-1-skeleton/manual/round-<r>-<lens>.txt`. Check md5/bytes by hand. Log rounds in
   `rounds.log` in the spec's format.
3. Fix → test → re-run until both lenses are CLEAN; on a stall, stop and ask the owner.
4. **Handoff D — owner-merge** (`ho_confirm` the PR, then
   `gh pr merge <n> --squash --match-head-commit <sha>`).
5. Agent: `git -C ~/code/forge pull origin dev`.

### 1.11 Close out (agent)

1. If review changed `handoff.sh`, re-run handoffs A–C on the merged runtime and re-verify
   (spec 4.9).
2. Memory move: the owner restarts Claude Code **in `~/code/forge`**. The agent copies the
   memories from the `~/code` project's memory folder into the new active folder, and confirms
   `MEMORY.md` lists them.
3. Write `.harness/state/CONTINUE.md`.

**Phase 1 exit:** `bash tests/run.sh` → `ALL PASS`; handoffs A–D verified; FRG-1 merged to
`dev`; memories moved.

---

## Phase 2 — Hooks and conformance (FRG-2 … FRG-6)

- **FRG-2:** `hookrt.sh` (init, mode, deny, tokens, simple-command check, git subcommand and
  alias detection); `mode.json`; `self-modification-paths.json`; `deploy-targets.json`;
  `.claude/settings.json`; `conformance` and its fixture layout. Mode-failure tests.
- **FRG-3:** `deny-push-to-protected`, `secret-scan`, `enforce-branch-format`,
  `deny-commit-on-shared-checkout`, `deny-history-rewrite`, with deny and allow fixtures
  (quoting tricks, `-C`, aliases, chaining).
- **FRG-4:** `gate-merge-on-review` (against the `review.md` format of spec 6.6, using test
  fixtures; Phase 3 produces the real thing), `gate-self-modification`, `deny-repo-admin`.
- **FRG-5:** `guard-live-checkout`, `gate-deploy-target`, `gate-spend` (reading a minimal
  `spend-limits.json`), `gate-owner-handoff-form` (observe).
- **FRG-6:** `.github/workflows/ci.yml` (macOS: `tests/run.sh`, shellcheck, gitleaks).
  Handoff: add `ci` as a required status check on `dev` and `main`.
- After FRG-2 merges, the owner restarts Claude Code so the hooks load. Each later merge of
  hooks also needs a restart.
- **Exit:** conformance PASS; each enforce hook shown denying a real attempt in a live
  session, with the transcript saved to `work/`.

## Phase 3 — Review runner (FRG-7)

`review.sh`, `review-lens init|prompt|codex|ingest|verify|defer|finalize`,
`reply.schema.json`, `.harness/lenses/*.md`, findings-hash, stall detection, PR-comment
summary; `gate-merge-on-review` recomputation wired to the real files. **Exit:** the runner
reviews its own PR to CLEAN.

## Phase 4 — Status, worktree, ticket, CONTINUE (FRG-8)

`status` (every part OK or UNKNOWN), `ticket new|list`, `worktree add|remove`, `pr.sh create`;
CONTINUE protocol tested in a fresh session. **Exit:** spec 12, Phase 4 row.

## Phase 5 — Templates and scaffolder (FRG-9, FRG-10)

The agent looks up current stable versions, records them in a decision file, then builds
`templates/web` (all gates in spec 7.2, workflows in 7.3), the `templates/ios` README,
`new-project` (owner handoff per 7.5) and `projects.json`. **Exit:**
`tests/run.sh --templates` ALL PASS.

## Phase 6 — Spend adapter (FRG-11)

`imagegen` interface, `manual` provider, `pnpm imagegen` CLI, budget wrapper + ledger with the
Vitest suite in spec 10.3; `spend-limits.json` with only `manual` enabled. **Exit:** tests pass,
`spend` lens CLEAN.

## Phase 7 — Dry run (FRG-12)

Spec 10.5. Includes a Vercel login handoff (Hobby plan is fine for a throwaway) and an
owner-run production deploy handoff. Every problem found → new FRG ticket → fixed. Then the
owner reviews `observed.log` and decides observe→enforce promotions by PR. **Exit:** spec 1.5
all true.

## Phase 8 — 5:00

Only after Phase 7. Brainstorm first, one question at a time.
