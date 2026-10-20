# The security lens may be run by a subagent (spec 6.2); only code must be codex.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
sc_review_edit '.lenses[1].mechanism = "subagent"'
