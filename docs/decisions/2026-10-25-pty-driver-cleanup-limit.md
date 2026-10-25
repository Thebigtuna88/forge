# Decision: the test pty driver can't guarantee cleanup of deliberately detached processes

- **Date:** 2026-10-25
- **Decided by:** owner (Thebigtuna88), after FRG-15's macOS experiment
- **Status:** accepted as a known limit; closes FRG-15 (#15) when merged
- **Follow-up:** FRG-28 (#28), stronger process isolation, not before FRG-26's checkpoint

## The limit, narrowly

`tests/lib/ptyrun.py` runs handoff tests in a pseudo-terminal. When a run ends, it kills every
descendant it saw in its process snapshots, taken every 0.1 s. **With the unprivileged approaches
tested, it can't guarantee cleanup of a descendant that deliberately detaches.** For example, a
process that forks, calls `setsid()` and lets its parent exit between two snapshots. That process
is re-parented to launchd, nothing links it to the run any more, and it keeps running after the
test.

This is about deliberate detaching. Background children that stay attached, children in their own
session, and orphans whose parent outlives a snapshot are cleaned up (`tests/unit/ptyrun.test.sh`).

## What this does and doesn't mean

- **A surviving process keeps the permissions of the user who ran the tests.** Today that's the
  owner's macOS user. It can do whatever that user can, for as long as it runs.
- **ptyrun.py is not a security sandbox.** It doesn't contain, limit or isolate what a test runs.
  It's a convenience that tidies up after FORGE's own reviewed tests. Today none of them starts a
  process meant to outlive the test.
- Nothing about this limit is promised away. Code run by the tests has to be trusted, as code run
  by the tests already had to be.

## Evidence (macOS 27.0.1, kernel 27.0.0; dev at fc06947)

The scripts and their output are in `work/FRG-15-pty-containment/` on the owner's Mac
(`findings.md`, `experiment/`). `work/` is gitignored.

| # | Approach tested | Result |
|---|---|---|
| 1 | kqueue `EVFILT_PROC` with `NOTE_TRACK` (follow forks) | Refused: errno 45, "Operation not supported" (`kq_track.py`) |
| 2 | kqueue `NOTE_FORK` alone | Fires on a fork but reports no child pid (data 0), so it can't follow the child (`kq_track.py`) |
| 3 | The gap itself: fork, `setsid()`, start `sleep`, middle process exits | Outlived the driver in **20 of 20** runs, parent 1 (launchd) (`escaper.py`, `escape_demo.sh`) |
| 4 | Tag the run with an environment variable and find processes carrying it | macOS doesn't show a process's environment, even to its own user: `ps -E` and `sysctl KERN_PROCARGS2` return the command line only. Found in 0 of 20 (`env_visible.sh`) |
| 5 | The cleanup recipe below | Listed the escaped process; a plain `kill` ended it (`cleanup_recipe.sh`) |

Also ruled out: killing "every new process whose parent is launchd". It would hit the owner's
unrelated apps and services.

Not tested, because each needs a Mac account change or administrator rights, and FRG-26's
restrictions forbid those before its checkpoint: a dedicated macOS user for test runs (kill
everything it owns). That's FRG-28.

The pid identity check before each kill also stays best-effort: `ps` start times have one-second
precision, and a pid can be reused between the snapshot and the kill. macOS has no pidfd. This was
already recorded on FRG-15 and in `ptyrun.py`.

## Cleanup: finding and stopping a survivor

Run the tests between two snapshots of your processes whose parent is launchd, and compare:

```bash
d="$(mktemp -d)"
ps -U "$USER" -o pid=,ppid=,lstart=,command= | awk '$2 == 1' | sort >"$d/before.txt"
bash tests/run.sh
ps -U "$USER" -o pid=,ppid=,lstart=,command= | awk '$2 == 1' | sort >"$d/after.txt"
comm -13 "$d/before.txt" "$d/after.txt"
```

Each line printed is a process that launchd adopted during the run: pid, parent, start time,
command. Some may be apps you opened meanwhile. For each one you recognise as coming from the
tests:

1. `kill <pid>`, then check with `ps -p <pid>`;
2. if it's still there after a few seconds, `kill -9 <pid>`.

If you're unsure what a process is, don't kill it. Logging out of macOS or restarting ends every
process of your user, survivors included.

## When we must revisit this

- **Before running untrusted test code** through the driver: any test, fixture or tool not written
  in FORGE and reviewed. FRG-28 (stronger isolation) must be done first.
- **Before adding a test that deliberately starts a background process.** Do FRG-28 first, or the
  test must stop its process itself and prove it in the same test.
- **If a survivor is ever found** after a run (the recipe above prints anything).
- **When someone else runs the tests:** another macOS user (for example FRG-26's `forge-agent`,
  which will hold the helper's GitHub token), or CI. A survivor would hold that user's access.
- **After a macOS major update:** rerun `kq_track.py`. If `NOTE_TRACK` works again, the driver
  can follow forks.
- **After FRG-26's checkpoint:** FRG-28 evaluates a dedicated test user, shown to the owner first
  with its effects and undo.

## Alternatives not taken

- Keep FRG-15 open with no fix available: it would stay open indefinitely and hide the decision.
- Create a dedicated test user now: a Mac account change before FRG-26's checkpoint, which the
  owner ruled out.
