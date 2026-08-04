# QTS Actions

Collection of reusable GitHub Actions for standardized workflows.

## Available Actions

### Dynamic Delivery Contract Matrix

| Action | Responsibility | Typical Trigger | Required Permissions |
|---|---|---|---|
| `release` | Semantic version decision and release publication only | Push to `main` | `contents: write`, `issues: write`, `pull-requests: write` |
| `git/content-id` | Hash tracked git content to a short id used to ask "already built this?" | Optional, before the image step | None beyond `contents: read`; reads the git object database, so `actions/checkout` must not be shallow in a way that hides the ref being hashed |
| `docker/promote` | Republish an image the registry already holds under release tags, no rebuild | Optional, on a content-id hit | `packages: write` (the job must also log in to the registry) |
| `docker/build` | Build and push release image, emit canonical image outputs | Release-published gate, or a content-id miss | `packages: write` |
| `kustomize/update-image` | Mutate overlay image reference and write back to Git | After image build output is available | `contents: write` |

Release call order for app repositories is: `release -> docker/build -> kustomize/update-image`.

Content-addressed promotion is an optional path inside that order. When the tracked content that reaches the image has not moved since a build that already ran (a PR build, typically), the release can republish that image instead of rebuilding it:

`release -> git/content-id -> (docker/promote on a hit | docker/build on a miss) -> kustomize/update-image`

`docker/promote` reports `promoted=false` and exits `0` when the content tag is absent from the registry, so the caller gates `docker/build` on `steps.<promote>.outputs.promoted != 'true'`. Any other registry error is a hard failure, not a fallback. Both branches hand `kustomize/update-image` the same reference shapes.

### Docker Tests Action

PR-preview readiness contract for Docker consumers.

**Location:** `qtsone/actions/docker/tests@main`

**Contract highlights:**
- Uses immutable `HEAD_SHA` tag by default (no mutable `pr-<number>` default tag).
- Publishes preview images only for eligible same-repo PRs.
- Applies ready-label lifecycle safely (`ready` by default): remove at start, add only after build + push + stale-SHA guard pass, with Trivy enforced when `scan-required=true`.
- Skips preview publish and label mutation for fork PRs by default with explicit Step Summary output.
- Optional `content-tag` (empty by default, which keeps the previous behaviour): re-tags an already-built image to the PR head on a registry hit, and publishes the content tag from a fresh build only after Trivy and the stale-head guard pass, so a release never promotes an image that failed a required scan.
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

### Docker Promote Action

Registry-side republication of an image that was already built, under a new set of tags.

**Location:** `qtsone/actions/docker/promote@main`

**Contract highlights:**
- Copies the manifest with `docker buildx imagetools create`: no layer is transferred and no build runs.
- Source is named by `content-tag` (for example `src-<id>` from `git/content-id`); `tags` takes full references, and bare values are prefixed with the image.
- A source that is absent from the registry reports `promoted=false` and exits `0` so the caller can build instead; auth, rate-limit, network and 5xx errors are hard failures rather than a silent full rebuild.
- A promoted image keeps the labels it was built with, so use `annotations` (for example `index:org.opencontainers.image.version=1.2.3`) to record what the image is now.
- `digest` is read back from the first published tag, not the source, because annotating or wrapping a single-platform source produces a new index.
- Performs no registry login of its own: the calling job must authenticate first (for example `docker/login-action@v3`).

**Documentation:** [docker/promote/README.md](./docker/promote/README.md)

### Git Content Id Action

Content id for the tracked paths that can reach a build artifact, for content-addressed republishing.

**Location:** `qtsone/actions/git/content-id@main`

**Contract highlights:**
- Hashes mode, blob id and path from the git object database (never the working tree) into a 16-character `id`, so a PR checkout and a tag checkout of the same content produce the same id.
- Select paths with `exclude` or `include` (mutually exclusive), or keep the lists in a JSON config keyed by `target` (default `.github/image-content.json`).
- Prefer `exclude`: a newly added path is then covered by default, and a wrong list only costs a needless rebuild.
- The id covers tracked git content and nothing else. Build args, floating base image tags and toolchain versions must be folded in via `extra`, or a hit republishes an image that no longer matches.
- Fails loudly instead of degrading: an `include` path matching no tracked entry, and an empty selection, are errors.
- Needs no permissions beyond a checkout that contains the ref being hashed; feeds `content-tag` on `docker/tests` and `docker/promote`.

**Documentation:** [git/content-id/README.md](./git/content-id/README.md)

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

Downstream release flow for app repos should call `docker/build` and then `kustomize/update-image` after a release is published, optionally with `git/content-id` and `docker/promote` in front of the build to skip it when the content is unchanged.

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
