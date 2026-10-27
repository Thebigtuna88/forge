#!/bin/bash
# A project main checkout that is a link to a folder elsewhere.
mkdir -p "$TMP/external-app/src" "$ROOT/projects"
ln -s "$TMP/external-app" "$ROOT/projects/app"
