# Semantic Release Action

A reusable and customizable GitHub Action for standardized release workflows using semantic release.

## Features

- Checks out the codebase.
- Sets up Node.js environment.
- Executes semantic release with a set of standard plugins.

## Usage

### Pre-requisites

- Have a [GitHub Actions workflow](https://docs.github.com/en/actions/configuring-and-managing-workflows/configuring-a-workflow) in your repository.
- In case you release from the protected branch. Uncheck these boxes from the branch protection config:
  - Require status checks to pass before merging
  - Require signed commits
  - Do not allow bypassing the above settings
- Place `.releaserc.json` in the root of repository and copy this config to it.
```
{
    "branches": ["main"], # Replace with your release branch
    "plugins": [
        "@semantic-release/commit-analyzer",
        "@semantic-release/release-notes-generator",
        "@semantic-release/github",
        "@semantic-release/changelog",
        "@semantic-release/git"
      ]
}
```
### Setting up Deploy Key and Secret

To trigger additional workflows from the tag, you need to set up a deploy key and a corresponding secret:

1. Generate a new SSH key pair:

   ```sh
   ssh-keygen -t ed25519 -f id_ed25519 -N "" -q -C ""
   ```

2. Go to your GitHub repository's settings.

3. Navigate to the "Deploy keys" section and click on "Add deploy key". Provide a title, paste the public key (`id_ed25519.pub` content), and ensure "Allow write access" is checked. Then, click "Add key".

4. Navigate to the "Secrets" section and click on "New repository secret". Name the secret (e.g., `DEPLOY_KEY`) and paste the private key (`id_ed25519` content) as the value.
5. Ensure the `ssh-key` input uses the correct secret name.

### Inputs

| Name             | Description                                               | Default      | Required |
|------------------|-----------------------------------------------------------|--------------|----------|
| `github-token`   | Either the default GITHUB_TOKEN or a PAT can be used.     | -            | Yes      |
| `ssh-key`        | SSH key for checkout. If provided, it will be used for checkout; otherwise, the default GITHUB_TOKEN will be used. | - | No |
| `node-version`   | Node version for setup.                                   | `20`         | No       |
| `semantic-version` | Semantic version for release.                           | `21.1.1`     | No       |
| `debug`          | Debug flag for semantic release (optional).               | -            | No       |
| `dry-run`        | Whether to run semantic release in dry-run mode (optional). | `false`            | No       |

### Example Workflow

```yaml
name: Release

on:
  push:
    branches:
      - main
    paths:
      - 'build/**'

jobs:
  release:
    runs-on: [self-hosted, global-pool]
    permissions:
      contents: write       # to be able to publish a GitHub release
      issues: write         # to be able to comment on released issues
      pull-requests: write  # to be able to comment on released pull requests
    steps:
      - name: Semantic Release
        uses: qts-cloud/actions/release@main
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          ssh-key: ${{ secrets.DEPLOY_KEY }}
```

### Notes

- If you provide a deploy key(`ssh-key`), it will be used for the checkout process. If not, the default `GITHUB_TOKEN` will be used.
- Ensure you tag versions in your GitHub Action repository (e.g., `v1`, `v1.1`, etc.) so that you can reference specific versions in your workflows.
- This approach allows you to maintain a standardized release workflow across multiple repositories.

## Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.
