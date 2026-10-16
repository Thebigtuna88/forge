# shellcheck shell=bash
# shellcheck disable=SC2034 # the HR_* variables are read by the hooks that source this file
# FORGE hook runtime (spec 5.2). Every .claude/hooks/<name>.sh starts with:
#
#   here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=.harness/lib/hookrt.sh
#   source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
#   [ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }
#
# then calls `hr_init <hook-name>` and ends every path with hr_allow or hr_deny. Claude Code
# treats any exit status other than 2 as "allow", so a hook that crashes, falls off its end or
# calls `exit` itself is turned into a deny by the EXIT trap below (fail closed, rule 9).
#
# A guard for git commands calls hr_require_simple (which also fills HR_TOK and HR_GIT_*) and
# then judges HR_GIT_SUB / HR_GIT_ARGS. HR_GIT_SUB is "?" when the hook cannot tell what git will
# run; a guard denies "?". HR_GIT_VIA_ALIAS=1 means the subcommand came from a git alias; a guard
# denies an alias for any subcommand it guards.
#
# Must stay compatible with macOS /bin/bash 3.2: no associative arrays, no mapfile, and empty
# arrays are expanded as ${a[@]+"${a[@]}"} under set -u.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "hookrt.sh: must be sourced by a hook, not executed" >&2
  exit 2
fi

set -u

_HR_DECIDED=0
_hr_on_exit() {
  local rc=$?
  [[ "$_HR_DECIDED" == 1 ]] && exit "$rc"
  printf 'FORGE hook %s ended without a decision (status %s): denied, fail closed.\n' "${HR_HOOK:-?}" "$rc" >&2
  exit 2
}
trap _hr_on_exit EXIT
trap 'exit 2' HUP INT TERM

_hr_lib="${BASH_SOURCE[0]%/*}"
[[ "$_hr_lib" == "${BASH_SOURCE[0]}" ]] && _hr_lib=.
HR_ROOT="$(cd "$_hr_lib/../.." && pwd -P)" || exit 2
HR_WORKTREES="${HR_ROOT%/*}/forge-worktrees"
HR_HOOK="" HR_MODE=enforce HR_INPUT="" HR_EVENT="" HR_TOOL="" HR_CMD="" HR_FILE="" HR_CWD=""
HR_TOK=() HR_GIT_ARGS=()
HR_GIT_SUB="?" HR_GIT_DIR="" HR_GIT_VIA_ALIAS=0
unset _hr_lib

# Guarded actions (spec 5.2), as words that must appear in this order. Deploy tools come from
# .harness/deploy-targets.json ("tools") on top of this floor, so a missing file can't open them.
_HR_GUARDED_SEQS=("git push" "git commit" "gh pr merge" "gh api" "gh repo" "gh workflow run")
_HR_DEPLOY_FLOOR=("vercel" "fastlane" "eas" "xcrun altool")
# With `$` or a backtick the shell can build words the hook never sees, so any of these words
# in such a command makes it guarded.
_HR_DYNAMIC_WORDS=" push commit merge api repo workflow "
# Git global options that don't change which repository or program git uses. Anything else
# before the subcommand makes it "?".
_HR_GIT_FLAGS=" --no-pager -p -P --paginate --no-optional-locks --literal-pathspecs --no-replace-objects "
# gh's own top-level commands (gh 2.102 `gh help`). Anything else is an alias or an extension.
_HR_GH_CMDS=" agent-task alias api attestation auth browse cache codespace completion config copilot
  discussion extension gist gpg-key help issue label licenses org pr preview project release repo
  ruleset run search secret skill ssh-key status variable workflow accessibility actions
  environment exit-codes formatting mintty reference telemetry "
# Characters a guarded command may not contain (spec 5.2), plus glob, brace and comment
# characters, which make the shell run words the hook never saw.
_HR_FORBIDDEN=('&' '|' ';' '<' '>' '(' ')' '$' '`' '#' '*' '?' '[' ']' '{' '}' $'\n' $'\r')

