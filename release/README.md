# Custom Semantic Release GitHub Action

A production-ready, maintainable GitHub Actions composite action for semantic-release that provides full control over automated version management and release processes.

## Features

✅ **Automated Version Management** - Supports version updates across multiple files via custom plugins
✅ **Flexible Plugin System** - Easy configuration of semantic-release plugins
✅ **Full Transparency** - Clear logging and debug output
✅ **Proper Output Handling** - Reliable capture of release status and version
✅ **Package.json Handling** - Works with or without existing package.json
✅ **Dry-Run Support** - Test releases without publishing
✅ **Comprehensive Error Handling** - Clear error messages and exit codes

## Why This Action?

This action solves common issues with third-party semantic-release actions:

- ❌ **Module Resolution Issues** - Third-party actions often have plugin path problems
- ❌ **Complex Install Failures** - Hidden errors in npm install steps
- ❌ **Lack of Transparency** - Hard to debug what's actually happening
- ❌ **Poor Output Capture** - Unreliable status and version outputs

Our solution provides:

- ✅ Direct semantic-release execution from your repo context
- ✅ Clear, readable bash scripts with comprehensive logging
- ✅ Proper multi-line input handling
- ✅ Reliable output parsing and GitHub Actions output setting
- ✅ Full control and easy customization

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `github-token` | GitHub Token (GITHUB_TOKEN or PAT) | Yes | - |
| `ssh-key` | SSH key for checkout (optional) | No | - |
| `node-version` | Node.js version | No | `20` |
| `semantic-version` | semantic-release version | No | `21.1.1` |
| `debug` | Enable debug mode | No | `true` |
| `dry-run` | Run in dry-run mode (no publish) | No | `false` |
| `tag-prefix` | Tag prefix (e.g., "v" for v1.0.0) | No | `v` |
| `tag-suffix` | Tag suffix | No | `` |
| `extra-plugins` | Additional semantic-release plugins (one per line) | No | `@semantic-release/changelog` `@semantic-release/git` |

## Outputs

| Output | Description | Example |
|--------|-------------|---------|
| `new_release_published` | Whether a new release was published | `"true"` or `"false"` |
| `new_release_version` | Version of the new release | `"1.3.0"` |

## Usage Examples

### Basic Usage (Default Plugins)

Uses default plugins: `@semantic-release/changelog` and `@semantic-release/git`

```yaml
name: Release
on:
  push:
    branches: [main]

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: write       # to be able to publish a GitHub release
      issues: write         # to be able to comment on released issues
      pull-requests: write  # to be able to comment on released pull requests
    steps:
      - name: Semantic Release
        uses: qtsone/actions/release@main
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          ssh-key: ${{ secrets.DEPLOY_KEY }}
```

### Advanced Usage (Custom Plugins)

Add custom plugins like `@semantic-release/exec` for version automation:

```yaml
name: Release
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
    steps:
      - name: Semantic Release
        id: release
        uses: qtsone/actions/release@main
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          ssh-key: ${{ secrets.DEPLOY_KEY }}
          extra-plugins: |
            @semantic-release/changelog
            @semantic-release/git
            @semantic-release/exec

      - name: Use Release Outputs
        if: steps.release.outputs.new_release_published == 'true'
        run: |
          echo "New version released: ${{ steps.release.outputs.new_release_version }}"
```

### Dry-Run Mode (Testing)

Test the release process without actually publishing:

```yaml
- name: Semantic Release (Dry Run)
  uses: qtsone/actions/release@main
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    dry-run: 'true'
```

### With Custom Node Version

```yaml
- name: Semantic Release
  uses: qtsone/actions/release@main
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    node-version: '18'
    semantic-version: '20.0.0'
```

## Configuration

### Repository .releaserc Configuration

Create a `.releaserc` or `.releaserc.json` in your repository root:

```json
{
  "branches": ["main"],
  "plugins": [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    [
      "@semantic-release/changelog",
      {
        "changelogFile": "CHANGELOG.md"
      }
    ],
    [
      "@semantic-release/exec",
      {
        "prepareCmd": "node scripts/update-versions.js ${nextRelease.version}"
      }
    ],
    [
      "@semantic-release/git",
      {
        "assets": [
          "CHANGELOG.md",
          ".claude-plugin/marketplace.json",
          "plugins/*/.claude-plugin/plugin.json"
        ],
        "message": "chore(release): version ${nextRelease.version}\n\n${nextRelease.notes}"
      }
    ],
    "@semantic-release/github"
  ]
}
```

### Example Version Update Script

Create `scripts/update-versions.js` for automated version updates:

