# FORGE — harness design spec

- **Status:** APPROVED by the owner, 2026-10-15 (all 12 sections, section by section)
- **Date:** 2026-10-15
- **Owner:** Thebigtuna88
- **Repo:** `Thebigtuna88/forge` (default branch `dev`)

## Contents

1. Purpose, scope and terms
2. Repository layout
3. Rules in force (the charter)
4. Owner handoffs
5. Hooks (the gates) and command conventions
6. Review runner and lenses
7. Stacks, templates and the project scaffolder
8. Paid APIs, image generation and budget
9. Memory and continuity
10. Testing and conformance
11. Known limits (what the harness does *not* protect against)
12. Build order

---

## 1. Purpose, scope and terms

### 1.1 What FORGE is

FORGE is a **governance repository**. It contains no product. It decides:

- what the AI agent may do on its own and what only the owner may do;
- that every change gets an **independent, adversarial review** (by a different model, codex)
  before it merges;
- how memory and context carry over from one session to the next;
- how anything that needs the owner (installs, logins, keys, payments, production releases)
  becomes a **script the owner runs**, whose output the owner pastes back as evidence.

Every later project (the first is **5:00**, a clothing brand) lives in its own GitHub repo,
cloned under `projects/`, and is governed by FORGE's rules, hooks and review runner.

### 1.2 What FORGE is not

- **Not a product.** Product code never goes in the FORGE repo itself.
- **Not a security sandbox.** The hooks stop the agent from making *mistakes* and from taking
  shortcuts through the normal commands. They cannot stop a determined program that has a shell,
  including a command deliberately disguised from them (L13).
  Section 11 lists the gaps honestly. The real backstops are GitHub server-side branch
  protection, the owner-only `main` branch, and the owner's own review of self-modification PRs.

### 1.3 Terms

| Term | Meaning |
|---|---|
| **Owner** | The human (Thebigtuna88). The only one who merges to `main`, changes limits, spends money, or ships to production. |
| **Agent** | Claude Code working in this repo. |
| **Ticket** | A GitHub Issue titled `FRG-<n>` (or `<PROJECTKEY>-<n>` in a project repo). One unit of work. |
| **Worktree** | A second checkout of the same repo in its own folder, so each ticket's work is isolated. Lives in `~/code/forge-worktrees/`. |
| **Hook / gate** | A script Claude Code runs automatically before or after a tool call. It can **deny** the call (exit code 2). |
| **enforce / observe** | A hook in *enforce* mode denies. In *observe* mode it only logs what it would have denied. |
| **Lens** | One kind of review (code, security, frontend, ios, spend), each with its own checklist. |
| **Read-proof** | The reviewer reports the diff's md5 and byte count *computed by itself*, which proves it actually read the diff. |
| **Owner handoff** | A generated `OWNER-RUN.sh` script for something only the owner can do. It prints a HANDOFF-RESULT block (with checksums of the script and runtime) that the owner pastes back. |
| **CLEAN** | A lens verdict with zero open findings. |

### 1.4 Facts recorded so far

| Item | Value |
|---|---|
| Harness name / ticket key | **FORGE** / **FRG** |
| Resume command | `CONTINUE FORGE` |
| GitHub | `Thebigtuna88/forge` (account verified to exist; repo name free) |
| Machine | Mac mini, Apple Silicon (arm64), macOS 27.0.1, Homebrew 7.0.9 |
| iOS | **Deferred.** The iOS template and lens are designed in this spec, built only when a project needs them. Full Xcode is not installed. |
| Already installed | `git` 2.54, `node` 26.12, `jq` 1.7.1, `swift` 6.4 (Command Line Tools) |
| To install via owner scripts (Phase 1) | `gh`, `pnpm`, `codex`, `gitleaks`, `shellcheck` |

### 1.5 Definition of done (before 5:00 may start)

1. `bash tests/run.sh` prints `ALL PASS` on a clean clone.
2. `.harness/bin/conformance` proves that every hook in `enforce` mode denies its target command.
3. One throwaway web project has gone through the full loop: ticket → worktree → PR → every
   required lens CLEAN (with valid read-proof) → merge to `dev` → owner-run production deploy,
   with a verified handoff.
4. A fresh Claude Code session given `CONTINUE FORGE` reports where things stand correctly.

---

## 2. Repository layout

### 2.1 The tree

```
~/code/forge/                       GitHub repo Thebigtuna88/forge, default branch `dev`
  CLAUDE.md                         the charter: rules in force, conventions, CONTINUE command
  README.md                         one-page orientation for a human
  docs/
    specs/                          design specs (this file)
    plans/                          phased build plans
    decisions/                      one file per durable decision: <date>-<slug>.md
    runbooks/                       how-tos for recurring owner/agent procedures
  .harness/
    bin/                            commands: status ticket worktree handoff review-lens
                                    conformance new-project
    lib/                            shared code: hookrt.sh handoff.sh review.sh pr.sh
                                    review-diff.sh (the one review diff, FRG-4)
    lenses/                         review checklists: code security frontend ios spend (.md)
    mode.json                       per-hook enforce|observe (missing/malformed = enforce)
    spend-limits.json               monthly $ cap per paid API              [owner-only]
    deploy-targets.json             which deploy targets are preview vs production
    self-modification-paths.json    the list of owner-only paths (incl. itself)
    projects.json                   registry of governed projects: name, repo, key, type
    state/CONTINUE.md               next action + in-flight reasoning   [gitignored]
    observed.log                    what observe-mode hooks would have denied [gitignored]
  .claude/
    settings.json                   hook registration, project-scoped (committed)
    settings.local.json             machine-local overrides               [gitignored]
    hooks/                          the gates (section 5)
  .github/workflows/ci.yml          runs tests/run.sh, shellcheck, gitleaks on every PR
  .gitleaks.toml                    secret-scan config
  templates/
    web/                            Next.js starter with all gates (section 7)
    ios/                            README placeholder until iOS is needed (deferred)
  tests/
    run.sh                          runs everything; last line is `ALL PASS` or `FAILED (n)`
    unit/                           one test file per bin/ and lib/ script
    conformance/                    proves each hook denies under the live mode.json
    fixtures/
  projects/<name>/                  each project's OWN GitHub repo, cloned here [gitignored]
  work/
    <KEY>-<n>-<slug>/               review evidence per ticket            [gitignored]
    owner/<date>-<slug>/            owner handoff scripts + results        [gitignored]
```

Worktrees live **outside** the repo:

```
~/code/forge-worktrees/
  FRG-<n>-<slug>/                   a FORGE ticket
  <KEY>-<n>-<slug>/                 a project ticket (e.g. a 5:00 ticket, with its own key)
```

### 2.2 Why it is shaped this way

- **The main checkout stays on `dev` and is never edited by hand.** It only moves forward with
  `git pull` after a reviewed PR merges. All work happens in a worktree on a feature branch.
- **The live hooks are always the ones on `dev`.** Claude Code is started in `~/code/forge`, so
  it loads hooks from the main checkout. Editing a hook inside a worktree changes nothing until
  that change is reviewed, merged by the owner, and pulled. A branch can't weaken the gates that
  are judging it.
- **Projects are separate repos.** Each has its own issues, PRs, CI and branch protection.
  FORGE only clones them under `projects/` (gitignored) and records them in `projects.json`.
  Each project gets its own 3-letter ticket key, chosen when it's created.
- **Evidence is local and gitignored.** `work/` holds review transcripts, diffs and handoff
  results. The merge gate reads from it. A summary of each final review is also posted as a PR
  comment, so a lasting record survives on GitHub (section 6).
- **Owner-only paths** (rule 7) are listed in `self-modification-paths.json`. That file is
  owner-only itself, so the list can't be shortened without the owner:
  `.harness/spend-limits.json`, `.harness/deploy-targets.json`, `.harness/mode.json`,
  `.harness/self-modification-paths.json`, `.claude/hooks/`, `.claude/settings.json`,
  `.harness/lib/`, `.github/workflows/`, `.harness/bin/conformance`, `tests/conformance/`
  (FRG-2), `.harness/gitleaks.toml` (FRG-3), `CLAUDE.md`, `.harness/bin/handoff`,
  `docs/specs/` and `tests/stubs/` (FRG-4). `gate-self-modification` reads both this list and the one at a PR's
  merge base.

---

## 3. Rules in force (the charter)

These ten rules are copied into `CLAUDE.md` word for word and apply to FORGE and every
governed project. "Enforced by" says what actually stops a violation. Where it only says
"charter", the rule depends on the agent following it and on review catching slips.

| # | Rule | Enforced by |
|---|---|---|
| 1 | **One ticket, one branch, one worktree.** A ticket is a GitHub Issue on the repo it concerns, titled `<KEY>-<n>`. Branch `feature/<KEY>-<n>-<slug>` → `dev` → `main`. | `enforce-branch-format`, `deny-commit-on-shared-checkout`, `ticket`/`worktree` commands |
| 2 | **`main` is human-only.** The agent never pushes to or merges into `main`. `dev` is reached only by a reviewed PR, which the agent may merge. | `deny-push-to-protected`, `gate-merge-on-review` (only `--base dev`), GitHub branch protection (3.2) |
| 3 | **Review before merge, every time.** Never review your own diff inline. Required lenses: `code` (codex, mandatory, adversarial), `security` (every PR), `frontend` (UI in a web project), `ios` (iOS project), `spend` (paid APIs, image gen, payments, `spend-limits.json`). Mechanisms `author`, `inline`, `self` are refused. | `review-lens` runner, `gate-merge-on-review` |
| 4 | **Read-proof.** A lens reply counts only if the reviewer itself computed and reported the diff's md5 and byte count, and they match the runner's own computation. | `review-lens verify` |
| 5 | **Rounds are uncapped; the only circuit breaker is a stall.** Fix and re-run until every required lens is CLEAN. Each round is logged to `rounds.log` as `<utc> <lens> <head-sha> <verdict> <findings-hash>`. Two consecutive identical findings-hashes for a lens = stall → stop and hand the decision to the owner. Every deferred finding becomes a ticket **before** merge. | `review-lens`, `gate-merge-on-review` (checks deferred findings have issue numbers) |
| 6 | **A finding clears only when the fix is demonstrated**: a test that fails without the fix, command output, or `file:line`. The same standard applies to every claim the agent makes to the owner. | review checklist; next round re-checks |
| 7 | **Limits are the owner's.** The paths in `self-modification-paths.json` (section 2.2) may be changed only by a PR the owner merges. | `gate-self-modification`, `guard-live-checkout` (5.2) |
| 8 | **Test mode until the owner flips it.** Payments (Stripe/Shopify) run in test mode. Production deploys, App Store/TestFlight submissions, DNS changes and anything that charges a card are owner-run scripts. | `gate-deploy-target`, `gate-spend`, owner handoffs |
| 9 | **Fail closed, no escape hatch.** If a hook blocks something, fix the code or config through a PR. Never route around a guard. Hooks that can't load their runtime deny. | `hookrt.sh` load check; charter |
| 10 | **Secrets never enter the chat or git.** They are collected only through `ho_secret_to_file`. Every commit is scanned by gitleaks, locally and in CI. | `secret-scan`, CI gitleaks job |

