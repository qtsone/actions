# QTS Actions

Collection of reusable GitHub Actions for standardized workflows.

## Available Actions

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
