# Refused: a rename out of an owner-only folder counts as a change to both paths.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_base
sc_start "$SC_BASE"
sc_put .claude/hooks/old.sh $'x\n'
SC_BASE="$(sc_commit "base with a hook" "$SC_BASE")"
SC_DEV="$SC_BASE"
sc_git update-ref refs/heads/dev "$SC_BASE"
sc_start "$SC_BASE"
sc_del .claude/hooks/old.sh
sc_put scripts/old.sh $'x\n'
scene_head "$(sc_commit "FRG-9: move a hook" "$SC_BASE")"
scene_review
scene_github
