# Refused (review round 6): GitHub's answer gives the deferred finding's issue the state
# "OP<NUL>EN"; bash drops the NUL, so it would be read as OPEN.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
SC_DEFERRED='[{"finding": "S1", "issue": 31}]'
scene_review_json
scene_review_md
printf '%s\n' '{"state": "OP\u0000EN"}' >"$SC_GH/issue-view-31.out"
