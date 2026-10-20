# Refused: the PR changes a CI workflow.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine .github/workflows/ci.yml $'on: push\n'