### 3.1 Branch flow

```
feature/FRG-12-review-runner ──PR (all lenses CLEAN)──► dev ──PR (owner merges)──► main
          ▲                                               │
          └──── git merge dev (to update; never rebase) ──┘
```

### 3.2 Server-side protection on GitHub

The local hooks run on the owner's Mac. GitHub branch protection is the second, independent
layer. On each governed repo:

- `main`: changes only through a PR; no force-push; no deletion; applies to admins too.
- `dev`: changes only through a PR; the CI check must pass; no force-push; no deletion.

**Limit:** the agent uses the owner's own `gh` login, so GitHub can't tell agent and owner
apart. Server-side protection stops direct pushes and force-pushes, but only the local hooks stop
the agent from *merging* a PR into `main`. Section 11 records this gap.

**Plan availability (verified 2026-10-15 against GitHub docs):** protected branches work on
**public** repos on GitHub Free. **Private** repos need GitHub Pro or above.
Decision: see 3.3.

### 3.3 Repository visibility — DECIDED 2026-10-15

- **FORGE is public.** It holds only rules, scripts and docs, never secrets (rule 10, gitleaks
  in CI), so it gets full branch protection on GitHub Free at $0.
- **Each project chooses at creation.** `new-project` asks public or private. A private project
  on GitHub Free has no server-side protection, so `new-project` records `"protection": "local-only"`
  in `projects.json`, `status` shows that on every run, and section 11 applies. Upgrading to Pro
  later is an owner script.
- **Commit identity.** Commits use the owner's GitHub noreply address
  (`<id>+Thebigtuna88@users.noreply.github.com`), set per repo in Phase 1, so no personal email
  appears in public history.
- Recorded in `docs/decisions/2026-10-15-repo-visibility.md`.

---

## 4. Owner handoffs

Whenever the agent is blocked on the owner (installing a tool, logging in, creating an API key,
buying credits, approving a production deploy, clicking something in a web UI), it **writes a
script, not instructions**. The owner runs the script in their own Terminal window. The script
prints a HANDOFF-RESULT block, which the owner pastes back into the chat as evidence.

### 4.1 Lifecycle

```
agent: handoff new <slug> "<title>"   → work/owner/<date>-<slug>/OWNER-RUN.sh (skeleton) + META.json
agent: edits the steps in OWNER-RUN.sh
agent: handoff ready <id>             → lint must pass; script made read-only; sha recorded in META.json
agent → owner, exactly two lines:
         bash /Users/atl/code/forge/work/owner/<id>/OWNER-RUN.sh
         paste back the HANDOFF-RESULT block
owner: runs it in a normal Terminal window (not inside Claude Code)
runtime: writes RESULT.txt, copies the block to the clipboard
owner: pastes the block into chat
hook:  capture-owner-paste saves it verbatim → work/owner/<id>/PASTED-<utc>.txt (+ pastes.log)
agent: handoff verify work/owner/<id>/PASTED-<utc>.txt → VERIFIED.txt on success
agent: proceeds only after verify passes
```

The id is `<date>-<slug>`, for example `2026-10-16-install-tools`.

### 4.2 Script shape

```bash
#!/usr/bin/env bash
# HANDOFF: 2026-10-16-install-tools — Install gh, pnpm, gitleaks, shellcheck, codex
set -uo pipefail
source "/Users/atl/code/forge/.harness/lib/handoff.sh"
ho_begin "2026-10-16-install-tools"

ho_check brew-present   command -v brew                      || ho_abort
ho_check install-gh     brew install gh                      || ho_abort
ho_check gh-version     gh --version
ho_confirm read-prices  "Did you check the live price before continuing?" || ho_abort

ho_end
```

### 4.3 Runtime: `.harness/lib/handoff.sh`

**Refuses to run** (exit 3, prints why) when any of these holds:
- stdin or stdout is not a TTY;
- `CLAUDECODE` (or any other known agent marker: `CLAUDE_CODE_ENTRYPOINT`, `CODEX_SANDBOX`,
  `CODEX_SANDBOX_NETWORK_DISABLED`) is set, even to the empty string;
- it is executed directly instead of sourced;
- `OWNER-RUN.sh` is still writable, or `META.json` doesn't say `ready` with this script's
  sha256 (it was never frozen by `handoff ready`, or it is already verified);
- its own sha256 or the runtime's can't be computed;
- shell tracing is on (`bash -x`), which would print secrets;
- allexport is on (`set -a`, or an exported `SHELLOPTS` carrying it), which would export a secret
  as soon as it is read (FRG-14);
- a symlink sits at `logs/` or `RESULT.txt` (the last three added in the FRG-1 review);
- the live redaction filter `.harness/lib/handoff_redact.py` is missing, a symlink, or not the
  one whose sha256 `handoff.sh` pins (FRG-14). So `runtime-sha256` covers the filter too. The
  filter is read with a shell builtin and hashed by the checked interpreter, never by a tool on
  `PATH`.
  `ho_begin` reads the filter once and every step runs that checked text (`python3 -c`), so
  replacing the file mid-run changes nothing;
- no `python3` from Apple's Command Line Tools or Xcode is found at its fixed path with it and
  every folder above it root-owned and not writable by the owner (so the Xcode copy under the
  admin-writable `/Applications` is refused). The filter never runs on the `/usr/bin/python3`
  shim, whose choice of interpreter follows `DEVELOPER_DIR`.

The refusal means running the script through Claude Code's `!` prefix fails too. That's
intended: the owner uses a separate Terminal window.

**Helpers.** Every evidence line comes from one of these. Each returns 1 on FAIL, so the script
can stop before an irreversible step.

