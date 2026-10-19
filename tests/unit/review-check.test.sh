#!/usr/bin/env bash
# Tests for FRG-4's review check (spec 6.6, 10.3): .harness/lib/review-diff.sh, the one diff a
# review reads and the merge gate recomputes, and the secret scan of text deny-repo-admin sends
# to GitHub where a conformance case can't hold the secret (a title is part of the command, and a
# case file with a secret in it would fail FORGE's own commit scan). The merge gates' refusals,
# case by case, are conformance cases (tests/conformance/gate-merge-on-review and
# gate-self-modification).
# shellcheck disable=SC2031 # each test sets and reads T_TMP inside its own subshell (assert.sh)
# shellcheck source=tests/lib/assert.sh
source "$(dirname "$0")/../lib/assert.sh"
# shellcheck source=tests/lib/hookfix.sh
source "$(dirname "$0")/../lib/hookfix.sh"

RD="$FORGE_SRC/.harness/lib/review-diff.sh"

g() { git -C "$T_TMP/repo" -c user.name=t -c user.email=t@example.com "$@"; }

mk_repo() { # $T_TMP/repo: dev at BASE, a ticket branch at HEAD with a text and a binary file
  git init -q -b dev "$T_TMP/repo"
  printf 'one\ntwo\n' >"$T_TMP/repo/a.txt"
  g add a.txt
  g commit -q -m base
  BASE="$(g rev-parse HEAD)"
  g checkout -q -b feature/FRG-9-x
  printf 'one\nTWO\nthree\n' >"$T_TMP/repo/a.txt"
  printf 'x\0secret-looking binary\n' >"$T_TMP/repo/b.dat"
  mkdir -p "$T_TMP/repo/sub dir"
  printf 'n\n' >"$T_TMP/repo/sub dir/ünï.txt"
  g add a.txt b.dat "sub dir"
  g commit -q -m change
  HEAD="$(g rev-parse HEAD)"
}

diff_in() { # <out folder>: run review-diff on BASE and HEAD; sets RC and ERR
  mkdir -p "$1"
  bash "$RD" "$T_TMP/repo" "$BASE" "$HEAD" "$1" 2>"$T_TMP/rd.err"
  RC=$?
  ERR="$(cat "$T_TMP/rd.err")"
}

test_diff_is_plain_and_complete() {
  mk_repo
  diff_in "$T_TMP/o"
  assert_exit 0 "$RC" "review-diff: $ERR"
  assert_eq "$(cat "$T_TMP/o/merge-base")" "$BASE" "merge base"
  local p
  p="$(cat "$T_TMP/o/diff.patch")"
  assert_contains "$p" "diff --git a/a.txt b/a.txt"
  assert_contains "$p" "+TWO"
  assert_contains "$p" "secret-looking binary" "a binary file is shown as text, not hidden"
  assert_not_contains "$p" "Binary files"
  assert_contains "$p" "index 0000000000000000000000000000000000000000.." "full object ids"
  assert_contains "$(tr '\0' '\n' <"$T_TMP/o/raw")" "b.dat"
}

test_diff_ignores_every_setting() {
  mk_repo
  diff_in "$T_TMP/clean"
  local want
  want="$(md5 -q <"$T_TMP/clean/diff.patch")"
  # Repository settings that change git diff's output, and a hostile global config.
  g config diff.noprefix true
  g config diff.mnemonicPrefix true
  g config diff.context 9
  g config diff.interHunkContext 9
  g config diff.algorithm patience
  g config diff.renames copies
  g config diff.relative true
  g config diff.external /bin/false
  g config diff.orderFile /dev/null
  g config color.ui always
  g config color.diff always
  g config core.quotepath false
  g config diff.suppressBlankEmpty true
  g config diff.indentHeuristic false
  g config diff.txt.textconv 'tr a-z A-Z'
  g config diff.txt.xfuncname '^(.*)$'
  printf '*.txt diff=txt\n*.dat -diff\n' >"$T_TMP/repo/.gitattributes"
  printf 'a.txt -diff\n' >"$T_TMP/repo/.git/info/attributes"
  g replace "$HEAD" "$BASE"
  mkdir -p "$T_TMP/home"
  printf '[diff]\n\tnoprefix = true\n\tcontext = 0\n' >"$T_TMP/home/.gitconfig"
  mkdir "$T_TMP/hostile"
  HOME="$T_TMP/home" GIT_CONFIG_PARAMETERS="'diff.context=1'" GIT_DIFF_OPTS=--unified=0 \
    GIT_EXTERNAL_DIFF=/bin/false bash "$RD" "$T_TMP/repo" "$BASE" "$HEAD" "$T_TMP/hostile" 2>"$T_TMP/rd.err"
  assert_exit 0 "$?" "review-diff under hostile settings: $(cat "$T_TMP/rd.err")"
  assert_eq "$(md5 -q <"$T_TMP/hostile/diff.patch")" "$want" "the same bytes whatever the settings"
  assert_eq "$(cat "$T_TMP/hostile/merge-base")" "$BASE"
}

