# Refused: the reviewer's read-proof md5 is wrong (rule 4).
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
jq '.diff_md5 = "00000000000000000000000000000000"' "$SC_WORK/rounds/1/reply-code.json" >"$TMP/r"
mv "$TMP/r" "$SC_WORK/rounds/1/reply-code.json"
scene_review_json
scene_review_md
