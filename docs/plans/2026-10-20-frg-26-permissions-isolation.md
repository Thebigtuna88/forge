# FRG-26: Permissions isolation — plan, revised for a GitHub App

- **Status:** **Revised plan approved by the owner for stage 1 implementation and independent
  reviews, 2026-11-01** (draft 2 plus the owner's clarifications of the same day). It replaces the
  2026-10-20 plan (helper account), which stays in git history; section 12 lists what changed.
  Done so far (2026-11-06, from the owner's handoff): the throwaway app `frg26-throwaway-test-atl`
  was created and installed on the first throwaway only, its App ID and key were stored in
  `work/owner-secrets/frg26/` (mode 600), and the second throwaway `forge-frg26-throwaway-2` was
  created; the earlier app from 2026-11-02 (no key, never installed) was deleted (2026-11-07, app
  check passed). **Stage 1 part 0 ran on 2026-11-11 and stopped: test A2 failed, a failed
  protection** (section 6, "A2, 2026-11-11"). Item 9 is unresolved until the owner approves a
  revised protection claim. The owner approved an investigation on the throwaway repos
  (2026-11-11; run 2026-11-14, section 6), then resumed the later stage 1 handoffs (2026-11-15,
  section 6), regenerated and reviewed before they are given. Nothing on the Mac or in FORGE's
  settings has changed.
- **Proposed revision, 2026-11-15:** section 13 records the request-forwarding broker design and required clarifications. Plan revision only; no implementation authorization, protection guarantee, risk acceptance or checkpoint change.
- **Ticket:** FRG-26 (#26). Branch `feature/FRG-26-permissions-isolation`, draft PR #37.
- **Follow-up:** FRG-27 (#27), review isolation, starts immediately after this one.
- **Why revised:** the owner asked (2026-11-01) whether FRG-26 needs a separate GitHub account.
  The comparison (owner's main account with a restricted token, a GitHub App, the helper account)
  is in `docs/decisions/2026-11-01-frg26-github-app.md`.
- **Kept unchanged:** the checkpoint after stage 1 (stage 2 and every Mac change wait for it); no
  change to FORGE's settings, the owner's Mac accounts or home-folder permissions before it;
  D1-D3 (no 5:00 credentials, test-mode keys included, until the protections are tested and the
  owner decides); D7 (review isolation is FRG-27, L12 stays open); D8 (home folder shown first,
  never recursive).
- **Wording:** every protection is a **Goal** until its test passes. "Confirmed (docs)" means
  GitHub's documentation says so; it is not a test result and never makes a protection a
  guarantee.
- **Stage 1 code:** `tests/permissions/github-throwaway.sh` (run only from owner handoffs),
  unit-tested without GitHub by `tests/unit/github-throwaway.test.sh`.

## 1. What this ticket does, in plain words

Today I run as **your** Mac user (an administrator) with **your** GitHub login (a repository
admin). FORGE's hooks catch ordinary commands, not a deliberately disguised one (L13).

FRG-26 gives me **my own Mac user** and, on GitHub, **a GitHub App that you own** instead of your
login. GitHub and macOS themselves should then refuse the harmful things, whatever command I run.
Each restriction is tried for real and counts only when GitHub or macOS refuses it.

## 2. Decisions

| # | Decision |
|---|---|
| D1-D3, D5-D8 | Unchanged from 2026-10-20 (D5: nothing merges into `dev` without your code-owner approval of the latest changes; D6: only you update `main`) |
| D4 (revised, owner 2026-11-01) | Three building blocks, block B now a **GitHub App** (section 4) |
| D9 (owner, 2026-11-01) | The helper account is no longer used by FORGE; its token file isn't read again. The account itself is your call |
| D10 (owner, 2026-11-01) | The app's private key stays out of my reach: a token broker, not the simpler fallback |

## 3. How sure we are

Same labels and stop rule as before: Confirmed (docs), Confirmed (this Mac / repo), Unconfirmed,
Goal. If a test fails or an Unconfirmed item turns out false, I stop and come back to you.
**Before expanding scope** (a new permission, a cost, a new account or repo, a limitation the plan
doesn't name), I report it to you and wait (owner, 2026-11-01).

**Approval:** approved for stage 1 implementation and independent reviews, 2026-11-01.
Every live GitHub action stays behind a reviewed owner handoff. The checkpoint before stage 2 and
any Mac change stays.

## 4. The three building blocks

**You: unchanged.** Admin on the Mac and on GitHub; the repo's only code owner. You also own the
GitHub App: only you can change its permissions, repositories or keys, from your browser.

**A. Mac user `forge-agent`:** unchanged (standard user, no `sudo`, can't open your home).

**C. Hooks I can't edit or switch off:** unchanged (root-owned install, managed settings with
`allowManagedHooksOnly`).

**B. GitHub App, owned by your account (name yours to pick)**

### 4.1 Minimum permissions

GitHub Apps start with no permissions (Confirmed, docs).

| Permission | Level | Why |
|---|---|---|
| Metadata | read | Mandatory for every app; also reads rulesets |
| Contents | read and write | Push feature branches; merge a PR (the merge endpoint needs Contents write) |
| Pull requests | read and write | Open, update, comment on PRs |
| Issues | read and write | Tickets and comments |
| Everything else | **none** | No Administration (settings, protection, rulesets, collaborators), Workflows (`.github/workflows`), Secrets, Variables, Environments, Deployments, Webhooks, Pages, Actions |

- CI reads (Checks, Commit statuses, Actions read) are not granted at first; test A11 decides. If
  one is needed, I ask you before anything is added.
- Installed "Only on this account" with "Only select repositories". Changed permissions take
  effect only after you approve them on the installation (Confirmed, docs).

**What "only selected repositories" does and doesn't restrict (revision 4).** Public repositories
are readable by anyone on the internet, logged in or not, so the app (or I) may still **read**
public repositories it isn't installed on; that isn't a protection we claim. The protection we
need is:
- **no writes** (pushes, PRs, issues, comments, merges) to any repository the app isn't installed
  on, and none beyond its four permissions where it is installed. **Failed for issues** (test A2,
  2026-11-11: the app opened an issue on the second throwaway; section 6). Unresolved until the
  owner approves a revised claim;
- **no access to private resources**: private repositories it isn't installed on, and private
  data in installed ones that needs a permission it doesn't have (settings, protection, secrets'
  names, collaborators, webhooks, deploy keys).

### 4.2 The token broker, in plain words (revision 1)

*Proposed replacement (2026-11-15, not built): section 13, where the broker keeps every token and
makes each request. This design stays the plan of record until that one is approved and tested.*

*The problem.* The app has a **private key**, a file that proves to GitHub "this is the app". It
never expires: whoever holds it can keep getting fresh access. So I must never be able to read it.

*The idea.* A small program, the **broker**, holds the key for me, like a front desk that holds
the master key and hands out day passes. It runs under its own hidden Mac account,
`_forgebroker`, which nobody logs into. Every 45 minutes (and when the Mac starts) it:
1. writes a short note, "I am app N, valid for the next 10 minutes", and signs it with the
   private key. GitHub calls this a JWT; it must be signed with RS256 and expire within 10 minutes
   (Confirmed, docs). Only the key's holder can make a valid signature;
2. sends the signed note to GitHub and asks for an **installation token** (a day pass) for exactly
   FORGE's repositories and exactly the four permissions above;
3. checks GitHub's reply: the token's repositories and permissions must be exactly those, or it
   throws the token away and writes nothing (fail closed);
4. writes the token into one file that only `forge-agent` can read. GitHub expires it after one
   hour (Confirmed, docs).

*Who can get a token.* Nobody "asks" the broker: there is no network port or request to fake. The
token sits in a file, and **macOS file permissions** decide who reads it: the file belongs to
`_forgebroker`, its group contains only `forge-agent`, mode 640, in a folder mode 750. Other Mac
users can't read it. You can, as Mac administrator (as you can read anything).

*How GitHub authenticates the broker.* By the signature on the note: GitHub checks it against the
app's public half of the key. No password, no login session.

*How the limits are enforced, three layers deep:*
1. **GitHub, the installation:** you choose, in your browser, which repositories and permissions
   the app has. GitHub never issues a token beyond them: "cannot be granted access to
   repositories that the installation was not granted access to" and "cannot be granted
   permissions that the app was not granted" (Confirmed, docs). This holds even if the broker
   were wrong or tampered with.
2. **The broker's request:** it asks for less than the installation allows if you ever install the
   app more widely: an exact repository list and the four permissions, from a settings file owned
   by `root` that `forge-agent` can't change.
3. **The broker's check:** it rejects any token GitHub returns with more than that.

*Where the key lives.* A file mode 600 in a folder mode 700, both owned by `_forgebroker`.
`forge-agent` isn't an administrator, so macOS refuses it (tests K1, K2). The broker's program and
settings are owned by `root`, so `forge-agent` can't change what it does (K4).

*What this does not stop.* **Automatic renewal means ongoing access:** as long as the broker runs
and the app is installed, I always have a valid token, so the one-hour expiry does not limit what
I can do over time; the four permissions and the selected repositories do (not fully: A2 showed
the app can open an issue on a public repo it isn't installed on; section 6). **Expiry limits only a
copied token:** a token copied elsewhere stops working within an hour of being issued, and
cancelling it (4.3) is documented to stop it sooner (for GitHub's stateless tokens Unconfirmed
until A5 runs; until then, count on the hour). Stopping ongoing access means stopping renewal or the app
itself (4.3, emergency). If the
broker stops, no new token appears and GitHub work stops (fails closed; you'd see it). Backups:
Time Machine would copy the key file like any other; whether to exclude its folder is your call at
stage 3.

*Stage 1 has no broker yet.* Stage 1 uses a **separate throwaway app**, installed only on the
throwaway repo, deleted at the end of stage 1. Its key is stored with a handoff under
`work/owner-secrets/frg26/`, which I can still read until stage 3 (the same limitation the helper
token had; accepted only for a throwaway app on a throwaway repo). The real app is created in
stage 4 and its key goes only to the broker. Moving a downloaded key file needs a new handoff step
in `.harness/lib/` (owner-only; you merge it).

### 4.3 Key revocation vs token revocation (revision 2)

| Action | Who, where | What it stops | What it doesn't |
|---|---|---|---|
| **Delete the private key** | You, app settings > Private keys (GitHub requires a second key before deleting the only one) | New tokens: a note signed with a deleted key should be refused (test A9) | Tokens already issued: GitHub's docs don't say. Expected to keep working until their hour runs out: Unconfirmed, test A9b records what happens |
| **Revoke one token** | Whoever holds it: `DELETE /installation/token` with that token | That token at once: "invalidated and cannot be used" (docs). For GitHub's stateless tokens, which this app now receives: Unconfirmed until A5 runs (see *Stateless tokens* below) | Other tokens; new tokens |
| **Suspend the installation** | You, Settings > Applications > Installed GitHub Apps > Configure > Suspend | The app's access to your account's resources (Confirmed, docs); whether already-issued tokens stop at once: Unconfirmed, test E1 | Reversible: Unsuspend |
| **Uninstall** | You, same page > Uninstall | The app's access to your account's resources (Confirmed, docs); token deactivation is documented for organisations, Unconfirmed for personal accounts, test E2 | Reinstalling gives a new installation id (broker settings updated by handoff) |

*Day to day:* the broker revokes the previous token a few minutes after writing a new one. If
revocation stops a token at once, at most two tokens work at any moment, none older than about 50
minutes. That holds only once A5 confirms it for stateless tokens and each revocation succeeds;
otherwise every token issued in the last hour may still work (about two at the broker's 45-minute
renewal), and the stage 2 design is corrected before it starts.

*Emergency: stop access first, keys later.* Stopping access never needs a replacement key.
GitHub requires a second key before the only key can be deleted (Confirmed, docs), so key
deletion is a later clean-up step, not an emergency step.
1. **Suspend** the installation in your browser (Settings > Applications > Installed GitHub Apps >
   Configure > Suspend). No key, no script, works from your phone. The app is blocked from your
   account's resources (Confirmed, docs); tokens already issued: test E1 records it.
2. If suspension doesn't stop tokens already issued (E1), or you want it permanent: **Uninstall**
   on the same page, or **delete the app** entirely in Developer settings; neither needs a key.
   Tokens already issued: E2 and E3 record it.
3. On the Mac: stop the broker (`launchctl bootout`, an owner handoff prepared in stage 3), so no
   renewal is attempted.
4. Later, calmly: look at what happened (the app's activity shows as its bot account); generate a
   new key, install it in the broker by handoff, delete the old key; then unsuspend (or reinstall).

*What happens to tokens already issued* is recorded for every way of revoking (A5 revoke, A9b key
deletion, E1 suspend, E2 uninstall, E3 app deletion). Each result goes into this section with the
date and GitHub's exact reply; where a token keeps working, the plan says so and the emergency
order is adjusted. Nothing here is assumed until its test has run.

*Freshness* (review round 18): a held token refused when it is 55 minutes old or more gives no
reading for A9b, E1, E2 or E3 (plain expiry could explain it); the step reads INCONCLUSIVE and
stops, and the plan is not corrected from it. A4 is the expiry test. The revocation handoff asks for
each browser step within about 30 minutes of the one before.

*Stateless tokens* (found 2026-11-06, the owner's first app run): GitHub now issues installation
tokens as `ghs_APPID_JWT`, about 520 characters, a token GitHub signs itself (changelog 2026-04-24,
rollout complete 2026-10-02). Permissions, repository scoping, the hour and the token endpoint are
unchanged (Confirmed, changelog). Neither changelog says whether `DELETE /installation/token` still
stops such a token at once: Unconfirmed until A5 runs. If A5 shows a revoked token still works, the
broker's "revoke the previous token" and the emergency steps are corrected before stage 2. The
script tries to revoke every token GitHub issues unless it is kept, including one it refuses
(round 31) and a control's own token (round 35); a revocation that fails is reported, and that
token works until its hour runs out.

*Held tokens in the tests* (review round 13): revocation is tried whatever the token's read
returned. A held token is removed only once that is settled (revoked, refused as bad credentials,
or its installation or app is gone); if GitHub can't be read reliably (no answer, a server error,
a rate limit) the step stops and keeps it for a retry. A token held over the suspension that
couldn't be revoked while suspended is read again after unsuspending, then revoked.

### 4.4 Secrets: seeing values vs managing them (revision 5)

- **Managing secrets** (create, change, delete, list names) needs the Secrets permission. The app
  doesn't get it (test A8). Even with it, the REST API never returns a value: "Gets a single
  repository secret without revealing its encrypted value" (Confirmed, docs).
- **Seeing secret values** happens only **inside a GitHub Actions run**: a job receives the
  secrets it uses. That is the real path, and it doesn't need any secrets permission:
  - With Contents write the app can push a branch. Events from an app's installation token **do**
    start workflows (Confirmed, docs: unlike `GITHUB_TOKEN`). A workflow running on that branch
    runs the branch's own scripts (for example `tests/run.sh`), which the app can change without
    the Workflows permission. So any repository-level secret such a workflow uses is reachable.
  - Therefore: **no repository-level secrets, ever** (today 0: Confirmed, repo). Deploy secrets
    only in a GitHub **Environment** with you as required reviewer and deployments limited to
    `main`: jobs "can only access these secrets after any configured rules" pass (Confirmed, docs).
    Environments are available on public repos with GitHub Free (Confirmed, docs).
  - The default workflow token stays read-only and "Allow GitHub Actions to create and approve
    pull requests" stays off (B15, read-only checks).
- **Actions-secret restrictions, explicit:**
  1. No repository-level or account-level Actions secrets on FORGE or project repos.
  2. Every deploy secret lives in an Environment with: you as the only required reviewer;
     "Prevent self-review" on; deployment branches limited to `main`.
  3. The app gets no Secrets, Environments, Deployments or Actions permission, so it can neither
     manage secrets nor approve a waiting deployment.
  4. The workflow token's default permission is read-only; Actions may not approve PRs.
- Tests: A8 (managing refused); S1 (read-only: 0 repository secrets; workflow token default
  read-only); **S2 in stage 1, on the throwaway repo**, with an Environment `frg26-test` holding a
  dummy, non-sensitive value (never a real secret):
  - S2a: the app pushes a feature branch whose (unchanged) workflow targets the Environment: the
    job must not get the value (deployment branches: `main` only). It counts as refused only on
    GitHub's own rejection: the deploy job failed without running a step, and its annotation says
    the branch is not allowed to deploy (wording Unconfirmed: if it differs, S2a reads
    inconclusive and the run stops). An unreadable run log is never taken as "no value";
  - S2b: in the open phase (no protection yet, so the app may push `main`), the app's push to
    `main` starts a run that waits for review; the app tries to **approve its own pending
    deployment**: refused (it has no Deployments permission, and "users who initiate a deployment
    cannot approve the deployment job" with Prevent self-review on: Confirmed, docs). Control:
    GitHub says you can approve it (`current_user_can_approve`), you approve it, and the job
    reports only the value's length;
  - S2c: the app tries to change the Environment (a no-op update with exactly its settings), read
    its secrets' public key, and delete a disposable dummy secret made for this test: refused.
    Control: your token makes the very same three requests and they succeed; the Environment then
    reads unchanged (review round 15);
  - S2d: a run you start yourself: your own approval should be refused, in this tested
    configuration (Prevent self-review on, you the only reviewer). It passes only when every
    criterion you approved holds (rounds 78-79, below). Control: your same request on the app's run
    in S2b worked, and S2b's readings show that approval taking effect. The run is then cancelled.
  The workflow file and the Environment are added by your handoff (the app can't). Actions on a
  public repo: $0, "standard GitHub-hosted runners is free … In public repositories" (Confirmed,
  docs).

### 4.5 Cost (revision 5)

| Item | Cost | Status |
|---|---|---|
| Creating and installing a GitHub App on your account | $0 | Confirmed (docs): registering has no pricing step (limit 100 apps per account); prices exist only for apps sold on GitHub Marketplace. GitHub doesn't say "free" in those words: if a billing step ever appears when you create it, we stop |
| Rulesets, branch protection, Environments on public repos | $0 | Confirmed (docs): public repos on GitHub Free |
| `_forgebroker` user, launchd, `openssl` | $0 | Built into macOS |
| Actions runs for S2 on the public throwaway repo | $0 | Confirmed (docs): standard GitHub-hosted runners are free in public repositories |
| Private repos later | GitHub Pro needed for these protections | Unchanged from the 2026-10-20 plan; decided when 5:00 needs it |

## 5. How your approval is enforced (D5) and only you update `main` (D6)

`dev` protection (applied by you): PR required, 1 approval, **review from Code Owners**
(`.github/CODEOWNERS` = `* @Thebigtuna88`), **approval of the most recent push**, stale approvals
dismissed, no force-push, no deletion, admins included.

Why the app can't satisfy it (each a Goal until its test passes):
- The app is the PR's author and its last pusher. GitHub: "Pull request authors cannot approve
  their own pull requests", and the latest push "must be approved by someone other than the person
  who pushed it" (Confirmed, docs).
- The app isn't a code owner: CODEOWNERS names only you, is read from `dev`, and changing it needs
  your approval (B2-B4).
- The app has no Administration permission, so it can't change the protection (B12, B13).

So a merge into `dev` needs **your** approval of the exact latest commit, from your own account.
GitHub does **not** check that codex reviewed it or said CLEAN (L12, FRG-27).

`main`: ruleset with Restrict updates, Restrict deletions, Block force pushes; bypass only the
repository-admin role (you). The app isn't an admin or a bypass actor. Step 0 still looks first at
what GitHub offers a personal repo; if "only you" isn't possible we stop and I explain the
alternatives before anything changes.

## 6. Protections and the tests that prove them (revision 3)

**Two kinds of test, two kinds of proof.** A refusal counts only with a protection or permission
reason from GitHub (BLOCKED, GH006/GH013, 403/404/401); anything else is inconclusive, a FAIL.

- **Kind S, a setting we add** (branch protection, ruleset, CODEOWNERS): **fails first**. The test
  runs before the setting exists and must get through, proving it can see the gap; after the
  setting it must be refused.
- **Kind P, forbidden by GitHub from the outset** (a permission the app never had, a repo it isn't
  installed on, approving its own PR, an expired or revoked token): it can't get through first.
  Each instead has a **control** that shows the test itself works:
  - **same request, a credential that may do it:** your token makes the identical request and
    succeeds. For writes the control is a **no-op** (setting a value to what it already is), so it
    changes nothing;
  - **neighbouring allowed action:** the app's token does the nearest permitted thing and succeeds
    (an ordinary file pushes, a workflow file doesn't; a fresh token works, an old one doesn't);
  - **the expected reason:** the refusal must be the documented one (for example 403 "Resource not
    accessible by integration"), not a typo or a network error.

| # | I must be unable to… | Enforced by | Docs | Tests (kind) |
|---|---|---|---|---|
| 1 | Push, force-push or delete `dev`/`main` | Protection + ruleset; app not admin | Confirmed | B1, B14a, B14b, M1, M5a, M5b (S) |
| 2 | Update `main` | Ruleset bypass = admin role only | Unconfirmed for personal repos | Step 0, M1-M6 (S) |
| 3 | Merge into `dev` without your approval of the latest push | Code-owner review + last-push approval | Confirmed | B1-B4, B6-B11 (S); B5 own approval (P); B16 control |
| 4 | Change settings, protection, rulesets; delete, archive, transfer | No Administration | Confirmed | B12, B13, M4, A6 (P) |
| 5 | Manage secrets, variables, deploy keys, webhooks, collaborators | No such permissions (collaborators: Administration) | Confirmed | A8 (P); collaborator changes via A6's Administration refusal |
| 5b | See secret values; approve its own deployment | No repo-level secrets; Environments need you, self-review prevented, `main` only | Confirmed (docs) | S1 (read-only), S2a-c (stage 1, P with controls) |
| 6 | Change workflow files | No Workflows permission | Confirmed | A3 (P) |
| 7 | Widen my access (permissions, repos, keys) | Only you change the app, in your browser | Confirmed | A1, A6 (P); A10 docs only (no API makes keys) |
| 9 | Write to, or read private resources of, repos it isn't installed on | Selected repositories + narrowed tokens | Confirmed (docs); **failed in A2 for issues, 2026-11-11; unresolved**; proposed replacement: section 13 (not built) | A2 (P) |
| 15 | Keep using an old, revoked or suspended token; mint with a deleted key | 1-hour expiry; revoke; suspend; uninstall; app deletion; key deletion | Partly Confirmed | A4, A5, A9, A9b, E1, E2, E3 (P) |
| 16 | Read the app's private key or change the broker | Broker user owns key; root owns program and settings | Goal | K1-K4 (stage 3, P) |
| 8, 10, 11, 13, 14 | Mac items | Unchanged | — | Unchanged (stage 3) |
| 12 | Rewrite review replies | **FRG-27**; L12 stays open | — | — |

B1-B16 and M1-M6 run as in the 2026-10-20 plan, with the throwaway app's token. B5 moves to kind P
(GitHub never lets an author approve): its control is B16, in the same phase: a separate PR the app
opens into dev, which you approve and the app then merges (review round 36: not the same PR, which
B5 closes).

New tests (throwaway app, throwaway repo, run only from your handoffs):

| # | Tries… | Must happen | Control |
|---|---|---|---|
| A1 | Mint a token; read what GitHub says it carries | Exactly the four permissions, only the throwaway repo | — (a reading) |
| A2 | Since 2026-11-15 (owner), code changes only, on a second public throwaway repo the app isn't installed on: a push, a file and a branch through the API | Refused, and that repo's branches and tags unchanged. **2026-11-11: FAILED** as first written (an issue was allowed; below the table); an issue or PR there is no longer tried | Same three on the installed repo succeed. The file goes on the owner's branch there, which must exist (checked first) |
| A3 | Push a commit adding `.github/workflows/x.yml` to a feature branch | Refused | The same commit with an ordinary file succeeds |
| A4 | Use a token over 1 hour old | 401 | A fresh token, same request, succeeds |
| A5 | Revoke a token, then use it | 401 | The same token makes the same request successfully just before it is revoked (review round 36) |
| A6 | Change the repo's settings (no-op description write); change its own installation | Refused | Your token makes the same no-op write and succeeds |
| A8 | Read the secrets' public key; list secrets, variables, deploy keys, webhooks, pending collaborator invitations | Refused | Your token lists the same and succeeds (reads; nothing created). Adding a collaborator is not tried: any valid target would invite a real person; it needs Administration, whose write A6 shows refused (review round 13) |
| A9 | You delete the key; mint with it | Refused | The new key mints |
| A9b | Use a token minted before the key's deletion | Recorded either way, and the plan is corrected | — (a finding) |
| E3 | Delete the throwaway app at the end of stage 1; use a token issued before | Recorded | — |
| S2a-c | Environment: branch limit, the app approving its own deployment, changing it or its secrets | Refused | You approve (S2b); your token makes S2c's same three requests (S2c) |
| A11 | Read CI results on a public repo with no Checks/Actions permission | Decides whether a read permission is needed | — (a finding) |
| A12 | Every `gh` command FORGE uses, with the app token | Works, or listed for you before any change | — |
| E1 | You suspend the installation; use a token issued before | Recorded; then a new mint must be refused | Unsuspend; a new mint works |
| E2 | Uninstall at the end of stage 1; use a token issued before | Recorded | — (the app is deleted next) |
| S1 | (Read-only) repository secrets count; default workflow token permission | 0; read-only | — |
| K1-K4 | (Stage 3) as `forge-agent`: read the key; list the broker's folder; change the broker's settings; read the token file | Refused, refused, refused, works | You (admin) can read the key: the check is valid |

**A2, 2026-11-11: failed, a failed protection, unresolved.** Stage 1 part 0 (handoff
`2026-11-06-frg26-stage1-open`, run 2026-11-11T06:51:10Z, verify failed) stopped after A2:
- The push to `forge-frg26-throwaway-2` (the app not installed there) was refused: "Permission to
  … denied to frg26-throwaway-test-atl[bot]", 403.
- Opening an issue there **was allowed**: issue #1, "FRG-26 A2 (20261111T065801Z-3110)", created
  06:58:16Z, author `frg26-throwaway-test-atl[bot]` (type Bot, author association NONE). The token
  was narrowed when minted to the first throwaway and the four permissions.
- Opening a PR there was not tried (the first attempt not refused ends the test), nor were the
  controls.
- The exit check that lists the second throwaway's open "FRG-26 " issues, seconds later, did not
  report issue #1, although GitHub lists it now. So that check can't be relied on to catch a write
  there. Why it missed it is Unconfirmed.
- GitHub's documentation, as far as one search found, doesn't describe this.

Item 9 therefore stays **failed and unresolved** until the owner approves a revised protection
claim. A2 is not run again and is not marked passed. The kind-P tests run before it in that same
run (S1, A6, A8, A5, A3) gave their expected results; they are recorded, not accepted, since the
run did not finish. Evidence, kept unchanged: the handoff's folder in `work/owner/`, and read-only
byte-for-byte copies in `work/FRG-26-permissions-isolation/evidence/` 36-39 (the paste, the log,
issue #1 and its timeline as GitHub returned them). Issue #1 stays open: this script never writes
to the second throwaway as the owner. The first throwaway's dev and main protection was put back
by a reviewed handoff (`2026-11-11-frg26-restore-protection`, run 2026-11-11T17:01:18Z, verified),
with issue #1 checked open before and after.

**A2 investigation, approved by the owner 2026-11-11 (without P6, the throwaway repos only).** One
reviewed owner handoff runs `github-throwaway.sh a2-probe` once, every attempt made as the app
against the second throwaway:
- Each token's permissions and repositories are printed from GitHub's answer (without the token)
  and read back with `GET /installation/repositories`: a token for the whole installation (C1),
  the full token (four permissions), P1's (contents write, metadata read: no Issues) and P2's
  (metadata read only). Each is revoked as soon as its attempts end, and a read with it must then
  get HTTP 401.
- Claim 9a, code changes: P5, a file and a branch created through the API, each must be refused,
  with the same two writes on the first throwaway as controls (a new branch `frg26/probe/…`).
  The first that isn't refused, or any change to the second throwaway's branches or tags, stops
  the run for the owner.
- Claim 9b, public activity, readings only: a comment on issue #1 (P3), a PR from `frg26-a2` (P4),
  an issue with P1's token and with P2's. GitHub's whole answer is kept, headers included
  (`X-Accepted-GitHub-Permissions`). An attempt GitHub gives no clear answer to (an error, a rate
  limit) is no reading: it stops the run too, since what GitHub did is then unknown.
- Nothing is closed or deleted: each object made is read back by the number GitHub returned (the
  fix for the exit check that missed issue #1). The second throwaway is deleted at the end of
  stage 1.
- Each token's expiry, from GitHub's answer, must be within the next hour, and its repositories
  are read back, not assumed.
- The clean-up contract (owner-approved, 2026-11-12, after review round 52). However the run ends
  (its end, a stop, an error, Ctrl-C, closing the window, a kill), its clean-up runs to its end,
  ignoring further signals, for at most three minutes, each revocation and each check for at most
  20 seconds. Every other request of the run has the same 20-second limit, so a stop reaches the
  clean-up within 20 seconds. It revokes again every token issued to the run that no read has
  shown revoked, and a read with it must get HTTP 401; after a stop it then compares the second
  throwaway's branches and tags; it reads back each object made; it ends with one line naming the
  tokens confirmed revoked and those not, describing each one not confirmed (GitHub's answer when
  it was issued, whether its expiry was checked, what it reaches now), never a token itself. Limits, accepted: a force-kill,
  a power loss, or a revocation that fails or times out leaves a token unconfirmed. It may stay
  valid until its expiry and can do what the run shows the app's tokens can do (on the first
  throwaway, and on a public repository it isn't installed on, as in A2). A review finding that
  fits these limits is recorded under them; any other is fixed.
- A further limit, accepted by the owner (2026-11-12, review round 56) **for this throwaway
  investigation only**: a token request that gets no complete answer (a timeout, a broken transfer,
  a 5xx) may leave a token GitHub issued that the run never received. It can't be revoked or
  checked from here. The run stops, never asks again, and names it as possibly issued and never
  received, with the most it could carry (the requested repositories and permissions, or the
  installation's for a request naming none) and the latest it can expire (an hour after the
  request, plus a minute). A token that did arrive in an answer whose transfer then failed is
  taken, revoked and checked like any other. This does **not** approve the same risk for the
  production broker: it is assessed separately before stage 2.
- Interruption, accepted by the owner (2026-11-13, after review round 67) **for this throwaway
  investigation only**. Ctrl-C and closing the window stay available: on one, the run starts no
  new test action and attempts the bounded clean-up. A stop arriving at an unlucky moment may
  leave the report incomplete or a revocation unconfirmed. Any token so affected is still within
  the approved scope (what its TOKEN lines show, and what the run shows on a public repository it
  isn't installed on) and expiry (within an hour of its issue). Uncertainty is reported when
  possible, and a successful clean-up is never reported without confirmation (HTTP 401 for each
  token). Not extended to the other stage 1 commands or the broker without separate approval.
- Review criteria for this investigation (owner, 2026-11-13): a finding that fits one of these
  accepted limits is recorded under it; any other is summarised for the owner before a fix is
  proposed. Automatic review rounds are paused until the owner says otherwise.

**Status during the investigation (historical, 2026-11-13 to 2026-11-15; the remaining handoffs
have since resumed, below):** the proposed split of item 9 into 9a and 9b was not yet a claim,
item 9 stayed failed and unresolved, the remaining stage 1 handoffs were paused, and the findings
went to the owner with a recommendation before the broker was extended or any risk accepted. Item 9
is still failed and unresolved.

**Investigation result (run 2026-11-14T00:33Z, verified):** code changes on the second throwaway
were refused (a file and a branch, 403) and its branches and tags were unchanged; a comment and a
PR there were refused; an issue was opened with a token without Issues and with one with metadata
read only (issues #2, #3, kept open). All four tokens reached only the first throwaway, expired
within the hour and were confirmed revoked (HTTP 401). Evidence: `evidence/70-a2-probe-log.txt` in
`work/FRG-26-permissions-isolation/`. The owner's response: section 13 (a proposed broker design).

**Stage 1 resumes (owner, 2026-11-15)** before the broker exists, with A2 changed to test code
changes only (the table above): the paused handoffs test what GitHub itself enforces, which section
13 doesn't change. The issue opening is recorded here as a known result, not tried again. Item 9
stays failed and unresolved; A2 passing as changed shows claim 9a only. The issue check on the
second throwaway now counts only this run's issues, so the kept evidence (#1-#3) stays open
without failing every run. The regenerated handoffs are reviewed like the others.

## 7. Your home folder (D8)

Unchanged: `chmod 700 /Users/atl`, not recursive, shown with effects and undo first.

## 8. Stages

Every change to your Mac or GitHub is an owner handoff; I never run them. Read-only checks I may
run myself.

**Stage 1: GitHub feasibility, throwaway only.** FORGE and your Mac untouched.
1. I rewrite `tests/permissions/github-throwaway.sh` for the app: JWT signed with `openssl`
   (bash 3.2), identity from the token itself instead of `GET /user` (not expected to work with an
   installation token: Unconfirmed), tests A1-A12, E1, E2, S1 with their controls. Unit tests that
   fail first, then codex `code` + `security` + `spend` to CLEAN on draft PR #37.
2. Handoff: you create the throwaway app (the four permissions, "Only on this account"), install
   it on the throwaway repo only, generate a key; the handoff stores it and reports the app and
   installation ids (no secret printed). You also create the second, empty public throwaway repo
   for A2.
3. Handoff: allowance gate, `unprotect`, reset, **open phase**: kind-S tests get through, kind-P
   tests are refused with their controls passing.
4. Handoff: protect; run again.
5. Handoff: step 0, then the `main` ruleset; run a third time; all must pass.
6. S2 runs inside the open phase (step 3): before it, your handoff adds the workflow and the
   Environment with a dummy value.
7. Handoff: A4, A5, A9, A9b, E1, E2, E3 (the last one deletes the throwaway app).
8. **Checkpoint with you.** Stage 2 and every Mac change wait for it. *Undo for stage 1: delete
   the throwaway app and both throwaway repos.*

Clean-up the stop rule allows after a failed test (review rounds 13-28): closing this run's test PRs
and issues, and cancelling S2 runs still unfinished (a waiting run, like an open PR with auto-merge
armed, could otherwise go ahead later). Nothing else is written: the disposable dummy secret, a
changed setting or description, or a ruleset stays for you to see. After A2's failure the owner
asked (2026-11-11) for one more step, by its own reviewed handoff: putting back the throwaway's
`dev` and `main` protection exactly as `protect` applies it (part 0 had removed it), with nothing
else written and no evidence removed.

The exit clean-up of every stage 1 command other than a2-probe (owner, 2026-11-16, review round
72): it settles the tokens first, alone, within its first 90 seconds (a revocation for each, before
any check, then a read with each, where only HTTP 401 confirms); then the clean-up above; then a
last try for any token not yet confirmed. Every GitHub call in it has a time limit (20 seconds,
never more than is left), its waits and loops check the deadline, and the whole clean-up ends
within three minutes plus a few seconds. What the deadline leaves out is named as not done. Its
last line names each token confirmed revoked or not and what was left undone; a clean-up not
shown complete makes the run's exit status a failure, never a success. This doesn't extend the
investigation's accepted limits (above) to these commands or to the broker.

Controls and every tidy-up (owner, 2026-11-16, review round 73). A control that needs its own
token (A9, E1) is named before it can ask for one, and settles that token itself: a revocation,
then a read that must get HTTP 401, up to three tries within its own 90 seconds. The token never
leaves the control; the run is told only its name and state. A failed or timed-out check, or a
control that ends without reporting, leaves its token NOT confirmed, and the clean-up INCOMPLETE;
expiry is never counted as revocation. Every tidy-up failure, on a normal finish too, is named in
the last line. (Until review round 74, a stop that arrived during a control acted only once the
control had ended.)

Bounded controls, and expiry (owner, 2026-11-17, review round 74). Every request a control makes
has a time limit, and so does the control as a whole: it is told to stop once its work has had its
share, which keeps 90 seconds for settling its own tokens, and is stopped outright at four
minutes. A stop to the run acts at once, during a control too: the control is told to stop and
settles its tokens while the run's clean-up runs, which collects its report within its own three
minutes. A control that has to be stopped outright, or that can't report, leaves its tokens NOT
confirmed and the clean-up INCOMPLETE. A revocation counts as confirmed only after GitHub answered
it as done and a read with the token then got HTTP 401 at least a minute before the expiry GitHub
gave the token when it issued it; otherwise the token is named "expired, revocation not
confirmed", "expiry unknown, revocation not confirmed" or "revocation never answered as done", and
the clean-up is INCOMPLETE. A revocation that took effect but whose answer was lost is therefore
reported NOT confirmed. a2-probe is unchanged.

Bounded requests (owner, 2026-11-17, review round 75). Every GitHub request goes through the
owner's gh, the app's gh, the app's git or the app's own requests (curl), and each gets its time
limit where it starts: 20 seconds for an API call (the app's own requests end at curl's 20, with 5
more as a backstop), 60 seconds for a git push or fetch, 120 seconds for a clone, 20 seconds for a
local git command; less near the clean-up's cap. A test reads the script and fails on any gh, git
or curl run another way, and on any request inside a command substitution or a pipeline, or a
sleep in the foreground, since bash holds a stop until those end (a2-probe's own code aside: its
accepted limit covers that). A request with no answer in time is stopped with every process under
it, and so is the run: no new request or test action starts, and the clean-up says why first. A
tidy-up on a normal finish (closing test PRs or issues, cancelling S2 runs) instead names what a
timeout left undone itself, as the clean-up does. A
stop during any request stops the request the same way, at once. A write that timed out, or that a
stop cut short, may have taken effect: it is never sent again, and the clean-up's last line names
it, outcome unknown, until someone checks it on GitHub; the clean-up is then INCOMPLETE. A token
request still holds a stop until its answer is in (rounds 58, 59). What reaches
a2-probe through the shared code: its requests are bounded at the wrappers too (the limits it
already had); a stop during its revocations and its capture calls acts at once, while its reads in
command substitutions still hold one up to 20 seconds, as before; a timeout doesn't stop it (its
own handling stands), it notes no writes, and its own code and evidence are unchanged.

**Token-request hold, accepted (owner, 2026-11-18, review round 76).** For the stage 1 commands
only, **not the production broker**, a stop that comes while a token request is out is held until
its answer is in: normally up to 20 seconds (curl's own limit), with a 25-second backstop if curl
fails to stop. After the stop no new test action starts; the answer is handled, then the bounded
clean-up runs. A token in the answer is registered, and its revocation is tried and checked. Not
every issued token is received or revoked: a lost or incomplete answer is reported as a token
possibly issued, never received, with the most it can carry (repository and permissions) and its
latest expiry, and the clean-up is INCOMPLETE. A test shows each case. Two smaller points from the
same round: the test runner runs each test with `set -e` off (a known limit, recorded in
`tests/lib/assert.sh`; no test relies on it), and a test shows that an assertion's failure stands
when a successful command follows it.

**Tidy-up writes that time out (owner, 2026-11-18, round 77).** Closing a test issue or PR and
cancelling an S2 run are bounded once, by the owner's request wrapper: the same 20 seconds, and less
near the clean-up's cap. A timeout is named as a timeout ("no answer within" its limit), a stop as a
stop ("cut short by the stop"), each with the repository and the issue, PR or run. It is never sent
again. A read-back that shows the final state settles it, and the clean-up reports what it read (a
PR closed or merged, a run no longer unfinished). Anything else stays outcome unknown in the
clean-up's last line, which is then INCOMPLETE: an issue's close (not read back), a PR still open
or unreadable, a run still unfinished or not listed again after its cancel. A test shows each case.
a2-probe calls none of these tidy-ups, and its code and evidence are unchanged.

**S2d's evidence (owner, 2026-11-20, round 78).** Part 0's run on 2026-11-20 stopped at S2d,
inconclusive: GitHub said you can't approve your own run, then answered the approval with HTTP 422
"No pending deployment requests to approve or reject", whose gh error line names no HTTP status.
That answer fits both "pending, but not yours to review" and "nothing pending", so it is never proof
of a refusal on its own, and that run's result stays inconclusive. S2d now reads GitHub's own state
before the attempt and again after it, each reading bound to the run (waiting, on your workflow
commit, pushed by you to main), the Environment (exactly one pending deployment for it, you its only
reviewer, GitHub saying you can't approve it), the one deployment GitHub made for that commit and
Environment (its id the same after as before, its statuses showing it neither started nor ended),
and no approval recorded. No approval is sent unless the reading before is bound in every part. The
attempt keeps GitHub's own status line, the whole body, gh's error output and only the headers
x-github-request-id, x-ratelimit-remaining and x-ratelimit-resource; every reading is recorded in
full, with this run's tokens and anything shaped like a GitHub token or a JWT hidden. Allowed (a
FAIL) when GitHub accepted the approval, recorded one, or the deployment started. Tests show a
missing or changed pending state, unexpected answers and an incomplete read-back, none of them a
pass. Whether a deployment waiting for review shows a deployment and its status before approval is
Unconfirmed (the docs don't say); if not, the reading before is not bound, no approval is sent, and
S2d stays inconclusive: the criteria are not weakened to fit.

**S2d's criteria for a refusal (owner, 2026-11-20, round 79).** S2d passes, as "self-approval
refused in this tested configuration" and never as a general guarantee, only when all of these hold:
(1) the reading before is bound in every part; (2) GitHub's status line is 422, with an
x-github-request-id (correlation only: the authenticated HTTPS connection is what says GitHub
answered); (3) the body's errors are exactly "No pending deployment requests to approve or reject";
(4) no sign of a rate limit, told apart on its own signs (a 429 or 403, a retry-after header, which
is noted but not kept, a quota of 0, or GitHub's rate-limit words), and quota left above 0; (5) the
reading after is bound to the same deployment, still pending, no approval recorded; (6) S2b's
control is ok and S2b's readings around your approval of the app's run show it taking effect: the
same run, commit and deployment, nothing pending afterwards, your approval recorded for the
Environment, and the deployment started. The 422 and its words are supporting evidence, not proof of
the refusal's cause. Anything short of all six is inconclusive, and names what was missing; S2b's
own verdict doesn't depend on its readings. Tests show each criterion missing, and missing or
ineffective S2b evidence, none of them a pass.

Rules found while building carry over unchanged: per-test stop, sweep on every exit, exact
protection compare, fail-closed allowance gate, a fresh open phase on the final reviewed commit.

**Stage 2: build and review.** As before, plus the broker, its install/uninstall scripts, and the
key-file handoff step. You merge (owner-only paths).

**Stage 3: the Mac.** As before, plus: create `_forgebroker` (hidden service user; check: not
admin; undo: delete it), install the broker (asks your Mac password), K1-K4.

**Stage 4: GitHub on FORGE.** You create the real app and install it on FORGE only; the key goes
only to the broker; you apply the tested `dev` rules and `main` ruleset; S1 on FORGE; live proof:
the first real PR, one refused attempt (B6) before your approval, then you approve and I merge as
the app.

**Stage 5: close.** Done when every item in section 6 (except 12) is enforced and tested, or you've
accepted it in writing as a known limit. **FRG-27 starts immediately.**

## 9. Before any 5:00 credential (D1-D3): unchanged in substance

| 5:00 access | Needs these items tested first |
|---|---|
| Real business credentials | 7, 8, 10, 11, 13, 14, 16 |
| Payment access, test mode included | the above + 5, 5b, 6 |
| Production deployment access | the above + 1, 2, 3, 4, 9, 15 |

Then I show you every remaining accepted risk (at least L12, L13, L1, L4, anything still
Unconfirmed, deferred findings), and you decide.

## 10. What changes for you

- **Money:** $0 (section 4.5).
- **Your time:** about the same number of handoffs as before, plus creating two apps and one extra
  throwaway repo in your browser.
- **Day to day:** PRs show the app's bot account as author; you click Approve; I merge as the app;
  a new key every 90 days with a handoff; the emergency steps in 4.3 need only your browser.

## 11. Not in this ticket

FRG-27 (review isolation, L12); Claude Code's sandbox; private repos / GitHub Pro; File Sharing.

## 12. What this revision changed (2026-11-01)

- Block B: GitHub App instead of the helper account (D4, D9, D10); token broker; items 5b, 15, 16
  new; item 9 restated (writes and private resources, not public reads).
- Kind S / kind P tests replace "every test fails first".
- Stage-1 code on PR #37 changes again; the four frozen stage-1 handoffs and diagnose-7 are
  superseded and never given out. The helper's restriction no longer blocks stage 1.

## 13. Proposed request-forwarding broker design (recorded 2026-11-15)

Status: **a proposed design, not a proven guarantee.** Written as a proposal on 2026-11-14 and recorded in the plan at the owner’s request on 2026-11-15. Nothing here is built or proven. **Item 9 stays failed and unresolved** until the replacement is implemented, the expanded tests pass and the owner accepts the revised claim. Recording this proposal does not accept residual risks or authorize implementation. The checkpoint after stage 1 (stage 2 and every Mac
change wait for it) and the credential restrictions (no 5:00 credentials, test-mode keys included,
D1-D3) are unchanged. The remaining stage 1 handoffs resume before the broker exists (owner,
2026-11-15; section 6), each still given only after its review, as before.

Labels as in the plan: **Confirmed (docs / this Mac / this run)**, **Unconfirmed**, **Goal** (a
protection is a Goal until its test passes).

### 13.1 Why the current broker design isn't enough

The plan (4.2) has the broker write a fresh token into a file that `forge-agent` can read. The A2
probe (2026-11-14, `a2-probe-findings.md`, evidence 70) showed what that token can do:

- **Code changes stay on the installed repository** (claim 9a): a file and a branch on the second
  throwaway were refused, 403, with the full token. Confirmed (this run).
- **Opening issues does not.** A token with no Issues permission, and one with metadata read only,
  each opened an issue on the second throwaway, where the app isn't installed. The token's
  permissions and its repository limit didn't stop it. Confirmed (this run). Behavior on other people’s public repositories remains untested. P6 was the excluded private-repository test; it was not a test on someone else’s public repository.

The investigation demonstrated issue creation on the second public throwaway outside the installation scope. Narrowing the token can't fix
that, because GitHub doesn't apply the narrowing here. The proposed mitigation is to keep tokens inside the broker, subject to the restrictions and tests below.

### 13.2 The change, in plain words

Today's plan: the front desk (the broker) hands me a day pass (a token) and I use it myself.

Proposed: the front desk **keeps every pass and makes each GitHub request for me**. I hand it a
filled-in form ("open a PR from branch X into `dev`, with this title and this text"). It checks who
I am, which repository, whether that kind of request is on your approved list, and what the form
says. Only then does it make the request itself and give me GitHub's answer, with no token in it.
Anything not on the list is refused on the Mac, before anything reaches GitHub.

GitHub's own limits stay as a second wall: the installation's repositories and four permissions
still bound what any token can do (9a). The broker's list adds what GitHub doesn't enforce.

### 13.3 How one request travels

1. I run a small client, `forge-github <action> <fields…>` (for example `forge-github pr-create`).
2. The client connects to the broker through a **local socket**: a file-like connection point on
   the Mac, `/var/run/forge-broker/broker.sock`. It is not a network port: nothing off the Mac can
   reach it.
3. The broker runs the four checks (13.4). The first failure ends the request with a refusal
   and a log line. Nothing is sent to GitHub.
4. The broker builds the request itself from a fixed template, adds the token in memory, sends it,
   reads the answer, removes anything it doesn't pass back (13.7), and returns the answer to
   the client.

### 13.4 The four checks

#### 13.4.1 Who is asking: the Mac user

- The broker asks the macOS kernel which user is on the other end of the socket
  (`getpeereid`). The macOS manual: "This mechanism is reliable; there is no way for either side to
  influence the credentials returned to its peer except by calling the appropriate system call …
  under different effective credentials." Confirmed (macOS manual page, read 2026-11-14).
- Only `forge-agent`'s user number is accepted. Every other user is refused, your own account
  included (you use your own GitHub login in the browser and `gh`, not the broker).
- The socket's folder belongs to `_forgebroker`, group `forge-agent`, mode 750. Other users can't
  even reach the socket (the kernel check is the real gate; the folder is a second one).
- Nothing in the request can claim to be someone else: the form has no user field. Goal; tests R1,
  R2.

#### 13.4.2 The exact repository

- The approved repositories are listed in the broker's settings file, owned by `root` (I can't
  change it): each with its owner/name **and GitHub's permanent numeric id**.
- The form names a repository by its listed short name only. Anything not listed is refused
  (the A2 case: an issue on the second throwaway is refused on the Mac).
- Before first use, and after each start, the broker reads each repository's id from GitHub and
  stops if it doesn't match the settings (a renamed, deleted or recreated repository never quietly
  becomes a different one).
- Requests address the repository by id (`/repositories/<id>/…`) where GitHub accepts it.
  Whether every needed endpoint accepts the id form: Unconfirmed, test R9b; where it doesn't, the
  broker uses the name form and checks the repository id in GitHub's answer.

#### 13.4.3 The allowed action

- The settings file holds an **allowlist of actions**. Each action is a fixed HTTP method, a fixed
  path template and a field schema. There is no "raw request" action, and no GraphQL (one GraphQL
  query can name any repository; if A12 shows FORGE needs one, it becomes a fixed, reviewed query
  with checked variables, by your approval).
- First list, to be finalised from test A12 (every `gh` command FORGE uses), each with its own
  limits:

| Action | Limits checked by the broker |
|---|---|
| Read repository, issue, PR, PR checks, PR reviews | Approved repository only |
| `issue-create`, `issue-comment` | Approved repository; title and body checked (13.4.4) |
| `issue-close` | Only an issue on the approved repository |
| `pr-create` | Base must be `dev`; head must be `feature/<KEY>-<n>-<slug>` |
| `pr-edit` (title, body), `pr-comment`, `pr-ready` | PR on the approved repository, base `dev` |
| `pr-merge` | Squash only; base `dev` (read from GitHub first); the head sha must be given and match; GitHub still requires your approval (item 3) |
| `push-branch` | 13.5 |

- Not on the list, so refused: anything to `main`, any settings, rulesets, collaborators, secrets,
  workflows, releases, gists, deleting branches or repositories, and every other repository.
- **Write quota** (proposed: 60 writes an hour, 300 a day, your call): bounds how much noise a
  misbehaving agent can make even with approved actions on FORGE itself.

#### 13.4.4 The request contents

- The form is JSON, at most 1 MB (the push stream: 13.5). Unknown fields are refused, so a
  smuggled `url`, `repo`, `method` or `path` field is refused, not ignored.
- Each field has a type, a length limit and, for names, a strict pattern: branch names, labels,
  and numbers (digits only). Characters that could change a path are refused, not encoded: `/` in a
  single name, `..`, `%`, `?`, `#`, backslash, spaces, control characters, and look-alike Unicode.
- Titles, bodies and comments are scanned with gitleaks and FORGE's rules (`.harness/gitleaks.toml`),
  the same rule 10 applies to commits today. A hit refuses the request and names only the rule.
- Cross-checks where an action depends on GitHub's state (a merge's base branch, an issue's
  repository) read that state first, from the approved repository.

### 13.5 Git pushes

`git push` with a credential would put the token in my reach (git's credential helpers hand it to
my process). So pushes go through the broker too, as a **bundle**: a single file containing a
branch and its commits, made by git itself (`git bundle`).

1. I run `forge-github push-branch <branch>`. The client makes a bundle of exactly that one branch
   and streams it over the socket (cap 50 MB; FORGE is far smaller). No shared folder, so nothing
   can be swapped in between the check and the push.
2. The broker, in its own private clone of the approved repository:
   - verifies the bundle (`git bundle verify`) and every object in it (`fsck`);
   - requires **exactly one** branch, named `refs/heads/feature/<KEY>-<n>-<slug>` with a key from
     the settings: no `dev`, no `main`, no tags, no deletions;
   - refuses a change to `.github/workflows/` (GitHub refuses it too without the Workflows
     permission, A3: two walls) and scans the new commits with gitleaks;
   - pushes `<that commit>:refs/heads/<that branch>` to the fixed address
     `https://github.com/<owner>/<name>.git`. **Never forced**: a branch that isn't a fast-forward
     is refused by GitHub, and the broker never uses `+` or `--force`.
3. The broker's git runs with system and user git settings ignored, hooks disabled, only `https`
   allowed, `http.followRedirects=false`, no credential helper; the token is passed as a header
   through git's environment-variable settings, never in the address or the command line.

Fetching: FORGE's repositories are public, so I fetch with no credential at all, straight from
GitHub. A private repository later would need a broker fetch action (not in this proposal).

### 13.6 No redirects, no arbitrary addresses

- **I never supply an address, host, path or method.** Only an action name and checked fields; the
  broker fills its own fixed template on the fixed hosts `api.github.com` and `github.com`.
- **Redirects are never followed.** The broker's HTTP client (`/usr/bin/curl`) runs with
  `--proto =https --proto-redir =https --max-redirs 0` and without `-L`; a 3xx answer is a refusal,
  its `Location` is never followed or stored in the metadata audit log. Git: `http.followRedirects=false`. So the token can't be
  carried to another host or path, and GitHub's own 301/307 for a moved repository stops the broker
  (the repository-id check then says why).
- **No inherited settings:** the broker starts curl and git with an empty environment (no proxy
  variables, `--noproxy '*'`), ignores `.curlrc` (`-q`), and pins the API version header.
- **Pagination:** the broker counts pages itself; it doesn't follow `Link` addresses from GitHub.
- Addresses in GitHub's answers (`html_url` and so on) come back to me as plain text. Without a
  credential, following them can only read public pages.

### 13.7 Credentials out of reach, out of answers, out of logs

- **No token file any more.** The token (and the signed note, the JWT) live only in the broker's
  memory. 4.2's step 4 is removed. The broker can mint a token when needed and revoke it after use,
  instead of every 45 minutes.
- **Never on a command line.** Any user can see other users' command lines with `ps` (Confirmed,
  this Mac 2026-11-14: run as your user, not root, it lists root's processes with their arguments),
  so the token reaches curl through its standard input (`-K -`) and git through environment settings.
  Whether macOS hides another user's process environment from `forge-agent`: Unconfirmed, test R3.
- **Answers:** I get GitHub's status, its JSON body, and a short list of headers (request id, rate
  limit, `X-Accepted-GitHub-Permissions`). Before returning, the broker scans the answer for the
  current and previous tokens and the token and JWT patterns; a hit withholds the answer, returns
  an error and logs an incident (without the token). Error text from curl and git is scanned the
  same way and never passed on raw.
- **Logs:** one line per request: time, Mac user, action, repository id, object number, GitHub's
  status and request id, sha256 of the form. No headers, no bodies. The log folder is written only
  by the broker; you and `forge-agent` can read it.
- **The broker process:** runs as `_forgebroker`; core dumps off; `forge-agent` isn't an
  administrator, so it is intended to be refused debugger and memory access (Goal; test R4). A pass demonstrates only the tested methods, privileges and system version; it cannot prove tokens can never be extracted.

### 13.8 What this still doesn't stop (stated, not accepted)

- **Approved actions on FORGE itself:** I could still open too many issues, PRs or comments there.
  Bounded by the write quota and visible in the log and on GitHub.
- **A broker bug is a hole.** Mitigated by review, the tests in 13.10, root-owned code and
  settings, and GitHub's own wall for code changes (9a). GitHub's wall does **not** cover public
  issues, so for those the broker is the only wall.
- **The internet outside GitHub:** the proposal controls authenticated operations through this broker; it does not establish a universal GitHub or internet data-loss boundary, including other identities or channels. Network limits are Claude Code's sandbox, already listed as not in this
  ticket (11).
- **You, as Mac administrator,** can read everything, the key included; unchanged.
- **The limits you accepted for the throwaway investigation** (a token possibly issued but never
  received; an interruption at an unlucky moment) are **not** carried over. With this design such
  a token stays inside the broker, never with me. That is your decision before stage 2, asked
  separately.

### 13.9 Daily workflow

**You:** unchanged. You approve PRs in your browser; PRs show the app's bot as author. Emergency
steps (4.3) still need only your browser, plus stopping the broker on the Mac. New: you can read
the broker's log to see every GitHub request I made.

**Me:** `forge-github <action>` instead of `gh` for anything that writes, and
`forge-github push-branch` instead of `git push`. Reads go through the broker too (one path to
check), or anonymously with `gh` for public data. FORGE's command conventions in `CLAUDE.md` and
the hooks change to match: owner-only paths, so by a PR you merge.

**When FORGE needs a new action:** I propose the entry (method, path template, schema), it is
reviewed like any change, and you install the new allowlist by a handoff (the root-owned settings
need your Mac password). Nothing reaches the list otherwise.

### 13.10 Tests

Unit tests (stage 2, no GitHub): the broker runs against a local stand-in for GitHub. Its test
settings live in a test folder; the production settings file is root-owned, so a test setting can
never point the real broker elsewhere.

Live tests (stage 3, on the Mac, as `forge-agent`, every one from an owner handoff, kind P with a
control as in section 6 of the plan):

| # | Tries, as `forge-agent` unless said | Must happen | Control |
|---|---|---|---|
| R1 | Connect to the broker as another Mac user (your account) | Refused by the user check | `forge-agent`, same read: works |
| R2 | List or open the broker's folders, settings, key; find any token file | Refused; no token file exists | You (admin) can read the key: the check is valid |
| R3 | Watch every process's command line and environment (`ps`) during 100 broker requests | No token or JWT pattern seen | A planted test value on `forge-agent`'s own process is seen (the watch works) |
| R4 | Attach a debugger to, or read the memory of, the broker | Refused | Attaching to `forge-agent`'s own process works |
| R5 | Each allowed action; scan everything returned | No token or JWT in any answer or error | A stand-in answer containing a fake token is withheld (unit) |
| R6 | Look for a GitHub credential in `forge-agent`'s reach (`gh auth status`, keychain, git config, environment) | None | — |
| R7 | Write to GitHub directly with no broker (an issue on the second throwaway) | 401: no credential | — |
| R8 | An action not on the list (settings change, a raw path) | Refused on the Mac; nothing sent | The broker's outgoing log shows no request |
| R9 | An approved action on another repository (the A2 case: an issue on the second throwaway) | Refused on the Mac; the second throwaway's issue count unchanged | The same action on the approved repository works |
| R9b | Each action's path form, by repository id | Works, or the name form plus the id check | — (a finding) |
| R10 | Names with `../`, `%2e`, `?`, `#`, encoded slashes, look-alike Unicode, overlong | Refused | A valid name works |
| R11 | Extra fields (`url`, `repo`, `method`, `path`) | Refused | The same form without them works |
| R12 | Redirects 301/302/307/308 from the stand-in (unit); a moved repository (live, if you approve renaming a throwaway) | Not followed; refused | — |
| R13 | Push: a bundle with `dev`, `main`, a tag, two branches, a deletion, a non-fast-forward, a workflow file, a secret | Each refused (on the Mac; non-fast-forward and workflow also by GitHub) | One feature branch pushes |
| R14 | A secret in a title, body or comment | Refused, rule named, nothing sent | The same text without it works |
| R15 | Writes past the quota | Refused | Under the quota: works |
| R16 | Broker stopped | Every request fails; no fallback | Broker started: works |
| R17 | Merge: a push after your approval; a push while the merge request is out; no or a stale approval | Each refused (by GitHub's conditional merge and protection; the broker never retries on a new head) | Your approval of the current head: merges |
| R18 | Push bundles carrying hostile git config, hooks, filters, helpers or submodules; malformed and oversized bundles | Refused or handled as data; no supplied program runs; no unexpected network or file access | A plain feature branch pushes |
| R19 | Each limit in 13.15 exhausted (size, time, pages, quota); audit log or disk unwritable | The action is refused; nothing sent | Within limits: works |
| R20 | The stand-in times out or drops the connection before and after a write commits; the broker dies mid-request | Reported `outcome unknown` with action id and target; reconciled by reads; never retried blindly | A normal answer: reported confirmed |

K1-K4 change: K4 ("read the token file: works") becomes R2 ("no token file exists").

**Item 9, proposed wording** (replaces 9 when the R tests pass): *I must be unable to make any
GitHub write, or read a private resource, other than an approved action on an approved
repository.* Enforced by: no GitHub credential in my reach (R1-R7, K1-K3); the broker's checks
(R8-R20); GitHub's installation limits for code changes (9a, probe 2026-11-14). **Status: failed and
unresolved** until R1-R20 pass live and you accept the revised claim.

### 13.11 Added maintenance

- **Allowlist updates:** a reviewed PR and your handoff each time FORGE needs a new action. Expect
  several while A12's list settles, then rare.
- **More code to review:** the broker grows from "mint and write a file" to a checked proxy with a
  push path. Its reviews are larger, and it is an owner-only path (you merge).
- **GitHub API version:** this run's answers say the version FORGE uses (2022-11-28) is deprecated
  since 2026-03-10, with a sunset of 2028-03-10 (Confirmed, this run's `Deprecation` and `Sunset`
  headers). The broker pins one version; moving it before the sunset is a reviewed change.
- **After each macOS update:** a short self-test handoff (R1, R3, R9 and one push), since the
  broker relies on the system's `curl`, `git` and Python.
- **Repository changes:** a new or recreated repository needs its id in the settings, by handoff.
- **Unchanged:** a new key every 90 days by handoff.

### 13.12 What changes in the plan, if approved

- 4.2: the broker forwards requests; no token file; the socket and the four checks (13.3-13.7).
- 4.3 day to day: tokens live only in the broker; minted when needed and revoked after use.
- 6: item 9 restated (13.10), still failed and unresolved; R1-R20 added; K4 replaced; A12
  becomes the source of the first allowlist.
- 8: stage 2 builds and unit-tests the broker proxy, the client and the push path; stage 3 runs
  R1-R20 live. The stage 1 throwaway app and both throwaway repositories would then be kept until
  stage 3's live tests instead of deleted at the end of stage 1 (R7, R9 need them): your decision.
- 10: the day-to-day lines above.

### 13.13 Cost

$0: the broker uses what macOS and its command line tools already have (`curl` 8.7.1, `git`
2.54.0, Python 3.9.6 standard library only, read on this Mac 2026-11-14). No new account, no
subscription. If the Python that comes with the command line tools is ever removed, the broker
stops and GitHub work stops (fails closed).

### 13.14 Decisions

Superseded by 13.17, which lists the remaining decisions.

### 13.15 Required clarifications and acceptance evidence (2026-11-15)

These requirements govern this proposal wherever earlier wording sounds stronger. The existing
stage-1 checkpoint, D1-D3 credential restrictions, D5-D8 and owner-only changes remain unchanged
(the stage 1 handoffs, paused when this was written, have since resumed: section 6). Section 4.2’s token-file mechanism, its 45-minute renewal narrative, and K4’s
successful token-file read are historical alternatives superseded by this proposal only if it is
later implemented and accepted. No token file or agent credential is part of the proposed end state.

- **Evidence, not guarantees.** R3/R4 show what the tested access methods were refused under the
  tested account, privileges and macOS version. They cannot establish that no exploit, future
  system change or untested method could extract a token. Item 9’s replacement is a bounded
  protection goal for broker-controlled operations, not proof that all GitHub writes or all data
  extraction are impossible. Item 9 remains failed and unresolved; A2 remains failed evidence.
- **Secret scanning:** scan text, paths and transferred Git data before publication; unreadable,
  incomplete or failed scans deny the action. Scanning reduces risk; it cannot guarantee that
  private information, novel secrets or sensitive ordinary prose will never be published.
- **Untrusted Git input:** never run agent-supplied hooks, configuration, helpers, filters,
  external diff/text converters, submodule commands or supplied programs. Use broker-created
  private storage, trusted executables, a clean environment and broker-controlled configuration;
  never reuse the agent’s repository or execute its checkout. Disable hooks, config includes,
  credential helpers and automatic maintenance; forbid external protocols and recursive
  submodule operations. Validate refs and object closure, use fixed argument arrays (no shell
  evaluation), bound decompressed objects and resource use, and scan the exact immutable objects
  that will be pushed. Bundle verification/fsck alone does not establish these properties.
  Add malicious config/hook/filter/helper/submodule fixtures and malformed/oversized bundles;
  verify no supplied program runs and no unauthorized network or filesystem access occurs.
- **Exact approval at merge:** bind the request to repository ID, PR number, base `dev` and full
  head SHA. Check owner approval and required checks for that version; invalidate on a new push.
  Submit a conditional merge naming the expected SHA and rely on server-enforced approval rules
  at the merge itself. A local pre-check alone is insufficient. A head change between validation
  and merge must refuse; never retry against a new head automatically. Changes to the base or
  protection state require revalidation; inability to establish the required state denies merge.
  Test both a push after approval and a push during the merge request, plus missing/stale approval.
- **Failure behavior:** authentication, parsing, scanning, identity, policy, quota, audit recording
  or upstream validation failures deny new actions with no direct-GitHub fallback. Bound input,
  output, socket reads, connect/overall time, concurrency, subprocess time, memory, disk, objects,
  pages and retries. The proposal’s 1 MB form and 50 MB stream are provisional; decompressed
  limits and exact timeouts still need a reviewed specification. Reserve quota before dispatch;
  concurrency and restarts must not reset or bypass it. Stop signals start no new write.
- **Uncertain writes:** timeout, disconnect or process death after dispatch can mean GitHub
  committed the write. Report `outcome unknown`, action ID, target, expected SHA and available
  GitHub request ID; never claim refusal or success without evidence and never blindly retry.
  Persist a pre-dispatch record, reconcile by bounded reads of authoritative remote state, and
  hold conflicting/repeat actions pending resolution. Unknown token issuance/revocation must
  likewise be reported with possible scope and expiry, without token values. The throwaway-only
  exceptions are not accepted for production by this proposal. Test timeouts before/after commit,
  crashes, disk/log failures, interrupted responses and exhausted limits.

### 13.16 Exactly what the owner can inspect (proposed interfaces)

| Surface | Visible information | Limits |
|---|---|---|
| Metadata-only audit log, readable by owner and agent | UTC time, unique action ID, kernel-derived user ID, action, repository ID, object/ref identifiers, expected head SHA, policy version, request digest, decision/reason code, dispatch state, HTTP status, safe GitHub request ID, confirmed/unknown outcome and reconciliation link | No title/body/comment text, patch, bundle, response body, auth header, token, JWT, private key or raw error/redirect text. Identifiers themselves may be sensitive. A digest links bytes; it does not reveal or reconstruct them. |
| Review preview for a pending request | Exact validated destination/action and proposed title/body/comment; for pushes, ref, immutable SHA and complete publishable diff/commit/path scope; for merges, PR/base/head and matching approval/check evidence | Separate from the audit log. Preview must bind to the dispatched immutable request; editing invalidates it. This interface is proposed, not available now. It gives no credential access. |
| GitHub after a confirmed write | Published issue/comment/PR content, commit objects/diffs, review/check state and merge result | Shows remote content, not necessarily the exact originally submitted bytes; content can later be edited/deleted. Missing content does not prove no write occurred. |
| Owner’s administrator inspection | Broker source, installed binary/version, root-owned policy, permissions, service configuration and test evidence | Administrator access can reach credentials; the agent gets no additional access. Never print credentials into chat or audit exports. |

The broker must process request contents transiently to validate and send them. **Metadata-only
logging is not a retained copy of those contents.** Historical exact request inspection requires a
separate, explicitly approved content archive with access, encryption, retention/deletion and
redaction rules. No such archive is authorized here. Without it, previews plus published GitHub
objects are inspectable, but past rejected requests or vanished content cannot be reconstructed.
A safe export/viewer and exact digest canonicalization remain implementation specification work.

### 13.17 Final proposed scope, decisions and FORGE schedule impact

Scope to review before implementation: request broker and local client; kernel user authentication;
root-owned repository/action policy; typed bounded schemas and scanning; safe Git bundle ingestion
and non-forced feature pushes; conditional approved merges into dev; credentials kept inside the
service; sanitized responses; metadata audit plus request preview; quotas; bounded failure,
interruption and unknown-outcome reconciliation; install/undo owner handoffs; expanded unit and
live tests. No main writes, extra permissions, arbitrary URLs, private-repository support, general
network isolation or FRG-27 review isolation are added. No implementation starts from this revision.

Remaining owner decisions, asked one at a time (recording this proposal is already authorized):
1. Whether to keep the existing throwaway app and both repositories through stage 3 for live tests,
   with revised reviewed cleanup/revocation handoffs. Recommendation: retain only for those tests;
   do not silently skip the stage-1 revocation/app-deletion tests or widen installations.
2. Write quota numbers (proposal: 60/hour and 300/day; retries and push counting must be specified).
3. Production handling and acceptance, if any, of residual token-issuance, interruption and uncertain
   write risks, after concrete recovery behavior and tests are reviewable.
4. Decided (owner, 2026-11-15): the remaining stage-1 handoffs resume before the broker exists,
   with A2 changed to code changes only (section 6); their scope and the reviewed-owner-handoff
   requirement are unchanged.
5. Whether historical request contents should be archived or only metadata retained. Recommendation:
   metadata plus immutable preview, with the historical inspection limits explicitly accepted.

Before coding, present a consolidated scope incorporating those answers, measurable limits,
acceptance tests, residual risks and a refreshed effort estimate for owner review. That review
cannot substitute for the existing checkpoint after stage 1 or authorize any Mac changes early.

Timeline: this replaces a token-renewal helper with a substantial security component. It adds
client/proxy work, Git parser containment, approval race tests, audit/preview handling, crash recovery
and more review/live-test effort to FRG-26 stages 2–3. Stage 1 still needs its remaining handoffs and owner
checkpoint; stages 4–5 and FRG-27 follow the tested broker. FRG-28/30/32/34 remain behind the
existing checkpoint under the recorded schedule. Planning for 5:00 remains allowed; credential,
payment (including test-mode keys) and deployment restrictions do not move. No dry-run deployment
may bypass them. FRG-7–12 work may proceed only where existing gates allow; their current completion
status and remaining work must be refreshed before quoting dates. The earlier 1–2 week estimate
is historical, not a current commitment. A defensible new calendar estimate needs the decisions,
a concrete task breakdown, review/CI/handoff allowances and current backlog status; no fixed delay
or finish date is established by this plan change.

## Sources (read 2026-11-01)

Listed in `docs/decisions/2026-11-01-frg26-github-app.md`, plus:
- https://docs.github.com/en/rest/authentication/permissions-required-for-github-apps
- https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app
- https://docs.github.com/en/rest/apps/installations
- https://docs.github.com/en/rest/apps/apps
- https://docs.github.com/en/apps/using-github-apps/reviewing-and-modifying-installed-github-apps
- https://docs.github.com/en/apps/creating-github-apps/about-creating-github-apps/best-practices-for-creating-a-github-app
- https://docs.github.com/en/rest/actions/secrets
- https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow
- https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments
- https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app
- https://docs.github.com/en/apps/github-marketplace/selling-your-app-on-github-marketplace/pricing-plans-for-github-marketplace-apps
- https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/token-expiration-and-revocation
- https://github.blog/changelog/2026-04-24-notice-about-upcoming-new-format-for-github-app-installation-tokens/ (read 2026-11-06)
- https://github.blog/changelog/2026-10-02-stateless-github-app-installation-tokens-rolled-out/ (read 2026-11-06)
