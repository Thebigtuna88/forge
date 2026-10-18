# Refused: the merge base's owner-only list counts too (here it adds extra/, which the live list lacks).
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
SC_LIST='{"paths": ["extra/"]}'
scene_genuine extra/x.txt $'x\n'
