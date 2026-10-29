# Refused: the change touches nothing about spending, and the review lists only code and security.
# The spend lens is required on every PR (spec 6.2, owner decision 2026-10-29, FRG-7); the gate
# works the required lenses out itself, whatever review.md lists.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
rm "$SC_WORK/rounds/1/reply-spend.json"
sc_review_edit '.lenses |= map(select(.lens != "spend"))'
