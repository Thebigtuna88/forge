#!/bin/bash -p
# secret-scan (spec 5.3, FRG-3). A commit is allowed only as `git commit -F <message file>` (or
# --file), and only if gitleaks finds no secret in the staged changes or in the message file.
# gitleaks always uses FORGE's own rules (.harness/gitleaks.toml), never the repository's
# .gitleaks.toml, .gitleaksignore or gitleaks:allow comments; a missing gitleaks blocks. Other
# ways of making a commit (commit-tree, am, cherry-pick, revert) skip the scan, so they're refused.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init secret-scan
hr_guarded || hr_allow
hr_require_simple
[[ "${HR_TOK[0]:-}" == git ]] || hr_allow
case "$HR_GIT_SUB" in
  commit) ;;
  commit-tree | am | cherry-pick | revert)
    hr_deny "git $HR_GIT_SUB makes a commit without the secret scan; commit with: git commit -F <message file>"
    ;;
  *) hr_allow ;;
esac

message=""
if [[ ${#HR_GIT_ARGS[@]} -eq 2 && ("${HR_GIT_ARGS[0]}" == -F || "${HR_GIT_ARGS[0]}" == --file) ]]; then
  message="${HR_GIT_ARGS[1]}"
elif [[ ${#HR_GIT_ARGS[@]} -eq 1 && "${HR_GIT_ARGS[0]}" == --file=* ]]; then
  message="${HR_GIT_ARGS[0]#--file=}"
fi
[[ -n "$message" ]] ||
  hr_deny "commit only as: git commit -F <message file> (no -m, -a, --amend, --no-verify or other options)"
[[ -n "$HR_GIT_DIR" && -d "$HR_GIT_DIR" ]] ||
  hr_deny "can't tell which repository this commit is in, so it can't be scanned for secrets"
[[ "$message" == /* ]] || message="$HR_GIT_DIR/$message"
[[ -f "$message" && -r "$message" ]] ||
  hr_deny "the commit message must be a readable message file, so it can be scanned too: $message"
type -P gitleaks >/dev/null || hr_deny "gitleaks is not installed, so the commit can't be scanned for secrets"

rules="$HR_ROOT/.harness/gitleaks.toml"
if ! gitleaks git --staged --config "$rules" --gitleaks-ignore-path "$HR_TMP" --ignore-gitleaks-allow \
  --no-banner --no-color --redact --exit-code 1 "$HR_GIT_DIR" >"$HR_TMP/staged.out" 2>&1; then
  summary="$(tail -n 3 "$HR_TMP/staged.out")"
  hr_deny "gitleaks found a possible secret in the staged changes (or could not scan them): ${summary//$'\n'/ | }"
fi
if ! gitleaks dir --config "$rules" --gitleaks-ignore-path "$HR_TMP" --ignore-gitleaks-allow \
  --no-banner --no-color --redact --exit-code 1 "$message" >"$HR_TMP/message.out" 2>&1; then
  summary="$(tail -n 3 "$HR_TMP/message.out")"
  hr_deny "gitleaks found a possible secret in the commit message (or could not scan it): ${summary//$'\n'/ | }"
fi
hr_allow
