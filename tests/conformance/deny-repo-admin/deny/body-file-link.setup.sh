# Refused: a linked body file.
printf 'x\n' >"$TMP/real.md"
ln -s "$TMP/real.md" "$TMP/link.md"