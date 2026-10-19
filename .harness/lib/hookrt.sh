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
# The command Claude Code runs inherits the same environment. GIT_* variables would make it use
# another repository, index, identity or settings than the ones the gates inspect, so their names
# are kept in _HR_GIT_ENV and hr_require_simple refuses guarded git commands while any is set.
# Claude Code's own GIT_EDITOR=true (an editor that changes nothing) is the only exception.
# EMAIL and XDG_CONFIG_HOME stay, so git reads the same identity and global settings here.
# GH_* and GITHUB_* variables (GH_REPO, GH_HOST, GH_TOKEN, GITHUB_TOKEN, GH_CONFIG_DIR, …) would
# make gh act on another repository, host or login, so they are kept in _HR_GH_ENV the same way.
unset _HR_GIT_ENV _HR_GH_ENV
_HR_GIT_ENV=""
_HR_GH_ENV=""
for _hr_v in $(compgen -e); do
  case "$_hr_v" in
    HOME | USER | LOGNAME | TMPDIR | CLAUDE_PROJECT_DIR | PATH | LC_ALL | EMAIL | XDG_CONFIG_HOME) ;;
    GIT_EDITOR)
      if [[ "${GIT_EDITOR:-}" != true ]]; then _HR_GIT_ENV+=" $_hr_v"; fi
      unset "$_hr_v" 2>/dev/null || true
      ;;
    GIT_*)
      _HR_GIT_ENV+=" $_hr_v"
      unset "$_hr_v" 2>/dev/null || true
      ;;
    GH_* | GITHUB_*)
      _HR_GH_ENV+=" $_hr_v"
      unset "$_hr_v" 2>/dev/null || true
      ;;
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
# gh is judged by its real command instead (FRG-4, _hr_gh_reads below), so a word such as --repo
# in `gh issue create --repo …` doesn't make it count as `gh repo`.
_HR_GUARDED_SEQS=("git push" "git commit" "git send pack" "git http push" "git rebase" "git filter branch"
  "git filter repo" "git replace" "git update ref" "git am" "git cherry pick" "git revert"
  "git checkout" "git switch" "git branch" "git worktree" "git reset" "git merge" "git pull" "git fetch"
  "git fast import" "git symbolic ref")
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
# gh commands that only read, as "<command>:<subcommand>" ("<command>:*" for any subcommand,
# "<command>" alone when it takes none). A gh invocation that is one of these, with the two words
# written right after gh, isn't guarded, so it may sit in a pipeline. Every other gh invocation is
# guarded: one plain command, judged by deny-repo-admin. `gh auth status` isn't here, because its
# --show-token prints the login token.
_HR_GH_READS=" issue:list issue:view pr:list pr:view pr:diff pr:checks pr:status run:list run:view
  run:watch workflow:list workflow:view repo:view release:list release:view label:list search:*
  status browse "
# git commands that never create a commit or move a branch. Any other git command (including ones
# a newer git adds) counts as guarded, so it must be one plain command and a gate decides on it.
_HR_GIT_SAFE_SUBS=" status log show diff add rm mv restore grep blame ls-files ls-tree ls-remote "
_HR_GIT_SAFE_SUBS+="rev-parse rev-list cat-file describe shortlog help version var for-each-ref show-ref "
_HR_GIT_SAFE_SUBS+="name-rev merge-base cherry whatchanged count-objects fsck check-ignore check-attr "
_HR_GIT_SAFE_SUBS+="check-ref-format check-mailmap diff-tree diff-index diff-files range-diff format-patch "
_HR_GIT_SAFE_SUBS+="archive clean gc prune repack maintenance sparse-checkout "
# The word lists above are matched as " word "; a line break must count as a space too.
_HR_GH_CMDS="${_HR_GH_CMDS//$'\n'/ }"
_HR_GH_READS="${_HR_GH_READS//$'\n'/ }"
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

