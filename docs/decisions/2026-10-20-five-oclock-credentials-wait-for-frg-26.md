# Decision: 5:00 gets no real credentials until FRG-26 protects them

- **Date:** 2026-10-20 (UTC; 2026-10-19 on the owner's clock)
- **Decided by:** owner (Thebigtuna88), after the FRG-4 live proof
- **Status:** accepted
- **Related:** known limit L13 (`2026-10-19-disguised-commands-known-limit.md`), FRG-26 (#26)

## The owner's words

> 5:00 may be brainstormed and planned, but must not receive real business credentials, payment
> access, or production deployment access until the relevant FRG-26 protections are implemented
> and tested.

## In plain words

Today I run as the owner's macOS user with the owner's GitHub admin login. The FORGE hooks stop
ordinary commands and mistakes, but not a command deliberately disguised to get around them
(L13). So anything handed to me is reachable by such a command. Until FRG-26 takes those powers
away and tests each restriction, 5:00 gets nothing that could cost money, leak customer data or
reach production.

## What this allows and forbids

| Allowed now | Forbidden until the relevant FRG-26 protections are implemented and tested |
|---|---|
| Brainstorming 5:00 with the owner | Real business credentials: any login, API key or token for an account 5:00 actually uses (store, email, domain registrar, analytics, suppliers) |
| A 5:00 spec and plan, written as documents | Payment access: any key or login for a payment provider account (Stripe, Shopify Payments, PayPal) |
| | Production deployment access: hosting or deploy tokens, DNS, App Store / TestFlight |

1. **This adds a condition; it doesn't move the start line.** The spec's phase order is
   unchanged: building 5:00 still starts only after Phase 7 (the dry run). This decision adds a
   second condition to the credentials, payments and deploy steps.
2. **"Relevant" is decided item by item in the FRG-26 plan**, which maps each kind of access
   above to the FRG-26 protections it needs. The owner approves that mapping. Until then, every
   FRG-26 item counts as relevant.
3. **"Tested" means FRG-26's own tests:** each restriction is tried with the agent's real
   credentials or macOS user, and GitHub or macOS (not a FORGE hook) refuses it.
4. **Open, to be asked later:** whether test-mode keys of a real payment account (for example a
   Stripe test secret key) count as payment access. Until the owner answers, they do.

## Alternatives not taken

- Start 5:00 with credentials once Phase 7 passes, relying on the hooks (what the spec allowed
  before L13). Not taken: the hooks are a guardrail, not a lock.
- Block 5:00 entirely, brainstorming included, until FRG-26. Not taken: documents carry no
  credentials, so planning can go ahead safely.