| Helper | Records | PASS when |
|---|---|---|
| `ho_begin <id>` | id, start time (the block's `at:`), `script-sha256` (of the calling script), `runtime-sha256` | must be called first; the id must match the folder name |
| `ho_check <name> <cmd…>` | `PASS` or `FAIL` + last non-empty output line | command exits 0 |
| `ho_info <name> <cmd…>` | `INFO` + last output line | never fails |
| `ho_confirm <name> "<question>"` | `PASS` (answered `y`) or `FAIL` | owner types `y` at `/dev/tty` |
| `ho_secret_to_file <name> <VAR> <file>` | `PASS stored VAR in <file> (mode 600)` | hidden input is non-empty, uses only `A-Z a-z 0-9 . _ + / = : @ % , -`, and doesn't appear in the handoff's own text (FRG-14); the target is a regular file (or absent) and gitignored (`git check-ignore`), as is its temp file; and every write step succeeds |
| `ho_redact_file <name> <file>` | `PASS hiding N values from <file>` (a count, never a value); on any refusal the run stops at once (`result: FAILED`), since later steps may use those values | no value appears in the handoff's own text (see below), the file is absolute, reached through no symlink, a regular readable file (opened without following a symlink, and confirmed after opening to be the file at that path), untracked and gitignored, and every line that isn't blank (spaces only) or a comment is `VAR=value` (a trailing CR is ignored) with a value of at least 8 characters from the `ho_secret_to_file` set. Its values are then hidden like collected secrets for the rest of the run (FRG-14) |
| `ho_abort` | `result: FAILED` | ends the run early with the block |
| `ho_end` | the block | — |

Details:
- Step names are `[a-z0-9-]+` and unique within a script.
- Command output still streams to the owner's screen and is saved to `logs/<name>.log`, both
  through the live redaction filter (below). Only the last line (trimmed to 200 characters,
  newlines and `-----` stripped) goes into the block.
- `ho_secret_to_file` reads with echo off, writes or replaces the single `VAR=value` line in
  the file via a private temp file, `chmod 600`, and unsets the variable. The value is written
  unquoted, which is why its characters are restricted: it means the same to a shell and a
  dotenv parser, and can never run as code. The secret never goes to the screen, the logs, the
  clipboard or the block; if a later step prints it anyway, the runtime replaces it with
  `[REDACTED]` in the evidence and in that step's log. Evidence is redacted both before and
  after it is normalised, so stripping `-----` or control characters can't rejoin a secret.
- Commands run as `script -q /dev/null /bin/bash -c '"$@"' … | <python3> -I -c <checked filter>
  <log>`, so they keep the terminal and shell builtins work. The handoff folder and its logs are
  mode 700, logs and `RESULT.txt` mode 600. Each step's log is removed before the step runs, and
  `RESULT.txt` is written fresh; if it can't be saved, `ho_end` prints no block and exits 1.
- **Live redaction (FRG-14).** The filter shows the step's output and writes its log with every
  known secret (collected this run, or loaded by `ho_redact_file`) masked before either sees it:
  every byte any occurrence of any secret covers, judged on the original bytes, so secrets that
  contain or overlap one another are hidden whole, and a run of masked bytes shows as one
  `[REDACTED]`. The secrets reach it on a private pipe (descriptor 3): never on a command line,
  and not in the step's environment. The list ends with the line `#END`; a list without it may
  have been cut short, so the filter shows nothing and the run ends FAILED. Everything else the
  runtime shows that holds words from the script goes through the filter too, without a log:
  step banners (`▶ name: command`), confirm questions, prompts, file paths and failure reasons.
  The block's check lines are masked as a whole before the block is saved, shown or copied, so
  a step name that matches a known secret shows as `[REDACTED]`, and verify then refuses the
  block. Evidence is masked the same way, through the filter, never one secret at a time.
- **No secret in the handoff's own text.** `ho_secret_to_file` refuses a typed value, and
  `ho_redact_file` refuses a file with a value, that appears anywhere in the handoff's own text:
  the frozen script, its folder, the runtime's and the interpreter's paths, the id, the
  checksums or the start time; the runtime's and the filter's own source (fixed messages, the `[REDACTED]` marker, the
  filter text on its command line); and each step's log path. Every line the runtime prints or
  passes on a command line, other than step output, is built from that text: banners,
  questions, prompts, paths, failure reasons, the block's header, and the filter's arguments. So a value found there could never be kept hidden, and a real secret
  found there has leaked already. The filter's own messages are fixed text, with no path,
  system message or traceback. If masking fails while evidence is cleaned, the run ends FAILED. It holds back only the longest end of the output that could
  still become a secret (less than one secret's length), and shows that as soon as more output
  rules it out or the step ends. There is no timer, which could show part of a
  secret: a step that prints the start of a secret and then waits for input shows those
  characters only when it continues. The filter ignores SIGINT; if it is killed, what it held is
  dropped.
- **Fail closed.** If the filter fails (it can't create the log, it dies, or writing fails), the
  run ends FAILED: `check _runtime: FAIL live redaction failed in step <name>`. The evidence and
  the log are also redacted again after the step, as before FRG-14. If a log can't be replaced by
  its redacted copy, the run ends FAILED (the log may hold a secret).
- **What it doesn't stop:** a step built to get around it, for example by writing to the
  terminal device directly, splitting a secret with screen codes, or encoding it. That is L11
  ("steps run arbitrary programs"), narrowed by FRG-30. Live redaction protects against a step
  printing a secret by accident.
- Ctrl-C, TERM or a hang-up ends the run through the same exit path: the block reports FAILED
  and any secret temp file is removed.
- Steps run from `/`, never from wherever Terminal was opened, so a step names its repository
  (`--repo`, `git -C`) and uses absolute paths.
- `handoff` itself needs `jq`, `git`, `shasum` and `python3`; macOS 15+ ships `/usr/bin/jq`,
  and the Command Line Tools provide git and python3. `handoff new` checks them first.

**`ho_end` output**, saved as `RESULT.txt` and copied to the clipboard with `pbcopy`:

```
----- HANDOFF-RESULT BEGIN -----
id: 2026-10-16-install-tools
script-sha256: <sha256 of OWNER-RUN.sh>
runtime-sha256: <sha256 of handoff.sh>
at: 2026-10-16T18:04:11Z
check brew-present: PASS /opt/homebrew/bin/brew
check install-gh: PASS ==> Summary 🍺 /opt/homebrew/Cellar/gh/…
check gh-version: PASS gh version 2.x.x (…)
check read-prices: PASS confirmed
result: OK
----- HANDOFF-RESULT END -----
```

### 4.4 `handoff lint`

The script must follow an **allowlist grammar** (`.harness/lib/handoff_grammar.py`, added in
the FRG-1 review because blocklists could be dodged with quoting): apart from blank lines and
comments it is exactly the shebang, `set -uo pipefail`, the `source` line, `ho_begin "<id>"`,
step lines, and `ho_end`. Each step line is one helper call made of plain words and quoted
strings, optionally ending in `|| ho_abort`: no `$` or backticks (except inside single quotes,
where they stay literal), no other operators, redirection, globs, assignments or function
definitions. Forbidden names are checked after quote removal, and no `ho_check`/`ho_info` step
may name a file that a `ho_secret_to_file` step writes or a `ho_redact_file` step names.
`ho_redact_file` takes exactly one absolute path (read with the grammar's own tokenizer, so a
quoted path is judged whole), which must already be inside a git repository, untracked and
gitignored when the script is linted (the runtime checks again at run time).

In addition, lint rejects a script (and `handoff ready` refuses to freeze it) if it:
- doesn't source the runtime by its exact absolute path, or doesn't call `ho_begin` first and
  `ho_end` last;
- contains the literal strings `HANDOFF-RESULT`, `result: OK`, `script-sha256`, or any
  `check <name>: PASS|FAIL|INFO` text, i.e. tries to fake evidence;
- redefines any `ho_*` function, or uses `eval`, `source`/`.` of any other file, `exec`
  redirection, `unset CLAUDECODE` or other agent-marker manipulation;
- writes to `RESULT.txt`, `VERIFIED.txt` or `PASTED-*`;
- fails `shellcheck`, or shellcheck or python3 is not installed (fail closed). The one
  exception is the bootstrap handoff that itself runs `brew install … shellcheck` (4.9).

`handoff ready` also refuses an id that is not `<date>-<slug>` (no path traversal) and a
`META.json` naming a runtime other than this checkout's `.harness/lib/handoff.sh`.

### 4.5 `handoff verify <pasted-file>`

Passes only if **all** of these hold:
1. The paste contains exactly one well-formed block.
2. `work/owner/<id>/` exists and its `META.json` marks it ready.
3. `script-sha256` equals the sha256 of `OWNER-RUN.sh` on disk **and** the sha frozen at
   `handoff ready`, and the run's `at:` is not older than `readied` (no replaying a run made
   before the script was frozen).
4. `runtime-sha256` equals the sha256 of the current `.harness/lib/handoff.sh`, and the
   runtime named in `META.json` is that file. The redaction filter beside it still matches the
   sha256 the runtime pins (FRG-14), as hashed by `/usr/bin/shasum` in an empty environment.
5. Every step declared in the script appears exactly once, and no undeclared step appears.
6. Every step is `PASS` or `INFO`, and `result: OK`.
7. The paste matches `RESULT.txt` (written by the runtime on the owner's run), ignoring
   leading and trailing whitespace.
8. The pasted file lives at `work/owner/<id>/PASTED-*.txt` and is its own regular file (not a
   symlink or hard link). Verify refuses to take `RESULT.txt` itself as input.
9. `.harness/state/pastes.log` in the main checkout (a regular file with one link, in folders
   that are not links) has a finished line (ending in a line break) of four fields naming
   `work/owner/<id>/PASTED-*.txt` with the paste's sha256 (FRG-5).

Verify reads the paste once: checks 1 to 9 all use that one copy, so the bytes it checks are the
bytes whose hash must be recorded.

**From FRG-5 on** (owner decision 2026-10-16-handoff-evidence-provenance), the paste file is
written by the `capture-owner-paste` UserPromptSubmit hook, not by the agent, and verify's check 9
requires the paste's sha256 to be recorded in `.harness/state/pastes.log` by that hook. The hook
gets the owner's message in full (a collapsed paste arrives expanded, between `<pasted_content>`
lines). When the message holds exactly one block (lines compared as verify compares them) for a
`<date>-<slug>` handoff whose `work/owner/<id>/` is a real folder with a `META.json` in state
`ready`, it saves the block's lines exactly as received to a new `PASTED-<utc>.txt` (never
replacing a file, never through a link) and appends `<utc> <id> <file> <sha256>` to
`pastes.log`. Its one-line note (what it saved, or why not) reaches the agent as added context. It
never blocks the message: it is registered without `onFailure` and fails open (5.1), so a failure
only means verify refuses the paste. `guard-live-checkout` keeps the agent's file tools away from
both files (5.3).

On success, it writes `VERIFIED.txt` (the block + verify time) in one step (temp file, then
rename). `VERIFIED.txt` alone is the record that a handoff is verified; `META.json`'s state
mirrors it, and failing to update that is only a warning. On failure, it prints which
check failed. The agent reports that failure to the owner. It never edits the paste.

If `handoff.sh` changes between the run and verification (a runtime update merged), check 4
fails by design. The fix is a fresh handoff, not a patched verify.

### 4.6 Stop hook: `gate-owner-handoff-form`

Runs when the agent finishes a turn. It reads the turn's last message from the input's
`last_assistant_message` (FRG-5: Claude Code's docs say the transcript file may lag behind).
- **Blocks** (exit 2, with "rewrite this as an owner handoff") when the message gives the owner
  prose run-instructions, i.e. it contains a block marked as shell, `$ ` lines, or a setup command
  at the start of a line or list item, aimed at the owner (`brew install`, `gh auth`, `npm i -g`,
  `export *_KEY=`, `curl … | sh`, etc.), or phrases like "run this in your terminal", "go to … and
  click". Only an owner handoff's own lines are exempt: `bash <…>/work/owner/<id>/OWNER-RUN.sh`
  (alone, or in a block of such lines) and "paste back the HANDOFF-RESULT block". The rest of a
  message that also holds a handoff is still checked (FRG-5 review round 2).
- **Never blocks twice in a row.** When Claude Code reports `stop_hook_active: true`, it allows.
- **Fails open.** If the message is missing or unreadable, or the hook itself fails, it allows
  and logs `FAILED-OPEN` to `.harness/observed.log` (hookrt, 5.1). A Stop hook that fails closed
  would block every turn.
- Starts in **observe** mode, because it is a text heuristic. The owner promotes it to enforce
  by PR once the observed log shows few false positives.

### 4.7 Visibility

`.harness/bin/status` lists every `work/owner/*/` folder without a `VERIFIED.txt`, with its
title and age.

### 4.8 What this proves, and what it doesn't

The TTY and agent-marker checks are a **speed bump**. A program with a shell could fake a
terminal or clear the variables. The real evidence is that **the owner pasted the block**, and
it matches a `RESULT.txt` produced by an unmodified script and runtime. Section 11 records
this.

### 4.9 Bootstrap (chicken and egg)

At the start, nothing exists: no `gh`, no `codex`, no GitHub repo. So Phase 1 runs in this
order, and the order is the only exception to "review before merge":

1. Build the runtime and `handoff new|ready|lint|verify` with its tests, committed **locally**
   on `feature/FRG-1-skeleton`. Nothing is pushed yet, because there's nowhere to push.
2. Use that unreviewed runtime for the first handoffs: install tools, `gh auth login`,
   `codex login`, create `Thebigtuna88/forge` with `dev` as the default branch.
3. Push the branch, open the PR, and run codex by hand on it. The runtime used in step 2 is
   reviewed **after the fact**. If review changes the runtime, the step-2 handoffs are re-run
   on the reviewed runtime, and their results are re-verified before Phase 1 counts as done.

---

## 5. Hooks (the gates) and command conventions

### 5.1 How a hook works

Claude Code runs each registered hook before the matching tool call (`PreToolUse`) or when the
agent ends a turn (`Stop`). It passes the call as JSON on stdin (`tool_name`, `tool_input`,
`cwd`, …). A hook **denies only by exiting 2**, and its stderr is shown to the agent as the
reason. Any other exit allows, and so do a hook that can't start (missing, not executable) and
one that times out, unless it is registered with `"onFailure": "block"` (Claude Code 2.1.295 or
later). Then any failure blocks, as exit 2 does. **Every FORGE hook is registered that way, with
a timeout of at most 120 seconds**, except on the events where Claude Code ignores the field
(`Stop`, `SubagentStop`, `TaskCompleted`, `TeammateIdle`), which is why the Stop hook below has
neither and fails open (4.6) (FRG-20, `docs/decisions/2026-10-18-failed-hooks-block.md`). The one
other exception is `capture-owner-paste` (UserPromptSubmit, FRG-5), registered with a timeout but
without `onFailure`, on purpose: there a blocking failure would stop the owner's message reaching
the agent, and fail-closed is kept at verify instead (4.5). The runtime lets exactly these two
hooks fail open, known by their file names: a crash or an input they can't judge allows and logs
`FAILED-OPEN`, while an explicit deny still denies. They load the runtime with header lines that
exit 0, not 2, if it can't load. Conformance checks that each is registered only for its own
event, and that they, and only they, use those header lines.

Registration is project-scoped, in the committed `.claude/settings.json` (never `~/.claude`):

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/deny-push-to-protected.sh",
          "onFailure": "block", "timeout": 120 }
      ]},
      { "matcher": "Edit|Write|MultiEdit|NotebookEdit", "hooks": [
        { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/guard-live-checkout.sh",
          "onFailure": "block", "timeout": 120 }
      ]}
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/gate-owner-handoff-form.sh" } ] }
    ]
  }
}
```

### 5.2 Shared runtime: `.harness/lib/hookrt.sh`

Every hook starts with the same three lines:

```bash
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }
```

The runtime is found relative to the hook's own file, never through an environment variable.
It provides:

- `hr_init <hook-name>`: reads the stdin JSON with `jq`, exposes the tool name, command,
  file path and cwd. Sets the mode: `jq` on `.harness/mode.json` → `enforce` or `observe`.
  **A missing file, malformed JSON, unknown value or missing key all mean `enforce`.** If `jq`
  itself is missing, it denies.
- `hr_deny "<reason>"`: in enforce mode, prints the reason and exits 2. In observe mode, appends
  `<utc> <hook> WOULD-DENY <reason> :: <command>` to `.harness/observed.log` and exits 0.
- `hr_tokens`: splits a command into words with `python3 -c 'import shlex…'` (correct quote
  handling, from the macOS Command Line Tools), never with ad-hoc regex.
- `hr_require_simple`: if a command mentions a guarded verb anywhere (`git push`, `git commit`,
  any `gh` command, any deploy tool), it must be a **single simple command**: no `&&` `||` `;`
  `|` `&` `$(` backticks `>` `<`, newlines, `~`, globs or `#`, and the first word must be the
  tool itself, not `NAME=value`, `env`, `command`, `sh -c`, `bash -c`, `xargs` or `eval`.
  Otherwise it's denied. So `echo "git push"` is denied too. That false positive is accepted:
  fail closed. Every `gh` invocation the runtime recognises (in command position, after a
  wrapper such as `xargs`, or with words after it) is guarded, reads included, and
  `deny-repo-admin` then judges it by its real command (FRG-4), so `--repo` doesn't count as
  `gh repo`. Reads were exempt at first, so they could sit in a pipeline; FRG-4 review rounds
  2-7 kept finding ways for the shell to change what such a read sends or runs (`xargs`, `$`,
  globs, `~`, line continuations, comments, `GH_PAGER=…` or `HOME=…` in front), and the owner
  removed the exemption (`docs/decisions/2026-10-19-gh-reads-plain.md`). A read that opens a
  browser (`gh browse`, `--web`, `-w`) is refused, since the browser is whatever program gh's
  settings name. A command that defines an alias (`alias`, zsh's `aliases[…]`, bash's
  `BASH_ALIASES`, `expand_aliases`) is guarded, since an alias runs a tool under another name,
  and so is a `NAME=gh` word with words after it (round 8). So is a command that builds its
  command line from its input, where input can become a command's name: `xargs` with a
  replacement (`-I`, `-J`, `-i`, `--replace`) or an option FORGE doesn't know, `parallel`, and
  `find -exec {}` (round 9); `xargs` that only appends words stays plain. A guarded `gh` command is refused while the environment sets a `GH_*`,
  `GITHUB_*`, `BROWSER` or `PAGER` variable, as git's are for `GIT_*`. A `#` doesn't hide the
  rest of a line from the gates: its words are judged like any others, and a line ending in a
  backslash is joined to the next before `gh` is looked for and before the secret scan.
  These checks recognise ordinary commands and mistakes. A command deliberately built to hide
  `gh` or `git` may not be recognised: review rounds 6-10 kept finding new spellings, and the
  owner accepted that as known limit L13 (11) rather than patching each one.
- `hr_gh`: runs `gh` for a gate with prompts, pager and update checks off. Inside a conformance
  sandbox, and only there (the runtime itself sits at
  `<tmp>/forge-conformance.XXXXXX/s<n>/code/forge`), it runs the sandbox's fake `gh`.
- `hr_git_sub`: finds the git subcommand after global options (`-C <dir>`, `-c k=v`). **A git
  alias is denied** if it would expand to a guarded subcommand, because the hook can't see
  what an alias does.

### 5.3 The gates

| Hook | Event / matcher | Denies | Start mode |
|---|---|---|---|
| `deny-push-to-protected` | Pre / Bash | `git push` to `main` or `dev` (any refspec form: `main`, `HEAD:main`, `refs/heads/dev`, `:main`); any `--force`, `-f`, `--force-with-lease`, `+refspec`; `--delete`/`-d`, `--mirror`, `--all`; a **bare** `git push` (target must be explicit: `git push origin <branch>`) | enforce |
| `secret-scan` | Pre / Bash | `git commit` if `gitleaks git --staged` finds a secret, or gitleaks is missing; also any `git commit` using `-m`, `-a`, `--no-verify` or without `-F <file>` | enforce |
| `gate-merge-on-review` | Pre / Bash | `gh pr merge` in any form but `gh pr merge <n> --repo Thebigtuna88/forge --squash --match-head-commit <40-character sha>` (so no `--auto`, `--admin`, `--delete-branch`, `--rebase`, `--merge`, `--subject`, `--body`), and that form unless all hold (FRG-4): GitHub says the PR is open, its base is `dev`, its head is a ticket branch of this repository (not a fork) at exactly that sha, its merge base with `dev` is the one recomputed locally, and `dev` requires no merge queue (where `gh pr merge` could turn on auto-merge); every answer and file it reads is exactly one JSON value; `work/<KEY>-<n>-<slug>/review.md` (6.6) is bound to that repository, branch, PR, head **and** merge base, and the diff recomputed now has its md5 and byte count; every lens listed is CLEAN, run by `codex` or `subagent` (`code` only by `codex`; `author`, `inline`, `self` refused), and its reply file still has the recorded sha256 and is itself a CLEAN reply for this lens and this diff's md5 and bytes; `code` and `security` are present; every deferred finding cites an issue open now; and gitleaks finds no secret in what the squash commit would hold (the PR's title, body, commit messages and authors). The hook recomputes everything; it trusts none of review.md's text. Merges through the API are refused by `deny-repo-admin` | enforce |
| `gate-self-modification` | Pre / Bash | `gh pr merge` when the PR touches any path in `self-modification-paths.json`, the live list or the one at the PR's merge base (or a project's own owner-only list in `projects.json`) → "owner must merge this". The changed paths come from the recomputed diff, not GitHub's file list (which stops at 100); names are compared case-folded and Unicode-normalised, a rename counts as both paths, and any symlink or submodule in the diff counts as owner-only. A missing or malformed list refuses | enforce |
| `guard-live-checkout` (added) | Pre / Edit, Write, MultiEdit, NotebookEdit **and** Bash | Edits inside the main checkout (the one the hook sits in, so it follows FORGE if it moves) or a project's main checkout under `projects/<name>`, other than gitignored scratch areas (`work/`, `.harness/state/`); in `work/owner/<id>/` anything but a draft `OWNER-RUN.sh` (results, pastes, `VERIFIED.txt`, `META.json`, logs), and `.harness/state/pastes.log` (FRG-5, 4.5); any write to a `.claude/settings.local.json` or `~/.claude/settings*.json` (these could switch hooks off). Paths are judged as written and with links resolved, compared as macOS compares names, and a file with more than one hard link is refused wherever it is; settings files in `CLAUDE_CONFIG_DIR` count as `~/.claude`'s (names compared ignoring case), and a settings file's real location is guarded too when the file, or a folder on its way, is a link (in a worktree only `settings.local.json`: its tracked `settings.json` changes by owner-merged PR). A guarded file or folder inside the main checkout that is a link is guarded at its real location as well (every link reachable in it is found, inside linked folders, `node_modules` and `.git` too; a checkout too large to list, or with a folder that can't be listed, means every file-tool write is refused). For Bash, a best-effort check for write operators (`>`, `tee`, `sed -i`, `cp`, `mv`, `rm`) aimed at those paths, following `cd` and skipping here-document bodies | enforce (Edit/Write); **observe** (Bash part) |
| `deny-repo-admin` (added) | Pre / Bash | Every `gh` command not on its allowlist (FRG-4): the read-only commands; `gh auth status` (no `--show-token`); `gh api <path>` as a GET only (no `-X`/`--method` but GET, no `-f`/`-F`/`--field`/`--raw-field`/`--input`, no `-H`, `--hostname` or `graphql`); `gh issue create/edit/comment/close/reopen` and `gh pr create/edit/comment/close/ready` with listed options only (a PR only into `dev` from a ticket branch, its base never edited); and the one merge form. So `gh repo edit`/`delete`/`rename`/`archive`/…, rulesets, secrets, variables, `gh auth login/logout/refresh/token/setup-git`, `gh config`, `gh alias`, `gh extension`, `gh workflow run` and anything a newer `gh` adds are refused. Text reaches GitHub only through `--title` and `--body-file`, and the whole command, each of its words as the shell passes them, and every body file are scanned by gitleaks first. (`git config` writes to `alias.*` or `core.hooksPath` are refused by `deny-history-rewrite`, FRG-3) | enforce |
| `deny-history-rewrite` (added) | Pre / Bash | `git rebase`, `git commit --amend`, `git filter-branch`, `git filter-repo`, `git replace`, `git update-ref -d`, `git push` of rewritten history (already caught by the force rules) | enforce |
| `gate-deploy-target` | Pre / Bash | Any command that matches a **production** pattern in `deploy-targets.json` (`vercel --prod`, `vercel deploy --prod`, `vercel promote`, `vercel alias`, `vercel domains`, `vercel dns`, `vercel env`, `xcrun altool --upload*`, `fastlane` upload lanes, `eas submit`), compared ignoring case; **any deploy tool command matching neither list** (fail closed). Preview patterns are allowed. A deploy command must already be one plain command starting with the tool itself (5.2); `gh workflow run` is refused by `deny-repo-admin` | enforce |
| `gate-spend` | Pre / Bash | Commands that mention a paid-API host (`api.openai.com`, `fal.run`, `api.replicate.com`, the Higgsfield API host, `api.stripe.com`, …), a provider key variable (`FAL_KEY`, `REPLICATE_API_TOKEN`, …) or names a provider's command-line tool (`openai`, `replicate`, `stripe`, …, which read a key from the environment), anywhere, except in a plain command (words joined by `|` `;` `&&` `||`, with no quoting, `$`, brackets or redirections) whose every program only reads and can run no other program (`cat`, `grep`, `ls`, `head`, …; not `rg`, whose `--pre` runs one), unless the command is the project's budget wrapper (from FRG-11; until then nothing is exempt). The hosts and variables are listed in `spend-limits.json` (8.5), so they're owner-only. Also any live Stripe key prefix (`sk_live_`, `rk_live_`) in a command. Matched ignoring case, as written and with quotes removed; a missing or malformed list refuses | enforce |
| `enforce-branch-format` | Pre / Bash | Creating a branch (`git checkout -b`, `git switch -c`, `git branch <new>`, `git worktree add -b`) or pushing one whose name isn't `feature/<KEY>-<n>-<slug>` (`^feature/[A-Z]{3}-[0-9]+-[a-z0-9]+(-[a-z0-9]+)*$`) with a known key (FRG or one in `projects.json`) | enforce |
| `deny-commit-on-shared-checkout` | Pre / Bash | `git commit` whose repo toplevel (cwd or `-C`) is the main checkout of FORGE or of any project, rather than a worktree under `~/code/forge-worktrees/`, or whose current branch isn't a `feature/…` branch | enforce |
| `gate-owner-handoff-form` | Stop | Prose run-instructions to the owner (section 4.6). Never blocks twice; fails open | **observe** |
| `capture-owner-paste` (FRG-5) | UserPromptSubmit | Nothing: it records the owner's pasted HANDOFF-RESULT block and never blocks (4.5); registered without `onFailure`, fails open | — (records only) |

