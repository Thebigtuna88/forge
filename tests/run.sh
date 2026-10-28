#!/usr/bin/env bash
# Runs every FORGE test (spec 10.1). The last line is exactly "ALL PASS" or "FAILED (<n>)".
#   bash tests/run.sh               shellcheck + unit tests + conformance
#   bash tests/run.sh --templates   also scaffold and check the project templates (Phase 5)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
failures=0
templates=0
[[ "${1:-}" == "--templates" ]] && templates=1

stage() { printf '\n== %s ==\n' "$1"; }

# --- 1. shellcheck -----------------------------------------------------------------------------
stage shellcheck
shell_files=()
while IFS= read -r f; do shell_files+=("$f"); done < <(
  {
    find .harness/bin .harness/lib tests -type f \( -name '*.sh' -o -perm -u+x \) 2>/dev/null
    find .claude/hooks -type f -name '*.sh' 2>/dev/null
  } | grep -v '\.py$' | sort -u
)
if ! command -v shellcheck >/dev/null 2>&1; then
  echo "not ok shellcheck — shellcheck is not installed"
  failures=$((failures + 1))
elif shellcheck -s bash -x "${shell_files[@]}"; then
  echo "ok shellcheck (${#shell_files[@]} files)"
else
  echo "not ok shellcheck"
  failures=$((failures + 1))
fi

# --- 2. unit tests -----------------------------------------------------------------------------
stage "unit tests"
# The unit tests run hooks with this environment, and the hooks rightly refuse gh while a GH_*,
# GITHUB_*, BROWSER or PAGER variable is set (hookrt.sh). GitHub Actions sets GITHUB_* (FRG-6), so
# the tests start without them; each test that needs one sets it itself.
unit_env=(env)
for v in $(compgen -e); do
  case "$v" in GH_* | GITHUB_* | BROWSER | PAGER) unit_env+=(-u "$v") ;; esac
done
for t in tests/unit/*.test.sh; do
  rc=0
  out="$("${unit_env[@]}" bash "$t" 2>&1)" || rc=$?
  printf '%s\n' "$out"
  n="$(printf '%s\n' "$out" | grep -c '^not ok ' || true)"
  if [[ $rc -ne 0 && $n -eq 0 ]]; then
    echo "not ok $t — exited with status $rc"
    n=1
  fi
  if ! printf '%s\n' "$out" | grep -q '^ok '; then
    echo "not ok $t — produced no passing tests"
    n=$((n + 1))
  fi
  failures=$((failures + n))
done

# --- 3. conformance (spec 5.5) -----------------------------------------------------------------
stage conformance
if [[ -x .harness/bin/conformance ]]; then
  # The real run checks the real Claude Code: no test override of its version (FRG-20).
  if env -u FORGE_TEST_CLAUDE .harness/bin/conformance; then echo "ok conformance"; else
    echo "not ok conformance"
    failures=$((failures + 1))
  fi
else
  echo "not ok conformance — .harness/bin/conformance is missing or not executable"
  failures=$((failures + 1))
fi

# --- 4. templates (Phase 5) --------------------------------------------------------------------
if [[ $templates == 1 ]]; then
  stage templates
  echo "not ok templates — not built yet (Phase 5, FRG-9)"
  failures=$((failures + 1))
fi

echo
if [[ $failures -eq 0 ]]; then
  echo "ALL PASS"
  exit 0
fi
echo "FAILED ($failures)"
exit 1