test_missing_commit_says_fetch() {
  mk_repo
  HEAD=0123456789abcdef0123456789abcdef01234567
  diff_in "$T_TMP/o"
  assert_exit 3 "$RC"
  assert_contains "$ERR" "run git fetch origin first"
}

test_two_merge_bases_refused() {
  mk_repo
  g checkout -q -b side "$BASE"
  printf 's\n' >"$T_TMP/repo/s.txt"
  g add s.txt
  g commit -q -m side
  local side
  side="$(g rev-parse HEAD)"
  # dev merges side into the branch's head; "crossed" merges the head into side: two merge bases.
  g checkout -q -b merged "$HEAD"
  g merge -q --no-ff --no-edit "$side"
  g checkout -q -b crossed "$side"
  g merge -q --no-ff --no-edit "$HEAD"
  g update-ref refs/heads/dev "$(g rev-parse merged)"
  BASE="$(g rev-parse dev)"
  HEAD="$(g rev-parse crossed)"
  diff_in "$T_TMP/o"
  assert_exit 4 "$RC" "criss-cross: $ERR"
  assert_contains "$ERR" "more than one merge base"
}

test_forged_object_refused() {
  mk_repo
  local blob obj
  blob="$(g rev-parse "$HEAD:a.txt")"
  obj="$T_TMP/repo/.git/objects/${blob:0:2}/${blob:2}"
  python3 -I -c 'import sys, zlib; open(sys.argv[1], "wb").write(zlib.compress(b"blob 14\0one\nTWO\nthrEE\n"))' "$T_TMP/forged"
  chmod u+w "$obj"
  cp "$T_TMP/forged" "$obj"
  diff_in "$T_TMP/o"
  assert_exit 5 "$RC" "forged object: $ERR"
  assert_contains "$ERR" "does not match its id"
}

test_usage_errors() {
  mk_repo
  mkdir -p "$T_TMP/full"
  : >"$T_TMP/full/x"
  bash "$RD" "$T_TMP/repo" "$BASE" "$HEAD" "$T_TMP/full" 2>/dev/null
  assert_exit 1 "$?" "a folder that isn't empty"
  mkdir -p "$T_TMP/o"
  bash "$RD" "$T_TMP/repo" "${BASE:0:7}" "$HEAD" "$T_TMP/o" 2>/dev/null
  assert_exit 1 "$?" "a short sha"
  bash "$RD" "$T_TMP/nope" "$BASE" "$HEAD" "$T_TMP/o" 2>/dev/null
  assert_exit 1 "$?" "not a repository"
}

# --- deny-repo-admin: secrets in the command's own text ---------------------------------------

