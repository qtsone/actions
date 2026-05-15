# Dynamic Delivery Actions Design Contract

Status: Proposed (for platform maintainer + app workflow author approval)
Date: 2026-05-15
Owner: qtsone/actions maintainers
Document type: Explanation / design contract

## Problem statement

`cloud-1` now owns the platform-side contract for pull-request preview routing and app-owned production image pins. What remains is reusable action architecture in `qtsone/actions` so app repositories can produce the correct image artifacts and write production image pins safely and consistently. Today, behavior is split across `docker/tests`, `docker/build`, and `release`, with missing output contracts, unclear readiness semantics, and no shared action for production `kustomization.yaml` image mutation.

This spec defines the reusable GitHub Actions contract that app repos depend on, without changing cloud-1 rendering logic and without prescribing app-specific workflow files.

## Goals and non-goals

### Goals

- Define stable contracts for reusable actions used in PR preview and production release flows.
- Make PR preview readiness explicit, deterministic, and safe against stale runs.
- Standardize image outputs (`image`, `tag`, `tags`, `digest`, `image-tag`, `image-digest`) for downstream steps.
- Introduce a dedicated reusable action for production overlay image writeback.
- Keep permissions minimal and split by concern.
- Document idempotency, concurrency, stale-run handling, and branch-protection implications.

### Non-goals

- No `cloud-1` organisation renderer changes.
- No app-specific workflow implementation details beyond contract-level call order.
- No merger of `docker/tests` and `docker/build` in this phase.
- No replacement of semantic-release behavior in `release`.

## Existing action gaps (brief)

- `docker/tests` is oriented to lint/build/scan feedback but does not currently define final PR readiness label lifecycle as a formal contract.
- `docker/tests` does not expose a complete output set for downstream reusable workflow composition.
- `docker/build` publishes release images but does not yet expose the same standardized output set.
- There is no reusable `kustomize/update-image` action for production overlay writeback.
- Current release flow responsibilities can be interpreted as overlapping; this spec separates semantic release from image writeback.

## Recommended architecture

- Keep `docker/tests` as the PR-preview-oriented action for now.
- Keep `docker/build` as the main/release image publishing action with current tag-default philosophy.
- Keep `release` semantic-release focused.
- Add a new reusable action `kustomize/update-image` dedicated to production overlay writeback.
- App workflow contract:
  - PR workflow calls `docker/tests`.
  - Release/tag workflow calls `release`, then `docker/build`, then `kustomize/update-image` (only after image push succeeds).
  - Argo CD convergence remains driven by existing webhook/polling mechanisms after Git writeback.

## Action contracts

### `docker/tests`

Purpose: PR preview image readiness gate for eligible PRs.

Default behavior:

- Pushes PR preview image by default.
- Manages `ready` label by default.
- Removes `ready` label at start of every eligible PR run.
- Uses immutable preview tag based on full PR `HEAD_SHA` only.
- Does not create mutable `pr-<number>` tags by default.

Eligibility and fork behavior:

- Same-repo PRs are eligible for preview publish and label mutation.
- Fork PRs default to no preview publishing and no label mutation.
- Fork PR runs must clearly report preview readiness was skipped.

Readiness gate semantics:

- Adds `ready` only after all of the following succeed:
  - image build
  - image push
  - scan gate pass
  - stale-run guard confirms live PR head SHA still equals built SHA
- Removes (or leaves absent) `ready` on all failure/skip paths:
  - build failure
  - push failure
  - scan failure
  - stale PR head SHA mismatch
  - fork skip

Scan and reporting:

- Scan result gates readiness by default.
- Gate must be configurable with `scan-required` and severity threshold input.
- Step Summary is always emitted.
- PR comment is optional.

Outputs (where applicable):

- `image`
- `tag`
- `tags`
- `digest`
- `image-tag`
- `image-digest`

### `docker/build`

Purpose: main/release image publishing action.

Default behavior:

- Remains the canonical reusable action for non-PR release image builds and pushes.
- Keeps its tag-default behavior model.

Outputs (must be exposed):

- `image`
- `tag`
- `tags`
- `digest`
- `image-tag`
- `image-digest`

### `kustomize/update-image`

Purpose: production overlay writeback action for `kustomization.yaml` image pin updates.

Core behavior:

