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

  local overlay_path overlay_path_abs extra_paths image_name new_name tag digest new_ref target_branch commit dry_run commit_message
  local commit_user_name commit_user_email
  local mode_count image_spec before_file after_file changed target_ref kustomization_changed

  before_file=""
  after_file=""
  cleanup_tempfiles() {
    rm -f "${before_file:-}" "${after_file:-}"
  }
  trap cleanup_tempfiles EXIT

  overlay_path="$(trim "${OVERLAY_PATH:-}")"
  extra_paths="${EXTRA_PATHS:-}"
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
  kustomization_changed="true"
  if cmp -s "${before_file}" "${after_file}"; then
    kustomization_changed="false"
    # Only a short-circuit when there is nothing else to stage. With extra-paths the
    # caller may have rewritten a companion file that still has to reach the same commit,
    # so the staged diff below is the authority on whether this run is a no-op.
    if [[ -z "${extra_paths}" ]]; then
      printf 'No-op: kustomization already at target image %s\n' "${target_ref}"
      if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        {
          echo "changed=false"
          echo "target-ref=${target_ref}"
        } >> "${GITHUB_OUTPUT}"
      fi
      exit 0
    fi
  fi

  if bool_true "${dry_run}"; then
    printf 'Dry-run: kustomization changed=%s for %s; extra-paths not staged\n' "${kustomization_changed}" "${target_ref}"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      {
        echo "changed=${kustomization_changed}"
        echo "target-ref=${target_ref}"
      } >> "${GITHUB_OUTPUT}"
    fi
    exit 0
  fi

  if ! bool_true "${commit}"; then
    printf 'Commit disabled: kustomization changed=%s for %s\n' "${kustomization_changed}" "${target_ref}"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      {
        echo "changed=${kustomization_changed}"
        echo "target-ref=${target_ref}"
      } >> "${GITHUB_OUTPUT}"
    fi
    exit 0
  fi

  [[ -n "${commit_user_name}" ]] || fail "commit-user-name is required when commit=true"
  [[ -n "${commit_user_email}" ]] || fail "commit-user-email is required when commit=true"

  git add "${overlay_path_abs}/kustomization.yaml"

  # Files the caller rewrote to stay in step with this image bump, staged here so they
  # land in the same commit. Two commits would mean two Argo syncs and a window where the
  # overlay's image tag and whatever tracks it disagree.
  if [[ -n "${extra_paths}" ]]; then
    local repo_root extra extra_abs
    repo_root="$(git rev-parse --show-toplevel)"
    while IFS= read -r extra; do
      extra="$(trim "${extra}")"
      [[ -n "${extra}" ]] || continue
      # Named files only, inside the repository. This action commits and pushes to the
      # target branch unreviewed, so a caller passing a directory — `.` being the most
      # plausible misreading — must not sweep in whatever an earlier step left behind.
      [[ -f "${extra}" ]] || fail "extra-paths entry is not a regular file: ${extra}"
      # -P on both sides: git reports a resolved path, so comparing it against a logical
      # one puts every entry "outside the repository" wherever a parent is a symlink.
      extra_abs="$(cd "$(dirname "${extra}")" && pwd -P)/$(basename "${extra}")"
      [[ "${extra_abs}" == "${repo_root}/"* ]] || fail "extra-paths entry is outside the repository: ${extra}"
      git add "${extra_abs}"
    done <<< "${extra_paths}"
  fi

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
