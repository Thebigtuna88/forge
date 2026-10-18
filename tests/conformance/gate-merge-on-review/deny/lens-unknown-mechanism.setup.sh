# Refused: an unknown mechanism.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
sc_review_edit '.lenses[1].mechanism = "human"'
