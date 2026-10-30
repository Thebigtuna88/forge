## Lens: spend

Paid APIs, image generation and payments (spec 8). This lens reviews every PR, whatever it
touches (owner decision 2026-10-29), so start by asking what in the change could spend money:
a new call to a paid API, a provider's SDK or command-line tool, a new provider, a script or
program that calls one indirectly, or a change to what the spend gate or the budget wrapper allow.
If nothing could, the reply is CLEAN. Check:
- Every paid call goes through the budget wrapper; nothing calls a provider directly.
- Caps are read from `.harness/spend-limits.json` (owner-only); a missing or malformed file, or a
  disabled provider, refuses the call.
- Every call writes a complete ledger entry, including failures that may still be charged.
- Retries, loops or concurrent calls can't multiply cost past a cap.
- No live keys anywhere; payments run in test mode until the owner flips it (rule 8).
- A change to spend limits, providers or the spend gate is the owner's (rule 7).
