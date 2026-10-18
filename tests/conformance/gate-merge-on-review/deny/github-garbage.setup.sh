# Refused: GitHub's answer is not JSON.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
printf 'not json\n' >"$SC_GH/pr-view-$SC_PR.out"
