# Refused: the change is one plan document, and the review lists only code and security. Even a
# change that can't spend anything needs a CLEAN spend lens (spec 6.2, owner decision 2026-10-29,
# FRG-7).
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine docs/plans/later.md $'A plan.\n'
rm "$SC_WORK/rounds/1/reply-spend.json"
sc_review_edit '.lenses |= map(select(.lens != "spend"))'
