#!/usr/bin/env bash
#
# Behavioural tests for git/attribution. The check decides whether a PR can be merged, so the
# cases that matter are the shapes real tooling produces: the Claude Code trailer and footer,
# the host-identity co-author GitHub appends to a squash commit, and a renovate commit that
# legitimately carries no agent trailer.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ATTRIBUTION_SCRIPT="$ROOT_DIR/git/attribution/scripts/attribution.sh"
ACTION_YAML="$ROOT_DIR/git/attribution/action.yaml"

# The agent and exempt-author lists are declared once, in action.yaml, and read from there
# rather than copied here. The script deliberately defaults neither, so the action metadata is
# the only definition — and a test that hard-coded its own copy would keep passing after the
# list callers actually get had changed.
action_default_list() {
  awk -v key="  $1:" '
    $0 == key { in_input = 1; next }
    in_input && $0 ~ /^    default: \|/ { in_block = 1; next }
    in_block {
      if ($0 ~ /^      [^ ]/) { sub(/^      /, ""); print; next }
      exit
    }
    in_input && $0 ~ /^  [^ ]/ { in_input = 0 }
  ' "$ACTION_YAML"
}

DEFAULT_AGENTS="$(action_default_list agents)"
DEFAULT_EXEMPT_AUTHORS="$(action_default_list exempt-authors)"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

TEMP_DIR_TO_CLEANUP=""
cleanup_tempdir() {
  if [[ -n "$TEMP_DIR_TO_CLEANUP" && -d "$TEMP_DIR_TO_CLEANUP" ]]; then
    rm -rf "$TEMP_DIR_TO_CLEANUP"
  fi
}
trap cleanup_tempdir EXIT

setup_repo() {
  local tempdir
  tempdir="$(mktemp -d)"
  TEMP_DIR_TO_CLEANUP="$tempdir"
  REPO="$tempdir/repo"

  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email "contracts@example.invalid"
  git -C "$REPO" config user.name "contract-test"
  git -C "$REPO" commit -q --allow-empty -m "seed

Co-Authored-By: Atlas"
}

# Appends one commit whose message is $1, authored by $2 (default a plain agent identity).
# --allow-empty keeps the fixtures about the message, which is all the script reads.
commit_msg() {
  local message="$1" author="${2:-contract-test}"
  git -C "$REPO" commit -q --allow-empty \
    --author="${author} <${author// /.}@example.invalid>" -F - <<< "$message"
}

# Runs the script over HEAD~1..HEAD with the default agent list. Extra NAME=VALUE arguments
# override anything set here, because env applies assignments left to right.
LAST_OUT=""
attribution() {
  local base head rc
  base="$(git -C "$REPO" rev-parse HEAD~1)"
  head="$(git -C "$REPO" rev-parse HEAD)"
  set +e
  LAST_OUT="$(
    cd "$REPO" && env -u GITHUB_STEP_SUMMARY -u GITHUB_OUTPUT \
      AGENTS="$DEFAULT_AGENTS" EXEMPT_AUTHORS="$DEFAULT_EXEMPT_AUTHORS" \
      BASE_SHA="$base" HEAD_SHA="$head" "$@" \
      bash "$ATTRIBUTION_SCRIPT" 2>&1
  )"
  rc=$?
  set -e
  return $rc
}

assert_ok() {
  local label="$1"
  shift
  if attribution "$@"; then
    pass "$label"
  else
    fail "$label (expected exit 0, got non-zero with: $LAST_OUT)"
  fi
}

assert_ok_with() {
  local needle="$1" label="$2"
  shift 2
  if ! attribution "$@"; then
    fail "$label (expected exit 0, got non-zero with: $LAST_OUT)"
  elif [[ "$LAST_OUT" != *"$needle"* ]]; then
    fail "$label (missing '$needle' in: $LAST_OUT)"
  else
    pass "$label"
  fi
}

assert_fails_with() {
  local needle="$1" label="$2"
  shift 2
  if attribution "$@"; then
    fail "$label (expected non-zero exit, got 0 with: $LAST_OUT)"
  elif [[ "$LAST_OUT" != *"$needle"* ]]; then
    fail "$label (missing '$needle' in: $LAST_OUT)"
  else
    pass "$label"
  fi
}