The owner moves an observe hook to enforce by a PR that changes `mode.json`, which only the
owner can merge.

### 5.4 Command conventions (copied into CLAUDE.md)

- **Commits:** write the message to a file, then run `git commit -F <file>`. Never `-m`, `-a`,
  `--amend` or `--no-verify`. Stage with an explicit `git add <paths>`.
- **Single simple commands** for `git push`, `git commit`, every `gh` command that isn't
  read-only, and every deploy command: one command per Bash call, no chaining, piping,
  substitution or redirection. Use `-C <dir>` instead of `cd … &&`.
- **Text to GitHub:** only `--title <text>` and `--body-file <file>`, both scanned for secrets
  first; never `--body`, `-b`, `--fill` or an editor. A PR: `gh pr create --base dev --head
  feature/<KEY>-<n>-<slug> --title <text> --body-file <file>`.
- **Push:** `git push -u origin feature/<KEY>-<n>-<slug>` (always explicit).
- **Update a branch:** `git merge dev` inside the worktree. Never rebase, amend or force-push.
- **Merge:** `gh pr merge <n> --repo Thebigtuna88/forge --squash --match-head-commit <sha>`.
  Squashing keeps one commit per ticket on `dev`. Feature branches are cleaned up by the repo setting "automatically
  delete head branches", which the owner sets in the repo-creation handoff, not by the agent.
