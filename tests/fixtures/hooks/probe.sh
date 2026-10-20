#!/bin/bash -p
# Test-only hook: prints what hookrt worked out, selected by $PROBE, then allows. Lets the unit
# tests check hookrt's parsing through the same entry point a real hook uses.
probe_what="${PROBE:-}" # read before the runtime clears the environment
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init probe
case "$probe_what" in
  fields)
    printf 'event=%s|tool=%s|file=%s|cwd=%s|mode=%s|root=%s|worktrees=%s\n' \
      "$HR_EVENT" "$HR_TOOL" "$HR_FILE" "$HR_CWD" "$HR_MODE" "$HR_ROOT" "$HR_WORKTREES"
    printf 'cmd=[%s]\n' "$HR_CMD"
    ;;
  tokens)
    if hr_tokens "$HR_CMD"; then
      printf 'n=%s' "${#HR_TOK[@]}"
      for t in ${HR_TOK[@]+"${HR_TOK[@]}"}; do printf ' [%s]' "$t"; done
      printf '\n'
    else
      echo UNPARSEABLE
    fi
    ;;
  guarded)
    if hr_guarded; then echo GUARDED; else echo PLAIN; fi
    ;;
  git)
    hr_tokens "$HR_CMD" || echo UNPARSEABLE
    hr_git_sub
    printf 'sub=%s|dir=%s|alias=%s|args=' "$HR_GIT_SUB" "$HR_GIT_DIR" "$HR_GIT_VIA_ALIAS"
    for t in ${HR_GIT_ARGS[@]+"${HR_GIT_ARGS[@]}"}; do printf '[%s]' "$t"; done
    printf '\n'
    ;;
  sums)
    m="$(hr_md5 "$HR_FILE")"
    s="$(hr_sha256 "$HR_FILE")"
    printf 'md5=%s sha256=%s\n' "$m" "$s"
    ;;
  md5)
    m="$(hr_md5 "$HR_FILE")"
    printf 'md5=%s\n' "$m"
    ;;
  sha256)
    s="$(hr_sha256 "$HR_FILE")"
    printf 'sha256=%s\n' "$s"
    ;;
  deny)
    hr_deny "probe was told to deny"
    ;;
  ghpath)
    p="$(_hr_gh_path)"
    printf 'gh=%s\n' "$p"
    ;;
esac
hr_allow