# _hr_word_guarded <one argument>: 0 if the argument is a command that mentions a guarded action
# (it has spaces: 'git tag -m x v1'), names one of git's own programs (…/git-stash), or is an
# option whose attached value is one of those (--exec='git tag …', -O'git tag …'): git runs some
# option values as programs, and stores others (git config) to run later. A single word is not
# read as a command otherwise, so a file such as git-message.txt is just a file.
_hr_word_guarded() {
  local w="$1" low v="" base
  case "$w" in
    *[[:space:]]*)
      if hr_guarded "$w"; then return 0; fi
      ;;
    *)
      _hr_load
      base="$(_hr_lower "${w##*/}")"
      if [[ "$base" == git-* ]] && _hr_git_builtin "${base#git-}"; then return 0; fi
      for v in "${_HR_TOOLS[@]}"; do
        if [[ "$base" == "$v" ]]; then return 0; fi
      done
      v=""
      ;;
  esac
  case "$w" in
    --*=*) v="${w#*=}" ;;
    -[!-]*)
      low="$(_hr_lower "$w")"
      if [[ "$low" == *git* ]]; then
        v="git${low#*git}"
      elif [[ "$low" == *gh* ]]; then
        v="gh${low#*gh}"
      fi
      ;;
  esac
  [[ -n "$v" ]] && _hr_word_guarded "$v"
}

# _hr_git_path <text>: 0 if the text names a .git path component anywhere: alone, after / = : or
# a space, or attached to an option (-o.git/x, -xC.git, --opt.git). foo.git and .gitignore don't.
_hr_git_path() {
  local low re='(^|[^a-z0-9_.-])(-+[a-z0-9]*)?[.]git($|[^a-z0-9_.-])'
  low="$(_hr_lower "$1")"
  [[ "$low" =~ $re ]]
}

# _hr_git_runs_program <git subcommand> <argument>: 0 if the argument is an option that makes this
# otherwise read-only git command run another program (any abbreviation git accepts):
# git archive --exec/--remote, git ls-remote --upload-pack/-u, git grep -O/--open-files-in-pager.
_hr_git_runs_program() {
  case "$1:$2" in
    archive:--e* | archive:--r* | ls-remote:--u* | ls-remote:-u* | ls-remote:-[!-]*u* | \
      grep:-O* | grep:-[!-]*O* | grep:--op*)
      return 0
      ;;
  esac
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

