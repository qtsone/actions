#!/usr/bin/env bash
#
# Behavioural tests for scripts/squash-merge.sh. A stub `gh` on PATH serves the pull request
# JSON and records the merge call, so the refusal paths can prove that nothing was merged.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/squash-merge.sh"

ATLAS='Co-authored-by: Atlas <340611218+qts-atlas[bot]@users.noreply.github.com>'
WARDEN='Co-authored-by: Warden <340611405+qts-warden[bot]@users.noreply.github.com>'
HEAD_OID=d12e90bd7e7e7a4ee0ea01d63193c5eae11f4518

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") cat "$STUB_PR_JSON" ;;
  # One argument per line, NUL-free: enough to read back the --body value.
  "pr merge") printf '%s\n' "$@" > "$STUB_MERGE_LOG" ;;
  *) echo "stub gh: unexpected $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$WORK/bin/gh"

# Writes the stub's pull request: body $1, then one commit message per further argument.
pull_request() {
  local body="$1"
  shift
  jq -n --arg body "$body" --arg head "$HEAD_OID" '
    { body: $body, headRefOid: $head,
      commits: [ $ARGS.positional | to_entries[]
                 | { oid: ("c0ffee" + (.key | tostring) + "00000"),
                     messageHeadline: (.value | split("\n")[0]),
                     messageBody: (.value | split("\n")[1:] | join("\n")) } ] }
  ' --args "$@" > "$WORK/pr.json"
}

LAST_OUT=""
squash_merge() {
  rm -f "$WORK/merge.log"
  set +e
  LAST_OUT="$(PATH="$WORK/bin:$PATH" STUB_PR_JSON="$WORK/pr.json" STUB_MERGE_LOG="$WORK/merge.log" \
    bash "$SCRIPT" 42 2>&1)"
  local rc=$?
  set -e
  return $rc
}

assert_refuses() {
  local needle="$1" label="$2"
  if squash_merge; then
    fail "$label (expected a refusal, got exit 0: $LAST_OUT)"
  elif [[ -e "$WORK/merge.log" ]]; then
    fail "$label (refused but still called gh pr merge)"
  elif [[ "$LAST_OUT" != *"$needle"* ]]; then
    fail "$label (missing '$needle' in: $LAST_OUT)"
  else
    pass "$label"
  fi
}

main() {
  pull_request $'## Summary\r\n\r\nAdds the thing.' \
    $'feat: one\n\nFirst.\n\n'"$ATLAS" \
    $'fix: two\n\n'"$ATLAS"
  if ! squash_merge; then
    fail "agreeing commits merge (exit non-zero: $LAST_OUT)"
  else
    local expected_body
    expected_body=$'## Summary\n\nAdds the thing.\n\n'"$ATLAS"
    if [[ "$(cat "$WORK/merge.log")" == *$'--body\n'"$expected_body" ]]; then
      pass "agreeing commits merge with the PR body plus the one trailer"
    else
      fail "merge body is not the PR body plus the trailer: $(cat "$WORK/merge.log")"
    fi
    if grep -qx -- '--squash' "$WORK/merge.log"; then
      pass "the merge is a squash"
    else
      fail "no --squash in the merge call"
    fi
    if grep -qx -- "$HEAD_OID" "$WORK/merge.log"; then
      pass "the merge is pinned to the head the trailer was read from"
    else
      fail "no --match-head-commit $HEAD_OID in the merge call"
    fi
  fi

  pull_request 'Adds the thing.' $'feat: one\n\n'"$ATLAS" $'fix: two\n\n'"$WARDEN"
  assert_refuses "disagree" "commits naming different agents are refused"

  pull_request 'Adds the thing.' $'feat: one\n\n'"$ATLAS" $'fix: two\n\nNo trailer here.'
  assert_refuses "carries no Co-authored-by" "a commit with no trailer is refused"

  pull_request 'Adds the thing.' $'feat: one\n\n'"$ATLAS"$'\n'"$WARDEN"
  assert_refuses "exactly one is allowed" "a commit with two trailers is refused"

  pull_request $'Adds the thing.\n\n'"$ATLAS" $'feat: one\n\n'"$ATLAS"
  assert_refuses "PR body already carries" "a PR body that already carries a trailer is refused"

  if [[ $FAILURES -gt 0 ]]; then
    printf '\n%d squash-merge assertion(s) failed\n' "$FAILURES" >&2
    exit 1
  fi
  printf '\nAll squash-merge behaviour contracts hold\n'
}

main "$@"
