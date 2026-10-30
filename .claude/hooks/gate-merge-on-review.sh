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
# - Every lens listed is known, run by codex (never a subagent, author, inline or self: codex only,
#   owner decision 2026-10-28) and CLEAN, and its reply file rounds/<r>/reply-<lens>.json still
#   has the recorded sha256 and is itself a CLEAN reply, with no findings, for this lens and this
#   diff's md5 and bytes (read-proof, rule 4: the reply names exactly this diff). Every lens the
#   recomputed diff requires (spec 6.2, review_lib.py, as the runner computes it) is listed.
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
hr_plain_numbers "$HR_TMP/review.json" ||
  hr_deny "work/$ticket/review.md's forge-review block writes a number that is not plain digits (spec 6.6: no fraction or exponent, as in rounds 1e0)"
jq -s '.[0]' "$HR_TMP/review.json" >"$HR_TMP/review.one"
mv "$HR_TMP/review.one" "$HR_TMP/review.json"

# Each row is one line of fields; a field with a line break can't be judged by its first line or
# split a row in two (review round 5), and one with a NUL can't lose it in bash (round 6).
jq -r "$HR_JQ_FIELDS"'[.repo, .branch, (.pr | tostring), .head, .merge_base, .diff_md5, (.diff_bytes | tostring)] | fields' \
  "$HR_TMP/review.json" >"$HR_TMP/bound" 2>/dev/null ||
  hr_deny "work/$ticket/review.md's forge-review block is malformed (a field holds a NUL or a line break)"
bound="$(cat "$HR_TMP/bound")"
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

jq -r "$HR_JQ_FIELDS"'.lenses[] | [.lens, .mechanism, .verdict, .reply, .reply_sha256, (.rounds | tostring)] | fields' \
  "$HR_TMP/review.json" >"$HR_TMP/lenses" 2>/dev/null ||
  hr_deny "work/$ticket/review.md's forge-review block is malformed (a lens's field holds a NUL or a line break)"
