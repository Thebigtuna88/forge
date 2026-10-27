#!/bin/bash
# A link in the scratch folder work/ to a folder elsewhere.
mkdir -p "$TMP/scratch-elsewhere" "$ROOT/work"
ln -s "$TMP/scratch-elsewhere" "$ROOT/work/elsewhere"
