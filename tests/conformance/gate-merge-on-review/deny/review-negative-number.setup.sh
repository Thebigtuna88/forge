# Refused (review round 12): review.md's numbers are plain digits, so a minus sign is refused
# even in a field the gate doesn't otherwise read.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
sc_review_edit '.note = -1'
