# Decision: FRG-26 uses a GitHub App, not a helper account

- **Date:** 2026-11-01
- **Decided by:** owner (Thebigtuna88)
- **Status:** accepted for stage 1 implementation and independent reviews
- **Related:** FRG-26 (#26), plan `docs/plans/2026-10-20-frg-26-permissions-isolation.md` (revised
  2026-11-01), `2026-10-20-five-oclock-credentials-wait-for-frg-26.md`

## The owner's words

> Reassess whether FRG-26 needs a separate GitHub helper account. Compare using my main account
> with restricted credentials, a GitHub App, and the helper account.

> I approve the GitHub App direction […] Keep the private key inaccessible to the agent; don't use
> the simpler fallback by default.

> I approve draft 2 for Stage 1 implementation and independent reviews. Keep all live GitHub
> actions behind reviewed owner handoffs, and preserve the checkpoint before Stage 2 and any Mac
> changes.

## In plain words

The agent needs a GitHub identity that is not the owner, so that GitHub itself requires the
owner's approval (an author can't approve their own PR) and keeps `main` the owner's. The helper
account does that but is restricted by GitHub with no date for Support to lift it. The owner's own
account with a narrower token can't do it at all: to GitHub the agent would be the owner. A GitHub
App the owner creates does it, with per-repository permissions and one-hour tokens, and its private
key stays with a token broker the agent can't read.

Nothing on GitHub or the Mac changed for this decision. The comparison, as read from GitHub's
official docs on 2026-11-01, follows.

## Facts that decide it (Confirmed, docs)

- "Pull request authors cannot approve their own pull requests."
- "Require approval of the most recent reviewable push": it "must be approved by someone other
  than the person who pushed it."
- Code owners "must have write permissions"; CODEOWNERS is read from the PR's base branch.
- Branch protection does not apply to admins unless "Do not allow bypassing the above settings"
  is on. "Actors may only be added to bypass lists when the repository belongs to an
  organization." "Restrict who can push" is organisation-only.
- Rulesets: public repos on GitHub Free; bypass by role, team or GitHub App. What a personal
  repo offers is not stated (plan step 0 still decides; round 8 saw the User form refused, 422).
- Fine-grained PAT: one resource owner, selected repositories, chosen permissions; "the same
  capabilities ... that the owner of the token has, and is further limited by" its permissions.
  Not supported: "repositories where the user is an outside or repository collaborator".
- GitHub App: no permissions by default; installed "Only on this account" with "Only select
  repositories"; changed permissions need the installing owner's approval; installation tokens
  last 1 hour and are minted with a JWT signed by the app's private key; actions are "attributed
  to the app" (bot account, e.g. @name[bot]); Git over HTTPS with the token as password; the
  "Workflows" permission is needed to edit `.github/workflows`. Private keys never expire; anyone
  holding one gets "persistent authentication as the GitHub App" until it is deleted. Rate limit
  at least 5,000 REST requests/hour.
- Terms of Service: one free personal account plus "no more than one free machine account";
  accounts "registered by bots or other automated methods are not permitted".

## Per approved protection (GitHub side)