- **No git aliases** for guarded commands.

### 5.5 Conformance: `.harness/bin/conformance`

It proves the gates work **as configured right now**:

1. Every hook file in `.claude/hooks/` is executable, registered in `.claude/settings.json`,
   and passes `shellcheck`, and every registered hook exists. Nothing is orphaned or missing.
   A registration holds only `type`, `command`, `onFailure` and `timeout` (in a group of
   `matcher` and `hooks`). Every registration, except on events where Claude Code ignores it
   such as `Stop`, has `"onFailure": "block"` and a timeout of 1 to 120 seconds. Every installed
   `claude` (on `PATH`, in `~/.local/bin` or `~/.claude/local`) reports 2.1.295 or later, read in
   a no-write sandbox with a time limit (FRG-20). The version check prints `SKIP` on GitHub
   Actions, which doesn't run Claude Code, and `NOTE` when tests point it at a fake `claude`.
2. For every hook, it feeds fixture JSON (`tests/conformance/<hook>/{deny,allow}/*.json`) on
   stdin under the live `mode.json`:
   - **enforce**: every deny case must exit 2, every allow case must exit 0;
   - **observe**: deny cases must exit 0 **and** append a `WOULD-DENY` line.
3. It checks `mode.json` failure handling: in a temporary copy, a missing file, malformed JSON
   and an unknown value each produce enforce behaviour.
4. It checks that hooks aren't disabled: no `disableAllHooks` in `~/.claude/settings.json` or
   `.claude/settings.local.json`.
5. It prints a table, `hook | mode | deny cases | allow cases | result`, and exits non-zero if
   any check fails.

`tests/run.sh` runs conformance, so `ALL PASS` covers the gates.

---

## 6. Review runner and lenses

### 6.1 Overview

`.harness/bin/review-lens` (logic in `.harness/lib/review.sh`) runs every review. The agent never
reviews its own diff. It asks an independent reviewer, **codex** (OpenAI's CLI agent, a
different model family from Claude), to find what's wrong, and the runner checks the answer
mechanically.

```
review-lens init <ticket> <pr#>      freeze diff for current head, work out required lenses
review-lens prompt <lens>            build the prompt (checklist + diff path + instructions)
review-lens codex <lens>             run codex read-only, save its reply
review-lens ingest <lens> <file> --mechanism subagent    (non-code lenses only)
review-lens verify <lens>            schema + read-proof + log the round + stall check
review-lens defer <lens> <id> <issue#>                   ticket a finding instead of fixing it
review-lens finalize                 all required lenses CLEAN at head → review.md + PR comment
```

Evidence goes in `work/<KEY>-<n>-<slug>/`:

```
meta.json          repo, PR#, branch, base merge-base sha, required lenses
rounds/<r>/        diff.patch, prompt-<lens>.md, reply-<lens>.json, stdout-<lens>.log
rounds.log         one line per lens round
fixes.md           finding id → demonstrated fix (test, command output, file:line)
deferred.md        finding id → issue number
evidence/          screenshots, test output (frontend/ios)
review.md          final, branch- and sha-bound summary read by the merge gate
STALL.md           written when a stall stops the loop
```

### 6.2 Required lenses (computed, not chosen)

`init` computes the set from the changed paths and the project type in `projects.json`. The
agent can't drop a lens.

| Lens | Required when |
|---|---|
| `code` | always. **Mechanism must be codex.** |
| `security` | always |
| `frontend` | web project **and** the diff touches UI (`app/`, `components/`, `*.tsx`, `*.css`, `public/`, design tokens) |
| `ios` | iOS project (any diff) |
| `spend` | the diff touches `spend-limits.json`, the budget wrapper or provider adapters, payments code, or mentions a paid-API host or key variable |

**Mechanisms:** `codex` (default for every lens) or `subagent` (a separate Claude subagent, only
for non-code lenses, as a fallback if codex is unavailable). The runner refuses `author`,
`inline` and `self`, and anything not on the allow-list.

### 6.3 Running codex

```
codex exec --sandbox read-only --ephemeral -C <worktree> \
  --output-schema .harness/lenses/reply.schema.json \
  -o work/<T>/rounds/<r>/reply-<lens>.json  -  < prompt-<lens>.md
```

- `read-only` means codex can read files and run read-only commands (needed to hash the diff)
  but can't change anything. `--ephemeral` keeps no session files.
- Frontend and iOS lenses also get the screenshots via `--image <file>`.
- Codex's reply must validate against `reply.schema.json`:

```json
{ "lens": "code", "diff_md5": "…", "diff_bytes": 12345,
  "verdict": "CLEAN | FINDINGS",
  "findings": [ { "id": "C1", "severity": "blocker|major|minor|nit",
                  "file": "…", "line": 42, "title": "…", "detail": "…", "evidence": "…" } ] }
```

**The prompt** contains the lens checklist, the path to `diff.patch` (never its hash), and
the instruction: *"You are an adversarial reviewer. Your job is to find what is wrong, not to
approve. Before reviewing, compute the md5 and byte count of the diff file yourself with
`md5 -q` and `wc -c` and report them. Report CLEAN only if you find nothing."* For later rounds
it also lists the findings already deferred to issues, so they aren't re-reported.

### 6.4 Verify, read-proof and rounds

`review-lens verify <lens>`:
1. The reply parses and matches the schema. `lens` matches. `verdict` is CLEAN **only if**
   `findings` is empty, and nits count.
2. **Read-proof:** `diff_md5` and `diff_bytes` equal the runner's own `md5 -q` / `wc -c` of the
   same `diff.patch`. A mismatch makes the round `INVALID` (logged), and it must be re-run.
3. It appends to `rounds.log`: `<utc> <lens> <head-sha> <CLEAN|FINDINGS|INVALID> <findings-hash>`.
4. **Findings-hash:** each finding becomes `file|title|detail`, lower-cased, with line numbers
   masked (`:123` → `:N`, `line 123` → `line N`), whitespace collapsed; then sorted,
   de-duplicated and sha256-hashed.
5. **Stall:** if this lens's last two valid rounds have the same non-empty findings-hash, it
   writes `STALL.md` and exits 4. The agent must stop and hand the decision to the owner.
   That's the only circuit breaker; there's no round limit.

**Any new commit invalidates all earlier CLEAN verdicts.** Every required lens must be CLEAN
at the **current** head sha.

### 6.5 Fixes and deferrals

- **Fix:** each finding cleared gets an entry in `fixes.md` with its demonstration: a test that
  fails without the fix, command output, or `file:line` (rule 6). The next round re-checks it.
- **Defer:** `review-lens defer` requires an existing open issue (checked with `gh issue view`)
  and records it in `deferred.md`. **Blocker findings can't be deferred**; they're fixed or go
  to the owner.

### 6.6 Finalize and the merge gate

`review-lens finalize` succeeds only if every required lens's latest valid round is CLEAN at
the current head. It writes `review.md` (branch, PR#, head sha, merge-base sha, diff md5/bytes,
per lens: mechanism, model, rounds, verdict, sha256 of the reply file; deferred findings with
issue numbers) and posts a short summary as a PR comment.

`gate-merge-on-review` does **not** trust `review.md`'s text. It recomputes the diff from the
merge base to the PR head, rechecks each reply's md5/bytes and file sha256, and checks that the
recorded merge base is still the merge base of GitHub's `dev` and the head.

**The diff** (FRG-4) is made by one command, `.harness/lib/review-diff.sh <repo> <dev sha>
<head sha> <out>`, which the runner uses to freeze `diff.patch` and the gate uses to recompute
it. It runs git in a fresh scratch repository that borrows the objects and nothing else: no
repository, global or system settings, no templates, no attributes, no replace refs, no
commit-graph. So no
setting (external diff tools, text conversion, prefixes, context, rename detection, diff
drivers) can change its bytes. It shows every file as text (`--text`, so nothing hides as
"Binary files differ"), and it re-hashes every object both snapshots are made of, so a planted
object file can't show the reviewer one content while GitHub merges another.

**What the gate reads in `review.md`** (FRG-4): the file is for people, with the facts in
exactly one block fenced by a line ` ```json forge-review ` and a line ` ``` `:

```json
{ "forge_review": 1, "repo": "Thebigtuna88/forge", "branch": "feature/FRG-4-github-gates",
  "pr": 22, "head": "<40 hex>", "merge_base": "<40 hex>", "diff_md5": "<32 hex>", "diff_bytes": 1234,
  "lenses": [ { "lens": "code", "mechanism": "codex", "model": "…", "rounds": 3, "verdict": "CLEAN",
                "reply": "rounds/3/reply-code.json", "reply_sha256": "<64 hex>" } ],
  "deferred": [ { "finding": "S4", "issue": 31 } ] }
```

