# Refused (review round 1): GitHub's merge-queue answer has no repository.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
printf '%s\n' '{"data": {"repository": null}}' >"$SC_GH/api-graphql.out"
