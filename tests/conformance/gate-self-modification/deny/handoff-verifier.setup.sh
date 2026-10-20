# Refused: the PR changes .harness/bin/handoff, owner-only in the live list (owner decision 2026-10-18), though not in the merge base's list.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine .harness/bin/handoff $'#!/bin/bash\n'
