#!/usr/bin/env bash
#
# Decide whether a preview image may be labelled ready, and publish the action's outputs.
#
# This is the deploy gate. ArgoCD's PR generator selects on the ready label, so
# ready_allowed=true is what puts an image in front of a cluster — nothing upstream of
# here holds it back, since the build now pushes before the scan runs.

set -euo pipefail

output_file="${GITHUB_OUTPUT:-/dev/stdout}"
summary_file="${GITHUB_STEP_SUMMARY:-/dev/stderr}"

scan_required="${SCAN_REQUIRED:-false}"
scan_pass="true"
if [ "${TRIVY_OUTCOME:-}" != "success" ]; then
  scan_pass="false"
fi

stale_pr_head="${STALE_PR_HEAD:-}"
if [ -z "${stale_pr_head}" ]; then
  stale_pr_head="false"
fi

build_pass="false"
push_pass="false"

if [ "${BUILD_OUTCOME:-}" = "success" ]; then
  build_pass="true"
fi

if [ "${PREVIEW_PUSH_ENABLED:-}" = "true" ]; then
  if [ "${PUSH_OUTCOME:-}" = "success" ]; then
    push_pass="true"
  fi
else
  push_pass="true"
fi

ready_allowed="false"
if [ "${ELIGIBLE:-}" = "true" ] && [ "${READY_LABEL_ENABLED:-}" = "true" ] && [ "${build_pass}" = "true" ] && [ "${push_pass}" = "true" ] && [ "${stale_pr_head}" != "true" ]; then
  if [ "${scan_required}" = "true" ]; then
    if [ "${scan_pass}" = "true" ]; then
      ready_allowed="true"
    fi
  else
    ready_allowed="true"
  fi
fi

# The digest outputs are a handoff into deployment (kustomize/update-image new-ref), so
# they are withheld under exactly the conditions that used to stop the separate push step
# from running. Emitting a usable reference to an image that failed a required scan would
# let a caller deploy it without ever consulting ready_allowed.
publish_allowed="false"
if [ "${PUSH_OUTCOME:-}" = "success" ] && [ "${stale_pr_head}" != "true" ]; then
  if [ "${scan_required}" != "true" ] || [ "${scan_pass}" = "true" ]; then
    publish_allowed="true"
  fi
fi

tags="${IMAGE_TAG:-}"
digest=""
image_digest=""
if [ "${publish_allowed}" = "true" ]; then
  digest="${PUSH_DIGEST:-}"
fi
if [ -n "${digest}" ]; then
  image_digest="${IMAGE:-}@${digest}"
fi

{
  echo "image=${IMAGE:-}"
  echo "tag=${TAG:-}"
  echo "image-tag=${IMAGE_TAG:-}"
  echo "digest=${digest}"
  echo "image-digest=${image_digest}"
  echo "ready_allowed=${ready_allowed}"
  echo "stale_pr_head=${stale_pr_head}"
  echo "tags<<EOF"
  printf '%s\n' "${tags}"
  echo "EOF"
} >> "${output_file}"

{
  echo "- Build outcome: ${BUILD_OUTCOME:-} (promoted=${PROMOTED:-false})"
  echo "- Hadolint outcome: ${HADOLINT_OUTCOME:-}"
  echo "- Scan outcome: ${TRIVY_OUTCOME:-} (scan_required=${scan_required})"
  echo "- Push outcome: ${PUSH_OUTCOME:-skipped} (preview_push_enabled=${PREVIEW_PUSH_ENABLED:-})"
  echo "- stale_pr_head: ${stale_pr_head}"
  echo "- Ready gate result: ${ready_allowed}"
} >> "${summary_file}"
