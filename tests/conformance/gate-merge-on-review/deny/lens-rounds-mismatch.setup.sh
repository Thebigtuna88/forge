# Refused (review round 2): review.md says the code lens took 2 rounds but points at round 1's reply.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
sc_review_edit '.lenses[0].rounds = 2'
