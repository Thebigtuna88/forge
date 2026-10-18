# Refused: a reply file is missing.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
rm "$SC_WORK/rounds/1/reply-security.json"