mk_gate() { # H: a harness holding the real deny-repo-admin, the runtime and FORGE's gitleaks rules
  mk_hook_harness
  cp "$FORGE_SRC"/.harness/lib/* "$H/.harness/lib/"
  cp "$FORGE_SRC/.harness/gitleaks.toml" "$H/.harness/"
  cp "$FORGE_SRC/.claude/hooks/deny-repo-admin.sh" "$H/.claude/hooks/"
  printf 'A clean body.\n' >"$T_TMP/body.md"
}

token_tail() { printf '%s%s' "4Vq9TzLm2Rk8XwPn6Yb" "Jc3HdF7GsA1KeUoNi"; } # after ghp_: a fake token
secret() { printf '%s%s' "ghp_" "$(token_tail)"; }                         # built at run time

test_secret_in_title_refused() {
  mk_gate
  run_hook deny-repo-admin "$(bash_input "gh issue create --title 'token = $(secret)' --body-file $T_TMP/body.md" "$T_TMP")"
  assert_exit 2 "$RC" "a secret in --title"
  assert_contains "$ERR" "possible secret in the text this gh command would send"
  run_hook deny-repo-admin "$(bash_input "gh pr edit 5 --title 'token = $(secret)'" "$T_TMP")"
  assert_exit 2 "$RC" "a secret in a PR's new title"
  run_hook deny-repo-admin "$(bash_input "gh issue create --title x --body-file $T_TMP/body.md --label $(secret)" "$T_TMP")"
  assert_exit 2 "$RC" "a secret in a label"
}

# Review round 1 (SEC-2): quotes and backslashes can split a secret in the command's text while gh
# gets it whole, so the words as the shell passes them are scanned too.
test_secret_split_by_quoting_refused() {
  mk_gate
  local tail
  tail="$(token_tail)"
  run_hook deny-repo-admin "$(bash_input "gh issue create --title 'ghp_'\"$tail\" --body-file $T_TMP/body.md" "$T_TMP")"
  assert_exit 2 "$RC" "a secret split by adjacent quotes"
  assert_contains "$ERR" "possible secret in the text this gh command would send"
  run_hook deny-repo-admin "$(bash_input "gh issue create --title ghp_\\${tail} --body-file $T_TMP/body.md" "$T_TMP")"
  assert_exit 2 "$RC" "a secret split by a backslash"
  run_hook deny-repo-admin "$(bash_input "gh pr edit 5 --add-label 'gh'p_$tail" "$T_TMP")"
  assert_exit 2 "$RC" "a secret split inside a label"
}

# Review round 2 (SEC-2): a read sends its words to GitHub too (a search query), so a gh read is
# scanned like a write, and stays allowed in a pipeline when clean.
test_secret_in_a_read_refused() {
  mk_gate
  run_hook deny-repo-admin "$(bash_input "gh search code $(secret)" "$T_TMP")"
  assert_exit 2 "$RC" "a secret in a search query"
  assert_contains "$ERR" "possible secret in the text this gh command would send"
  run_hook deny-repo-admin "$(bash_input "gh issue list --search $(secret) | head -5" "$T_TMP")"
  assert_exit 2 "$RC" "a secret in a read inside a pipeline"
  run_hook deny-repo-admin "$(bash_input "gh issue list --repo Thebigtuna88/forge --state open | head -5" "$T_TMP")"
  assert_exit 0 "$RC" "a clean read in a pipeline: $ERR"
}

# Review round 4 (SEC-2): bash joins a line that ends in a backslash to the next one, so g\
# h is gh, and a secret split the same way is whole when gh receives it.
test_secret_across_a_line_continuation_refused() {
  mk_gate
  local s nl=$'\n'
  s="$(secret)"
  run_hook deny-repo-admin "$(bash_input "g\\${nl}h search code $s" "$T_TMP")"
  assert_exit 2 "$RC" "gh spelt across a line continuation"
  assert_contains "$ERR" "possible secret in the text this gh command would send"
  run_hook deny-repo-admin "$(bash_input "gh search code ${s:0:12}\\${nl}${s:12}" "$T_TMP")"
  assert_exit 2 "$RC" "a secret split by a line continuation"
  assert_contains "$ERR" "possible secret in the text this gh command would send"
}

# Review round 2 (C1): gitleaks silently skips what it takes for a binary format (a file that
# starts like a PDF), and reports success. Text that gitleaks wouldn't really read is refused.
test_text_gitleaks_would_skip_refused() {
  mk_gate
  { printf '%%PDF-1.7\n'; printf 'token = "%s"\n' "$(secret)"; } >"$T_TMP/pdf-secret.md"
  run_hook deny-repo-admin "$(bash_input "gh issue create --title x --body-file $T_TMP/pdf-secret.md" "$T_TMP")"
  assert_exit 2 "$RC" "a secret behind a PDF header"
  assert_contains "$ERR" "could not scan it"
  printf '%%PDF-1.7\nhello\n' >"$T_TMP/pdf-clean.md"
  run_hook deny-repo-admin "$(bash_input "gh issue create --title x --body-file $T_TMP/pdf-clean.md" "$T_TMP")"
  assert_exit 2 "$RC" "a body gitleaks would skip, even without a secret"
  assert_contains "$ERR" "skipped"
}

test_clean_title_allowed() {
  mk_gate
  run_hook deny-repo-admin "$(bash_input "gh issue create --title 'FRG-30: a ticket' --body-file $T_TMP/body.md" "$T_TMP")"
  assert_exit 0 "$RC" "a clean ticket: $ERR"
}

run_tests