_hr_gh_reads() { # <index of a gh word in HR_TOK>: 0 if that gh invocation only reads
  local c1="${HR_TOK[$(($1 + 1))]:-}" c2="${HR_TOK[$(($1 + 2))]:-}"
  [[ "$c1" =~ ^[a-z]+(-[a-z]+)*$ && "$_HR_GH_CMDS" == *" $c1 "* ]] || return 1
  if [[ "$_HR_GH_READS" == *" $c1 "* ]]; then return 0; fi
  [[ "$c2" =~ ^[a-z]+(-[a-z]+)*$ ]] || return 1
  [[ "$_HR_GH_READS" == *" $c1:$c2 "* || "$_HR_GH_READS" == *" $c1:* "* ]]
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
  # A path into git's own files (.git/refs, .git/config, …) can move a branch with no git
  # command at all, so naming one makes a command guarded (and hr_require_simple refuses it).
  if _hr_git_path "${cmd//[\'\"\\]/}"; then return 0; fi
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
  #    - a git invocation whose command is not one of git's own (an alias or something
  #      unknowable), or that may write;
  #    - a gh invocation that isn't one of the read-only commands (_HR_GH_READS).
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
  # git's verbs count wherever they appear; gh's only as whole words, so the --repo of a read
  # such as `gh pr view 5 --repo a/b --json files | jq '.files[]'` isn't one.
  local verbs=0
  for w in "${words[@]}"; do
    case "$w" in push | commit | merge) verbs=1 ;; esac
  done
  for w in ${HR_TOK[@]+"${HR_TOK[@]}"}; do
    case "$(_hr_lower "$w")" in api | repo | workflow) verbs=1 ;; esac
  done
  local i n=${#HR_TOK[@]} t u base rc=1 cmdpos=1 wrapped=0 skip=0 op='^[;&|()<>]+$'
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
          ;;
      esac
      continue
    fi
    if [[ "$t" == '`'* ]]; then cmdpos=1; fi
    u="${t//\`/}"
    base="$(_hr_lower "${u##*/}")"
    # gh runs here, or may: in command position, after a wrapper (xargs gh), or with words after
    # it. Unless gh itself is the command and the two words after it are written out and name a
    # read-only command, the command is guarded. So a word the shell expands can't become a
    # guarded subcommand (gh pr m???e, gh pr $X); a program that runs gh can't rewrite its words
    # (xargs -I view gh repo view … runs gh repo delete; FRG-4 review round 2); and `which gh`
    # (nothing after it) stays plain.
    if [[ "$base" == gh ]] && [[ $cmdpos == 1 || $wrapped == 1 || $((i + 1)) -lt $n ]]; then
      if [[ $cmdpos != 1 ]] || ! _hr_gh_reads "$i"; then
        rc=0
        break
      fi
    fi
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
      # git's own programs (git-tag, git-remote, …) run git commands under another name.
      if _hr_could_be_tool "$u" || [[ "$base" == git-* ]]; then
        rc=0
        break
      fi
    elif [[ $wrapped == 1 ]] && { _hr_could_be_tool "$u" || [[ "$base" == git-* ]]; }; then
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
      if _hr_word_guarded "$u"; then rc=0; fi
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
      elif [[ $_HR_SUBI -ge 0 ]]; then
        # A safe command with an option that runs another program (git archive --remote=stash
        # --exec=git runs git stash) is guarded too.
        local j sub="${HR_TOK[$_HR_SUBI]}"
        for ((j = _HR_SUBI + 1; j < n; j++)); do
          if [[ "${HR_TOK[$j]}" =~ $op ]]; then break; fi
          if _hr_git_runs_program "$sub" "${HR_TOK[$j]}"; then rc=0; fi
        done
        if [[ $rc == 0 ]]; then break; fi
      fi
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
  for c in "${HR_TOK[@]}"; do
    if _hr_git_path "$c"; then
      hr_deny "commands may not touch git's own files ($c) directly; use git commands"
    fi
  done
  first="${HR_TOK[0]:-}"
  case "$first" in
    git)
      [[ -z "$_HR_GIT_ENV" ]] ||
        hr_deny "the environment sets${_HR_GIT_ENV}, so git would use another repository, index, identity or settings than the ones FORGE checks; start Claude Code without it"
      hr_git_sub
      if [[ "$HR_GIT_SUB" == "?" ]]; then
        hr_deny "can't tell what this git command runs (unknown global option, alias.*/include.* config, or a command that isn't git's own)"
      fi
      if [[ "$HR_GIT_VIA_ALIAS" == 1 && "$_HR_GIT_GUARDED_SUBS" == *" $HR_GIT_SUB "* ]]; then
        hr_deny "git alias for a guarded command ($HR_GIT_SUB); use the command itself"
      fi
      # The guarded action must be the command itself, never inside one of its arguments, and the
      # command may not run another program: the gates judge only the outer git command. The
      # arguments checked are git's global options and the subcommand's arguments as an alias
      # expands them.
      local -a whole=("${HR_TOK[@]}") check=("${HR_TOK[@]:1:$((_HR_SUBI - 1))}" ${HR_GIT_ARGS[@]+"${HR_GIT_ARGS[@]}"})
      local a
      for a in ${check[@]+"${check[@]}"}; do
        if _hr_git_path "$a"; then
          hr_deny "commands may not touch git's own files ($a) directly; use git commands"
        fi
        if _hr_git_runs_program "$HR_GIT_SUB" "$a"; then
          hr_deny "git $HR_GIT_SUB $a runs another program, which no FORGE gate can check; leave the option out"
        fi
        if _hr_word_guarded "$a"; then
          hr_deny "an argument of git $HR_GIT_SUB names a guarded action ('$a'); a guarded action runs only as its own git command"
        fi
        HR_TOK=("${whole[@]}")
      done
      HR_TOK=("${whole[@]}")
      return 0
      ;;
    gh)
      [[ "$_HR_GH_CMDS" == *" ${HR_TOK[1]:-} "* ]] ||
        hr_deny "gh alias, extension or option before the command ('${HR_TOK[1]:-}'); use gh's own command"
      [[ -z "$_HR_GH_ENV" ]] ||
        hr_deny "the environment sets${_HR_GH_ENV}, so gh could act on another repository, host or login than the one FORGE checks; start Claude Code without it"
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

# --- GitHub (FRG-4) -----------------------------------------------------------------------------

