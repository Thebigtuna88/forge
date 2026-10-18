# Refused: review.md names another merge base.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
sc_review_edit '.merge_base = "0123456789abcdef0123456789abcdef01234567"'