| Plan row | A: owner + fine-grained PAT | B: GitHub App | C: helper account |
|---|---|---|---|
| 1 no push / force-push / delete `dev`, `main` | Only with "Do not allow bypassing" on; `main`'s ruleset bypass is the admin role, which the token's user holds: **likely NOT enforced** (Unconfirmed) | Enforced: not admin, not a bypass actor | Enforced: write, not admin |
| 2 only the owner updates `main` | **NOT enforced**: to GitHub the agent is the owner | Enforced (subject to step 0, as before) | Enforced (subject to step 0) |
| 3 no merge into `dev` without the owner's code-owner approval of the latest push | **NOT possible**: the owner is the PR author and last pusher, so cannot approve; a merge needs a bypass, so GitHub never checks the owner's approval | Enforced: author and pusher are the app; the owner approves as code owner | Enforced: author and pusher are the helper |
| 4 settings, protection, rulesets, delete/archive/transfer | Enforced by the token (no Administration) | Enforced (no Administration) | Enforced (write role; no `delete_repo`) |
| 5 secrets, deploy keys, webhooks, collaborators | Enforced by the token | Enforced | Enforced (secrets Unconfirmed, as before) |
| 6 workflow files | Enforced (no Workflows permission) | Enforced (no Workflows permission) | Enforced (no `workflow` scope; identical-file caveat stays) |
| 7 widen own access | Token can't make tokens; but it is the owner's account | Only the owner changes permissions and approves them | Classic token; the owner holds the account |
| 9 only FORGE repos | Enforced (selected repositories) | Enforced (selected repositories) | Classic `public_repo` reaches every public repo the helper can write to (only invited ones) |

## Authorship and the owner's approval

- A: PRs, pushes, comments and merges all show as the owner. GitHub can't tell agent from owner.
  The owner can't approve them (author rule), so D5 can't be met by GitHub.
- B: PRs and pushes show as the app's bot. The owner reviews and approves from their own account;
  that approval is what GitHub checks. Commit author lines come from git config (labelled).
- C: as the plan: PRs by the helper, approved by the owner.

## Limits that remain

- A: fails D5 and D6 at GitHub level; only FORGE's hooks would stop merges and `main` updates
  (the L13 gap FRG-26 exists to close). Not a fit.
- B:
  - The private key is a credential that never expires; stolen, it mints tokens until the owner
    deletes it (fine-grained, selected repos, 1 hour each). As accepted (D10, the owner's words
    above): it is held by a token broker running as its own Mac user (`_forgebroker`), never by
    `forge-agent`; the agent only reads the current 1-hour token. Revoke: delete the key in the
    app's settings; to stop access at once, suspend the installation (plan 4.3). (This comparison
    first said "held by `forge-agent`"; corrected in review round 17.)
  - New code: a token-minting step (JWT, owner-only paths likely) and changes to
    github-throwaway.sh (e.g. `need_helper_identity` reads `GET /user`, which an installation token
    is not expected to serve: Unconfirmed). Every `gh` command FORGE uses must work with an
    installation token: Unconfirmed, a test decides. Then a full review cycle and new handoffs.
  - Owner work: create the app in the web UI (permissions: Contents, Pull requests, Issues
    read/write; Metadata read; nothing else), install it on selected repos, generate the key and
    give it to the broker through a handoff (plan 4.2).
  - No second account, no Terms question, and no wait on GitHub Support.
- C:
  - The account is restricted by GitHub today (diagnose-5, 2026-10-31); the stage-1 tests wait on
    Support with no date.
  - Fine-grained tokens don't work for collaborators, so the token is classic `public_repo`.
  - Allowed as the owner's one free machine account; it could be flagged again.

## Recommendation made to the owner (2026-11-01), then accepted

B, a GitHub App. It keeps D5 (the owner is never the author) and D6 (the app is not an admin)
like C, with tighter, per-repository permissions and short tokens, and needs no second account or
Support. The cost is new code, a new review cycle and new handoffs, and a key that never expires.
If chosen: rewrite the plan section 4B and the stage-1 test script around the app, plan only,
for approval first. The checkpoint before stage 2 stays.

## Sources (read 2026-11-01)

- https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/approving-a-pull-request-with-required-reviews
- https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches
- https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets
- https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets
- https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository
- https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners
- https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens
- https://docs.github.com/en/apps/creating-github-apps/about-creating-github-apps/deciding-when-to-build-a-github-app
- https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app
- https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app
- https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation
- https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps
- https://docs.github.com/en/apps/using-github-apps/installing-your-own-github-app
- https://docs.github.com/en/rest/authentication/permissions-required-for-github-apps
- https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api
- https://docs.github.com/en/site-policy/github-terms/github-terms-of-service
