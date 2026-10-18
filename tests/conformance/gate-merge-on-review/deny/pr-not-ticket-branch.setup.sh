# Refused: the PR's branch is not a ticket branch.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
sc_pr_edit '.headRefName = "hotfix"'
