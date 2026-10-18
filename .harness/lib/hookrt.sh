# shellcheck shell=bash
# shellcheck disable=SC2034 # the HR_* variables are read by the hooks that source this file
# FORGE hook runtime (spec 5.2). Every .claude/hooks/<name>.sh starts with:
#
#   #!/bin/bash -p
#   here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   unset HOOKRT_LOADED
#   # shellcheck source=.harness/lib/hookrt.sh
#   source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
#   [ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }
#
# then calls `hr_init <hook-name>` and ends every path with hr_allow or hr_deny. Claude Code
# treats any exit status other than 2 as "allow", so only an explicit hr_allow allows: errexit,
# an ERR trap inherited by command substitutions (it leaves a "failed" mark that the exit check
# reads, so even `local x="$(cmd)"` or "$(cmd)" as an argument counts), and an EXIT trap turn a
# crash, a failed command, a catchable signal, a bare `exit`, `exec` or falling off the end into a
# deny (fail closed, rule 9). So a hook puts only commands that must succeed inside $(…); an
# expected failure is tested directly (`if cmd; then …`), never inside a substitution.
# A hook uses $(…) only as the whole value of a plain assignment, `name="$(…)"`, one per line
# and not nested, never inside a condition or a && || | list, and defines no functions or { } / ( )
# groups spanning lines, where bash stops checking for errors (conformance checks its source): then a deny, an unset variable or a signal inside it fails the assignment,
# which errexit turns into a deny, where `local x="$(…)"` or an argument would hide it. `bash -p` makes bash ignore exported functions,
# BASH_ENV, SHELLOPTS and CDPATH; the runtime then clears every environment variable except
# HOME, USER, LOGNAME, TMPDIR and CLAUDE_PROJECT_DIR (no PERL5OPT, GIT_*, DEVELOPER_DIR, …) and
# sets PATH itself, system folders first. So nothing in the environment can change what jq, git,
# shasum or the runtime's own functions do. A hook whose parts have their own modes calls
# `hr_part <part>` once it knows which part applies (mode key "<hook>:<part>").
#
# A guard for git commands calls hr_require_simple (which also fills HR_TOK and HR_GIT_*) and
# then judges HR_GIT_SUB / HR_GIT_ARGS. HR_GIT_SUB is "?" when the hook cannot tell what git will
# run; a guard denies "?". HR_GIT_VIA_ALIAS=1 means the subcommand came from a git alias; a guard
# denies an alias for any subcommand it guards. HR_GIT_DIR is "" when the folder is unknown.
#
# Must stay compatible with macOS /bin/bash 3.2: no associative arrays, no mapfile, and empty
# arrays are expanded as ${a[@]+"${a[@]}"} under set -u.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "hookrt.sh: must be sourced by a hook, not executed" >&2
  exit 2
fi

set -eEu -o pipefail # pipefail: a failure anywhere in a pipeline counts

_HR_DECISION="" # "allow" only after hr_allow; anything else ends in exit 2
_HR_TMPD=""     # private folder holding the "failed" mark
_hr_on_exit() {
  local rc=$? failed=0
  set +eu
  if [[ -n "${_HR_TMPD:-}" ]]; then
    if [[ -e "$_HR_TMPD/failed" ]]; then failed=1; fi
    rm -rf "$_HR_TMPD"
  fi
  if [[ $failed == 0 && "${_HR_DECISION:-}" == allow && "$rc" == 0 ]]; then exit 0; fi
  if [[ $failed == 1 && "${_HR_DECISION:-}" != deny ]]; then
    printf 'FORGE hook %s: a command failed (perhaps inside a command substitution), so it denies, fail closed.\n' "${HR_HOOK:-?}" >&2
  elif [[ "${_HR_DECISION:-}" != deny ]]; then
    printf 'FORGE hook %s ended without a decision (status %s): denied, fail closed.\n' "${HR_HOOK:-?}" "$rc" >&2
  fi
  exit 2
}
_hr_on_err() { # runs in the hook and in every $(…) inside it
  if [[ -n "${_HR_TMPD:-}" ]]; then : >"$_HR_TMPD/failed" 2>/dev/null || true; fi
  exit 2
}
trap _hr_on_exit EXIT
trap _hr_on_err ERR
trap 'exit 2' HUP INT QUIT ILL TRAP ABRT EMT FPE BUS SEGV SYS PIPE ALRM TERM XCPU XFSZ VTALRM PROF USR1 USR2

