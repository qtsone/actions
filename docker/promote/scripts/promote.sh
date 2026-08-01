#!/usr/bin/env bash
#
# Republish an image the registry already holds under a new set of tags, using a
# registry-side manifest copy. No layer is transferred and no build runs.
#
# Safe because the caller names the content: content-tag is a digest of the sources that
# reach the image, so a hit means the bytes are the ones this build would have produced.
# A miss reports promoted=false and the caller falls back to building, which makes the
# worst case identical to not using this action at all.
#
# Annotations exist because a promoted image keeps the labels it was built with — a
# release published from a PR build carries that PR's version label. An OCI annotation on
# the manifest is the place to record what it is now, without rebuilding a layer.

set -euo pipefail

image="${REGISTRY}/${IMAGE_NAME}"
src="${image}:${CONTENT_TAG}"

if ! docker buildx imagetools inspect "${src}" >/dev/null 2>&1; then
  echo "promoted=false" >> "${GITHUB_OUTPUT}"
  echo "miss: ${src} is not in the registry" >&2
  exit 0
fi

args=()
while IFS= read -r tag; do
  [ -n "${tag}" ] || continue
  case "${tag}" in
    *:*) args+=(--tag "${tag}") ;;
    *)   args+=(--tag "${image}:${tag}") ;;
  esac
done <<< "${TAGS}"

if [ "${#args[@]}" -eq 0 ]; then
  echo "no tags given to promote ${src} to" >&2
  exit 1
fi

while IFS= read -r annotation; do
  [ -n "${annotation}" ] || continue
  args+=(--annotation "${annotation}")
done <<< "${ANNOTATIONS:-}"

docker buildx imagetools create "${args[@]}" "${src}"

digest="$(docker buildx imagetools inspect "${src}" --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
{
  echo "promoted=true"
  echo "digest=${digest}"
} >> "${GITHUB_OUTPUT}"

echo "promoted ${src}" >&2
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "- Promoted \`${src}\` — no rebuild" >> "${GITHUB_STEP_SUMMARY}"
fi
