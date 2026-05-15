#!/usr/bin/env bash
set -euo pipefail

DEFAULT_COMMIT_MESSAGE="chore(deploy): update production image [skip ci]"

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

trim() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "${value}"
}

bool_true() {
  [[ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" == "true" ]]
}

main() {
  require_cmd git
  require_cmd kustomize

  local overlay_path overlay_path_abs image_name new_name tag digest new_ref target_branch commit dry_run commit_message
  local commit_user_name commit_user_email
  local mode_count image_spec before_file after_file changed target_ref

  before_file=""
  after_file=""
  cleanup_tempfiles() {
    rm -f "${before_file:-}" "${after_file:-}"
  }
  trap cleanup_tempfiles EXIT

  overlay_path="$(trim "${OVERLAY_PATH:-}")"
  image_name="$(trim "${IMAGE_NAME:-}")"
  new_name="$(trim "${NEW_NAME:-}")"
  tag="$(trim "${TAG:-}")"
  digest="$(trim "${DIGEST:-}")"
  new_ref="$(trim "${NEW_REF:-}")"
  target_branch="$(trim "${TARGET_BRANCH:-main}")"
  commit="$(trim "${COMMIT:-true}")"
  dry_run="$(trim "${DRY_RUN:-false}")"
  commit_message="$(trim "${COMMIT_MESSAGE:-${DEFAULT_COMMIT_MESSAGE}}")"
  commit_user_name="$(trim "${COMMIT_USER_NAME:-github-actions[bot]}")"
  commit_user_email="$(trim "${COMMIT_USER_EMAIL:-github-actions[bot]@users.noreply.github.com}")"

  [[ -n "${overlay_path}" ]] || fail "overlay-path is required"
  [[ -n "${image_name}" ]] || fail "image-name is required"
  [[ -d "${overlay_path}" ]] || fail "overlay-path does not exist: ${overlay_path}"
  overlay_path_abs="$(cd "${overlay_path}" && pwd)"
  [[ -f "${overlay_path_abs}/kustomization.yaml" ]] || fail "kustomization.yaml not found in overlay-path: ${overlay_path_abs}"

  mode_count=0
  [[ -n "${tag}" ]] && mode_count=$((mode_count + 1))
  [[ -n "${digest}" ]] && mode_count=$((mode_count + 1))
  [[ -n "${new_ref}" ]] && mode_count=$((mode_count + 1))
  [[ ${mode_count} -eq 1 ]] || fail "exactly one of tag, digest, or new-ref must be provided"

  image_spec="${image_name}"
  if [[ -n "${new_ref}" ]]; then
    target_ref="${new_ref}"
    image_spec="${image_name}=${new_ref}"
  elif [[ -n "${digest}" ]]; then
    if [[ -n "${new_name}" ]]; then
      target_ref="${new_name}@${digest}"
    else
      target_ref="${image_name}@${digest}"
    fi
    image_spec="${image_name}=${target_ref}"
  else
    # tag-only mode
    if [[ -n "${new_name}" ]]; then
      target_ref="${new_name}:${tag}"
    else
      target_ref="${image_name}:${tag}"
    fi
    image_spec="${image_name}=${target_ref}"
  fi

  before_file="$(mktemp)"
  after_file="$(mktemp)"

  cp "${overlay_path_abs}/kustomization.yaml" "${before_file}"

  (
    cd "${overlay_path_abs}"
    kustomize edit set image "${image_spec}"
    kustomize build "${overlay_path_abs}" >/dev/null
  )

  cp "${overlay_path_abs}/kustomization.yaml" "${after_file}"
  if cmp -s "${before_file}" "${after_file}"; then
    printf 'No-op: kustomization already at target image %s\n' "${target_ref}"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      {
        echo "changed=false"
        echo "target-ref=${target_ref}"
      } >> "${GITHUB_OUTPUT}"
    fi
    exit 0
  fi

  if bool_true "${dry_run}"; then
    printf 'Dry-run: updated image to %s without commit/push\n' "${target_ref}"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      {
        echo "changed=true"
        echo "target-ref=${target_ref}"
      } >> "${GITHUB_OUTPUT}"
    fi
    exit 0
  fi

  if ! bool_true "${commit}"; then
    printf 'Commit disabled: updated image to %s without commit/push\n' "${target_ref}"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      {
        echo "changed=true"
        echo "target-ref=${target_ref}"
      } >> "${GITHUB_OUTPUT}"
    fi
    exit 0
  fi

  [[ -n "${commit_user_name}" ]] || fail "commit-user-name is required when commit=true"
  [[ -n "${commit_user_email}" ]] || fail "commit-user-email is required when commit=true"

  git add "${overlay_path_abs}/kustomization.yaml"
  changed="$(git diff --cached --name-only)"
  if [[ -z "${changed}" ]]; then
    printf 'No-op after staging: no commit created\n'
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      {
        echo "changed=false"
        echo "target-ref=${target_ref}"
      } >> "${GITHUB_OUTPUT}"
    fi
    exit 0
  fi

  git config --local user.name "${commit_user_name}"
  git config --local user.email "${commit_user_email}"
  git commit -m "${commit_message}"

  if ! git push origin "HEAD:${target_branch}"; then
    fail "push conflict while updating ${target_branch}; remote advanced, rebase and retry"
  fi

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "changed=true"
      echo "target-ref=${target_ref}"
    } >> "${GITHUB_OUTPUT}"
  fi

  printf 'Updated image to %s and pushed to %s\n' "${target_ref}" "${target_branch}"
}

main "$@"
