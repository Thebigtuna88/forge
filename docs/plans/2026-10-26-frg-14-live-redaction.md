# FRG-14: Live redaction of handoff step output — plan section

- **Status:** APPROVED by the owner on 2026-10-26, with Option A (`ho_redact_file`). See "Built
  as planned, with these details" at the end.
- **Ticket:** FRG-14 (#14), narrowed to live redaction on 2026-10-26. The inline-interpreter ban
  is FRG-30 (#30), planned with FRG-26 stage 2.
- **Owner-only:** it changes `.harness/lib/` and `docs/specs/`, so the owner merges.

## In plain words

When a handoff collects a secret, such as a token, the runtime hides it as `[REDACTED]`. But today
it does that only **after** each step finishes, and only in two places: the result block you paste
back, and the step's saved log. If a step prints the secret while it runs, three things happen:
- the real value appears on **your screen**;
- it sits in the step's **log file** until the step ends;
- if the run is killed mid-step, it stays in the log **for good**.

FRG-14 puts a filter between each step and your screen. Everything the step prints passes through
it, and any collected secret is replaced with `[REDACTED]` **before** it reaches the screen or the
log. The filter writes the log too, so the log never holds the raw value, even mid-step.

## How it works

Today a step runs as `script -q <log> /bin/bash -c '"$@"' …`. script(1) gives the step a terminal,
shows its output, and copies it to the log.

After FRG-14:

1. script(1) still gives the step a terminal, but writes no log (`/dev/null`). Its output goes into
   a pipe.
2. A small filter, the new file `.harness/lib/handoff_redact.py`, run on Apple's own Python
   with `-I` (see the details at the end), reads that pipe. It writes the redacted output to your screen and to the step's log.
3. **How the secrets reach the filter:** through a private pipe on a separate file descriptor
   (bash process substitution), one per line. Never on a command line, so `ps` can't show them.
   Never in an environment variable, so the step can't inherit them.
4. **Matching:** the filter masks every byte that any occurrence of any secret covers, so a secret
   that contains or overlaps another is hidden whole (as built; see the details at the end).
5. **A secret split across two writes:** the filter holds back only the end of what it has
   received, and only if that end could be the start of a secret. The rest is shown at once. The
   held part is shown as soon as more output proves it isn't a secret, or when the step ends.
6. **Exit status:** the runtime takes the step's status from script(1) (`PIPESTATUS`), so PASS and
   FAIL work as today.
7. **Fail closed:** if the filter fails or dies, the step is a FAIL and the run ends FAILED. If it
   can't start at all, the step's output is lost rather than shown raw.
8. **Ctrl-C:** the filter ignores SIGINT, so it keeps filtering until the step ends. A Ctrl-C
   typed during a step reaches the step, which fails (see the details at the end). Anything held
   back when the filter is killed is dropped, never shown.
9. **A second pass stays:** today's after-step redaction of the log and the evidence stays as it is.

**Confirmed on this Mac (2026-10-26)**, with a throwaway prototype (`work/FRG-14-live-redaction/`:
`redactor.py`, `step.sh`) run inside a pseudo-terminal:
- the step still had a terminal for input and output;
- a secret printed in two pieces with a 0.3 s pause between them appeared as `[REDACTED]`;
- a `[y/N] ` prompt with no newline appeared, and the typed answer reached the step;
- the step's exit status (7) came back through `PIPESTATUS`.

## Decision for you: which secrets it hides

**Today**, the runtime hides only secrets collected **in the same run**, by `ho_secret_to_file`.
A secret stored by an **earlier** handoff isn't hidden at all: not on screen, not in the log, not
in the result block you paste into the chat. FRG-26's helper token is exactly this case: one
handoff stored it, and later handoffs use it.

- **Option A (recommended): add a helper, `ho_redact_file <name> <absolute file>`.** It names a
  gitignored secrets file, and the runtime reads its `VAR=value` values into the redaction list
  without printing them. The step records only how many values it loaded. Lint allows it only on
  gitignored, absolute paths, like `ho_secret_to_file`. FRG-26's next handoffs would add one line
  naming the helper-token file.
- **Option B:** keep FRG-14 to secrets collected in the same run, and make Option A its own
  ticket.

## What it doesn't do (stated in spec 4.3 and L11)

- **A step built to get around it still can.** It could write straight to your terminal's device
  by path, print the secret in pieces with screen codes between them, or encode it. That's L11's
  "steps run arbitrary programs", narrowed by FRG-30, not closed here. Live redaction protects
  against accidental printing.
- **It only hides secrets the runtime knows:** this run's collected secrets, plus files named with
  `ho_redact_file` if Option A is chosen.
- **A held-back piece can delay output.** If a step prints the first few characters of a secret
  and then waits for input, those characters don't show until it continues or ends. There is
  deliberately no timer that flushes them: that would show part of the secret.

## Tests

Each is written to **fail on today's runtime**, then pass. They run in `tests/unit/handoff-runtime.test.sh`
with the pty driver, using fake secrets made of `% @ , +`, as FRG-23 did.

| # | Test | Fails today because |
|---|---|---|
| R1 | A step prints a collected secret: the screen capture holds no piece of it | The screen shows it |
| R2 | A step prints the secret, then sleeps: read **mid-step**, the log holds no piece of it | script(1) writes the raw log live |
| R3 | Same, but the run is killed mid-step: the log holds no piece of it afterwards | The raw log stays |
| R4 | The secret is printed in two writes with a pause between them: redacted on screen and in the log | (new behaviour) |
| R5 | Overlapping secrets: replaced whole, longest first, live | (new behaviour) |
| R6 | While a step runs, no process's command line (`ps -ww`) and not the step's environment holds the secret | Guards the out-of-band rule |
| R7 | The filter is missing or changed: the run is refused before any step. The filter dies mid-step: the run ends FAILED, and nothing is shown raw | Fail closed |
| R8 | Ctrl-C mid-step: the run ends FAILED, and neither the screen nor the log holds the secret | Fail closed |
| R9 | Regressions: a prompt without a newline appears and gets its answer; the exit status is kept; screen codes and `\r` pass through; a step with no secrets prints exactly as before | Unchanged behaviour |
| R10 | Option A only: a value from a named file is hidden; a non-gitignored or relative file is refused; the count is recorded, not the values | (new helper) |

Plus `handoff lint` tests for `ho_redact_file` (Option A), `bash tests/run.sh` → ALL PASS, and
codex `code` + `security` rounds to CLEAN.

## Files and spec changes

- `.harness/lib/handoff.sh`: `_ho_run` uses the pipeline; secrets go to the filter on a private
  file descriptor. Option A adds `ho_redact_file`.
- New: `.harness/lib/handoff_redact.py`, the filter.
- Option A only: `.harness/lib/handoff_grammar.py` and `.harness/bin/handoff` learn the new
  helper.
- `docs/specs/2026-10-15-harness-design.md`:
  - 4.3: redaction is live, on screen and in the log;
  - 4.4: Option A's grammar;
  - 10.3: the coverage row;
  - 11 L11: live redaction done, inline interpreters moved to FRG-30.
- This section goes into `docs/plans/` with the PR.

## Rollout

- **Owner-only:** you merge, through a merge handoff, as usual.
- **Merge only when no handoff is waiting for your paste.** A runtime change makes earlier runs
  fail verification by design (spec 4.5), so a handoff run before the merge would need re-running.
  Right now nothing is waiting: FRG-26's next handoffs will be new ones.
- **Interaction with FRG-26:**
  - its planned change to where secrets are stored (item 14) touches a different function;
  - whichever lands second merges `dev` in and is re-reviewed;
  - nothing about FRG-26's checkpoint or credential restrictions changes;
  - FRG-14 changes no settings, Mac accounts or permissions.
- **Not in this ticket:** the inline-interpreter ban (FRG-30), and where secrets are stored
  (FRG-26 item 14).

## Built as planned, with these details

- **The filter is pinned.** `handoff.sh` holds the filter's sha256 (`HO_REDACT_SHA256`), and
  `ho_begin` refuses to run if `handoff_redact.py` is missing, a symlink, or different. So the
  `runtime-sha256` in every result also covers the filter, and verify's check 4 (spec 4.5) also
  confirms that the filter still matches the pin. `ho_begin` reads the filter once and every step
  runs that checked text (`python3 -c`), so replacing the file mid-run changes nothing. Changing
  the filter means updating that line in the same PR.
- **The interpreter is Apple's own,** found by fixed path (Command Line Tools, then Xcode) and
  required to be root-owned and not writable. It is never the `/usr/bin/python3` shim, whose
  choice of interpreter follows `DEVELOPER_DIR` (review round 1).
- **Masking covers every matched byte** (review round 1). Every byte that any occurrence of any
  secret covers is masked, judged on the original bytes, so overlapping secrets can't leave a
  piece showing. The filter carries "already masked" across reads, so it never holds more than
  one secret's length minus one, even for output that matches a secret over and over.
- **`ho_redact_file` reads through the checked interpreter.** It opens the file without following
  a symlink, refuses anything but a regular file, confirms after opening that it is still the file
  at that path with no symlink anywhere in the path, and only then are git's tracked and ignored
  checks applied to that path (review round 1).
- **What today's log really held** (found by the red run). script(1) buffers its log, so before
  FRG-14 the raw secret reached the log mid-step only once a step had printed enough to fill that
  buffer (the tests print 200 kB). After that, it stayed if the run was killed. The screen always
  showed it at once.
- **`ho_redact_file` accepts only safe values.** Every `VAR=value` line must hold a value of at
  least 8 characters, of the kind `ho_secret_to_file` stores. Otherwise the step FAILs and hides
  nothing, because a shorter value would blank out ordinary output. Blank lines and `#` comments
  are skipped. Its file counts as a secret file for lint: no other step may name it.
- **Ctrl-C at a step's prompt** reaches the step, because script(1) keeps the terminal raw. The
  step fails, and the run goes on to the next step or `|| ho_abort`, as it did before FRG-14. The
  filter ignores SIGINT either way.
- **Test design note:** the runtime prints each step's command before running it. So a test
  whose step prompts with a literal `[y/N] ` gets answered early; the tests build such prompts at
  run time.
