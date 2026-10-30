# Refused (FRG-7 review round 2): the ios lens ran, though the diff doesn't require it, and
# review.md leaves it out. Every lens that ran must be listed, and so CLEAN.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
jq '.lens = "ios" | .verdict = "FINDINGS" | .findings = [{id: "I1", severity: "major", file: "x", line: 1, title: "t", detail: "d", evidence: "e"}]' \
  "$SC_WORK/rounds/1/reply-code.json" >"$SC_WORK/rounds/1/reply-ios.json"
