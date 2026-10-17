printf 'conf.txt -diff
' >"$ROOT/.gitattributes"
printf 'token = "%s%s"
' "ghp_" "4Vq9TzLm2Rk8XwPn6YbJc3HdF7GsA1KeUoNi" >"$ROOT/conf.txt"
git -C "$ROOT" add .gitattributes conf.txt
printf 'FRG-9: a message
' >"$TMP/msg"