# Splits shell words with Python's shlex. Writes "<count>\0<word>\0…" in a single write after
# parsing, so a partial result can't be mistaken for a whole one; exits 3 if quoting is broken.
_HR_PY_TOKENS='
import os, shlex, sys
mode, text = sys.argv[1], sys.argv[2]
try:
    if mode == "punct":
        lex = shlex.shlex(text, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        words = list(lex)
    else:
        words = shlex.split(text, posix=True)
except ValueError:
    sys.exit(3)
out = str(len(words)).encode() + b"\0" + b"".join(os.fsencode(w) + b"\0" for w in words)
sys.stdout.buffer.write(out)
'

# --- decisions ---------------------------------------------------------------------------------

_hr_fatal() { # <reason>: deny in every mode, because the hook cannot judge the command
  printf 'BLOCKED by FORGE hook %s: %s\n' "${HR_HOOK:-?}" "$1" >&2
  _HR_DECIDED=1
  exit 2
}

hr_allow() {
  _HR_DECIDED=1
  exit 0
}

hr_deny() { # <reason>: enforce → block with the reason; observe → log WOULD-DENY and allow
  if [[ "$HR_MODE" == observe ]]; then
    local subject="${HR_CMD:-$HR_FILE}"
    subject="${subject//$'\n'/\\n}"
    subject="${subject//$'\r'/\\r}"
    if printf '%s %s WOULD-DENY %s :: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$HR_HOOK" \
      "${1//$'\n'/ }" "$subject" 2>/dev/null >>"$HR_ROOT/.harness/observed.log"; then
      _HR_DECIDED=1
      exit 0
    fi
    _hr_fatal "observe mode, but .harness/observed.log can't be written ($1)"
  fi
  printf 'BLOCKED by FORGE hook %s: %s\n' "$HR_HOOK" "$1" >&2
  printf 'FORGE rule 9: fix the code or config through a PR; never route around a guard.\n' >&2
  _HR_DECIDED=1
  exit 2
}

# --- input and mode ----------------------------------------------------------------------------

_hr_field() { # <var> <jq path>: a string field into <var> ("" if absent); fails on anything else
  local v
  v="$(jq -j "($2) // \"\" | if type == \"string\" and (any(explode[]; . == 0) | not)
    then . + \".\" else error(\"not a string\") end" <<<"$HR_INPUT" 2>/dev/null)" || return 1
  printf -v "$1" '%s' "${v%.}"
}

_hr_mode() { # <key>: "observe" only if mode.json validly says so for exactly this key
  local m
  m="$(jq -r --arg k "$1" '.modes[$k]' "$HR_ROOT/.harness/mode.json" 2>/dev/null)" || m=enforce
  if [[ "$m" == observe ]]; then printf observe; else printf enforce; fi
}

hr_init() { # <hook-name, or hook:part for a part with its own mode>; reads the hook JSON on stdin
  HR_HOOK="$1"
  command -v jq >/dev/null 2>&1 || _hr_fatal "jq is not installed"
  command -v python3 >/dev/null 2>&1 || _hr_fatal "python3 is not installed"
  HR_INPUT="$(cat)" || _hr_fatal "can't read the hook input"
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$HR_INPUT" || _hr_fatal "hook input is not a JSON object"
  _hr_field HR_EVENT '.hook_event_name' || _hr_fatal "bad hook_event_name in the hook input"
  _hr_field HR_TOOL '.tool_name' || _hr_fatal "bad tool_name in the hook input"
  _hr_field HR_CMD '.tool_input.command' || _hr_fatal "bad tool_input.command in the hook input"
  _hr_field HR_FILE '.tool_input.file_path // .tool_input.notebook_path' ||
    _hr_fatal "bad file path in the hook input"
  _hr_field HR_CWD '.cwd' || _hr_fatal "bad cwd in the hook input"
  HR_MODE="$(_hr_mode "$HR_HOOK")"
}

# --- words -------------------------------------------------------------------------------------

hr_tokens() { # <text> [punct]: shell words of <text> into HR_TOK; returns 1 if quoting is broken
  # With "punct", operators (&& ; | ( ) < > &) become words of their own.
  HR_TOK=()
  local n="" t
  while IFS= read -r -d '' t; do
    if [[ -z "$n" ]]; then n="$t"; else HR_TOK+=("$t"); fi
  done < <(python3 -I -c "$_HR_PY_TOKENS" "${2:-plain}" "$1" 2>/dev/null)
  if [[ -z "$n" || "$n" != "${#HR_TOK[@]}" ]]; then
    HR_TOK=()
    return 1
  fi
}

_hr_lower() { # <text>: printed in lower case (ASCII)
  if [[ "$1" == *[A-Z]* ]]; then printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'; else printf '%s' "$1"; fi
}

_hr_load() { # fills _HR_TOOLS (deploy tools, lower case) and _HR_GIT_CMDS once per hook run
  [[ -z "${_HR_LOADED:-}" ]] || return 0
  local t
  _HR_TOOLS=()
  while IFS= read -r t; do [[ -n "$t" ]] && _HR_TOOLS+=("$(_hr_lower "$t")"); done < <(
    printf '%s\n' "${_HR_DEPLOY_FLOOR[@]}"
    jq -r '.tools[]? | strings' "$HR_ROOT/.harness/deploy-targets.json" 2>/dev/null
  )
  # git's own commands; empty if git can't list them, and then every subcommand is "?".
  _HR_GIT_CMDS=" $(git --list-cmds=main 2>/dev/null | tr '\n' ' ') "
  _HR_LOADED=1
}

