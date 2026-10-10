#!/usr/bin/env bash
#
# Behavioural tests for git/attribution. The check decides whether a PR can be merged, so the
# cases that matter are the shapes real tooling produces: the Claude Code trailer and footer,
# the host-identity co-author GitHub appends to a squash commit, and commits and PRs by people
# and bots, which are not agent work and are not checked at all.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ATTRIBUTION_SCRIPT="$ROOT_DIR/git/attribution/scripts/attribution.sh"
ACTION_YAML="$ROOT_DIR/git/attribution/action.yaml"

# The agent, agent-account and agent-login lists are declared once, in action.yaml, and read from there
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
DEFAULT_AGENT_ACCOUNTS="$(action_default_list agent-accounts)"
DEFAULT_AGENT_LOGINS="$(action_default_list agent-logins)"

# What an agent's branch commits are authored as (company file §10).
AGENT_AUTHOR="Atlas (QTS agent) <336271639+qtsone-developer@users.noreply.github.com>"
OWNER_AUTHOR="Iulian Bacalu <ibacalu@icloud.com>"

# The trailer line for a roster name, built from the default roster for the same reason.
trailer_for() {
  printf 'Co-authored-by: %s\n' "$(printf '%s\n' "$DEFAULT_AGENTS" | grep "^$1 <")"
}
ATLAS="$(trailer_for Atlas)"
WARDEN="$(trailer_for Warden)"
JOHN="$(trailer_for John)"

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

$ATLAS"
}

# Appends one commit whose message is $1, authored by $2 (`Name <email>`, default an agent).
# --allow-empty keeps the fixtures about the message and author, which is all the script reads.
commit_msg() {
  local message="$1" author="${2:-$AGENT_AUTHOR}"
  git -C "$REPO" commit -q --allow-empty --author="${author}" -F - <<< "$message"
}

