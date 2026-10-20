# Refused: a reply outside the ticket's rounds.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
sc_review_edit '.lenses[0].reply = "../FRG-8-other/rounds/1/reply-code.json"'
