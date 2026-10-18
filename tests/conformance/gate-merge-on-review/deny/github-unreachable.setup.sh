# Refused: GitHub can't be read.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
rm "$SC_GH/pr-view-$SC_PR.out"
