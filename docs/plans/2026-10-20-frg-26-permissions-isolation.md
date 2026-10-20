# FRG-26: Permissions isolation — final plan

- **Status:** **Stage 1 approved by the owner, 2026-10-20.** The checkpoint after the
  feasibility tests stays. Until it, nothing changes in FORGE's settings, the owner's Mac
  accounts or home-folder permissions. Unexpected permissions, costs or limitations are
  reported before going further. FRG-26 does not close L12; FRG-27 is next.
- **Ticket:** FRG-26 (#26). Branch `feature/FRG-26-permissions-isolation`.
- **Follow-up:** FRG-27 (#27), review isolation, starts immediately after this one.
- **Research:** 2026-10-20, against current official docs (sources at the end).
- **Stage 1 code:** `tests/permissions/github-throwaway.sh` (run only from owner handoffs),
  unit-tested without GitHub by `tests/unit/github-throwaway.test.sh`.

## 1. What this ticket does, in plain words

Today I run as **your** Mac user (an administrator) with **your** GitHub login (a repository
admin). FORGE's hooks catch ordinary commands and mistakes, but not a command deliberately
disguised to get past them (known limit L13).

FRG-26 gives me **my own Mac user and my own GitHub account**, set up so that **macOS and GitHub
themselves refuse** the harmful things, whatever command I run. Every restriction is then tried
for real and must be refused by GitHub or macOS, not by a FORGE hook.

## 2. Your decisions (all 2026-10-20)

| # | Decision |
|---|---|
| D1 | 5:00 may be brainstormed and planned, but gets **no real business credentials, payment access or production deploy access** until the relevant FRG-26 protections are implemented and tested. Building 5:00 still waits for Phase 7 |
| D2 | **Test-mode payment keys count as payment access** and wait exactly like live keys |
| D3 | Before any 5:00 credential, I show you **every accepted risk that remains**, and **you decide**. Passing tests is necessary, not sufficient |
| D4 | Shape: **three building blocks** (section 4) |
| D5 | Nothing merges into `dev` without **your code-owner approval of the latest changes**. Tested against bypasses, including changing CODEOWNERS and pushing directly to `dev` |
| D6 | **Only you can update `main`.** Tested on a throwaway repo first. If GitHub can't enforce it with our account and plan, I explain the alternatives **before** changing FORGE |
| D7 | Review isolation is **FRG-27**, right after this ticket. **L12 stays open** until FRG-27's tests pass. **FRG-26 does not resolve review integrity** |
| D8 | Home-folder permissions: shown first with effects and undo; **never recursive** |

Recorded in `docs/decisions/2026-10-20-five-oclock-credentials-wait-for-frg-26.md` (commits
be724d9, 27b6472, 7b0a076 on the FRG-26 branch).

## 3. How sure we are

| Label | Meaning |
|---|---|
| **Confirmed (docs)** | Official GitHub / Apple / Anthropic documentation says so |
| **Confirmed (this Mac / repo)** | I saw it with a read-only command on 2026-10-20 |
| **Unconfirmed** | Likely, but the docs are silent or ambiguous; a test decides |
| **Goal** | What we want; proven only when its test passes |

**Stop rule:** if a test fails, or an Unconfirmed item turns out false, I stop and come back to
you before going further.

## 4. The three building blocks and exact permissions

**You: unchanged.** Still admin on the Mac and on GitHub. Two additions: your home folder closes
to other users (section 7), and you become the repo's **code owner**, the only person whose
approval lets work into `dev`.

**A. Mac user `forge-agent`: standard, not an administrator**

| Can | Cannot |
|---|---|
| Read and write its own home `/Users/forge-agent` (its own FORGE copy, worktrees, `work/`, memory) | Use `sudo` (run as administrator), or write to system folders |
| Run Claude Code, git, `gh`, codex | Open your home folder or read your keychain |
| Read the installed hooks and managed settings | Change them (owned by the system administrator account, `root`) |
| Use the network; add login items for itself | Add system services or change system settings |
|  | Read handoff secrets not deliberately given to it |

**B. GitHub helper account: free machine account, you pick the name**

- **Access:** collaborator with **write** on `Thebigtuna88/forge` (later on each project repo),
  and nothing else. It can push branches, open PRs and issues, and comment. It can merge **only
  when GitHub's protection is satisfied**. It can't change settings, protection, collaborators,
  webhooks, deploy keys or visibility, and can't delete, archive or transfer a repo.
- **Token:** classic, **`public_repo` only**, with an expiry date (proposed 90 days; renewed with
  a handoff). Not granted: `repo`, `workflow`, `delete_repo`, `admin:*`, `user`, `gist`,
  `read:org`. If a `gh` command FORGE needs turns out to require more, I stop and ask you before
  adding anything.
- **Account secrets:** you keep its password, 2-step codes and recovery codes in your password
  manager. I only ever hold the token.

**C. Hooks I can't edit or switch off**

- FORGE's hooks, and the owner-only files they read (`spend-limits.json`, `mode.json`,
  `deploy-targets.json`, the owner-only paths list), are **installed** into a root-owned folder.
- Claude Code's system settings file
  `/Library/Application Support/ClaudeCode/managed-settings.json` turns them on, with
  `allowManagedHooksOnly`.
  - **Confirmed (docs):** nothing from my side overrides that file, and only it can switch
    managed hooks off.
  - **Confirmed (docs):** only a Mac administrator can edit it, so `forge-agent` is never one.
  - **Confirmed (docs):** if the file can't be read, Claude Code silently starts without it. So
    it's readable but not writable by me, and every check confirms Claude Code reports it as
    active.
- A merged change to hooks or limits takes effect only when **you** run the install script.

## 5. Protections, enforcement, limits, tests

"Fails first" applies to every row: each test is run once **before** the protection exists and
must then succeed, to prove it can detect the gap.

| # | I must be unable to… | Enforced by | Status | Limits |
|---|---|---|---|---|
| 1 | Push to `main`/`dev`, force-push, delete them | Branch protection; helper isn't admin | Protection **Confirmed (repo)**; that a collaborator can't edit it: **Unconfirmed** → tests B1, B12, B14, M1, M5 | Feature branches stay pushable and deletable (accepted) |
| 2 | Update `main` | Ruleset "Restrict updates" with only you able to bypass, on top of protection and code-owner review | **Unconfirmed** for personal repos → section 6.2 | If not offered: alternatives first (D6) |
| 3 | Merge into `dev` without your approval of the latest changes | Code-owner review + approval of the most recent push (section 6.1) | **Confirmed (docs)** → tests B1–B16 | GitHub checks **your approval, not codex** (section 6.1) |
| 4 | Change settings, protection, rulesets, default branch, visibility, name; archive, transfer, delete | Write ≠ admin; token has no `delete_repo` | Delete, archive, visibility, default branch: **Confirmed (docs)**; the rest **Unconfirmed** → B12, B13, M4 | — |
| 5 | Read or change Actions secrets/variables, deploy keys, webhooks, collaborators, apps | Write ≠ admin | Deploy keys, webhooks, collaborators: **Confirmed (docs)**; secrets **Unconfirmed** → test | Write access can still *use* a secret through a workflow. So deploy secrets go only in GitHub Environments that need your approval, and workflows on my branches get none. Today: 0 secrets, 0 workflows (**Confirmed, repo**) |
| 6 | Change workflow files; run deploying workflows | No `workflow` scope; Environments need your approval; production deploys stay your scripts (rule 8) | Workflow files **Confirmed (docs)**; deploy gating **Goal** | A workflow file identical to one on another branch can be committed anyway (**Confirmed caveat**) |
| 7 | Widen my access (tokens, SSH keys, scopes, other repos/orgs) | You create tokens in the web UI; no `admin:public_key`; invited only to FORGE and projects | **Confirmed (docs)**; accepting invitations with `public_repo`: **Unconfirmed** → test | Fine-grained tokens don't work for collaborators (**Confirmed, docs**), so the token reaches every repo the helper is invited to |
| 8 | Act as you (your `gh` login, SSH keys, keychain, browser) | Separate Mac user + your home closed | **Goal**; gap **Confirmed (this Mac)** today | — |
| 9 | Reach repos beyond FORGE and projects | Helper invited only there | **Confirmed (docs)** | Public repos are readable by anyone (accepted) |
| 10 | Read your home, keychain, configs, browser profiles | macOS permissions: `chmod 700 /Users/atl` | **Goal** | Shared places (`/Users/Shared`, `/tmp`) stay readable: no secrets go there |
| 11 | Change the hooks and owner-only limits, or switch hooks off | Block C | Mechanism **Confirmed (docs)**; FORGE's use **Goal** | `forge-agent` must never become admin |
| 12 | Rewrite review replies | **Moved to FRG-27.** L12 stays open | — | — |
| 13 | Become admin, use `sudo`, add system services, change system settings | Standard user | **Confirmed (standard macOS)** → test | It can add login items for itself (accepted) |
| 14 | Read handoff secrets not given to me | `ho_secret_to_file` saves into a folder only you can read; giving me a file is an explicit step of yours | **Goal**; changes the handoff runtime (owner-only) | — |

## 6. GitHub branch rules and their bypass tests

### 6.1 `dev`: your approval of the latest changes (D5)

Settings, applied by you:
- PR required, 1 approval, **review from Code Owners** (`.github/CODEOWNERS` = `* @Thebigtuna88`).
- **Approval of the most recent push**, and stale approvals dismissed.
- No force-push, no deletion.

**What GitHub guarantees** (Confirmed, docs): nothing merges into `dev`, by any command, unless
you approved its latest commit, and weren't its author. The helper can't count, for two reasons:
- authors can't approve their own PRs;
- it isn't a code owner.

GitHub reads CODEOWNERS from `dev` itself, so a PR changing CODEOWNERS still needs your approval.
CODEOWNERS also joins the owner-only paths.

**What it doesn't guarantee:** that codex ran or said CLEAN. GitHub checks your approval.
Until FRG-27, the review summary comes from files I could edit (L12).

**Tests** (helper's real token, throwaway repo; GitHub's exact error saved as proof):

| # | Helper tries… | Must happen |
|---|---|---|
| B1 | Push straight to `dev` | Refused |
| B2 | Push to `dev` editing `.github/CODEOWNERS` | Refused |
| B3 | PR changing CODEOWNERS to itself, then merge | Refused |
| B4 | Same with a new CODEOWNERS at the root or in `docs/` | Refused |
| B5 | Approve its own PR | Refused |
| B6 | Merge with no approval | Refused |
| B7 | You approve → it pushes one more commit → merges | Refused |
| B8 | You approve → it pulls `dev` into the PR ("update branch") → merges | Refused |
| B9 | You approve a PR aimed elsewhere → it re-aims it at `dev` → merges | Refused; if GitHub allows it, recorded as a gap and you decide |
| B10 | Merge with the admin override | Refused |
| B11 | Auto-merge on an unapproved PR | May queue, must not merge |
| B12 | Change or delete `dev`'s protection | Refused |
| B13 | Create a ruleset or change settings | Refused |
| B14 | Force-push or delete `dev` | Refused |
| B15 | (Read-only) "Allow GitHub Actions to approve pull requests" | Off |
| B16 | Control: you approve, nothing changes, it merges | **Allowed** |

### 6.2 `main`: only you (D6)

- **Step 0, look only:** your handoff reports which bypass choices GitHub offers a personal repo.
  If "only you / repository admin" isn't one of them, **we stop and I explain the alternatives**:
  - (a) move the repos into a free GitHub organisation (can restrict pushes on public repos);
  - (b) rely on your approval alone;
  - (c) a paid plan, price confirmed first.

  Nothing on FORGE changes until you choose.
- **Rule:** ruleset on `main` with Restrict updates, Restrict deletions and Block force pushes;
  bypass only you.

| # | Who tries | Must happen |
|---|---|---|
| M1 | Helper pushes to `main` | Refused |
| M2 | Helper's `dev`→`main` PR, **approved by you**, merged by helper | Refused |
| M3 | Helper merges with the admin override | Refused |
| M4 | Helper changes or deletes the ruleset or protection | Refused |
| M5 | Helper force-pushes or deletes `main` | Refused |
| M6 | Control: **you** merge `dev`→`main` | **Allowed** |

## 7. Your home folder (D8)

- **Today (Confirmed, this Mac):** `/Users/atl` is `drwxr-x---`, group `staff`, plus "everyone:
  deny delete". Any account in `staff` can open it and read whatever inside is group-readable:
  `~/code`, `~/.codex`, `~/.claude`, `~/Applications`, `~/Public`. New Mac users join `staff` by
  default.
- **Change:** `chmod 700 /Users/atl`. It touches the folder itself only and is **not recursive**.
  Nothing inside changes. The deny-delete rule stays, and the script checks it before and after.
- **Effects (Confirmed, this Mac):**
  - You and your apps: none.
  - Root services (Spotlight, Time Machine): none.
  - The 37 running service accounts: none of them is in `staff`.
  - Today `staff` holds only `root` and you, so nothing loses access. It takes effect once
    `forge-agent` exists.
  - File Sharing (your Public folder, guest access on): guests aren't in `staff`, so nothing
    changes for them.
- **Undo:** `chmod 750 /Users/atl` restores exactly today's state. Both scripts print
  `ls -led /Users/atl` before and after.

## 8. How it gets done: stages, in order

Every step that changes your Mac or GitHub is an **owner handoff**: you run
`bash …/OWNER-RUN.sh` and paste back the result. Every step lists its check and its undo. I
never run those scripts myself. The GitHub and Mac tests run inside your handoffs, outside Claude
Code. If I ran "push to `main`" myself, even expecting a refusal, I'd be getting around a hook
(rule 9). Read-only checks (permission level, token scopes, protection settings) I can run myself.

**Stage 1: GitHub feasibility, on a throwaway repo only.** FORGE and your Mac are untouched.
1. I write the stage-1 test scripts (they handle the helper's token). codex reviews them
   (`code` + `security`) **before** you run anything.
2. Handoff: create the helper account in your browser, turn on its 2-step login, save its
   password and codes in your password manager. It reports the account name.
3. Handoff: create the throwaway public repo (`dev`, `main`, CODEOWNERS), invite the helper with
   write, accept as the helper. It saves the helper's classic token (`public_repo`, 90 days)
   with `ho_secret_to_file`, into `work/owner-secrets/frg26/helper.env` (mode 600, folder 700,
   gitignored).
   *Limitation found while building:* `ho_secret_to_file` only writes inside a gitignored path
   of a git checkout. Until stage 3, I run as your user, so I can read that file. It holds only
   the helper's token, which has far less power than your own login (already reachable to me
   today). Item 14 moves handoff secrets out of my reach in stage 3.
4. Handoff: **fails-first** run of B1–B16 and M1–M6 with no protection.
5. Handoff: **Step 0** look at the ruleset bypass choices. If "only you" isn't offered → stop,
   alternatives (D6).
6. Handoff: apply the `dev` rules and the `main` ruleset on the throwaway repo; run B1–B16 and
   M1–M6. All must pass.
7. **Checkpoint with you:** results, any gap (for example B9), and whether to carry on.
   *Undo for stage 1: delete the throwaway repo; revoke the token.*

**Stage 2: build and review.** Nothing in your environment changes.
- Install and uninstall scripts for block C (managed settings, hooks, owner-only config).
- Hooks read owner-only config from the installed copy.
- Launcher script.
- The repeatable permissions test script.
- Conformance updates: block C active, CODEOWNERS valid.
- `.github/CODEOWNERS` and the owner-only paths entry.
- The handoff secret-folder change (item 14).
- Spec 11 updates: L2 and L13 narrowed by what the tests prove; **L12 stays open**; L1 and L4
  unchanged.
- `bash tests/run.sh` → `ALL PASS`; codex `code` + `security` rounds to CLEAN.
- **You merge**, because this touches owner-only paths.

**Stage 3: the Mac.** Each step is a handoff, with check and undo.
1. Create `forge-agent` (standard user). Check: not in `admin`. *Undo: delete the user.*
2. **Fails-first:** as `forge-agent`, read `~atl/code` → succeeds (the gap exists). It's
   harmless because nothing runs as `forge-agent` yet.
3. Home folder `chmod 700` (section 7). Re-run → "Permission denied". *Undo: `chmod 750`.*
4. **Fails-first** for block C: a `disableAllHooks` setting in `forge-agent`'s own settings
   switches hooks off. Then install block C (asks your Mac password). Check: Claude Code reports
   "Enterprise managed settings (file)", and the same setting no longer switches hooks off.
   *Undo: the uninstall script.*
5. Set up `forge-agent`:
   - its own FORGE copy;
   - the helper token;
   - Claude Code and codex logins (on your existing plans);
   - a one-time copy of my memory, `work/` evidence and CONTINUE.md from your copy.
6. Mac tests as `forge-agent` (items 8, 10, 11, 13, 14) → all refused by macOS.

**Stage 4: GitHub on FORGE.**
1. Handoff: invite the helper to FORGE (write); apply the tested `dev` rules and `main` ruleset.
2. My read-only checks on FORGE: helper permission = `write`, token scopes = `public_repo`,
   protection and ruleset as tested, Actions approval setting off.
3. **Live proof:** the first real PR through the new flow. You approve, I merge as the helper.
   Plus one refused attempt (B6) on that PR before your approval.

**Stage 5: close.** FRG-26 is done when every item in section 5 (except 12) is enforced and
tested, or you've accepted it in writing as a known limit. Then **FRG-27 starts immediately**.

## 9. Before any 5:00 credential (D1–D3)

| 5:00 access | Needs these items tested first |
|---|---|
| Real business credentials | 7, 8, 10, 11, 13, 14 |
| Payment access, **test mode included** | the above + 5, 6 |
| Production deployment access | the above + 1, 2, 3, 4 |

**Then I show you the remaining accepted risks, and you decide.** Today that list would include
at least:
- **L12:** review evidence I can edit, until FRG-27.
- **L13:** disguised commands, reduced only as far as the tested items reach.
- **L1:** commands inside script files.
- **L4:** pasted results saved by me, until FRG-5.
- Every item still Unconfirmed after the tests.
- Any deferred findings.

## 10. Cost and what changes for you

- **Money: $0** while repos are public:
  - the helper account is free (**Confirmed, terms**: one free machine account besides yours);
  - tokens and Mac users are free;
  - Claude Code and codex reuse your existing plans with a second login (**Unconfirmed**,
    checked at login).

  A **private** 5:00 repo would need GitHub Pro for these protections (**Confirmed, docs**).
  Pro's price isn't on GitHub's own pages; other sites say about $4/month. That's a separate
  decision, with a token change (`repo`), when 5:00 gets there.
- **Your time:** roughly 2–3 hours over about 10 handoffs, across stages 1, 3 and 4 (an
  estimate).
- **Day to day:**
  1. You start Claude Code with a launcher script that asks your Mac password.
  2. You click **Approve** on each PR, instead of running a merge handoff. I then merge.
  3. Merged changes to hooks or limits take effect only after you run the install script.
  4. Commits and PRs show the helper account as author.
  5. The permissions test runs again after any change to accounts or permissions.
  6. The helper token is renewed every 90 days with a short handoff.

## 11. Not in this ticket

- **FRG-27:** review isolation (L12).
- **Claude Code's sandbox:** an optional extra fence later. Anthropic says it isn't a complete
  boundary.
- **Private repos, GitHub Pro, the `repo` token scope:** decided when 5:00 needs them.
- **File Sharing / guest access:** your call, outside FORGE.

## Sources

- [GitHub: collaborator permissions on personal repos](https://docs.github.com/en/account-and-profile/reference/permission-levels-for-a-personal-account-repository)
- [GitHub: token limits](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
- [GitHub roadmap #601](https://github.com/github/roadmap/issues/601)
- [Fine-grained tokens GA changelog](https://github.blog/changelog/2025-03-18-fine-grained-pats-are-now-generally-available/)
- [Classic token scopes](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps)
- [gh auth login](https://cli.github.com/manual/gh_auth_login)
- [Protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)
- [Ruleset rules](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets)
- [Approving PRs](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/approving-a-pull-request-with-required-reviews)
- [Code owners](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners)
- [GitHub plans](https://docs.github.com/en/get-started/learning-about-github/githubs-plans)
- [GitHub pricing](https://github.com/pricing)
- [Mandatory 2FA](https://docs.github.com/en/authentication/securing-your-account-with-two-factor-authentication-2fa/about-mandatory-two-factor-authentication)
- [GitHub Terms (machine accounts)](https://docs.github.com/en/site-policy/github-terms/github-terms-of-service)
- [Claude Code managed settings](https://code.claude.com/docs/en/managed-settings)
- [Claude Code settings reference](https://code.claude.com/docs/en/settings-reference)
- [Claude Code sandbox](https://code.claude.com/docs/en/sandboxing)