`reply` is relative to `work/<KEY>-<n>-<slug>/` and must be `rounds/<r>/reply-<lens>.json`.
Every number in the block is written as plain digits, with no fraction or exponent (`1`, not
`1e0` or `1.0`).

### 6.7 Lens checklists (`.harness/lenses/*.md`)

| Lens | Checks (summary) |
|---|---|
| `code` | correctness and edge cases, error handling, tests that would fail without the change, dead or duplicated code, matches the ticket's scope, no silent behaviour changes |
| `security` | secrets, injection (shell/SQL/HTML), auth and access, unsafe defaults, dependency risk, input validation, logging of sensitive data, hook bypasses |
| `frontend` | screenshots at 390px and 1440px: layout, overflow, contrast and a11y, empty/loading/error states, design-token use, keyboard navigation |
| `ios` | SwiftUI state handling, Dynamic Type, VoiceOver labels, contrast, memory/threading, simulator screenshots |
| `spend` | every paid call goes through the budget wrapper, caps read from `spend-limits.json`, ledger entries written, no live keys, test mode for payments, retries can't multiply cost |

### 6.8 Before the runner exists, and what codex needs

- **Phases 1–2** (before the runner is built): the agent runs the same `codex exec` command by
  hand with the code and security checklists, saves the output under `work/<T>/manual/`, and
  checks the md5/bytes by hand against `md5 -q` / `wc -c`. From Phase 3 on, the harness reviews
  itself with the runner.
- Codex needs either a **ChatGPT plan that includes Codex** (log in with `codex login`) or an
  **OpenAI API key** (pay per use). The owner picks at the Phase 1 login handoff. Pricing is
  checked live at that point.

---

## 7. Stacks, templates and the project scaffolder

### 7.1 Web stack: TypeScript-first

**Next.js (App Router) + TypeScript `strict` + Tailwind CSS + pnpm, deployed on Vercel.**
There's no strong case for anything else: it's the most widely used React framework, Vercel
makes it, preview deploys per PR come free with the GitHub integration, and its documentation
and AI support are the best of any option. Exact versions are pinned to the current stable
releases at Phase 5 and recorded in a decision file.

**Hosting cost note (checked 2026-10-15, third-party sources; confirmed live at the owner
handoff):** Vercel Hobby is free but limited to **non-commercial** use. A store that takes
money, like 5:00, needs **Pro (reported ~$20/month)**. The throwaway dry-run project fits on
Hobby. Hosting for 5:00 is decided in its brainstorm, where Shopify vs custom Next.js +
Stripe is also chosen.

### 7.2 `templates/web/` gates

One command runs every local gate: **`pnpm check`**.

| Gate | Tool | Pass condition | Local | CI |
|---|---|---|---|---|
| Types | `tsc --noEmit` | `strict` + `noUncheckedIndexedAccess`; no `any` unless the line has an `eslint-disable` **with a reason** | ✓ | ✓ |
| Lint | ESLint (`next`, `typescript-eslint`, `jsx-a11y`) | zero errors; disable comments must carry a description; Tailwind arbitrary colour values (`bg-[#…]`) banned in favour of tokens | ✓ | ✓ |
| Format | Prettier `--check` | no diffs | ✓ | ✓ |
| Unit | Vitest | all pass | ✓ | ✓ |
| E2E | Playwright, mobile (390×844) and desktop (1440×900) | critical flows pass; screenshots saved as review evidence | ✓ | ✓ |
| Accessibility | `@axe-core/playwright` in every e2e page | zero `serious` or `critical` violations | ✓ | ✓ |
| Visual regression | Playwright `toHaveScreenshot` on key pages | no unexpected pixel diffs | — | ✓ |
| Lighthouse | `@lhci/cli` against the **Vercel preview URL** | performance ≥ 0.90, accessibility ≥ 0.95, best practices ≥ 0.95, SEO ≥ 0.95 | — | ✓ |
| Secrets | gitleaks | none found | (hook) | ✓ |

- **Why visual regression runs only in CI:** screenshots render slightly differently on macOS
  and Linux, so baselines are made on Linux. A manually triggered workflow
  (`update-snapshots`, run on the feature branch) regenerates and commits them. The frontend lens
  sees the before/after images.
- **Why Lighthouse runs only in CI:** it needs the deployed preview. It's triggered by Vercel's
  `deployment_status` event for the Preview environment.
- **Design tokens** live in `src/styles/tokens.css` and are mapped into the Tailwind theme.
  Components use tokens, not raw values.
- **Project owner-only paths** (in `projects.json`, enforced by `gate-self-modification`):
  `.github/workflows/`, `.claude/settings.json`, `lighthouserc.json`, `eslint.config.*`,
  `tsconfig.json`, the budget wrapper and provider config (section 8). Loosening a gate is the
  owner's call.

### 7.3 Project CI (`templates/web/.github/workflows/`)

- `ci.yml`: on every PR to `dev` or `main`. Runs install (`pnpm install --frozen-lockfile`),
  types, lint, format, unit, e2e + axe, visual, gitleaks, and uploads screenshots and reports as
  artifacts. It's a **required status check** on `dev` and `main`.
- `lighthouse.yml`: on a successful Preview deployment, runs LHCI against its URL.
- `update-snapshots.yml`: manual trigger only, feature branches only.

### 7.4 `templates/ios/` (designed now, built when first needed)

- Swift + SwiftUI. The Xcode project is generated from a text `project.yml` by **XcodeGen**, so
  the agent never hand-edits Xcode's fragile project file.
- Gates: SwiftLint (strict), swift-format (`lint --strict`), XCTest unit tests, XCUITest on a
  simulator with screenshots attached and exported as evidence, an accessibility audit
  (`performAccessibilityAudit()` in UI tests, plus checks at the largest Dynamic Type size,
  VoiceOver labels and contrast).
- CI on GitHub's macOS runners.
- Signing certificates and App Store Connect keys go only through `ho_secret_to_file`.
  TestFlight and App Store uploads are owner-run scripts.
- Needs full Xcode and a paid Apple Developer account, both installed or bought by owner
  scripts at the time.

### 7.5 `.harness/bin/new-project web|ios <name> --key <KEY> --public|--private`

Creating a repo, pushing its first `main`/`dev`, and setting protection are all things the hooks
forbid the agent to do, so they're **one owner handoff**:

1. **Agent:** checks the name and key are unused, copies the template into
   `work/owner/<id>/repo/`, fills in name/key, makes the initial commit locally.
2. **Agent:** generates handoff `new-project-<name>`. The owner's script will:
   - `gh repo create Thebigtuna88/<name>` with the chosen visibility;
   - push the initial commit to `main` and `dev`, and set `dev` as default;
   - turn on "automatically delete head branches", squash-merge only;
   - apply branch protection to `main` and `dev` (public repos, or private with Pro), or record
     `local-only`;
   - optionally link the repo to Vercel.

   Each step is a `ho_check`.
3. **Owner** runs it and pastes the block. **Agent** verifies.
4. **Agent:** clones into `projects/<name>/` and opens a FORGE PR (its own ticket) adding the
   project to `projects.json`.

Each project gets its own `CLAUDE.md` (pointing to the FORGE charter, giving its key) and a
`.claude/settings.json` that registers **FORGE's hooks by absolute path**. The gates therefore
apply even if Claude Code is started inside the project folder.

---

## 8. Paid APIs, image generation and budget

### 8.1 Decision: Tier C only for now (2026-10-15)

The owner chose **Tier C**: images are made outside the harness (any web app) and dropped into a
folder. **Paid API spend is $0.** The adapter and budget wrapper are still built and tested in
Phase 6, so adding Higgsfield, fal.ai or any other provider later is a new adapter file, a
config line and an owner handoff, not a redesign. Prices researched on 2026-10-15 are recorded
in `docs/decisions/2026-10-15-image-generation-tier.md` for when that day comes.

### 8.2 Where it lives

Image generation is a **local, dev-time tool** in each web project (from `templates/web/`). It
never runs inside a deployed site.

```
src/lib/imagegen/
  index.ts              generateImage(prompt, options) → { file, costUsd, provider, model }
  types.ts              ImageProvider interface
  providers/manual.ts   Tier C: imports files from the inbox folder, cost 0
  providers/<paid>.ts   added later, one file per provider
src/lib/spend/
  budget.ts             the budget wrapper (every paid call goes through it)
  ledger.ts             append-only ledger
imagegen.config.json    { "provider": "manual" }     ← the one-line switch
assets/inbox/           owner drops images here (gitignored)
assets/generated/       imported/generated images (committed)
```

CLI for the agent: `pnpm imagegen "<prompt>" --out <path>` and `pnpm imagegen import`.

### 8.3 The interface

```ts
interface ImageProvider {
  id: string;
  estimateCostUsd(req: ImageRequest): Promise<number>;   // before the call
  generate(req: ImageRequest): Promise<ImageResult>;      // { file, costUsd, model, requestId }
}
```

- `generateImage()` picks the provider named in `imagegen.config.json`. Paid providers are only
  ever called through `budget.run()`.
- **The `manual` provider** lists new files in `assets/inbox/`, moves them to
  `assets/generated/<slug>.<ext>` with a sidecar `.json` (prompt or note, source app, date) and
  records a $0 ledger entry. A "generate" call on `manual` prints which file it is waiting for
  rather than pretending to generate.

### 8.4 Budget wrapper (`budget.run(provider, request, fn)`)

1. Reads the provider's entry in **`~/code/forge/.harness/spend-limits.json`** (owner-only). If
   the file or entry is missing or malformed, or the entry says `"enabled": false`, it **refuses**.
2. Takes a lock (`mkdir` lock directory), sums this calendar month's (UTC) ledger entries for
   that project and provider, and adds the estimate. If that total would exceed
   `monthly_cap_usd`, it **refuses** without calling.
3. Writes a `pending` ledger entry (the reservation), releases the lock, makes the call, then
   writes the final entry with the actual cost (0 if the provider refunds a failure).
4. An unreadable ledger means refuse (fail closed).

**Ledger** (`~/code/forge/.harness/ledger/<project>.jsonl`, gitignored, one line per call):
`{ at, project, provider, model, status, est_usd, cost_usd, prompt_sha256, output_path, request_id }`.
Prompts are stored only as hashes. The prompt text lives in the image's sidecar file.

### 8.5 `spend-limits.json` (owner-only)

