# Refused: a reply file is a link.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
mv "$SC_WORK/rounds/1/reply-code.json" "$TMP/reply-code.json"
ln -s "$TMP/reply-code.json" "$SC_WORK/rounds/1/reply-code.json"
