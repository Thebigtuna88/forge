# Allowed (review round 4): rounds are uncapped (rule 5), so a CLEAN code lens in round 1000000
# counts like one in round 1.
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
mkdir -p "$SC_WORK/rounds/1000000"
mv "$SC_WORK/rounds/1/reply-code.json" "$SC_WORK/rounds/1000000/reply-code.json"
sc_review_edit '.lenses[0].rounds = 1000000 | .lenses[0].reply = "rounds/1000000/reply-code.json"'
