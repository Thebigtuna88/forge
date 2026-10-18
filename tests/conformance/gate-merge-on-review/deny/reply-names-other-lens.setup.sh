# Refused: the code reply says it is the security lens.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
jq '.lens = "security"' "$SC_WORK/rounds/1/reply-code.json" >"$TMP/r"
mv "$TMP/r" "$SC_WORK/rounds/1/reply-code.json"
scene_review_json
scene_review_md
