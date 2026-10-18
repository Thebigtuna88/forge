printf 'hello\n' >"$ROOT/notes.txt"
git -C "$ROOT" add notes.txt
printf 'FRG-9: a message\n' >"$TMP/msg"
git -C "$ROOT" config i18n.commitEncoding UTF-8