seen=" "
while IFS=$'\x1f' read -r lens mech verdict reply rsha rounds; do
  case "$lens" in
    code | security | frontend | ios | spend) ;;
    *) hr_deny "work/$ticket/review.md lists an unknown lens '$lens' (code, security, frontend, ios, spend)" ;;
  esac
  [[ "$seen" != *" $lens "* ]] || hr_deny "work/$ticket/review.md lists the $lens lens twice"
  seen+="$lens "
  case "$mech" in
    codex) ;;
    subagent)
      hr_deny "the $lens lens was run by a subagent; every lens is run by codex (owner decision 2026-10-28, FRG-7)"
      ;;
    author | inline | self)
      hr_deny "the $lens lens was run by '$mech', a mechanism FORGE refuses (rule 3): the author never reviews its own diff"
      ;;
    *) hr_deny "the $lens lens names an unknown mechanism '$mech' (only codex)" ;;
  esac
  [[ "$verdict" == CLEAN ]] || hr_deny "the $lens lens is $verdict, not CLEAN; fix and review again until it is"
  # The reply is the last round's, and no later round exists for the lens: a summary left behind
  # by a newer round (perhaps with findings) is stale (review round 2).
  [[ "$reply" == "rounds/$rounds/reply-$lens.json" ]] ||
    hr_deny "the $lens lens's reply file '$reply' must be rounds/$rounds/reply-$lens.json in work/$ticket, its last round (review.md records $rounds rounds)"
  # Rounds are uncapped (rule 5), so they compare as decimal text of any length, never in bash's
  # 64-bit arithmetic: a longer number is later, and one of the same length compares digit by
  # digit (review round 4).
  [[ "$rounds" =~ ^[1-9][0-9]*$ ]] ||
    hr_deny "review.md records '$rounds' rounds for the $lens lens, not a whole number written out"
  # A link counts as there even when it points nowhere (-L): a broken or unreadable later round is
  # still a later round (review round 9). So does a later run that failed (reply-<lens>.failed.json)
  # or never finished (only its prompt): it is the lens's latest attempt (FRG-7 review round 2).
  for later in "$work"/rounds/*/reply-"$lens".json "$work"/rounds/*/reply-"$lens".failed.json \
    "$work"/rounds/*/prompt-"$lens".md; do
    k="${later%/*}"
    k="${k##*/}"
    if [[ (-e "$later" || -L "$later") && ! "$k" =~ ^[1-9][0-9]*$ ]]; then
      hr_deny "work/$ticket/rounds/$k/ is not a round number, so the $lens lens's rounds can't be checked"
    fi
    if [[ (-e "$later" || -L "$later") && (${#k} -gt ${#rounds} || (${#k} -eq ${#rounds} && "$k" > "$rounds")) ]]; then
      hr_deny "work/$ticket has a later round ($k) for the $lens lens than review.md records ($rounds); review.md is stale, so finish the review and rewrite it"
    fi
  done
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
# The lenses this diff requires are worked out here, from the diff recomputed above, whatever
# review.md lists (spec 6.2).
if ! hr_required_lenses "$HR_PR_DIR/raw"; then
  why="$(head -c 200 "$HR_TMP/lenses.err")"
  hr_deny "can't work out which lenses PR #$HR_PR's diff requires (spec 6.2): ${why//$'\n'/ }"
fi
while IFS= read -r lens; do
  [[ "$seen" == *" $lens "* ]] ||
    hr_deny "work/$ticket/review.md has no $lens lens, and PR #$HR_PR's diff requires it (spec 6.2: required lenses are computed, not chosen)"
done <"$HR_TMP/lenses.req"
# A lens that was started in any round, required or not, must be listed (and so CLEAN): its
# findings can't be dropped by leaving it out of review.md (FRG-7 review round 2).
for lens in code security frontend ios spend; do
  for ran in "$work"/rounds/*/reply-"$lens".json "$work"/rounds/*/reply-"$lens".failed.json \
    "$work"/rounds/*/prompt-"$lens".md; do
    if [[ (-e "$ran" || -L "$ran") && "$seen" != *" $lens "* ]]; then
      hr_deny "the $lens lens ran (work/$ticket/${ran#"$work"/}) but review.md doesn't list it; every lens that ran must be CLEAN"
    fi
  done
done

jq -r "$HR_JQ_FIELDS"'.deferred[] | [.finding, (.issue | tostring)] | fields' "$HR_TMP/review.json" \
  >"$HR_TMP/deferred" 2>/dev/null ||
  hr_deny "work/$ticket/review.md's forge-review block is malformed (a deferred finding holds a NUL or a line break; name it on one line)"
while IFS=$'\x1f' read -r finding issue; do
  hr_gh issue view "$issue" --repo "$HR_FORGE_REPO" --json state </dev/null >"$HR_TMP/issue.json" 2>/dev/null ||
    hr_deny "can't read issue #$issue (deferred finding $finding) from GitHub; try again"
  jq -sr "$HR_JQ_FIELDS"'if length == 1 and (.[0] | type) == "object" then [.[0].state | tostring] | fields else error("not one object") end' "$HR_TMP/issue.json" >"$HR_TMP/issue.state" 2>/dev/null ||
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
# gh lists only the first 100 commits of a PR, and 100 authors of each, without saying whether
# there are more, so a list that long may be cut off (review round 2).
jq -e '(.commits | length) < 100 and all(.commits[]; (.authors | length) < 100)' "$HR_TMP/pr.json" >/dev/null 2>&1 ||
  hr_deny "PR #$HR_PR has 100 or more commits (or a commit with 100 or more authors), and GitHub lists only the first 100, so the squash text can't all be scanned; the owner merges this one"
mkdir "$HR_TMP/squash"
jq -r '.title' "$HR_TMP/pr.json" >"$HR_TMP/squash/title"
jq -r '.body' "$HR_TMP/pr.json" >"$HR_TMP/squash/body"
jq -r '.commits[] | .messageHeadline, .messageBody, (.authors[] | .name // empty, .email // empty)' "$HR_TMP/pr.json" >"$HR_TMP/squash/commits"
if ! hr_scan_text "$HR_TMP/squash"; then
  hr_deny "gitleaks found a possible secret in what the squash commit would hold (PR #$HR_PR's title, body or commit messages), or could not scan it: $HR_SCAN"
fi
hr_allow
