#!/usr/bin/env bash
#
# squash-merge <pr> — Warden's merge step. Squash-merges a pull request with the PR body as
# the message and one trailer per distinct branch agent appended in first-commit order, so
# `main` credits every contributing agent exactly once.
#
# Only agent commits are checked: a branch commit whose author email, compared
# case-insensitively, is on the `agent-accounts` list of git/attribution, the same list the
# Attribution check reads. Any other commit, the owner's for one, adds no trailer and is never
# refused for its trailers, so a PR with no agent commit merges with the PR body alone.
#
# Refuses, and merges nothing, when an agent commit carries no `Co-authored-by:` line or more
# than one, when any of their trailers is not exactly a `Name <email>` pair from the attribution
# roster, when the PR body already carries one, or when the PR title is not a Conventional
# Commits subject.
#
# The explicit --body is load-bearing: without it GitHub composes the message itself and
# appends a `Co-authored-by:` line per distinct branch commit author, host identities included.
#
# Runs against the repository of the current directory; set GH_REPO=owner/repo to aim
# elsewhere. Needs `gh` and `jq`.

set -euo pipefail

fatal() {
  printf 'squash-merge: %s\n' "$1" >&2
  exit 1
}

[ "$#" -eq 1 ] || fatal "usage: squash-merge <pr>"
pr="$1"

view="$(gh pr view "${pr}" --json title,body,headRefOid,commits)" \
  || fatal "cannot read pull request ${pr}"

# The squash puts the title on main as the commit subject, so it decides the release. The
# pattern is git/attribution/pr-title.ere on qtsone/actions main, the file the check reads.
title_re="$(gh api repos/qtsone/actions/contents/git/attribution/pr-title.ere \
  -H 'Accept: application/vnd.github.raw')" || fatal "cannot read the PR title pattern from qtsone/actions"
[ -n "${title_re}" ] || fatal "the PR title pattern from qtsone/actions is empty"
title="$(jq -r '.title' <<< "${view}")"
[[ "${title}" =~ ${title_re} ]] \
  || fatal "PR title '${title}' is not a Conventional Commits subject, so semantic-release ships nothing from it. It must match ${title_re}, e.g. 'fix(auth): refresh expired sessions (QTS-123)'. A breaking change is a 'BREAKING CHANGE:' paragraph in the body, not '!'. Fix it with gh pr edit ${pr} --title."

# The roster and the agent accounts are the `agents` and `agent-accounts` input defaults of
# git/attribution on qtsone/actions main, so the merge and the Attribution check share one list
# of each. Without the roster a Paperclip-only or Claude-only trailer is consistent across
# commits and lands on main, and nothing makes the red check bind.
action_yaml="$(gh api repos/qtsone/actions/contents/git/attribution/action.yaml \
  -H 'Accept: application/vnd.github.raw')" || fatal "cannot read git/attribution/action.yaml from qtsone/actions"
input_default() {
  awk -v input="  $1:" '
      $0 == input { in_input = 1; next }
      in_input && /^    default: \|/ { in_block = 1; next }
      in_block {
        if ($0 ~ /^      [^ ]/) { sub(/^      /, ""); print; next }
        exit
      }
      in_input && /^  [^ ]/ { in_input = 0 }
    ' <<< "${action_yaml}"
}
roster="$(input_default agents)"
[ -n "${roster}" ] || fatal "the attribution roster from qtsone/actions is empty"
agent_accounts="$(input_default agent-accounts)"
[ -n "${agent_accounts}" ] || fatal "the agent-accounts list from qtsone/actions is empty"

[ "$(jq '.commits | length' <<< "${view}")" -gt 0 ] || fatal "pull request ${pr} has no commits"

# One tab-separated row per agent commit: short sha, number of trailer lines, the first one's
# value. `authors` also lists every Co-authored-by: identity; GitHub puts the git author first.
rows="$(jq -r --arg accounts "${agent_accounts}" '
  ($accounts | ascii_downcase | split("\n")) as $agents
  | .commits[]
  | select(.authors[0].email // "" | ascii_downcase | IN($agents[]))
  | [ (.messageHeadline + "\n" + .messageBody) | split("\n")[]
      | select(test("^\\s*co-authored-by:"; "i"))
      | sub("^\\s*co-authored-by:\\s*"; ""; "i") | sub("\\s+$"; "") ] as $t
  | [.oid[0:9], ($t | length), ($t[0] // "")] | @tsv
' <<< "${view}")"

trailers=("")
while IFS=$'\t' read -r sha count value; do
  # A PR with no agent commit has no rows, and a here-string of nothing still reads one line.
  [ -n "${sha}" ] || continue
  case "${count}" in
    0) fatal "agent commit ${sha} carries no Co-authored-by: line; amend it before merging" ;;
    1) ;;
    *) fatal "agent commit ${sha} carries ${count} Co-authored-by: lines; exactly one is allowed" ;;
  esac
  printf '%s\n' "${roster}" | grep -qxF -- "${value}" \
    || fatal "the trailer '${value}' is not a roster pair from git/attribution; amend the commits"
  seen=false
  for trailer in "${trailers[@]}"; do
    if [ "${value}" = "${trailer}" ]; then
      seen=true
      break
    fi
  done
  if [ "${seen}" = false ]; then
    trailers+=("${value}")
  fi
done <<< "${rows}"

# GitHub stores a body edited in the browser with CRLF line ends.
body="$(jq -r '.body // ""' <<< "${view}" | tr -d '\r')"
if printf '%s\n' "${body}" | grep -qiE '^[[:space:]]*co-authored-by:'; then
  fatal "the PR body already carries a Co-authored-by: line; remove it, the merge adds the trailer"
fi

message="${body}"
if [ "${#trailers[@]}" -gt 1 ]; then
  credits="$(printf 'Co-authored-by: %s\n' "${trailers[@]:1}")"
  if [ -n "${message}" ]; then
    message="${message}"$'\n\n'"${credits}"
  else
    message="${credits}"
  fi
fi

# --match-head-commit: the trailer was read from this head, so a push since then must not merge.
gh pr merge "${pr}" --squash \
  --match-head-commit "$(jq -r .headRefOid <<< "${view}")" \
  --body "${message}"
