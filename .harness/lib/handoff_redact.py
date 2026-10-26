"""Live redaction filter for handoff steps (spec 4.3, FRG-14).

usage: <python3> -I handoff_redact.py <log | -> 3<secrets
       (the runtime runs this file's checked text with -c, so argv is then ['-c', <log>])

The runtime pipes a step's terminal output (from script(1)) into this filter. It copies the output
to its own stdout (the owner's screen) and to <log> ("-": no log, for the runtime's own step
banners), replacing every known secret with [REDACTED] before either sees it. The secrets arrive
one per line on file descriptor 3, never on the command line or in the environment, followed by
the line "#END" ("#" is never in a secret). Without that line the list may be cut short, so the
filter shows nothing and exits 2.

Masking: every byte that any occurrence of any secret covers is masked, judged on the original
bytes, so secrets that contain or overlap one another are hidden whole. A run of masked bytes
becomes one [REDACTED], even across reads.

Holding back: only the longest end of the output so far that could still become a secret (a
proper prefix of one), at most one secret's length minus one. Everything else is shown at once.
A held piece is shown as soon as more output proves it isn't a secret, or when the step ends.
Bytes already known to be inside a secret stay masked when the piece is finally shown. Nothing is
flushed on a timer, since that could show part of a secret.

It ignores SIGINT, so a Ctrl-C meant for the step can't stop it mid-output. If it is killed, the
held piece is dropped, never shown. Its own messages are fixed text, with no path, system message
or traceback, since they reach the screen unmasked. Exit status: 0 when everything was shown and logged; 2 for a
usage error or a log it can't create (it never writes through a symlink or onto an existing file);
3 when writing failed partway (the screen went away, or the log could not be written).
"""

import os
import signal
import sys

MASK = b"[REDACTED]"
END = b"#END"


def read_secrets():
    """The secrets, longest first; None if the list didn't end with END (cut short)."""
    with os.fdopen(3, "rb") as f:
        lines = f.read().split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()
    if not lines or lines[-1] != END:
        return None
    found = {s for s in lines[:-1] if s}
    return sorted(found, key=len, reverse=True)


def covered(buf, secrets, lead):
    """One flag per byte of buf: inside some occurrence of a secret, or among the first `lead`
    bytes (already known to be inside one that began in output shown earlier)."""
    cov = bytearray(len(buf))
    cov[:lead] = b"\x01" * min(lead, len(buf))
    for s in secrets:
        i = buf.find(s)
        while i != -1:
            cov[i:i + len(s)] = b"\x01" * len(s)
            i = buf.find(s, i + 1)
    return cov


def hold_start(buf, secrets, longest):
    """Start of the longest suffix of buf that is a proper prefix of some secret."""
    for k in range(min(longest - 1, len(buf)), 0, -1):
        tail = buf[-k:]
        if any(len(s) > k and s.startswith(tail) for s in secrets):
            return len(buf) - k
    return len(buf)


def masked(seg, cov, in_mask):
    """seg with each run of covered bytes replaced by one MASK. in_mask says the output shown
    just before seg ended inside a mask, so a run at the start of seg continues it."""
    out = bytearray()
    for i, byte in enumerate(seg):
        if cov[i]:
            if not in_mask:
                out += MASK
                in_mask = True
        else:
            out.append(byte)
            in_mask = False
    return bytes(out), in_mask


def write_all(fd, data):
    while data:
        data = data[os.write(fd, data):]


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: handoff_redact.py <log | -> 3<secrets\n")
        return 2
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    try:
        secrets = read_secrets()
    except OSError:
        sys.stderr.write("handoff_redact: cannot read the secrets\n")
        return 2
    if secrets is None:
        sys.stderr.write("handoff_redact: the list of secrets was cut short; showing nothing\n")
        return 2
    log = None
    if sys.argv[1] != "-":
        try:
            log = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        except OSError:
            # Fixed text only (no path, no system message): this reaches the screen unmasked, and
            # the runtime names the step.
            sys.stderr.write("handoff_redact: cannot create the log\n")
            return 2
    log_ok = True

    def show(out):
        nonlocal log_ok
        if not out:
            return
        write_all(1, out)
        if log is not None and log_ok:
            try:
                write_all(log, out)
            except OSError:
                log_ok = False

    longest = max((len(s) for s in secrets), default=0)
    held, lead, in_mask = b"", 0, False
    while True:
        data = os.read(0, 4096)
        if not data:
            break
        if not secrets:
            show(data)
            continue
        buf = held + data
        cov = covered(buf, secrets, lead)
        p = hold_start(buf, secrets, longest)
        if p:
            out, in_mask = masked(buf[:p], cov, in_mask)
            show(out)
        held = buf[p:]
        lead = 0
        while lead < len(held) and cov[p + lead]:
            lead += 1
    if held:
        out, _ = masked(held, covered(held, secrets, lead), in_mask)
        show(out)
    if log is not None:
        os.close(log)
    return 0 if log_ok else 3


if __name__ == "__main__":
    try:
        sys.exit(main())
    except OSError:  # the screen went away mid-output
        sys.exit(3)
    except Exception:  # anything else: fixed text, never a traceback or a system message
        sys.stderr.write("handoff_redact: failed\n")
        sys.exit(3)
