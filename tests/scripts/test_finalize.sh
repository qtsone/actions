#!/usr/bin/env bash
#
# Behavioural tests for docker/tests' readiness gate.
#
# ready_allowed=true is what puts an image in front of a cluster, and since the build now
# pushes before the scan runs it is the only thing that does. Every combination that can
# reach it is asserted here rather than inferred from the shape of the YAML.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FINALIZE_SCRIPT="$ROOT_DIR/docker/tests/scripts/finalize.sh"

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

# A run with the happy-path defaults, overridden by whatever the caller passes.
run_finalize() {
  : > "$OUTPUT_FILE"
  : > "$SUMMARY_FILE"
  env \
    GITHUB_OUTPUT="$OUTPUT_FILE" \
    GITHUB_STEP_SUMMARY="$SUMMARY_FILE" \
    ELIGIBLE=true \
    PREVIEW_PUSH_ENABLED=true \
    READY_LABEL_ENABLED=true \
    SCAN_REQUIRED=false \
    BUILD_OUTCOME=success \
    PUSH_OUTCOME=success \
    TRIVY_OUTCOME=success \
    HADOLINT_OUTCOME=success \
    STALE_PR_HEAD=false \
    IMAGE=ghcr.io/owner/repo \
    TAG=abc123 \
    IMAGE_TAG=ghcr.io/owner/repo:abc123 \
    PUSH_DIGEST=sha256:deadbeef \
    "$@" \
    bash "$FINALIZE_SCRIPT" >/dev/null
}

output_value() {
  sed -n "s/^$1=//p" "$OUTPUT_FILE" | head -1
}

assert_output() {
  local key="$1" expected="$2" label="$3"
  local actual
  actual="$(output_value "$key")"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label ($key expected '$expected', got '$actual')"
  fi
}

main() {
  [[ -f "$FINALIZE_SCRIPT" ]] || { printf 'FAIL: missing %s\n' "$FINALIZE_SCRIPT" >&2; exit 1; }

  local tempdir
  tempdir="$(mktemp -d)"
  TEMP_DIR_TO_CLEANUP="$tempdir"
  OUTPUT_FILE="$tempdir/github_output"
  SUMMARY_FILE="$tempdir/github_step_summary"

  run_finalize
  assert_output ready_allowed true "the happy path is ready"
  assert_output digest "sha256:deadbeef" "the happy path publishes a digest"
  assert_output image-digest "ghcr.io/owner/repo@sha256:deadbeef" "the happy path publishes an image-digest"

  # scan-required is the whole point of the input: with it set, a failing scan must
  # withhold the label, and without it the same failure must not.
  run_finalize SCAN_REQUIRED=true TRIVY_OUTCOME=failure
  assert_output ready_allowed false "scan-required=true withholds ready when the scan fails"
  assert_output digest "" "scan-required=true withholds the digest when the scan fails"
  assert_output image-digest "" "scan-required=true withholds image-digest when the scan fails"

  run_finalize SCAN_REQUIRED=false TRIVY_OUTCOME=failure
  assert_output ready_allowed true "scan-required=false permits ready despite a failing scan"
  assert_output digest "sha256:deadbeef" "scan-required=false still publishes the digest"

  run_finalize SCAN_REQUIRED=true TRIVY_OUTCOME=success
  assert_output ready_allowed true "scan-required=true permits ready when the scan passes"

  # A stale head means the PR moved on while this ran; whatever was built is superseded.
  run_finalize STALE_PR_HEAD=true
  assert_output ready_allowed false "a stale PR head withholds ready"
  assert_output digest "" "a stale PR head withholds the digest"

  run_finalize STALE_PR_HEAD=""
  assert_output ready_allowed true "an unset stale flag is treated as not stale"

  run_finalize BUILD_OUTCOME=failure PUSH_OUTCOME=failure
  assert_output ready_allowed false "a failed build withholds ready"

  run_finalize PUSH_OUTCOME=failure
  assert_output ready_allowed false "a failed push withholds ready"
  assert_output digest "" "a failed push withholds the digest"

  run_finalize ELIGIBLE=false PUSH_OUTCOME=skipped
  assert_output ready_allowed false "an ineligible context is never ready"

  run_finalize READY_LABEL_ENABLED=false
  assert_output ready_allowed false "ready-label-enabled=false withholds the label"

  # The regression this gate is most exposed to: with the push disabled the local build is
  # the one that ran, and its success has to reach build_pass or nothing is ever ready.
  run_finalize PREVIEW_PUSH_ENABLED=false PUSH_OUTCOME=skipped
  assert_output ready_allowed true "preview-push-enabled=false is ready on a successful local build"
  assert_output digest "" "preview-push-enabled=false publishes no digest"

  run_finalize PREVIEW_PUSH_ENABLED=false PUSH_OUTCOME=skipped BUILD_OUTCOME=skipped
  assert_output ready_allowed false "a build reported as skipped is not treated as a pass"

  # A promote hit reports success with the digest promote read back from the new tag.
  run_finalize PROMOTED=true PUSH_DIGEST=sha256:promoted
  assert_output digest "sha256:promoted" "a promoted image publishes the promote digest"
  assert_output image-digest "ghcr.io/owner/repo@sha256:promoted" "a promoted image publishes an image-digest"
  grep -q 'promoted=true' "$SUMMARY_FILE" || fail "the summary records that the image was promoted"

  run_finalize PUSH_DIGEST=""
  assert_output digest "" "no digest is invented when the build reported none"
  assert_output image-digest "" "image-digest stays empty without a digest"

  # The tag outputs describe what was built and stay populated regardless of the gate, so
  # a not-ready run can still say which reference it was talking about.
  run_finalize STALE_PR_HEAD=true
  assert_output tag "abc123" "the tag output survives a withheld gate"
  assert_output image-tag "ghcr.io/owner/repo:abc123" "the image-tag output survives a withheld gate"
  assert_output image "ghcr.io/owner/repo" "the image output survives a withheld gate"

  if [[ $FAILURES -gt 0 ]]; then
    printf '\n%d readiness-gate assertion(s) failed\n' "$FAILURES" >&2
    exit 1
  fi
  printf '\nAll readiness-gate contracts hold\n'
}

main "$@"
