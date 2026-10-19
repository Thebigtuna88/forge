# Refused (review round 9): a later round's reply for the code lens is a link to nothing. A
# broken or unreadable later round still counts as one, so the older CLEAN review is stale.
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
mkdir -p "$SC_WORK/rounds/2"
ln -s missing-reply.json "$SC_WORK/rounds/2/reply-code.json"
