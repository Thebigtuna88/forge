# Refused: a secret in the PR's title.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
sc_pr_edit '.title = ("FRG-9: token = " + $s)' --arg s "$(sc_secret)"
