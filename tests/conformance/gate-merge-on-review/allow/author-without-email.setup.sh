# A co-author with no email on GitHub (null) is fine: there is no text to scan.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
sc_pr_edit '.commits[0].authors += [{name: "Someone", email: null}]'
