# Refused: the PR changes a conformance case.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine tests/conformance/deny-repo-admin/allow/x.json $'{}\n'
