# Refused: dev and the branch have two merge bases (a criss-cross), so no single diff describes the PR.
# shellcheck disable=SC2016 # jq filters are single-quoted on purpose
# shellcheck source=tests/stubs/scene.sh
source "$TMP/stubs/scene.sh"
scene_base
sc_start "$SC_BASE"
sc_put a.txt $'a\n'
a="$(sc_commit "a" "$SC_BASE")"
sc_start "$SC_BASE"
sc_put b.txt $'b\n'
b="$(sc_commit "b" "$SC_BASE")"
sc_start "$a"
sc_put b.txt $'b\n'
SC_DEV="$(sc_commit "dev: merge b" "$a" "$b")"
sc_git update-ref refs/heads/dev "$SC_DEV"
sc_start "$b"
sc_put a.txt $'a\n'
sc_put src/sample.txt $'sample\n'
scene_head "$(sc_commit "FRG-9: merge a" "$b" "$a")"
SC_MB="$a"
scene_github
