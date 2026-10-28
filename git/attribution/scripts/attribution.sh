#!/usr/bin/env bash
#
# Enforce attribution on the agent-authored commits in a range and on an agent's PR body, and a
# Conventional Commits title on an agent's PR, because the squash makes it the release subject. Each
# branch commit carries exactly one `Co-authored-by: <Name> <email>` roster pair. An agent
# squash commit on `main` may carry several distinct roster pairs, one per contributing agent.
# The PR body carries no `Co-authored-by:` line: the merge step appends the trailers read from
# branch commits. Commits and PRs by anyone else are not agent work and are skipped.
#
# ⚠️ Scope is decided by author email (`%ae`), never by name: `%an` is free text, so a name
# allowlist could be dodged by renaming, while setting an agent email only opts into checks.
#
# ⚠️ A roster name with the wrong or no email is an error, not a pass: GitHub links a
# co-author to an account only through the email, so `Co-authored-by: Atlas` alone credits
# nobody.
#
# ⚠️ The checks run before the merge because the lines this rejects are written by tooling,
# not by a person who can be asked to amend. GitHub appends a `Co-authored-by:` carrying the
# commit author's host identity to a squash commit whenever that author differs from the
# merger, and Claude Code appends its own trailer plus a `Generated with [Claude Code]`
# footer. Once either lands on `main` it is in the published history for good.
#
# ⚠️ Written for bash 3.2 (no `mapfile`, no associative arrays, no `${var,,}`) so the same
# script and its tests run on a macOS workstation as well as on a runner. Keep it that way:
# a bash 4 builtin here is only caught when someone runs the tests locally.

set -euo pipefail

# Keeps tr's character classes and every comparison below off the runner's locale.
export LC_ALL=C

# Lines that mean a vendor claimed authorship, matched as literal substrings anywhere in the
# message rather than only in a trailer, because the Claude Code footer is prose, not a
# trailer, and the anthropic address also arrives as the email half of someone else's line.
VENDOR_NEEDLES=(
  'noreply@anthropic.com'
  'Generated with [Claude Code]'
)

# The one definition of a title semantic-release's Angular analyzer reads. scripts/squash-merge.sh
# fetches the same file from qtsone/actions main, so the check and the merge cannot disagree.
TITLE_PATTERN_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pr-title.ere"

# GitHub sends this as `before` for the first push of a branch: there is no range to walk.
ZERO_SHA="0000000000000000000000000000000000000000"

fatal() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

ERRORS=0
WARNINGS=0

# ::error:: / ::warning:: go to stdout: that is where GitHub reads workflow commands from,
# and it is also what the behaviour tests grep.
emit_error() {
  printf '::error::%s\n' "$1"
  ERRORS=$((ERRORS + 1))
}

emit_warning() {
  printf '::warning::%s\n' "$1"
  WARNINGS=$((WARNINGS + 1))
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# A global is how a bash 3.2 function returns a list.
PARSED_LIST=()
parse_list() {
  PARSED_LIST=()
  local line entry
  while IFS= read -r line; do
    entry="$(trim "$line")"
    [ -n "${entry}" ] || continue
    PARSED_LIST+=("${entry}")
  done <<< "${1:-}"
}

# Case-insensitive: emails and GitHub logins both are.
list_contains() {
  local needle
  needle="$(lower "$1")"
  shift
  local item
  for item in "$@"; do
    [ "$(lower "${item}")" = "${needle}" ] || continue
    return 0
  done
  return 1
}

# GitHub may append a branch author's identity to a web-UI squash. Accept only the known
# shared account names or an agent's git author name, paired with an agent-account email.
is_github_agent_author() {
  local name="$1" email="$2" agent
  list_contains "${email}" "${AGENT_ACCOUNT_LIST[@]}" || return 1
  case "${name}" in
    qtsone-developer | qtsone-reviewer) return 0 ;;
    *' (QTS agent)')
      agent="${name% (QTS agent)}"
      roster_lookup "${agent}"
      return $?
      ;;
  esac
  return 1
}

