# Refused: the PR changes a hook.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine .claude/hooks/new-gate.sh $'#!/bin/bash -p\n'