- Uses `kustomize edit set image` to perform mutations.
- Ensures `kustomize` is installed in-action.
- Installer is vendored/adapted into `qtsone/actions` (not runtime-referenced from another repository).
- Installer hardening requirements:
  - `set -euo pipefail`
  - pinned default kustomize version
  - checksum verification with strict match
  - OS/arch detection (practical coverage)
  - safe `GITHUB_PATH` handling

Input modes:

- Simple mode:
  - `overlay-path`
  - `image-name`
  - `tag`
- Advanced mode:
  - `image-name`
  - optional `new-name`
  - exactly one of: `tag`, `digest`, `new-ref`

Reference semantics:

- `new-ref` is a full image reference.
- `tag` is tag-only.
- Default production pin mode is tag; digest pin is optional.

Git writeback defaults:

- `target-branch: main`
- `commit: true`
- direct push to `main`
- `dry-run` supported

Safety and validation:

- No-op when target image already matches desired value.
- Runs `kustomize build <overlay-path>` before commit.
- Fails clearly on push conflict.

Commit message policy:

- Default message: `chore(deploy): update production image [skip ci]`.
- Must avoid release-triggering commit types/footers and semantic-release loop patterns.

### `release`

Purpose: semantic-release orchestration only.

Contract:

- Stays focused on version/release publication semantics.
- Does not mutate production overlays.
- Provides release outputs consumed by downstream workflow logic.

## App workflow contracts

### PR flow contract

- Triggered by PR events.
- Calls `docker/tests`.
- Relies on `docker/tests` for preview publish decision, scan gate readiness decision, stale-SHA guard, and `ready` label lifecycle.
- Exposes actionable run summary for maintainers and contributors; optional PR comment can be enabled.

### Production release flow contract

- Triggered by release/tag strategy defined by the app repository.
- Ordered calls:
  1. `release`
  2. `docker/build`
  3. `kustomize/update-image` (only after image push succeeds)
- `kustomize/update-image` writes production overlay image pin to `main` by default.
- Argo CD convergence is external to the workflow contract and handled by existing webhook/polling behavior.

## Security and permissions model

Principle: least privilege per job and per action invocation.

- Image push jobs: `packages: write`.
- PR label/comment mutation: `pull-requests: write` and `issues: write`.
- Production overlay writeback job: `contents: write`.
- Fork PR default path performs no preview publish and no label mutation to avoid privilege escalation and token misuse.

## Failure, idempotency, and concurrency behavior

- **Stale-run protection:** PR readiness is conditioned on live PR head SHA match before labeling ready.
- **Idempotency:**
  - `kustomize/update-image` no-ops when desired image ref already set.
  - repeat runs with unchanged inputs do not create unnecessary commits.
- **Failure outcomes:**
  - PR flow keeps/removes `ready` on all non-success paths.
  - production writeback fails loudly on branch push conflicts.
- **Concurrency expectations:**
  - app workflows should use per-PR and per-release concurrency groups to reduce racing updates.
  - stale-run guard is mandatory defense when concurrency cancellation cannot prevent overlap.
- **Branch-protection consideration:**
  - direct `main` push default requires branch policy to allow the workflow actor/token path; otherwise adopters must intentionally override strategy (outside this action contract).

## Rollout and migration notes (from current `docker/tests` behavior)

- Preserve `docker/tests` role as PR-check action; do not merge with `docker/build` now.
- Shift `docker/tests` from local-only build semantics to default preview publish + readiness gating semantics.
- Introduce standardized outputs so downstream reusable workflows can consume image identity consistently.
- Move production image mutation responsibility out of release scripts/workflows into `kustomize/update-image`.
- Adopt immutable `HEAD_SHA` preview tag default and remove dependency on mutable PR-number tags.

## Acceptance criteria

- Contract clearly separates responsibilities across `docker/tests`, `docker/build`, `release`, and `kustomize/update-image`.
- `docker/tests` defaults and failure semantics match the approved readiness/label decisions.
- Output contract is explicit and consistent for `docker/tests` and `docker/build`.
- `kustomize/update-image` modes, defaults, safety checks, and commit policy are explicit.
- App workflow ordering for PR and release paths is explicit and unambiguous.
- Permission model is minimal, split by capability, and documents fork PR restrictions.
- Idempotency, stale-run, concurrency, and branch-protection implications are documented.
- No cloud-1 renderer scope or app-specific implementation details are included.

## Open questions

None.
