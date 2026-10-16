# shellcheck shell=bash
# FORGE owner-handoff runtime (spec section 4.3).
#
# Sourced by work/owner/<id>/OWNER-RUN.sh. Every evidence line in a HANDOFF-RESULT block is
# written by a helper in this file; a script cannot write evidence itself (handoff lint).
# Must stay compatible with macOS /bin/bash 3.2: no associative arrays, no mapfile.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "handoff.sh: must be sourced by an OWNER-RUN.sh script, not executed" >&2
  exit 3
fi

_ho_refuse() {
  printf '\nHANDOFF REFUSED: %s\n' "$1" >&2
  exit 3
}

# --- Refusal checks: run by the owner, in a real terminal, outside any agent session ---------

for _ho_marker in CLAUDECODE CLAUDE_CODE_ENTRYPOINT CODEX_SANDBOX CODEX_SANDBOX_NETWORK_DISABLED; do
  if [[ -n "${!_ho_marker+set}" ]]; then
    _ho_refuse "this is an AI agent session (${_ho_marker} is set). Run the script in your own Terminal window."
  fi
done
unset _ho_marker

if [[ ! -t 0 || ! -t 1 ]]; then
  _ho_refuse "no terminal attached. Run the script in your own Terminal window."
fi

if [[ -z "${BASH_SOURCE[1]:-}" ]]; then
  _ho_refuse "handoff.sh must be sourced from an OWNER-RUN.sh script."
fi

HO_RUNTIME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
HO_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
HO_SCRIPT="$HO_DIR/$(basename "${BASH_SOURCE[1]}")"
readonly HO_RUNTIME HO_DIR HO_SCRIPT

# Steps run from / so that no command picks up a repository from wherever Terminal was opened:
# a step names its repository (--repo, git -C) and uses absolute paths.
cd / || _ho_refuse "cannot change to /"

if [[ "$(basename "$HO_SCRIPT")" != "OWNER-RUN.sh" ]]; then
  _ho_refuse "handoff.sh may only be sourced by a file named OWNER-RUN.sh."
fi

case "$-" in
  *x*) _ho_refuse "shell tracing (bash -x) is on; it would print secrets. Run: bash OWNER-RUN.sh" ;;
esac

if [[ -w "$HO_SCRIPT" ]]; then
  _ho_refuse "OWNER-RUN.sh is still writable, so it was never frozen by 'handoff ready' (or you ran it with sudo)."
fi

# --- Internal state -------------------------------------------------------------------------

_HO_ID=""
_HO_BEGUN=0
_HO_ENDED=0
_HO_FAILED=0
_HO_NAMES=" "
_HO_LINES=()
_HO_SCRIPT_SHA=""
_HO_RUNTIME_SHA=""
_HO_AT=""
_HO_TMP="" # a secret temp file being written; removed on any exit
_HO_SECRETS=() # values collected by ho_secret_to_file in this run, kept only to redact them

_ho_sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
_ho_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Strip terminal escapes (CSI; OSC ended by BEL, ESC \ or end of line; charset), carriage-return
# overdraws and control characters from a log file, then print its last non-blank line.
_ho_last_line() {
  [[ -f "$1" ]] || return 0
  LC_ALL=C sed -e $'s|\x1b\\][^\x07\x1b]*\x07||g' -e $'s|\x1b\\][^\x07\x1b]*\x1b\\\\||g' \
    -e $'s|\x1b\\][^\x07\x1b]*$||' \
    -e $'s|\x1b\\[[0-9;?]*[ -/]*[@-~]||g' -e $'s|\x1b[()][A-Za-z0-9]||g' \
    -e $'s/\r$//' -e $'s/.*\r//' "$1" \
    | LC_ALL=C tr -d '\000-\010\013\014\016-\037' \
    | grep -v '^[[:space:]]*$' | tail -n 1
}

# One-line evidence: no newlines, no control characters, no block markers, at most 200 chars.
_ho_clean() {
  local s
  s="$(_ho_redact "$1")"
  s="$(printf '%s' "$s" | LC_ALL=C tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037')"
  while [[ "$s" == *-----* ]]; do s="${s//-----/}"; done
  s="$(printf '%s' "$s" | tr -s ' ')"
  s="${s# }"
  s="${s% }"
  # Again after normalising: removing ----- or control characters can join a split secret.
  s="$(_ho_redact "$s")"
  [[ -n "$s" ]] || s="(no output)"
  printf '%s' "${s:0:200}"
}

