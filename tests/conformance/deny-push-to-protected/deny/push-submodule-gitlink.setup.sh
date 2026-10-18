git -C "$ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
sha="$(git -C "$ROOT" rev-parse HEAD)"
git -C "$ROOT" update-index --add --cacheinfo "160000,$sha,sub"
mkdir -p "$ROOT/docs"
git -C "$ROOT" config remote.origin.url /nowhere.git
git -C "$ROOT" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
