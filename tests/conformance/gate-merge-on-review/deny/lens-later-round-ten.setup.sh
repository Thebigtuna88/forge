# Refused (review round 4): review.md records round 9 for the code lens, but round 10 exists.
# Rounds compare as numbers, not as text ("10" sorts before "9").
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
mkdir -p "$SC_WORK/rounds/9" "$SC_WORK/rounds/10"
mv "$SC_WORK/rounds/1/reply-code.json" "$SC_WORK/rounds/9/reply-code.json"
sc_review_edit '.lenses[0].rounds = 9 | .lenses[0].reply = "rounds/9/reply-code.json"'
jq '.verdict = "FINDINGS" | .findings = [{id: "C1", severity: "major", file: "x", line: 1, title: "t", detail: "d", evidence: "e"}]' "$SC_WORK/rounds/9/reply-code.json" >"$SC_WORK/rounds/10/reply-code.json"
