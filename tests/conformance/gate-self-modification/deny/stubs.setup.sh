# Refused: the PR changes the fake gh the cases run on (owner decision 2026-10-18).
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine tests/stubs/gh $'#!/bin/bash\n'
