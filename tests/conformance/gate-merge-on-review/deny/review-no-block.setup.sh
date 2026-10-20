# Refused: review.md has no facts block.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
printf '# Review\n\nCLEAN\n' >"$SC_WORK/review.md"
