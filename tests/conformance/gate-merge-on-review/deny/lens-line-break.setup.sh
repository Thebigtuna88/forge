# Refused (review round 5): a lens's verdict holds a line break, which would split its row in two;
# a field with a line break makes the block malformed.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
sc_review_edit '.lenses[0].verdict = "CLEAN\nx"'
