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

emit_outputs() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "changed=$1"
      echo "target-ref=$2"
    } >> "${GITHUB_OUTPUT}"
  fi
}

# Prints the newTag of one entry in a kustomization's images list, or nothing.
current_image_tag() {
  local kustomization="$1" name="$2"
  awk -v name="${name}" '
    function value(line) {
      sub(/^[^:]*:[[:space:]]*/, "", line)
      gsub(/["\047]/, "", line)
      sub(/[[:space:]]+$/, "", line)
      return line
    }
    /^[[:space:]]*-[[:space:]]+name:/ { in_entry = (value($0) == name); next }
    /^[^[:space:]-]/ { in_entry = 0 }
    in_entry && /^[[:space:]]+newTag:/ { print value($0); exit }
  ' "${kustomization}"
}

# True when both tags are MAJOR.MINOR.PATCH (optional leading v, any suffix) and the
# first is strictly lower. Equal cores and non-semver tags (sha-…, latest) never count
# as older, so a re-release or a pre-release of the deployed version still goes through.
semver_older() {
  local re='^v?([0-9]+)\.([0-9]+)\.([0-9]+)'
  local a1 a2 a3 i
  [[ "$1" =~ ${re} ]] || return 1
  a1="${BASH_REMATCH[1]}" a2="${BASH_REMATCH[2]}" a3="${BASH_REMATCH[3]}"
  [[ "$2" =~ ${re} ]] || return 1
  local -a a=("${a1}" "${a2}" "${a3}") b=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")
  for i in 0 1 2; do
    ((10#${a[i]} < 10#${b[i]})) && return 0
    ((10#${a[i]} > 10#${b[i]})) && return 1
  done
  return 1
}

main() {
  require_cmd git
  require_cmd kustomize

  local overlay_path overlay_path_abs extra_paths image_name new_name tag digest new_ref target_branch commit dry_run commit_message
  local commit_user_name commit_user_email push_attempts push_retry_delay
  local mode_count image_spec before_file after_file target_ref kustomization_changed extras_dir

  before_file=""
  after_file=""
  extras_dir=""
  cleanup_tempfiles() {
    rm -f "${before_file:-}" "${after_file:-}"
    [[ -z "${extras_dir:-}" ]] || rm -rf "${extras_dir}"
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
  push_attempts="$(trim "${PUSH_ATTEMPTS:-5}")"
  push_retry_delay="$(trim "${PUSH_RETRY_DELAY:-3}")"

  [[ -n "${overlay_path}" ]] || fail "overlay-path is required"
  [[ -n "${image_name}" ]] || fail "image-name is required"
  [[ -d "${overlay_path}" ]] || fail "overlay-path does not exist: ${overlay_path}"
  overlay_path_abs="$(cd "${overlay_path}" && pwd)"
  [[ -f "${overlay_path_abs}/kustomization.yaml" ]] || fail "kustomization.yaml not found in overlay-path: ${overlay_path_abs}"
  [[ "${push_attempts}" =~ ^[1-9][0-9]*$ ]] || fail "PUSH_ATTEMPTS must be a positive integer: ${push_attempts}"
  [[ "${push_retry_delay}" =~ ^[0-9]+$ ]] || fail "PUSH_RETRY_DELAY must be a non-negative integer: ${push_retry_delay}"

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

  set_image() {
    (
      cd "${overlay_path_abs}"
      kustomize edit set image "${image_spec}"
      kustomize build "${overlay_path_abs}" >/dev/null
    )
  }

  if bool_true "${dry_run}" || ! bool_true "${commit}"; then
    before_file="$(mktemp)"
    after_file="$(mktemp)"
    cp "${overlay_path_abs}/kustomization.yaml" "${before_file}"
    set_image
    cp "${overlay_path_abs}/kustomization.yaml" "${after_file}"

    kustomization_changed="true"
    if cmp -s "${before_file}" "${after_file}"; then
      kustomization_changed="false"
      if [[ -z "${extra_paths}" ]]; then
        printf 'No-op: kustomization already at target image %s\n' "${target_ref}"
        emit_outputs false "${target_ref}"
        exit 0
      fi
    fi

    if bool_true "${dry_run}"; then
      # Reachable with an unchanged kustomization only when extra-paths kept us past the
      # no-op return above, and dry-run never stages those — so say so rather than claiming
      # an update that did not happen.
      if bool_true "${kustomization_changed}"; then
        printf 'Dry-run: updated image to %s without commit/push\n' "${target_ref}"
      else
        printf 'Dry-run: kustomization already at %s; extra-paths are not staged in dry-run\n' "${target_ref}"
      fi
    elif bool_true "${kustomization_changed}"; then
      printf 'Commit disabled: updated image to %s without commit/push\n' "${target_ref}"
    else
      printf 'Commit disabled: kustomization already at %s; extra-paths are not staged\n' "${target_ref}"
    fi
    emit_outputs "${kustomization_changed}" "${target_ref}"
    exit 0
  fi

  [[ -n "${commit_user_name}" ]] || fail "commit-user-name is required when commit=true"
  [[ -n "${commit_user_email}" ]] || fail "commit-user-email is required when commit=true"

  # Files the caller rewrote to stay in step with this image bump, staged so they land in
  # the same commit. Two commits would mean two Argo syncs and a window where the overlay's
  # image tag and whatever tracks it disagree. Each attempt below checks out a fresh target
  # branch, which discards the caller's edits, so their content is kept aside here.
  local -a extra_files=()
  if [[ -n "${extra_paths}" ]]; then
    local repo_root extra extra_abs
    repo_root="$(git rev-parse --show-toplevel)"
    extras_dir="$(mktemp -d)"
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
      cp "${extra_abs}" "${extras_dir}/${#extra_files[@]}"
      extra_files+=("${extra_abs}")
    done <<< "${extra_paths}"
  fi

  git config --local user.name "${commit_user_name}"
  git config --local user.email "${commit_user_email}"

  # Release workflows check out the tag and build for minutes; any merge or second release
  # in that window moves the target branch, and a commit on the tag's HEAD is then refused
  # (QTS-1883). So every attempt starts from the target branch as it is now and re-applies
  # the edit there, rather than rebasing a commit whose overlay may already be stale.
  local attempt deployed_tag i
  for ((attempt = 1; attempt <= push_attempts; attempt++)); do
    git fetch --quiet origin "${target_branch}"
    git checkout --quiet --force --detach FETCH_HEAD
    [[ -f "${overlay_path_abs}/kustomization.yaml" ]] \
      || fail "kustomization.yaml not found in overlay-path on ${target_branch}: ${overlay_path_abs}"

    # Two overlapping releases can reach this point in either order; the older one must
    # not roll the target branch back past the newer one it already holds.
    if [[ -n "${tag}" ]]; then
      deployed_tag="$(current_image_tag "${overlay_path_abs}/kustomization.yaml" "${image_name}")"
      if semver_older "${tag}" "${deployed_tag}"; then
        printf 'Skipped: %s already deploys %s at %s, newer than %s; leaving it\n' \
          "${target_branch}" "${image_name}" "${deployed_tag}" "${tag}"
        emit_outputs false "${target_ref}"
        exit 0
      fi
    fi

    for i in "${!extra_files[@]}"; do
      mkdir -p "$(dirname "${extra_files[i]}")"
      cp "${extras_dir}/${i}" "${extra_files[i]}"
    done
    set_image

    git add "${overlay_path_abs}/kustomization.yaml" "${extra_files[@]}"
    if git diff --cached --quiet; then
      if [[ -z "${extra_paths}" ]]; then
        printf 'No-op: kustomization already at target image %s\n' "${target_ref}"
      else
        printf 'No-op after staging: no commit created\n'
      fi
      emit_outputs false "${target_ref}"
      exit 0
    fi

    git commit --quiet -m "${commit_message}"
    if git push origin "HEAD:${target_branch}"; then
      emit_outputs true "${target_ref}"
      printf 'Updated image to %s and pushed to %s\n' "${target_ref}" "${target_branch}"
      exit 0
    fi

    printf 'Push to %s rejected on attempt %d of %d; refetching and retrying\n' \
      "${target_branch}" "${attempt}" "${push_attempts}" >&2
    ((attempt == push_attempts)) || sleep "$((attempt * push_retry_delay))"
  done

  fail "push conflict while updating ${target_branch}: still rejected after ${push_attempts} attempts"
}

main "$@"
