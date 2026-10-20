# Refused (review round 5): the comparison's merge base is a valid commit id followed by a line
# break and more text; a commit id is judged whole, not by its first line.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
f="$SC_GH/api-repos_Thebigtuna88_forge_compare_dev...$SC_HEAD.out"
jq '.merge_base_commit.sha += "\nnot-a-sha"' "$f" >"$TMP/compare.edit" && mv "$TMP/compare.edit" "$f"
