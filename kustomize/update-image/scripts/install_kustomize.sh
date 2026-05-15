#!/usr/bin/env bash
set -euo pipefail

DEFAULT_KUSTOMIZE_VERSION="v5.4.3"

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

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

install_kustomize() {
  local version os arch base_url checksums_url tarball_name tarball_url checksum_line expected_checksum
  local tempdir archive checksum_file install_dir

  version="${KUSTOMIZE_VERSION:-${DEFAULT_KUSTOMIZE_VERSION}}"
  os="$(detect_os)"
  arch="$(detect_arch)"
  base_url="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${version}"
  checksums_url="${base_url}/checksums.txt"
  tarball_name="kustomize_${version#v}_${os}_${arch}.tar.gz"
  tarball_url="${base_url}/${tarball_name}"

  tempdir="$(mktemp -d)"
  trap 'rm -rf "${tempdir}"' EXIT

  archive="${tempdir}/${tarball_name}"
  checksum_file="${tempdir}/checksums.txt"
  install_dir="${KUSTOMIZE_INSTALL_DIR:-${HOME}/.local/bin}"
  mkdir -p "${install_dir}"

  curl -fsSL "${checksums_url}" -o "${checksum_file}"
  curl -fsSL "${tarball_url}" -o "${archive}"

  checksum_line="$(grep -E "^[a-f0-9]{64}[[:space:]]+${tarball_name}$" "${checksum_file}" || true)"
  if [[ -z "${checksum_line}" ]]; then
    fail "checksum line not found for ${tarball_name}"
  fi

  expected_checksum="${checksum_line%% *}"
  if [[ "${expected_checksum}" =~ [^a-f0-9] ]]; then
    fail "checksum parse failed for ${tarball_name}"
  fi

  printf '%s  %s\n' "${expected_checksum}" "${archive}" | shasum -a 256 -c -

  tar -xzf "${archive}" -C "${install_dir}"
  chmod +x "${install_dir}/kustomize"

  append_to_path "${install_dir}"

  "${install_dir}/kustomize" version
}

install_kustomize
