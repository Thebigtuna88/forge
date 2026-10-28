#!/bin/bash
# A worktree file that is a link to a main-checkout file.
mkdir -p "$WORKTREES/FRG-5-a"
ln -s "$ROOT/CLAUDE.md" "$WORKTREES/FRG-5-a/notes.txt"
