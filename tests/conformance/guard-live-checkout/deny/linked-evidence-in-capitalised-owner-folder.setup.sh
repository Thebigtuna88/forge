#!/bin/bash
# work/OWNER (capitals) holds an evidence file that is a link to a file elsewhere.
mkdir -p "$ROOT/work/OWNER/2026-01-01-demo"
printf 'x\n' >"$TMP/outside-evidence.txt"
ln -s "$TMP/outside-evidence.txt" "$ROOT/work/OWNER/2026-01-01-demo/PASTED-x.txt"
