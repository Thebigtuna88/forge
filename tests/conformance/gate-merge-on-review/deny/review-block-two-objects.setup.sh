# Refused (review round 1): the facts block holds two JSON values.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
jq -c '.lenses = []' "$TMP/review.json" >"$TMP/first"
{ cat "$TMP/first"; cat "$TMP/review.json"; } >"$TMP/two.json"
mv "$TMP/two.json" "$TMP/review.json"
scene_review_md
