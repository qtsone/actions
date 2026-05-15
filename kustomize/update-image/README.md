# kustomize/update-image

Reusable composite action that updates an app-owned production kustomize overlay image reference after a release image is available.

## Permissions

- Requires `contents: write` when `commit: true` (default), because the action commits and pushes directly to `target-branch`.
- Default writeback target is direct push to `main` (`target-branch: main`).
- If branch protection blocks direct pushes, use an alternate branch/PR flow in your calling workflow.

## Concurrency Guidance

- Use per-release concurrency in caller workflows to avoid parallel writeback races, for example: `group: deploy-${{ github.ref_name }}` with `cancel-in-progress: true`.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `overlay-path` | yes | n/a | Overlay directory containing `kustomization.yaml`. |
| `image-name` | yes | n/a | Existing image name key to update. |
| `new-name` | no | `""` | Optional replacement repository/name. |
| `tag` | no* | `""` | Tag-only mode target (for example `1.2.3`). |
| `digest` | no* | `""` | Digest mode target (e.g. `sha256:...`). |
| `new-ref` | no* | `""` | Full image reference mode target (for example `ghcr.io/org/app:1.2.3` or `ghcr.io/org/app@sha256:...`). |
| `target-branch` | no | `main` | Branch to push writeback commit to. |
| `commit` | no | `true` | When `true`, commit+push changes. |
| `dry-run` | no | `false` | Validate and mutate working tree only; no commit/push. |
| `skip-install` | no | `false` | Skip bundled kustomize installer. |
| `kustomize-version` | no | `v5.4.3` | Pinned installer version. |
| `commit-message` | no | `chore(deploy): update production image [skip ci]` | Safe non-release-triggering default writeback message. |
| `commit-user-name` | no | `github-actions[bot]` | Git commit author name used when `commit: true`. |
| `commit-user-email` | no | `github-actions[bot]@users.noreply.github.com` | Git commit author email used when `commit: true`. |

`tag`, `digest`, and `new-ref` are mutually exclusive; exactly one must be provided.

## Outputs

| Output | Description |
| --- | --- |
| `changed` | `true` when `kustomization.yaml` changed. |
| `target-ref` | Resolved target image ref applied by the action. |

## Simple mode (default tag pin)

```yaml
- uses: qtsone/actions/kustomize/update-image@main
  with:
    overlay-path: gitops/services/my-app/environments/production
    image-name: ghcr.io/qtsone/my-app
    tag: 1.2.3
```

## Digest mode

```yaml
- uses: qtsone/actions/kustomize/update-image@main
  with:
    overlay-path: gitops/services/my-app/environments/production
    image-name: ghcr.io/qtsone/my-app
    digest: sha256:abcd1234...
```

## Full reference mode

```yaml
- uses: qtsone/actions/kustomize/update-image@main
  with:
    overlay-path: gitops/services/my-app/environments/production
    image-name: ghcr.io/qtsone/my-app
    new-ref: ghcr.io/qtsone/my-app@sha256:abcd1234...
```

## Dry-run and skip-install

```yaml
- uses: qtsone/actions/kustomize/update-image@main
  with:
    overlay-path: gitops/services/my-app/environments/production
    image-name: ghcr.io/qtsone/my-app
    tag: 1.2.3
    dry-run: true
    skip-install: true
```

Behavior notes:

- Always runs `kustomize build <overlay-path>` before any commit/push.
- No-op updates exit successfully and do not create commits.
- When `commit: true`, the action configures local repository commit identity from `commit-user-name`/`commit-user-email` before `git commit`.
- Push conflicts fail explicitly so callers can retry/rebase.

## Release Flow Fit

- Expected downstream position is after `qtsone/actions/release` and `qtsone/actions/docker/build`.
- `tag` input is tag-only and should receive `docker/build` output `tag` when using default tag mode.
- `new-ref` input should receive full image references such as `docker/build` output `image-tag` or `image-digest`.

| `docker/build` output | `kustomize/update-image` input |
|---|---|
| `docker/build.tag` | `kustomize/update-image.tag` |
| `docker/build.image-tag` | `kustomize/update-image.new-ref` |
| `docker/build.image-digest` | `kustomize/update-image.new-ref` |
