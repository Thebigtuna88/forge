git -C "$ROOT" init -q -b dev "$TMP/sub"
mkdir -p "$ROOT/.git/modules"
cp -R "$TMP/sub/.git" "$ROOT/.git/modules/sub"
git -C "$ROOT" config remote.origin.url /nowhere.git
git -C "$ROOT" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
