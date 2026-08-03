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

  local output rc
  set +e
  output="$(env -i PATH="$PATH" bash "$UPDATE_SCRIPT" 2>&1)"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail "Update script should fail when required inputs are missing"
  [[ "$output" != *"unbound variable"* ]] || fail "Update script trap must be safe under set -u"
  [[ "$output" == *"overlay-path is required"* ]] || fail "Expected overlay-path validation failure when inputs are missing"

  pass "Update-image implementation includes required contract primitives"
}

run_extra_paths_checks() {
  local tempdir worker rc output
  tempdir="$(setup_git_fixtures)"
  TEMP_DIR_TO_CLEANUP="$tempdir"
  worker="$tempdir/worker"

  git -C "$worker" config user.email "contracts@example.invalid"
  git -C "$worker" config user.name "contract-test"

  # The base fixture lists deployment.yaml as a resource, and update_image.sh runs
  # `kustomize build` as a pre-commit validation, so the overlay has to actually resolve.
  cat > "$worker/deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: forge
spec:
  selector:
    matchLabels:
      app: forge
  template:
    metadata:
      labels:
        app: forge
    spec:
      containers:
        - name: forge
          image: ghcr.io/qtsone/forge
YAML
  printf 'version: old\n' > "$worker/values.yaml"
  git -C "$worker" add deployment.yaml values.yaml
  git -C "$worker" commit -qm "seed deployment and values"
  git -C "$worker" push -q origin HEAD:main

  run_update() {
    ( cd "$worker" && env \
        OVERLAY_PATH=. \
        IMAGE_NAME=ghcr.io/qtsone/forge \
        TARGET_BRANCH=main \
        COMMIT=true \
        COMMIT_USER_NAME=contract-test \
        COMMIT_USER_EMAIL=contracts@example.invalid \
        "$@" \
        bash "$UPDATE_SCRIPT" 2>&1 )
  }

  # The image bump and whatever tracks it must land together: two commits would mean two
  # Argo syncs and a window where the overlay and the companion file disagree.
  printf 'version: new\n' > "$worker/values.yaml"
  output="$(run_update TAG=sha-20260515abcdef0 EXTRA_PATHS=values.yaml)" || fail "extra-paths run failed: $output"
  local committed
  committed="$(git -C "$worker" show --name-only --format= HEAD)"
  assert_contains "$committed" "kustomization.yaml" "extra-paths run commits the kustomization"
  assert_contains "$committed" "values.yaml" "extra-paths land in the same commit as the image bump"

  # The regression that matters: with the kustomization already at the target, an early
  # no-op return would drop the companion change on the floor and report changed=false.
  printf 'version: newer\n' > "$worker/values.yaml"
  output="$(run_update TAG=sha-20260515abcdef0 EXTRA_PATHS=values.yaml)" || fail "second extra-paths run failed: $output"
  committed="$(git -C "$worker" show --name-only --format= HEAD)"
  assert_contains "$committed" "values.yaml" "extra-paths are staged even when the kustomization is already at the target"
  [[ "$(git -C "$worker" show HEAD:values.yaml)" == "version: newer" ]] \
    || fail "companion file content was not committed"
  pass "Companion change reaches the remote when only it changed"

  # Nothing to do at all must still be a no-op rather than an empty commit.
  local before_head
  before_head="$(git -C "$worker" rev-parse HEAD)"
  output="$(run_update TAG=sha-20260515abcdef0 EXTRA_PATHS=values.yaml)" || fail "no-op run failed: $output"
  [[ "$(git -C "$worker" rev-parse HEAD)" == "$before_head" ]] \
    || fail "Unchanged inputs must not create a commit"
  pass "No commit is created when neither the image nor the extra paths changed"

  # This action pushes to the target branch unreviewed, so a directory — `.` being the
  # most plausible misreading of "files to stage" — must be refused rather than sweeping
  # in whatever an earlier workflow step left in the workspace.
  set +e
  output="$(run_update TAG=sha-newtag00000000 EXTRA_PATHS=.)"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail "A directory in extra-paths must be rejected"
  assert_contains "$output" "not a regular file" "Directory in extra-paths reports why it was rejected"

  set +e
  output="$(run_update TAG=sha-newtag00000000 EXTRA_PATHS="$tempdir/outside.txt")"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail "A missing extra-paths entry must be rejected"

  printf 'outside\n' > "$tempdir/outside.txt"
  set +e
  output="$(run_update TAG=sha-newtag00000000 EXTRA_PATHS="$tempdir/outside.txt")"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail "An extra-paths entry outside the repository must be rejected"
  assert_contains "$output" "outside the repository" "Out-of-repo extra-paths reports why it was rejected"

  pass "extra-paths staging and boundary contracts hold"

  TEMP_DIR_TO_CLEANUP=""
  rm -rf "$tempdir"
}

main() {
  if [[ ! -f "$UPDATE_SCRIPT" ]]; then
    run_pending_contract_mode
    return 0
  fi

  validate_fixture_contracts
  run_implemented_checks
  run_extra_paths_checks
}

main "$@"
