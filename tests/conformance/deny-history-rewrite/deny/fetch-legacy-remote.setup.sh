mkdir -p "$ROOT/.git/remotes"
printf 'URL: /nowhere.git
Push: refs/heads/feature/FRG-3-a:refs/heads/main
Pull: +refs/heads/main:refs/heads/dev
' >"$ROOT/.git/remotes/origin"
