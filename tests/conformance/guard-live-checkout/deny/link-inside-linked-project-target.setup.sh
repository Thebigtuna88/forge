#!/bin/bash
# projects/demo is a link to a folder elsewhere, whose src is itself a link.
mkdir -p "$TMP/outside-project" "$TMP/outside-source" "$ROOT/projects"
ln -s "$TMP/outside-source" "$TMP/outside-project/src"
ln -s "$TMP/outside-project" "$ROOT/projects/demo"
