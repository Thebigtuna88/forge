#!/bin/bash -p
# review-diff (FRG-4, spec 6.6): the one diff that a review reads and the merge gate recomputes.
#   review-diff.sh <repository folder> <base sha> <head sha> <out folder>
# <base> is the tip of the branch the PR merges into (dev), <head> the PR's head. Writes, into
# <out folder> (which must exist and be empty):
#   merge-base   the merge base of <base> and <head>, one line
#   diff.patch   the diff from that merge base to <head>
#   raw          `git diff --raw -z` of the same two trees (modes, object ids and paths)
# The diff is made in a fresh bare repository that borrows the objects of <repository folder>
# (alternates) and nothing else: no repository, global or system settings, no attributes (no
# .gitattributes, info/attributes or attributes file: the attribute source is the empty tree), no
# replace refs and no commit-graph. So no setting can change its bytes (external diff tools, text
# conversion, colour, prefixes, context, rename detection, diff drivers, order files), and the
# same commits always give the same diff on the same git. Every object the diff reads (both
# commits and every tree and file of both snapshots) is re-hashed, so an object file planted in
# the repository can't show the reviewer one content while GitHub merges another.
# Exit status: 0 done; 3 a commit is not in the repository (fetch it first); 4 there isn't
# exactly one merge base; 5 an object doesn't match its id; 1 anything else.
# Must run on macOS /bin/bash 3.2.
set -uo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin
export PATH LC_ALL=C
for v in $(compgen -e); do
  case "$v" in
    PATH | LC_ALL | TMPDIR) ;;
    *) unset "$v" 2>/dev/null || true ;;
  esac
done

die() { # <status> <message>
  printf 'review-diff: %s\n' "$2" >&2
  exit "$1"
}

[[ $# -eq 4 ]] || die 1 "usage: review-diff.sh <repository folder> <base sha> <head sha> <out folder>"
repo="$1" base="$2" head="$3" out="$4"
sha='^[0-9a-f]{40}$'
[[ "$base" =~ $sha && "$head" =~ $sha ]] || die 1 "base and head must be full 40-character commit ids"
[[ -d "$out" && ! -L "$out" ]] || die 1 "the out folder must be an existing folder: $out"
[[ -z "$(ls -A "$out")" ]] || die 1 "the out folder must be empty: $out"
objects="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/objects" ||
  die 1 "$repo is not a git repository"
[[ -d "$objects" ]] || die 1 "no object folder at $objects"

iso="$out/iso.git"
home="$out/home"
mkdir "$home" || die 1 "can't create $home"
git init -q --bare "$iso" >/dev/null 2>&1 || die 1 "can't create a scratch repository in $out"
printf '%s\n' "$objects" >"$iso/objects/info/alternates" || die 1 "can't write the alternates file"
empty_tree=4b825dc642cb6eb9a060e54bf8d69288fbe4904b
igit() { # git in the scratch repository, with no settings from anywhere
  env -i PATH="$PATH" LC_ALL=C HOME="$home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_NO_REPLACE_OBJECTS=1 GIT_ATTR_NOSYSTEM=1 \
    git --git-dir="$iso" --attr-source="$empty_tree" -c core.commitGraph=false "$@"
}

for c in "$base" "$head"; do
  [[ "$(igit cat-file -t "$c" 2>/dev/null)" == commit ]] ||
    die 3 "commit $c is not in $repo; run git fetch origin first"
done
igit merge-base --all "$base" "$head" >"$out/merge-base.all" 2>/dev/null ||
  die 4 "$base and $head have no merge base"
[[ "$(wc -l <"$out/merge-base.all" | tr -d ' ')" == 1 ]] ||
  die 4 "$base and $head have more than one merge base"
mv "$out/merge-base.all" "$out/merge-base"
mb="$(cat "$out/merge-base")"
[[ "$mb" =~ $sha ]] || die 1 "unexpected merge base: $mb"

# Re-hash every object both snapshots are made of, and the two commits themselves.
{
  printf '%s\n' "$mb" "$head"
  for c in "$mb" "$head"; do
    igit rev-parse "$c^{tree}" || exit 1
    igit ls-tree -r -t --full-tree "$c" | awk '$2 != "commit" {print $3}' || exit 1
  done
} >"$out/objects.list" 2>/dev/null || die 1 "can't list the objects of $mb and $head"
sort -u "$out/objects.list" | igit cat-file --batch >"$out/objects.batch" 2>/dev/null ||
  die 5 "can't read every object of $mb and $head"
# shellcheck disable=SC2016 # Python source
python3 -I -c '
import hashlib, sys
data = open(sys.argv[1], "rb").read()
i, n = 0, 0
while i < len(data):
    nl = data.index(b"\n", i)
    head = data[i:nl].split(b" ")
    if len(head) != 3:
        sys.exit("bad object header: %r" % data[i:nl][:80])
    oid, kind, size = head[0].decode(), head[1], int(head[2])
    body = data[nl + 1:nl + 1 + size]
    if len(body) != size or data[nl + 1 + size:nl + 2 + size] != b"\n":
        sys.exit("short object " + oid)
    if hashlib.sha1(kind + b" " + str(size).encode() + b"\0" + body).hexdigest() != oid:
        sys.exit("object " + oid + " does not match its id")
    i, n = nl + 2 + size, n + 1
if n == 0:
    sys.exit("no objects read")
' "$out/objects.batch" 2>"$out/verify.err" || die 5 "$(cat "$out/verify.err")"
rm -f "$out/objects.list" "$out/objects.batch" "$out/verify.err"

igit diff --text --no-ext-diff --no-textconv --no-color --no-renames --full-index \
  --src-prefix=a/ --dst-prefix=b/ "$mb" "$head" -- >"$out/diff.patch" 2>/dev/null ||
  die 1 "git diff failed"
igit diff --raw -z --no-abbrev --no-renames "$mb" "$head" -- >"$out/raw" 2>/dev/null ||
  die 1 "git diff --raw failed"
exit 0