# The only repository a merge may name, until projects.json (FRG-10) adds the projects'.
HR_FORGE_REPO=Thebigtuna88/forge
HR_MERGE_FORM="gh pr merge <n> --repo $HR_FORGE_REPO --squash --match-head-commit <40-character sha>"
HR_TICKET_BRANCH='^feature/FRG-[0-9]+-[a-z0-9]+(-[a-z0-9]+)*$'
HR_PR="" HR_PR_HEAD="" HR_PR_BRANCH="" HR_PR_DEV="" HR_PR_MB="" HR_PR_DIR="" HR_SCAN=""

# hr_gh <args…>: runs gh with prompts, pager, colour and update checks off. Inside a conformance
# sandbox (this runtime itself sits at <tmp>/forge-conformance.XXXXXX/s<n>/code/forge) it runs the
# sandbox's fake gh (<tmp>/…/s<n>/stubs/gh), which answers from files the case wrote and never
# reaches GitHub. Nothing in the environment or in a real checkout can pick the fake: the runtime
# Claude Code runs lives in the folder Claude Code was started in.
hr_gh() {
  local gh
  gh="$(_hr_gh_path)"
  [[ -n "$gh" && -f "$gh" && -x "$gh" ]] || return 127
  env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 GH_NO_EXTENSION_UPDATE_NOTIFIER=1 \
    GH_SPINNER_DISABLED=1 GH_PAGER=cat NO_COLOR=1 "$gh" "$@"
}

# The fake is chosen only when the runtime sits in a sandbox-shaped folder *and* the project folder
# the hook was started for is exactly that folder, as conformance starts it. A live checkout moved
# into such a folder, with a link left where Claude Code was started, doesn't qualify: Claude
# Code's CLAUDE_PROJECT_DIR still names the folder it was started in (FRG-4 review round 1).
_hr_gh_path() { # the gh hr_gh runs: the sandbox's fake inside a conformance sandbox, else gh on PATH
  local sandbox='^/.+/forge-conformance\.[A-Za-z0-9]{6}/s[0-9]+/code/forge$'
  if [[ "$HR_ROOT" =~ $sandbox && "${CLAUDE_PROJECT_DIR:-}" == "$HR_ROOT" ]]; then
    printf '%s\n' "${HR_ROOT%/code/forge}/stubs/gh"
  else
    type -P gh || true
  fi
}

# hr_scan_text <folder>: 0 if gitleaks, with FORGE's rules (never a repository's own config,
# .gitleaksignore or gitleaks:allow comments), finds nothing in the files of <folder> and really
# read each of them. Otherwise 1, with the reason in HR_SCAN; a missing gitleaks or a failed scan
# counts as a finding. gitleaks silently skips what it takes for a binary or archive format (a
# file that starts like a PDF) and still reports success, so each file is scanned again with a
# fake token (built here, at run time) added at its end: if gitleaks doesn't find that, it didn't
# read the file, and the file can't be sent (FRG-4 review round 2).
hr_scan_text() {
  local f k=0 rc canary dir
  HR_SCAN="gitleaks is not installed"
  type -P gitleaks >/dev/null || return 1
  HR_SCAN="can't make a scratch folder for gitleaks"
  [[ -d "$HR_TMP/no-ignore" ]] || mkdir "$HR_TMP/no-ignore" || return 1
  if ! gitleaks dir --config "$HR_ROOT/.harness/gitleaks.toml" --gitleaks-ignore-path "$HR_TMP/no-ignore" \
    --ignore-gitleaks-allow --no-banner --no-color --redact --exit-code 1 "$1" >"$HR_TMP/scan.out" 2>&1; then
    HR_SCAN="$(tail -n 3 "$HR_TMP/scan.out" 2>/dev/null || true)"
    HR_SCAN="${HR_SCAN//$'\n'/ | }"
    return 1
  fi
  canary="$(printf '%s%s%s' 'ghp_' 'Zq7Lw2Xn9Rb4Tk6Vm1Pc' '8Hd3Jf5Gs0Ay2QeU')"
  for f in "$1"/*; do
    [[ -f "$f" ]] || continue
    k=$((k + 1))
    HR_SCAN="can't make a scratch folder for gitleaks"
    # A fresh folder for every file of every call: a hook may scan more than once.
    dir="$(mktemp -d "$HR_TMP/canary.XXXXXX")" || return 1
    { cat "$f" && printf '\ntoken = "%s"\n' "$canary"; } >"$dir/check" || return 1
    if gitleaks dir --config "$HR_ROOT/.harness/gitleaks.toml" --gitleaks-ignore-path "$HR_TMP/no-ignore" \
      --ignore-gitleaks-allow --no-banner --no-color --redact --exit-code 1 "$dir" \
      >"$dir.out" 2>&1; then
      rc=0
    else
      rc=$?
    fi
    if [[ $rc != 1 ]]; then
      HR_SCAN="gitleaks skipped ${f##*/} (it takes it for a binary or archive format, or failed), so it can't be checked for secrets"
      return 1
    fi
  done
  HR_SCAN=""
  return 0
}

