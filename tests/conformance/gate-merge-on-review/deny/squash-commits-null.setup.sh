# Refused (review round 1): GitHub's commit list is missing, so the scan would read nothing.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
sc_pr_edit '.commits = null'
