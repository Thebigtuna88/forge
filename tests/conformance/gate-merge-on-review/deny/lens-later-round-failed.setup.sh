# Refused (FRG-7 review round 2): a later code run failed (its reply set aside as
# reply-code.failed.json), so it is the lens's latest attempt and review.md is stale.
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
mkdir -p "$SC_WORK/rounds/2"
cp "$SC_WORK/rounds/1/reply-code.json" "$SC_WORK/rounds/2/reply-code.failed.json"
