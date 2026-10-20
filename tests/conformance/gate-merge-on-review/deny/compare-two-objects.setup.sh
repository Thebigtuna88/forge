# Refused (review round 1): GitHub's comparison holds two JSON values.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
jq -c . "$SC_GH/api-repos_Thebigtuna88_forge_compare_dev...$SC_HEAD.out" >"$TMP/one"
{ printf '{"base_commit": {"sha": "x"}}\n'; cat "$TMP/one"; } >"$SC_GH/api-repos_Thebigtuna88_forge_compare_dev...$SC_HEAD.out"
