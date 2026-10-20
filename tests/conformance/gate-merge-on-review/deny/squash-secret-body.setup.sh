# Refused: a secret in the PR's body.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
sc_pr_edit '.body = ("token = " + $s)' --arg s "$(sc_secret)"
