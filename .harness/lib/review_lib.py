# review_lib.py (FRG-7, spec 6): the review runner's checks that are easier to get exactly right
# in Python than in bash. Run with python3 -I (no user site, no environment, no current folder on
# the import path). Python 3.9 (Apple's /usr/bin/python3).
#   lenses <project type> <raw> <diff.patch> <spend-limits.json>
#       the lenses spec 6.2 requires for a frozen diff (review-diff.sh's raw and diff.patch), one
#       per line. The runner and the merge gate both call this, so they can't disagree. The spend
#       rule also reads every provider's and payments' hosts, key variables and commands (tools
#       and SDK packages), and the always-blocked texts, from spend-limits.json; a missing or
#       malformed list is an error, never an empty one.
#   check-reply <reply.json> <lens> <diff.patch> <evidence.txt or ->
#       prints one JSON object: status VALID or INVALID, reason, verdict, findings, hash.
#       Exit 0 if VALID, 3 if INVALID.
#   instruction-files <worktree> <codex home>
#       lists every file or folder that could hand codex instructions (spec 6.3, FRG-7 step 2):
#       AGENTS.md, AGENTS.override.md, .agents/ or .codex/ anywhere in the worktree; AGENTS.md,
#       AGENTS.override.md or .agents/ in any folder above it; AGENTS.md or AGENTS.override.md
#       in codex's home. Names are compared without case, as macOS's file system does. Exit 0 if
#       there are none, 1 if there are (one path per line).
import hashlib
import json
import os
import re
import sys

LENSES = ["code", "security", "frontend", "ios", "spend"]
# A finding id: the reply schema's pattern, and the one review-lens defer accepts.
ID_RE = r"^[A-Za-z0-9._-]{1,40}$"
SEVERITIES = ["blocker", "major", "minor", "nit"]
REPLY_KEYS = ["lens", "diff_md5", "diff_bytes", "evidence_md5", "evidence_bytes", "verdict", "findings"]
FINDING_KEYS = ["id", "severity", "file", "line", "title", "detail", "evidence"]

# --- required lenses (spec 6.2) --------------------------------------------------------------------

PROJECT_TYPES = ["harness", "web", "ios"]
# spend: the spend limits, the spend gate, a budget wrapper, ledger, image generation, provider
# adapter or payments code, or a paid-API host, key variable, tool or SDK package anywhere in the
# diff's text: these lists, and spend-limits.json's (spend_words). The rule is a floor: any known
# lens can also be run when it isn't required, and then counts like a required one.
SPEND_PATHS = [
    re.compile(r"(^|/)spend-limits\.json$", re.I),
    re.compile(r"^\.claude/hooks/gate-spend\.sh$"),
    re.compile(r"(^|/)[^/]*(budget|ledger|imagegen|payment|billing|stripe|checkout)[^/]*(/|$)", re.I),
    re.compile(r"(^|/)providers?(/|$)", re.I),
]
SPEND_TEXT = [
    re.compile(r"\b(api\.openai\.com|api\.anthropic\.com|api\.stripe\.com|generativelanguage\.googleapis\.com|"
               r"api\.replicate\.com|fal\.run|api\.stability\.ai|api\.elevenlabs\.io|api\.ideogram\.ai|"
               r"api\.bfl\.ml|api\.together\.xyz|api\.mistral\.ai|api\.x\.ai)\b", re.I),
    re.compile(r"\b[A-Z0-9_]*(OPENAI|ANTHROPIC|STRIPE|REPLICATE|FAL|STABILITY|ELEVENLABS|GEMINI|"
               r"IDEOGRAM|BFL|TOGETHER|MISTRAL|XAI)[A-Z0-9_]*_(API_KEY|KEY|TOKEN|SECRET)\b"),
    re.compile(r"\b(sk|pk|rk)_(live|test)_"),
]
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


def spend_words(spend_file):
    # (texts matched anywhere, ignoring case; commands matched as whole words) from
    # spend-limits.json: hosts, key_vars and commands of every provider but manual and of
    # payments, and always_blocked. The shape is the one gate-spend requires (hookrt.sh): a
    # providers object, a payments object, all three lists on each of those sections (empty is
    # fine) and a non-empty always_blocked; anything else is an error (FRG-7 review round 2).
    def strings(section, key, where):
        if key not in section:
            raise ValueError("%s has no %s list" % (where, key))
        v = section[key]
        if not isinstance(v, list) or not all(isinstance(s, str) and s for s in v):
            raise ValueError("%s.%s is not a list of texts" % (where, key))
        return v
    try:
        doc = json.loads(open(spend_file, "rb").read().decode("utf-8"))
        if not isinstance(doc, dict) or not isinstance(doc.get("providers"), dict):
            raise ValueError("no providers object")
        if not isinstance(doc.get("payments"), dict):
            raise ValueError("no payments object")
        sections = [(n, p) for n, p in doc["providers"].items() if n != "manual"] + [("payments", doc["payments"])]
        texts = list(strings(doc, "always_blocked", "the file"))
        if not texts:
            raise ValueError("always_blocked is empty")
        commands = []
        for name, p in sections:
            if not isinstance(p, dict):
                raise ValueError("%s is not an object" % name)
            texts += strings(p, "hosts", name) + strings(p, "key_vars", name)
            commands += strings(p, "commands", name)
    except (OSError, UnicodeDecodeError, ValueError) as e:
        sys.exit("spend-limits.json can't be read (%s), so the spend lens can't be worked out" % e)
    return texts, commands


def lenses(project, raw_file, patch_file, spend_file):
    if project not in PROJECT_TYPES:
        sys.exit("unknown project type: %s (%s)" % (project, ", ".join(PROJECT_TYPES)))
    texts, commands = spend_words(spend_file)
    paths = raw_paths(open(raw_file, "rb").read())
    text = open(patch_file, "rb").read().decode("utf-8", "replace")
    low = text.lower()
    need = ["code", "security"]
    if project == "web" and any(r.search(p) for p in paths for r in FRONTEND_PATHS):
        need.append("frontend")
    if project == "ios":
        need.append("ios")
    if (any(r.search(p) for p in paths for r in SPEND_PATHS) or any(r.search(text) for r in SPEND_TEXT)
            or any(t.lower() in low for t in texts)
            or any(re.search(r"(?<![A-Za-z0-9_-])" + re.escape(c) + r"(?![A-Za-z0-9_-])", text) for c in commands)):
        need.append("spend")
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


# --- instruction files (spec 6.3) ------------------------------------------------------------------

DOC_NAMES = {"agents.md", "agents.override.md"}
TREE_DIRS = {".agents", ".codex"}


def instruction_files(worktree, codex_home):
    hits = []
    wt = os.path.realpath(worktree)
    for top, dirs, files in os.walk(wt, followlinks=False):
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
        except OSError:
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
    except OSError:
        pass
    for h in sorted(set(hits)):
        print(h)
    return 1 if hits else 0


def main(argv):
    if len(argv) == 6 and argv[1] == "lenses":
        lenses(argv[2], argv[3], argv[4], argv[5])
        return 0
    if len(argv) == 6 and argv[1] == "check-reply":
        return check_reply_main(argv[2], argv[3], argv[4], argv[5])
    if len(argv) == 4 and argv[1] == "instruction-files":
        return instruction_files(argv[2], argv[3])
    sys.stderr.write("usage: review_lib.py lenses <type> <raw> <patch> <spend-limits.json> | check-reply <reply> <lens> <diff> <evidence|-> | instruction-files <worktree> <codex home>\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
