# Refused: the branch got a new commit after the review (review.md names the old head).
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_base
scene_change
scene_review
sc_start "$SC_HEAD"
sc_put src/more.txt $'more\n'
scene_head "$(sc_commit "FRG-9: more" "$SC_HEAD")"
scene_github
