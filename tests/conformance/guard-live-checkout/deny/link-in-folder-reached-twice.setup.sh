#!/bin/bash
# $TMP/outside is reached through two links; inside it, deep is a link to $TMP/victim.
mkdir -p "$TMP/outside" "$TMP/victim" "$ROOT/projects/p/work"
ln -s "$TMP/victim" "$TMP/outside/deep"
ln -s "$TMP/outside" "$ROOT/protected"
ln -s "$TMP/outside" "$ROOT/projects/p/work/cache"
