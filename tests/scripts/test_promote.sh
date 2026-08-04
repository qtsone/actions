#!/usr/bin/env bash
#
# Behavioural tests for docker/promote. The script's whole contract is the argv it hands
# to `docker buildx imagetools` and how it classifies a failure, so `docker` is a PATH shim
# that records its arguments instead of talking to a registry.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROMOTE_SCRIPT="$ROOT_DIR/docker/promote/scripts/promote.sh"

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

# INSPECT_MODE decides what the first `imagetools inspect` (the existence probe) does:
#   ok        -> exits 0
#   miss      -> exits 1 with a manifest-unknown message
#   autherror -> exits 1 with a 401
# `inspect --format` always succeeds and echoes a digest derived from the reference, so a
# test can tell which reference the digest was read from.
write_docker_shim() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/docker" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SHIM_LOG}"

if [ "$2" = "imagetools" ] && [ "$3" = "inspect" ]; then
  for arg in "$@"; do
    if [ "${arg}" = "--format" ]; then
      printf 'sha256:digest-of-%s\n' "$4"
      exit 0
    fi
  done
  case "${INSPECT_MODE}" in
    miss)      echo "ERROR: $4: not found" >&2; exit 1 ;;
    autherror) echo "ERROR: failed to authorize: unexpected status from GET request: 401 Unauthorized" >&2; exit 1 ;;
  esac
  echo "Name: $4"
  exit 0
fi

exit 0
SHIM
  chmod +x "$bin/docker"
}

# Runs promote.sh and exports: RC, OUT (stderr+stdout), LOG (recorded docker argv),
# OUTPUTS (contents of GITHUB_OUTPUT).
run_promote() {
  local mode="$1"
  shift
  : > "$SHIM_LOG"
  : > "$OUTPUT_FILE"
  set +e
  OUT="$(
    env PATH="$SHIM_BIN:$PATH" \
      SHIM_LOG="$SHIM_LOG" \
      INSPECT_MODE="$mode" \
      GITHUB_OUTPUT="$OUTPUT_FILE" \
      REGISTRY=ghcr.io \
      IMAGE_NAME=owner/repo \
      "$@" \
      bash "$PROMOTE_SCRIPT" 2>&1
  )"
  RC=$?
  set -e
  LOG="$(cat "$SHIM_LOG")"
  OUTPUTS="$(cat "$OUTPUT_FILE")"
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label (missing '$needle' in: $haystack)"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label (unexpectedly found '$needle')"
  fi
}

assert_rc() {
  local expected="$1" label="$2"
  if [[ "$RC" -eq "$expected" ]]; then
    pass "$label"
  else
    fail "$label (expected rc=$expected, got rc=$RC; output: $OUT)"
  fi
}

main() {
  [[ -f "$PROMOTE_SCRIPT" ]] || { printf 'FAIL: missing %s\n' "$PROMOTE_SCRIPT" >&2; exit 1; }
  [[ -x "$PROMOTE_SCRIPT" ]] || { printf 'FAIL: %s is not executable\n' "$PROMOTE_SCRIPT" >&2; exit 1; }

  local tempdir
  tempdir="$(mktemp -d)"
  TEMP_DIR_TO_CLEANUP="$tempdir"
  SHIM_BIN="$tempdir/bin"
  SHIM_LOG="$tempdir/docker.log"
  OUTPUT_FILE="$tempdir/github_output"
  write_docker_shim "$SHIM_BIN"

  # A bare tag is a convenience the action documents; a full reference must survive as-is.
  run_promote ok SOURCE_TAG=src-abc TAGS=$'v1.2.3\nghcr.io/other/repo:latest'
  assert_rc 0 "a hit exits 0"
  assert_contains "$LOG" "--tag ghcr.io/owner/repo:v1.2.3" "a bare tag is prefixed with the image"
  assert_contains "$LOG" "--tag ghcr.io/other/repo:latest" "a full reference is passed through unchanged"
  assert_contains "$LOG" "imagetools create" "a hit creates the new tags"
  assert_contains "$OUTPUTS" "promoted=true" "a hit reports promoted=true"

  # The digest must name what the new tags point at. Reading it back from the source would
  # be wrong whenever create rewrites the index, which is exactly what annotating does.
  assert_contains "$OUTPUTS" "digest=sha256:digest-of-ghcr.io/owner/repo:v1.2.3" \
    "the digest is read from the first created tag, not the source"
  assert_not_contains "$OUTPUTS" "digest-of-ghcr.io/owner/repo:src-abc" \
    "the digest is not the source tag's digest"

  run_promote ok SOURCE_TAG=src-abc TAGS=v1.2.3 ANNOTATIONS=$'index:org.opencontainers.image.version=1.2.3\nindex:foo=bar'
  assert_contains "$LOG" "--annotation index:org.opencontainers.image.version=1.2.3" "annotations reach the create args"
  assert_contains "$LOG" "--annotation index:foo=bar" "every annotation reaches the create args"

  # A miss is the caller's signal to build instead, so it must not be a red pipeline.
  run_promote miss SOURCE_TAG=src-abc TAGS=v1.2.3
  assert_rc 0 "a registry miss exits 0"
  assert_contains "$OUTPUTS" "promoted=false" "a miss reports promoted=false"
  assert_not_contains "$LOG" "imagetools create" "a miss never creates a tag it did not verify"

  # Anything that is not a miss must be loud: reporting a 401 as "never built" would hide
  # a broken registry behind a silent full rebuild on every run.
  run_promote autherror SOURCE_TAG=src-abc TAGS=v1.2.3
  assert_rc 1 "an auth failure is a hard error, not a miss"
  assert_contains "$OUT" "401" "the underlying registry error is surfaced"
  assert_not_contains "$OUTPUTS" "promoted=false" "an auth failure is not reported as a miss"

  run_promote ok SOURCE_TAG=src-abc TAGS=""
  assert_rc 1 "no tags to promote to is an error"
  assert_not_contains "$LOG" "imagetools create" "no create runs when there are no tags"

  # The script has to be runnable outside Actions or it cannot be tested at all.
  : > "$SHIM_LOG"
  set +e
  OUT="$(
    env -u GITHUB_OUTPUT PATH="$SHIM_BIN:$PATH" SHIM_LOG="$SHIM_LOG" INSPECT_MODE=ok \
      REGISTRY=ghcr.io IMAGE_NAME=owner/repo SOURCE_TAG=src-abc TAGS=v1.2.3 \
      bash "$PROMOTE_SCRIPT" 2>&1
  )"
  RC=$?
  set -e
  assert_rc 0 "runs with GITHUB_OUTPUT unset"
  assert_contains "$OUT" "promoted=true" "falls back to stdout when GITHUB_OUTPUT is unset"

  if [[ $FAILURES -gt 0 ]]; then
    printf '\n%d promote assertion(s) failed\n' "$FAILURES" >&2
    exit 1
  fi
  printf '\nAll promote behaviour contracts hold\n'
}

main "$@"
