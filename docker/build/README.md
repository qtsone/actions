# Docker Build and Push to GitHub Packages

A reusable and customizable GitHub Action for standardized building and pushing of Docker images to GitHub Packages.

> :warning: **Important**
> Recommended release path is semantic-release gated: `release -> docker/build -> kustomize/update-image`, with build/deploy jobs guarded by `steps.release.outputs.new_release_published == 'true'`.
> Tag-push workflows can still be used as an alternative trigger model when needed.

## Features

- Sets up Docker buildx.
- Logs in to GitHub Container Registry.
- Generates Docker metadata for tagging.
- Builds and pushes Docker image to GitHub Packages with caching.
- Logs out from GitHub Container Registry.

## Usage

### Pre-requisites

- Have a [GitHub Actions workflow](https://docs.github.com/en/actions/configuring-and-managing-workflows/configuring-a-workflow) in your repository.

### Inputs

| Name                | Description                                                                 | Default    |
|---------------------|-----------------------------------------------------------------------------|------------|
| `image-name`        | Name of the Docker image.                                                   | (required) |
| `github-token`      | GitHub token for authentication                                             | (required) |
| `registry`          | GitHub Packages registry                                                    | `ghcr.io`  |
| `dockerfile-path`   | Path to the Dockerfile.                                                     | `Dockerfile` |
| `context`           | Directory path for Docker build files. Typically the same as Dockerfile.    | `.`        |
| `build-args`        | Additional build arguments for the Docker build command.                    | `''`       |
| `tag-latest`        | Add 'latest' tag to the generated Docker image.                             | `auto`     |
| `tag-prefix`        | Add a prefix to the generated Docker image tag.                             | `''`       |
| `tag-prefix-latest` | Add a prefix to the 'latest' Docker image tag.                              | `false`    |
| `tag-suffix`        | Add a suffix to the generated Docker image tag.                             | `''`       |
| `tag-suffix-latest` | Add a suffix to the 'latest' Docker image tag.                              | `false`    |

### Outputs

| Name | Description |
|------|-------------|
| `image` | Base image repository for the canonical tag (for example `ghcr.io/qtsone/app`). |
| `tag` | Canonical first tag from the normalized pushed tag list. |
| `tags` | Newline-separated normalized tag list used for the push. |
| `digest` | OCI image digest returned by `docker/build-push-action`. |
| `image-tag` | Canonical `image:tag` reference (defaults to first normalized tag). |
| `image-digest` | Canonical `image@digest` reference when digest is available. |

## Release Image Output Contract

- `image`: canonical repository (for example `ghcr.io/qtsone/app`).
- `tag`: canonical primary tag chosen from normalized tag list.
- `tags`: newline-separated normalized pushed tags.
- `digest`: OCI digest returned by `docker/build-push-action`.
- `image-tag`: canonical `image:tag` handoff for tag-based deployment mutation.
- `image-digest`: canonical `image@digest` handoff for immutable deployment mutation.

Downstream handoff contract with `qtsone/actions/kustomize/update-image@main`:

| `docker/build` output | `kustomize/update-image` input |
|---|---|
| `docker/build.tag` | `kustomize/update-image.tag` |
| `docker/build.image-tag` | `kustomize/update-image.new-ref` |
| `docker/build.image-digest` | `kustomize/update-image.new-ref` |

## Permissions and Concurrency Guidance

- Use `packages: write` to push release images to GHCR.
- Use per-release concurrency to prevent duplicate push/writeback races, for example: `group: release-${{ github.ref_name }}` with `cancel-in-progress: true`.

### Example Workflow (Release-Gated Recommended Path)

```yaml
name: Release and Build Image

on:
  push:
    branches: [main]

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      issues: write
      pull-requests: write
    outputs:
      published: ${{ steps.release.outputs.new_release_published }}
    steps:
      - uses: actions/checkout@v5
      - id: release
        uses: qtsone/actions/release@main
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}

  build-and-push:
    needs: release
    if: needs.release.outputs.published == 'true'
    runs-on: ubuntu-latest
    concurrency:
      group: release-${{ github.ref_name }}
      cancel-in-progress: true
    permissions:
      contents: read
      packages: write
    steps:
      - name: Build and Push Docker Image
        uses: qtsone/actions/docker/build@main
        with:
          image-name: <organization>/<image-name>
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

### Alternative Workflow (Tag Push Trigger)

```yaml
name: Push to GitHub Packages

on:
  push:
    tags:
      - '**'

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    concurrency:
      group: release-${{ github.ref_name }}
      cancel-in-progress: true
    permissions:
      contents: read
      packages: write
    steps:
    - name: Build and Push Docker Image
      uses: qtsone/actions/docker/build@main
      with:
        image-name: <organization>/<image-name>
        # other inputs as needed
        github-token: ${{ secrets.GITHUB_TOKEN }}
```

### Notes

- Ensure you tag versions in your GitHub Action repository (e.g., `v1`, `v1.1`, etc.) so that you can reference specific versions in your workflows.
- This approach allows you to maintain a standardized build and push workflow across multiple repositories.

### Release Flow Output Handoff

Use `tag` for `kustomize/update-image` tag-only mode, and use `image-tag`/`image-digest` for full-reference mode:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      release_tag: ${{ steps.build.outputs.tag }}
      release_image: ${{ steps.build.outputs.image-tag }}
      release_image_digest: ${{ steps.build.outputs.image-digest }}
    steps:
      - uses: actions/checkout@v5
      - id: build
        uses: qtsone/actions/docker/build@main
        with:
          image-name: qtsone/app
          github-token: ${{ secrets.GITHUB_TOKEN }}

  deploy:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - name: Use tag mode (default)
        run: |
          echo "tag=${{ needs.build.outputs.release_tag }}"

      - name: Use full-reference mode (image:tag)
        run: |
          echo "image=${{ needs.build.outputs.release_image }}"

      - name: Use full-reference mode (image@digest, immutable)
        if: ${{ needs.build.outputs.release_image_digest != '' }}
        run: |
          echo "image=${{ needs.build.outputs.release_image_digest }}"
```

## Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.