if [[ "$-" != *p* ]]; then
  echo "FORGE hook runtime: the hook must start with #!/bin/bash -p (privileged mode, no inherited functions)" >&2
  _HR_DECISION=deny
  exit 2
fi
IFS=$' \t\n'
export LC_ALL=C
# System tools first: jq, python3, git, shasum and md5 come from root-owned /usr/bin and /sbin.
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin
export PATH
for _hr_v in $(compgen -e); do
  case "$_hr_v" in
    HOME | USER | LOGNAME | TMPDIR | CLAUDE_PROJECT_DIR | PATH | LC_ALL) ;;
    *) unset "$_hr_v" 2>/dev/null || true ;;
  esac
done
unset _hr_v
_HR_TMPD="$(mktemp -d "${TMPDIR:-/tmp}/forge-hook.XXXXXX")"
HR_TMP="$_HR_TMPD" # a private scratch folder for the hook, removed when it exits

# Replacing the shell would skip the EXIT trap, so a hook may not do it in any form: the builtin
# is switched off (so `builtin exec` and `command exec` fail) and plain `exec` explains why.
exec() {
  _hr_fatal "a hook may not use exec (it would skip the fail-closed exit check)"
}
enable -n exec

_hr_lib="${BASH_SOURCE[0]%/*}"
[[ "$_hr_lib" != "${BASH_SOURCE[0]}" ]] || _hr_lib=.
HR_ROOT="$(cd "$_hr_lib/../.." && pwd -P)"
case "${HR_ROOT%/*}" in # the main checkout's sibling, or the folder a ticket worktree sits in
  */forge-worktrees) HR_WORKTREES="${HR_ROOT%/*}" ;;
  *) HR_WORKTREES="${HR_ROOT%/*}/forge-worktrees" ;;
esac
unset _hr_lib

# All state is set here, so nothing inherited from the environment can steer the runtime.
HR_HOOK="" HR_MODE=enforce HR_INPUT="" HR_EVENT="" HR_TOOL="" HR_CMD="" HR_FILE="" HR_CWD=""
HR_TOK=() HR_GIT_ARGS=()
HR_GIT_SUB="?" HR_GIT_DIR="" HR_GIT_VIA_ALIAS=0
_HR_LOADED="" _HR_TOOLS=() _HR_GIT_CMDS="" _HR_SUBI=-1 _HR_UNKNOWABLE=0 _HR_CDS=()

# Guarded actions (spec 5.2), as words that must appear in this order (hyphens split words, so
# send-pack is "send pack"). Deploy tools come from
# .harness/deploy-targets.json ("tools") on top of this floor, so a missing file can't open them.
_HR_GUARDED_SEQS=("git push" "git commit" "git send pack" "git http push" "git rebase" "git filter branch"
  "git filter repo" "git replace" "git update ref" "git am" "git cherry pick" "git revert"
  "git checkout" "git switch" "git branch" "git worktree" "git reset" "git merge" "git pull" "git fetch"
  "git fast import" "git symbolic ref"
  "gh pr merge" "gh api" "gh repo" "gh workflow run")
