# Decision: repository visibility and branch protection

- **Date:** 2026-10-15
- **Decided by:** owner (Thebigtuna88)
- **Status:** accepted

## Context

GitHub branch protection is FORGE's server-side safety layer (spec 3.2). Per GitHub docs
(checked 2026-10-15), protected branches are available on public repos with GitHub Free;
private repos need GitHub Pro or above.

## Decision

- FORGE (`Thebigtuna88/forge`) is **public**. It contains no secrets, by rule 10.
- Each governed project chooses public or private when `new-project` creates it. A private
  project without Pro is recorded as `"protection": "local-only"`, and `status` surfaces that.
- Commits use the owner's GitHub noreply email.

## Alternatives rejected

- GitHub Pro for everything: a recurring cost that isn't needed yet.
- Everything private without Pro: no server-side protection at all.
