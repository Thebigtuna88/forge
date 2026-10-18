# shellcheck shell=bash
# Scene helper for the merge gates' conformance cases (FRG-4). A case's setup sources it
# (source "$TMP/stubs/scene.sh"), where ROOT is the sandbox's main checkout and TMP the sandbox.
# With git plumbing only (nothing is checked out, so the copied hooks, runtime and config are
# never touched, and fixed names and dates make the same scene give the same commits) it builds:
#   dev         a base commit: README.md, docs/plans/plan.md and an owner-only list
#   SC_BRANCH   a ticket branch with one more commit (scene_change sets what it holds)
# then freezes the diff with review-diff.sh, writes CLEAN code and security replies and
# work/<ticket>/review.md, and the fake gh's answers about the PR and dev...head. The command's
# --match-head-commit is the case's @SHA@, which conformance reads from $TMP/case.sha. A case
# changes one thing before or after. scene_genuine does it all.
SC_REPO=Thebigtuna88/forge
SC_PR=22
SC_TICKET=FRG-9-sample
SC_BRANCH="feature/$SC_TICKET"
SC_LIST='{"paths": [".harness/self-modification-paths.json", ".claude/hooks/", ".claude/settings.json", ".harness/lib/", "CLAUDE.md", "docs/specs/"]}'
SC_GH="$TMP/gh"
SC_WORK="$ROOT/work/$SC_TICKET"
SC_CODE_MECH=codex
SC_SEC_MECH=codex
SC_DEFERRED='[]'
SC_BASE="" SC_DEV="" SC_HEAD="" SC_MB="" SC_MD5="" SC_BYTES=""
mkdir -p "$SC_GH"

sc_git() { # git in the sandbox's main checkout, with a scratch index and a fixed identity and date
  env GIT_INDEX_FILE="$TMP/scene.index" GIT_AUTHOR_NAME=Scene GIT_AUTHOR_EMAIL=scene@example.com \
    GIT_COMMITTER_NAME=Scene GIT_COMMITTER_EMAIL=scene@example.com \
    GIT_AUTHOR_DATE=2026-10-18T12:00:00Z GIT_COMMITTER_DATE=2026-10-18T12:00:00Z git -C "$ROOT" "$@"
}

sc_start() { # [commit]: the scratch index starts empty, or from <commit>'s tree
  rm -f "$TMP/scene.index"
  if [[ -n "${1:-}" ]]; then sc_git read-tree "$1"; fi
}

sc_put() { # <path> <content> [mode]: a file (or, with mode 120000, a symlink to <content>)
  local oid
  oid="$(printf '%s' "$2" | sc_git hash-object -w --stdin)" || return 1
  sc_git update-index --add --cacheinfo "${3:-100644},$oid,$1"
}

sc_del() { sc_git update-index --force-remove "$1"; } # <path>

sc_commit() { # <message> [parent…]: prints the new commit
  local tree msg="$1" p
  local -a parents=()
  shift
  tree="$(sc_git write-tree)" || return 1
  for p in "$@"; do parents+=(-p "$p"); done
  sc_git commit-tree "$tree" ${parents[@]+"${parents[@]}"} -m "$msg"
}

scene_base() { # dev's base commit
  sc_start
  sc_put README.md $'scene\n'
  sc_put docs/plans/plan.md $'plan\n'
  sc_put .harness/self-modification-paths.json "$SC_LIST"
  SC_BASE="$(sc_commit "base")"
  SC_DEV="$SC_BASE"
  sc_git update-ref refs/heads/dev "$SC_BASE"
}

