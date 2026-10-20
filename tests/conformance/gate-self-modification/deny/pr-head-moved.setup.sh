# Refused: GitHub's head is not the --match-head-commit.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
sc_pr_edit '.headRefOid = "0123456789abcdef0123456789abcdef01234567"'