```javascript
#!/usr/bin/env node
const fs = require("fs");
const path = require("path");

const newVersion = process.argv[2];

function updateVersion(filePath) {
  const content = fs.readFileSync(filePath, "utf8");
  const json = JSON.parse(content);
  json.version = newVersion;
  fs.writeFileSync(filePath, JSON.stringify(json, null, 2) + "\n", "utf8");
  console.log(`✓ ${path.relative(process.cwd(), filePath)}: → ${newVersion}`);
}

// Update marketplace.json
const marketplaceFile = path.join(process.cwd(), ".claude-plugin", "marketplace.json");
if (fs.existsSync(marketplaceFile)) {
  updateVersion(marketplaceFile);
}

// Update all plugin.json files
const pluginsDir = path.join(process.cwd(), "plugins");
if (fs.existsSync(pluginsDir)) {
  const glob = require("glob");
  glob.sync("plugins/*/.claude-plugin/plugin.json").forEach(updateVersion);
}

console.log(`\n✅ Version update complete: ${newVersion}\n`);
```

## Setting up Deploy Key and Secret

To trigger additional workflows from the tag, you need to set up a deploy key and a corresponding secret:

1. **Generate a new SSH key pair:**

   ```sh
   ssh-keygen -t ed25519 -f id_ed25519 -N "" -q -C ""
   ```

2. Go to your GitHub repository's settings.

3. Navigate to the **Deploy keys** section and click **Add deploy key**. Provide a title, paste the public key (`id_ed25519.pub` content), and ensure **Allow write access** is checked. Then, click **Add key**.

4. Navigate to the **Secrets** section and click **New repository secret**. Name the secret (e.g., `DEPLOY_KEY`) and paste the private key (`id_ed25519` content) as the value.

5. Ensure the `ssh-key` input uses the correct secret name in your workflow.

## How It Works

### 1. Multi-line Input Handling

The action properly handles multi-line `extra-plugins` input by converting newlines to spaces:

```bash
PLUGINS_INPUT="${{ inputs.extra-plugins }}"
PLUGINS_LIST=$(echo "$PLUGINS_INPUT" | tr '\n' ' ' | xargs)
```

### 2. Package.json Management

The action handles repositories with or without package.json:

- **If package.json exists:** Uses it and installs plugins with `--no-save`
- **If package.json missing:** Creates temporary one, installs plugins, then removes it

### 3. Output Parsing

The action captures semantic-release output and parses it for:

- Release publication status
- Version number
- Dry-run mode results

Patterns matched:

- `"Published release X.Y.Z"` → Published
- `"There are no relevant changes"` → No release
- `"The next release version is X.Y.Z"` → Dry-run determination

### 4. Environment Setup

Proper environment variables for semantic-release:

```yaml
env:
  GITHUB_TOKEN: ${{ inputs.github-token }}
  GIT_AUTHOR_NAME: ${{ github.actor }}
  GIT_AUTHOR_EMAIL: ${{ github.actor }}@users.noreply.github.com
  GIT_COMMITTER_NAME: ${{ github.actor }}
  GIT_COMMITTER_EMAIL: ${{ github.actor }}@users.noreply.github.com
```

## Troubleshooting

### Debug Mode

Enable debug output to see detailed semantic-release logs:

```yaml
- uses: qtsone/actions/release@main
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    debug: 'true'
```

### Common Issues

#### Issue: "No package.json found"

- Solution: This is expected and handled automatically. The action creates a temporary one.

#### Issue: "Plugin not found"

- Solution: Check plugin name spelling in `extra-plugins` input.
- Ensure plugin is compatible with your semantic-release version.

#### Issue: "No release created"

- Solution: Check commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
- Use dry-run mode to test: `dry-run: 'true'`

#### Issue: "Permission denied"

- Solution: Ensure GITHUB_TOKEN has write permissions
- For protected branches, use a PAT with appropriate permissions or configure deploy key

### Testing

Test the action with dry-run before using in production:

```yaml
- name: Test Release (Dry Run)
  uses: qtsone/actions/release@feat/auto-version-updates
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    dry-run: 'true'
    debug: 'true'
```

## Best Practices

1. **Use SSH Key for Protected Branches:** If your main branch is protected, use an SSH deploy key
2. **Test with Dry-Run First:** Always test with `dry-run: 'true'` on feature branches
3. **Follow Conventional Commits:** Ensure all commits follow the [Conventional Commits](https://www.conventionalcommits.org/) format
4. **Configure .releaserc:** Keep your semantic-release configuration in `.releaserc` for clarity
5. **Version Update Scripts:** Use `@semantic-release/exec` for custom version update logic
6. **Monitor Outputs:** Use the `new_release_published` output for conditional steps
7. **Set Proper Permissions:** Ensure your workflow has necessary permissions (contents: write, etc.)

## Success Criteria

- ✅ Action installs semantic-release and plugins correctly
- ✅ semantic-release runs and analyzes commits
- ✅ Version is determined correctly (feat → minor, fix → patch)
- ✅ CHANGELOG.md is generated
- ✅ Custom scripts executed via @semantic-release/exec
- ✅ Version numbers updated in all target files
- ✅ Changes committed to git
- ✅ Git tag created (e.g., v1.2.0)
- ✅ GitHub release created
- ✅ Outputs properly set (new_release_published, new_release_version)
- ✅ Dry-run mode works for testing
- ✅ Clear error messages on failure
- ✅ Works for both default and custom plugin configurations

## Contributing

Issues and pull requests are welcome! Please ensure any changes maintain backward compatibility.

## License

MIT - See repository license file.
