"""Run a command inside a pseudo-terminal, answering prompts in order (spec 10.2).

Usage: python3 -I ptyrun.py [--answer TEXT]... -- COMMAND [ARGS...]

Each answer is typed when the next "[y/N] " or "(input hidden): " prompt appears; for a hidden
one, only once the terminal's echo is off (bash's `read -s -p` prints its prompt first), or after
IDLE_TIMEOUT seconds, so a run that never hides the answer shows it.
Prints everything the command wrote to the terminal and exits with the command's status.

Cleanup: every descendant seen in a process snapshot (taken repeatedly while the command runs,
before each wait of up to POLL seconds for output and while waiting for it to exit) is killed when
the run ends, if it still looks like the same process (pid and start time). Known limits,
accepted in docs/decisions/2026-10-25-pty-driver-cleanup-limit.md (stronger isolation: FRG-28):
a process that detaches itself (forks, setsid, loses its parent) between two snapshots, whether
to evade cleanup or as ordinary daemon start-up, can be missed and outlive the run, with its
children and the permissions of the user running the tests; and the identity check is
best-effort (ps start times have one-second precision, and a pid can be reused between the
snapshot and the kill). This driver is not a security sandbox: it tidies up after FORGE's own
reviewed tests, none of which starts a process meant to outlive the test.
"""

import os
import pty
import re
import select
import signal
import subprocess
import sys
import termios
import time

PROMPT = re.compile(rb"\[y/N\] |\(input hidden\): ")
HIDDEN = b"(input hidden): "
IDLE_TIMEOUT = int(os.environ.get("PTYRUN_TIMEOUT", "15"))


class SnapshotError(Exception):
    """ps failed: without a process table, cleanup can't be trusted, so the run fails."""


def process_table():
    """{pid: (ppid, start time)} from ps; the start time tells a reused pid apart."""
    res = subprocess.run(["/bin/ps", "-A", "-o", "pid=,ppid=,lstart="],
                         capture_output=True, text=True)
    if res.returncode != 0 or not res.stdout.strip():
        raise SnapshotError("ps failed (status %d): %s" % (res.returncode, res.stderr.strip()))
    out = res.stdout
    table = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3:
            table[int(parts[0])] = (int(parts[1]), parts[2].strip())
    return table


def descendants(root):
    """{(pid, start time)} of every process below root, found by parent pid, so separate
    sessions are included."""
    table = process_table()
    children = {}
    for p, (pp, _) in table.items():
        children.setdefault(pp, []).append(p)
    found, todo = set(), [root]
    while todo:
        for c in children.get(todo.pop(), []):
            found.add((c, table[c][1]))
            todo.append(c)
    return found


POLL = 0.1  # how often descendants are recorded while the child runs


def wait_for_echo_off(fd):
    """Wait until the terminal no longer echoes, for at most IDLE_TIMEOUT seconds."""
    deadline = time.monotonic() + IDLE_TIMEOUT
    while time.monotonic() < deadline:
        try:
            if not termios.tcgetattr(fd)[3] & termios.ECHO:
                return
        except termios.error:
            return
        time.sleep(0.01)


def kill_tracked(tracked):
    """Kill each recorded (pid, start time) that is still that same process (never a reused pid).
    A detached descendant may have been re-parented, so it can no longer be found from the child."""
    alive = process_table()
    for p, start in tracked:
        if p in alive and alive[p][1] == start:
            try:
                os.kill(p, signal.SIGKILL)
            except ProcessLookupError:
                pass


def kill_all(pid, tracked):
    """For a child that has NOT been reaped yet (so its pid and group can't have been reused):
    kill every descendant seen or current, then the child's process group. script(1) starts its
    own session, so the group alone is not enough."""
    kill_tracked(tracked | descendants(pid))
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def main() -> int:
    args = sys.argv[1:]
    answers = []
    while len(args) >= 2 and args[0] == "--answer":
        answers.append(args[1])
        args = args[2:]
    if args and args[0] == "--":
        args = args[1:]
    if not args:
        print("usage: ptyrun.py [--answer TEXT]... -- COMMAND [ARGS...]", file=sys.stderr)
        return 2

    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(args[0], args)
    CHILD.append(pid)

    out = b""
    sent = 0
    tracked = set()
    idle = 0.0
    while True:
        tracked.update(descendants(pid))
        ready, _, _ = select.select([fd], [], [], POLL)
        if not ready:
            idle += POLL
            if idle >= IDLE_TIMEOUT:
                kill_all(pid, tracked)
                out += b"\n[ptyrun: killed after %d s without output]\n" % IDLE_TIMEOUT
                break
            continue
        idle = 0.0
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
        out += data
        prompts = PROMPT.findall(out)
        while sent < len(prompts) and sent < len(answers):
            if prompts[sent] == HIDDEN:
                wait_for_echo_off(fd)
            os.write(fd, answers[sent].encode() + b"\n")
            sent += 1

    os.close(fd)
    # The terminal may close before the child exits (it can close its own descriptors and
    # hang), so waiting is bounded by the same timeout.
    deadline = time.monotonic() + IDLE_TIMEOUT
    while True:
        tracked.update(descendants(pid))
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            CHILD.clear()  # reaped: its pid and group may be reused from now on
            break
        if time.monotonic() >= deadline:
            kill_all(pid, tracked)
            out += b"\n[ptyrun: killed after %d s without exiting]\n" % IDLE_TIMEOUT
            _, status = os.waitpid(pid, 0)
            CHILD.clear()
            break
        time.sleep(0.05)
    # Nothing a test started may outlive it, even after a normal exit. The child is reaped now, so
    # its pid and group may already belong to someone else: only identity-checked kills here.
    kill_tracked(tracked)
    sys.stdout.write(out.decode("utf-8", "replace"))
    return os.waitstatus_to_exitcode(status)


def run() -> int:
    try:
        return main()
    except SnapshotError as e:
        # Only a child that is still unreaped (listed in CHILD) may have its group signalled.
        if CHILD:
            try:
                os.killpg(CHILD[0], signal.SIGKILL)
                os.waitpid(CHILD[0], 0)
            except OSError:  # already gone, or a finished leader (macOS: EPERM)
                pass
        print("ptyrun: %s; process cleanup is unreliable, failing the run" % e, file=sys.stderr)
        return 125


CHILD = []  # the forked child's pid, for run()'s error path


if __name__ == "__main__":
    sys.exit(run())
