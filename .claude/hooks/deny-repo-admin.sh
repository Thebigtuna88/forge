#!/bin/bash -p
# deny-repo-admin (spec 5.3, FRG-4): the gh allowlist. A gh command that only reads (hookrt's
# _HR_GH_READS) isn't guarded, so it may sit in a pipeline and reaches here only when something
# else makes the command guarded; it is allowed. Every other gh command must be one plain command
# (hr_require_simple, which also refuses while a GH_* or GITHUB_* variable is set) and one of:
#   gh auth status [--active]
#   gh api <endpoint> as a GET only: no -X/--method but GET, no -f/-F/--field/--raw-field/--input
#     (any of them turns it into a write), no -H, --hostname or graphql; options --paginate,
#     --jq/-q, --template/-t, -i/--include, --silent
#   gh issue create/edit/comment/close/reopen, gh pr create/edit/comment/close/ready, with the
#     options listed below for each, long forms only: a PR is created only into dev from a ticket
#     branch, and its base is never edited
#   gh pr merge in the one form HR_MERGE_FORM (gate-merge-on-review and gate-self-modification
#     judge the rest)
# Text goes to GitHub only as --title <text> and --body-file <file> (no -b/--body, --fill, editor
# or web modes): the whole command, each of its words as gh receives them, and every body file are
# scanned by gitleaks with FORGE's rules
# before anything is sent, since the repository is public (rule 10). Everything else is refused:
# repo create/edit/delete/rename/archive/fork/sync/set-default/clone, rulesets, secrets,
# variables, auth login/logout/refresh/token/setup-git, config, alias, extension, gist, release
# create/delete, pr checkout, workflow run/enable/disable, codespace, cache, and any command a
# future gh adds. (git config writes to alias.* or core.hooksPath are refused by
# deny-history-rewrite, FRG-3.)
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset HOOKRT_LOADED
# shellcheck source=.harness/lib/hookrt.sh
source "$here/../../.harness/lib/hookrt.sh" || { echo "hookrt failed to load" >&2; exit 2; }
[ "${HOOKRT_LOADED:-}" = 1 ] || { echo "hookrt not loaded" >&2; exit 2; }

hr_init deny-repo-admin
hr_guarded || hr_allow
hr_require_simple
[[ "${HR_TOK[0]:-}" == gh ]] || hr_allow
if hr_gh_reads 0; then hr_allow; fi
cmd="${HR_TOK[1]:-}"
sub="${HR_TOK[2]:-}"
n=${#HR_TOK[@]}
vopts=""
flags=""
need=""
numbered=0
case "$cmd $sub" in
  "pr merge")
    hr_merge_form || hr_deny "merge only as: $HR_MERGE_FORM"
    hr_allow
    ;;
  "auth status")
    [[ $n == 3 || "${HR_TOK[*]:3}" == --active ]] ||
      hr_deny "only gh auth status (or gh auth status --active) is allowed: --show-token would print the login token"
    hr_allow
    ;;
  "api "*) ;;
  "issue create")
    vopts=" --title --body-file --label --assignee --repo "
    need=" --title --body-file "
    ;;
  "issue edit")
    numbered=1
    vopts=" --title --body-file --add-label --remove-label --add-assignee --remove-assignee --repo "
    ;;
  "issue comment" | "pr comment")
    numbered=1
    vopts=" --body-file --repo "
    need=" --body-file "
    ;;
  "issue close")
    numbered=1
    vopts=" --reason --repo "
    ;;
  "issue reopen" | "pr close" | "pr ready")
    numbered=1
    vopts=" --repo "
    ;;
  "pr create")
    vopts=" --base --head --title --body-file --label --repo "
    flags=" --draft "
    need=" --base --head --title --body-file "
    ;;
  "pr edit")
    numbered=1
    vopts=" --title --body-file --add-label --remove-label --repo "
    ;;
  *)
    hr_deny "gh $cmd $sub is not on FORGE's list of allowed gh commands (reading, gh api GETs, tickets, PRs into dev, and the one merge form); repository settings, secrets, logins and deletions are the owner's"
    ;;
esac