hr_mentions_gh() { # 0 if gh is one of the command's words (quotes and backslashes removed)
  local low
  low="$(printf '%s' "${HR_CMD//[\'\"\\]/}" | LC_ALL=C tr -c 'A-Za-z0-9_.' ' ' | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  [[ " $low " == *" gh "* ]]
}

# hr_merge_form: 0 if HR_TOK is exactly HR_MERGE_FORM, setting HR_PR and HR_PR_HEAD.
hr_merge_form() {
  HR_PR="" HR_PR_HEAD=""
  [[ ${#HR_TOK[@]} -eq 9 && "${HR_TOK[0]}" == gh && "${HR_TOK[1]}" == pr && "${HR_TOK[2]}" == merge ]] || return 1
  [[ "${HR_TOK[3]}" =~ ^[1-9][0-9]{0,8}$ && "${HR_TOK[4]}" == --repo && "${HR_TOK[5]}" == "$HR_FORGE_REPO" ]] || return 1
  [[ "${HR_TOK[6]}" == --squash && "${HR_TOK[7]}" == --match-head-commit && "${HR_TOK[8]}" =~ ^[0-9a-f]{40}$ ]] || return 1
  HR_PR="${HR_TOK[3]}"
  HR_PR_HEAD="${HR_TOK[8]}"
}

# hr_merge_prepare: the facts both merge gates judge, read from GitHub and recomputed here, never
# taken from a file the agent wrote. Call after hr_merge_form. Denies unless the PR is open, merges
# into dev, comes from a ticket branch of this repository (not a fork) and has exactly HR_PR_HEAD
# as its head, and unless the merge base GitHub reports for dev...head is the one review-diff.sh
# recomputes from the local objects. Sets HR_PR_BRANCH, HR_PR_DEV (dev's tip on GitHub), HR_PR_MB
# and HR_PR_DIR (review-diff.sh's output: diff.patch, raw, iso.git), and leaves GitHub's answer
# about the PR in "$HR_TMP/pr.json".
hr_merge_prepare() {
  local pr="$HR_TMP/pr.json" cmp="$HR_TMP/compare.json" err="" got="" rc=0
  local state base branch head cross owner ghmb sha='^[0-9a-f]{40}$'
  if ! hr_gh pr view "$HR_PR" --repo "$HR_FORGE_REPO" \
    --json state,baseRefName,headRefName,headRefOid,isCrossRepository,headRepositoryOwner,title,body,commits \
    >"$pr" 2>"$HR_TMP/gh.err"; then
    err="$(head -c 200 "$HR_TMP/gh.err" | tr '\n' ' ')"
    hr_deny "can't read PR #$HR_PR from GitHub ($err); check gh auth status and try again"
  fi
  # Every answer must be exactly one JSON object: jq reads a stream, and would judge only part of
  # it otherwise (FRG-4 review round 1).
  # Types are checked before anything is turned into text, so "false" (a string) can't pass for
  # false (review round 2).
  got="$(jq -ser 'if length == 1 and (.[0] | type == "object" and (.state | type) == "string"
      and (.baseRefName | type) == "string" and (.headRefName | type) == "string"
      and (.headRefOid | type) == "string" and (.isCrossRepository | type) == "boolean"
      and (.headRepositoryOwner | type) == "object" and (.headRepositoryOwner.login | type) == "string")
      then .[0] | [.state, .baseRefName, .headRefName, .headRefOid, (.isCrossRepository | tostring),
        .headRepositoryOwner.login] | join("\u001f")
      else error("not one object of the expected shape") end' "$pr" 2>/dev/null)" ||
    hr_deny "GitHub's answer about PR #$HR_PR can't be read (not one object of the expected shape); try again"
  IFS=$'\x1f' read -r state base branch head cross owner <<<"$got"
  [[ "$state" == OPEN ]] || hr_deny "PR #$HR_PR is $state, not open"
  [[ "$base" == dev ]] || hr_deny "PR #$HR_PR merges into '$base'; a merge goes only into dev (main is the owner's)"
  [[ "$cross" == false && "$owner" == "${HR_FORGE_REPO%%/*}" ]] ||
    hr_deny "PR #$HR_PR comes from a fork or another owner's repository; merge only branches of $HR_FORGE_REPO"
  [[ "$branch" =~ $HR_TICKET_BRANCH ]] ||
    hr_deny "PR #$HR_PR's branch '$branch' is not a ticket branch (feature/<KEY>-<n>-<slug>)"
  [[ "$head" == "$HR_PR_HEAD" ]] ||
    hr_deny "PR #$HR_PR's head on GitHub is $head, not the --match-head-commit $HR_PR_HEAD; the branch moved, so review its new head"
  HR_PR_BRANCH="$branch"

  if ! hr_gh api "repos/$HR_FORGE_REPO/compare/dev...$HR_PR_HEAD" >"$cmp" 2>"$HR_TMP/gh.err"; then
    err="$(head -c 200 "$HR_TMP/gh.err" | tr '\n' ' ')"
    hr_deny "can't read dev...$HR_PR_HEAD from GitHub ($err); try again"
  fi
  got="$(jq -ser 'if length == 1 and (.[0] | type == "object" and (.base_commit.sha | type) == "string"
      and (.merge_base_commit.sha | type) == "string")
      then .[0] | [.base_commit.sha, .merge_base_commit.sha] | join(" ")
      else error("not one object of the expected shape") end' "$cmp" 2>/dev/null)" ||
    hr_deny "GitHub's comparison of dev and PR #$HR_PR can't be read; try again"
  read -r HR_PR_DEV ghmb <<<"$got"
  [[ "$HR_PR_DEV" =~ $sha && "$ghmb" =~ $sha ]] ||
    hr_deny "GitHub's comparison of dev and PR #$HR_PR has no commit ids; try again"

  # Where dev requires a merge queue, gh pr merge may turn on auto-merge or queue the PR (and the
  # queue picks the merge method) instead of squash-merging it now, so the gate stops there.
  local owner_name="${HR_FORGE_REPO%%/*}" repo_name="${HR_FORGE_REPO#*/}" mq="$HR_TMP/merge-queue.json"
  if ! hr_gh api graphql -f "query=query { repository(owner: \"$owner_name\", name: \"$repo_name\") { mergeQueue(branch: \"dev\") { id } } }" \
    >"$mq" 2>"$HR_TMP/gh.err"; then
    err="$(head -c 200 "$HR_TMP/gh.err" | tr '\n' ' ')"
    hr_deny "can't tell whether dev requires a merge queue ($err); try again"
  fi
  got="$(jq -ser 'if length == 1 and (.[0].data.repository | type) == "object"
      and (.[0].data.repository | has("mergeQueue"))
      then (.[0].data.repository.mergeQueue == null | tostring) else error("unreadable") end' "$mq" 2>/dev/null)" ||
    hr_deny "can't tell whether dev requires a merge queue (GitHub's answer can't be read); try again"
  [[ "$got" == true ]] ||
    hr_deny "dev requires a merge queue, where gh pr merge can turn on auto-merge or queue the PR instead of squash-merging it now; the owner merges"

  HR_PR_DIR="$HR_TMP/review"
  mkdir "$HR_PR_DIR"
  if /bin/bash -p "$HR_ROOT/.harness/lib/review-diff.sh" "$HR_ROOT" "$HR_PR_DEV" "$HR_PR_HEAD" "$HR_PR_DIR" \
    2>"$HR_TMP/review-diff.err"; then
    rc=0
  else
    rc=$?
  fi
  err="$(head -c 300 "$HR_TMP/review-diff.err" | tr '\n' ' ')"
  case "$rc" in
    0) ;;
    3) hr_deny "$err (dev is at $HR_PR_DEV on GitHub)" ;;
    *) hr_deny "can't recompute PR #$HR_PR's diff: $err" ;;
  esac
  HR_PR_MB="$(cat "$HR_PR_DIR/merge-base")"
  [[ "$HR_PR_MB" == "$ghmb" ]] ||
    hr_deny "GitHub's merge base of dev and PR #$HR_PR ($ghmb) is not the one recomputed here ($HR_PR_MB); run git fetch origin and try again"
}

