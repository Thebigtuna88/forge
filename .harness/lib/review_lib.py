# review_lib.py (FRG-7, spec 6): the review runner's checks that are easier to get exactly right
# in Python than in bash. Run with python3 -I (no user site, no environment, no current folder on
# the import path). Python 3.9 (Apple's /usr/bin/python3).
#   lenses <project type> <raw>
#       the lenses spec 6.2 requires for a frozen diff (review-diff.sh's raw), one per line:
#       code, security and spend on every PR, then frontend or ios by project. The runner and the
#       merge gate both call this, so they can't disagree, and both refuse a list without code,
#       security and spend.
#   check-reply <reply.json> <lens> <diff.patch> <evidence.txt or ->
#       prints one JSON object: status VALID or INVALID, reason, verdict, findings, hash.
#       Exit 0 if VALID, 3 if INVALID.
#   snapshot <git dir> <commit> <out folder>
#       writes the commit's files, and nothing else, into <out folder> (which must not exist), for
#       codex to review instead of the worktree (FRG-7 review round 4): no untracked or ignored
#       file, nothing git status can't see. Each blob is re-hashed against its object id, so a
#       planted object can't show codex other content. A symbolic link, a submodule, a path that
#       could leave the folder, or two paths that differ only in case (one file on macOS) is an
#       error. Git runs with no system or global settings.
#   instruction-files <folder> <codex home>
#       lists every file or folder that could hand codex instructions (spec 6.3, FRG-7 step 2):
#       AGENTS.md, AGENTS.override.md, .agents/ or .codex/ anywhere in the worktree; AGENTS.md,
#       AGENTS.override.md or .agents/ in any folder above it; AGENTS.md or AGENTS.override.md
#       in codex's home. Names are compared without case, as macOS's file system does. Exit 0 if
#       there are none, 1 if there are (one path per line) or if a folder can't be looked into.
import hashlib
import json
import os
import re
import subprocess
import sys

LENSES = ["code", "security", "frontend", "ios", "spend"]
# A finding id: the reply schema's pattern, and the one review-lens defer accepts.
ID_RE = r"^[A-Za-z0-9._-]{1,40}$"
SEVERITIES = ["blocker", "major", "minor", "nit"]
REPLY_KEYS = ["lens", "diff_md5", "diff_bytes", "evidence_md5", "evidence_bytes", "verdict", "findings"]
FINDING_KEYS = ["id", "severity", "file", "line", "title", "detail", "evidence"]

# --- required lenses (spec 6.2) --------------------------------------------------------------------

PROJECT_TYPES = ["harness", "web", "ios"]
# code, security and spend review every PR. Spend was once required only for a diff that looked
# like it touched paid APIs; three review rounds in a row found a provider or SDK that guess
# missed, so the owner made it required on every PR (decision 2026-10-29, FRG-7 review round 3).
EVERY_PR = ["code", "security", "spend"]
# frontend (web projects only): the UI paths of spec 6.2.
FRONTEND_PATHS = [
    re.compile(r"(^|/)(app|components|public)/"),
    re.compile(r"\.(tsx|jsx|css|scss)$", re.I),
    re.compile(r"(^|/)[^/]*tokens?[^/]*\.(json|ts|js|css)$", re.I),
]


def raw_paths(raw):
    # git diff --raw -z --no-renames: ":<mode> <mode> <oid> <oid> <status>\0<path>\0" per file.
    parts = raw.split(b"\0")
    paths, i = [], 0
    while i < len(parts) - 1:
        head = parts[i]
        if not head.startswith(b":"):
            raise ValueError("unexpected raw diff entry")
        paths.append(parts[i + 1].decode("utf-8", "surrogateescape"))
        i += 2
    return paths


def lenses(project, raw_file):
    if project not in PROJECT_TYPES:
        sys.exit("unknown project type: %s (%s)" % (project, ", ".join(PROJECT_TYPES)))
    paths = raw_paths(open(raw_file, "rb").read())
    need = list(EVERY_PR)
    if project == "web" and any(r.search(p) for p in paths for r in FRONTEND_PATHS):
        need.append("frontend")
    if project == "ios":
        need.append("ios")
    for lens in need:
        print(lens)


