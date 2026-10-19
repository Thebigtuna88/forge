# Refused (review round 2): GitHub lists only the first 100 authors of a commit.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
sc_pr_edit '.commits[0].authors = [range(100) as $i | .commits[0].authors[0]]'
