# Names that only look like owner-only paths.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine CLAUDE.md.bak x .claude/hooks-old/x.sh x docs/specsheet.md x .harness/library.txt x
