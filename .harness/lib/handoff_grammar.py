"""Allowlist grammar for OWNER-RUN.sh scripts (spec 4.4). Used by `handoff lint`.

usage: python3 -I handoff_grammar.py <OWNER-RUN.sh> <runtime path> <id>
Prints one error per line ("line N: ..."); prints nothing when the script conforms.

A conforming script is, apart from blank lines and whole-line comments, exactly:
    #!/usr/bin/env bash
    set -uo pipefail
    source "<runtime path>"
    ho_begin "<id>"
    <step lines>
    ho_end
where every step line is one helper call made of plain words and quoted strings:
    ho_check|ho_info <name> <command word>... [|| ho_abort]
    ho_confirm <name> "<question>" [|| ho_abort]
    ho_secret_to_file <name> <VAR> </absolute/path> [|| ho_abort]
    ho_redact_file <name> </absolute/path> [|| ho_abort]
No step may name a file that a ho_secret_to_file or ho_redact_file step names (the secret file).
No expansions ($, backticks), no operators other than a final "|| ho_abort", no redirection,
no globbing, no function definitions. Words are checked after quote removal, so splitting a
forbidden name across quotes ('RESULT''.''txt') does not hide it.
"""

import re
import sys

HELPERS = ("ho_check", "ho_info", "ho_confirm", "ho_secret_to_file", "ho_redact_file")
NAME = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
VAR = re.compile(r"^[A-Z_][A-Z0-9_]*$")
UNQUOTED_OK = re.compile(r"[A-Za-z0-9_@%+=:,./^-]")  # no ~: bash would expand it
FORBIDDEN = (
    "HANDOFF-RESULT", "result: OK", "result: FAILED", "script-sha256", "runtime-sha256",
    "RESULT.txt", "VERIFIED.txt", "META.json", "PASTED-", "CLAUDECODE",
    "CLAUDE_CODE_ENTRYPOINT", "CODEX_SANDBOX", "pbcopy",
)


class Bad(Exception):
    pass


def split_words(line):
    """Split a step line into (text, quoted) words; '||' comes back as ('||', None)."""
    words, cur, quoted, i, n = [], None, False, 0, len(line)

    def end():
        nonlocal cur, quoted
        if cur is not None:
            words.append((cur, quoted))
        cur, quoted = None, False

    while i < n:
        c = line[i]
        if c in " \t":
            end()
            i += 1
        elif c == "'":
            j = line.find("'", i + 1)
            if j < 0:
                raise Bad("unterminated single quote")
            cur = (cur or "") + line[i + 1:j]
            quoted = True
            i = j + 1
        elif c == '"':
            j = line.find('"', i + 1)
            if j < 0:
                raise Bad("unterminated double quote")
            inner = line[i + 1:j]
            for bad in ("$", "`", "\\", "!"):
                if bad in inner:
                    raise Bad("%r inside double quotes (use single quotes)" % bad)
            cur = (cur or "") + inner
            quoted = True
            i = j + 1
        elif c == "|" and line[i:i + 2] == "||" and cur is None:
            words.append(("||", None))
            i += 2
        elif UNQUOTED_OK.match(c):
            cur = (cur or "") + c
            i += 1
        else:
            raise Bad("unquoted %r is not allowed (no expansions, operators, redirection or globs)" % c)
    end()
    return words


def check_step(words, secret_files):
    """Validate one step; return (name, helper)."""
    if len(words) >= 2 and words[-2] == ("||", None):
        if words[-1] != ("ho_abort", False):
            raise Bad("'||' may only be followed by ho_abort")
        words = words[:-2]
    if any(q is None for _, q in words):
        raise Bad("'||' may only appear once, before a final ho_abort")
    if not words or words[0][1] or words[0][0] not in HELPERS:
        raise Bad("only ho_check, ho_info, ho_confirm, ho_secret_to_file and ho_redact_file steps are allowed here")
    helper = words[0][0]
    args = words[1:]
    if not args or args[0][1] or not NAME.match(args[0][0]):
        raise Bad("%s needs a step name of lowercase letters, digits and hyphens" % helper)
    name = args[0][0]
    rest = args[1:]
    if helper in ("ho_check", "ho_info"):
        if not rest:
            raise Bad("%s %s: no command given" % (helper, name))
        for text, _ in rest:
            for f in secret_files:
                base = f.rsplit("/", 1)[-1]
                if f in text or text == base or text.endswith("/" + base):
                    raise Bad("step %s reads the secret file %s" % (name, f))
    elif helper == "ho_confirm":
        if len(rest) != 1 or not rest[0][1]:
            raise Bad("ho_confirm %s takes exactly one quoted question" % name)
    elif helper == "ho_redact_file":
        if len(rest) != 1 or not rest[0][0].startswith("/"):
            raise Bad("ho_redact_file %s takes </absolute/path>" % name)
    else:
        if len(rest) != 2 or not VAR.match(rest[0][0]) or not rest[1][0].startswith("/"):
            raise Bad("ho_secret_to_file %s takes <VAR> </absolute/path>" % name)
    for text, _ in words:
        for lit in FORBIDDEN:
            if lit in text:
                raise Bad("forbidden text (fakes or bypasses evidence): %s" % lit)
    return name, helper


def main(path, runtime, ident):
    errors = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    header = ["set -uo pipefail", 'source "%s"' % runtime, 'ho_begin "%s"' % ident]
    stage = 0  # 0..2 = expecting header[stage]; 3 = steps; 4 = after ho_end
    # First pass: every secret target, so no step before or after it may name the file.
    secret_files = []
    for raw in lines:
        try:
            w = split_words(raw)
        except Bad:
            continue
        if len(w) >= 4 and w[0] == ("ho_secret_to_file", False):
            secret_files.append(w[3][0])
        elif len(w) >= 3 and w[0] == ("ho_redact_file", False):
            secret_files.append(w[2][0])
    for no, raw in enumerate(lines, 1):
        line = raw.strip()
        if no == 1:
            if raw != "#!/usr/bin/env bash":
                errors.append("line 1: must be '#!/usr/bin/env bash'")
            continue
        if not line or line.startswith("#"):
            continue
        if stage == 4:
            errors.append("line %d: nothing may follow ho_end" % no)
            continue
        if stage < 3:
            if raw != header[stage]:
                errors.append("line %d: expected exactly: %s" % (no, header[stage]))
                if line != "ho_end":
                    continue
            else:
                stage += 1
                continue
        if raw == "ho_end":
            stage = 4
            continue
        try:
            check_step(split_words(raw), secret_files)
        except Bad as e:
            errors.append("line %d: %s: %s" % (no, e, raw.strip()[:120]))
    if stage != 4:
        errors.append("the script must end with a line containing exactly: ho_end")
    for e in errors:
        print(e)


def redact_files(path):
    """Print the path of every ho_redact_file step, after quote removal, one per line."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh.read().split("\n"):
            try:
                w = split_words(raw)
            except Bad:
                continue
            if len(w) >= 3 and w[0] == ("ho_redact_file", False):
                print(w[2][0])


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--redact-files":
        redact_files(sys.argv[2])
        sys.exit(0)
    if len(sys.argv) != 4:
        print("usage: handoff_grammar.py <OWNER-RUN.sh> <runtime> <id> | --redact-files <OWNER-RUN.sh>")
        sys.exit(2)
    main(*sys.argv[1:])
