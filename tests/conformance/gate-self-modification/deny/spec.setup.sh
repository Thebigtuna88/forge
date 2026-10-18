# Refused: the PR changes the approved spec under docs/specs/ (owner decision 2026-10-18).
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine docs/specs/2026-10-15-harness-design.md $'# spec\n'
