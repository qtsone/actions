#!/usr/bin/env bash
#
# Enforce one attribution line on every commit in a range and on the PR body: exactly one
# `Co-Authored-By: <Agent Name>` naming a known agent, and nothing else in that role.
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

list_contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [ "${item}" = "${needle}" ] || continue
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

# Inspects one commit message or PR body. Sets CHECK_ERRORS, CHECK_RESULT and CHECK_AGENT
# for the summary row the caller appends.
check_message() {
  local label="$1" exempt="$2" message="$3"
  CHECK_LABEL="${label}"
  CHECK_ERRORS=0
  CHECK_RESULT=""
  CHECK_AGENT=""

  local agent_hits=0 agent_lines="" paperclip_hits=0 extra_lines=""
  local line lead trimmed lower_key value name lower_name is_vendor needle

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
    case "${name}" in
      *'<'*) name="$(trim "${name%%<*}")" ;;
    esac
    lower_name="$(lower "${name}")"

    if [ "${lower_name}" = "claude" ] || [ "${lower_name}" = "claude code" ]; then
      # Already reported when the same line also carried the anthropic address.
      if [ "${is_vendor}" -eq 0 ]; then
        target_error "vendor attribution is not allowed: ${line}" "vendor attribution"
      fi
    elif list_contains "${name}" "${AGENTS_LIST[@]}"; then
      agent_hits=$((agent_hits + 1))
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
      if [ -n "${extra_lines}" ]; then
        extra_lines="${extra_lines} | ${trimmed}"
      else
        extra_lines="${trimmed}"
      fi
    fi
  done <<< "${message}"

  if [ "${exempt}" = "true" ]; then
    add_result "exempt author"
  elif [ "${agent_hits}" -eq 0 ]; then
    target_error "missing the required trailer line 'Co-Authored-By: <Agent Name>', one of: ${AGENTS_SUMMARY}" \
      "missing agent trailer"
  elif [ "${agent_hits}" -gt 1 ]; then
    target_error "expected exactly one agent trailer, found ${agent_hits}: ${agent_lines}" \
      "duplicate agent trailer"
  fi

  if [ "${paperclip_hits}" -gt 0 ]; then
    if [ "${ALLOW_PAPERCLIP}" = "true" ]; then
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
    if [ "${POLICY}" = "fail" ]; then
      target_error "co-author naming neither an agent nor Paperclip: ${extra_lines}" "extra co-author"
    else
      emit_warning "${label}: co-author naming neither an agent nor Paperclip: ${extra_lines}"
      add_result "warned: extra co-author"
    fi
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
AGENTS_LIST=("${PARSED_LIST[@]}")
AGENTS_SUMMARY="$(printf '%s, ' "${AGENTS_LIST[@]}")"
AGENTS_SUMMARY="${AGENTS_SUMMARY%, }"

parse_list "${EXEMPT_AUTHORS:-}"
EXEMPT_LIST=()
if [ "${#PARSED_LIST[@]}" -gt 0 ]; then
  EXEMPT_LIST=("${PARSED_LIST[@]}")
fi

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
if [ -z "${commits}" ] && [ -z "$(trim "${pr_body}")" ]; then
  fatal "nothing to check: the commit range is empty and pr-body is empty"
fi

commit_count=0
while IFS= read -r sha; do
  [ -n "${sha}" ] || continue
  commit_count=$((commit_count + 1))
  author="$(git log -1 --format='%an' "${sha}")"
  exempt=false
  if [ "${#EXEMPT_LIST[@]}" -gt 0 ] && list_contains "${author}" "${EXEMPT_LIST[@]}"; then
    exempt=true
  fi
  check_message "${sha}" "${exempt}" "$(git log -1 --format='%B' "${sha}")"
  add_row "\`${sha:0:9}\`" "${author}" "${CHECK_AGENT:-—}" "${CHECK_RESULT}"
done <<< "${commits}"

body_checked=0
if [ -n "$(trim "${pr_body}")" ]; then
  body_checked=1
  check_message "PR body" "false" "${pr_body}"
  add_row "PR body" "—" "${CHECK_AGENT:-—}" "${CHECK_RESULT}"
fi

{
  printf '### Attribution check\n\n'
  printf '| Target | Author | Agent trailer | Result |\n'
  printf '| --- | --- | --- | --- |\n'
  printf '%s' "${ROWS}"
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

if [ "${ERRORS}" -gt 0 ]; then
  printf 'attribution failed: %d error(s) across %d commit(s) and %d PR body\n' \
    "${ERRORS}" "${commit_count}" "${body_checked}" >&2
  exit 1
fi

printf 'attribution ok: %d commit(s) and %d PR body checked, %d warning(s)\n' \
  "${commit_count}" "${body_checked}" "${WARNINGS}" >&2
