# Refused: review.md is a link.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
mv "$SC_WORK/review.md" "$TMP/review.md"
ln -s "$TMP/review.md" "$SC_WORK/review.md"
