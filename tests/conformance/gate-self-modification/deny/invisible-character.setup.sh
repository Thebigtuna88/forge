# Refused: the PR changes CLAUDE.md with a zero-width space in its name.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine $'CLAUDE\xe2\x80\x8b.md' $'x\n'
