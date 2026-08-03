# Docker Tests Action

Reusable PR-preview readiness action for Docker workloads.

## What it does

- Builds the image once with an immutable `HEAD_SHA` tag and pushes it straight from BuildKit for eligible same-repo PRs; Trivy then scans the pushed reference.
- Falls back to a local `load: true` build for fork PRs and non-PR contexts, which have no push credentials, and scans that from the local daemon.
- Skips the build entirely when `content-tag` is set and the registry already holds that tag, re-tagging the existing image to the PR head instead.
- Runs Hadolint and Trivy with warning-first defaults.
- Pins third-party scanner action references (including Trivy) to non-floating refs to prevent supply-chain drift.
- Publishes preview images only for **eligible same-repo PRs** (default on).
- Manages ready-label lifecycle for eligible PRs (default on):
  - remove at start,
  - add only when build + push + live PR SHA validation pass, and Trivy passes when `scan-required=true`.
- Publishes the `content-tag` for later reuse only after Trivy and the stale-head guard pass.
- Detects fork PRs and skips preview publish + label mutation by default.
- Always writes GitHub Step Summary.
- Posts a PR comment diagnostics summary via `gh` CLI by default (callers can disable).

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
| `scan-required` | Block readiness when Trivy fails | `false` |
| `scan-severity-threshold` | Trivy severity gate threshold | `CRITICAL` |
| `pr-comment-enabled` | Post/update PR diagnostics comment (`false` disables) | `true` |
| `content-tag` | Tag naming the content this build would produce (for example `src-<id>` from `git/content-id`); empty disables promote-on-hit | `''` |

## Outputs

| Name | Description |
|---|---|
| `image` | Base image repository |
| `tag` | Canonical immutable `HEAD_SHA` tag |
| `tags` | Newline-separated list of generated tags |
| `digest` | Preview image digest, empty when withheld |
| `image-tag` | `image:tag` canonical reference |
| `image-digest` | `image@digest` canonical reference, empty when the digest is withheld |

`digest` and `image-digest` come back empty when the push did not succeed, the PR head is
stale, or `scan-required=true` and the scan failed. They are a handoff into deployment
(`kustomize/update-image` `new-ref`), so they are withheld under the same conditions that
withhold the ready label. Guard on them rather than assuming a value:
`if: ${{ steps.docker-tests.outputs.image-digest != '' }}`.

## PR Contract

- **Eligibility:** same-repo pull requests are eligible; fork pull requests are ineligible by default and skip preview push plus label mutation.
- **Stale-run guard:** readiness label add is gated by live PR `head.sha` revalidation so outdated runs do not mark stale commits as ready.
- **Ready-label lifecycle:** when enabled, the action removes the ready label at start and re-adds it only after successful build/push and SHA guard pass.
- **Scan/lint defaults:** `scan-required=false` and `scan-severity-threshold=CRITICAL` by default; Trivy and Hadolint findings are warnings unless callers opt into strict Trivy gating.
- **Strict scan opt-in:** `scan-required=true` does not hold the push back. The image is built once, pushed, and scanned from the pushed reference, so an image that later fails the scan exists in the registry for the few seconds between the push and the scan result. What a failing required scan withholds is the ready label, the `digest`/`image-digest` outputs, and the content tag. The ready label is the deploy gate, not the presence of the image in the registry.
- **Content-tag reuse:** when `content-tag` names a tag the registry already holds, the image is re-tagged to the PR head by a registry-side manifest copy instead of rebuilt. A miss falls through to a normal build; so does any other registry error, since the promote step is `continue-on-error` and a rebuild is always a safe fallback. The content tag is published by a separate step that runs only after Trivy and the stale-head guard pass, so an image that failed a required scan never becomes a promotion source for a later release.
- **Immutable preview tag:** canonical preview tag is full `HEAD_SHA`; mutable PR tags are not the default contract. The content tag is mutable by design and is the one future runs trust.
- **Stable outputs:** `image`, `tag`, `tags`, and `image-tag` are always emitted for downstream workflow wiring; `digest` and `image-digest` are conditional (see Outputs).
- **PR diagnostics comment:** set `pr-comment-enabled=true` (default) to publish/update a PR comment with sections for readiness, warnings, Trivy outcome, Hadolint outcome, push outcome, stale PR head, and report excerpts (or `no report available`).

## Permissions and Concurrency Guidance

- Use `packages: write` for preview image push to GHCR.
- Use `pull-requests: write` (and `issues: write` if your label policy requires it) for ready-label lifecycle and default-on PR diagnostics comments.
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

## Skipping the build when the content is unchanged

Pair with `git/content-id` to name the image by the tracked content that produced it. When
a previous run already published that tag, this run re-tags it to the PR head instead of
rebuilding.

```yaml
- uses: actions/checkout@v5
- name: Compute content id
  id: content
  uses: qtsone/actions/git/content-id@main
  with:
    exclude: |
      docs
      README.md
- name: Preview readiness
  id: docker-tests
  uses: qtsone/actions/docker/tests@main
  with:
    image-name: qtsone/my-service
    github-token: ${{ secrets.GITHUB_TOKEN }}
    content-tag: src-${{ steps.content.outputs.id }}
```

The id covers tracked git content only. Anything else that changes the image the build
would produce — build args, a floating base image, a toolchain version — has to be folded
in through `git/content-id`'s `extra` input, or a hit will republish an image that no
longer matches the inputs.

## Eligibility model

- Same-repo PR: eligible for preview publish + ready-label lifecycle.
- Fork PR (or non-PR context): ineligible; preview publish and label mutation are skipped by default, with explicit Step Summary reporting.
