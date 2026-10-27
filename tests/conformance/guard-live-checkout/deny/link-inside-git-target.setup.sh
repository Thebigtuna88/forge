#!/bin/bash
# A file inside the main checkout's .git is a link to a file elsewhere.
printf 'x\n' >"$TMP/outside-config"
ln -s "$TMP/outside-config" "$ROOT/.git/forge-linked-config"
