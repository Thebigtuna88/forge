# docs/plans/ and docs/decisions/ stay the agent's (owner decision 2026-10-18).
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine docs/plans/2026-10-20-x.md $'plan\n' docs/decisions/2026-10-20-x.md $'decision\n' work/x.txt x