# Runs the script over HEAD~1..HEAD with the default lists, a PR opened by an agent, and no
# cut-over grace. Extra NAME=VALUE arguments override anything set here, because env applies
# assignments left to right.
LAST_OUT=""
attribution() {
  local base head rc
  base="$(git -C "$REPO" rev-parse HEAD~1)"
  head="$(git -C "$REPO" rev-parse HEAD)"
  set +e
  LAST_OUT="$(
    cd "$REPO" && env -u GITHUB_STEP_SUMMARY -u GITHUB_OUTPUT \
      AGENTS="$DEFAULT_AGENTS" AGENT_ACCOUNTS="$DEFAULT_AGENT_ACCOUNTS" \
      AGENT_LOGINS="$DEFAULT_AGENT_LOGINS" PR_AUTHOR=qtsone-developer LEGACY_TRAILER_UNTIL='' \
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
  [[ "$ATLAS" == *"+qts-atlas[bot]@users.noreply.github.com>" ]] \
    || { printf 'FAIL: could not read the agents default out of %s\n' "$ACTION_YAML" >&2; exit 1; }
  local agent_email="${AGENT_AUTHOR#*<}"
  [[ $'\n'"$DEFAULT_AGENT_ACCOUNTS"$'\n' == *$'\n'"${agent_email%>}"$'\n'* ]] \
    || { printf 'FAIL: could not read the agent-accounts default out of %s\n' "$ACTION_YAML" >&2; exit 1; }
  [[ "$DEFAULT_AGENT_LOGINS" == *qtsone-developer* ]] \
    || { printf 'FAIL: could not read the agent-logins default out of %s\n' "$ACTION_YAML" >&2; exit 1; }
  setup_repo

  # The shape every agent commit is supposed to have.
  commit_msg "feat: a change

$ATLAS"
  assert_ok "a roster name with its email passes"
  # The sha has to be in the annotation, or a failing PR with twenty commits says nothing
  # about which one to amend.
  assert_ok_with "$(git -C "$REPO" rev-parse --short=9 HEAD)" "the summary row names the commit"

  # The email is what makes GitHub show the co-author; without it the trailer credits nobody.
  commit_msg "feat: name only

Co-authored-by: Atlas"
  assert_fails_with "has no email" "a roster name without an email fails"
  assert_fails_with "$ATLAS" "the missing-email error spells out the expected line"
  commit_msg "feat: wrong email

Co-authored-by: Atlas <atlas@qts.one>"
  assert_fails_with "wrong email" "a roster name with another email fails"
  commit_msg "feat: another agent's email

Co-authored-by: Atlas ${WARDEN#*Warden }"
  assert_fails_with "wrong email" "a roster name with another agent's email fails"
  commit_msg "feat: email in capitals

$(printf '%s' "$ATLAS" | tr '[:lower:]' '[:upper:]' | sed 's/^CO-AUTHORED-BY: ATLAS/Co-authored-by: Atlas/')"
  assert_ok "the email is compared case-insensitively"

  commit_msg "feat: no attribution at all"
  assert_fails_with "missing the required trailer" "a commit with no agent trailer fails"
  assert_fails_with "$(git -C "$REPO" rev-parse HEAD)" "the missing-trailer error names the sha"

  commit_msg "feat: two agents

$ATLAS
$WARDEN"
  assert_fails_with "found 2" "two agent trailers fail"

  # What Claude Code writes unless told otherwise.
  commit_msg "feat: vendor trailer

Co-Authored-By: Claude <noreply@anthropic.com>"
  assert_fails_with "vendor attribution is not allowed" "a vendor trailer fails"

  # The same line matches both the anthropic needle and the Claude trailer name, and must
  # still be reported once — a doubled annotation reads as two separate problems to fix.
  commit_msg "feat: vendor trailer alongside a valid one

$ATLAS
Co-Authored-By: Claude <noreply@anthropic.com>"
  assert_fails_with "1 error(s)" "a vendor trailer carrying the anthropic address is reported once"

  commit_msg "feat: vendor trailer without the address

$ATLAS
Co-Authored-By: Claude"
  assert_fails_with "vendor attribution is not allowed" "a bare 'Co-Authored-By: Claude' fails"

  commit_msg "feat: paperclip

$ATLAS
Co-Authored-By: Paperclip <noreply@paperclip.ing>"
  assert_fails_with "Paperclip' is not allowed" "a Paperclip trailer fails by default"
  assert_ok "a Paperclip trailer passes when allow-paperclip-trailer is true" \
    ALLOW_PAPERCLIP_TRAILER=true
  # The input tolerates one line, not a pile of them.
  commit_msg "feat: two paperclips

$ATLAS
Co-Authored-By: Paperclip <noreply@paperclip.ing>
Co-Authored-By: Paperclip <noreply@paperclip.ing>"
  assert_fails_with "tolerates one" "a second Paperclip trailer fails even when allowed" \
    ALLOW_PAPERCLIP_TRAILER=true

  # The squash puts the PR body on `main` and the merge appends the trailer read from the
  # branch commits, so any trailer already in the body would land twice or unchecked.
  commit_msg "feat: clean commit

$ATLAS"
  assert_ok "a PR body with no trailer passes" PR_BODY='Adds the thing.'
  assert_fails_with "must not carry a Co-authored-by" "a PR body carrying the correct trailer fails" \
    PR_BODY=$'Adds the thing.\n\n'"$ATLAS"
  assert_fails_with "must not carry a Co-authored-by" "a PR body carrying the old name-only trailer fails" \
    PR_BODY=$'Adds the thing.\n\nCo-Authored-By: Atlas'
  assert_fails_with "must not carry a Co-authored-by" "a PR body carrying a non-agent co-author fails" \
    PR_BODY=$'Adds the thing.\n\nCo-authored-by: someone <someone@example.invalid>' EXTRA_COAUTHOR_POLICY=warn
  assert_fails_with "must not carry a Co-authored-by" "a PR body carrying a Paperclip trailer fails even when allowed" \
    PR_BODY=$'Adds the thing.\n\nCo-Authored-By: Paperclip <noreply@paperclip.ing>' ALLOW_PAPERCLIP_TRAILER=true
  # The footer lands in the PR body far more often than in a commit message.
  assert_fails_with "vendor attribution is not allowed" "the Claude Code footer in the PR body fails" \
    PR_BODY=$'Adds the thing.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)'
  assert_fails_with "PR body" "the PR body error is labelled as the PR body" \
    PR_BODY=$'Adds the thing.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)'
  assert_ok "an empty pr-body skips the body check" PR_BODY=''

  # Cut-over: a pull request opened under the old rule has name-only commit trailers and the
  # trailer in its body. Before legacy-trailer-until both only warn; from that day both fail.
  commit_msg "feat: opened before the cut-over

Co-Authored-By: Atlas"
  assert_ok_with "tolerated until 2999-01-01" "a name-only trailer warns inside the grace window" \
    LEGACY_TRAILER_UNTIL=2999-01-01 PR_BODY=$'Adds the thing.\n\nCo-Authored-By: Atlas'
  assert_fails_with "has no email" "a name-only trailer fails once the grace window has passed" \
    LEGACY_TRAILER_UNTIL=2000-01-01
  assert_fails_with "must not carry a Co-authored-by" "a body trailer fails once the grace window has passed" \
    LEGACY_TRAILER_UNTIL=2000-01-01 PR_BODY=$'Adds the thing.\n\n'"$ATLAS"
  # The grace covers the old agent trailer only; it never lets a stranger into the body.
  assert_fails_with "must not carry a Co-authored-by" "the grace window does not tolerate a non-agent body co-author" \
    LEGACY_TRAILER_UNTIL=2999-01-01 PR_BODY=$'Adds the thing.\n\nCo-authored-by: someone <someone@example.invalid>'
  assert_fails_with "must be a YYYY-MM-DD date" "a malformed legacy-trailer-until is an error" \
    LEGACY_TRAILER_UNTIL=24/10/2026

  # The squash commit `main` gets from an owner merge in the browser: the PR body, then the
  # lines GitHub appends — the agent trailer from the branch commits and the branch author's
  # host identity. The `push` callers run with extra-coauthor-policy=warn for exactly this.
  commit_msg "feat: merged in the web UI (#99)

Adds the thing.

$ATLAS
Co-authored-by: qtsone-developer <developer@qts.one>"
  assert_ok_with "::warning::" "GitHub-appended lines on a web-UI squash are tolerated on main" \
    PR_BODY='' EXTRA_COAUTHOR_POLICY=warn
  commit_msg "feat: merged by Warden (#100)

Adds the thing.

$ATLAS"
  assert_ok "a Warden squash with the one appended trailer passes on main" PR_BODY=''

  # Only agent work is checked (owner, QTS-1381). A person's or a bot's commit is skipped
  # whole, vendor lines included.
  commit_msg "feat: the owner's own change" "$OWNER_AUTHOR"
  assert_ok_with "skipped: not an agent account" "an owner commit with no trailer passes"
  commit_msg "feat: the owner's own change

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>" "$OWNER_AUTHOR"
  assert_ok "an owner commit carrying the Claude Code footer passes"
  commit_msg "chore(deps): bump something" "renovate[bot] <29139614+renovate[bot]@users.noreply.github.com>"
  assert_ok "a renovate commit passes"
  # The squash identity of an agent PR on `main`, and the email matched case-insensitively.
  commit_msg "feat: squashed agent PR without a trailer (#101)" "qtsone-developer <developer@qts.one>"
  assert_fails_with "missing the required trailer" "a developer@qts.one commit without a trailer fails"
  commit_msg "feat: shouted email" "qtsone-developer <Developer@QTS.one>"
  assert_fails_with "missing the required trailer" "the author email is matched case-insensitively"
  # Scope follows the email: a name is free text, so renaming must neither dodge nor trigger it.
  commit_msg "feat: agent account under a person's name" "Iulian Bacalu <developer@qts.one>"
  assert_fails_with "missing the required trailer" "an agent email under another name is still checked"
  commit_msg "feat: a person under an agent's name" "Atlas (QTS agent) <ibacalu@icloud.com>"
  assert_ok_with "skipped: not an agent account" "an agent name on a person's email is skipped"
  assert_fails_with "missing the required trailer" "agent-accounts replaces the default list" \
    AGENT_ACCOUNTS='ibacalu@icloud.com'

  # The PR body is checked only on a PR an agent account opened.
  commit_msg "feat: clean commit

$ATLAS"
  assert_ok_with "skipped: not an agent account" "a body co-author on a PR opened by the owner passes" \
    PR_AUTHOR=ibacalu PR_BODY=$'Adds the thing.\n\nCo-authored-by: someone <someone@example.invalid>'
  assert_fails_with "must not carry a Co-authored-by" "the same body on a PR opened by qtsone-developer fails" \
    PR_AUTHOR=qtsone-developer PR_BODY=$'Adds the thing.\n\nCo-authored-by: someone <someone@example.invalid>'
  assert_fails_with "must not carry a Co-authored-by" "the PR author login is matched case-insensitively" \
    PR_AUTHOR=QTSone-Reviewer PR_BODY=$'Adds the thing.\n\nCo-authored-by: someone <someone@example.invalid>'
  assert_ok_with "skipped: not an agent account" "an empty pr-author skips the body check" \
    PR_AUTHOR='' PR_BODY=$'Adds the thing.\n\nCo-authored-by: someone <someone@example.invalid>'

  # No name on the current roster contains a space, so this drives the capability through a
  # caller-supplied `agents` input — which is how a future multi-word name would arrive — and
  # not through a default-roster name that a re-org can delete.
  commit_msg "feat: multi-word agent name

Co-authored-by: Multi Word Agent <multi@example.invalid>"
  assert_ok "an agent name containing a space passes" \
    AGENTS=$'Multi Word Agent <multi@example.invalid>\nAtlas <atlas@example.invalid>'
  assert_fails_with "is not 'Name <email>'" "a roster entry without an email is an error" \
    AGENTS=$'Multi Word Agent\nAtlas <atlas@example.invalid>'

  # Roster drift is what this action gets wrong when nothing checks it: on the 2026-10-02
  # re-org the default still rejected John — a live agent whose CI would have gone red on
  # every caller — and still accepted four terminated personas. Both directions are asserted
  # against the default list, so the next re-org fails here rather than in a product repo.
  commit_msg "feat: a renamed agent

$JOHN"
  assert_ok "a current agent on the default roster passes"
  commit_msg "feat: a terminated persona

Co-Authored-By: CTO"
  assert_fails_with "missing the required trailer" "a terminated persona cannot claim authorship"

  commit_msg "feat: house-style key

$ATLAS"
  assert_ok "a 'Co-authored-by' key is recognised"
  commit_msg "feat: title-case key

Co-Authored-By: ${ATLAS#Co-authored-by: }"
  assert_ok "a 'Co-Authored-By' key is recognised"
  commit_msg "feat: shouting key

CO-AUTHORED-BY: ${ATLAS#Co-authored-by: }"
  assert_ok "an uppercase 'CO-AUTHORED-BY' key is recognised"

  # A reference to the trailer in prose is not a trailer; only a line that starts with the
  # key counts, or a PR body explaining the rule could never pass.
  commit_msg "feat: prose mention

The rule asks for a Co-Authored-By: Claude line to be absent.

$ATLAS"
  assert_ok "a mid-line mention of the key is not treated as a trailer" \
    PR_BODY='The rule asks for no Co-authored-by: line in this body.'

  # What GitHub appends to a squash commit when the commit author is not the merger.
  commit_msg "feat: host identity

$ATLAS
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
  assert_fails_with "agent-accounts lists no emails" "an empty agent-accounts list is an error, not 'skip everything'" \
    AGENT_ACCOUNTS='   '
  assert_fails_with "agent-logins lists no logins" "an empty agent-logins list is an error, not 'skip every body'" \
    AGENT_LOGINS='   '
  assert_fails_with "nothing to check" "an empty range with an empty body is an error" \
    BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"
  assert_fails_with "fetch-depth" "a sha that is not present locally names the likely cause" \
    BASE_SHA=0123456789012345678901234567890123456789
  assert_fails_with "head-sha is empty" "a base without a head is an error" HEAD_SHA=''

  # First push of a branch: GitHub's all-zero `before` must check the head commit, not die.
  commit_msg "feat: first push on a new branch

$ATLAS"
  assert_ok "an all-zero base-sha checks the head commit alone" \
    BASE_SHA=0000000000000000000000000000000000000000
  commit_msg "feat: first push, unattributed"
  assert_fails_with "missing the required trailer" "an all-zero base-sha still checks the head commit" \
    BASE_SHA=0000000000000000000000000000000000000000

  # A range, not just a tip: an offending commit in the middle of a PR must be caught.
  local range_base
  range_base="$(git -C "$REPO" rev-parse HEAD)"
  commit_msg "feat: one

$ATLAS"
  commit_msg "feat: two, unattributed"
  commit_msg "feat: three

$WARDEN"
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
