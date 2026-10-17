printf 'hello\n' >"$ROOT/notes.txt"
git -C "$ROOT" add notes.txt
printf 'token %s%s\n' "ghp_" "4Vq9TzLm2Rk8XwPn6YbJc3HdF7GsA1KeUoNi" >"$TMP/msg"