```json
{
  "currency": "USD",
  "providers": {
    "manual":     { "enabled": true,  "monthly_cap_usd": 0 },
    "higgsfield": { "enabled": false, "monthly_cap_usd": 0,
                    "hosts": ["api.higgsfield.ai"],
                    "key_vars": ["HIGGSFIELD_API_KEY", "HF_API_KEY_ID", "HF_API_KEY_SECRET"],
                    "commands": [] },
    "fal":        { "enabled": false, "monthly_cap_usd": 0,
                    "hosts": ["fal.run", "queue.fal.run"], "key_vars": ["FAL_KEY"], "commands": ["fal"] }
  },
  "payments": { "hosts": ["api.stripe.com"], "key_vars": ["STRIPE_SECRET_KEY"], "commands": ["stripe"] },
  "always_blocked": ["sk_live_", "rk_live_"]
}
```

`gate-spend` (section 5) reads every provider's `hosts`, `key_vars` and `commands` (its
command-line tools), the `payments` section's (8.7) and `always_blocked` from this file, so a paid
host is blocked outside the wrapper even while the provider is disabled. Every provider but
`manual`, and `payments`, must hold all three lists (empty is fine, missing is malformed and
refuses everything). FRG-5's file also lists `replicate` and `openai` (disabled), so their
hosts and keys are blocked too.

### 8.6 Turning on a paid provider later

It takes one ticket and one owner handoff:
1. A PR adds `providers/<name>.ts` with tests (a fake HTTP server, no real calls). The `spend`
   lens is required.
2. The owner merges a PR to `spend-limits.json` that sets `enabled: true` and a cap.
3. The owner runs a handoff that:
   - confirms the live price;
   - tops up a **prepaid** balance;
   - confirms **auto top-up is OFF** (`ho_confirm`);
   - stores the key with `ho_secret_to_file` in the project's gitignored `.env`.
4. `imagegen.config.json` switches provider.

### 8.7 Other spend

- **Payments (Stripe/Shopify)** charge customers, not the owner, so they aren't routed through
  the budget wrapper. Rule 8 keeps them in **test mode**: only `sk_test_`/test-store
  credentials, `sk_live_` is blocked everywhere, and switching to live is an owner-run script.
- **Codex review:** with a ChatGPT plan it costs a flat subscription. If the owner chooses an
  OpenAI API key instead, the Phase 1 login handoff also sets a **monthly usage limit in the
  OpenAI dashboard** (`ho_confirm`), because codex calls can't go through the project's wrapper.
- **Hosting (Vercel), GitHub, Apple:** subscriptions bought only by owner scripts.

---

## 9. Memory, continuity and the workflow commands

### 9.1 What is remembered where

| Store | Holds | Committed? | Who changes it |
|---|---|---|---|
| `CLAUDE.md` | the charter: rules, conventions, the CONTINUE protocol | yes | PR (owner-merged if it touches rules) |
| Claude Code native memory (`MEMORY.md` index + one file per memory) | owner preferences, corrections and confirmed approaches, **each with its why** | no (machine-local) | agent, whenever the owner corrects or confirms something |
| `docs/decisions/<date>-<slug>.md` | durable decisions: context, decision, alternatives | yes | PR |
| `.harness/state/CONTINUE.md` | the next action + in-flight reasoning | no (gitignored) | agent, **rewritten** at the end of each session |
| GitHub Issues | the backlog, including every deferred finding | on GitHub | `ticket` |
| `work/` | review and handoff evidence | no (gitignored) | runner / handoff tools |

No other memory plugin is used.

**Where native memory lives.** Claude Code keeps memory per project folder, so a session started
in `~/code` and one started in `~/code/forge` use **different** memory folders. Rule: **always
start Claude Code in `~/code/forge`.** The memories saved while writing this spec (under the
`~/code` project) are moved into FORGE's memory folder in Phase 1, and `status` prints which
memory folder is active.

### 9.2 `CONTINUE.md`

Rewritten, never appended. Under 100 lines (`status` warns past that). Fixed headings:

```
# CONTINUE — updated <utc>
## Next action        (exactly one step)
## In flight          ticket · branch · worktree · PR# · head sha · lens states
## Reasoning          why this is the next step; anything half-decided
## Blocked on         owner handoff ids / questions, or "nothing"
```

When it's rewritten: the charter requires it before the agent ends a working session, and
whenever the owner says "stop", "pause" or "wrap up". `status` flags it **stale** if it's older
than the newest commit or handoff.

### 9.3 `CONTINUE FORGE`

When the owner types `CONTINUE FORGE`, the agent:
1. runs `.harness/bin/status`;
2. reports exactly three headings: **Where we are**, **Next action** (one step), **Blocked on**;
3. **stops and waits.** It takes no other action.

If git and `CONTINUE.md` disagree, git wins, and the report says so. If any part of `status`
failed, the report says **"state unknown"** for that part, never "nothing open".

### 9.4 `.harness/bin/status` (read-only)

For FORGE and every project in `projects.json`, it prints:
- current branch, clean or dirty, ahead/behind `origin/dev`, last 5 commits on `dev`;
- worktrees (`git worktree list`);
- open PRs (`gh pr list`), each with its review state from `work/*/review.md` or `rounds.log`;
- open issues (`gh issue list`);
- protection: `github` or `local-only`;
- unverified handoffs (no `VERIFIED.txt`), with title and age;
- `mode.json` summary and the count of `WOULD-DENY` entries in `observed.log` since the last
  status;
- the active memory folder;
- `CONTINUE.md` (with a stale warning if needed).

Each part prints `OK …` or `UNKNOWN: <error>`, never an empty list on failure. It exits
non-zero if any part is UNKNOWN.

### 9.5 Workflow commands

- **`ticket new <repo> "<title>"`** creates a GitHub Issue and renames it `<KEY>-<n>: <title>`,
  where **`n` is the issue number** (unique, no counter to keep). `ticket list` is a shortcut
  for open issues.
- **`worktree add <KEY>-<n> <slug>`** fetches, then creates
  `~/code/forge-worktrees/<KEY>-<n>-<slug>` on `feature/<KEY>-<n>-<slug>` from `origin/dev`
  (from the right repo for the key), and creates `work/<KEY>-<n>-<slug>/`.
- **`worktree remove <KEY>-<n>-<slug>`** removes it locally, only after its PR has merged. It
  never deletes branches; GitHub's auto-delete does that.
- **`.harness/lib/pr.sh`** (`pr create`) opens a PR into `dev` titled `<KEY>-<n>: <title>`,
  with a body linking the issue, a summary, and the evidence of `pnpm check` or `tests/run.sh`.

---

## 10. Testing and conformance

### 10.1 `bash tests/run.sh`

One entry point. It runs, in order:
1. `shellcheck` on every shell file (`.harness/bin`, `.harness/lib`, `.claude/hooks`, `tests`);
2. unit tests (`tests/unit/*.test.sh`);
3. conformance (`.harness/bin/conformance`, section 5.5);
4. with `--templates` (slow, needs network, always on in CI): scaffolds `templates/web` into a
   temp folder and runs `pnpm install` and `pnpm check` there.

It prints one line per test and finishes with exactly `ALL PASS` or `FAILED (<n>)`, exiting 0
or 1.

### 10.2 How tests stay honest and isolated

- **No test framework to install.** A small `tests/lib/assert.sh` provides `assert_eq`,
  `assert_exit`, `assert_contains`. Runtime dependencies stay at bash, git, jq, python3,
  shellcheck, gitleaks.
- **Each test runs in a fresh temp folder** with its own throwaway git repo and a local "bare"
  repo standing in for GitHub. No test touches the network or the real repos.
- **`gh` and `codex` are replaced by stubs** (`tests/stubs/`) put first on `PATH` *inside the
  test only*. The stubs record how they were called and return canned replies, for example a
  codex reply with a wrong md5. The hooks set their own `PATH`, so for them conformance copies
  the stubs into each sandbox, and the runtime's `hr_gh` runs the fake `gh` there and only
  there (FRG-4). Its answers come from files the case's setup wrote (`tests/stubs/scene.sh`
  builds a PR, its review and GitHub's answers about it).
- **Handoff tests need a terminal**, so they run the script in a pseudo-terminal
  (`tests/lib/ptyrun.py`, which also types the answers) with all four agent markers removed.
  That the test suite can do this is exactly why section 4.8 calls the TTY check a speed bump.
