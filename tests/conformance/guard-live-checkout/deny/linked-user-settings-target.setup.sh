#!/bin/bash
# ~/.claude/settings.json is a link to a file elsewhere.
mkdir -p "$HOME/.claude"
printf '{}\n' >"$TMP/active.json"
ln -s "$TMP/active.json" "$HOME/.claude/settings.json"