# Sets ROSTER_INDEX to the position of $1 in ROSTER_NAMES, or -1.
ROSTER_INDEX=-1
roster_lookup() {
  local i
  ROSTER_INDEX=-1
  for i in "${!ROSTER_NAMES[@]}"; do
    [ "${ROSTER_NAMES[$i]}" = "$1" ] || continue
    ROSTER_INDEX=$i
    return 0
  done
  return 1
}

CHECK_LABEL=""
CHECK_ERRORS=0
CHECK_RESULT=""
CHECK_AGENT=""

add_result() {
  if [ -n "${CHECK_RESULT}" ]; then
    CHECK_RESULT="${CHECK_RESULT}; $1"
  else
    CHECK_RESULT="$1"
  fi
}

target_error() {
  emit_error "${CHECK_LABEL}: $1"
  CHECK_ERRORS=$((CHECK_ERRORS + 1))
  add_result "$2"
}

# A shape the cut-over still tolerates: a warning while LEGACY_ACTIVE, an error after.
target_legacy() {
  if [ "${LEGACY_ACTIVE}" = "true" ]; then
    emit_warning "${CHECK_LABEL}: $1 (pre-cut-over form, tolerated until ${LEGACY_UNTIL})"
    add_result "warned: $2"
  else
    target_error "$1" "$2"
  fi
}

