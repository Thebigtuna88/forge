# Refused: the comparison has no commit ids.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
printf '{}\n' >"$SC_GH/api-repos_Thebigtuna88_forge_compare_dev...$SC_HEAD.out"
