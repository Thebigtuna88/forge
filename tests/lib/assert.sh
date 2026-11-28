# shellcheck shell=bash
# Minimal test helpers (spec 10.2). A test file defines test_* functions, then calls run_tests.
# Each test runs in its own subshell with a fresh temp folder in $T_TMP.
# Output: "ok <file>::<test>" or "not ok <file>::<test>" followed by "  # …" diagnostics.

_t_fail() {
  printf '  # %s\n' "$1"
  _T_CUR_FAILED=1
}

assert_eq() { # <actual> <expected> [message]
  [[ "$1" == "$2" ]] || _t_fail "${3:-values differ}: expected [$2] got [$1]"
}

assert_exit() { # <expected status> <actual status> [message]
  [[ "$1" == "$2" ]] || _t_fail "${3:-exit status}: expected $1 got $2"
}

assert_contains() { # <haystack> <needle> [message]
  [[ "$1" == *"$2"* ]] || _t_fail "${3:-missing text}: [$2] not in: ${1:0:600}"
}

assert_not_contains() { # <haystack> <needle> [message]
  [[ "$1" != *"$2"* ]] || _t_fail "${3:-unexpected text}: [$2] found"
}

assert_file_mode() { # <file> <octal mode>
  local mode
  mode="$(stat -f '%Lp' "$1" 2>/dev/null || echo missing)"
  [[ "$mode" == "$2" ]] || _t_fail "mode of $1: expected $2 got $mode"
}

# A test passes only if it returned, every assertion held, and its subshell then ended with status
# 0. Its result is written to a file only once it has returned: a test that crashed, or that ended
# early through an exit or an exit trap (even with status 0, as a sourced script's clean-up can),
# never writes it, and an exit trap that changes the status afterwards is caught too (FRG-26 round
# 75). A test that runs a command expecting it to fail is unaffected: only the test's own end counts.
# Known limit (round 76, C2): the test runs on the left of ||, so set -e is off inside it and a
# failing command that no assertion checks does not fail the test. A test fails through its
# assertions (each failure is kept, whatever runs after it), a crash, an early exit or its status;
# no test here relies on set -e.
run_tests() {
  local file t rc failures=0 out res got
  file="$(basename "$0" .test.sh)"
  out="$(mktemp)" || return 1 # private (mode 600), unpredictable name
  res="$(mktemp)" || return 1
  for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    : >"$res"
    (
      _T_CUR_FAILED=0
      # A test never runs without its own temp folder (it would otherwise write to /h etc.).
      T_TMP="$(mktemp -d)" && T_TMP="$(cd "$T_TMP" && pwd -P)" && [[ -d "$T_TMP" && "$T_TMP" != / ]] || {
        printf '  # could not create a temp folder for %s\n' "$t"
        exit 1
      }
      "$t" || _t_fail "$t returned non-zero"
      rc=$_T_CUR_FAILED
      rm -rf "$T_TMP"
      printf '%s\n' "$rc" >"$res"
      exit "$rc"
    ) >"$out" 2>&1
    rc=$?
    got="$(cat "$res" 2>/dev/null)"
    if [[ $rc -eq 0 && "$got" == 0 ]]; then
      printf 'ok %s::%s\n' "$file" "$t"
    else
      printf 'not ok %s::%s\n' "$file" "$t"
      grep '^  # ' "$out"
      if [[ -z "$got" ]]; then
        printf '  # crashed or exited before it returned (status %s)\n' "$rc"
      elif [[ "$got" != "$rc" ]]; then
        printf '  # ended with status %s after it returned %s (an exit trap?)\n' "$rc" "$got"
      fi
      failures=$((failures + 1))
    fi
  done
  rm -f "$out" "$res"
  [[ $failures -eq 0 ]]
}