# The git subcommands those name; an alias for any of them is refused (hr_require_simple).
_HR_GIT_GUARDED_SUBS=" push commit send-pack http-push rebase filter-branch filter-repo replace "
_HR_GIT_GUARDED_SUBS+="update-ref commit-tree am cherry-pick revert checkout switch branch worktree "
_HR_GIT_GUARDED_SUBS+="reset merge pull fetch fast-import symbolic-ref "
_HR_DEPLOY_FLOOR=("vercel" "fastlane" "eas" "xcrun altool")
# With `$` or a backtick the shell can build words the hook never sees, so any of these words
# in such a command makes it guarded.
_HR_DYNAMIC_WORDS=" push commit merge api repo workflow "
# Words after which the next word is still a command name.
_HR_KEYWORDS=" if then else elif do while until ! { coproc "
_HR_WRAPPERS=" env command exec nohup nice sudo doas xargs builtin eval time timeout caffeinate stdbuf
  arch xcrun script taskpolicy sandbox-exec su chroot launchctl find "
# Git global options that don't change which repository or program git uses. Anything else
# before the subcommand makes it "?".
_HR_GIT_FLAGS=" --no-pager -p -P --paginate --no-optional-locks --literal-pathspecs --no-replace-objects "
# gh's own top-level commands (gh 2.102 `gh help`). Anything else is an alias or an extension.
_HR_GH_CMDS=" agent-task alias api attestation auth browse cache codespace completion config copilot
  discussion extension gist gpg-key help issue label licenses org pr preview project release repo
  ruleset run search secret skill ssh-key status variable workflow accessibility actions
  environment exit-codes formatting mintty reference telemetry "
# git commands that never create a commit or move a branch. Any other git command (including ones
# a newer git adds) counts as guarded, so it must be one plain command and a gate decides on it.
_HR_GIT_SAFE_SUBS=" status log show diff add rm mv restore grep blame ls-files ls-tree ls-remote "
_HR_GIT_SAFE_SUBS+="rev-parse rev-list cat-file describe shortlog help version var for-each-ref show-ref "
_HR_GIT_SAFE_SUBS+="name-rev merge-base cherry whatchanged count-objects fsck check-ignore check-attr "
_HR_GIT_SAFE_SUBS+="check-ref-format check-mailmap diff-tree diff-index diff-files range-diff format-patch "
_HR_GIT_SAFE_SUBS+="archive remote tag clean gc prune repack maintenance init clone sparse-checkout "
# The word lists above are matched as " word "; a line break must count as a space too.
_HR_GH_CMDS="${_HR_GH_CMDS//$'\n'/ }"
_HR_WRAPPERS="${_HR_WRAPPERS//$'\n'/ }"
_HR_GIT_GUARDED_SUBS="${_HR_GIT_GUARDED_SUBS//$'\n'/ }"
# Characters a guarded command may not contain (spec 5.2), plus glob, brace, comment and tilde
# characters, which make the shell run words the hook never saw.
_HR_FORBIDDEN=('&' '|' ';' '<' '>' '(' ')' '$' '`' '#' '*' '?' '[' ']' '{' '}' '~' $'\n' $'\r')

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

_hr_mark_failed() { # so a deny inside a $(…) whose status is lost still denies at the end
  if [[ -n "${_HR_TMPD:-}" ]]; then : >"$_HR_TMPD/failed" 2>/dev/null || true; fi
}

_hr_fatal() { # <reason>: deny in every mode, because the hook cannot judge the command
  printf "FORGE hook %s can't judge this command, so it denies: %s\n" "${HR_HOOK:-?}" "$1" >&2
  _hr_mark_failed
  _HR_DECISION=deny
  exit 2
}

hr_allow() {
  _HR_DECISION=allow
  exit 0
}

hr_deny() { # <reason>: enforce → block with the reason; observe → log WOULD-DENY and allow
  if [[ "$HR_MODE" == observe ]]; then
    local subject="${HR_CMD:-$HR_FILE}"
    subject="${subject//$'\n'/\\n}"
    subject="${subject//$'\r'/\\r}"
    if printf '%s %s WOULD-DENY %s :: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$HR_HOOK" \
      "${1//$'\n'/ }" "$subject" 2>/dev/null >>"$HR_ROOT/.harness/observed.log"; then
      hr_allow
    fi
    _hr_fatal "observe mode, but .harness/observed.log can't be written ($1)"
  fi
  printf 'BLOCKED by FORGE hook %s: %s\n' "$HR_HOOK" "$1" >&2
  printf 'FORGE rule 9: fix the code or config through a PR; never route around a guard.\n' >&2
  _hr_mark_failed
  _HR_DECISION=deny
  exit 2
}

