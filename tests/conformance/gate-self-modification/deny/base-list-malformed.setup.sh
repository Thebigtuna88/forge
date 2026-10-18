# Refused: the merge base's owner-only list is not JSON.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
SC_LIST='not json'
scene_genuine
