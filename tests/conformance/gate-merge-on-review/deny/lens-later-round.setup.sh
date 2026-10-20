# Refused (review round 2): a round-2 reply exists that review.md doesn't account for (a stale summary).
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
mkdir -p "$SC_WORK/rounds/2"
jq '.verdict = "FINDINGS" | .findings = [{id: "C1", severity: "major", file: "x", line: 1, title: "t", detail: "d", evidence: "e"}]' "$SC_WORK/rounds/1/reply-code.json" >"$SC_WORK/rounds/2/reply-code.json"