_hr_seq_in() { # <sequence> <words…>: 0 if the sequence's words occur in order among the words
  local -a seq
  read -r -a seq <<<"$1"
  shift
  local i=0 w
  for w in "$@"; do
    [[ "$w" == "${seq[$i]}" ]] && i=$((i + 1))
    [[ $i -ge ${#seq[@]} ]] && return 0
  done
  return 1
}

_hr_git_builtin() { # <word>: 0 if it is one of git's own commands (call _hr_load first)
  [[ -n "$1" && "$1" != *[[:space:]]* && "$_HR_GIT_CMDS" == *" $1 "* ]]
}

# _hr_git_globals <index of "git" in HR_TOK>: sets _HR_SUBI to the index of git's subcommand
# after global options, or -1 if there is none. _HR_UNKNOWABLE=1 when an option makes it
# unknowable (unknown option, -c alias.*/include.*, missing argument). --version and --help just
# print, so they end the scan with no subcommand. -C arguments are collected in _HR_CDS.
_hr_git_globals() {
  local i=$(($1 + 1)) n=${#HR_TOK[@]} t
  _HR_SUBI=-1
  _HR_UNKNOWABLE=1
  _HR_CDS=()
  while [[ $i -lt $n ]]; do
    t="${HR_TOK[$i]}"
    case "$t" in
      --version | --help | -v | -h)
        _HR_UNKNOWABLE=0
        return 0
        ;;
      -C)
        [[ $((i + 1)) -lt $n ]] || return 0
        _HR_CDS+=("${HR_TOK[$((i + 1))]}")
        i=$((i + 2))
        ;;
      -c)
        [[ $((i + 1)) -lt $n ]] || return 0
        case "$(_hr_lower "${HR_TOK[$((i + 1))]}")" in
          alias.* | include.* | includeif.*) return 0 ;;
        esac
        i=$((i + 2))
        ;;
      -*)
        [[ "$_HR_GIT_FLAGS" == *" $t "* ]] || return 0
        i=$((i + 1))
        ;;
      *)
        _HR_SUBI=$i
        _HR_UNKNOWABLE=0
        return 0
        ;;
    esac
  done
  _HR_UNKNOWABLE=0 # plain `git` with nothing after it
}

hr_guarded() { # [command]: 0 if the command mentions a guarded action (spec 5.2)
  local cmd="${1-$HR_CMD}" w seq tool
  local -a words
  _hr_load
  # 1. The words with quotes and backslashes removed, split on anything else, lower case.
  #    Catches g"i"t p\ush, `git push`, sh -c "git push", GIT PUSH (case-insensitive disk).
  read -r -a words <<<"$(printf '%s' "${cmd//[\'\"\\]/}" | LC_ALL=C tr -c 'A-Za-z0-9_.-' ' ' | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  [[ ${#words[@]} -gt 0 ]] || return 1
  for seq in "${_HR_GUARDED_SEQS[@]}" "${_HR_TOOLS[@]}"; do
    _hr_seq_in "$seq" "${words[@]}" && return 0
  done
  if [[ "$cmd" == *'$'* || "$cmd" == *'`'* ]]; then
    for w in "${words[@]}"; do
      [[ "$_HR_DYNAMIC_WORDS" == *" $w "* ]] && return 0
      for tool in "${_HR_TOOLS[@]}"; do [[ "$w" == "$tool" ]] && return 0; done
    done
  fi
  # 2. Real shell words: a git or gh invocation whose command is not one of their own is an
  #    alias, extension or something unknowable, so it counts as guarded.
  local -a saved=(${HR_TOK[@]+"${HR_TOK[@]}"})
  if ! hr_tokens "$cmd" punct; then
    HR_TOK=(${saved[@]+"${saved[@]}"})
    for w in "${words[@]}"; do [[ "$w" == git || "$w" == gh ]] && return 0; done
    return 1
  fi
  local i n=${#HR_TOK[@]} t base rc=1
  for ((i = 0; i < n; i++)); do
    t="${HR_TOK[$i]}"
    base="$(_hr_lower "${t##*/}")"
    if [[ "$t" == *[[:space:]]* ]]; then
      local -a inner=("${HR_TOK[@]}")
      if hr_guarded "$t"; then rc=0; fi
      HR_TOK=("${inner[@]}")
      [[ $rc == 0 ]] && break
    elif [[ "$base" == git ]]; then
      _hr_git_globals "$i"
      if [[ $_HR_UNKNOWABLE == 1 ]]; then
        rc=0
        break
      elif [[ $_HR_SUBI -ge 0 ]] && ! _hr_git_builtin "${HR_TOK[$_HR_SUBI]}"; then
        rc=0
        break
      fi
    elif [[ "$base" == gh && $((i + 1)) -lt $n && "$_HR_GH_CMDS" != *" ${HR_TOK[$((i + 1))]} "* ]]; then
      rc=0
      break
    fi
  done
  HR_TOK=(${saved[@]+"${saved[@]}"})
  return $rc
}

hr_require_simple() { # deny unless a guarded command is one plain command; fills HR_TOK, HR_GIT_*
  hr_guarded || return 0
  local c first tool
  _hr_load
  for c in "${_HR_FORBIDDEN[@]}"; do
    [[ "$HR_CMD" == *"$c"* ]] &&
      hr_deny "guarded command must be one plain command (no chaining, pipes, redirection, \$, globs or comments; found '${c//$'\n'/newline}'). Run it as its own Bash call with git -C <dir>."
  done
  local tilde='~([^/]|$)'
  [[ "$HR_CMD" =~ $tilde ]] && hr_deny "guarded command may use ~ only as ~/"
  hr_tokens "$HR_CMD" || hr_deny "guarded command's quoting does not parse"
  first="${HR_TOK[0]:-}"
  case "$first" in
    git)
      hr_git_sub
      [[ "$HR_GIT_SUB" == "?" ]] &&
        hr_deny "can't tell what this git command runs (unknown global option, alias.*/include.* config, or a command that isn't git's own)"
      if [[ "$HR_GIT_VIA_ALIAS" == 1 ]]; then
        case "$HR_GIT_SUB" in
          push | commit) hr_deny "git alias for a guarded command ($HR_GIT_SUB); use the command itself" ;;
        esac
      fi
      return 0
      ;;
    gh)
      [[ "$_HR_GH_CMDS" == *" ${HR_TOK[1]:-} "* ]] ||
        hr_deny "gh alias, extension or option before the command ('${HR_TOK[1]:-}'); use gh's own command"
      return 0
      ;;
  esac
  for tool in "${_HR_TOOLS[@]}"; do
    [[ "$first" == "${tool%% *}" ]] && return 0
  done
  hr_deny "a guarded command must start with the tool itself (git, gh or a deploy tool), not '$first'"
}

