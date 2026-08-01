# QTS Actions

Collection of reusable GitHub Actions for standardized workflows.

## Runner selection

Org repos do not hardcode a runner label. Every job resolves its runner from the
`GHA_RUNNER_TYPE` / `GHA_RUNNER_SIZE` organization custom properties, which repo
admins can change from **Settings → General → Custom properties** without editing
any workflow. Paste this verbatim as the `runs-on` of every job:

```yaml
jobs:
  build:
    runs-on: ${{ vars.GHA_RUNNER_OVERRIDE || (github.event.repository.custom_properties.GHA_RUNNER_TYPE == 'PRIVATE' && format('arc-{0}', github.event.repository.custom_properties.GHA_RUNNER_SIZE) || 'ubuntu-latest') }}
```

It is deliberately repeated rather than wrapped in a reusable workflow. `runs-on` can
only leave a repo if the whole job does, and for a job that is already one `uses:` of a
composite action here, that trades a single line for a second indirection and a
merge-order dependency. A reusable workflow earns its keep when it centralises real
multi-step logic — the `docker/build` → `kustomize/update-image` delivery chain is the
candidate — not a runner label.

Precedence, highest first:

| Source | Scope | Wins when |
|---|---|---|
| `vars.GHA_RUNNER_OVERRIDE` | org Actions variable | set to a non-empty label |
| `GHA_RUNNER_TYPE` = `PRIVATE` | repo custom property | resolves to `arc-<GHA_RUNNER_SIZE>` |
| `ubuntu-latest` | — | `GHA_RUNNER_TYPE` is `PUBLIC`, the schema default |

`GHA_RUNNER_SIZE` maps onto the scale sets defined in `qtsone/cloud-1`
(`gitops/org/projects/ci.yaml`):

| `GHA_RUNNER_SIZE` | Label | Capacity |
|---|---|---|
| `SMALL` | `arc-small` | max 6 · 1 CPU / 1Gi |
| `MEDIUM` | `arc-medium` | max 3 · 2 CPU / 4Gi |
| `LARGE` | `arc-large` | max 2 · 4 CPU / 4Gi |

### Why this works

Custom properties have no dedicated expression context, but they ride along on the
`repository` object of the webhook payload, so they are reachable as
`github.event.repository.custom_properties.*`. `runs-on` accepts the `github` and
`vars` contexts, so the whole decision resolves before scheduling — no resolver job,
no added latency, and nothing billed to make the decision.

`format('arc-{0}', 'SMALL')` yields `arc-SMALL`. Runner label matching is
case-insensitive, so that matches the `arc-small` scale set; the property values do
not need to be lower-cased.

### The override

Custom property values are per-repository — an "org-level value" is only a *default*
for repos that have not set their own, so it cannot override a repo that has. The org
Actions variable `GHA_RUNNER_OVERRIDE` is the org-scoped lever that outranks every
repo, which is what makes it the escape hatch when the ARC pool is unavailable:

```sh
gh api -X PATCH /orgs/qtsone/actions/variables/GHA_RUNNER_OVERRIDE -f value=ubuntu-latest  # force whole org onto hosted
gh api -X PATCH /orgs/qtsone/actions/variables/GHA_RUNNER_OVERRIDE -f value=''             # hand control back to each repo
```

Requires `admin:org`. It takes effect on the next workflow run; runs already queued or
in flight keep the value they started with.

### Constraints worth knowing

- **Hosted minutes are capped and private repos consume them.** One `stay-now` PR
  validation measured ~32 billable minutes on `ubuntu-latest` (`quality` 18, `image`
  12, plus two 1-minute jobs — GitHub rounds every job up to a whole minute). ARC is
  the cost-free steady state; `GHA_RUNNER_OVERRIDE` is for incidents, not for comfort.
- **Public repos cannot use ARC.** Org runner groups exclude public repositories by
  default, so a public repo set to `PRIVATE` queues forever rather than failing — an
  unmatched label queues, it does not error. Leave public repos on `PUBLIC` unless the
  runner group is explicitly opened up.
- **Size is per repository, not per job.** A repo that needs one heavy job and many
  light ones gets one size for all of them; a job that genuinely needs different
  hardware has to opt out of the shared expression and hardcode its label.
- **`GHA_RUNNER_SIZE` is ignored when the type is `PUBLIC`.** Mapping it onto GitHub's
  larger hosted runners would need those runners provisioned and named at the org first.
- The ARC image (`ghcr.io/qtsone/runner`) pre-bakes Node, Python, uv, buf and bun into
  the tool cache. On `ubuntu-latest` the `setup-*` actions re-download them, so setup
  steps get slower even though the runners themselves are larger.

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
