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
# The live redaction filter every step's output passes through (FRG-14). Its sha256 is fixed
# here, so this file's runtime-sha256 in the evidence covers the filter too. ho_begin reads the
# filter once, checks that text and keeps it, and every step runs the kept text (python3 -c), so
# replacing the file afterwards changes nothing.
HO_REDACT="$(dirname "$HO_RUNTIME")/handoff_redact.py"
HO_REDACT_SHA256=cd1e8dc8609d5cc95ffc3aa13de822f8e00eacd7fd6f00cbc5a1dcf20f5e70f1
# The Python that runs it: Apple's own interpreter, found by fixed path; it and every folder above
# it must be root-owned and not writable by this user (_ho_root_only). Never the /usr/bin/python3
# shim, whose choice follows DEVELOPER_DIR.
HO_PYTHONS="/Library/Developer/CommandLineTools/usr/bin/python3 /Applications/Xcode.app/Contents/Developer/usr/bin/python3"
readonly HO_RUNTIME HO_DIR HO_SCRIPT HO_REDACT HO_REDACT_SHA256 HO_PYTHONS

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
_HO_SECRETS=() # values collected by ho_secret_to_file or loaded by ho_redact_file, kept only to redact them
_HO_REDACT_RC=0 # the live redaction filter's status for the last step
_HO_PY="" # the checked interpreter (ho_begin)
_HO_REDACT_CODE="" # the checked text of the filter (ho_begin)
_HO_SCRIPT_TEXT="" # the frozen script's text (ho_begin)
_HO_OWN_TEXT="" # the handoff's own text (_ho_build_own_text), for _ho_in_own_text

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
  s="$(_ho_redact "$1")" || s="(hidden: live redaction failed)"
  s="$(printf '%s' "$s" | LC_ALL=C tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037')"
  while [[ "$s" == *-----* ]]; do s="${s//-----/}"; done
  s="$(printf '%s' "$s" | tr -s ' ')"
  s="${s# }"
  s="${s% }"
  # Again after normalising: removing ----- or control characters can join a split secret.
  s="$(_ho_redact "$s")" || s="(hidden: live redaction failed)"
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

