# Refused: the change touches the spend limits, so the spend lens is required (spec 6.2), and the
# review lists only code and security. The gate works the required lenses out from the diff it
# recomputes, whatever review.md lists (FRG-7).
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine .harness/spend-limits.json $'{"providers": {}}\n'
