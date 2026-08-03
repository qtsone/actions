#!/usr/bin/env bash
#
# Republish an image the registry already holds under a new set of tags, using a
# registry-side manifest copy. No layer is transferred and no build runs.
#
# The caller names the source, so this is only as safe as the source tag's meaning. Used
# with a content id, a hit means the *tracked git content* matches — not that the bytes
# are identical, because build-args and floating base images do not reach that id unless
# the caller folded them in (see git/content-id `extra`).
#
# A source that is absent reports promoted=false and exits 0 so the caller can fall back
# to building. Every other failure — auth, rate limit, network, a registry 5xx — is a hard
# error, because reporting those as "never built" would hide a broken registry behind a
# silent full rebuild on every run.
#
# Annotations exist because a promoted image keeps the labels it was built with — a
# release published from a PR build carries that PR's version label. An OCI annotation on
# the manifest is the place to record what it is now, without rebuilding a layer.

set -euo pipefail

output_file="${GITHUB_OUTPUT:-/dev/stdout}"

image="${REGISTRY}/${IMAGE_NAME}"
src="${image}:${SOURCE_TAG}"

if ! inspect_error="$(docker buildx imagetools inspect "${src}" 2>&1 >/dev/null)"; then
  case "${inspect_error}" in
    *"not found"*|*"NAME_UNKNOWN"*|*"MANIFEST_UNKNOWN"*|*"manifest unknown"*|*"no such manifest"*)
      echo "promoted=false" >> "${output_file}"
      echo "miss: ${src} is not in the registry" >&2
      exit 0
      ;;
  esac
  printf 'ERROR: cannot read %s: %s\n' "${src}" "${inspect_error}" >&2
  exit 1
fi

first_tag=""
args=()
while IFS= read -r tag; do
  [ -n "${tag}" ] || continue
  case "${tag}" in
    *:*) ;;
    *) tag="${image}:${tag}" ;;
  esac
  [ -n "${first_tag}" ] || first_tag="${tag}"
  args+=(--tag "${tag}")
done <<< "${TAGS}"

if [ -z "${first_tag}" ]; then
  echo "ERROR: no tags given to promote ${src} to" >&2
  exit 1
fi

while IFS= read -r annotation; do
  [ -n "${annotation}" ] || continue
  args+=(--annotation "${annotation}")
done <<< "${ANNOTATIONS:-}"

docker buildx imagetools create "${args[@]}" "${src}"

# Read back from a tag that was just created, not from the source. `imagetools create` is
# a carbon copy only for an index source with no annotations; annotating rewrites the
# index, and a single-platform source gets wrapped into one. Both give the new tags a
# different digest than the source, and it is the new tags a deployment will pin.
digest="$(docker buildx imagetools inspect "${first_tag}" --format '{{.Manifest.Digest}}')"
{
  echo "promoted=true"
  echo "digest=${digest}"
} >> "${output_file}"

echo "promoted ${src} -> ${first_tag} (${digest})" >&2
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  # Neutral wording: the same script also publishes a content tag from a build that just
  # ran, where "no rebuild" would be a lie.
  echo "- Registry copy: \`${src}\` -> \`${first_tag}\`" >> "${GITHUB_STEP_SUMMARY}"
fi
