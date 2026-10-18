printf 'hello\n' >"$ROOT/notes.txt"
git -C "$ROOT" add notes.txt
printf 'FRG-9: a message\n' >"$TMP/msg"
git -C "$ROOT" config user.name "$(printf '%s%s' "ghp_" "4Vq9TzLm2Rk8XwPn6YbJc3HdF7GsA1KeUoNi")"
