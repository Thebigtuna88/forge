git -C "$ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
git -C "$ROOT" rev-parse HEAD >"$ROOT/.git/CHERRY_PICK_HEAD"
printf 'hello\n' >"$ROOT/notes.txt"
git -C "$ROOT" add notes.txt
printf 'FRG-9: a message\n' >"$TMP/msg"
