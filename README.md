# QTS Actions

Collection of reusable GitHub Actions for standardized workflows.

## Runner selection

Org repos do not hardcode a runner label. Every job selects its runner through an
organization-level Actions variable, so the whole org can be moved between the
self-hosted ARC pool and GitHub-hosted runners without touching a single repo.

```yaml
jobs:
  build:
    runs-on: ${{ vars.RUNNER_SMALL || 'ubuntu-latest' }}
```

| Variable | ARC value | Backing scale set |
|---|---|---|
| `RUNNER_SMALL` | `arc-small` | `arc-runner-small` (max 6, 1 CPU / 1Gi) |
| `RUNNER_MEDIUM` | `arc-medium` | `arc-runner-medium` (max 3, 2 CPU / 4Gi) |

Scale sets are defined in `qtsone/cloud-1` (`gitops/org/projects/ci.yaml`).
`arc-large` exists there but no workflow currently targets it, so it has no variable.

**Why the `||` fallback.** `runs-on` accepts only the `github`, `needs`, `strategy`,
`matrix`, `vars` and `inputs` contexts. An undefined variable resolves to an empty
string, and an empty `runs-on` is a workflow *configuration* error — every job in the
repo goes red with an error that does not name the missing variable. The fallback
converts that into a job that merely runs somewhere else, and makes the behaviour for
fork PRs (where variable availability is not guaranteed) explicit rather than fatal.

**Switching the whole org.** Requires `admin:org`.

```sh
gh api -X PATCH /orgs/qtsone/actions/variables/RUNNER_SMALL  -f value=ubuntu-latest
gh api -X PATCH /orgs/qtsone/actions/variables/RUNNER_MEDIUM -f value=ubuntu-latest
```

Substitute `arc-small` / `arc-medium` to move back. The change takes effect on the next
workflow run; runs already queued or in flight keep the value they started with.

> Org-hosted runners are billed for private repos, and the ARC image
> (`ghcr.io/qtsone/runner`) pre-bakes Node, Python, uv, buf and bun into the tool cache.
> On `ubuntu-latest` the `setup-*` actions re-download those instead of hitting the
> baked cache, so setup steps get slower even though the runners themselves are larger.

## Available Actions

### Dynamic Delivery Contract Matrix

| Action | Responsibility | Typical Trigger | Required Permissions |
|---|---|---|---|
| `release` | Semantic version decision and release publication only | Push to `main` | `contents: write`, `issues: write`, `pull-requests: write` |
| `docker/build` | Build and push release image, emit canonical image outputs | Release-published gate | `packages: write` |
| `kustomize/update-image` | Mutate overlay image reference and write back to Git | After image build output is available | `contents: write` |

Release call order for app repositories is: `release -> docker/build -> kustomize/update-image`.

### Docker Tests Action

PR-preview readiness contract for Docker consumers.

**Location:** `qtsone/actions/docker/tests@main`

**Contract highlights:**
- Uses immutable `HEAD_SHA` tag by default (no mutable `pr-<number>` default tag).
- Publishes preview images only for eligible same-repo PRs.
- Applies ready-label lifecycle safely (`ready` by default): remove at start, add only after build + push + stale-SHA guard pass, with Trivy enforced when `scan-required=true`.
- Skips preview publish and label mutation for fork PRs by default with explicit Step Summary output.
- Exposes standardized outputs: `image`, `tag`, `tags`, `digest`, `image-tag`, `image-digest`.

**Documentation:** [docker/tests/README.md](./docker/tests/README.md)

### Docker Build Action

Release image build and output handoff for downstream deployment updates.

**Location:** `qtsone/actions/docker/build@main`

**Contract highlights:**
- Pushes release images and exposes canonical outputs: `image`, `tag`, `tags`, `digest`, `image-tag`, `image-digest`.
- `tag` is the tag-only handoff for `kustomize/update-image` `tag` mode.
- `image-tag` and `image-digest` are full-reference handoffs for `kustomize/update-image` `new-ref` mode.
- Designed to chain directly into `kustomize/update-image`.

Compact handoff mapping:

| `docker/build` output | `kustomize/update-image` input |
|---|---|
| `docker/build.tag` | `kustomize/update-image.tag` |
| `docker/build.image-tag` | `kustomize/update-image.new-ref` |
| `docker/build.image-digest` | `kustomize/update-image.new-ref` |

**Documentation:** [docker/build/README.md](./docker/build/README.md)

### Release Action

A production-ready semantic-release action for automated version management.

**Location:** `qtsone/actions/release@main`

**Features:**
- Automated semantic versioning based on conventional commits
- CHANGELOG generation
- GitHub release creation
- Configurable plugins support
- Dry-run mode for testing

**Documentation:** [release/README.md](./release/README.md)

**Scope boundary:** semantic-release only; no app overlay mutation.

Downstream release flow for app repos should call `docker/build` and then `kustomize/update-image` after a release is published.

### Kustomize Update Image Action

Overlay image reference mutation and Git writeback for release deployment flow.

**Location:** `qtsone/actions/kustomize/update-image@main`

**Contract highlights:**
- Requires `contents: write` when committing changes.
- Pushes directly to `main` by default (`target-branch: main`).
- Supports `tag`, `digest`, and `new-ref` update modes.

**Documentation:** [kustomize/update-image/README.md](./kustomize/update-image/README.md)

**Usage:**
```yaml
- name: Semantic Release
  uses: qtsone/actions/release@main
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
```

## Contributing

This repository uses its own release action for automated releases. When contributing:

1. Follow [Conventional Commits](https://www.conventionalcommits.org/) specification
2. Create a feature branch from `main`
3. Submit a pull request
4. Once merged, the release workflow will automatically:
   - Analyze commits
   - Determine version bump
   - Generate CHANGELOG
   - Create GitHub release

## License

MIT
