#!/bin/bash
# A main-checkout file that is a link to a file elsewhere.
printf 'x\n' >"$TMP/external.md"
ln -s "$TMP/external.md" "$ROOT/charter.md"
