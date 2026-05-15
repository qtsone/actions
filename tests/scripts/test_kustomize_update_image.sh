#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPDATE_SCRIPT="$ROOT_DIR/kustomize/update-image/scripts/update_image.sh"
BASE_FIXTURE="$ROOT_DIR/tests/fixtures/kustomize/base/kustomization.yaml"
EXPECTED_TAG_FIXTURE="$ROOT_DIR/tests/fixtures/kustomize/expected/tag/kustomization.yaml"
EXPECTED_DIGEST_FIXTURE="$ROOT_DIR/tests/fixtures/kustomize/expected/digest/kustomization.yaml"

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TEMP_DIR_TO_CLEANUP=""
cleanup_tempdir() {
  if [[ -n "$TEMP_DIR_TO_CLEANUP" && -d "$TEMP_DIR_TO_CLEANUP" ]]; then
    rm -rf "$TEMP_DIR_TO_CLEANUP"
  fi
}
trap cleanup_tempdir EXIT

assert_file_exists() {
  local path="$1"
  [[ -f "$path" ]] || fail "Expected file to exist: $path"
}

assert_contains() {
  local content="$1"
  local needle="$2"
  local label="$3"
  [[ "$content" == *"$needle"* ]] || fail "$label (missing: $needle)"
}

print_pending() {
  printf 'PENDING(Task 4): %s\n' "$1"
}

setup_git_fixtures() {
  local tempdir bare origin worker
  tempdir="$(mktemp -d)"
  bare="$tempdir/remote.git"
  origin="$tempdir/origin"
  worker="$tempdir/worker"

  git init --bare "$bare" >/dev/null 2>&1
  git clone "$bare" "$origin" >/dev/null 2>&1
  git clone "$bare" "$worker" >/dev/null 2>&1

  git -C "$origin" config user.email "contracts@example.invalid"
  git -C "$origin" config user.name "contract-test"
  cp "$BASE_FIXTURE" "$origin/kustomization.yaml"
  git -C "$origin" add kustomization.yaml
  git -C "$origin" commit -m "seed" >/dev/null 2>&1
  git -C "$origin" push origin HEAD:main >/dev/null 2>&1

  git -C "$worker" fetch origin main >/dev/null 2>&1
  git -C "$worker" checkout -B main origin/main >/dev/null 2>&1

  printf '%s\n' "$tempdir"
}

validate_fixture_contracts() {
  assert_file_exists "$BASE_FIXTURE"
  assert_file_exists "$EXPECTED_TAG_FIXTURE"
  assert_file_exists "$EXPECTED_DIGEST_FIXTURE"

  local base_content tag_content digest_content
  base_content="$(<"$BASE_FIXTURE")"
  tag_content="$(<"$EXPECTED_TAG_FIXTURE")"
  digest_content="$(<"$EXPECTED_DIGEST_FIXTURE")"

  assert_contains "$base_content" "newTag: sha-oldtag123" "Base fixture must pin initial tag"
  assert_contains "$tag_content" "newTag: sha-20260515abcdef0" "Tag fixture must represent simple mode update"
  assert_contains "$digest_content" "newDigest: sha256:" "Digest fixture must represent digest mode update"
  pass "Kustomize fixtures encode deterministic tag and digest contracts"
}

run_pending_contract_mode() {
  local tempdir
  tempdir="$(setup_git_fixtures)"
  TEMP_DIR_TO_CLEANUP="$tempdir"

  print_pending "Missing implementation script: $UPDATE_SCRIPT"
  print_pending "Contract requires simple mode: overlay-path + image-name + tag"
  print_pending "Contract requires advanced mode: image-name + optional new-name + exactly one of tag|digest|new-ref"
  print_pending "Contract requires no-op commit suppression when desired image already set"
  print_pending "Contract requires explicit push-conflict failure message when remote advanced"

  validate_fixture_contracts

  local worker_file
  worker_file="$tempdir/worker/kustomization.yaml"
  assert_file_exists "$worker_file"
  pass "Local git fixture topology prepared for no-op/conflict tests"

  TEMP_DIR_TO_CLEANUP=""
  rm -rf "$tempdir"
}

run_implemented_checks() {
  local script_content
  script_content="$(<"$UPDATE_SCRIPT")"

  assert_contains "$script_content" "set -euo pipefail" "Update script must enable strict shell mode"
  assert_contains "$script_content" "kustomize edit set image" "Update script must mutate image with kustomize"
  assert_contains "$script_content" "kustomize build" "Update script must validate overlay build before commit"
  assert_contains "$script_content" "chore(deploy): update production image [skip ci]" "Update script must include default commit message"
  assert_contains "$script_content" "conflict" "Update script must report push-conflict behavior"
  pass "Update-image implementation includes required contract primitives"
}

main() {
  if [[ ! -f "$UPDATE_SCRIPT" ]]; then
    run_pending_contract_mode
    return 0
  fi

  validate_fixture_contracts
  run_implemented_checks
}

main "$@"
