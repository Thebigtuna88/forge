git -C "$ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
git -C "$ROOT" update-ref refs/remotes/origin/topic HEAD
git -C "$ROOT" update-ref refs/remotes/origin/feature/FRG-9-remote HEAD
git -C "$ROOT" branch feature/FRG-9-other
