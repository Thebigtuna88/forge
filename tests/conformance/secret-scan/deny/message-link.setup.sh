printf 'hello
' >"$ROOT/notes.txt"
git -C "$ROOT" add notes.txt
printf 'token %s%s
' "ghp_" "4Vq9TzLm2Rk8XwPn6YbJc3HdF7GsA1KeUoNi" >"$TMP/real-msg"
ln -s "$TMP/real-msg" "$TMP/msg"
