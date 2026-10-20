# Refused (review round 5): the head repository owner is the right name followed by a line break
# and more text; a field is judged whole, not by its first line.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
sc_pr_edit '.headRepositoryOwner.login += "\ngarbage"'
