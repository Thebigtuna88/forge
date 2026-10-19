# Refused (review round 2): GitHub's answer has no head repository owner.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
sc_pr_edit 'del(.headRepositoryOwner)'
