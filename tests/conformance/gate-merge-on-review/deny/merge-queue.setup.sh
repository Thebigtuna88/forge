# Refused (review round 1): dev requires a merge queue, where gh pr merge can turn on auto-merge.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
printf '%s\n' '{"data": {"repository": {"mergeQueue": {"id": "MQ_1"}}}}' >"$SC_GH/api-graphql.out"
