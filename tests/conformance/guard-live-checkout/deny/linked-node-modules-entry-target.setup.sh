#!/bin/bash
# node_modules/dep in the main checkout is a link to a folder elsewhere.
mkdir -p "$TMP/outside-dep" "$ROOT/node_modules"
ln -s "$TMP/outside-dep" "$ROOT/node_modules/dep"