# Inspects one commit message (kind `commit`) or PR body (kind `body`). Sets CHECK_ERRORS,
# CHECK_RESULT and CHECK_AGENT for the summary row the caller appends.
check_message() {
  local label="$1" kind="$2" message="$3"
  CHECK_LABEL="${label}"
  CHECK_ERRORS=0
  CHECK_RESULT=""
  CHECK_AGENT=""

  local agent_hits=0 agent_lines="" duplicate_lines="" paperclip_hits=0 extra_lines="" host_lines=""
  local -a seen_agents=("")
  local line lead trimmed lower_key value name email lower_name is_vendor needle expected

  while IFS= read -r line; do
    is_vendor=0
    for needle in "${VENDOR_NEEDLES[@]}"; do
      if [[ "${line}" == *"${needle}"* ]]; then
        target_error "vendor attribution is not allowed: ${line}" "vendor attribution"
        is_vendor=1
        break
      fi
    done

    lead="${line%%[![:space:]]*}"
    trimmed="${line#"${lead}"}"
    lower_key="$(lower "${trimmed}")"
    case "${lower_key}" in
      co-authored-by:*) ;;
      *) continue ;;
    esac

    value="$(trim "${trimmed#*:}")"
    name="${value}"
    email=""
    case "${name}" in
      *'<'*)
        name="$(trim "${value%%<*}")"
        email="${value#*<}"
        email="$(lower "$(trim "${email%%>*}")")"
        ;;
    esac
    lower_name="$(lower "${name}")"

    if [ "${lower_name}" = "claude" ] || [ "${lower_name}" = "claude code" ]; then
      # Already reported when the same line also carried the anthropic address.
      if [ "${is_vendor}" -eq 0 ]; then
        target_error "vendor attribution is not allowed: ${line}" "vendor attribution"
      fi
    elif [ "${kind}" = "body" ]; then
      if roster_lookup "${name}"; then
        target_legacy "the PR body must not carry a Co-authored-by: line; the trailer goes in commit messages and the merge adds it: ${trimmed}" \
          "trailer in PR body"
      else
        target_error "the PR body must not carry a Co-authored-by: line: ${trimmed}" "trailer in PR body"
      fi
    elif roster_lookup "${name}"; then
      expected="Co-authored-by: ${name} <${ROSTER_EMAILS[$ROSTER_INDEX]}>"
      if [ -z "${email}" ]; then
        target_legacy "'${name}' has no email, so GitHub credits nobody; expected '${expected}'" "missing email"
      elif [ "${email}" != "$(lower "${ROSTER_EMAILS[$ROSTER_INDEX]}")" ]; then
        target_legacy "'${name}' carries the wrong email <${email}>; expected '${expected}'" "wrong email"
      fi
      agent_hits=$((agent_hits + 1))
      if [ "${MAIN_PUSH}" = true ] && list_contains "${name}" "${seen_agents[@]}"; then
        duplicate_lines="${duplicate_lines} | ${trimmed}"
      else
        seen_agents+=("${name}")
      fi
      if [ -n "${CHECK_AGENT}" ]; then
        CHECK_AGENT="${CHECK_AGENT}, ${name}"
        agent_lines="${agent_lines} | ${trimmed}"
      else
        CHECK_AGENT="${name}"
        agent_lines="${trimmed}"
      fi
    elif [ "${lower_name}" = "paperclip" ]; then
      paperclip_hits=$((paperclip_hits + 1))
    else
      if [ "${MAIN_PUSH}" = true ] && [ "${POLICY}" = warn ] && \
        [ -n "${email}" ] && is_github_agent_author "${name}" "${email}"; then
        host_lines="${host_lines} | ${trimmed}"
      elif [ -n "${extra_lines}" ]; then
        extra_lines="${extra_lines} | ${trimmed}"
      else
        extra_lines="${trimmed}"
      fi
    fi
  done <<< "${message}"

  if [ "${kind}" = "body" ]; then
    :
  elif [ "${agent_hits}" -eq 0 ]; then
    target_error "missing the required trailer line 'Co-authored-by: <Name> <email>' for one of: ${AGENTS_SUMMARY} (pairs in the action's agents input)" \
      "missing agent trailer"
  elif [ "${MAIN_PUSH}" = true ] && [ -n "${duplicate_lines}" ]; then
    target_error "duplicate agent trailer on main:${duplicate_lines}" "duplicate agent trailer"
  elif [ "${MAIN_PUSH}" = false ] && [ "${agent_hits}" -gt 1 ]; then
    target_error "expected exactly one agent trailer, found ${agent_hits}: ${agent_lines}" \
      "duplicate agent trailer"
  fi

  if [ "${paperclip_hits}" -gt 0 ]; then
    if [ "${MAIN_PUSH}" = true ]; then
      target_error "'Co-Authored-By: Paperclip' is not a roster pair on main" "paperclip trailer"
    elif [ "${ALLOW_PAPERCLIP}" = "true" ]; then
      if [ "${paperclip_hits}" -gt 1 ]; then
        target_error "allow-paperclip-trailer tolerates one 'Co-Authored-By: Paperclip' line, found ${paperclip_hits}" \
          "duplicate paperclip trailer"
      fi
    else
      target_error "'Co-Authored-By: Paperclip' is not allowed while allow-paperclip-trailer is false" \
        "paperclip trailer"
    fi
  fi

  if [ -n "${extra_lines}" ]; then
    if [ "${POLICY}" = "fail" ] || [ "${MAIN_PUSH}" = true ]; then
      target_error "co-author naming neither an agent nor Paperclip: ${extra_lines}" "extra co-author"
    else
      emit_warning "${label}: co-author naming neither an agent nor Paperclip: ${extra_lines}"
      add_result "warned: extra co-author"
    fi
  fi
  if [ -n "${host_lines}" ]; then
    emit_warning "${label}: GitHub-appended agent-account co-author:${host_lines}"
    add_result "warned: GitHub-appended co-author"
  fi

  if [ "${CHECK_ERRORS}" -gt 0 ]; then
    CHECK_RESULT="fail: ${CHECK_RESULT}"
  elif [ -z "${CHECK_RESULT}" ]; then
    CHECK_RESULT="pass"
  else
    CHECK_RESULT="pass (${CHECK_RESULT})"
  fi
}

ROWS=""
add_row() {
  ROWS="${ROWS}| $1 | $2 | $3 | $4 |
"
}

