# Refused (review round 1): a commit's author is not an object.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
sc_pr_edit '.commits[0].authors = ["x"]'
