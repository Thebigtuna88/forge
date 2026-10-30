#!/bin/bash
# A worktree whose .claude folder is a link to a folder elsewhere.
mkdir -p "$TMP/outside" "$WORKTREES/FRG-5-a"
printf '{}\n' >"$TMP/outside/settings.local.json"
ln -s "$TMP/outside" "$WORKTREES/FRG-5-a/.claude"
