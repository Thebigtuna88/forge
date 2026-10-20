# Refused: a loose object file was replaced, so the local copy of a file differs from what its id (and GitHub) says; review-diff re-hashes every object.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
blob="$(git -C "$ROOT" rev-parse "$SC_HEAD:src/sample.txt")"
obj="$ROOT/.git/objects/${blob:0:2}/${blob:2}"
python3 -I -c 'import sys, zlib; open(sys.argv[1], "wb").write(zlib.compress(b"blob 7\0SAMPLE\n"))' "$TMP/forged"
chmod u+w "$obj"
cp "$TMP/forged" "$obj"
