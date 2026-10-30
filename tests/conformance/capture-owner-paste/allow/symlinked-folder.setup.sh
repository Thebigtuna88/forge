#!/bin/bash
# The handoff folder is a link to a ready handoff elsewhere.
mkdir -p "$TMP/elsewhere" "$ROOT/work/owner"
printf '{"id": "2026-01-01-demo", "state": "ready"}\n' >"$TMP/elsewhere/META.json"
ln -s "$TMP/elsewhere" "$ROOT/work/owner/2026-01-01-demo"