# --- input and mode ----------------------------------------------------------------------------

_hr_field() { # <var> <jq path>: a string field into <var> ("" if absent or null); fails otherwise
  local v
  v="$(jq -j "($2) | if . == null then \"\"
    elif type == \"string\" and (any(explode[]; . == 0) | not) then .
    else error(\"not a string\") end | . + \".\"" <<<"$HR_INPUT" 2>/dev/null || true)"
  [[ -n "$v" ]] || return 1 # the trailing "." is there on success, even for ""
  printf -v "$1" '%s' "${v%.}"
}

# Must give the same answer as mode_of in .harness/bin/conformance.
_hr_mode() { # <key>: "observe" only if mode.json is one object whose .modes[key] is exactly "observe"
  if jq -se --arg k "$1" 'length == 1 and (.[0] | type) == "object"
      and (.[0].modes | type) == "object" and .[0].modes[$k] == "observe"' \
    "$HR_ROOT/.harness/mode.json" >/dev/null 2>&1; then
    printf observe
  else
    printf enforce
  fi
}

hr_init() { # <hook-name>; reads the hook JSON on stdin
  HR_HOOK="$1"
  command -v jq >/dev/null 2>&1 || _hr_fatal "jq is not installed"
  command -v python3 >/dev/null 2>&1 || _hr_fatal "python3 is not installed"
  # Command substitution silently drops NUL bytes; turned into U+0001 instead, jq rejects them.
  HR_INPUT="$(tr '\000' '\001')" || _hr_fatal "can't read the hook input"
  jq -se 'length == 1 and (.[0] | type) == "object"' >/dev/null 2>&1 <<<"$HR_INPUT" ||
    _hr_fatal "hook input is not exactly one JSON object"
  _hr_field HR_EVENT '.hook_event_name' || _hr_fatal "bad hook_event_name in the hook input"
  _hr_field HR_TOOL '.tool_name' || _hr_fatal "bad tool_name in the hook input"
  _hr_field HR_CMD '.tool_input.command' || _hr_fatal "bad tool_input.command in the hook input"
  _hr_field HR_FILE '.tool_input.file_path' || _hr_fatal "bad tool_input.file_path in the hook input"
  [[ -n "$HR_FILE" ]] || _hr_field HR_FILE '.tool_input.notebook_path' ||
    _hr_fatal "bad tool_input.notebook_path in the hook input"
  _hr_field HR_CWD '.cwd' || _hr_fatal "bad cwd in the hook input"
  HR_MODE="$(_hr_mode "$HR_HOOK")"
}

hr_part() { # <part>: from here on the hook runs under the mode key "<hook>:<part>"
  HR_HOOK="${HR_HOOK%%:*}:$1"
  HR_MODE="$(_hr_mode "$HR_HOOK")"
}

# --- words -------------------------------------------------------------------------------------

hr_tokens() { # <text> [punct]: shell words of <text> into HR_TOK; returns 1 if quoting is broken
  # With "punct", operators (&& ; | ( ) < > &) become words of their own.
  HR_TOK=()
  local n="" t
  while IFS= read -r -d '' t; do
    if [[ -z "$n" ]]; then n="$t"; else HR_TOK+=("$t"); fi
  done < <(python3 -I -c "$_HR_PY_TOKENS" "${2:-plain}" "$1" 2>/dev/null || true)
  if [[ -z "$n" || "$n" != "${#HR_TOK[@]}" ]]; then
    HR_TOK=()
    return 1
  fi
}

_hr_lower() { # <text>: printed in lower case (ASCII)
  if [[ "$1" == *[A-Z]* ]]; then printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'; else printf '%s' "$1"; fi
}

