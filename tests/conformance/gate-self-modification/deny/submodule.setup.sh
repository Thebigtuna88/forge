# Refused: a submodule in the diff.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_base
sc_start "$SC_BASE"
sc_git update-index --add --cacheinfo "160000,$SC_BASE,vendor/lib"
scene_head "$(sc_commit "FRG-9: a submodule" "$SC_BASE")"
scene_review
scene_github