parse_list "${AGENTS:-}"
[ "${#PARSED_LIST[@]}" -gt 0 ] || fatal "agents lists no names — refusing to accept every trailer"
ROSTER_NAMES=()
ROSTER_EMAILS=()
# In a variable because bash 3.2 and 5 disagree on quoting a regex literal after `=~`.
roster_entry_re='^(.*[^[:space:]])[[:space:]]+<([^<>[:space:]]+@[^<>[:space:]]+)>$'
for entry in "${PARSED_LIST[@]}"; do
  [[ "${entry}" =~ ${roster_entry_re} ]] \
    || fatal "agents entry '${entry}' is not 'Name <email>' — a name without its email credits nobody"
  ROSTER_NAMES+=("${BASH_REMATCH[1]}")
  ROSTER_EMAILS+=("${BASH_REMATCH[2]}")
done
AGENTS_SUMMARY="$(printf '%s, ' "${ROSTER_NAMES[@]}")"
AGENTS_SUMMARY="${AGENTS_SUMMARY%, }"

LEGACY_UNTIL="$(trim "${LEGACY_TRAILER_UNTIL:-}")"
LEGACY_ACTIVE=false
if [ -n "${LEGACY_UNTIL}" ]; then
  [[ "${LEGACY_UNTIL}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
    || fatal "legacy-trailer-until must be a YYYY-MM-DD date or empty, got '${LEGACY_UNTIL}'"
  # ISO dates order lexically, so a string comparison is a date comparison.
  if [[ "$(date -u +%Y-%m-%d)" < "${LEGACY_UNTIL}" ]]; then
    LEGACY_ACTIVE=true
  fi
fi

# An empty allowlist would skip every commit and pass everything, silently.
parse_list "${AGENT_ACCOUNTS:-}"
[ "${#PARSED_LIST[@]}" -gt 0 ] || fatal "agent-accounts lists no emails — refusing to skip every commit"
AGENT_ACCOUNT_LIST=("${PARSED_LIST[@]}")

parse_list "${AGENT_LOGINS:-}"
[ "${#PARSED_LIST[@]}" -gt 0 ] || fatal "agent-logins lists no logins — refusing to skip every PR body"
AGENT_LOGIN_LIST=("${PARSED_LIST[@]}")

ALLOW_PAPERCLIP="$(trim "${ALLOW_PAPERCLIP_TRAILER:-false}")"
case "${ALLOW_PAPERCLIP}" in
  true | false) ;;
  *) fatal "allow-paperclip-trailer must be true or false, got '${ALLOW_PAPERCLIP}'" ;;
esac

POLICY="$(trim "${EXTRA_COAUTHOR_POLICY:-fail}")"
case "${POLICY}" in
  fail | warn) ;;
  *) fatal "extra-coauthor-policy must be fail or warn, got '${POLICY}'" ;;
esac

base_sha="$(trim "${BASE_SHA:-}")"
head_sha="$(trim "${HEAD_SHA:-}")"
pr_body="${PR_BODY:-}"
pr_title="${PR_TITLE:-}"
pr_author="$(trim "${PR_AUTHOR:-}")"
MAIN_PUSH=false
[ -n "${pr_author}" ] || MAIN_PUSH=true

[ -s "${TITLE_PATTERN_FILE}" ] || fatal "cannot read the PR title pattern from ${TITLE_PATTERN_FILE}"
title_re="$(cat "${TITLE_PATTERN_FILE}")"

pr_by_agent=false
if [ -n "${pr_author}" ] && list_contains "${pr_author}" "${AGENT_LOGIN_LIST[@]}"; then
  pr_by_agent=true
fi

if [ -n "${base_sha}" ] && [ -z "${head_sha}" ]; then
  fatal "base-sha is set but head-sha is empty — the range to check is undefined"
fi

