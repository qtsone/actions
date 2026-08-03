#!/usr/bin/env bash
#
# Behavioural tests for git/content-id. The id decides whether a later release republishes
# an existing image instead of building one, so the cases that matter are the ones where a
# real change must move it and a cosmetic one must not.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTENT_ID_SCRIPT="$ROOT_DIR/git/content-id/scripts/content_id.sh"

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

# Emits `id=<digest>` on stdout when GITHUB_OUTPUT is unset, which is also the local-run
# contract the script advertises.
content_id() {
  ( cd "$REPO" && env -u GITHUB_OUTPUT "$@" bash "$CONTENT_ID_SCRIPT" 2>/dev/null | sed -n 's/^id=//p' )
}

content_id_rc() {
  local out rc
  set +e
  out="$( cd "$REPO" && env -u GITHUB_OUTPUT "$@" bash "$CONTENT_ID_SCRIPT" 2>&1 )"
  rc=$?
  set -e
  printf '%s\n' "$out"
  return $rc
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label (expected '$expected', got '$actual')"
  fi
}

assert_ne() {
  local a="$1" b="$2" label="$3"
  if [[ "$a" != "$b" ]]; then
    pass "$label"
  else
    fail "$label (both were '$a')"
  fi
}

assert_fails_with() {
  local needle="$1" label="$2"
  shift 2
  local out rc
  set +e
  out="$(content_id_rc "$@")"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    fail "$label (expected non-zero exit, got 0)"
  elif [[ "$out" != *"$needle"* ]]; then
    fail "$label (missing '$needle' in: $out)"
  else
    pass "$label"
  fi
}

setup_repo() {
  local tempdir
  tempdir="$(mktemp -d)"
  TEMP_DIR_TO_CLEANUP="$tempdir"
  REPO="$tempdir/repo"

  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email "contracts@example.invalid"
  git -C "$REPO" config user.name "contract-test"

  mkdir -p "$REPO/src" "$REPO/docs" "$REPO/docker" "$REPO/weird(dir)" "$REPO/a+b"
  printf 'console.log(1)\n' > "$REPO/src/app.js"
  printf 'FROM alpine\n' > "$REPO/Dockerfile"
  printf 'docs\n' > "$REPO/docs/readme.md"
  printf 'compose\n' > "$REPO/docker/compose.yaml"
  printf 'w\n' > "$REPO/weird(dir)/f.txt"
  printf 'p\n' > "$REPO/a+b/f.txt"
  printf 'changelog\n' > "$REPO/CHANGELOG.md"

  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "seed"
}

commit_all() {
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "$1"
}

