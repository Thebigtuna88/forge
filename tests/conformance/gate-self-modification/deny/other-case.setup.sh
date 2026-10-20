# Refused: the PR changes a hook spelled in other case (macOS treats it as the same file).
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine .Claude/Hooks/new-gate.sh $'x\n'
