# Decision: deliberately disguised commands are a known limit (L13)

- **Date:** 2026-10-19
- **Decided by:** owner (Thebigtuna88), after FRG-4's review round 10
- **Status:** accepted, on condition that the approved design says so (spec 1.2, 5.2, 10.5 and
  11 updated in the same PR)
- **Accepted risk, not fixed:** FRG-4 review round 10, security finding SEC-1 (major), deferred
  to FRG-26 (#26)

## In plain words

The FORGE hooks read each command before it runs and refuse the ones that break the rules. They
are good at catching **ordinary commands and mistakes**: `gh` or `git` written out by name, with
any options, quoting, chaining or inherited settings. Conformance proves that for every listed
case.

They **do not reliably stop a command deliberately built to hide** that it runs `gh` or `git`,
for example by spelling the tool's name in a way the text check doesn't recognise. Review rounds
6, 8, 9 and 10 each found another such way. Each was patched, and the next round found another.
Reading a command's text can't predict everything the shell will make of it, so this list has
no end.

So the hooks are a guardrail, not a lock. The lock is what the agent's own credentials and macOS
user are **unable** to do, whatever command it runs. That is FRG-26.

## Decision

1. Add known limit **L13** to spec 11: a command deliberately built to hide a guarded tool
   (`gh`, `git`, a deploy tool) from the gates may not be judged as that tool. Same family as
   L1 (commands inside a script file) and L12 (evidence the agent writes).
2. **Round 10's SEC-1 stays open as accepted risk.** It isn't fixed, and FORGE doesn't claim
   it is. It's deferred to FRG-26 and listed in `review.md`'s deferred findings, so the merge
   gate checks that FRG-26 is still open.
3. The checks added in rounds 2-9 stay. They catch some disguises, but FORGE no longer claims
   they catch all.
4. The reviewers are told about L13: report what an ordinary command or an honest mistake gets
   past the gates, not a new way of deliberately disguising one. Anything else stays in scope
   as before, including a disguise that an ordinary command could fall into by accident.
5. **FRG-26 (permissions isolation)** defines which actions the agent's own GitHub credentials
   and macOS user must be unable to perform, and tests each one. A separate account alone is
   not enough: what matters is what that account and its token can't do, proven by tests.

## How this changes FORGE's guarantees

| Promise | Before (as written) | Now |
|---|---|---|
| The gates refuse rule-breaking `gh`/`git` commands | "Every `gh` invocation wherever `gh` may run is guarded" (spec 5.2) | Every ordinary `gh`/`git` command is judged; a deliberately disguised one may not be (L13) |
| I can't merge an owner-only change, change GitHub settings, delete anything or widen my login (FRG-4 plan) | Stated without conditions | Holds for ordinary commands. Against a deliberate disguise, it rests on the charter (rule 9), the reviews and FRG-26, not on the hooks |
| `main` is human-only | Gates plus GitHub branch protection | Unchanged for ordinary commands. My `gh` login is your admin login (L2), and an admin can change branch protection, so against a deliberate attempt nothing technical holds this until FRG-26 |
| Review before every merge into `dev` | Merge gate | Unchanged for ordinary commands. GitHub itself requires a PR but no approval or check, so a disguised merge isn't stopped there (L2, L12, L13) |

Spec 1.2 already said the hooks "cannot stop a determined program that has a shell". L13 makes
that concrete for `gh` and corrects the sentences in spec 5.2 and the FRG-4 plan that promised
more.

## Effect on the dry run (spec 1.5, 10.5)

The criteria are unchanged and can still be met: tests ALL PASS, conformance proving every listed
case, one project end to end, and `CONTINUE FORGE`. None of them tests resistance to a deliberate
disguise. A pass proves the workflow and the gates against ordinary commands and mistakes.
It doesn't prove the agent couldn't get around them on purpose. Spec 10.5 now says so. Whether 5:00 waits
for FRG-26 is a separate owner decision.

## Alternative not taken

Keep patching each disguise as reviewers find them, round by round (rounds 6, 8, 9 and 10 show
the list has no end).
