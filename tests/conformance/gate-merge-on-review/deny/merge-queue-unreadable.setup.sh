# Refused (review round 1): GitHub can't say whether dev has a merge queue.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
rm "$SC_GH/api-graphql.out"
