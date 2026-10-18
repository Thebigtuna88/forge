git -C "$ROOT" config remote.origin.url /nowhere.git
git -C "$ROOT" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git -C "$ROOT" config --add remote.origin.fetch '+refs/heads/dev:refs/heads/main'
