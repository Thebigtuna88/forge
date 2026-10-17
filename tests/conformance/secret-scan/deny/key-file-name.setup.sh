printf 'not really a key
' >"$ROOT/signing.p12"
git -C "$ROOT" add signing.p12
printf 'FRG-9: a message
' >"$TMP/msg"
