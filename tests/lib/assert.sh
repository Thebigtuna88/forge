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

run_tests() {
  local file t rc failures=0 out
  file="$(basename "$0" .test.sh)"
  out="$(mktemp)" || return 1 # private (mode 600), unpredictable name
  for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    (
      _T_CUR_FAILED=0
      T_TMP="$(mktemp -d)"
      T_TMP="$(cd "$T_TMP" && pwd -P)"
      "$t" || _t_fail "$t returned non-zero"
      rc=$_T_CUR_FAILED
      rm -rf "$T_TMP"
      exit "$rc"
    ) >"$out" 2>&1
    rc=$?
    if [[ $rc -eq 0 ]]; then
      printf 'ok %s::%s\n' "$file" "$t"
    else
      printf 'not ok %s::%s\n' "$file" "$t"
      grep '^  # ' "$out" || printf '  # crashed (status %s)\n' "$rc"
      failures=$((failures + 1))
    fi
  done
  rm -f "$out"
  [[ $failures -eq 0 ]]
}
