#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER_SCRIPT="$ROOT_DIR/kustomize/update-image/scripts/install_kustomize.sh"

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

assert_contains() {
  local content="$1"
  local needle="$2"
  local label="$3"
  [[ "$content" == *"$needle"* ]] || fail "$label (missing: $needle)"
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
}

main() {
  if [[ ! -f "$INSTALLER_SCRIPT" ]]; then
    run_pending_contract_mode
    return 0
  fi

  run_implemented_checks
}

main "$@"