- **Platform:** scripts target macOS (the owner's machine) and use small helpers
  (`hr_md5`, `hr_sha256`) instead of tool-specific flags. Harness CI runs on GitHub's
  **macOS** runners, which are free for public repos.

The pty driver kills, when a run ends, every descendant it saw in its process snapshots, after a
best-effort check that each is still the same process. A process that detaches itself (fork,
setsid, parent exits) between two snapshots can escape, whether to evade cleanup or as ordinary
daemon start-up, and it and its children keep the permissions of the user running the tests; the
identity check has one-second precision. None of the unprivileged approaches tested on macOS
closes either gap. The driver is not a security sandbox; the tests start no daemons. Accepted as
a known limit, with cleanup steps and when to revisit it, in
`docs/decisions/2026-10-25-pty-driver-cleanup-limit.md`; stronger isolation is FRG-28.

### 10.3 Required test coverage (minimum)

| Area | Must prove |
|---|---|
| `handoff.sh` | refuses without a TTY and with `CLAUDECODE` set; each helper's PASS/FAIL/INFO; secret never appears in logs, screen capture or block; refuses a non-gitignored secret file; `ho_abort` produces `result: FAILED`; live redaction (FRG-14): no piece of a secret on screen or in the log, mid-step or after a killed run, split across writes or overlapping another; secrets on no command line and not in the step's environment; a missing or changed filter refuses, a filter dying mid-step ends the run FAILED; `ho_redact_file` hides stored values and refuses unsafe files |
| `handoff_redact.py` | shows text at once; holds back only a possible start of a secret, shows it once ruled out or at the end; longest secret whole; private log, never through a symlink; ignores SIGINT |
| `handoff lint` | rejects each forbidden pattern in 4.4, one test each |
| `handoff verify` | fails on each of checks 1–8 in 4.5, one test each; passes on a genuine run |
| `hookrt.sh` | missing, malformed, unknown-value and missing-key `mode.json` all mean enforce; load failure denies |
| each hook | deny and allow fixtures (conformance), including quoting tricks, `-C`, aliases, chained commands |
| `review-lens` | read-proof mismatch means INVALID; CLEAN with findings is rejected; refused mechanisms; findings-hash normalisation; stall after two identical rounds; required-lens computation; a new commit invalidates CLEAN; finalize refuses an incomplete set |
| `gate-merge-on-review` | edited `review.md` text, a stale sha, a moved merge-base or `--auto` all deny |
| `review-diff.sh` | the same bytes whatever the repository, global or environment settings; binary files shown as text; a missing commit, two merge bases or a forged object refused |
| `status` | a failing `gh` prints `UNKNOWN`, never an empty list |
| budget wrapper (Vitest, in the template) | refuses over cap, on a missing or malformed limits file, on a disabled provider; two concurrent calls can't both pass a cap that allows one; ledger entries are complete |

### 10.4 Test-first for fixes

Every review finding that's fixed in code gets a test that **fails before the fix and passes
after** (rule 6). The PR shows both runs.

### 10.5 Acceptance: the Phase 7 dry run

The harness is accepted only when a throwaway web project (`projects/dryrun`, key `DRY`) has
gone through: `new-project` handoff → ticket → worktree → change with a UI component → PR →
`pnpm check` + CI green → `code`, `security` and `frontend` lenses through at least one real
fix round → finalize → gated merge to `dev` → owner merges `dev`→`main` → **owner-run
production deploy handoff** verified. Every problem found becomes a FRG ticket and is fixed
before 5:00 starts.

A pass proves the workflow, and the gates against ordinary commands and mistakes. It doesn't
prove the agent couldn't get around them on purpose (L1, L12, L13): that rests on what its
credentials and macOS user can't do (FRG-26).

---

## 11. Known limits (what FORGE does not protect against)

The hooks are **guardrails against mistakes and shortcuts**, not a sandbox. Each gap below has
its mitigation and, where one exists, a stronger option the owner can adopt later.

| # | Gap | Why | Mitigation now | Stronger option later |
|---|---|---|---|---|
| L1 | **Indirect commands.** A guarded action inside a script file (`bash x.sh` containing `git push origin main`), or a Node/Python program calling a paid API, isn't seen by the command-matching hooks. | Hooks see the command line, not what a program does. | GitHub branch protection (public repos); no paid key exists while Tier C is in force; `spend` and `security` lenses; charter rule 9. | Run the agent under a separate OS user with no access to keys. |
| L2 | **Same GitHub identity.** The agent uses the owner's `gh` login, so GitHub can't tell agent from owner; only the local hook stops a `dev`→`main` merge. | Personal accounts can't use bypass lists or required reviewers against yourself. | `gate-merge-on-review` (base must be `dev`, API merges denied), `deny-repo-admin`. | A separate free **machine account** for the agent with write access, with `main` requiring the owner's approving review. |
| L3 | **Handoff runtime checks are a speed bump.** The TTY and `CLAUDECODE` checks can be faked (the test suite does it). | Any program with a shell can fake a terminal. | Evidence = the owner's paste matching `RESULT.txt`, frozen script sha, unchanged runtime; `handoff lint`. | — (the owner's paste is the real control) |
| L4 | **The paste file is recorded from any prompt-shaped input.** Since FRG-5 the `capture-owner-paste` hook, not the agent, saves the paste, verify accepts only a recorded one, and the agent's file tools can't write the paste, its record or the other evidence files (FRG-1 review S1, decision 2026-10-16). But Claude Code also runs UserPromptSubmit hooks on turns it starts itself (a scheduled task, a background agent reporting back, another session's message) and doesn't say who wrote the text, so an agent that sent a forged block through one of those would get it recorded. And a shell command can still write the files (L1; the guard's Bash part only observes). | Claude Code has no "owner-signed" input, and its hook input names no sender. | The paste and each of those channels are visible in the chat transcript; verify cross-checks `RESULT.txt`; the charter forbids putting a block into those channels. Forgery takes a deliberate act, not a slip. | Agent runs as a separate macOS user (FRG-26), with evidence it can't write. |
| L11 | **Handoff steps run arbitrary programs.** The grammar limits shell syntax, but an allowed step (`python3 -c …`) can do anything the owner can: forge evidence, or deliberately get a known secret past live redaction (write to the terminal device directly, split it with screen codes, encode it) (FRG-1 review S15, C3, S18). | The agent writes the scripts the owner runs. | Allowlist grammar; secret-file rule; live redaction of the screen and logs and redaction of evidence (FRG-14, for secrets printed by accident); owner sees each step's command on screen. | FRG-30: reject inline interpreters, with runtime replacements (after FRG-26's checkpoint). |
| L12 | **Evidence the agent writes can be forged or swapped by the agent** (FRG-4 review round 1). The merge gate re-checks `review.md` and the reply files (binding, recomputed diff, hashes, read-proof), which proves which code they describe, not that a reviewer wrote them: the agent could write CLEAN replies and a matching `review.md` itself. Likewise a second command running at the same moment could replace a `--body-file` between the scan and `gh` sending it. | Agent, reviewer runner and files share one macOS user; nothing on disk is beyond the agent's reach. | The gates stop mistakes and shortcuts, not a deliberately dishonest agent (as L1, L4); every PR touching an owner-only path is merged by the owner; review summaries are posted on the PR; charter rules 3, 6 and 9. **Decided 2026-10-18** (owner): accepted as a known limit. | Agent (and codex) run as separate macOS users, or a GitHub machine account whose merges need the owner's approval (L2). |
| L13 | **Commands deliberately disguised from the gates** (FRG-4 review rounds 6-10). A command built to hide that it runs `gh`, `git` or a deploy tool (its name or words spelled so the text check doesn't recognise them) may not be judged as that tool. Accepted risk, not fixed: round 10's SEC-1, deferred to FRG-26. | The hooks read a command's text; what the shell makes of it can't be fully predicted, and each patch was followed by a new spelling. | The gates recognise ordinary commands and mistakes (conformance proves each listed case); the round 2-9 checks stay; charter rule 9; GitHub branch protection on `main` and `dev`. Against a deliberate attempt, nothing technical holds while the agent uses the owner's admin login (L2). **Decided 2026-10-19** (owner): `docs/decisions/2026-10-19-disguised-commands-known-limit.md`. | FRG-26: define what the agent's own GitHub credentials and macOS user must be unable to do, and test each restriction. A separate account alone isn't enough. |
| L5 | **Read-proof proves access, not diligence.** A reviewer can hash the diff and still review it badly. | — | Adversarial prompt, structured findings, multiple lenses, stall rule, owner merges `main`. | Owner skims `review.md` for risky PRs. |
| L6 | **Heuristic hooks.** The Stop hook and the Bash part of `guard-live-checkout` guess from text. | Natural language and shell are open-ended. | They start in observe; the owner promotes them by PR after reviewing `observed.log`. | — |
| L7 | **Local-only evidence.** `work/` and the spend ledger live on one Mac. | Gitignored by design (may hold logs/screens). | PR comment summary of every review; prepaid wallets as the real spend cap; deleting the ledger doesn't remove a provider's own limits. | Back up `work/` with Time Machine. |
| L8 | **Private projects on GitHub Free** have no server-side protection. | Plan limit (section 3.2). | Recorded as `local-only`, shown by `status`. | GitHub Pro. |
| L9 | **Claude Code or tool updates** can change hook input formats or CLI flags. | External software. | Conformance runs on every `tests/run.sh` and in CI, so breakage shows as FAILED. | — |
| L10 | **Prices and terms change** (Vercel, GitHub, Higgsfield, OpenAI). | External. | Every paid step's handoff re-checks the live price with `ho_confirm`. | — |

---

## 12. Build order

Each phase is one or more tickets, each with its own branch, worktree, PR and review. Ticket
numbers are GitHub issue numbers, so issues are created in phase order. GitHub numbers issues
and PRs from the **same** counter, so the exact numbers are fixed when the issues are created.

**Who merges.** Phases 1–3 and 6 change owner-only paths (`.harness/lib/`, `.claude/hooks/`,
`.claude/settings.json`, `mode.json`, `spend-limits.json`, `.github/workflows/`), so **the owner
merges those PRs**, through an `owner-merge` handoff (`ho_confirm` + `gh pr merge <n> --squash
--match-head-commit <sha>`) after every required lens is CLEAN. The agent may merge only PRs
that touch no owner-only path.

**Review before the runner exists.** In Phases 1–2, codex is run by hand (section 6.8). From
Phase 3 on, `review-lens` reviews every PR, including the harness's own.

| Phase | Delivers | Exit criteria |
|---|---|---|
| **0. Spec and plan** | this spec, `docs/plans/2026-10-15-harness-plan.md` | owner approved both |
| **1. Skeleton and handoff runtime** | `git init`, root commit (spec, plan, decisions, `.gitignore`, `README.md`); `CLAUDE.md` charter; `handoff.sh`; `handoff new/ready/lint/verify`; `tests/run.sh` + assert lib + handoff tests. **Handoffs:** (a) install `gh`, `pnpm`, `gitleaks`, `shellcheck`, `codex`; (b) `gh auth login`, `codex login` (plan or API key + usage limit), git noreply identity; (c) create `Thebigtuna88/forge` (public), push root commit to `main` and `dev`, default `dev`, protection, auto-delete branches; then push FRG-1, open PR, hand-run codex review; move memories into FORGE's memory folder | `ALL PASS`; handoffs a–c **verified**; FRG-1 merged to `dev` by owner; bootstrap handoffs re-run if review changed the runtime (4.9) |
| **2. Hooks and conformance** | `hookrt.sh`, `mode.json`, `self-modification-paths.json`, `deploy-targets.json`, all 12 hooks in section 5.3, `.claude/settings.json`, `conformance`, fixtures; harness CI (`ci.yml` on macOS) | conformance PASS under the live `mode.json`; each enforce hook shown denying in a real session (screenshot/transcript) |
| **3. Review runner** | `review.sh`, `review-lens` subcommands, `reply.schema.json`, five lens checklists, `rounds.log`, stall detection, `finalize` + PR comment; `gate-merge-on-review` wired to it | its own PR reviewed by **itself** (runner on the runner's PR) with all lenses CLEAN |
| **4. Status, worktree, ticket, CONTINUE** | `status`, `ticket`, `worktree`, `pr.sh`, `CONTINUE.md` format, CONTINUE protocol in `CLAUDE.md` | a fresh session given `CONTINUE FORGE` reports correctly; `status` shows UNKNOWN when `gh` is unplugged |
| **5. Templates and scaffolder** | `templates/web` with every gate in 7.2 and CI in 7.3; `templates/ios` README (deferred); `new-project`; `projects.json` | `tests/run.sh --templates` ALL PASS; template CI green on a scratch repo |
| **6. Spend adapter** | `imagegen` interface, `manual` provider, budget wrapper, ledger, `spend-limits.json` (manual only), `gate-spend` reading it | budget tests in 10.3 pass; `spend` lens CLEAN |
| **7. Dry run** | `projects/dryrun` (key `DRY`) taken end to end, as in 10.5; owner-run production deploy | every 1.5 criterion met; all problems found fixed via FRG tickets; owner reviews `observed.log` and decides observe→enforce promotions |
| **8. 5:00** | brainstorm with the owner (brand, audience, Shopify vs Next.js + Stripe explained, drop model, iOS ever?), then a spec and plan, built in `projects/five-oclock/` | starts **only** after Phase 7 |
