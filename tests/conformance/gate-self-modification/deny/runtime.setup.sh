# Refused: the PR changes the hook runtime.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine .harness/lib/hookrt.sh $'# x\n'
