# dev got new commits after the review, but the branch didn't take them: the merge base and the diff are unchanged.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_base
scene_change
scene_review
scene_dev_moves
scene_github
