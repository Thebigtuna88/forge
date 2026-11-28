"""request-scan.py <script>: how github-throwaway.sh makes its GitHub requests (round 75, C1).

Prints one line per problem, nothing if there is none:
  raw <line>     gh, git or curl run other than through an identity's runner
  held <line>    a request (or a function that makes one) inside a command substitution or a
                 pipeline, where bash holds a stop until it ends; a2-probe's own functions aside
  sleep <line>   a sleep in the foreground (bash holds a stop until it ends), other than nap's
Then "functions: <names>", the functions found to make requests.
"""
import re
import sys

RUNNERS = {"owner_gh_run": "gh", "app_gh_run": "gh", "app_git_run": "git", "app_curl": "curl", "app_api_curl_run": "curl"}
SEEDS = {"owner_gh", "app_gh", "app_git", "app_curl", "app_api_curl"}


def joined(lines):
    """(first line number, text) for each logical line: continuation lines joined."""
    out, buf, first = [], "", None
    for i, l in enumerate(lines, 1):
        if first is None:
            first = i
        if l.endswith("\\"):
            buf += l[:-1] + " "
            continue
        out.append((first, buf + l))
        buf, first = "", None
    return out


def code(l):
    """The line without a comment (a # at the start of a word, outside quotes) and without a case
    arm's pattern (names there are matched, not run; their | is no pipeline)."""
    l = re.sub(r"^\s*[A-Za-z0-9_*|\" .?-]+\)\s", " ", l)
    q, i = None, 0
    while i < len(l):
        c = l[i]
        if q:
            if c == "\\" and q == '"':
                i += 2
                continue
            if c == q:
                q = None
        elif c in "'\"":
            q = c
        elif c == "#" and (i == 0 or l[i - 1] in " \t;"):
            return l[:i]
        i += 1
    return l


def unquoted(l):
    """The line with every quoted string replaced by a placeholder (keeps $( ) out of view too)."""
    out, q, i = [], None, 0
    while i < len(l):
        c = l[i]
        if q:
            if c == "\\" and q == '"':
                i += 2
                continue
            if c == q:
                q = None
                out.append("Q")
        elif c in "'\"":
            q = c
        else:
            out.append(c)
        i += 1
    return "".join(out)


def comsubs(l):
    """The text of each $( ) on the line (not $(( )) ), parentheses in single quotes ignored."""
    found, i = [], 0
    while True:
        j = l.find("$(", i)
        if j < 0:
            return found
        if l.startswith("$((", j):
            i = j + 3
            continue
        d, k, q = 0, j + 1, None
        while k < len(l):
            c = l[k]
            if q:
                if c == q:
                    q = None
            elif c == "'":
                q = c
            elif c == "(":
                d += 1
            elif c == ")":
                d -= 1
                if d == 0:
                    break
            k += 1
        found.append(l[j + 2:k])
        i = j + 2


def names_in(text, names):
    return [n for n in names if re.search(r"(^|[^A-Za-z0-9_-])" + re.escape(n) + r"([^A-Za-z0-9_-]|$)", text)]


def main():
    lines = open(sys.argv[1]).read().split("\n")
    logical = joined(lines)
    funcs, owner, cur = {}, {}, None
    for n, l in logical:
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\(\) ?\{(.*)$", l)
        if m:
            cur = m.group(1)
            funcs[cur] = []
            rest = code(m.group(2)).strip()
            if rest.endswith("}"):
                funcs[cur].append((n, rest))
                owner[n] = cur
                cur = None
            continue
        if cur:
            if l == "}":
                cur = None
                continue
            funcs[cur].append((n, code(l)))
            owner[n] = cur
    req = set(SEEDS)
    changed = True
    while changed:
        changed = False
        for f, body in funcs.items():
            if f in req or f == "main":
                continue
            if any(names_in(c, req) for _, c in body):
                req.add(f)
                changed = True
    probe = lambda f: bool(f) and (f.startswith("probe_") or f == "cmd_a2_probe")
    problems = []
    for n, l in logical:
        c = code(l)
        if not c.strip():
            continue
        f = owner.get(n)
        # gh, git or curl as a command: only in its runner (and need_tools' version check). The
        # command substitutions too: a quoted one is out of view in the unquoted line. Round 115: by an
        # absolute path too (/usr/bin/curl).
        u = unquoted(c)
        views = [u] + [unquoted(s) for s in comsubs(c)]
        for tool in ("gh", "git", "curl"):
            if any(re.search(r"(^|[\s;|&({/])" + tool + r"(\s|$)", v) for v in views) and RUNNERS.get(f) != tool:
                if f == "need_tools" and (tool == "git" and "git --version" in c or c.strip().startswith("for t in")):
                    continue
                problems.append(f"raw {n}: {l.strip()[:140]}")
        if f in RUNNERS:
            continue
        if not probe(f):
            held = [x for s in comsubs(c) for x in names_in(s, req)]
            segs = re.split(r"(?<!\|)\|(?!\|)", u)
            if len(segs) > 1:
                held += [x for s in segs[:-1] for x in names_in(s, req)]
            if held:
                problems.append(f"held {n}: [{f}] {','.join(sorted(set(held)))}: {l.strip()[:140]}")
        if f != "nap" and any(re.search(r"(^|[\s;|&({])sleep\s", v) for v in views):
            problems.append(f"sleep {n}: [{f}] {l.strip()[:140]}")
    for p in problems:
        print(p)
    print("functions:", " ".join(sorted(req)))


main()
