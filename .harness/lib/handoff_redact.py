"""Live redaction filter for handoff steps (spec 4.3, FRG-14).

usage: /usr/bin/python3 -I handoff_redact.py <log> 3<secrets

The runtime pipes a step's terminal output (from script(1)) into this filter. It copies the output
to its own stdout (the owner's screen) and to <log>, replacing every collected secret with
[REDACTED] before either sees it. The secrets arrive one per line on file descriptor 3, never on
the command line or in the environment.

What it holds back: only the end of the output received so far, and only while that end could
still become a secret (it is the start of one), together with any secret that overlaps it. All
other output is shown at once. A held piece is shown as soon as more output proves it isn't a
secret, or when the step ends. Nothing is ever flushed on a timer, since that could show part of a
secret. Secrets are replaced longest first, so one that contains another is replaced whole.

It ignores SIGINT, so a Ctrl-C meant for the step can't stop it mid-output. If it is killed, the
held piece is dropped, never shown. Exit status: 0 when everything was shown and logged; 2 for a
usage error or a log it can't create (it never writes through a symlink or onto an existing file);
3 when writing the log failed partway (the screen output stays redacted).
"""

import os
import signal
import sys

MASK = b"[REDACTED]"


def read_secrets():
    with os.fdopen(3, "rb") as f:
        found = {s for s in f.read().split(b"\n") if s}
    return sorted(found, key=len, reverse=True)


def hold_start(buf, secrets):
    """Where the held piece begins: the earliest suffix of buf that is a proper prefix of a
    secret, moved back over any whole secret that overlaps it."""
    p = len(buf)
    longest = max(len(s) for s in secrets)
    for k in range(min(longest - 1, len(buf)), 0, -1):
        tail = buf[-k:]
        if any(len(s) > k and s.startswith(tail) for s in secrets):
            p = len(buf) - k
            break
    moved = True
    while moved:
        moved = False
        for s in secrets:
            i = buf.find(s, max(0, p - len(s) + 1))
            while i != -1 and i < p:
                if i + len(s) > p:
                    p = i
                    moved = True
                    break
                i = buf.find(s, i + 1)
    return p


def redact(data, secrets):
    for s in secrets:
        data = data.replace(s, MASK)
    return data


def write_all(fd, data):
    while data:
        data = data[os.write(fd, data):]


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: handoff_redact.py <log> 3<secrets\n")
        return 2
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    try:
        secrets = read_secrets()
    except OSError as e:
        sys.stderr.write("handoff_redact: cannot read the secrets: %s\n" % e)
        return 2
    try:
        log = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except OSError as e:
        sys.stderr.write("handoff_redact: cannot create the log %s: %s\n" % (sys.argv[1], e))
        return 2
    log_ok = True

    def show(out):
        nonlocal log_ok
        if not out:
            return
        write_all(1, out)
        if log_ok:
            try:
                write_all(log, out)
            except OSError:
                log_ok = False

    held = b""
    while True:
        data = os.read(0, 4096)
        if not data:
            break
        buf = held + data
        p = hold_start(buf, secrets) if secrets else len(buf)
        show(redact(buf[:p], secrets))
        held = buf[p:]
    show(redact(held, secrets))
    os.close(log)
    return 0 if log_ok else 3


if __name__ == "__main__":
    try:
        sys.exit(main())
    except OSError:  # the screen went away mid-output
        sys.exit(3)
