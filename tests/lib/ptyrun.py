"""Run a command inside a pseudo-terminal, answering prompts in order (spec 10.2).

Usage: python3 -I ptyrun.py [--answer TEXT]... -- COMMAND [ARGS...]

Each answer is typed when the next "[y/N] " or "(input hidden): " prompt appears.
Prints everything the command wrote to the terminal and exits with the command's status.

Cleanup: every descendant seen in a process snapshot (taken every POLL seconds) is killed when
the run ends, if it is still the same process (pid and start time). Known limit (FRG-15): a
process that double-forks, detaches and loses its parent between two snapshots is never seen,
and macOS offers no unprivileged way to contain it. The handoff tests start no such daemons.
"""

import os
import pty
import re
import select
import signal
import subprocess
import sys
import time

PROMPT = re.compile(rb"\[y/N\] |\(input hidden\): ")
IDLE_TIMEOUT = int(os.environ.get("PTYRUN_TIMEOUT", "15"))


def process_table():
    """{pid: (ppid, start time)} from ps; the start time tells a reused pid apart."""
    out = subprocess.run(["/bin/ps", "-A", "-o", "pid=,ppid=,lstart="],
                         capture_output=True, text=True).stdout
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


def kill_all(pid, tracked):
    """Kill every descendant ever seen (a detached one may have outlived its parent and been
    re-parented, so it can no longer be found from pid), the current ones, then the child's
    process group. script(1) starts its own session, so the group alone is not enough."""
    alive = process_table()
    for p, start in tracked | descendants(pid):
        if p in alive and alive[p][1] == start:  # still the same process, not a reused pid
            try:
                os.kill(p, signal.SIGKILL)
            except ProcessLookupError:
                pass
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
        seen = len(PROMPT.findall(out))
        while sent < seen and sent < len(answers):
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
            break
        if time.monotonic() >= deadline:
            kill_all(pid, tracked)
            out += b"\n[ptyrun: killed after %d s without exiting]\n" % IDLE_TIMEOUT
            _, status = os.waitpid(pid, 0)
            break
        time.sleep(0.05)
    # Nothing a test started may outlive it, even after a normal exit.
    kill_all(pid, tracked)
    sys.stdout.write(out.decode("utf-8", "replace"))
    return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    sys.exit(main())
