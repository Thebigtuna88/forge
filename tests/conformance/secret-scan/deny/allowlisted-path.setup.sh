printf '{"token": "%s%s"}
' "ghp_" "4Vq9TzLm2Rk8XwPn6YbJc3HdF7GsA1KeUoNi" >"$ROOT/package-lock.json"
git -C "$ROOT" add package-lock.json
printf 'FRG-9: a message
' >"$TMP/msg"
