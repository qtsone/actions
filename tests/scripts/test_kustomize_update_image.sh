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

  # These two lines are a published contract other workflows grep for, so the wording is
  # pinned here rather than only where it is consumed.
  printf 'version: dryrun\n' > "$worker/values.yaml"
  output="$(run_update TAG=sha-drrun0000000000 EXTRA_PATHS=values.yaml DRY_RUN=true)" || fail "dry-run failed: $output"
  assert_contains "$output" "Dry-run: updated image to ghcr.io/qtsone/forge:sha-drrun0000000000 without commit/push" \
    "dry-run reports the update in the established wording"
  git -C "$worker" checkout -- kustomization.yaml

  output="$(run_update TAG=sha-20260515abcdef0 EXTRA_PATHS=values.yaml DRY_RUN=true)" || fail "dry-run no-change failed: $output"
  assert_contains "$output" "extra-paths are not staged in dry-run" \
    "dry-run says plainly that extra-paths are not staged when the image is unchanged"

  output="$(run_update TAG=sha-nocommit00000000 EXTRA_PATHS=values.yaml COMMIT=false)" || fail "commit=false failed: $output"
  assert_contains "$output" "Commit disabled: updated image to ghcr.io/qtsone/forge:sha-nocommit00000000 without commit/push" \
    "commit=false reports the update in the established wording"
  git -C "$worker" checkout -- kustomization.yaml
  git -C "$worker" checkout -- values.yaml

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

# A release workflow checks out its tag, builds for minutes, then writes back to main.
# This builds that topology: a remote whose main holds the overlay at $2, a tag v1.5.0,
# and an unrelated merge on main after the tag, so the caller's HEAD is already behind.
seed_release_remote() {
  local tempdir="$1" deployed_tag="$2" seed
  seed="$tempdir/seed"
  git init -q --bare -b main "$tempdir/remote.git"
  git clone -q "$tempdir/remote.git" "$seed" 2>/dev/null
  git -C "$seed" checkout -q -b main
  cat > "$seed/deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
spec:
  selector:
    matchLabels:
      app: app
  template:
    metadata:
      labels:
        app: app
    spec:
      containers:
        - name: app
          image: ghcr.io/qtsone/app
        - name: scraper
          image: ghcr.io/qtsone/app-scraper
YAML
  cat > "$seed/kustomization.yaml" <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
images:
  - name: ghcr.io/qtsone/app
    newTag: ${deployed_tag}
  - name: ghcr.io/qtsone/app-scraper
    newTag: ${deployed_tag}
YAML
  printf 'version: %s\n' "$deployed_tag" > "$seed/release-version-patch.yaml"
  git -C "$seed" add deployment.yaml kustomization.yaml release-version-patch.yaml
  git -C "$seed" -c user.name=seed -c user.email=seed@example.invalid commit -qm "seed"
  git -C "$seed" tag v1.5.0
  printf 'merged while the images built\n' > "$seed/merged.txt"
  git -C "$seed" add merged.txt
  git -C "$seed" -c user.name=seed -c user.email=seed@example.invalid commit -qm "unrelated merge"
  git -C "$seed" push -q origin main v1.5.0

  git clone -q "$tempdir/remote.git" "$tempdir/caller"
  git -C "$tempdir/caller" checkout -q --detach v1.5.0
  git clone -q "$tempdir/remote.git" "$tempdir/rival"
  git -C "$tempdir/rival" config user.name rival
  git -C "$tempdir/rival" config user.email rival@example.invalid
}

# Lands a competing commit on main from inside the caller's own push, after it has read
# the remote, so the push is refused exactly as when a merge lands mid-release. With
# $2=always every push is raced; otherwise only the first.
arm_push_race() {
  local tempdir="$1" mode="${2:-once}"
  cat > "$tempdir/caller/.git/hooks/pre-push" <<HOOK
#!/usr/bin/env bash
set -euo pipefail
# git exports these to hooks; left set they would point the rival at the caller's repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
marker="$tempdir/race-fired"
[[ "$mode" == always || ! -e "\$marker" ]] || exit 0
touch "\$marker"
git -C "$tempdir/rival" pull -q --ff-only origin main
date +%s%N >> "$tempdir/rival/rival.txt"
git -C "$tempdir/rival" add rival.txt
git -C "$tempdir/rival" commit -qm "rival merge"
git -C "$tempdir/rival" push -q origin HEAD:main
HOOK
  chmod +x "$tempdir/caller/.git/hooks/pre-push"
}

run_release_update() {
  local caller="$1"
  shift
  ( cd "$caller" && env \
      OVERLAY_PATH=. \
      TARGET_BRANCH=main \
      COMMIT=true \
      PUSH_RETRY_DELAY=0 \
      "$@" \
      bash "$UPDATE_SCRIPT" 2>&1 )
}

remote_image_tag() {
  git -C "$1/remote.git" show main:kustomization.yaml \
    | awk -v name="$2" '$0 ~ "name: "name"$" { found = 1; next } found && /newTag:/ { print $2; exit }'
}

