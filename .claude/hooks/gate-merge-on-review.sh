#!/bin/bash -p
# gate-merge-on-review (spec 5.3 and 6.6, FRG-4). A merge is allowed only as
#   gh pr merge <n> --repo Thebigtuna88/forge --squash --match-head-commit <40-character sha>
# and only when a finished review says every required lens is CLEAN for exactly the code being
# merged. Nothing the review file says is taken on trust:
# - From GitHub (hr_merge_prepare): the PR is open, merges into dev, comes from a ticket branch of
#   this repository, and its head is the --match-head-commit sha, which GitHub also enforces at the
#   merge. The merge base GitHub reports for dev...head must be the one recomputed locally.
# - work/<KEY>-<n>-<slug>/review.md holds the fields of spec 6.6 in one ```json forge-review
#   block. Its repository, branch, PR number, head and merge base must be this PR's, and the diff
#   review-diff.sh recomputes now must have the recorded md5 and byte count.
# - Every lens listed is known, run by codex or subagent (never author, inline or self; code only
#   by codex) and CLEAN, and its reply file rounds/<r>/reply-<lens>.json still has the recorded
#   sha256 and is itself a CLEAN reply, with no findings, for this lens and this diff's md5 and
#   bytes (read-proof, rule 4). code and security are required (FRG-7 adds the rest of spec 6.2).
# - Every deferred finding cites an issue that is open on GitHub now.
# - What GitHub may write into the squash commit (the PR's title and body as they are now, its
#   commit messages and authors) holds no secret, by gitleaks with FORGE's rules (rule 10).
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init gate-merge-on-review
hr_guarded || hr_allow
hr_require_simple
[[ "${HR_TOK[0]:-} ${HR_TOK[1]:-} ${HR_TOK[2]:-}" == "gh pr merge" ]] || hr_allow
hr_merge_form ||
  hr_deny "merge only as: $HR_MERGE_FORM (no --auto, --admin, --delete-branch, --rebase, --merge, --subject or --body)"
hr_merge_prepare

ticket="${HR_PR_BRANCH#feature/}"
work="$HR_ROOT/work/$ticket"
review="$work/review.md"
[[ ! -L "$HR_ROOT/work" && ! -L "$work" && -f "$review" && ! -L "$review" ]] ||
  hr_deny "no review for $HR_PR_BRANCH: work/$ticket/review.md is missing (review the PR first, until every required lens is CLEAN)"
hr_review_json "$review" "$HR_TMP/review.json" ||
  hr_deny "work/$ticket/review.md must hold exactly one json forge-review block with the review's facts (spec 6.6)"
jq -se 'length == 1 and (.[0] | type == "object" and .forge_review == 1 and (.repo | type) == "string" and (.branch | type) == "string" and (.pr | type) == "number" and (.head | type) == "string" and (.merge_base | type) == "string" and (.diff_md5 | type) == "string" and (.diff_bytes | type) == "number" and (.lenses | type) == "array" and (.deferred | type) == "array" and (.lenses | all(type == "object" and (.lens | type) == "string" and (.mechanism | type) == "string" and (.model | type) == "string" and (.model | length) > 0 and (.rounds | type) == "number" and .rounds >= 1 and .rounds == (.rounds | floor) and (.verdict | type) == "string" and (.reply | type) == "string" and (.reply_sha256 | type) == "string")) and (.deferred | all(type == "object" and (.finding | type) == "string" and (.issue | type) == "number" and .issue >= 1 and .issue == (.issue | floor))))' \
  "$HR_TMP/review.json" >/dev/null 2>&1 ||
  hr_deny "work/$ticket/review.md's forge-review block is malformed (spec 6.6: one JSON object with forge_review 1, repo, branch, pr, head, merge_base, diff_md5, diff_bytes, lenses and deferred)"
jq -s '.[0]' "$HR_TMP/review.json" >"$HR_TMP/review.one"
mv "$HR_TMP/review.one" "$HR_TMP/review.json"

bound="$(jq -r '[.repo, .branch, (.pr | tostring), .head, .merge_base, .diff_md5, (.diff_bytes | tostring)] | join("\u001f")' "$HR_TMP/review.json")"
IFS=$'\x1f' read -r r_repo r_branch r_pr r_head r_mb r_md5 r_bytes <<<"$bound"
[[ "$r_repo" == "$HR_FORGE_REPO" && "$r_branch" == "$HR_PR_BRANCH" && "$r_pr" == "$HR_PR" ]] ||
  hr_deny "work/$ticket/review.md is a review of PR #$r_pr on $r_branch ($r_repo), not of PR #$HR_PR on $HR_PR_BRANCH"
[[ "$r_head" == "$HR_PR_HEAD" ]] ||
  hr_deny "work/$ticket/review.md reviewed head $r_head, but PR #$HR_PR's head is $HR_PR_HEAD; review the new head"
[[ "$r_mb" == "$HR_PR_MB" ]] ||
  hr_deny "work/$ticket/review.md reviewed the diff from merge base $r_mb, but PR #$HR_PR's merge base is now $HR_PR_MB (dev was merged into the branch?); review again"
md5="$(hr_md5 "$HR_PR_DIR/diff.patch")"
bytes="$(wc -c <"$HR_PR_DIR/diff.patch" | tr -d ' ')"
[[ "$r_md5" == "$md5" && "$r_bytes" == "$bytes" ]] ||
  hr_deny "the diff recomputed now (md5 $md5, $bytes bytes) is not the one work/$ticket/review.md records (md5 $r_md5, $r_bytes bytes)"

