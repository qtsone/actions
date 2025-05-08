# Docker Tests Action

A reusable and customizable GitHub Action for standardized PR checks on Docker images.

> :warning: **Important**
> This action should be used `on.pull_request`.

## Features

- Runs Hadolint for Dockerfile linting.
- Sets up Docker buildx.
- Logs in to Amazon ECR.
- Builds Docker image with caching.
- Runs Trivy vulnerability scanner on the built image.
- Prepares a comment summarizing the checks and posts it on the PR.

## Usage

### Pre-requisites

- Have a [GitHub Actions workflow](https://docs.github.com/en/actions/configuring-and-managing-workflows/configuring-a-workflow) in your repository.

### Inputs

| Name                | Description                                                                 | Default    |
|---------------------|-----------------------------------------------------------------------------|------------|
| `image-name`        | Name of the Docker image.                                                   | (required) |
| `dockerhub-username`| Dockerhub Username                                                          | (required) |
| `dockerhub-token`   | DOckerhub Token                                                             | (required) |
| `dockerfile-path`   | Path to the Dockerfile.                                                     | `Dockerfile` |
| `context`           | Directory path for Docker build files. Typically the same as Dockerfile.    | `.`        |
| `build-args`        | Additional build arguments for the Docker build command.                    | `''`       |
| `tag-prefix`        | Add a prefix to the generated Docker image tag.                             | `''`       |
| `tag-suffix`        | Add a suffix to the generated Docker image tag.                             | `''`       |
| `trivy-severity`    | Default failure severity for Trivy checks.                                  | `CRITICAL` |

### Example Workflow

```yaml
name: PR Checks

on:
  pull_request:
    paths:
      - 'build/**'

jobs:
  pr-checks:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write
    steps:
    - name: Docker Tests
      uses: qts-cloud/actions/docker/tests@main
      with:
        image-name: <dockerhub-username>/<image-name>
        # other inputs as needed
      secrets:
        DOCKERHUB_USERNAME: ${{ secrets.DOCKERHUB_USERNAME }}
        DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }}
```

### Notes

- Ensure you tag versions in your GitHub Action repository (e.g., `v1`, `v1.1`, etc.) so that you can reference specific versions in your workflows.
- This approach allows you to maintain a standardized PR check workflow across multiple repositories.

## Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.
