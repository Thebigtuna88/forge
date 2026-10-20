# Refused: one owner-only file among 151 (GitHub's own file list stops at 100).
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
files=()
for i in $(seq 1 150); do files+=("src/f$i.txt" x); done
scene_genuine "${files[@]}" .claude/hooks/late.sh x
