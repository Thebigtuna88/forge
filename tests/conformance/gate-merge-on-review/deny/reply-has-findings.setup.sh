# Refused: the reply itself has findings.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
jq '.verdict = "FINDINGS" | .findings = [{id: "C1", severity: "minor", file: "x", line: 1, title: "t", detail: "d", evidence: "e"}]' "$SC_WORK/rounds/1/reply-code.json" >"$TMP/r"
mv "$TMP/r" "$SC_WORK/rounds/1/reply-code.json"
scene_review_json
scene_review_md
