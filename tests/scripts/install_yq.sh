#!/usr/bin/env bash
#
# Put a working mikefarah yq on PATH for the contract tests.
#
# Every assertion in those tests is `yq ... | grep -q`. A yq that cannot read the file it
# is pointed at exits printing nothing, which makes an assertion for a forbidden string
# pass vacuously — it reports a contract as upheld while inspecting nothing. So the probe
# below tests that yq can actually parse a file, not that some binary answers --version.

set -euo pipefail

# renovate: datasource=github-releases depName=mikefarah/yq extractVersion=^v(?<version>.+)$
DEFAULT_YQ_VERSION="v4.53.3"
TEMP_DIR_TO_CLEANUP=""

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

cleanup_tempdir() {
  if [[ -n "${TEMP_DIR_TO_CLEANUP:-}" ]]; then
    rm -rf "${TEMP_DIR_TO_CLEANUP}"
  fi
}
trap cleanup_tempdir EXIT

detect_os() {
  local os
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "${os}" in
    linux|darwin) printf '%s\n' "${os}" ;;
    *) fail "unsupported operating system: ${os}" ;;
  esac
}

detect_arch() {
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) printf 'amd64\n' ;;
    arm64|aarch64) printf 'arm64\n' ;;
    *) fail "unsupported architecture: ${arch}" ;;
  esac
}

append_to_path() {
  local install_dir="$1"
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    printf '%s\n' "${install_dir}" >> "${GITHUB_PATH}"
  else
    export PATH="${install_dir}:${PATH}"
    printf 'GITHUB_PATH not set; PATH updated for current shell session only\n' >&2
  fi
}

# Reads a real file from a real path, which is the capability the tests depend on and the
# one a sandbox-confined build silently lacks.
yq_can_read_files() {
  local candidate="$1" probe result
  command -v "${candidate}" >/dev/null 2>&1 || return 1

  probe="$(mktemp -d)"
  printf 'a:\n  b: expected\n' > "${probe}/probe.yaml"
  result="$("${candidate}" -r '.a.b // ""' "${probe}/probe.yaml" 2>/dev/null || true)"
  rm -rf "${probe}"

  [[ "${result}" == "expected" ]]
}

install_yq() {
  local version os arch base_url asset asset_url order_url checksums_url
  local tempdir order_file checksums_file sha_index expected_checksum install_dir

  version="${YQ_VERSION:-${DEFAULT_YQ_VERSION}}"
  os="$(detect_os)"
  arch="$(detect_arch)"
  base_url="https://github.com/mikefarah/yq/releases/download/${version}"
  asset="yq_${os}_${arch}"
  asset_url="${base_url}/${asset}"
  order_url="${base_url}/checksums_hashes_order"
  checksums_url="${base_url}/checksums"

  tempdir="$(mktemp -d)"
  TEMP_DIR_TO_CLEANUP="${tempdir}"

  order_file="${tempdir}/checksums_hashes_order"
  checksums_file="${tempdir}/checksums"
  install_dir="${YQ_INSTALL_DIR:-${HOME}/.local/bin}"
  mkdir -p "${install_dir}"

  curl -fsSL "${order_url}" -o "${order_file}"
  curl -fsSL "${checksums_url}" -o "${checksums_file}"
  curl -fsSL "${asset_url}" -o "${tempdir}/${asset}"

  # yq publishes one row per asset with a column per hash algorithm, and names the column
  # order in a separate file. Column 1 is the filename, so SHA-256 sits one to the right
  # of its index in that list.
  sha_index="$(grep -n '^SHA-256$' "${order_file}" | cut -d: -f1)"
  [[ -n "${sha_index}" ]] || fail "SHA-256 not listed in ${order_url}"

  expected_checksum="$(
    grep -E "^${asset} " "${checksums_file}" \
      | awk -v col="$((sha_index + 1))" '{print $col}'
  )"
  if [[ ! "${expected_checksum}" =~ ^[a-f0-9]{64}$ ]]; then
    fail "checksum parse failed for ${asset}"
  fi

  printf '%s  %s\n' "${expected_checksum}" "${tempdir}/${asset}" | shasum -a 256 -c -

  mv "${tempdir}/${asset}" "${install_dir}/yq"
  chmod +x "${install_dir}/yq"

  append_to_path "${install_dir}"

  yq_can_read_files "${install_dir}/yq" || fail "installed yq cannot read a file it is pointed at"
  "${install_dir}/yq" --version
}

if yq_can_read_files yq; then
  printf 'Preinstalled yq can read files; keeping %s (%s)\n' "$(command -v yq)" "$(yq --version)"
else
  install_yq
fi
