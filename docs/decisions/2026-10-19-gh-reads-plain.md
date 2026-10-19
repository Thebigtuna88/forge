# Decision: gh reads are one plain command, and never open a browser

- **Date:** 2026-10-19
- **Decided by:** owner (Thebigtuna88)
- **Status:** accepted (implementation in FRG-4, review round 7)

## Context

FRG-4's approved plan let read-only `gh` commands (`gh pr view`, `gh issue list`, `gh search`, …)
skip the one-plain-command rule, so a read could sit in a pipeline (`gh pr view 5 --json files |
jq …`). That needed the gates to predict everything the shell can do to such a command, and
every review round from 2 to 7 found a new way the shell changes what a read sends to GitHub or
what it runs: `xargs -I` rewriting its words into `gh repo delete` (round 2), `$S` (3), an
unquoted glob turning into a file's name (4), a line continuation hiding `gh` from the scan (4),
inherited `GH_PAGER` running a program (5), a `#` hiding the lines after it, an inline
`GH_PAGER=…` and `BROWSER` (6), `~+` and `HOME=…`/`XDG_CONFIG_HOME=…` pointing gh at another
settings file whose `browser` it runs (7). Each was patched; the next round found another.

## Decision

- Every `gh` command is guarded, reads included: one plain command (no pipes, chains, `$`,
  backticks, redirection, `~`, globs, `#` or line breaks, nothing in front of `gh`), judged by
  `deny-repo-admin` by its real command, so `--repo` still doesn't count as `gh repo`.
- A read never opens a browser: `gh browse` is no longer a read, and `--web`, `--web=…` and `-w`
  (alone or among other one-letter options) are refused, because the browser is whatever
  program gh's settings name.
- What stays: the secret scan of every command that names `gh`, reads included; the refusal
  while `GH_*`, `GITHUB_*`, `BROWSER` or `PAGER` is set; `#` no longer hiding later lines.
- The per-trick read checks from rounds 3-6 (`$`/backtick, the quote-aware glob check, named
  `GH_*` variables) are removed: the plain-command rule refuses all of them.

## Consequences

- `gh … | jq …` is refused; `gh … --jq <filter>` does the same job. A filter containing `|`,
  `[ ]`, `$` or other shell characters is refused even inside quotes: the existing false positive
  ticketed as FRG-22 (#22), which now applies to reads too.
- Fewer moving parts in `hookrt.sh` for reviewers to attack.
- Agent-written `gh` settings (a config file with a `browser` or `pager`) no longer matter to
  reads: no read opens a browser, and gh pages only on a terminal, which Claude Code's Bash isn't
  (`GH_FORCE_TTY` is refused).

## Alternative not taken

Keep the pipeline exemption and patch round 7's two findings (`~`, `HOME`/`XDG_CONFIG_HOME`) like
the earlier ones, round by round.
