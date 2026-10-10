#!/usr/bin/env bash
#
# squash-merge <pr> — Warden's merge step. Squash-merges a pull request with the PR body as
# the message and the one agent trailer from its branch commits appended, so `main` credits
# the agent exactly once.
#
# Refuses, and merges nothing, when a branch commit carries no `Co-authored-by:` line or more
# than one, when the commits disagree on it, or when the PR body already carries one.
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

view="$(gh pr view "${pr}" --json body,headRefOid,commits)" \
  || fatal "cannot read pull request ${pr}"

# One tab-separated row per commit: short sha, number of trailer lines, the first one's value.
rows="$(jq -r '
  .commits[]
  | [ (.messageHeadline + "\n" + .messageBody) | split("\n")[]
      | select(test("^\\s*co-authored-by:"; "i"))
      | sub("^\\s*co-authored-by:\\s*"; ""; "i") | sub("\\s+$"; "") ] as $t
  | [.oid[0:9], ($t | length), ($t[0] // "")] | @tsv
' <<< "${view}")"
[ -n "${rows}" ] || fatal "pull request ${pr} has no commits"

trailer=""
while IFS=$'\t' read -r sha count value; do
  case "${count}" in
    0) fatal "commit ${sha} carries no Co-authored-by: line; amend it before merging" ;;
    1) ;;
    *) fatal "commit ${sha} carries ${count} Co-authored-by: lines; exactly one is allowed" ;;
  esac
  if [ -z "${trailer}" ]; then
    trailer="${value}"
  elif [ "${value}" != "${trailer}" ]; then
    fatal "branch commits disagree on the trailer: '${trailer}' vs '${value}' (commit ${sha})"
  fi
done <<< "${rows}"

# GitHub stores a body edited in the browser with CRLF line ends.
body="$(jq -r '.body // ""' <<< "${view}" | tr -d '\r')"
if printf '%s\n' "${body}" | grep -qiE '^[[:space:]]*co-authored-by:'; then
  fatal "the PR body already carries a Co-authored-by: line; remove it, the merge adds the trailer"
fi

message="Co-authored-by: ${trailer}"
[ -z "${body}" ] || message="${body}"$'\n\n'"${message}"

# --match-head-commit: the trailer was read from this head, so a push since then must not merge.
gh pr merge "${pr}" --squash \
  --match-head-commit "$(jq -r .headRefOid <<< "${view}")" \
  --body "${message}"
