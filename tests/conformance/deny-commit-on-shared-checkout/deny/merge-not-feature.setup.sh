git -C "$ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
git init -q -b feature/FRG-9-solo "$WORKTREES/FRG-9-solo"
git -C "$ROOT" worktree add -q -b scratch "$WORKTREES/FRG-9-scratch"