# Mask every known secret with [REDACTED], through the filter, so secrets that overlap are hidden
# whole (FRG-14; replacing them one at a time would leave a piece). Fails if the filter does.
_ho_redact() {
  if [[ ${#_HO_SECRETS[@]} -eq 0 ]]; then
    printf '%s' "$1"
    return 0
  fi
  _ho_masked "$1"
}

# Succeeds if the value appears anywhere in this handoff's own text (_HO_OWN_TEXT, built by
# ho_begin): the frozen script; its folder, the runtime's path, id, checksums and start time; the
# runtime's and the filter's own source (every fixed message, the [REDACTED] marker, and the
# filter text on its command line); and each step's log path. Everything the runtime prints or
# passes on a command line, apart from step output, comes from that text, so such a value could
# not be kept hidden (FRG-14).
_ho_in_own_text() { # <value>
  [[ "$_HO_OWN_TEXT" == *"$1"* ]]
}

# Build _HO_OWN_TEXT (called once by ho_begin, after the checksums and the filter are known).
_ho_build_own_text() {
  local runtime line logs=""
  runtime="$(cat "$HO_RUNTIME")" || _ho_refuse "could not read $HO_RUNTIME"
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*ho_(check|info)[[:space:]]+([a-z0-9-]+) ]]; then
      logs="$logs$HO_DIR/logs/${BASH_REMATCH[2]}.log"$'\n'
    fi
  done <<<"$_HO_SCRIPT_TEXT"
  _HO_OWN_TEXT="$_HO_SCRIPT_TEXT"$'\n'"$HO_DIR"$'\n'"$HO_RUNTIME"$'\n'"$_HO_ID $_HO_SCRIPT_SHA $_HO_RUNTIME_SHA $_HO_AT"
  _HO_OWN_TEXT="$_HO_OWN_TEXT"$'\n'"$logs$runtime"$'\n'"$_HO_REDACT_CODE"
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

# The collected secrets, one per line, then "#END", for the filter's private descriptor (printf
# is a builtin, so they are never on a command line). The filter refuses a list without "#END":
# a list cut short would leave secrets unmasked.
_ho_secret_lines() {
  if [[ ${#_HO_SECRETS[@]} -gt 0 ]]; then printf '%s\n' "${_HO_SECRETS[@]}"; fi
  printf '#END\n'
}

# Text the runtime shows that holds words from the script (step names, commands, paths, questions,
# reasons) goes through the filter too, without a log: any of them can match a known secret.
# Before ho_begin there are no secrets yet. If the filter fails, a placeholder is shown instead.
_ho_say() { # <text>
  if [[ -z "$_HO_PY" ]]; then
    printf '%s' "$1"
    return 0
  fi
  printf '%s' "$1" | "$_HO_PY" -I -c "$_HO_REDACT_CODE" - 3< <(_ho_secret_lines) && return 0
  printf '(hidden: live redaction failed)\n'
  return 1
}

# The same masking for a value used inside other output (a prompt).
_ho_masked() { # <text>
  printf '%s' "$1" | "$_HO_PY" -I -c "$_HO_REDACT_CODE" - 3< <(_ho_secret_lines)
}

_ho_banner() { # <name> <command…>
  local name="$1" text
  shift
  printf -v text '\n▶ %s: %s\n' "$name" "$*"
  _ho_say "$text" || _ho_fatal "live redaction failed for the banner of step $name"
}

# Run a step's command under script(1) so it keeps the terminal; builtins work too. Its output
# goes through the live redaction filter, which shows it and writes the log with every collected
# secret replaced (FRG-14). The secrets reach the filter through a pipe on its descriptor 3 only:
# not on a command line, and not in the step's environment or descriptors. Returns the command's
# status and sets _HO_REDACT_RC to the filter's.
_ho_run() { # <log> <command…>
  local log="$1"
  local -a st
  shift
  # shellcheck disable=SC2016 # "$@" is expanded by the inner bash, which runs the command
  /usr/bin/script -q /dev/null /bin/bash -c '"$@"' ho-step "$@" \
    | "$_HO_PY" -I -c "$_HO_REDACT_CODE" "$log" 3< <(_ho_secret_lines)
  st=("${PIPESTATUS[@]}")
  _HO_REDACT_RC="${st[1]}"
  return "${st[0]}"
}

# ho_redact_file's reader, run by the checked interpreter with the file as its argument. It prints
# "OK" and one value per line, or a single "ERR <reason>" line (never a value).
_HO_READ_VALUES='import os, re, stat, sys
p = sys.argv[1]
def refuse(why):
    sys.stdout.write("ERR " + why + "\n")
    sys.exit(0)
if os.path.realpath(p) != p:
    refuse("%s is reached through a symbolic link" % p)
try:
    fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
except OSError as e:
    refuse("%s could not be opened (%s)" % (p, e.strerror))
opened = os.fstat(fd)
if not stat.S_ISREG(opened.st_mode):
    refuse("%s is not a regular file" % p)
now = os.stat(p)
if (now.st_dev, now.st_ino) != (opened.st_dev, opened.st_ino) or os.path.realpath(p) != p:
    refuse("%s changed while it was being opened" % p)
data = b""
while True:
    chunk = os.read(fd, 65536)
    if not chunk:
        break
    data += chunk
safe = re.compile(rb"^[A-Z_][A-Z0-9_]*=([A-Za-z0-9._+/=:@%,-]{8,})$")
values = []
for no, line in enumerate(data.split(b"\n"), 1):
    if line.endswith(b"\r"):
        line = line[:-1]
    if not line.strip() or line.startswith(b"#"):
        continue
    m = safe.match(line)
    if not m:
        refuse("line %d of %s holds a value that can\x27t be hidden safely (not VAR=value, shorter than 8 characters, or characters ho_secret_to_file never stores)" % (no, p))
    values.append(m.group(1).decode())
if not values:
    refuse("no values in %s" % p)
sys.stdout.write("OK\n" + "".join(v + "\n" for v in values))'
readonly _HO_READ_VALUES

# True if the path and every folder above it, up to /, are owned by root and not writable by this
# user, so nothing this user runs can replace what the path leads to.
_ho_root_only() { # <absolute path>
  local p="$1"
  while :; do
    [[ ! -L "$p" && ! -w "$p" && "$(/usr/bin/stat -f %u "$p" 2>/dev/null)" == 0 ]] || return 1
    [[ "$p" != / ]] || return 0
    p="$(dirname "$p")"
  done
}

# After a step: if the filter failed, its output may be incomplete and the log missing, so the run
# ends FAILED (fail closed).
_ho_check_redaction() { # <name>
  if [[ "$_HO_REDACT_RC" != 0 ]]; then
    _ho_fatal "live redaction failed in step $1 (filter status $_HO_REDACT_RC); its output may be incomplete"
  fi
}

_ho_record() { # <PASS|FAIL|INFO> <name> <evidence>
  _HO_LINES+=("check $2: $1 $(_ho_clean "$3")")
}

_ho_fatal() { # script bug or misuse: recorded under the reserved name "_runtime"
  local text
  printf -v text '\n✘ %s\n' "$1"
  _ho_say "$text" >&2 || true
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
  _HO_SCRIPT_SHA="$(_ho_sha256 "$HO_SCRIPT")" || _HO_SCRIPT_SHA=""
  _HO_RUNTIME_SHA="$(_ho_sha256 "$HO_RUNTIME")" || _HO_RUNTIME_SHA=""
  if [[ ! "$_HO_SCRIPT_SHA" =~ ^[0-9a-f]{64}$ || ! "$_HO_RUNTIME_SHA" =~ ^[0-9a-f]{64}$ ]]; then
    _ho_refuse "could not compute the sha256 of the script and runtime, so this run couldn't be verified."
  fi
  local cand real
  for cand in $HO_PYTHONS; do
    real="$(/usr/bin/readlink -f "$cand" 2>/dev/null)" || real=""
    if [[ -n "$real" && -f "$real" && -x "$real" ]] && _ho_root_only "$real"; then
      _HO_PY="$real"
      break
    fi
  done
  if [[ -z "$_HO_PY" ]]; then
    _ho_refuse "no root-owned python3 from Apple's Command Line Tools or Xcode was found; the redaction filter needs one (install them with: xcode-select --install)."
  fi
  # The filter's text is read once and checked; steps run this text, not the file.
  local code="" redact_sha
  if [[ ! -L "$HO_REDACT" && -f "$HO_REDACT" ]]; then code="$(cat "$HO_REDACT")" || code=""; fi
  redact_sha="$(printf '%s\n' "$code" | shasum -a 256 | awk '{print $1}')"
  if [[ -z "$code" || "$redact_sha" != "$HO_REDACT_SHA256" ]]; then
    _ho_refuse "the redaction filter $HO_REDACT is missing or is not the reviewed one (sha256 $redact_sha), so a step could show a secret."
  fi
  _HO_REDACT_CODE="$code"
  _HO_SCRIPT_TEXT="$(cat "$HO_SCRIPT")" || _ho_refuse "could not read $HO_SCRIPT"
  _ho_build_own_text
  # Only a script that `handoff ready` froze may run: META.json must say ready and record this
  # exact script. (A draft can't be run early and its result replayed after ready.)
  local st frozen
  st="$(jq -r '.state // empty' "$HO_DIR/META.json" 2>/dev/null)" || st=""
  frozen="$(jq -r '.script_sha256 // empty' "$HO_DIR/META.json" 2>/dev/null)" || frozen=""
  # VERIFIED.txt is the record of verification, even if META.json could not be updated.
  if [[ "$st" != ready || "$frozen" != "$_HO_SCRIPT_SHA" ]] \
    || [[ -e "$HO_DIR/VERIFIED.txt" || -L "$HO_DIR/VERIFIED.txt" ]]; then
    _ho_refuse "this script is not the one 'handoff ready' froze (state '${st:-none}'), or it was already verified."
  fi
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
  _ho_banner "$name" "$@"
  rm -f "$log"
  _ho_run "$log" "$@" || rc=$?
  _ho_check_redaction "$name"
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
  _ho_banner "$name" "$@"
  rm -f "$log"
  _ho_run "$log" "$@" || rc=$?
  _ho_check_redaction "$name"
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
  local text shown
  printf -v text '\n? %s\n' "$name"
  _ho_say "$text" || _ho_fatal "live redaction failed for the question of step $name"
  shown="$(_ho_masked "$question")" || _ho_fatal "live redaction failed for the question of step $name"
  read -r -p "$shown [y/N] " ans </dev/tty || ans=""
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
  local text
  printf -v text '\n▶ %s: store %s in %s\n' "$name" "$var" "$file"
  _ho_say "$text" || _ho_fatal "live redaction failed for the banner of step $name"

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
    printf -v text '  ✘ FAIL (%s)\n' "$why"
    _ho_say "$text" || true
    return 1
  fi

  set +x # tracing is refused at startup; this only guards against a later change
  local value="" tmp shown
  shown="$(_ho_masked "$var")" || _ho_fatal "live redaction failed for the prompt of step $name"
  # IFS= keeps leading and trailing spaces, so the charset check refuses them instead of trimming.
  IFS= read -r -s -p "Enter $shown (input hidden): " value </dev/tty || value=""
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
  if _ho_in_own_text "$value"; then
    value=""
    _HO_FAILED=1
    _ho_record FAIL "$name" "refused: the value appears in this handoff's own text (its script, folder, id or checksums), where it could not be hidden; nothing stored"
    printf '  ✘ FAIL (the value appears in this handoff'"'"'s own text, where it could not be hidden; nothing stored)\n'
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
    printf -v text '  ✘ FAIL (could not remove %s)\n' "$tmp"
    _ho_say "$text" || true
    return 1
  fi
  _HO_TMP=""
  if [[ $ok != 1 ]]; then
    _HO_FAILED=1
    _ho_record FAIL "$name" "could not write $file; nothing stored"
    printf -v text '  ✘ FAIL (could not write %s)\n' "$file"
    _ho_say "$text" || true
    return 1
  fi
  _ho_record PASS "$name" "stored $var in $file (mode 600)"
  printf '  ✔ PASS (stored, not shown)\n'
  return 0
}

ho_redact_file() { # <name> <absolute file> — hide the values stored in a gitignored secrets file
  _ho_need_begun
  local name="${1:-}" file="${2:-}" text
  _ho_new_name "$name"
  printf -v text '\n▶ %s: hide the values stored in %s\n' "$name" "$file"
  _ho_say "$text" || _ho_fatal "live redaction failed for the banner of step $name"

  local why="" dir
  dir="$(dirname "$file")"
  if [[ "$file" != /* ]]; then
    why="the file must be an absolute path"
  elif [[ -L "$file" || ( -e "$file" && ! -f "$file" ) ]]; then
    why="$file is not a regular file"
  elif [[ ! -e "$file" ]]; then
    why="$file does not exist"
  elif [[ ! -r "$file" ]]; then
    why="$file is not readable"
  fi

  # The checked interpreter reads the values (_HO_READ_VALUES): it opens the file without following
  # a symlink, refuses anything but a regular file, and confirms after opening that it is still the
  # file at that path, with no symlink anywhere in the path. Git's checks below then judge that
  # same symlink-free path. Every VAR=value line must hold a value that is safe to hide: at least
  # 8 characters (a shorter one would blank out ordinary output) of the kind ho_secret_to_file
  # stores. Blank lines and comments are skipped. Nothing is hidden unless the whole file
  # qualifies and passes git's checks. The values come back through a pipe and are never shown.
  set +x # tracing is refused at startup; this only guards against a later change
  local out="" line="" value="" n=0
  local -a values=()
  if [[ -z "$why" ]]; then
    out="$("$_HO_PY" -I -c "$_HO_READ_VALUES" "$file" 2>/dev/null)" || out="ERR could not read $file"
    line="${out%%$'\n'*}"
    if [[ "$line" != OK ]]; then
      why="${line#ERR }"
      [[ -n "$why" ]] || why="could not read $file"
    else
      out="${out#OK}"
      out="${out#$'\n'}"
      while [[ -n "$out" ]]; do
        line="${out%%$'\n'*}"
        if [[ "$out" == *$'\n'* ]]; then out="${out#*$'\n'}"; else out=""; fi
        if [[ -n "$line" ]]; then values+=("$line"); fi
      done
    fi
  fi
  out=""
  line=""
  if [[ -z "$why" && ${#values[@]} -eq 0 ]]; then why="no values in $file"; fi
  if [[ -z "$why" ]]; then
    for value in "${values[@]}"; do
      if _ho_in_own_text "$value"; then
        why="a value in $file appears in this handoff's own text (its script, folder, id or checksums), where it could not be hidden"
        break
      fi
    done
    value=""
  fi
  if [[ -z "$why" ]]; then
    if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      why="$file is not inside a git repository, so it cannot be proven gitignored"
    elif git -C "$dir" ls-files --error-unmatch "$file" >/dev/null 2>&1; then
      why="$file is tracked by git"
    elif ! git -C "$dir" check-ignore -q "$file"; then
      why="$file is not gitignored"
    fi
  fi
  # Later steps may use these secrets, so if they can't be hidden the run stops here.
  if [[ -n "$why" ]]; then
    values=()
    _HO_FAILED=1
    _ho_record FAIL "$name" "refused: $why"
    printf -v text '  ✘ FAIL (%s)\n' "$why"
    _ho_say "$text" || true
    printf '\nStopping here: the values to hide could not be loaded, so no later step runs.\n'
    ho_end
  fi
  for value in "${values[@]}"; do
    _ho_add_secret "$value"
    n=$((n + 1))
  done
  values=()
  value=""
  local noun=values
  [[ $n -ne 1 ]] || noun=value
  _ho_record PASS "$name" "hiding $n $noun from $file"
  printf '  ✔ PASS (hiding %s %s, not shown)\n' "$n" "$noun"
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
  local result=OK block checks=""
  if [[ "$_HO_FAILED" != 0 || ${#_HO_LINES[@]} -eq 0 ]]; then
    result=FAILED
  fi
  # The check lines hold step names and reasons from the script as well as evidence, so all of
  # each line goes through the filter (FRG-14). A name that matches a known secret then shows as
  # [REDACTED], and verify refuses the block, which is fail closed.
  if [[ ${#_HO_LINES[@]} -gt 0 ]]; then
    checks="$(printf '%s\n' "${_HO_LINES[@]}")"
    if ! checks="$(_ho_masked "$checks")"; then
      result=FAILED
      checks="check _runtime: FAIL the result lines could not be masked, so they are not shown"
    fi
  fi
  block="$(
    printf '%s\n' "----- HANDOFF-RESULT BEGIN -----" \
      "id: $_HO_ID" \
      "script-sha256: $_HO_SCRIPT_SHA" \
      "runtime-sha256: $_HO_RUNTIME_SHA" \
      "at: $_HO_AT"
    if [[ -n "$checks" ]]; then printf '%s\n' "$checks"; fi
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