main() {
  [[ -f "$CONTENT_ID_SCRIPT" ]] || { printf 'FAIL: missing %s\n' "$CONTENT_ID_SCRIPT" >&2; exit 1; }
  setup_repo

  local baseline
  baseline="$(content_id)"
  [[ -n "$baseline" ]] || { printf 'FAIL: baseline id was empty\n' >&2; exit 1; }

  # The stated purpose: a release commit that only touches an excluded file must reuse the
  # artifact, so the id has to be identical at two different refs.
  local before after
  before="$(content_id EXCLUDE=CHANGELOG.md)"
  printf 'changelog\nbump\n' > "$REPO/CHANGELOG.md"
  commit_all "changelog only"
  after="$(content_id EXCLUDE=CHANGELOG.md)"
  assert_eq "$after" "$before" "id is stable across commits that only touch excluded paths"
  assert_eq "$(content_id EXCLUDE=CHANGELOG.md REF=HEAD~1)" "$before" "id is stable when read from an older ref"

  # ...and the opposite direction, which is what stops a real change being skipped.
  printf 'console.log(2)\n' > "$REPO/src/app.js"
  commit_all "source change"
  assert_ne "$(content_id EXCLUDE=CHANGELOG.md)" "$before" "id moves when hashed content changes"

  # A mode-only change leaves every blob id untouched, so an id built from blob ids alone
  # would republish an image whose entrypoint is not executable.
  before="$(content_id)"
  chmod +x "$REPO/src/app.js"
  commit_all "chmod +x"
  assert_ne "$(content_id)" "$before" "id moves when only a file mode changes"

  # Prefix matching would let a short exclude swallow a sibling directory.
  local excl_docs
  excl_docs="$(content_id EXCLUDE=doc)"
  assert_eq "$excl_docs" "$(content_id)" "exclude 'doc' matches nothing and leaves the id unchanged"
  assert_ne "$(content_id EXCLUDE=docs)" "$(content_id EXCLUDE=$'docs\ndocker')" \
    "exclude 'docs' does not also drop 'docker/'"
  assert_eq "$(content_id EXCLUDE=docs/)" "$(content_id EXCLUDE=docs)" "a trailing slash on an exclude entry is ignored"

  # Excludes are compared literally, so a path that looks like a regex is still excluded.
  assert_ne "$(content_id EXCLUDE='weird(dir)')" "$(content_id)" "exclude handles a path containing regex metacharacters"
  assert_ne "$(content_id EXCLUDE='a+b')" "$(content_id)" "exclude handles a path containing a plus"

  # A typo in an include list would otherwise pin the id to a subset forever.
  assert_fails_with "matched no tracked entry" "include entry matching nothing is an error" \
    INCLUDE=$'src\nsrcc-typo'
  assert_fails_with "matched no tracked entry" "include entry matching nothing is an error even when alone" \
    INCLUDE=no-such-path
  assert_eq "$(content_id INCLUDE=$'src\nDockerfile')" "$(content_id INCLUDE=$'Dockerfile\nsrc')" \
    "include order does not change the id"

  assert_fails_with "refusing to emit the digest of an empty set" "an empty selection is refused" \
    EXCLUDE=$'src\nDockerfile\ndocs\ndocker\nweird(dir)\na+b\nCHANGELOG.md'
  assert_fails_with "give include or exclude, not both" "include and exclude together is an error" \
    INCLUDE=src EXCLUDE=docs
  assert_fails_with "include is set but lists no paths" "a whitespace-only include is not treated as 'hash everything'" \
    INCLUDE='   '
  assert_eq "$(content_id EXCLUDE='   ')" "$(content_id)" "a whitespace-only exclude is harmless and does not fail"

  # extra is how a caller folds in what git cannot see: build-args, a resolved base digest.
  assert_ne "$(content_id EXTRA=BASE=node:20@sha256:aaa)" "$(content_id)" "extra changes the id"
  assert_eq "$(content_id EXTRA=$'a=1\nb=2')" "$(content_id EXTRA=$'b=2\na=1')" "extra order does not change the id"

  # target/config resolution: the common misconfiguration is a config file that is not
  # there, which must not silently widen the id to the whole tree.
  assert_fails_with "does not exist" "target with a missing config file is an error" \
    TARGET=api CONFIG=.github/nope.json
  printf '{"api": {"exclude": ["docs"]}, "empty": {"include": []}}\n' > "$REPO/content.json"
  commit_all "add config"
  assert_eq "$(content_id TARGET=api CONFIG=content.json)" "$(content_id EXCLUDE=docs)" \
    "target resolves exclude from config"
  assert_fails_with "not found in" "unknown target key is an error" TARGET=nope CONFIG=content.json
  assert_fails_with "empty include list" "an empty include list in config is an error" \
    TARGET=empty CONFIG=content.json
  # The config wins, so accepting both would silently ignore whichever the caller believed
  # was in effect.
  assert_fails_with "do not also pass them directly" "target plus a direct exclude is an error" \
    TARGET=api CONFIG=content.json EXCLUDE=src
  assert_fails_with "do not also pass them directly" "target plus a direct extra is an error" \
    TARGET=api CONFIG=content.json EXTRA=BASE=alpine

  if [[ $FAILURES -gt 0 ]]; then
    printf '\n%d content-id assertion(s) failed\n' "$FAILURES" >&2
    exit 1
  fi
  printf '\nAll content-id behaviour contracts hold\n'
}

main "$@"
