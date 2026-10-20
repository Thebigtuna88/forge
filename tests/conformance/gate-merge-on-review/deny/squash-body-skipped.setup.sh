# Refused (review round 2): the PR body starts like a PDF, which gitleaks would silently skip.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_genuine
sc_pr_edit '.body = "%PDF-1.7\nA body gitleaks would skip."'
