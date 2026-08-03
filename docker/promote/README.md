# Docker Promote Action

Republishes an image the registry already holds under a new set of tags, using a registry-side manifest copy (`docker buildx imagetools create`).

## What it does

- Probes `<registry>/<image-name>:<content-tag>` and republishes it under every tag in `tags`.
- Reports a missing source as `promoted=false` and exits `0`, so the caller can fall back to a build.
- Fails hard on any other registry error (401, 429, 5xx, network), rather than reporting it as "never built".
- Applies OCI `annotations` to the created index, which is how a promoted image records what it now is.
- Emits the manifest digest of the first created tag, and a Step Summary line on a hit.

## What it does not do

- **No layers move.** Nothing is pulled, built, or pushed as content; only manifests are written. The source and the new tags share the same blobs in the same registry, so this does not copy an image between registries.
- **No login.** There is no token input; see [Registry login](#registry-login).
- **No buildx install.** `docker buildx` must already be on the runner (preinstalled on GitHub-hosted runners; add `docker/setup-buildx-action@v3` on runners where it is not).
- **No verification of the source.** It copies whatever the source tag points at right now; see [Trust model](#trust-model).

## Inputs

| Name | Description | Default |
|---|---|---|
| `image-name` | Image name without registry (`owner/repo`) | required |
| `content-tag` | Tag naming the content to republish, for example `src-<id>` from `git/content-id` | required |
| `tags` | Newline-separated tags to publish. Bare values are prefixed with the image | required |
| `annotations` | Newline-separated OCI annotations, for example `index:org.opencontainers.image.version=1.2.3` | `''` |
| `registry` | Container registry hostname | `ghcr.io` |

## Outputs

| Name | Description |
|---|---|
| `promoted` | `true` when the content was found and republished; `false` on a miss |
| `digest` | Manifest digest of the **first** published tag, empty on a miss |

## Registry login

The action takes no token and performs no login. Run `docker/login-action@v3` (or an equivalent) in the same job first.

Without credentials the source probe returns 401, which is **not** a miss: the step fails. That is deliberate — treating an auth failure as "never built" would hide broken credentials behind a silent full rebuild on every run.

## Miss vs. error

| Source state | `promoted` | `digest` | Step result |
|---|---|---|---|
| Present | `true` | digest of first created tag | success |
| Absent (`not found`, `NAME_UNKNOWN`, `MANIFEST_UNKNOWN`, `manifest unknown`, `no such manifest`) | `false` | empty | success, exit `0` |
| Any other registry failure (401, 429, 5xx, network) | unset | unset | failure, exit `1` |
| `tags` empty or blank-only | unset | unset | failure, exit `1` |

No tag is created on a miss. Callers branch on `steps.<id>.outputs.promoted != 'true'` to build instead.

If a registry error should also fall through to a build rather than fail the job, the caller must opt in with `continue-on-error: true` on the promote step — `promoted` is then unset, which the same `!= 'true'` check already covers. `docker/tests` does exactly this for its `content-tag` fallback.

## Tag handling

Each non-empty line of `tags` is a tag to create:

- A bare value is prefixed with `<registry>/<image-name>`, so `1.2.3` becomes `ghcr.io/owner/repo:1.2.3`.
- A value containing `:` is treated as a full reference and passed through unchanged, so it can target a different repository in the same registry.

This differs from `docker/build`'s `extra-tags`, which requires full references and never prefixes.

## Digest output

`digest` is read back from the first created tag, not from the source, and the two are frequently different:

- Annotating rewrites the index.
- A single-platform source is wrapped into an index by `imagetools create`.

The new tags are what a deployment pins, so the new digest is the one to hand downstream.

| `docker/promote` output | `kustomize/update-image` input |
|---|---|
| `docker/promote.digest` | `kustomize/update-image.digest` |

## Trust model

The source tag is **mutable**. Anyone with `packages:write` on the package can overwrite it, and the action copies whatever it resolves to at that moment — there is no signature check, no provenance check, and no comparison against the current checkout. Only point `content-tag` at a tag whose write access and meaning you control.

Two consequences worth stating plainly:

- A content-id hit means the *tracked git content* matched when the tag was published. It does not mean the bytes are identical: build-args, floating base images, and toolchain versions do not reach the id unless the caller folded them in via `git/content-id`'s `extra` input.
- Whoever can publish the source tag can decide what a later release ships. `docker/tests` publishes its content tag only for eligible same-repo PRs, and only after Trivy and the stale-head guard pass, so a fork PR or a failed required scan never becomes a promotion source.

A promoted image also keeps the labels it was built with — a release promoted from a PR build carries that PR's version label. `annotations` is the way to record the new identity without rebuilding a layer; it does not rewrite labels.

## Permissions and Concurrency Guidance

- Use `packages: write` — the copy both reads the source manifest and writes new tags.
- Promoting to a mutable tag (`latest`, a floating major) from parallel jobs races, and the last writer wins. Use per-release concurrency, for example: `group: release-${{ github.ref_name }}` with `cancel-in-progress: true`.

## Example (promote a content tag to a release)

Promotes the image already built for this content to a semver tag with an OCI version annotation, and builds only when the content was never built.

```yaml
jobs:
  release-image:
    runs-on: ubuntu-latest
    concurrency:
      group: release-${{ github.ref_name }}
      cancel-in-progress: true
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v5

      - name: Compute content id
        id: content
        uses: qtsone/actions/git/content-id@main
        with:
          exclude: |
            docs
            README.md

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Promote already-built content
        id: promote
        uses: qtsone/actions/docker/promote@main
        with:
          image-name: qtsone/my-service
          content-tag: src-${{ steps.content.outputs.id }}
          tags: |
            1.2.3
            latest
          annotations: |
            index:org.opencontainers.image.version=1.2.3

      - name: Build when the content was never built
        if: ${{ steps.promote.outputs.promoted != 'true' }}
        uses: qtsone/actions/docker/build@main
        with:
          image-name: qtsone/my-service
          github-token: ${{ secrets.GITHUB_TOKEN }}
          checkout: false
          extra-tags: ghcr.io/qtsone/my-service:src-${{ steps.content.outputs.id }}
```

The build fallback publishes the content tag itself (as a full reference, per `extra-tags`), so the next release of the same content promotes instead of rebuilding.

## Release Flow Fit

- Sits in front of `docker/build` in the release path: promote first, build only on a miss.
- Pair with `git/content-id` so the source tag names content rather than a commit; a commit-named tag misses on every no-op change.
- Hand `digest` to `kustomize/update-image` in `digest` mode for an immutable deployment pin.
