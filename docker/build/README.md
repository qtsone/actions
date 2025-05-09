# Docker Build and Push to GitHub Packages

A reusable and customizable GitHub Action for standardized building and pushing of Docker images to GitHub Packages.

> :warning: **Important**
> This action should be used `on.push: tags`.

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

### Example Workflow

```yaml
name: Push to GitHub Packages

on:
  push:
    tags:
      - '**'

jobs:
  build-and-push:
    runs-on: ubuntu-latest
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

## Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.
