git -C "$ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
git -C "$ROOT" worktree add -q -b feature/FRG-9-demo "$WORKTREES/FRG-9-demo"
git -C "$ROOT" worktree add -q -b scratch "$WORKTREES/FRG-9-scratch"
git -C "$ROOT" worktree add -q --detach "$WORKTREES/FRG-9-detached"
git -C "$ROOT" worktree add -q -b feature/FRG-9-out "$TMP/elsewhere"
git init -q -b dev "$ROOT/projects/demo"
