# Dynamic Delivery Actions Implementation Plan
> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver reusable `qtsone/actions` contracts for PR preview readiness, release image outputs, and production overlay image writeback required by cloud-1 dynamic delivery consumers.

**Architecture:** Keep responsibilities split across existing actions: `docker/tests` owns PR preview readiness gates and labels, `docker/build` owns release/main image publish outputs, `release` stays semantic-release only, and a new `kustomize/update-image` action owns production overlay image mutation + writeback. Use deterministic shell/workflow tests with local fixtures and explicit output assertions to keep composite behavior stable.

**Tech Stack:** GitHub composite actions (YAML), Bash (`set -euo pipefail`), Docker official actions, Trivy action, GitHub CLI/API calls from workflow steps, Kustomize CLI, shell-based deterministic tests, GitHub workflow-based integration checks.

---

## Problem Model

- App repos need a stable action contract to complete dynamic delivery without embedding custom scripting per repository.
- Current gaps are contract-level, not cloud-1 renderer-level: missing image outputs, incomplete PR readiness semantics, and no reusable production overlay writeback action.
- Risk areas are stale PR runs, fork PR privilege boundaries, branch push conflicts, and non-deterministic scan/report behavior.
- Success requires deterministic outputs and clear failure/skip semantics that app workflows can compose safely.

## Acceptance Criteria

- `docker/tests` implements default preview push + default ready-label lifecycle with fork-safe skips, stale SHA guard, scan gating, and documented optional PR comment mode.
- `docker/tests` exposes outputs: `image`, `tag`, `tags`, `digest`, `image-tag`, `image-digest`.
- `docker/build` exposes outputs: `image`, `tag`, `tags`, `digest`, `image-tag`, `image-digest` without changing its main/release role.
- `release` remains semantic-release focused and does not gain overlay mutation behavior.
- New `kustomize/update-image` action exists with pinned hardened installer, `kustomize edit set image` mutation, no-op detection, pre-commit `kustomize build`, push-conflict failure, and commit defaults.
- Docs include app workflow call order: PR uses `docker/tests`; release flow uses `release` -> `docker/build` -> `kustomize/update-image`.
- Permissions, concurrency/stale-run handling, idempotency, and branch-protection implications are explicitly documented.
- Deterministic tests/fixtures/workflow checks are added or extended for each changed action contract.

## Size Estimate

- Estimated effort: 2-3 engineer days.
- Complexity: medium-high (cross-action contract alignment + safety semantics + new writeback action).
- Primary risk: edge-case correctness in PR label transitions and Git writeback race/conflict handling.

## Slice Breakdown And Dependencies

1. Test harness foundation for composite-action contract checks (blocks all other slices).
2. `docker/build` outputs + docs + tests (independent after test harness exists).
3. `docker/tests` readiness/preview semantics + outputs + docs + tests (depends on harness; independent from Task 2 implementation details).
4. New `kustomize/update-image` action + installer + mutation/writeback scripts + tests (depends on harness only).
5. Repo-level docs/examples for PR and release workflow contracts, permissions, concurrency, and branch-protection implications (depends on Tasks 2-4).
6. Final QA gate across action contracts (depends on Tasks 1-5).

## File Responsibility Map

- `docker/build/action.yaml`: add standardized composite outputs and wire values from metadata/build steps.
- `docker/build/README.md`: document output contract and release-flow usage.
- `docker/tests/action.yaml`: implement preview push defaults, ready-label lifecycle, fork behavior, stale SHA guard, scan gate controls, reporting controls, and outputs.
- `docker/tests/README.md`: document readiness semantics, fork behavior, scan gates, outputs, required permissions.
- `release/README.md`: clarify release-only responsibility and downstream handoff contract.
- `kustomize/update-image/action.yaml`: composite entrypoint for install/mutate/validate/commit/push flow.
- `kustomize/update-image/scripts/install_kustomize.sh`: pinned, checksum-verified installer with strict OS/arch handling and safe path export.
- `kustomize/update-image/scripts/update_image.sh`: input-mode parsing, kustomize mutation, no-op handling, validation build, commit/push logic.
- `kustomize/update-image/README.md`: inputs/modes/defaults/safety behavior and workflow examples.
- `tests/fixtures/kustomize/base/kustomization.yaml`: deterministic mutation fixture.
- `tests/fixtures/kustomize/expected/`: expected outputs for tag/digest/new-ref modes.
- `tests/scripts/test_kustomize_installer.sh`: deterministic installer behavior checks (version, checksum mismatch, arch mapping).
- `tests/scripts/test_kustomize_update_image.sh`: deterministic mutation/writeback logic checks with local git repos.
- `.github/workflows/test-docker-actions.yml`: workflow integration checks for `docker/build` and `docker/tests` outputs/flags using dry mock conditions where possible.
- `.github/workflows/test-kustomize-update-image.yml`: workflow integration checks for new action modes, no-op behavior, and dry-run/commit paths.
- `README.md`: top-level action catalog updates for new action and dynamic delivery contract summary.