# --- git ---------------------------------------------------------------------------------------

_hr_git_cd() { # <-C argument>: apply it to HR_GIT_DIR ("" means unknown)
  local d="$1"
  [[ -z "$d" ]] && return 0
  # shellcheck disable=SC2088 # a literal ~/ in the command, expanded here as the shell would
  [[ "$d" == "~/"* ]] && d="$HOME/${d#\~/}"
  if [[ "$d" == /* ]]; then
    HR_GIT_DIR="${d%/}"
  elif [[ -n "$HR_GIT_DIR" ]]; then
    HR_GIT_DIR="$HR_GIT_DIR/${d%/}"
  fi
}

hr_git_sub() { # uses HR_TOK (a git command): sets HR_GIT_SUB, HR_GIT_ARGS, HR_GIT_DIR, HR_GIT_VIA_ALIAS
  HR_GIT_SUB="?"
  HR_GIT_ARGS=()
  HR_GIT_DIR="$HR_CWD"
  HR_GIT_VIA_ALIAS=0
  [[ "${HR_TOK[0]:-}" == git ]] || return 0
  _hr_load
  _hr_git_globals 0
  local d
  for d in ${_HR_CDS[@]+"${_HR_CDS[@]}"}; do _hr_git_cd "$d"; done
  [[ $_HR_SUBI -ge 0 ]] || return 0
  local sub="${HR_TOK[$_HR_SUBI]}" exp depth
  local -a rest=("${HR_TOK[@]:$((_HR_SUBI + 1))}") saved=("${HR_TOK[@]}")
  # An alias can't shadow git's own commands; otherwise follow up to 5 aliases.
  for ((depth = 0; depth < 6; depth++)); do
    if _hr_git_builtin "$sub"; then
      HR_GIT_SUB="$sub"
      HR_GIT_ARGS=(${rest[@]+"${rest[@]}"})
      break
    fi
    [[ "$sub" =~ ^[A-Za-z0-9-]+$ && -n "$HR_GIT_DIR" ]] || break
    exp="$(git -C "$HR_GIT_DIR" config --get "alias.$sub" 2>/dev/null)" || break
    [[ "$exp" == '!'* ]] && break
    hr_tokens "$exp" && [[ ${#HR_TOK[@]} -gt 0 ]] || break
    sub="${HR_TOK[0]}"
    rest=("${HR_TOK[@]:1}" ${rest[@]+"${rest[@]}"})
    HR_GIT_VIA_ALIAS=1
  done
  HR_TOK=("${saved[@]}")
}

# --- checksums ---------------------------------------------------------------------------------

hr_md5() { md5 -q "$1" 2>/dev/null || md5sum "$1" | awk '{print $1}'; }
hr_sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

HOOKRT_LOADED=1
