# Refused: review.md's md5 was edited.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
sc_review_edit '.diff_md5 = "00000000000000000000000000000000"'
