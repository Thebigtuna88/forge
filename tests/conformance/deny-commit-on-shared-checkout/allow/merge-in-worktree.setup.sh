git -C "$ROOT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
git -C "$ROOT" worktree add -q -b feature/FRG-9-demo "$WORKTREES/FRG-9-demo"
