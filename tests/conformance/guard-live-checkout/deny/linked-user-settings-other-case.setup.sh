#!/bin/bash
# ~/.claude/Settings.json (capital S) is a link to a file elsewhere.
mkdir -p "$HOME/.claude"
printf '{}\n' >"$TMP/active.json"
ln -s "$TMP/active.json" "$HOME/.claude/Settings.json"
