#!/bin/bash
# A ticket worktree with a .claude folder, as every FORGE worktree has.
mkdir -p "$WORKTREES/FRG-5-a/.claude"
printf '{}\n' >"$WORKTREES/FRG-5-a/.claude/settings.json"