# Remember a secret for redaction, keeping the list longest first (so a secret that contains
# another is replaced whole).
_ho_add_secret() {
  local new=() placed=0 sec
  if [[ ${#_HO_SECRETS[@]} -gt 0 ]]; then
    for sec in "${_HO_SECRETS[@]}"; do
      if [[ $placed == 0 && ${#1} -ge ${#sec} ]]; then
        new+=("$1")
        placed=1
      fi
      new+=("$sec")
    done
  fi
  [[ $placed == 1 ]] || new+=("$1")
  _HO_SECRETS=("${new[@]}")
}

# Replace every secret collected in this run with [REDACTED].
_ho_redact() {
  local s="$1" sec
  if [[ ${#_HO_SECRETS[@]} -gt 0 ]]; then
    for sec in "${_HO_SECRETS[@]}"; do s="${s//"$sec"/[REDACTED]}"; done
  fi
  printf '%s' "$s"
}

# Replace a step's log with a redacted copy. Returns 1 if that fails (the log may still hold a
# secret), and the caller ends the run.
_ho_redact_log() {
  [[ ${#_HO_SECRETS[@]} -gt 0 ]] || return 0
  [[ -e "$1" || -L "$1" ]] || return 0
  local content
  content="$(cat "$1")" || {
    rm -f "$1"
    return 1
  }
  rm -f "$1" || return 1
  (set -C && umask 077 && _ho_redact "$content" >"$1") 2>/dev/null || return 1
}

# Run a step's command under script(1) so it keeps the terminal; builtins work too.
_ho_run() { # <log> <command…>
  local log="$1"
  shift
  # shellcheck disable=SC2016 # "$@" is expanded by the inner bash, which runs the command
  /usr/bin/script -q "$log" /bin/bash -c '"$@"' ho-step "$@"
}

_ho_record() { # <PASS|FAIL|INFO> <name> <evidence>
  _HO_LINES+=("check $2: $1 $(_ho_clean "$3")")
}

_ho_fatal() { # script bug or misuse: recorded under the reserved name "_runtime"
  printf '\n✘ %s\n' "$1" >&2
  _HO_FAILED=1
  _HO_LINES+=("check _runtime: FAIL $(_ho_clean "$1")")
  ho_end
}

_ho_need_begun() {
  if [[ "$_HO_BEGUN" != 1 ]]; then
    _ho_refuse "ho_begin must be called before any other helper."
  fi
  if [[ "$_HO_ENDED" == 1 ]]; then
    _ho_refuse "no helper may be called after ho_end."
  fi
}

_ho_new_name() {
  local name="$1"
  if [[ ! "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    _ho_fatal "invalid step name '$name' (use lowercase letters, digits and hyphens)"
  fi
  case "$_HO_NAMES" in
    *" $name "*) _ho_fatal "duplicate step name '$name'" ;;
  esac
  _HO_NAMES="$_HO_NAMES$name "
}

_ho_on_exit() {
  local rc=$?
  if [[ -n "$_HO_TMP" ]] && ! rm -f "$_HO_TMP"; then
    _HO_LINES+=("check _runtime: FAIL could not remove the temp file $_HO_TMP; it may hold the secret")
  fi
  if [[ "$_HO_BEGUN" == 1 && "$_HO_ENDED" != 1 ]]; then
    _HO_FAILED=1
    _HO_LINES+=("check _runtime: FAIL script exited with status $rc before ho_end")
    ho_end
  fi
}

# --- Public helpers -------------------------------------------------------------------------

ho_begin() { # <id>
  [[ "$_HO_BEGUN" == 0 ]] || _ho_refuse "ho_begin called twice."
  local id="${1:-}"
  if [[ "$id" != "$(basename "$HO_DIR")" ]]; then
    _ho_refuse "ho_begin id '$id' does not match the handoff folder '$(basename "$HO_DIR")'."
  fi
  _HO_ID="$id"
  _HO_AT="$(_ho_utc)" # start time: verify requires the run to start after handoff ready
  _HO_SCRIPT_SHA="$(_ho_sha256 "$HO_SCRIPT")"
  _HO_RUNTIME_SHA="$(_ho_sha256 "$HO_RUNTIME")"
  if [[ -L "$HO_DIR/logs" || -L "$HO_DIR/RESULT.txt" ]]; then
    _ho_refuse "a symlink sits where the runtime writes (logs/ or RESULT.txt); remove it first."
  fi
  if ! chmod 700 "$HO_DIR" || ! mkdir -p "$HO_DIR/logs" || ! chmod 700 "$HO_DIR/logs"; then
    _ho_refuse "could not make the handoff folder private (mode 700): $HO_DIR"
  fi
  _HO_BEGUN=1
  trap _ho_on_exit EXIT
  trap 'exit 130' INT TERM HUP # leave through the EXIT trap, so cleanup and the block still run
  local title
  title="$(sed -n 's/^# HANDOFF: //p' "$HO_SCRIPT" | head -n 1)"
  printf '══ FORGE owner handoff ══\n%s\n' "${title:-$id}"
}

ho_check() { # <name> <command…> — PASS only if the command exits 0
  _ho_need_begun
  local name="${1:-}"
  shift || true
  _ho_new_name "$name"
  [[ $# -gt 0 ]] || _ho_fatal "ho_check $name: no command given"
  local log="$HO_DIR/logs/$name.log" rc=0 last
  printf '\n▶ %s: %s\n' "$name" "$*"
  rm -f "$log"
  _ho_run "$log" "$@" || rc=$?
  _ho_redact_log "$log" || _ho_fatal "could not redact the log of step $name; it may hold a secret: $log"
  last="$(_ho_last_line "$log")"
  if [[ $rc -eq 0 ]]; then
    _ho_record PASS "$name" "$last"
    printf '  ✔ PASS\n'
    return 0
  fi
  _HO_FAILED=1
  _ho_record FAIL "$name" "exit $rc: $last"
  printf '  ✘ FAIL (exit %s)\n' "$rc"
  return 1
}

ho_info() { # <name> <command…> — recorded, never fails
  _ho_need_begun
  local name="${1:-}"
  shift || true
  _ho_new_name "$name"
  [[ $# -gt 0 ]] || _ho_fatal "ho_info $name: no command given"
  local log="$HO_DIR/logs/$name.log" rc=0 last
  printf '\n▶ %s: %s\n' "$name" "$*"
  rm -f "$log"
  _ho_run "$log" "$@" || rc=$?
  _ho_redact_log "$log" || _ho_fatal "could not redact the log of step $name; it may hold a secret: $log"
  last="$(_ho_last_line "$log")"
  if [[ $rc -ne 0 ]]; then last="exit $rc: $last"; fi
  _ho_record INFO "$name" "$last"
  printf '  ℹ INFO\n'
  return 0
}

ho_confirm() { # <name> "<question>" — PASS only if the owner types y
  _ho_need_begun
  local name="${1:-}" question="${2:-}" ans=""
  _ho_new_name "$name"
  [[ -n "$question" ]] || _ho_fatal "ho_confirm $name: no question given"
  printf '\n? %s\n' "$name"
  read -r -p "$question [y/N] " ans </dev/tty || ans=""
  case "$ans" in
    y | Y | yes | Yes | YES)
      _ho_record PASS "$name" "confirmed"
      printf '  ✔ PASS\n'
      return 0
      ;;
  esac
  _HO_FAILED=1
  _ho_record FAIL "$name" "not confirmed"
  printf '  ✘ FAIL (not confirmed)\n'
  return 1
}

ho_secret_to_file() { # <name> <VAR> <absolute file> — hidden input, mode 600, never echoed
  _ho_need_begun
  local name="${1:-}" var="${2:-}" file="${3:-}"
  _ho_new_name "$name"
  [[ "$var" =~ ^[A-Z_][A-Z0-9_]*$ ]] || _ho_fatal "ho_secret_to_file $name: invalid variable name '$var'"
  printf '\n▶ %s: store %s in %s\n' "$name" "$var" "$file"

  local why="" dir
  dir="$(dirname "$file")"
  if [[ "$file" != /* ]]; then
    why="target must be an absolute path"
  elif [[ ! -d "$dir" ]]; then
    why="directory $dir does not exist"
  elif ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    why="$file is not inside a git repository, so it cannot be proven gitignored"
  elif git -C "$dir" ls-files --error-unmatch "$file" >/dev/null 2>&1; then
    why="$file is tracked by git"
  elif ! git -C "$dir" check-ignore -q "$file"; then
    why="$file is not gitignored"
  elif [[ -L "$file" || ( -e "$file" && ! -f "$file" ) ]]; then
    why="$file exists but is not a regular file"
  fi
  if [[ -n "$why" ]]; then
    _HO_FAILED=1
    _ho_record FAIL "$name" "refused: $why"
    printf '  ✘ FAIL (%s)\n' "$why"
    return 1
  fi

  set +x # tracing is refused at startup; this only guards against a later change
  local value="" tmp
  # IFS= keeps leading and trailing spaces, so the charset check refuses them instead of trimming.
  IFS= read -r -s -p "Enter $var (input hidden): " value </dev/tty || value=""
  printf '\n' >/dev/tty
  if [[ -z "$value" ]]; then
    _HO_FAILED=1
    _ho_record FAIL "$name" "empty input; nothing stored"
    printf '  ✘ FAIL (empty input)\n'
    return 1
  fi
  # Written unquoted as VAR=value, so only characters that mean nothing to a shell or a dotenv
  # parser are accepted (API keys and tokens fit).
  if [[ ! "$value" =~ ^[A-Za-z0-9._+/=:@%,-]+$ ]]; then
    value=""
    _HO_FAILED=1
    _ho_record FAIL "$name" "refused: the value has spaces, quotes or shell characters; nothing stored"
    printf '  ✘ FAIL (unsupported characters in the value; nothing stored)\n'
    return 1
  fi
  _ho_add_secret "$value"

  # Write a private temp file next to the target (it must be gitignored too), then move it.
  local ok=1 rc=0
  tmp="$(umask 077 && mktemp "$file.ho-tmp.XXXXXX" 2>/dev/null)" || ok=0
  _HO_TMP="${tmp:-}"
  if [[ $ok == 1 ]] && ! git -C "$dir" check-ignore -q "$tmp"; then ok=0; fi
  if [[ $ok == 1 && -f "$file" ]]; then
    grep -v "^${var}=" "$file" >"$tmp" || rc=$?
    [[ $rc -le 1 ]] || ok=0
  fi
  if [[ $ok == 1 ]]; then printf '%s=%s\n' "$var" "$value" >>"$tmp" || ok=0; fi
  value=""
  unset value
  if [[ $ok == 1 ]]; then chmod 600 "$tmp" || ok=0; fi
  if [[ $ok == 1 ]]; then mv -f "$tmp" "$file" || ok=0; fi
  if [[ $ok == 1 ]]; then [[ -f "$file" && ! -e "$tmp" ]] || ok=0; fi
  if [[ -n "${tmp:-}" && -e "$tmp" ]] && ! rm -f "$tmp"; then
    _HO_FAILED=1
    _ho_record FAIL "$name" "could not remove the temp file $tmp; it may hold the secret"
    printf '  ✘ FAIL (could not remove %s)\n' "$tmp"
    return 1
  fi
  _HO_TMP=""
  if [[ $ok != 1 ]]; then
    _HO_FAILED=1
    _ho_record FAIL "$name" "could not write $file; nothing stored"
    printf '  ✘ FAIL (could not write %s)\n' "$file"
    return 1
  fi
  _ho_record PASS "$name" "stored $var in $file (mode 600)"
  printf '  ✔ PASS (stored, not shown)\n'
  return 0
}

ho_abort() { # stop now; the block reports result: FAILED
  _ho_need_begun
  _HO_FAILED=1
  printf '\nStopping here: a step failed.\n'
  ho_end
}

ho_end() { # print the block, save RESULT.txt, copy to clipboard, exit
  [[ "$_HO_BEGUN" == 1 ]] || _ho_refuse "ho_end called before ho_begin."
  [[ "$_HO_ENDED" == 0 ]] || return 0
  _HO_ENDED=1
  trap - EXIT
  local result=OK block
  if [[ "$_HO_FAILED" != 0 || ${#_HO_LINES[@]} -eq 0 ]]; then
    result=FAILED
  fi
  block="$(
    printf '%s\n' "----- HANDOFF-RESULT BEGIN -----" \
      "id: $_HO_ID" \
      "script-sha256: $_HO_SCRIPT_SHA" \
      "runtime-sha256: $_HO_RUNTIME_SHA" \
      "at: $_HO_AT"
    if [[ ${#_HO_LINES[@]} -gt 0 ]]; then printf '%s\n' "${_HO_LINES[@]}"; fi
    printf '%s\n' "result: $result" "----- HANDOFF-RESULT END -----"
  )"
  rm -f "$HO_DIR/RESULT.txt"
  if ! (set -C && umask 077 && printf '%s\n' "$block" >"$HO_DIR/RESULT.txt") 2>/dev/null \
    || [[ "$(cat "$HO_DIR/RESULT.txt" 2>/dev/null)" != "$block" ]]; then
    printf '\n✘ Could not save %s/RESULT.txt, so this run cannot be verified.\n' "$HO_DIR" >&2
    printf 'Nothing to paste back. Tell Claude Code the handoff could not save its result.\n' >&2
    exit 1
  fi
  printf '\n%s\n\n' "$block"
  if printf '%s\n' "$block" | pbcopy 2>/dev/null; then
    printf 'Copied to your clipboard. Paste it back into Claude Code.\n'
  else
    printf 'Select the block above, copy it, and paste it back into Claude Code.\n'
  fi
  if [[ "$result" == OK ]]; then exit 0; fi
  exit 1
}
