# Docker Tests Action

Reusable PR-preview readiness action for Docker workloads.

## What it does

- Builds the Docker image with an immutable `HEAD_SHA` tag.
- Runs Hadolint and Trivy.
- Pins third-party scanner action references (including Trivy) to non-floating refs to prevent supply-chain drift.
- Publishes preview images only for **eligible same-repo PRs** (default on).
- Manages ready-label lifecycle for eligible PRs (default on):
  - remove at start,
  - add only when build + push + live PR SHA validation pass, and Trivy passes when `scan-required=true`.
- Detects fork PRs and skips preview publish + label mutation by default.
- Always writes GitHub Step Summary.
- Optionally posts a PR comment summary.

## Inputs

| Name | Description | Default |
|---|---|---|
| `image-name` | Docker image name (`org/repo`) | required |
| `github-token` | GitHub token used for registry and PR API | required |
| `registry` | Container registry hostname | `ghcr.io` |
| `dockerfile-path` | Dockerfile path | `Dockerfile` |
| `context` | Docker build context | `.` |
| `build-args` | Newline-separated Docker build args | `''` |
| `preview-push-enabled` | Push preview image for eligible PRs | `true` |
| `ready-label-enabled` | Manage ready label lifecycle | `true` |
| `ready-label-name` | Label name to manage | `ready` |
| `pr-number` | Optional PR number override | `''` |
| `pr-head-sha` | Optional PR head SHA override | `''` |
| `scan-required` | Block readiness when Trivy fails | `true` |
| `scan-severity-threshold` | Trivy severity gate threshold | `CRITICAL` |
| `pr-comment-enabled` | Post PR comment summary | `false` |

## Outputs

| Name | Description |
|---|---|
| `image` | Base image repository |
| `tag` | Canonical immutable `HEAD_SHA` tag |
| `tags` | Newline-separated list of generated tags |
| `digest` | Preview image digest when pushed |
| `image-tag` | `image:tag` canonical reference |
| `image-digest` | `image@digest` canonical reference |

## PR Contract

- **Eligibility:** same-repo pull requests are eligible; fork pull requests are ineligible by default and skip preview push plus label mutation.
- **Stale-run guard:** readiness label add is gated by live PR `head.sha` revalidation so outdated runs do not mark stale commits as ready.
- **Ready-label lifecycle:** when enabled, the action removes the ready label at start and re-adds it only after successful build/push and SHA guard pass.
- **Scan gate defaults:** `scan-required=true` and `scan-severity-threshold=CRITICAL` by default; failed required scan blocks readiness.
- **Immutable preview tag:** canonical preview tag is full `HEAD_SHA`; mutable PR tags are not the default contract.
- **Stable outputs:** `image`, `tag`, `tags`, `digest`, `image-tag`, `image-digest` are always emitted for downstream workflow wiring.
- **Optional PR comment:** set `pr-comment-enabled=true` to post PR comment summary; default is summary-only in GitHub Step Summary.

## Permissions and Concurrency Guidance

- Use `packages: write` for preview image push to GHCR.
- Use `pull-requests: write` (and `issues: write` if your label policy requires it) for ready-label lifecycle and optional PR comments.
- Use per-PR concurrency to prevent parallel label races, for example: `group: docker-tests-${{ github.event.pull_request.number }}` with `cancel-in-progress: true`.

## Example

```yaml
jobs:
  docker-preview-readiness:
    runs-on: ubuntu-latest
    concurrency:
      group: docker-tests-${{ github.event.pull_request.number || github.ref }}
      cancel-in-progress: true
    permissions:
      contents: read
      pull-requests: write
      issues: write
      packages: write
    steps:
      - uses: actions/checkout@v5
      - name: Preview readiness
        id: docker-tests
        uses: qtsone/actions/docker/tests@main
        with:
          image-name: qtsone/my-service
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

## Eligibility model

- Same-repo PR: eligible for preview publish + ready-label lifecycle.
- Fork PR (or non-PR context): ineligible; preview publish and label mutation are skipped by default, with explicit Step Summary reporting.