# --- reply check (spec 6.4) ------------------------------------------------------------------------

class Invalid(Exception):
    pass


def refuse_number(text):
    raise Invalid("a number that is not a whole number written in digits: %s" % text)


def plain_int(text):
    if not (text.isascii() and text.isdigit()):
        raise Invalid("a number that is not a whole number written in digits: %s" % text)
    return int(text)


def no_duplicates(pairs):
    seen = {}
    for key, value in pairs:
        if key in seen:
            raise Invalid("the key %r appears twice in one object" % key)
        seen[key] = value
    return seen


def file_proof(path):
    data = open(path, "rb").read()
    return hashlib.md5(data).hexdigest(), len(data)


def exact_keys(obj, keys, what):
    if not isinstance(obj, dict):
        raise Invalid("%s is not an object" % what)
    extra = sorted(set(obj) - set(keys))
    missing = [k for k in keys if k not in obj]
    if extra:
        raise Invalid("%s has fields the schema doesn't allow: %s" % (what, ", ".join(extra)))
    if missing:
        raise Invalid("%s is missing fields: %s" % (what, ", ".join(missing)))


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def check_reply(reply_file, lens, diff_file, evidence_file):
    try:
        reply = json.loads(open(reply_file, "rb").read().decode("utf-8"), object_pairs_hook=no_duplicates,
                           parse_float=refuse_number, parse_constant=refuse_number, parse_int=plain_int)
    except Invalid:
        raise
    except (OSError, UnicodeDecodeError, ValueError) as e:
        raise Invalid("the reply is not one JSON object (%s)" % str(e).split("\n")[0][:120])
    exact_keys(reply, REPLY_KEYS, "the reply")
    if reply["lens"] != lens:
        raise Invalid("the reply is for lens %r, not %s" % (reply["lens"], lens))
    if not isinstance(reply["diff_md5"], str) or not is_int(reply["diff_bytes"]):
        raise Invalid("diff_md5 must be a string and diff_bytes a whole number")
    if reply["verdict"] not in ("CLEAN", "FINDINGS"):
        raise Invalid("verdict %r is not CLEAN or FINDINGS" % (reply["verdict"],))
    findings = reply["findings"]
    if not isinstance(findings, list):
        raise Invalid("findings is not a list")
    ids = []
    for n, f in enumerate(findings, 1):
        exact_keys(f, FINDING_KEYS, "finding %d" % n)
        for k in ("id", "file", "title", "detail", "evidence"):
            if not isinstance(f[k], str):
                raise Invalid("finding %d's %s is not text" % (n, k))
        if not re.fullmatch(ID_RE, f["id"]):
            raise Invalid("finding %d's id %r doesn't match %s (letters, digits, . _ -; at most 40)" % (n, f["id"], ID_RE))
        if f["severity"] not in SEVERITIES:
            raise Invalid("finding %d's severity %r is not one of %s" % (n, f["severity"], ", ".join(SEVERITIES)))
        if not (f["line"] is None or is_int(f["line"])):
            raise Invalid("finding %d's line is not a whole number or null" % n)
        ids.append(f["id"])
    if len(set(ids)) != len(ids):
        raise Invalid("two findings share an id")
    # CLEAN only with no findings, and nits count (spec 6.4).
    if reply["verdict"] == "CLEAN" and findings:
        raise Invalid("verdict CLEAN with %d findings; CLEAN means none, nits included" % len(findings))
    if reply["verdict"] == "FINDINGS" and not findings:
        raise Invalid("verdict FINDINGS with no findings")
    # The fingerprints: the reply must name exactly these files. That shows consistency, not that
    # the reviewer read or understood them (spec 6.3).
    md5, size = file_proof(diff_file)
    if reply["diff_md5"] != md5:
        raise Invalid("diff_md5 %s is not the diff's md5 %s" % (reply["diff_md5"], md5))
    if reply["diff_bytes"] != size:
        raise Invalid("diff_bytes %s is not the diff's %d bytes" % (reply["diff_bytes"], size))
    if evidence_file == "-":
        if reply["evidence_md5"] is not None or reply["evidence_bytes"] is not None:
            raise Invalid("this round has no evidence file, so evidence_md5 and evidence_bytes must be null")
    else:
        emd5, esize = file_proof(evidence_file)
        if reply["evidence_md5"] is None or reply["evidence_bytes"] is None:
            raise Invalid("this round has an evidence file, and the reply doesn't report its evidence_md5 and evidence_bytes")
        if not isinstance(reply["evidence_md5"], str) or not is_int(reply["evidence_bytes"]):
            raise Invalid("evidence_md5 must be a string and evidence_bytes a whole number")
        if reply["evidence_md5"] != emd5:
            raise Invalid("evidence_md5 %s is not the evidence file's md5 %s" % (reply["evidence_md5"], emd5))
        if reply["evidence_bytes"] != esize:
            raise Invalid("evidence_bytes %s is not the evidence file's %d bytes" % (reply["evidence_bytes"], esize))
    return reply


