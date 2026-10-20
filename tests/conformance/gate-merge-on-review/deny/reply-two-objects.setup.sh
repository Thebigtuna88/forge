# Refused (review round 1): a reply file holds a FINDINGS reply followed by a CLEAN one (jq would judge only the last).
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
jq -c . "$SC_WORK/rounds/1/reply-code.json" >"$TMP/one"
{ printf '{"lens": "code", "verdict": "FINDINGS", "findings": [{"id": "C1"}]}\n'; cat "$TMP/one"; } >"$SC_WORK/rounds/1/reply-code.json"
scene_review_json
scene_review_md
