# Decision: the test pty driver can't guarantee cleanup of detached descendants

- **Date:** 2026-10-25
- **Decided by:** owner (Thebigtuna88), after FRG-15's macOS experiment
- **Status:** accepted as a known limit; closes FRG-15 (#15) when merged
- **Follow-up:** FRG-28 (#28), stronger process isolation, not before FRG-26's checkpoint

## The limit, narrowly

`tests/lib/ptyrun.py` runs handoff tests in a pseudo-terminal. When a run ends, it kills every
descendant it saw in the process snapshots it takes repeatedly while the test runs. They come
roughly a tenth of a second apart, not on a fixed schedule. **With the unprivileged approaches
tested, it can't guarantee cleanup of a descendant that detaches itself between two snapshots:**
it forks, calls `setsid()`, and its parent exits. That process is re-parented to launchd, and
nothing links it to the run any more. If it's still running when the test ends, it isn't killed:
it keeps running, along with any children it starts.

What matters is that behaviour, not intent. A program trying to evade cleanup does it, and so
does ordinary daemon start-up by a well-meaning tool.

What is cleaned up (`tests/unit/ptyrun.test.sh`):
- background children that stay attached;
- children in their own session;
- orphans whose parent was still alive at a snapshot.

## What this does and doesn't mean

- **A surviving process keeps the permissions of the user who ran the tests.** Today that's the
  owner's macOS user. A survivor can do whatever that user can, for as long as it runs, including
  using credentials or access that user gains later.
- **ptyrun.py is not a security sandbox.** It doesn't contain, limit or isolate what a test runs.
  It tidies up after FORGE's own reviewed tests. Today none of them starts a process meant to
  outlive the test.
- Code run by the tests has to be trusted, as it already had to be.
- This is an accepted risk. Before any 5:00 credential, it goes on the list of remaining accepted
  risks the owner reviews (FRG-26 plan, decision D3).

## Evidence (macOS 27.0.1, kernel 27.0.0; dev at fc06947)

The scripts and their output are in `work/FRG-15-pty-containment/` on the owner's Mac
(`findings.md`, `experiment/`). `work/` is gitignored.

| # | Approach tested | Result |
|---|---|---|
| 1 | kqueue `EVFILT_PROC` with `NOTE_TRACK` (follow forks) | Refused: errno 45, "Operation not supported" (`kq_track.py`) |
| 2 | kqueue `NOTE_FORK` alone | Fires on a fork but reports no child pid (data 0), so it can't follow the child (`kq_track.py`) |
| 3 | The gap itself: fork, `setsid()`, start `sleep`, middle process exits | Outlived the driver in **20 of 20** runs, parent 1 (launchd) (`escaper.py`, `escape_demo.sh`) |
| 4 | Tag the run with an environment variable and find processes carrying it | On this Mac, `ps -E` and `sysctl KERN_PROCARGS2` returned only the command line of a `/bin/sleep` started by the same user, not its environment (`env_visible.sh`). `ps -E` found the marker in 0 of the 20 escaped processes (`escape_demo.sh`) |
| 5 | The cleanup steps below | Listed an escaped `sleep`, and separately an escaped `bash` together with its own `sleep` child. The kill steps (identity recheck before each signal, children first) ended all of them, including with survivors that ignore SIGTERM, where the `kill -9` step ran (`cleanup_recipe.sh`, with and without `tree` and `SURVIVOR_IGNORES_TERM=1`) |

Also ruled out: killing "every new process whose parent is launchd". It would hit the owner's
unrelated apps and services, and it would miss a survivor's children.

Not tested: a dedicated macOS user for test runs (kill everything it owns). It needs a Mac account
change and administrator rights, which FRG-26's restrictions forbid before its checkpoint. That's
FRG-28.

The pid identity check before each of the driver's kills also stays best-effort. `ps` start times
have one-second precision, a pid can be reused between the snapshot and the kill, and macOS has no
pidfd. This was already recorded on FRG-15 and in `ptyrun.py`.

## Cleanup: finding and stopping survivors

Snapshot every process of your user, by pid and start time, before and after the run. Then list
the ones that are new and still the same process:

```bash
d="$(mktemp -d)"
ps -U "$USER" -o pid=,lstart= | sort >"$d/before.txt"
bash tests/run.sh
ps -U "$USER" -o pid=,lstart= | sort >"$d/after.txt"
comm -13 "$d/before.txt" "$d/after.txt" | while read -r p start; do
  row="$(ps -o pid=,ppid=,user=,lstart=,command= -p "$p")"
  [ "$(echo "$row" | awk '{print $4, $5, $6, $7, $8}')" = \
    "$(echo "$start" | awk '{print $1, $2, $3, $4, $5}')" ] && echo "$row"
done
```

Each line is a **candidate**: a process of yours that started during the run and is still
running. It shows pid, parent pid, user, start time and command. The loop reads each row once,
and prints it only if that row's start time is the one recorded in the second snapshot, so a pid
reused since then isn't shown. Start times have one-second precision, so a reuse within the same
second could still slip through; the user column shows if it's someone else's. A survivor's children are listed too:
their parent is the survivor, not launchd. Apps or tools you started meanwhile also appear, so
decide from the command and start time.

What it can't show:
- survivors of an **earlier** run, which are already in `before.txt`;
- a survivor that starts *after* the second snapshot.

An empty list is reassuring, not proof. For an earlier run, look at
`ps -U "$USER" -o pid=,ppid=,lstart=,command=` for processes that look like FORGE tests (temporary
folders, `sleep`, `script`, `bash`, `python3` running test files) and started around that run.

To stop one you recognise as coming from the tests, children first:
1. Check it's still the same process: `ps -o pid=,lstart=,command= -p <pid>` must show the start
   time and command you listed. If it doesn't, the pid now belongs to something else. Leave it.
2. `kill <pid>`.
3. After a few seconds, if it's still running, repeat step 1, and only if it still matches,
   `kill -9 <pid>`.

A small gap remains between the check and the signal, in which the process could exit and its pid
be reused. Checking right before each signal keeps that gap to a moment. If you're unsure what a
process is, don't kill it.

**Restarting the Mac** ends every process of your user, survivors included. Logging out ends the
processes of your login session, but not necessarily all of your user's, so don't rely on it alone.

## When we must revisit this

- **Before running untrusted test code** through the driver: any test, fixture or tool not written
  in FORGE and reviewed. FRG-28 (stronger isolation) must be done first.
- **Before adding a test that deliberately starts a background process.** FRG-28 must be done
  first.
- **Before the test user gains new credentials or access:** for example payment, business or
  production credentials, or a token with wider scopes. A survivor from an earlier run would gain
  them too. Run the cleanup steps first, and list this limit among FRG-26's remaining accepted
  risks (decision D3).
- **If a survivor is ever found** after a run.
- **When someone else runs the tests:** another macOS user (for example FRG-26's `forge-agent`,
  which will hold the helper's GitHub token), or CI. A survivor would hold that user's access.
- **After a macOS major update:** rerun `kq_track.py`. If `NOTE_TRACK` works again, the driver
  could follow forks.
- **After FRG-26's checkpoint:** FRG-28 evaluates a dedicated test user, shown to the owner first
  with its effects and undo.

## Alternatives not taken

- **Keep FRG-15 open with no fix available.** It would stay open indefinitely and hide the
  decision.
- **Create a dedicated test user now.** That's a Mac account change before FRG-26's checkpoint,
  which the owner ruled out.