commits=""
if [ -n "${head_sha}" ]; then
  git rev-parse --git-dir >/dev/null 2>&1 || fatal "not inside a git repository — the action needs a checkout"
  if [ -z "${base_sha}" ] || [ "${base_sha}" = "${ZERO_SHA}" ]; then
    # First push of a branch: GitHub's `before` is all zeros, so `${base}..${head}` would
    # die on `bad object` exactly when a new branch appears. Check the pushed commit alone.
    commits="$(git rev-list -n 1 "${head_sha}")"
  elif ! commits="$(git rev-list "${base_sha}..${head_sha}" 2>&1)"; then
    fatal "cannot walk ${base_sha}..${head_sha}: ${commits} — check out with fetch-depth: 0 so both ends are present"
  fi
fi

# A check that inspected nothing and reported success is worse than no check: it reads as a
# green tick on a PR whose range or body never reached the script.
if [ -z "${commits}" ] && [ -z "$(trim "${pr_body}")" ] && [ -z "$(trim "${pr_title}")" ]; then
  fatal "nothing to check: the commit range, pr-body and pr-title are all empty"
fi

commit_count=0
skipped_count=0
while IFS= read -r sha; do
  [ -n "${sha}" ] || continue
  commit_count=$((commit_count + 1))
  author="$(git log -1 --format='%an <%ae>' "${sha}")"
  if ! list_contains "$(git log -1 --format='%ae' "${sha}")" "${AGENT_ACCOUNT_LIST[@]}"; then
    skipped_count=$((skipped_count + 1))
    printf '%s (%s): skipped: not an agent account\n' "${sha}" "${author}"
    add_row "\`${sha:0:9}\`" "${author}" "—" "skipped: not an agent account"
    continue
  fi
  check_message "${sha}" commit "$(git log -1 --format='%B' "${sha}")"
  add_row "\`${sha:0:9}\`" "${author}" "${CHECK_AGENT:-—}" "${CHECK_RESULT}"
done <<< "${commits}"

body_checked=0
if [ -n "$(trim "${pr_body}")" ]; then
  if [ "${pr_by_agent}" = "true" ]; then
    body_checked=1
    check_message "PR body" body "${pr_body}"
    add_row "PR body" "${pr_author}" "${CHECK_AGENT:-—}" "${CHECK_RESULT}"
  else
    printf 'PR body (%s): skipped: not an agent account\n' "${pr_author:-no PR author}"
    add_row "PR body" "${pr_author:-—}" "—" "skipped: not an agent account"
  fi
fi

title_checked=0
if [ -n "$(trim "${pr_title}")" ]; then
  if [ "${pr_by_agent}" = "true" ]; then
    title_checked=1
    if [[ "${pr_title}" =~ ${title_re} ]]; then
      add_row "PR title" "${pr_author}" "—" "pass"
    else
      emit_error "PR title: '${pr_title}' is not a Conventional Commits subject, so semantic-release ships nothing from it. It must match ${title_re}, e.g. 'fix(auth): refresh expired sessions (QTS-123)'. A breaking change is a 'BREAKING CHANGE:' paragraph in the body, not '!'."
      add_row "PR title" "${pr_author}" "—" "fail: not a Conventional Commits title"
    fi
  else
    printf 'PR title (%s): skipped: not an agent account\n' "${pr_author:-no PR author}"
    add_row "PR title" "${pr_author:-—}" "—" "skipped: not an agent account"
  fi
fi

{
  printf '### Attribution check\n\n'
  printf '| Target | Author | Agent trailer | Result |\n'
  printf '| --- | --- | --- | --- |\n'
  printf '%s' "${ROWS}"
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

if [ "${ERRORS}" -gt 0 ]; then
  printf 'attribution failed: %d error(s) across %d commit(s), %d PR body and %d PR title\n' \
    "${ERRORS}" "${commit_count}" "${body_checked}" "${title_checked}" >&2
  exit 1
fi

printf 'attribution ok: %d commit(s) (%d skipped: not an agent account), %d PR body and %d PR title checked, %d warning(s)\n' \
  "${commit_count}" "${skipped_count}" "${body_checked}" "${title_checked}" "${WARNINGS}" >&2
