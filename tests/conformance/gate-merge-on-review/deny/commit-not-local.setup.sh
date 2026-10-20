# Refused: GitHub's head commit isn't in the local repository (not fetched).
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
sc_pr_edit '.headRefOid = "0123456789abcdef0123456789abcdef01234567"'
jq -n --arg d "$SC_DEV" '{base_commit: {sha: $d}, merge_base_commit: {sha: $d}}' >"$SC_GH/api-repos_Thebigtuna88_forge_compare_dev...0123456789abcdef0123456789abcdef01234567.out"
printf '%s\n' "0123456789abcdef0123456789abcdef01234567" >"$TMP/case.sha"