## Task 1: Create Deterministic Contract Test Harness

**Dependencies:** none

**Files:**
- Create: `tests/scripts/test_kustomize_installer.sh`
- Create: `tests/scripts/test_kustomize_update_image.sh`
- Create: `tests/fixtures/kustomize/base/kustomization.yaml`
- Create: `tests/fixtures/kustomize/expected/tag/kustomization.yaml`
- Create: `tests/fixtures/kustomize/expected/digest/kustomization.yaml`

- [ ] **Step 1: Add fixture and script skeletons with strict shell options**
- [ ] **Step 2: Implement installer tests for pinned version, checksum mismatch failure, and OS/arch mapping**
- [ ] **Step 3: Implement update-image tests for simple mode (`tag`) and advanced mode (`digest`/`new-ref`) parse + mutation behavior**
- [ ] **Step 4: Add local git repo fixture logic validating no-op commit suppression and push-conflict error messaging paths**
- [ ] **Step 5: Make scripts executable and ensure deterministic tempdir cleanup**

**Verification command group:**

```bash
chmod +x tests/scripts/test_kustomize_installer.sh tests/scripts/test_kustomize_update_image.sh
bash tests/scripts/test_kustomize_installer.sh
bash tests/scripts/test_kustomize_update_image.sh
```

**Expected outcomes:**
- Both scripts exit `0`.
- Failure-path assertions prove non-zero exit and exact error text fragments for checksum mismatch, invalid input combinations, and push conflict.

## Task 2: Add Standardized `docker/build` Outputs

**Dependencies:** Task 1

**Files:**
- Modify: `docker/build/action.yaml`
- Modify: `docker/build/README.md`
- Modify: `.github/workflows/test-docker-actions.yml`

- [ ] **Step 1: Add composite action `outputs` in `docker/build/action.yaml` mapping to metadata/build step outputs (`image`, `tag`, `tags`, `digest`, `image-tag`, `image-digest`)**
- [ ] **Step 2: Normalize output derivation rules when custom `inputs.tags` is used (first tag as `tag`, full newline list as `tags`)**
- [ ] **Step 3: Extend `docker/build/README.md` with output table and release-flow usage snippet consuming `image-digest`**
- [ ] **Step 4: Add/extend `.github/workflows/test-docker-actions.yml` job asserting all six outputs are present and correctly formatted after a controlled build invocation**

**Verification command group:**

```bash
yq '.outputs' docker/build/action.yaml
yq '.jobs' .github/workflows/test-docker-actions.yml
```

**Expected outcomes:**
- `docker/build/action.yaml` contains all six outputs.
- Workflow test job references and validates all six outputs.

## Task 3: Upgrade `docker/tests` Preview Readiness Contract

**Dependencies:** Task 1

**Files:**
- Modify: `docker/tests/action.yaml`
- Modify: `docker/tests/README.md`
- Modify: `.github/workflows/test-docker-actions.yml`
- Modify: `README.md`

- [ ] **Step 1: Add/rename inputs for scan gate control (`scan-required`, severity threshold), ready-label controls, optional PR comment control, and preview publish toggles with secure defaults**
- [ ] **Step 2: Implement eligibility detection (same-repo PR vs fork PR), default fork behavior (skip publish + skip label mutation), and explicit Step Summary messaging for skipped readiness**
- [ ] **Step 3: Implement ready-label lifecycle: remove `ready` at start for eligible PRs, remove/keep absent on all fail/skip paths, add only after build + push + scan pass + live PR HEAD SHA match**
- [ ] **Step 4: Switch default preview tag to immutable full `HEAD_SHA` only and remove mutable `pr-<number>` default behavior**
- [ ] **Step 5: Ensure scan gates readiness by default, configurable via `scan-required` and severity input; always emit Step Summary and keep PR comment optional**
- [ ] **Step 6: Add standardized outputs (`image`, `tag`, `tags`, `digest`, `image-tag`, `image-digest`) and document exact semantics in README**
- [ ] **Step 7: Extend `.github/workflows/test-docker-actions.yml` with matrix checks for eligible PR, fork PR skip, scan fail, and stale SHA mismatch branches validating label/output/report behavior**

**Verification command group:**

```bash
yq '.inputs, .outputs' docker/tests/action.yaml
yq '.jobs' .github/workflows/test-docker-actions.yml
```

**Expected outcomes:**
- `docker/tests` input/output contract includes all required controls and outputs.
- Workflow checks cover ready-label add/remove logic, fork skips, stale SHA guard, and scan-gate outcomes.

## Task 4: Add `kustomize/update-image` Composite Action

**Dependencies:** Task 1

**Files:**
- Create: `kustomize/update-image/action.yaml`
- Create: `kustomize/update-image/scripts/install_kustomize.sh`
- Create: `kustomize/update-image/scripts/update_image.sh`
- Create: `kustomize/update-image/README.md`
- Modify: `.github/workflows/test-kustomize-update-image.yml`

