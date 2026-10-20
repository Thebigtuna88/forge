# Refused (review round 11): review.md's numbers are plain digits. jq reads "rounds": 1e0 as 1,
# so the spelling is checked in the block itself.
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
sed 's/"rounds": 1,/"rounds": 1e0,/' "$TMP/review.json" >"$TMP/review.edit"
grep -q '"rounds": 1e0,' "$TMP/review.edit" || exit 1
mv "$TMP/review.edit" "$TMP/review.json"
scene_review_md