bodies=()
if [[ "$cmd" == api ]]; then
  endpoint=""
  i=2
  while ((i < n)); do
    t="${HR_TOK[i]}"
    case "$t" in
      --paginate | --silent | -i | --include) ((i += 1)) ;;
      --jq | -q | --template | -t)
        ((i + 1 < n)) || hr_deny "gh api $t needs a value"
        ((i += 2))
        ;;
      -X | --method)
        [[ "${HR_TOK[i + 1]:-}" == GET ]] ||
          hr_deny "gh api may only read: $t GET or no method at all (not '${HR_TOK[i + 1]:-}')"
        ((i += 2))
        ;;
      -*)
        hr_deny "gh api option $t is not allowed: gh api may only read (--paginate, --jq, --template, --include, --silent, -X GET); -f/-F/--field/--raw-field/--input would make it a write"
        ;;
      *)
        [[ -z "$endpoint" ]] || hr_deny "gh api takes one endpoint, not '$endpoint' and '$t'"
        endpoint="$t"
        ((i += 1))
        ;;
    esac
  done
  [[ -n "$endpoint" ]] || hr_deny "gh api needs an endpoint"
  [[ "$endpoint" =~ ^/?[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] ||
    hr_deny "gh api's endpoint must be a plain path on api.github.com such as repos/$HR_FORGE_REPO/pulls/5 (not '$endpoint')"
  low="$(printf '%s' "$endpoint" | tr '[:upper:]' '[:lower:]')"
  [[ "${low#/}" != graphql ]] || hr_deny "gh api graphql is refused: a GraphQL request can write (mutations), and only GETs are allowed"
else
  i=3
  if [[ $numbered == 1 ]]; then
    [[ "${HR_TOK[3]:-}" =~ ^[1-9][0-9]{0,8}$ ]] ||
      hr_deny "gh $cmd $sub needs the issue or PR number right after it: gh $cmd $sub <n> …"
    i=4
  fi
  seen=" "
  while ((i < n)); do
    t="${HR_TOK[i]}"
    if [[ "$vopts" == *" $t "* ]]; then
      ((i + 1 < n)) || hr_deny "gh $cmd $sub $t needs a value"
      v="${HR_TOK[i + 1]}"
      [[ "$v" != -* ]] || hr_deny "the value of $t may not start with - ('$v')"
      [[ "$seen" != *" $t "* ]] || hr_deny "give $t once (gh would use only the last one)"
      seen+="$t "
      case "$t" in
        --body-file) bodies+=("$v") ;;
        --base) [[ "$v" == dev ]] || hr_deny "a PR goes only into dev (--base dev), not '$v'; main is the owner's" ;;
        --head)
          [[ "$v" =~ $HR_TICKET_BRANCH ]] ||
            hr_deny "a PR's head must be a ticket branch (feature/<KEY>-<n>-<slug>), not '$v'"
          ;;
        --reason)
          [[ "$v" == completed || "$v" == "not planned" ]] ||
            hr_deny "close an issue with --reason completed or --reason 'not planned', not '$v'"
          ;;
      esac
      ((i += 2))
    elif [[ "$flags" == *" $t "* && "$seen" != *" $t "* ]]; then
      seen+="$t "
      ((i += 1))
    else
      hr_deny "gh $cmd $sub: '$t' is not allowed. Allowed:${vopts}${flags}(long forms, each with its value as the next word; text only from --body-file <file>, which is scanned for secrets first)"
    fi
  done
  # shellcheck disable=SC2086 # $need is a space-separated list on purpose
  for t in $need; do
    [[ "$seen" == *" $t "* ]] || hr_deny "gh $cmd $sub needs $t"
  done
fi

mkdir "$HR_TMP/text"
printf '%s\n' "$HR_CMD" >"$HR_TMP/text/command"
# Quotes and backslashes can split a secret in the command's text ('ghp_'"…") while gh gets it
# whole, so each word as the shell passes it is scanned too, one per line (review round 1).
printf '%s\n' "${HR_TOK[@]}" >"$HR_TMP/text/words"
k=0
for b in ${bodies[@]+"${bodies[@]}"}; do
  [[ "$b" != - ]] || hr_deny "the text must come from a file, not standard input (--body-file -)"
  if [[ "$b" != /* ]]; then
    [[ "$HR_CWD" == /* ]] || hr_deny "can't tell which folder the command runs in, so can't find --body-file $b; give its full path"
    b="$HR_CWD/$b"
  fi
  [[ -f "$b" && -r "$b" && ! -L "$b" ]] ||
    hr_deny "the --body-file must be a regular file you can read (not a link), so it can be scanned: $b"
  ((k += 1))
  cp "$b" "$HR_TMP/text/body-$k"
done
if ! hr_scan_text "$HR_TMP/text"; then
  hr_deny "gitleaks found a possible secret in the text this gh command would send to GitHub (the command itself or its --body-file), or could not scan it: $HR_SCAN"
fi
hr_allow
