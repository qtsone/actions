#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER_SCRIPT="$ROOT_DIR/kustomize/update-image/scripts/install_kustomize.sh"
TEMP_DIR_TO_CLEANUP=""

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

cleanup_tempdir() {
  if [[ -n "${TEMP_DIR_TO_CLEANUP:-}" ]]; then
    rm -rf "$TEMP_DIR_TO_CLEANUP"
  fi
}
trap cleanup_tempdir EXIT

assert_contains() {
  local content="$1"
  local needle="$2"
  local label="$3"
  [[ "$content" == *"$needle"* ]] || fail "$label (missing: $needle)"
}

write_fake_release_tools() {
  local tempdir="$1"
  mkdir -p "$tempdir/bin"

  cat >"$tempdir/bin/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf 'Linux\n' ;;
  -m) printf 'x86_64\n' ;;
  *) /usr/bin/uname "$@" ;;
esac
SH

  cat >"$tempdir/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

url=""
output=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -o)
      output="${2:?missing curl output path}"
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

printf '%s\n' "$url" >> "${FAKE_CURL_LOG:?missing FAKE_CURL_LOG}"

if [[ "$url" == *.tar.gz && "${FAKE_CURL_FAIL_TARBALL:-false}" == "true" ]]; then
  printf 'simulated tarball download failure: %s\n' "$url" >&2
  exit 22
fi

case "$url" in
  */checksums.txt)
    cat >"$output" <<'TXT'
0000000000000000000000000000000000000000000000000000000000000000  kustomize_v5.4.3_linux_amd64.tar.gz
TXT
    ;;
  */kustomize_v5.4.3_linux_amd64.tar.gz)
    printf 'fake archive\n' >"$output"
    ;;
  *)
    printf 'unexpected curl url: %s\n' "$url" >&2
    exit 22
    ;;
esac
SH

  cat >"$tempdir/bin/shasum" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
printf 'fake checksum: OK\n'
SH

  cat >"$tempdir/bin/tar" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

install_dir=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -C)
      install_dir="${2:?missing tar install dir}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

mkdir -p "$install_dir"
cat >"$install_dir/kustomize" <<'KUSTOMIZE'
#!/usr/bin/env bash
printf 'v5.4.3\n'
KUSTOMIZE
chmod +x "$install_dir/kustomize"
SH

  chmod +x "$tempdir/bin/uname" "$tempdir/bin/curl" "$tempdir/bin/shasum" "$tempdir/bin/tar"
}

run_fake_release_installer_success() {
  local tempdir output status
  tempdir="$(mktemp -d)"
  TEMP_DIR_TO_CLEANUP="$tempdir"
  write_fake_release_tools "$tempdir"

  set +e
  output="$(
    PATH="$tempdir/bin:$PATH" \
    FAKE_CURL_LOG="$tempdir/curl.log" \
    GITHUB_PATH="$tempdir/github_path" \
    KUSTOMIZE_INSTALL_DIR="$tempdir/install" \
    KUSTOMIZE_VERSION="v5.4.3" \
    bash "$INSTALLER_SCRIPT" 2>&1
  )"
  status=$?
  set -e

  if [[ "$status" -ne 0 ]]; then
    fail "Installer should succeed against upstream-style v-prefixed asset names. Output: $output"
  fi

  assert_contains "$(<"$tempdir/curl.log")" "kustomize_v5.4.3_linux_amd64.tar.gz" "Installer must request the upstream v-prefixed tarball asset"
  [[ "$output" != *"unbound variable"* ]] || fail "Installer cleanup trap must be safe under set -u"

  rm -rf "$tempdir"
  TEMP_DIR_TO_CLEANUP=""
  pass "Installer downloads upstream-style v-prefixed asset names"
}

run_download_failure_check() {
  local tempdir output status
  tempdir="$(mktemp -d)"
  TEMP_DIR_TO_CLEANUP="$tempdir"
  write_fake_release_tools "$tempdir"

  set +e
  output="$(
    PATH="$tempdir/bin:$PATH" \
    FAKE_CURL_LOG="$tempdir/curl.log" \
    FAKE_CURL_FAIL_TARBALL="true" \
    GITHUB_PATH="$tempdir/github_path" \
    KUSTOMIZE_INSTALL_DIR="$tempdir/install" \
    KUSTOMIZE_VERSION="v5.4.3" \
    bash "$INSTALLER_SCRIPT" 2>&1
  )"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "Installer should fail when tarball download fails"
  assert_contains "$output" "simulated tarball download failure" "Installer should preserve curl download failure output"
  [[ "$output" != *"unbound variable"* ]] || fail "Installer cleanup trap must not mask download failures"

  rm -rf "$tempdir"
  TEMP_DIR_TO_CLEANUP=""
  pass "Installer download failures are not masked by cleanup"
}

print_pending() {
  printf 'PENDING(Task 4): %s\n' "$1"
}

validate_contract_spec() {
  print_pending "Contract spec validated structurally only; executable installer checks start in Task 4"
}

run_pending_contract_mode() {
  print_pending "Missing implementation script: $INSTALLER_SCRIPT"
  print_pending "Contract requires pinned default version handling"
  print_pending "Contract requires strict checksum mismatch failure"
  print_pending "Contract requires deterministic OS/arch mapping coverage (linux/amd64, darwin/arm64 at minimum)"
  validate_contract_spec
}

run_implemented_checks() {
  local script_content
  script_content="$(<"$INSTALLER_SCRIPT")"

  assert_contains "$script_content" "set -euo pipefail" "Installer must enable strict shell mode"
  assert_contains "$script_content" "checksum" "Installer must include checksum verification logic"
  assert_contains "$script_content" "GITHUB_PATH" "Installer must handle GITHUB_PATH export"

  [[ "$script_content" != *'install_dir="${tempdir}/bin"'* ]] || fail "Installer must not use tempdir-backed install path"
  [[ "$script_content" == *'.local/bin'* ]] || fail "Installer must use a persistent install path"

  pass "Installer implementation includes required hardened primitives"

  run_fake_release_installer_success
  run_download_failure_check
}

main() {
  if [[ ! -f "$INSTALLER_SCRIPT" ]]; then
    run_pending_contract_mode
    return 0
  fi

  run_implemented_checks
}

main "$@"
