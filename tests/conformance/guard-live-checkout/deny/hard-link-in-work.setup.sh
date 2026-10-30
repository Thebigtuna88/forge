#!/bin/bash
# work/alias.txt is a second hard link to a main-checkout file.
printf 'a\n' >"$ROOT/notes.txt"
mkdir -p "$ROOT/work"
ln "$ROOT/notes.txt" "$ROOT/work/alias.txt"
