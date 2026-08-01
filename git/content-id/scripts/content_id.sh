#!/usr/bin/env bash
#
# Digest the git object ids of the tracked paths that can reach a build artifact, so a
# later workflow can ask "has this exact content already been built?" and republish
# instead of rebuilding.
#
# Reads blob ids from the object database, never the working tree, so the id is identical
# between a PR checkout and a tag checkout of the same content — which is the whole point:
# a release commit that only touches a changelog must not move it.
#
# ⚠️ The direction that causes harm is a path that reaches the artifact without being
# hashed here, because that republishes stale bytes. Prefer `exclude` (everything counts
# unless listed, so a new path is covered by default and a wrong list only costs a
# needless rebuild) and reach for `include` only when a denylist would make unrelated
# changes invalidate an artifact that contains none of them.

set -euo pipefail

ref="${REF:-HEAD}"
include="${INCLUDE:-}"
exclude="${EXCLUDE:-}"

if [ -n "${CONFIG:-}" ] && [ -n "${TARGET:-}" ] && [ -f "${CONFIG}" ]; then
  if ! jq -e --arg t "${TARGET}" 'has($t)' "${CONFIG}" >/dev/null; then
    echo "target '${TARGET}' not found in ${CONFIG}" >&2
    exit 1
  fi
  include="$(jq -r --arg t "${TARGET}" '.[$t].include // [] | join("\n")' "${CONFIG}")"
  exclude="$(jq -r --arg t "${TARGET}" '.[$t].exclude // [] | join("\n")' "${CONFIG}")"
fi

if [ -n "${include}" ] && [ -n "${exclude}" ]; then
  echo "give include or exclude, not both — they describe opposite strategies" >&2
  exit 1
fi

listing=""
if [ -n "${include}" ]; then
  paths=()
  while IFS= read -r path; do
    [ -n "${path}" ] || continue
    paths+=("${path}")
  done <<< "$(printf '%s\n' "${include}" | sed '/^[[:space:]]*$/d')"
  listing="$(git ls-tree -r "${ref}" --format='%(objectname) %(path)' -- "${paths[@]}")"
else
  listing="$(git ls-tree -r "${ref}" --format='%(objectname) %(path)')"
  if [ -n "${exclude}" ]; then
    # Anchored at the start of the path so entries match top-level names the way a
    # .dockerignore entry does, rather than any substring.
    filter="$(printf '%s\n' "${exclude}" | sed '/^[[:space:]]*$/d' | sed 's/[.[\*^$]/\\&/g' | paste -sd '|' -)"
    listing="$(printf '%s\n' "${listing}" | grep -vE "^[0-9a-f]+ (${filter})" || true)"
  fi
fi

# An empty listing hashes to the digest of nothing, which is stable across every commit
# and would republish the first artifact ever built onto every later release.
if [ -z "${listing}" ]; then
  echo "no tracked paths matched at ${ref} — refusing to emit the digest of an empty set" >&2
  exit 1
fi

id="$(printf '%s\n' "${listing}" | sha256sum | cut -c1-16)"
echo "id=${id}" >> "${GITHUB_OUTPUT:-/dev/stdout}"
echo "content id (${ref}): ${id}" >&2
