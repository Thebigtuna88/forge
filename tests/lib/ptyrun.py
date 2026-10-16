"""Run a command inside a pseudo-terminal, answering prompts in order (spec 10.2).

Usage: python3 -I ptyrun.py [--answer TEXT]... -- COMMAND [ARGS...]

Each answer is typed when the next "[y/N] " or "(input hidden): " prompt appears.
Prints everything the command wrote to the terminal and exits with the command's status.
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


def descendants(root):
    """Every process below root, found by parent pid (ps), so separate sessions are included."""
    out = subprocess.run(["/bin/ps", "-A", "-o", "pid=,ppid="], capture_output=True, text=True).stdout
    children = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2:
            children.setdefault(int(parts[1]), []).append(int(parts[0]))
    found, todo = [], [root]
    while todo:
        for c in children.get(todo.pop(), []):
            found.append(c)
            todo.append(c)
    return found


def kill_tree(pid):
    """Kill every descendant first (script(1) starts its own session, so the child's process
    group is not enough), then the child's group."""
    for p in descendants(pid):
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
    while True:
        ready, _, _ = select.select([fd], [], [], IDLE_TIMEOUT)
        if not ready:
            kill_tree(pid)
            out += b"\n[ptyrun: killed after %d s without output]\n" % IDLE_TIMEOUT
            break
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
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            break
        if time.monotonic() >= deadline:
            kill_tree(pid)
            out += b"\n[ptyrun: killed after %d s without exiting]\n" % IDLE_TIMEOUT
            _, status = os.waitpid(pid, 0)
            break
        time.sleep(0.05)
    sys.stdout.write(out.decode("utf-8", "replace"))
    return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    sys.exit(main())
