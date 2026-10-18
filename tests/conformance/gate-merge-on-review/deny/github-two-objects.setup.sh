# Refused (review round 1): GitHub's answer about the PR holds two JSON values.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
jq -c . "$SC_GH/pr-view-$SC_PR.out" >"$TMP/one"
{ printf '{"state": "MERGED"}\n'; cat "$TMP/one"; } >"$SC_GH/pr-view-$SC_PR.out"
