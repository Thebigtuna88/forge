# Refused: the merge base has no owner-only list.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_base
sc_start "$SC_BASE"
sc_del .harness/self-modification-paths.json
SC_BASE="$(sc_commit "base without a list" "$SC_BASE")"
SC_DEV="$SC_BASE"
sc_git update-ref refs/heads/dev "$SC_BASE"
scene_change
scene_review
scene_github
