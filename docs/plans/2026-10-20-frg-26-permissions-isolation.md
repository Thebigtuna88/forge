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
  revised protection claim; the later stage 1 handoffs wait. Nothing on the Mac or in FORGE's
  settings has changed.
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
  - S2d: a run you start yourself: your own approval is refused (shows Prevent self-review is
    really on). Refused needs all of: GitHub says you can't approve it (`current_user_can_approve`
    false), GitHub itself answered the approval with a 4xx (not a network error or a rate limit),
    and the run still waits. Control: your same request on the app's run in S2b worked. The run is
    then cancelled.
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
| 9 | Write to, or read private resources of, repos it isn't installed on | Selected repositories + narrowed tokens | Confirmed (docs); **failed in A2 for issues, 2026-11-11; unresolved** | A2 (P) |
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
| A2 | Push, open a PR, open an issue on a second public throwaway repo the app isn't installed on | Refused. **2026-11-11: FAILED** (the issue was allowed; below the table) | Same three on the installed repo succeed. The PR's branch there must be ahead of main (checked first), or no one could open it (review round 15) |
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
to the second throwaway.

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
