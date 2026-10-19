# Refused (review round 6): a lens's mechanism is "co<NUL>dex"; bash drops the NUL, so it would be
# read as codex. A field holding a NUL makes the block malformed.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
sc_review_edit '.lenses[0].mechanism = "co\u0000dex"'
