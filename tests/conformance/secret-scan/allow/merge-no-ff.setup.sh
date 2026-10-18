git -C "$ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
git -C "$ROOT" branch feature/FRG-3-git-gates
git -C "$ROOT" branch feature/FRG-3-a
git -C "$ROOT" branch feature/FRG-12-dry-run
git -C "$ROOT" update-ref refs/remotes/origin/dev HEAD
