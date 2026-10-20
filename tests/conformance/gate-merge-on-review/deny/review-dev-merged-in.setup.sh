# Refused: dev was merged into the branch after the review, so the merge base moved; review.md was updated by hand to the new head but still describes the old diff.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_base
scene_change
scene_review
scene_dev_moves
sc_start "$SC_HEAD"
sc_put docs/plans/later.md $'later\n'
scene_head "$(sc_commit "Merge dev" "$SC_HEAD" "$SC_DEV")"
old_mb="$SC_MB"
scene_freeze
scene_github
sc_review_edit '.head = $h | .merge_base = $m' --arg h "$SC_HEAD" --arg m "$old_mb"
