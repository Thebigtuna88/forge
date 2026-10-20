# Refused: a deferred finding's issue is closed.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
SC_DEFERRED='[{"finding": "S1", "issue": 31}]'
scene_review_json
scene_review_md
sc_issue 31 CLOSED