_hr_load() { # fills _HR_TOOLS (deploy tools, lower case) and _HR_GIT_CMDS once per hook run
  if [[ -n "$_HR_LOADED" ]]; then return 0; fi
  local t
  _HR_TOOLS=()
  while IFS= read -r t; do
    if [[ -n "$t" ]]; then _HR_TOOLS+=("$(_hr_lower "$t")"); fi
  done < <(
    printf '%s\n' "${_HR_DEPLOY_FLOOR[@]}"
    jq -r '.tools[]? | strings' "$HR_ROOT/.harness/deploy-targets.json" 2>/dev/null || true
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
    if [[ "$w" == "${seq[$i]}" ]]; then i=$((i + 1)); fi
    if [[ $i -ge ${#seq[@]} ]]; then return 0; fi
  done
  return 1
}

_hr_git_builtin() { # <word>: 0 if it is one of git's own commands (call _hr_load first)
  [[ -n "$1" && "$1" != *[[:space:]]* && "$_HR_GIT_CMDS" == *" $1 "* ]]
}

# _hr_could_be_tool <command word>: 0 if the shell could turn this word into git, gh or a
# deploy tool: it contains $ or { (built by the shell), or it is a glob that matches one of them.
_hr_could_be_tool() {
  local base name
  case "$1" in *'$'* | *'{'*) return 0 ;; esac
  case "$1" in *[*?[]*) ;; *) return 1 ;; esac
  base="$(_hr_lower "${1##*/}")"
  for name in git gh "${_HR_TOOLS[@]%% *}"; do
    # shellcheck disable=SC2053 # $base is a glob pattern on purpose
    if [[ "$name" == $base ]]; then return 0; fi
  done
  return 1
}

# _hr_glob_could_be_tool <word>: 0 if the word is a glob (with at least one letter or digit, so
# not just `*`) whose last part matches git, gh or a deploy tool, or a brace expansion; such an
# argument may be run by a wrapper the runtime doesn't know (`arch -arm64 /usr/bin/g[i]t`).
_hr_glob_could_be_tool() {
  local base name brace='\{[^}]*(,|\.\.)[^}]*\}'
  if [[ "$1" =~ $brace ]]; then return 0; fi
  case "$1" in *[*?[]*) ;; *) return 1 ;; esac
  base="$(_hr_lower "${1##*/}")"
  case "$base" in *[a-z0-9]*) ;; *) return 1 ;; esac
  for name in git gh "${_HR_TOOLS[@]%% *}"; do
    # shellcheck disable=SC2053 # $base is a glob pattern on purpose
    if [[ "$name" == $base ]]; then return 0; fi
  done
  return 1
}

# _hr_git_globals <index of "git" in HR_TOK>: sets _HR_SUBI to the index of git's subcommand
# after global options, or -1 if there is none. _HR_UNKNOWABLE=1 when an option makes it
# unknowable (unknown option, -c other than color.*/core.quotepath/advice.*, missing argument). --version and --help just
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
        # Only display settings: many others run programs (core.editor, core.sshCommand, …).
        [[ $((i + 1)) -lt $n ]] || return 0
        case "$(_hr_lower "${HR_TOK[$((i + 1))]}")" in
          color.* | core.quotepath=* | advice.*) ;;
          *) return 0 ;;
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
  cmd="${cmd//\\$'\n'/}" # line continuations, removed as the shell does
  # $'…' and $"…" can spell any word or separator in escapes, so nothing below could see it.
  if [[ "$cmd" == *"\$'"* || "$cmd" == *'$"'* ]]; then return 0; fi
  # 1. The words with quotes and backslashes removed, split on anything else, lower case.
  #    Catches g"i"t p\ush, `git push`, sh -c "git push", GIT PUSH (case-insensitive disk).
  # Hyphens split words too, so git's own git-push and git-commit programs read as git push.
  read -r -a words <<<"$(printf '%s' "${cmd//[\'\"\\]/}" | LC_ALL=C tr -c 'A-Za-z0-9_.' ' ' | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  [[ ${#words[@]} -gt 0 ]] || return 1
  for seq in "${_HR_GUARDED_SEQS[@]}" "${_HR_TOOLS[@]}"; do
    if _hr_seq_in "$seq" "${words[@]}"; then return 0; fi
  done
  if [[ "$cmd" == *'$'* || "$cmd" == *'`'* ]]; then
    for w in "${words[@]}"; do
      if [[ "$_HR_DYNAMIC_WORDS" == *" $w "* ]]; then return 0; fi
      for tool in "${_HR_TOOLS[@]}"; do
        if [[ "$w" == "$tool" ]]; then return 0; fi
      done
    done
  fi
  # 2. Real shell words (newlines count as command separators):
  #    - a command name the shell builds or globs that could become git, gh or a deploy tool;
  #    - a git or gh invocation whose command is not one of their own (an alias, an extension or
  #      something unknowable).
  local -a saved=(${HR_TOK[@]+"${HR_TOK[@]}"})
  if ! hr_tokens "${cmd//$'\n'/ ; }" punct; then
    HR_TOK=(${saved[@]+"${saved[@]}"})
    for w in "${words[@]}"; do
      if [[ "$w" == git || "$w" == gh ]]; then return 0; fi
    done
    return 1
  fi
  # A guarded verb in the text makes any glob suspect, even one without letters (/tmp/bin/???),
  # since some program the runtime doesn't know may run it.
  local verbs=0
  for w in "${words[@]}"; do
    if [[ "$_HR_DYNAMIC_WORDS" == *" $w "* ]]; then verbs=1; fi
  done
  local i n=${#HR_TOK[@]} t u base rc=1 cmdpos=1 wrapped=0 skip=0 op='^[;&|()<>]+$' toolargs=0
  for ((i = 0; i < n; i++)); do
    t="${HR_TOK[$i]}"
    if [[ $skip == 1 ]]; then # the target of a redirection
      skip=0
      continue
    fi
    if [[ "$t" =~ $op ]]; then
      case "$t" in
        *'('*) # ( or <( >( : a command starts inside
          cmdpos=1
          wrapped=0
          ;;
        *'<'* | *'>'*) skip=1 ;;
        *)
          cmdpos=1
          wrapped=0
          toolargs=0
          ;;
      esac
      continue
    fi
    if [[ "$t" == '`'* ]]; then cmdpos=1; fi
    u="${t//\`/}"
    base="$(_hr_lower "${u##*/}")"
    # After gh, a word the shell expands could become its guarded subcommand (gh pr m???e →
    # gh pr merge), so the command counts as guarded. (git's subcommand is checked exactly below,
    # and any deploy tool already makes a command guarded.)
    if [[ $toolargs == 1 && "$t" == *[*?[\{\$\`]* ]]; then
      rc=0
      break
    fi
    if [[ "$base" == gh ]]; then toolargs=1; fi
    if [[ $cmdpos == 1 ]]; then
      if [[ "$u" =~ ^[0-9]+$ && $((i + 1)) -lt $n && "${HR_TOK[$((i + 1))]}" == *[\<\>]* ]]; then
        continue # a file descriptor in front of a redirection (2>f): still before the command
      elif [[ "$u" =~ ^[A-Za-z_][A-Za-z0-9_]*= || "$_HR_KEYWORDS" == *" $u "* ]]; then
        continue
      elif [[ "$_HR_WRAPPERS" == *" $base "* ]]; then
        # env, nice, xargs … take options with arguments of their own, so every later word up to
        # the next operator may be the command they run.
        wrapped=1
        cmdpos=0
        continue
      fi
      cmdpos=0
      if _hr_could_be_tool "$u"; then
        rc=0
        break
      fi
    elif [[ $wrapped == 1 ]] && _hr_could_be_tool "$u"; then
      rc=0
      break
    elif _hr_glob_could_be_tool "$u"; then
      rc=0
      break
    elif [[ $verbs == 1 && "$u" == *[*?[]* ]]; then
      rc=0
      break
    fi
    if [[ "$u" == *[[:space:]]* ]]; then
      local -a inner=("${HR_TOK[@]}")
      if hr_guarded "$u"; then rc=0; fi
      HR_TOK=("${inner[@]}")
      if [[ $rc == 0 ]]; then break; fi
    elif [[ "$base" == git ]]; then
      _hr_git_globals "$i"
      if [[ $_HR_UNKNOWABLE == 1 ]]; then
        rc=0
        break
      elif [[ $_HR_SUBI -ge 0 && "$_HR_GIT_SAFE_SUBS" != *" ${HR_TOK[$_HR_SUBI]} "* ]]; then
        rc=0 # an alias, an unknown command, or a git command that may write: guarded
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
    if [[ "$HR_CMD" == *"$c"* ]]; then
      c="${c//$'\n'/newline}"
      hr_deny "guarded command must be one plain command (no chaining, pipes, redirection, \$, globs, ~ or comments; found '${c//$'\r'/carriage return}'). Run it as its own Bash call with git -C <absolute dir>."
    fi
  done
  hr_tokens "$HR_CMD" || hr_deny "guarded command's quoting does not parse"
  first="${HR_TOK[0]:-}"
  case "$first" in
    git)
      hr_git_sub
      if [[ "$HR_GIT_SUB" == "?" ]]; then
        hr_deny "can't tell what this git command runs (unknown global option, alias.*/include.* config, or a command that isn't git's own)"
      fi
      if [[ "$HR_GIT_VIA_ALIAS" == 1 && "$_HR_GIT_GUARDED_SUBS" == *" $HR_GIT_SUB "* ]]; then
        hr_deny "git alias for a guarded command ($HR_GIT_SUB); use the command itself"
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
    if [[ "$first" == "${tool%% *}" ]]; then return 0; fi
  done
  hr_deny "a guarded command must start with the tool itself (git, gh or a deploy tool), not '$first'"
}

# --- git ---------------------------------------------------------------------------------------

_hr_git_cd() { # <-C argument>: apply it to HR_GIT_DIR ("" means unknown)
  local d="$1"
  if [[ -z "$d" ]]; then
    return 0
  elif [[ "$d" == "~"* ]]; then
    HR_GIT_DIR="" # the shell expands ~ only when unquoted, and quoting is lost here: unknown
  elif [[ "$d" == /* ]]; then
    HR_GIT_DIR="$d"
  elif [[ -n "$HR_GIT_DIR" ]]; then
    HR_GIT_DIR="${HR_GIT_DIR%/}/$d"
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
    exp="$(git -C "$HR_GIT_DIR" config --get "alias.$sub" 2>/dev/null || true)"
    [[ -n "$exp" ]] || break
    [[ "$exp" != '!'* ]] || break
    hr_tokens "$exp" && [[ ${#HR_TOK[@]} -gt 0 ]] || break
    sub="${HR_TOK[0]}"
    rest=("${HR_TOK[@]:1}" ${rest[@]+"${rest[@]}"})
    HR_GIT_VIA_ALIAS=1
  done
  HR_TOK=("${saved[@]}")
}

# --- checksums ---------------------------------------------------------------------------------

# The file is read on stdin, so a name like --help or -s is never taken for an option.
hr_md5() { # <file>: its md5 in hex; fails if the file can't be read
  local s
  [[ -f "$1" && -r "$1" ]] || return 1
  s="$(md5 -q <"$1" 2>/dev/null || true)"
  [[ -n "$s" ]] || s="$(md5sum <"$1" 2>/dev/null || true)"
  [[ -n "$s" ]] || return 1
  printf '%s\n' "${s%% *}"
}

hr_sha256() { # <file>: its sha256 in hex; fails if the file can't be read
  local s
  [[ -f "$1" && -r "$1" ]] || return 1
  s="$(shasum -a 256 <"$1" 2>/dev/null || true)"
  [[ -n "$s" ]] || return 1
  printf '%s\n' "${s%% *}"
}

HOOKRT_LOADED=1