main() {
  [[ -f "$ATTRIBUTION_SCRIPT" ]] || { printf 'FAIL: missing %s\n' "$ATTRIBUTION_SCRIPT" >&2; exit 1; }
  [[ -f "$ACTION_YAML" ]] || { printf 'FAIL: missing %s\n' "$ACTION_YAML" >&2; exit 1; }
  # A reader that silently returned nothing would make every case below fail on an empty
  # agent list rather than on the behaviour it is testing.
  [[ "$DEFAULT_AGENTS" == *"Design Lead"* ]] \
    || { printf 'FAIL: could not read the agents default out of %s\n' "$ACTION_YAML" >&2; exit 1; }
  [[ "$DEFAULT_EXEMPT_AUTHORS" == *"renovate[bot]"* ]] \
    || { printf 'FAIL: could not read the exempt-authors default out of %s\n' "$ACTION_YAML" >&2; exit 1; }
  setup_repo

  # The shape every agent commit is supposed to have.
  commit_msg "feat: a change

Co-Authored-By: Atlas"
  assert_ok "a single agent trailer passes"
  # The sha has to be in the annotation, or a failing PR with twenty commits says nothing
  # about which one to amend.
  assert_ok_with "$(git -C "$REPO" rev-parse --short=9 HEAD)" "the summary row names the commit"

  commit_msg "feat: no attribution at all"
  assert_fails_with "missing the required trailer" "a commit with no agent trailer fails"
  assert_fails_with "$(git -C "$REPO" rev-parse HEAD)" "the missing-trailer error names the sha"

  commit_msg "feat: two agents

Co-Authored-By: Atlas
Co-Authored-By: Warden"
  assert_fails_with "found 2" "two agent trailers fail"

  # What Claude Code writes unless told otherwise.
  commit_msg "feat: vendor trailer

Co-Authored-By: Claude <noreply@anthropic.com>"
  assert_fails_with "vendor attribution is not allowed" "a vendor trailer fails"

  # The same line matches both the anthropic needle and the Claude trailer name, and must
  # still be reported once — a doubled annotation reads as two separate problems to fix.
  commit_msg "feat: vendor trailer alongside a valid one

Co-Authored-By: Atlas
Co-Authored-By: Claude <noreply@anthropic.com>"
  assert_fails_with "1 error(s)" "a vendor trailer carrying the anthropic address is reported once"

  commit_msg "feat: vendor trailer without the address

Co-Authored-By: Atlas
Co-Authored-By: Claude"
  assert_fails_with "vendor attribution is not allowed" "a bare 'Co-Authored-By: Claude' fails"

  commit_msg "feat: paperclip

Co-Authored-By: Atlas
Co-Authored-By: Paperclip <noreply@paperclip.ing>"
  assert_fails_with "Paperclip' is not allowed" "a Paperclip trailer fails by default"
  assert_ok "a Paperclip trailer passes when allow-paperclip-trailer is true" \
    ALLOW_PAPERCLIP_TRAILER=true
  # The input tolerates one line, not a pile of them.
  commit_msg "feat: two paperclips

Co-Authored-By: Atlas
Co-Authored-By: Paperclip <noreply@paperclip.ing>
Co-Authored-By: Paperclip <noreply@paperclip.ing>"
  assert_fails_with "tolerates one" "a second Paperclip trailer fails even when allowed" \
    ALLOW_PAPERCLIP_TRAILER=true

  # The footer lands in the PR body far more often than in a commit message.
  commit_msg "feat: clean commit

Co-Authored-By: Atlas"
  assert_fails_with "vendor attribution is not allowed" "the Claude Code footer in the PR body fails" \
    PR_BODY=$'Adds the thing.\n\nCo-Authored-By: Atlas\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)'
  assert_fails_with "PR body" "the PR body error is labelled as the PR body" \
    PR_BODY=$'Adds the thing.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)'
  assert_fails_with "missing the required trailer" "a PR body with no agent trailer fails" \
    PR_BODY='Adds the thing.'
  assert_ok "a compliant PR body passes" PR_BODY=$'Adds the thing.\n\nCo-Authored-By: Atlas'
  assert_ok "an empty pr-body skips the body check" PR_BODY=''

  # Renovate cannot be asked to write an agent trailer, and blocking its PRs on one would
  # only get the check removed.
  commit_msg "chore(deps): bump something" "renovate[bot]"
  assert_ok "a renovate-authored commit is exempt from the agent trailer"
  assert_fails_with "missing the required trailer" "the exemption is by author, not blanket" \
    EXEMPT_AUTHORS='dependabot[bot]'
  # Exempt only from the trailer requirement; a vendor line is still a vendor line.
  commit_msg "chore(deps): bump something

Co-Authored-By: Claude <noreply@anthropic.com>" "renovate[bot]"
  assert_fails_with "vendor attribution is not allowed" "vendor checks still apply to an exempt author"

  commit_msg "feat: multi-word agent name

Co-Authored-By: Design Lead"
  assert_ok "an agent name containing a space passes"

  commit_msg "feat: trailer with an email

Co-Authored-By: Atlas <atlas@qts.one>"
  assert_ok "an agent trailer with an email suffix passes"

  commit_msg "feat: lowercase key

Co-authored-by: Atlas"
  assert_ok "a lowercase 'Co-authored-by' key is recognised"
  commit_msg "feat: shouting key

CO-AUTHORED-BY: Atlas"
  assert_ok "an uppercase 'CO-AUTHORED-BY' key is recognised"

  # A reference to the trailer in prose is not a trailer; only a line that starts with the
  # key counts, or a PR body explaining the rule could never pass.
  commit_msg "feat: prose mention

The rule asks for a Co-Authored-By: Claude line to be absent.

Co-Authored-By: Atlas"
  assert_ok "a mid-line mention of the key is not treated as a trailer"

  # What GitHub appends to a squash commit when the commit author is not the merger.
  commit_msg "feat: host identity

Co-Authored-By: Atlas
Co-authored-by: iulian <iulian@iulian-macbook.local>"
  assert_fails_with "neither an agent nor Paperclip" "a host-identity co-author fails under the default policy"
  assert_ok_with "::warning::" "a host-identity co-author only warns under extra-coauthor-policy=warn" \
    EXTRA_COAUTHOR_POLICY=warn

  # Configuration mistakes must be loud: each of these would otherwise pass a PR the rule
  # was meant to stop.
  assert_fails_with "must be fail or warn" "an unknown extra-coauthor-policy is an error" \
    EXTRA_COAUTHOR_POLICY=ignore
  assert_fails_with "must be true or false" "a non-boolean allow-paperclip-trailer is an error" \
    ALLOW_PAPERCLIP_TRAILER=yes
  assert_fails_with "agents lists no names" "an empty agents list is an error, not 'accept anything'" \
    AGENTS='   '
  assert_fails_with "nothing to check" "an empty range with an empty body is an error" \
    BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"
  assert_fails_with "fetch-depth" "a sha that is not present locally names the likely cause" \
    BASE_SHA=0123456789012345678901234567890123456789
  assert_fails_with "head-sha is empty" "a base without a head is an error" HEAD_SHA=''

  # First push of a branch: GitHub's all-zero `before` must check the head commit, not die.
  commit_msg "feat: first push on a new branch

Co-Authored-By: Atlas"
  assert_ok "an all-zero base-sha checks the head commit alone" \
    BASE_SHA=0000000000000000000000000000000000000000
  commit_msg "feat: first push, unattributed"
  assert_fails_with "missing the required trailer" "an all-zero base-sha still checks the head commit" \
    BASE_SHA=0000000000000000000000000000000000000000

  # A range, not just a tip: an offending commit in the middle of a PR must be caught.
  local range_base
  range_base="$(git -C "$REPO" rev-parse HEAD)"
  commit_msg "feat: one

Co-Authored-By: Atlas"
  commit_msg "feat: two, unattributed"
  commit_msg "feat: three

Co-Authored-By: Warden"
  assert_fails_with "missing the required trailer" "every commit in the range is checked, not only the head" \
    BASE_SHA="$range_base"
  assert_fails_with "across 3 commit(s)" "the range failure reports all three commits as checked" \
    BASE_SHA="$range_base"

  if [[ $FAILURES -gt 0 ]]; then
    printf '\n%d attribution assertion(s) failed\n' "$FAILURES" >&2
    exit 1
  fi
  printf '\nAll attribution behaviour contracts hold\n'
}

main "$@"
