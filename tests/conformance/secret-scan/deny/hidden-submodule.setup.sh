git -C "$ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
sha="$(git -C "$ROOT" rev-parse HEAD)"
git -C "$ROOT" update-index --add --cacheinfo "160000,$sha,sub"
git -C "$ROOT" config diff.ignoreSubmodules all
printf 'FRG-9: a message
' >"$TMP/msg"
