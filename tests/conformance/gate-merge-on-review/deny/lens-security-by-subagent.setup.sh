# Refused: the security lens was run by a subagent. Every lens is run by codex (owner decision
# 2026-10-28, FRG-7); until FRG-7 a non-code lens could be.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
sc_review_edit '.lenses[1].mechanism = "subagent"'
