# Refused: a symlink in the diff can point into an owner-only folder.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_base
sc_start "$SC_BASE"
sc_put tools/gates ../.claude/hooks 120000
scene_head "$(sc_commit "FRG-9: a link" "$SC_BASE")"
scene_review
scene_github
