# Refused: GitHub's merge base differs from the local one.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
jq -n --arg d "$SC_DEV" '{base_commit: {sha: $d}, merge_base_commit: {sha: "0123456789abcdef0123456789abcdef01234567"}}' >"$SC_GH/api-repos_Thebigtuna88_forge_compare_dev...$SC_HEAD.out"
