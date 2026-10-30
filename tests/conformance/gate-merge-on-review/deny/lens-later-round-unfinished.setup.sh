# Refused (FRG-7 review round 2): a later security run never finished (only its prompt is
# there), so it is the lens's latest attempt and review.md is stale.
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
mkdir -p "$SC_WORK/rounds/2"
printf 'You are an adversarial reviewer.\n' >"$SC_WORK/rounds/2/prompt-security.md"