# hr_base_blob <path> <out file>: the file at <path> in the merge base, read from review-diff's
# scratch repository (whose objects review-diff re-hashed). Fails if it isn't a file there.
hr_base_blob() {
  [[ "$(git --git-dir="$HR_PR_DIR/iso.git" cat-file -t "$HR_PR_MB:$1" 2>/dev/null || true)" == blob ]] || return 1
  git --git-dir="$HR_PR_DIR/iso.git" cat-file blob "$HR_PR_MB:$1" >"$2" 2>/dev/null
}

# Owner-only paths a diff touches. Arguments: review-diff's raw file, then one or more owner-only
# lists (JSON: {"paths": [...]}, a path ending in / covering everything under it). Each changed path
# and each list entry is compared as macOS compares names: Unicode-normalised (NFC), case-folded,
# with invisible format characters (such as zero-width joiners) dropped. A deleted path counts as
# much as an added one (renames are both), and any symlink or submodule on either side counts as
# owner-only, since it can point into an owner-only folder. Prints one line per hit; exits 1 if any,
# 3 if a list is missing or malformed, 0 if none.
_HR_PY_OWNER='
import json, sys, unicodedata

def norm(p):
    p = "".join(c for c in unicodedata.normalize("NFC", p) if unicodedata.category(c) != "Cf")
    return unicodedata.normalize("NFC", p.casefold())