- [ ] **Step 1: Create `action.yaml` inputs/outputs with defaults (`target-branch: main`, `commit: true`, `dry-run` and `skip-install` support, mode-selection validation)**
- [ ] **Step 2: Implement vendored installer script with `set -euo pipefail`, pinned default version, checksum strict match, safe tempdir extraction, and `GITHUB_PATH` export**
- [ ] **Step 3: Implement mutation/writeback script using `kustomize edit set image` supporting simple mode (`overlay-path`, `image-name`, `tag`) and advanced mode (`image-name`, optional `new-name`, exactly one of `tag|digest|new-ref`)**
- [ ] **Step 4: Implement no-op detection, `kustomize build <overlay-path>` pre-commit validation, default commit message `chore(deploy): update production image [skip ci]`, direct push to target branch, and explicit push-conflict failure text**
- [ ] **Step 5: Add action README usage for default production tag pin and optional digest pin, including minimal required permissions (`contents: write`) and branch-protection caveat**
- [ ] **Step 6: Add/extend workflow integration tests covering dry-run, commit true, skip-install path, no-op path, and conflict path assertions**

**Verification command group:**

```bash
chmod +x kustomize/update-image/scripts/install_kustomize.sh kustomize/update-image/scripts/update_image.sh
bash tests/scripts/test_kustomize_installer.sh
bash tests/scripts/test_kustomize_update_image.sh
yq '.inputs, .runs' kustomize/update-image/action.yaml
```

**Expected outcomes:**
- Unit-style script tests pass and cover install/mutation safety paths.
- Action metadata shows both mode inputs and writeback defaults.

## Task 5: Document App Workflow Contract And Permissions Split

**Dependencies:** Tasks 2, 3, 4

**Files:**
- Modify: `README.md`
- Modify: `docker/tests/README.md`
- Modify: `docker/build/README.md`
- Modify: `release/README.md`
- Modify: `kustomize/update-image/README.md`

- [ ] **Step 1: Update top-level `README.md` with dynamic delivery action matrix and explicit call order (`release` -> `docker/build` -> `kustomize/update-image`)**
- [ ] **Step 2: Add PR contract section to `docker/tests/README.md` (fork restrictions, stale-run guard, label lifecycle, scan gate defaults, optional PR comment)**
- [ ] **Step 3: Add release image output contract section to `docker/build/README.md`**
- [ ] **Step 4: Clarify `release/README.md` scope boundary (semantic-release only, no overlay mutation)**
- [ ] **Step 5: Add permissions and concurrency guidance snippets across docs (packages write for image push, pull-requests/issues write for PR label/comment, contents write for writeback; per-PR and per-release concurrency groups)**

**Verification command group:**

```bash
grep -n "kustomize/update-image" README.md
grep -n "release -> docker/build -> kustomize/update-image" README.md
grep -n "semantic-release only" release/README.md
```

**Expected outcomes:**
- All docs align on responsibility boundaries and workflow ordering.
- Permissions/concurrency guidance appears in user-facing docs.

## Task 6: Final QA Gate

**Dependencies:** Tasks 1-5

**Files:**
- Modify (if needed): `.github/workflows/test-docker-actions.yml`
- Modify (if needed): `.github/workflows/test-kustomize-update-image.yml`

- [ ] **Step 1: Run shell-based deterministic test scripts locally**
- [ ] **Step 2: Validate composite action metadata for all changed/new actions (`docker/build`, `docker/tests`, `kustomize/update-image`)**
- [ ] **Step 3: Run kustomize fixture build checks in tests to ensure mutation output remains valid manifests**
- [ ] **Step 4: Run a targeted docs consistency sweep to confirm all required outputs/defaults are documented exactly once per action README and summarized in root README**
- [ ] **Step 5: Confirm no scope creep into cloud-1 or app-specific repo code; confirm no commit steps are mandatory in plan**

**Verification command group:**

```bash
bash tests/scripts/test_kustomize_installer.sh
bash tests/scripts/test_kustomize_update_image.sh
yq '.outputs' docker/build/action.yaml
yq '.outputs' docker/tests/action.yaml
yq '.inputs' kustomize/update-image/action.yaml
```

**Expected outcomes:**
- Deterministic tests pass.
- Output/input contracts match approved design.
- No out-of-scope file changes are required.

## Final QA Exit Criteria

- Every approved design requirement is implemented and mapped to at least one task above.
- No placeholder markers exist in code or docs introduced by this plan.
- `docker/tests` readiness semantics are deterministic for success/failure/fork/stale-SHA paths.
- `docker/build` and `docker/tests` publish uniform output keys.
- `kustomize/update-image` safely handles install, mutation, validation, no-op, and push-conflict paths.
- Documentation enables app teams to adopt PR and release contracts without reading cloud-1 internals.

## Assumptions

- `yq` is available to maintainers for local metadata inspection commands.
- GitHub-hosted workflow integration checks are the canonical integration verification path for composite actions that rely on Actions runtime context.
- The repository accepts adding `tests/` and workflow files for deterministic contract validation.
- Branch policies in consuming repos may require intentional override if direct push-to-main is blocked; the default action contract still targets direct push.
