# Refused: a CLEAN reply that lists a finding (nits count).
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
jq '.findings = [{id: "N1", severity: "nit", file: "x", line: 1, title: "t", detail: "d", evidence: "e"}]' "$SC_WORK/rounds/1/reply-security.json" >"$TMP/r"
mv "$TMP/r" "$SC_WORK/rounds/1/reply-security.json"
scene_review_json
scene_review_md