def findings_hash(findings):
    # Spec 6.4: file|title|detail, lower-cased, line numbers masked, whitespace collapsed; sorted,
    # de-duplicated, sha256 of the lines (each ending in a line break). None for no findings.
    if not findings:
        return None
    lines = set()
    for f in findings:
        s = ("%s|%s|%s" % (f["file"], f["title"], f["detail"])).lower()
        s = re.sub(r":[0-9]+", ":N", s)
        s = re.sub(r"line [0-9]+", "line N", s)
        s = re.sub(r"\s+", " ", s).strip()
        lines.add(s)
    return hashlib.sha256("".join(l + "\n" for l in sorted(lines)).encode("utf-8")).hexdigest()


def check_reply_main(reply_file, lens, diff_file, evidence_file):
    try:
        reply = check_reply(reply_file, lens, diff_file, evidence_file)
    except Invalid as e:
        print(json.dumps({"status": "INVALID", "reason": str(e), "verdict": None, "findings": [], "hash": None}))
        return 3
    print(json.dumps({"status": "VALID", "reason": "", "verdict": reply["verdict"],
                      "findings": reply["findings"], "hash": findings_hash(reply["findings"])}))
    return 0


# --- the copy codex reviews (spec 6.3) ------------------------------------------------------------

def git(git_dir, args, stdin=None):
    env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "HOME": "/nonexistent", "GIT_CONFIG_NOSYSTEM": "1",
           "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_NO_REPLACE_OBJECTS": "1", "GIT_ATTR_NOSYSTEM": "1"}
    r = subprocess.run(["git", "--git-dir=" + git_dir, "-c", "core.commitGraph=false"] + args,
                       input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    if r.returncode != 0:
        sys.exit("git %s failed: %s" % (args[0], r.stderr.decode("utf-8", "replace").strip()[:200]))
    return r.stdout


def snapshot(git_dir, commit, out):
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        sys.exit("%s is not a commit id" % commit)
    entries = []
    for item in git(git_dir, ["ls-tree", "-r", "-z", "--full-tree", commit]).split(b"\0"):
        if not item:
            continue
        meta, path = item.split(b"\t", 1)
        mode, kind, oid = meta.decode("ascii").split(" ")
        name = path.decode("utf-8", "surrogateescape")
        parts = name.split("/")
        if name.startswith("/") or any(p in ("", ".", "..") or p.lower() == ".git" for p in parts):
            sys.exit("the commit has a path codex's copy can't hold: %r" % name)
        if mode == "120000":
            sys.exit("the commit has a symbolic link, %s, which could lead codex to any file; the review runner doesn't review links" % name)
        if mode == "160000":
            sys.exit("the commit has a submodule, %s; the review runner doesn't review submodules" % name)
        if kind != "blob" or mode not in ("100644", "100755"):
            sys.exit("the commit has %s with mode %s, which codex's copy can't hold" % (name, mode))
        entries.append((path, mode, oid))
    # macOS folds case in names: two paths (or folders) that differ only in case would become one.
    seen = {}
    for path, _, _ in entries:
        parts = path.decode("utf-8", "surrogateescape").split("/")
        for k in range(1, len(parts) + 1):
            name = "/".join(parts[:k])
            if seen.setdefault(name.lower(), name) != name:
                sys.exit("two paths in the commit differ only in case (%s, %s); on macOS they are one" %
                         (seen[name.lower()], name))
    batch = git(git_dir, ["cat-file", "--batch"], b"".join(oid.encode("ascii") + b"\n" for _, _, oid in entries))
    os.mkdir(out, 0o755)
    i = 0
    for path, mode, oid in entries:
        head_end = batch.index(b"\n", i)
        got_oid, kind, size = batch[i:head_end].decode("ascii").split(" ")
        size = int(size)
        data = batch[head_end + 1:head_end + 1 + size]
        i = head_end + 1 + size + 1
        if got_oid != oid or kind != "blob" or len(data) != size or \
                hashlib.sha1(b"blob %d\0" % size + data).hexdigest() != oid:
            sys.exit("object %s doesn't hash to its id; the copy would not be the commit" % oid)
        target = os.path.join(os.fsencode(out), path)
        os.makedirs(os.path.dirname(target), 0o755, exist_ok=True)
        fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o755 if mode == "100755" else 0o644)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
    return 0


