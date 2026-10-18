# Decision: merges stop before committing

- **Date:** 2026-10-18
- **Decided by:** owner (Thebigtuna88)
- **Status:** accepted

## Decision

**A merge in a ticket worktree never makes its own merge commit.** A branch is updated with
`git merge --no-commit dev`, then `git commit -F <message file>`. The commit goes through the
secret scan, which reads the whole merged result from the index. Fast-forwards
(`--ff-only`), `--squash` and `--abort` are unchanged. The main checkout still only fast-forwards.

## Why

FRG-3 review round 15 (security lens): an automatic merge commit was allowed after scanning only
its author and committer. Repository settings such as a custom merge driver or a filter can write
new content into the merged files, which git would then commit unscanned. Requiring the merge to
stop closes that whole class: whatever the merge produces is scanned before it becomes a commit.

## Alternative not taken

Keep the one-step `git merge dev` and refuse it while merge-driver or filter settings exist. That
keeps the charter's wording, but closes only the known ways in. The cost of the chosen option is
one extra command, which the agent runs.