# shellcheck disable=SC2120 # the files are optional
scene_change() { # [<path> <content>]…: the ticket branch's commit (default: src/sample.txt)
  sc_start "$SC_BASE"
  if [[ $# -eq 0 ]]; then set -- src/sample.txt $'sample\n'; fi
  while [[ $# -ge 2 ]]; do
    sc_put "$1" "$2"
    shift 2
  done
  scene_head "$(sc_commit "FRG-9: a sample change" "$SC_BASE")"
}

scene_head() { # <commit>: the ticket branch now points at <commit>
  SC_HEAD="$1"
  sc_git update-ref "refs/heads/$SC_BRANCH" "$SC_HEAD"
}

scene_dev_moves() { # dev gets one more commit that the branch doesn't have
  sc_start "$SC_DEV"
  sc_put docs/plans/later.md $'later\n'
  SC_DEV="$(sc_commit "dev moved on" "$SC_DEV")"
  sc_git update-ref refs/heads/dev "$SC_DEV"
}

scene_freeze() { # the diff a review reads, made by review-diff.sh exactly as the gate makes it
  rm -rf "$TMP/freeze"
  mkdir -p "$TMP/freeze"
  bash -p "$ROOT/.harness/lib/review-diff.sh" "$ROOT" "$SC_DEV" "$SC_HEAD" "$TMP/freeze" || return 1
  SC_MB="$(cat "$TMP/freeze/merge-base")"
  SC_MD5="$(md5 -q <"$TMP/freeze/diff.patch")"
  SC_BYTES="$(wc -c <"$TMP/freeze/diff.patch" | tr -d ' ')"
}

sc_reply() { # <lens>: a CLEAN reply for the frozen diff
  jq -n --arg l "$1" --arg m "$SC_MD5" --argjson b "$SC_BYTES" \
    '{lens: $l, diff_md5: $m, diff_bytes: $b, verdict: "CLEAN", findings: []}'
}

sc_sha() { shasum -a 256 <"$1" | cut -d ' ' -f 1; } # <file>

scene_review_json() { # $TMP/review.json from the replies as they are now
  jq -n --arg repo "$SC_REPO" --arg br "$SC_BRANCH" --argjson pr "$SC_PR" --arg head "$SC_HEAD" \
    --arg mb "$SC_MB" --arg md5 "$SC_MD5" --argjson bytes "$SC_BYTES" \
    --arg cm "$SC_CODE_MECH" --arg sm "$SC_SEC_MECH" \
    --arg cs "$(sc_sha "$SC_WORK/rounds/1/reply-code.json")" \
    --arg ss "$(sc_sha "$SC_WORK/rounds/1/reply-security.json")" --argjson def "$SC_DEFERRED" \
    '{forge_review: 1, repo: $repo, branch: $br, pr: $pr, head: $head, merge_base: $mb,
      diff_md5: $md5, diff_bytes: $bytes,
      lenses: [
        {lens: "code", mechanism: $cm, model: "gpt-5-codex", rounds: 1, verdict: "CLEAN",
         reply: "rounds/1/reply-code.json", reply_sha256: $cs},
        {lens: "security", mechanism: $sm, model: "gpt-5-codex", rounds: 1, verdict: "CLEAN",
         reply: "rounds/1/reply-security.json", reply_sha256: $ss}],
      deferred: $def}' >"$TMP/review.json"
}

scene_review_md() { # work/<ticket>/review.md around $TMP/review.json
  {
    printf '# Review: %s, PR #%s\n\nEvery required lens is CLEAN.\n\n' "$SC_TICKET" "$SC_PR"
    printf '```json forge-review\n'
    cat "$TMP/review.json"
    printf '```\n'
  } >"$SC_WORK/review.md"
}

scene_review() { # freeze, CLEAN replies for code and security, review.md
  scene_freeze || return 1
  mkdir -p "$SC_WORK/rounds/1"
  sc_reply code >"$SC_WORK/rounds/1/reply-code.json"
  sc_reply security >"$SC_WORK/rounds/1/reply-security.json"
  scene_review_json
  scene_review_md
}

scene_github() { # the fake gh's answers about the PR and dev...head, and the case's @SHA@
  jq -n --arg h "$SC_HEAD" --arg b "$SC_BRANCH" \
    '{state: "OPEN", baseRefName: "dev", headRefName: $b, headRefOid: $h, isCrossRepository: false,
      headRepositoryOwner: {login: "Thebigtuna88"}, title: "FRG-9: a sample change",
      body: "A sample change.\n\nCloses #9",
      commits: [{oid: $h, messageHeadline: "FRG-9: a sample change", messageBody: "",
        authors: [{name: "Scene", email: "scene@example.com"}]}]}' >"$SC_GH/pr-view-$SC_PR.out"
  jq -n --arg d "$SC_DEV" --arg m "$SC_MB" '{base_commit: {sha: $d}, merge_base_commit: {sha: $m}}' \
    >"$SC_GH/api-repos_Thebigtuna88_forge_compare_dev...$SC_HEAD.out"
  printf '%s\n' "$SC_HEAD" >"$TMP/case.sha"
}

sc_pr_edit() { # <jq filter> [jq options…]: change the fake gh's answer about the PR
  local filter="$1"
  shift
  jq "$@" "$filter" "$SC_GH/pr-view-$SC_PR.out" >"$TMP/pr.edit" && mv "$TMP/pr.edit" "$SC_GH/pr-view-$SC_PR.out"
}

sc_review_edit() { # <jq filter> [jq options…]: change review.json and rewrite review.md around it
  local filter="$1"
  shift
  jq "$@" "$filter" "$TMP/review.json" >"$TMP/review.edit" && mv "$TMP/review.edit" "$TMP/review.json"
  scene_review_md
}

sc_secret() { printf '%s%s' "ghp_" "4Vq9TzLm2Rk8XwPn6YbJc3HdF7GsA1KeUoNi"; } # a fake token, built at run time

sc_issue() { jq -n --arg s "$2" '{state: $s}' >"$SC_GH/issue-view-$1.out"; } # <n> <state>

# shellcheck disable=SC2120 # the files are optional
scene_genuine() { # [<path> <content>]…: a PR with a genuine, complete review
  scene_base
  scene_change "$@"
  scene_review
  scene_github
}
