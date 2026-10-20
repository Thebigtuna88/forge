# Refused: the reviewer's read-proof byte count is wrong (rule 4).
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
jq '.diff_bytes += 1' "$SC_WORK/rounds/1/reply-security.json" >"$TMP/r"
mv "$TMP/r" "$SC_WORK/rounds/1/reply-security.json"
scene_review_json
scene_review_md
