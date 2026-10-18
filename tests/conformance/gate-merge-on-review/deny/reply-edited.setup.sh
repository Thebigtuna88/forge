# Refused: a reply was edited after the review.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
printf ' ' >>"$SC_WORK/rounds/1/reply-code.json"
