# FORGE — charter

FORGE is a governance harness, not a product. Owner: **Thebigtuna88**. Ticket key: **FRG**.
Design: `docs/specs/2026-10-15-harness-design.md`. Plan: `docs/plans/2026-10-15-harness-plan.md`.
The owner is new to Claude Code: explain each step in plain language and ask **one question at
a time**, with a recommendation.

**Always start Claude Code in `~/code/forge`.** Native memory is per launch folder.

## Rules in force

1. **One ticket, one branch, one worktree.** A ticket is a GitHub Issue on the repo it concerns,
   titled `<KEY>-<n>: <title>` where n is the issue number. Branch `feature/<KEY>-<n>-<slug>` →
   `dev` → `main`. Worktrees live in `~/code/forge-worktrees/<KEY>-<n>-<slug>`. The main
   checkout (`~/code/forge`, and each `projects/<name>`) stays on `dev` and is never edited by hand.
2. **`main` is human-only.** Never push or merge to `main`. `dev` is reached only by a reviewed PR.
3. **Review before merge, every time.** Never review your own diff inline. Required lenses:
   `code` (codex, mandatory, adversarial), `security` (every PR), `frontend` (UI in a web
   project), `ios` (iOS project), `spend` (paid APIs, image gen, payments, `spend-limits.json`).
   Mechanisms `author`, `inline` and `self` are refused.
4. **Read-proof.** A lens reply counts only if the reviewer itself computed and reported the
   diff's md5 and byte count, and they match the runner's own computation.
5. **Rounds are uncapped; the only circuit breaker is a stall.** Fix and re-run until every
   required lens is CLEAN. Log `<utc> <lens> <head-sha> <verdict> <findings-hash>` to
   `rounds.log`. Two identical findings-hashes in a row for a lens → stop and ask the owner.
   Every deferred finding becomes a ticket **before** merge. Blockers are never deferred.
6. **A finding clears only when the fix is demonstrated**: a test that fails without the fix,
   command output, or `file:line`. The same goes for every claim made to the owner.
7. **Limits are the owner's.** Paths in `.harness/self-modification-paths.json` (spend limits,
   deploy targets, mode.json, the paths list itself, `.claude/hooks/`, `.claude/settings.json`,
   `.harness/lib/`, `.github/workflows/`, `.harness/bin/conformance`, `tests/conformance/`,
   `.harness/gitleaks.toml`, this file `CLAUDE.md`, `.harness/bin/handoff`, `docs/specs/`,
   `tests/stubs/`) change only by a PR **the owner** merges.
8. **Test mode until the owner flips it.** Payments run in test mode. Production deploys, App
   Store/TestFlight submissions, DNS changes and anything that charges a card are owner-run
   scripts, never agent actions.
9. **Fail closed, no escape hatch.** If a hook blocks something, fix the code or config through
   a PR. Never route around a guard.
10. **Secrets never enter the chat or git.** Collect them only with `ho_secret_to_file`.
    Every commit is scanned by gitleaks.

## Owner handoffs (spec section 4)

Whenever you are blocked on the owner (install, login, API key, credits, production deploy, a
web-UI click), **write a script, never instructions**:

1. `.harness/bin/handoff new <slug> "<title>"`, then add steps using only `ho_check`,
   `ho_info`, `ho_confirm`, `ho_secret_to_file` and `ho_redact_file`, with `|| ho_abort` before
   anything irreversible. A step that uses a secret stored by an earlier handoff is preceded by
   `ho_redact_file <name> <that file>`, so the value is hidden if printed.
2. `.harness/bin/handoff ready <id>` (it lints and freezes the script).
3. Give the owner **exactly two things**: `bash <full path>/OWNER-RUN.sh` and "paste back the
   HANDOFF-RESULT block". Nothing else.
4. Save the owner's pasted text **verbatim** to `work/owner/<id>/PASTED-<utc>.txt` and run
   `.harness/bin/handoff verify <that file>`. **Do not proceed until verify passes.** Never
   verify `RESULT.txt` or a block you wrote yourself. Never run an OWNER-RUN.sh yourself.

## Command conventions (the hooks parse these)

- Commit: write the message to a file, then `git commit -F <file>`. Never `-m`, `-a`, `--amend`
  or `--no-verify`. Stage with explicit `git add <paths>`.
- `git push`, `git commit`, every `gh` command (reads too) and deploy commands are **single
  simple commands**: one per Bash call, no `&&` `||` `;` `|` `&`, no `$( )`, backticks,
  redirection, `~`, globs or `#`, and nothing in front of the tool (no `NAME=value`, `env`,
  `xargs`). Use `git -C <dir>` instead of `cd … &&`, and `gh … --jq <filter>` instead of piping
  into `jq` (a filter with `|`, `[ ]` or `$` is refused for now, FRG-22). Reads never open a
  browser: no `gh browse`, `--web` or `-w`.
- Text goes to GitHub only as `--title <text>` and `--body-file <file>` (scanned for secrets
  first); never `--body`, `-b`, `--fill` or an editor. PRs: `gh pr create --base dev --head
  feature/<KEY>-<n>-<slug> --title <text> --body-file <file>`. `gh api` only reads (GET).
- Push with an explicit target: `git push -u origin feature/<KEY>-<n>-<slug>`.
- Update a branch in its worktree with `git merge --no-commit dev`, then `git commit -F <file>`
  (the merged result is scanned). Never rebase, amend or force-push.
- Update a main checkout with `git -C /Users/atl/code/forge pull --ff-only origin dev` (an
  absolute path: the gates refuse `~` in guarded commands). It may only fast-forward and never gets
  a commit of its own.
- Merge: `gh pr merge <n> --repo Thebigtuna88/forge --squash --match-head-commit <sha>`, only
  into `dev`, only after review (`work/<KEY>-<n>-<slug>/review.md`, every required lens CLEAN),
  and never a PR that touches an owner-only path.
- No git aliases for guarded commands.

## Where things are remembered

- Rules and conventions: this file.
- Owner preferences, corrections and confirmed approaches: Claude Code native memory, each with
  its **why**. No other memory plugin.
- Durable decisions: `docs/decisions/<date>-<slug>.md`.
- Next action and in-flight reasoning: `.harness/state/CONTINUE.md`, **rewritten** (never
  appended), under 100 lines, before ending a session and whenever the owner says stop, pause or
  wrap up. Headings: Next action (one step) · In flight · Reasoning · Blocked on.

## `CONTINUE FORGE`

When the owner types `CONTINUE FORGE`:
1. Run `.harness/bin/status` (until it exists in Phase 4: `git status`, `git log --oneline -5`
   and `git worktree list` for the harness, the list of `work/owner/*` without `VERIFIED.txt`,
   then `.harness/state/CONTINUE.md`).
2. Report exactly **Where we are**, **Next action** (one step) and **Blocked on**.
3. **Stop and wait.**

If git and CONTINUE.md disagree, trust git and say so. If a command failed, report "state
unknown" for that part, never "nothing open".

## Tests

`bash tests/run.sh` must end with `ALL PASS`. Shell scripts must run on macOS `/bin/bash` 3.2.
