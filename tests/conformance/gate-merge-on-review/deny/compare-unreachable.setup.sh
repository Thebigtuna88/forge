# Refused: the comparison can't be read.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
rm "$SC_GH/api-repos_Thebigtuna88_forge_compare_dev...$SC_HEAD.out"
