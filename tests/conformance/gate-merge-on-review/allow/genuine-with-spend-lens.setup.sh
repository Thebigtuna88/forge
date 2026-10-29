# Allowed: the change touches the spend limits, and the review has CLEAN code, security and spend
# lenses, as every PR's must (spec 6.2, owner decision 2026-10-29, FRG-7).
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine .harness/spend-limits.json $'{"providers": {}}\n'
