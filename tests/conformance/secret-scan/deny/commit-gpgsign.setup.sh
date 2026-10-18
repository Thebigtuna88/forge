printf 'hello\n' >"$ROOT/notes.txt"
git -C "$ROOT" add notes.txt
printf 'FRG-9: a message\n' >"$TMP/msg"
git -C "$ROOT" config commit.gpgSign true
