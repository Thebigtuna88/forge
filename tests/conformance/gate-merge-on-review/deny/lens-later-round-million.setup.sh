# Refused (review round 4): review.md records round 1000000 for the code lens, but round 10000000
# exists. Rounds have any number of digits, and a longer number is a later round.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
mkdir -p "$SC_WORK/rounds/1000000" "$SC_WORK/rounds/10000000"
mv "$SC_WORK/rounds/1/reply-code.json" "$SC_WORK/rounds/1000000/reply-code.json"
sc_review_edit '.lenses[0].rounds = 1000000 | .lenses[0].reply = "rounds/1000000/reply-code.json"'
jq '.verdict = "FINDINGS" | .findings = [{id: "C1", severity: "major", file: "x", line: 1, title: "t", detail: "d", evidence: "e"}]' "$SC_WORK/rounds/1000000/reply-code.json" >"$SC_WORK/rounds/10000000/reply-code.json"
