git -C "$ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
git -C "$ROOT" tag release-1
