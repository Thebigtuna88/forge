## Lens: spend

Paid APIs, image generation and payments (spec 8). Check:
- Every paid call goes through the budget wrapper; nothing calls a provider directly.
- Caps are read from `.harness/spend-limits.json` (owner-only); a missing or malformed file, or a
  disabled provider, refuses the call.
- Every call writes a complete ledger entry, including failures that may still be charged.
- Retries, loops or concurrent calls can't multiply cost past a cap.
- No live keys anywhere; payments run in test mode until the owner flips it (rule 8).
- A change to spend limits, providers or the spend gate is the owner's (rule 7).