run_release_race_checks() {
  local tempdir output rc
  tempdir="$(mktemp -d)"
  TEMP_DIR_TO_CLEANUP="$tempdir"

  # stay-now release.yaml: one image, tag checkout, main moved before and during the push.
  seed_release_remote "$tempdir" 1.4.0
  arm_push_race "$tempdir"
  output="$(run_release_update "$tempdir/caller" IMAGE_NAME=ghcr.io/qtsone/app TAG=1.5.0)" \
    || fail "release update did not survive a raced push: $output"
  assert_contains "$output" "rejected on attempt 1" "the raced push is reported and retried"
  assert_contains "$output" "Updated image to ghcr.io/qtsone/app:1.5.0 and pushed to main" "retry reports success"
  [[ -e "$tempdir/race-fired" ]] || fail "the push race never fired"
  [[ "$(remote_image_tag "$tempdir" ghcr.io/qtsone/app)" == "1.5.0" ]] || fail "main does not deploy 1.5.0"
  git -C "$tempdir/remote.git" cat-file -e main:merged.txt || fail "the merge before the push was lost"
  git -C "$tempdir/remote.git" cat-file -e main:rival.txt || fail "the merge that raced the push was lost"
  [[ "$(git -C "$tempdir/remote.git" log -1 --format=%s main~1)" == "rival merge" ]] \
    || fail "the image bump is not on top of the rival merge"
  pass "Tag-mode update lands on main after main moved during the build and during the push"

  rm -rf "$tempdir"
  tempdir="$(mktemp -d)"
  TEMP_DIR_TO_CLEANUP="$tempdir"

  # forge tags.yaml: a companion file rewritten on the tag checkout, then a second image
  # bumped by a second call; the first call's push is raced.
  seed_release_remote "$tempdir" 1.4.0
  arm_push_race "$tempdir"
  printf 'version: 1.5.0\n' > "$tempdir/caller/release-version-patch.yaml"
  output="$(run_release_update "$tempdir/caller" IMAGE_NAME=ghcr.io/qtsone/app TAG=1.5.0 \
    EXTRA_PATHS=release-version-patch.yaml)" || fail "forge-shaped first update failed: $output"
  assert_contains "$output" "rejected on attempt 1" "the forge-shaped push was raced"
  output="$(run_release_update "$tempdir/caller" IMAGE_NAME=ghcr.io/qtsone/app-scraper TAG=1.5.0)" \
    || fail "forge-shaped second update failed: $output"
  [[ "$(remote_image_tag "$tempdir" ghcr.io/qtsone/app)" == "1.5.0" ]] || fail "main does not deploy app 1.5.0"
  [[ "$(remote_image_tag "$tempdir" ghcr.io/qtsone/app-scraper)" == "1.5.0" ]] || fail "main does not deploy scraper 1.5.0"
  [[ "$(git -C "$tempdir/remote.git" show main:release-version-patch.yaml)" == "version: 1.5.0" ]] \
    || fail "the companion file was not carried onto the refetched main"
  local bump_files
  bump_files="$(git -C "$tempdir/remote.git" show --name-only --format= main~1)"
  assert_contains "$bump_files" "release-version-patch.yaml" "companion file rides in the image bump commit"
  git -C "$tempdir/remote.git" cat-file -e main:rival.txt || fail "the merge that raced the push was lost"
  pass "extra-paths are re-applied with the image on the refetched main"

  # The older of two overlapping releases finishes last: it must leave main alone.
  local before_main
  before_main="$(git -C "$tempdir/remote.git" rev-parse main)"
  git -C "$tempdir/caller" checkout -q --detach v1.5.0
  printf 'version: 1.4.9\n' > "$tempdir/caller/release-version-patch.yaml"
  output="$(run_release_update "$tempdir/caller" IMAGE_NAME=ghcr.io/qtsone/app TAG=1.4.9 \
    EXTRA_PATHS=release-version-patch.yaml GITHUB_OUTPUT="$tempdir/outputs")" \
    || fail "an older tag must be skipped, not fail: $output"
  assert_contains "$output" "Skipped: main already deploys ghcr.io/qtsone/app at 1.5.0, newer than 1.4.9" \
    "an older tag reports why it left main alone"
  [[ "$(git -C "$tempdir/remote.git" rev-parse main)" == "$before_main" ]] || fail "an older tag moved main"
  grep -qx 'changed=false' "$tempdir/outputs" || fail "a skipped older tag must report changed=false"
  output="$(run_release_update "$tempdir/caller" IMAGE_NAME=ghcr.io/qtsone/app TAG=v1.10.0)" \
    || fail "a newer tag failed: $output"
  [[ "$(remote_image_tag "$tempdir" ghcr.io/qtsone/app)" == "v1.10.0" ]] \
    || fail "1.10.0 must compare as newer than 1.5.0, numerically"
  pass "A tag-mode update never moves main to a lower semver tag"

  rm -rf "$tempdir"
  tempdir="$(mktemp -d)"
  TEMP_DIR_TO_CLEANUP="$tempdir"

  seed_release_remote "$tempdir" 1.4.0
  arm_push_race "$tempdir" always
  set +e
  output="$(run_release_update "$tempdir/caller" IMAGE_NAME=ghcr.io/qtsone/app TAG=1.5.0 PUSH_ATTEMPTS=2)"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail "a push refused on every attempt must fail the step"
  assert_contains "$output" "push conflict while updating main: still rejected after 2 attempts" \
    "exhausted retries name the bound"
  [[ "$(remote_image_tag "$tempdir" ghcr.io/qtsone/app)" == "1.4.0" ]] || fail "a failed run must not change main"
  pass "Retries are bounded and fail loudly when exhausted"

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
  run_release_race_checks
}

main "$@"
