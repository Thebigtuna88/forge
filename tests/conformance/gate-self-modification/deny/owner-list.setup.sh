# Refused: the PR changes the owner-only list itself.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine .harness/self-modification-paths.json $'{"paths": ["x"]}\n'
