#!/usr/bin/env bash
#
# Digest the git object ids of the tracked paths that can reach a build artifact, so a
# later workflow can ask "has this exact content already been built?" and republish
# instead of rebuilding.
#
# Reads modes and blob ids from the object database, never the working tree, so the id is
# identical between a PR checkout and a tag checkout of the same content — which is the
# whole point: a release commit that only touches a changelog must not move it.
#
# ⚠️ The id covers tracked git content and nothing else. Anything else that changes the
# image the caller would have built — build-args, a floating base image tag, a file
# generated during the build — is invisible to it, and a hit republishes an image that no
# longer matches. Fold those inputs into `extra`.
#
# ⚠️ The direction that causes harm is a path that reaches the artifact without being
# hashed here, because that republishes stale bytes. Prefer `exclude` (everything counts
# unless listed, so a new path is covered by default and a wrong list only costs a
# needless rebuild) and reach for `include` only when a denylist would make unrelated
# changes invalidate an artifact that contains none of them.

set -euo pipefail

# The id must not vary with the runner's locale, which would otherwise reach it via sort.
export LC_ALL=C

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

# core.quotePath decides whether non-ASCII paths are emitted escaped, so pinning it keeps
# the id off a runner's global git config.
ls_tree() {
  git -c core.quotePath=true ls-tree -r "$@"
}

strip_blank() {
  printf '%s\n' "$1" | sed '/^[[:space:]]*$/d'
}

ref="${REF:-HEAD}"
include="$(strip_blank "${INCLUDE:-}")"
exclude="$(strip_blank "${EXCLUDE:-}")"
extra="$(strip_blank "${EXTRA:-}")"

# An include that is set but blank — an expression that rendered to nothing, say — would
# otherwise fall through to the exclude branch and hash the whole tree, turning a narrow
# allowlist into "everything" without a word. The same slip on exclude only costs a
# rebuild, so it is left alone rather than failing a caller that renders an empty list.
if [ -n "${INCLUDE:-}" ] && [ -z "${include}" ]; then
  fail "include is set but lists no paths"
fi

if [ -n "${TARGET:-}" ]; then
  # The config wins, so accepting both would mean silently ignoring whichever the caller
  # believed was in effect.
  if [ -n "${include}" ] || [ -n "${exclude}" ] || [ -n "${extra}" ]; then
    fail "target reads include/exclude/extra from the config file; do not also pass them directly"
  fi
  [ -n "${CONFIG:-}" ] || fail "target '${TARGET}' given but config is empty"
  [ -f "${CONFIG}" ] || fail "target '${TARGET}' given but ${CONFIG} does not exist"
  jq -e --arg t "${TARGET}" 'has($t)' "${CONFIG}" >/dev/null \
    || fail "target '${TARGET}' not found in ${CONFIG}"

  # An include key that is present but empty means "hash nothing", which would otherwise
  # fall through to the exclude branch and quietly hash the whole tree instead.
  if jq -e --arg t "${TARGET}" '.[$t] | has("include") and (.include | length) == 0' "${CONFIG}" >/dev/null; then
    fail "target '${TARGET}' declares an empty include list in ${CONFIG}"
  fi

  include="$(strip_blank "$(jq -r --arg t "${TARGET}" '.[$t].include // [] | join("\n")' "${CONFIG}")")"
  exclude="$(strip_blank "$(jq -r --arg t "${TARGET}" '.[$t].exclude // [] | join("\n")' "${CONFIG}")")"
  extra="$(strip_blank "$(jq -r --arg t "${TARGET}" '.[$t].extra // [] | join("\n")' "${CONFIG}")")"
fi

if [ -n "${include}" ] && [ -n "${exclude}" ]; then
  fail "give include or exclude, not both — they describe opposite strategies"
fi

# %(objectmode) is load-bearing: a chmod +x moves the tree entry's mode while leaving the
# blob id alone, so without it a commit that only makes an entrypoint executable hits the
# cache and republishes the image where it is not.
tree_format='%(objectmode) %(objectname) %(path)'

listing=""
if [ -n "${include}" ]; then
  # Resolved one pathspec at a time: `git ls-tree` prints nothing and exits 0 for a
  # pathspec that matches no tracked entry, so a typo inside a list would silently drop
  # that path from the id forever and every later change to it would promote stale bytes.
  while IFS= read -r path; do
    [ -n "${path}" ] || continue
    entries="$(ls_tree "${ref}" --format="${tree_format}" -- "${path}")"
    [ -n "${entries}" ] || fail "include path matched no tracked entry at ${ref}: ${path}"
    listing="${listing}${entries}
"
  done <<< "${include}"

  # Two overlapping pathspecs would otherwise list a file twice, and per-pathspec
  # resolution leaves entries grouped by pathspec rather than globally ordered.
  listing="$(printf '%s' "${listing}" | sort -u)"
else
  listing="$(ls_tree "${ref}" --format="${tree_format}")"
  if [ -n "${exclude}" ]; then
    # Whole path components, compared as literal prefixes rather than as a regex, so
    # `docs` cannot also drop `docker/` and a path containing regex metacharacters is
    # excluded as written.
    listing="$(
      printf '%s\n' "${listing}" \
        | EXCLUDES="$(printf '%s\n' "${exclude}" | sed 's#/*$##')" awk '
            BEGIN { n = split(ENVIRON["EXCLUDES"], ex, "\n") }
            {
              path = $0
              sub(/^[0-9]+ [0-9a-f]+ /, "", path)
              for (i = 1; i <= n; i++) {
                if (ex[i] == "") continue
                if (path == ex[i] || index(path, ex[i] "/") == 1) next
              }
              print
            }
          '
    )"
  fi
fi

# An empty listing hashes to the digest of nothing, which is stable across every commit
# and would republish the first artifact ever built onto every later release.
if [ -z "${listing}" ]; then
  fail "no tracked paths matched at ${ref} — refusing to emit the digest of an empty set"
fi

# Sorted so the id does not depend on the order the caller happened to list them in.
if [ -n "${extra}" ]; then
  listing="${listing}
$(printf '%s\n' "${extra}" | sed 's/^/extra /' | sort)"
fi

id="$(printf '%s\n' "${listing}" | sha256sum | cut -c1-16)"
echo "id=${id}" >> "${GITHUB_OUTPUT:-/dev/stdout}"
echo "content id (${ref}): ${id}" >&2