jq -r '.lenses[] | [.lens, .mechanism, .verdict, .reply, .reply_sha256] | join("\u001f")' "$HR_TMP/review.json" >"$HR_TMP/lenses"
seen=" "
while IFS=$'\x1f' read -r lens mech verdict reply rsha; do
  case "$lens" in
    code | security | frontend | ios | spend) ;;
    *) hr_deny "work/$ticket/review.md lists an unknown lens '$lens' (code, security, frontend, ios, spend)" ;;
  esac
  [[ "$seen" != *" $lens "* ]] || hr_deny "work/$ticket/review.md lists the $lens lens twice"
  seen+="$lens "
  case "$mech" in
    codex | subagent) ;;
    author | inline | self)
      hr_deny "the $lens lens was run by '$mech', a mechanism FORGE refuses (rule 3): the author never reviews its own diff"
      ;;
    *) hr_deny "the $lens lens names an unknown mechanism '$mech' (only codex or subagent)" ;;
  esac
  [[ "$lens" != code || "$mech" == codex ]] || hr_deny "the code lens must be run by codex (rule 3), not $mech"
  [[ "$verdict" == CLEAN ]] || hr_deny "the $lens lens is $verdict, not CLEAN; fix and review again until it is"
  [[ "$reply" =~ ^rounds/[1-9][0-9]*/reply-[a-z]+\.json$ && "$reply" == */reply-"$lens".json ]] ||
    hr_deny "the $lens lens's reply file '$reply' must be rounds/<r>/reply-$lens.json in work/$ticket"
  rdir="$work/${reply%/*}"
  rfile="$work/$reply"
  [[ ! -L "$work/rounds" && ! -L "$rdir" && -f "$rfile" && ! -L "$rfile" ]] ||
    hr_deny "the $lens lens's reply work/$ticket/$reply is missing (or a link)"
  got="$(hr_sha256 "$rfile")"
  [[ "$got" == "$rsha" ]] ||
    hr_deny "the $lens lens's reply work/$ticket/$reply changed after the review (its sha256 is $got; review.md records $rsha)"
  jq -se --arg l "$lens" --arg m "$md5" --argjson b "$bytes" 'length == 1 and (.[0] | type == "object" and .lens == $l and .verdict == "CLEAN" and .findings == [] and .diff_md5 == $m and .diff_bytes == $b)' "$rfile" >/dev/null 2>&1 ||
    hr_deny "the $lens lens's reply work/$ticket/$reply is not a CLEAN reply for this diff: it must be one JSON object that names the $lens lens, lists no findings, and reports the diff's md5 $md5 and $bytes bytes as the reviewer computed them (read-proof, rule 4)"
done <"$HR_TMP/lenses"
for lens in code security; do
  [[ "$seen" == *" $lens "* ]] || hr_deny "work/$ticket/review.md has no $lens lens; code and security are required for every PR (rule 3)"
done

jq -r '.deferred[] | [.finding, (.issue | tostring)] | join("\u001f")' "$HR_TMP/review.json" >"$HR_TMP/deferred"
while IFS=$'\x1f' read -r finding issue; do
  hr_gh issue view "$issue" --repo "$HR_FORGE_REPO" --json state </dev/null >"$HR_TMP/issue.json" 2>/dev/null ||
    hr_deny "can't read issue #$issue (deferred finding $finding) from GitHub; try again"
  jq -sr 'if length == 1 and (.[0] | type) == "object" then .[0].state | tostring else error("not one object") end' "$HR_TMP/issue.json" >"$HR_TMP/issue.state" 2>/dev/null ||
    hr_deny "GitHub's answer about issue #$issue (deferred finding $finding) can't be read; try again"
  istate="$(cat "$HR_TMP/issue.state")"
  [[ "$istate" == OPEN ]] ||
    hr_deny "deferred finding $finding cites issue #$issue, which is $istate; every deferred finding needs an open issue (rule 5)"
done <"$HR_TMP/deferred"

# Everything the squash commit may hold must be there in the expected shape, so nothing is skipped
# by being missing or malformed (FRG-4 review round 1); a co-author's name or email may be null.
jq -se 'length == 1 and (.[0] | (.title | type) == "string" and (.body | type) == "string" and (.commits | type) == "array" and (.commits | length) > 0 and (.commits | all(type == "object" and (.messageHeadline | type) == "string" and (.messageBody | type) == "string" and (.authors | type) == "array" and (.authors | all(type == "object" and ((.name | type) == "string" or .name == null) and ((.email | type) == "string" or .email == null))))))' \
  "$HR_TMP/pr.json" >/dev/null 2>&1 ||
  hr_deny "GitHub's answer about PR #$HR_PR's title, body or commits is incomplete, so what the squash commit would hold can't be scanned; try again"
mkdir "$HR_TMP/squash"
jq -r '.title' "$HR_TMP/pr.json" >"$HR_TMP/squash/title"
jq -r '.body' "$HR_TMP/pr.json" >"$HR_TMP/squash/body"
jq -r '.commits[] | .messageHeadline, .messageBody, (.authors[] | .name // empty, .email // empty)' "$HR_TMP/pr.json" >"$HR_TMP/squash/commits"
if ! hr_scan_text "$HR_TMP/squash"; then
  hr_deny "gitleaks found a possible secret in what the squash commit would hold (PR #$HR_PR's title, body or commit messages), or could not scan it: $HR_SCAN"
fi
hr_allow