# --- instruction files (spec 6.3) ------------------------------------------------------------------

DOC_NAMES = {"agents.md", "agents.override.md"}
TREE_DIRS = {".agents", ".codex"}


def instruction_files(worktree, codex_home):
    # Every folder must be looked into: one that can't be is reported, and counts like a hit, so
    # an incomplete look never lets codex run (FRG-7 review round 3). Only a codex home that
    # doesn't exist is fine.
    hits, unread = [], []

    def cant(e):
        unread.append("%s (%s)" % (e.filename, e.strerror))
    wt = os.path.realpath(worktree)
    for top, dirs, files in os.walk(wt, onerror=cant, followlinks=False):
        for name in list(dirs) + files:
            low = name.lower()
            if low in DOC_NAMES or low in TREE_DIRS:
                hits.append(os.path.join(top, name))
        # git's own folder holds no instructions codex reads, and a worktree's .git is a file.
        dirs[:] = [d for d in dirs if not (top == wt and d == ".git")]
    up = os.path.dirname(wt)
    while True:
        try:
            names = os.listdir(up)
        except OSError as e:
            cant(e)
            names = []
        for name in names:
            if name.lower() in DOC_NAMES or name.lower() == ".agents":
                hits.append(os.path.join(up, name))
        if up == "/":
            break
        up = os.path.dirname(up)
    try:
        for name in os.listdir(codex_home):
            if name.lower() in DOC_NAMES:
                hits.append(os.path.join(codex_home, name))
    except FileNotFoundError:
        pass
    except OSError as e:
        cant(e)
    for h in sorted(set(hits)):
        print(h)
    for u in unread:
        print("can't look into %s" % u)
    return 1 if hits or unread else 0


def main(argv):
    if len(argv) == 4 and argv[1] == "lenses":
        lenses(argv[2], argv[3])
        return 0
    if len(argv) == 6 and argv[1] == "check-reply":
        return check_reply_main(argv[2], argv[3], argv[4], argv[5])
    if len(argv) == 5 and argv[1] == "snapshot":
        return snapshot(argv[2], argv[3], argv[4])
    if len(argv) == 4 and argv[1] == "instruction-files":
        return instruction_files(argv[2], argv[3])
    sys.stderr.write("usage: review_lib.py lenses <type> <raw> | check-reply <reply> <lens> <diff> <evidence|-> | snapshot <git dir> <commit> <out> | instruction-files <folder> <codex home>\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
