# Allowed: the change touches the spend limits, and the review has a CLEAN spend lens besides code
# and security (spec 6.2, FRG-7).
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine .harness/spend-limits.json $'{"providers": {}}\n'
scene_add_lens spend
