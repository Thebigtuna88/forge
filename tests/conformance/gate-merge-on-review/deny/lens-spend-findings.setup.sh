# Refused: the spend reply has findings, though review.md calls it CLEAN (FRG-7).
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
jq '.verdict = "FINDINGS" | .findings = [{id: "P1", severity: "minor", file: "x", line: 1, title: "t", detail: "d", evidence: "e"}]' "$SC_WORK/rounds/1/reply-spend.json" >"$TMP/r"
mv "$TMP/r" "$SC_WORK/rounds/1/reply-spend.json"
scene_review_json
scene_review_md
