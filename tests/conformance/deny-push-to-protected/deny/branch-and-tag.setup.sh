git -C "$ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
git -C "$ROOT" branch feature/FRG-3-a
git -C "$ROOT" tag feature/FRG-3-a