raw, lists = sys.argv[1], sys.argv[2:]
entries = []
for f in lists:
    try:
        with open(f, encoding="utf-8") as fh:
            doc = json.load(fh)
    except Exception:
        print("owner-only list " + f + " is missing or not JSON")
        sys.exit(3)
    paths = doc.get("paths") if isinstance(doc, dict) else None
    if not isinstance(paths, list) or not paths or not all(isinstance(p, str) and p.strip("/") for p in paths):
        print("owner-only list " + f + " has no paths list of non-empty strings")
        sys.exit(3)
    entries.extend(norm(p) for p in paths)
parts = open(raw, "rb").read().split(b"\0")
if parts and parts[-1] == b"":
    parts.pop()
if len(parts) % 2:
    print("diff --raw output is malformed")
    sys.exit(3)
hits = []
for meta, path in zip(parts[0::2], parts[1::2]):
    fields = meta.decode("ascii", "replace").lstrip(":").split()
    name = path.decode("utf-8", "surrogateescape")
    if len(fields) < 2:
        print("diff --raw output is malformed")
        sys.exit(3)
    if {"120000", "160000"} & set(fields[:2]):
        hits.append("symlink or submodule: " + name)
        continue
    n = norm(name)
    for e in entries:
        d = e.rstrip("/")
        if n == d or n.startswith(d + "/"):
            hits.append(name)
            break
for h in hits:
    print(h)
sys.exit(1 if hits else 0)
'
hr_owner_hits() { # <raw> <list…>: prints the hits into "$HR_TMP/owner.hits"; status as above
  python3 -I -c "$_HR_PY_OWNER" "$@" >"$HR_TMP/owner.hits" 2>&1
}

hr_gh_reads() { # <index of gh in HR_TOK>: 0 if that gh invocation is one of the read-only commands
  _hr_gh_reads "$1"
}

# review.md (spec 6.6) is for people, with the facts the merge gate reads in exactly one block
# fenced by a line that is exactly ```json forge-review and a line that is exactly ```.
_HR_PY_REVIEW='
import sys
fence = chr(96) * 3
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
blocks, cur = [], None
for line in lines:
    if cur is None and line == fence + "json forge-review":
        cur = []
    elif cur is not None and line == fence:
        blocks.append("\n".join(cur))
        cur = None
    elif cur is not None:
        cur.append(line)
if cur is not None or len(blocks) != 1:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(blocks[0] + "\n")
'
hr_review_json() { # <review.md> <out.json>: 0 if review.md holds exactly one forge-review block
  python3 -I -c "$_HR_PY_REVIEW" "$1" "$2" 2>/dev/null
}

HOOKRT_LOADED=1
