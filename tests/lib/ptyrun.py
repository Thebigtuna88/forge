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
import sys

PROMPT = re.compile(rb"\[y/N\] |\(input hidden\): ")
IDLE_TIMEOUT = 15


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
            os.kill(pid, signal.SIGKILL)
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

    _, status = os.waitpid(pid, 0)
    sys.stdout.write(out.decode("utf-8", "replace"))
    return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    sys.exit(main())
