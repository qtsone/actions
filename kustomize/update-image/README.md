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
| `extra-paths` | no | `""` | Newline-separated files to stage into the same commit as the image bump. Regular files inside the repository only; directories are rejected. See [Extra paths](#extra-paths). |
| `commit-message` | no | `chore(deploy): update production image [skip ci]` | Safe non-release-triggering default writeback message. |
| `commit-user-name` | no | `github-actions[bot]` | Git commit author name used when `commit: true`. |
| `commit-user-email` | no | `github-actions[bot]@users.noreply.github.com` | Git commit author email used when `commit: true`. |

`tag`, `digest`, and `new-ref` are mutually exclusive; exactly one must be provided.

## Outputs

| Output | Description |
| --- | --- |
| `changed` | On the commit path, `true` when a commit was created — from `kustomization.yaml`, from an `extra-paths` entry, or both. Under `dry-run: true` or `commit: false` it reports whether `kustomization.yaml` itself changed, because nothing is staged in those modes. |
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

## Extra paths

Some repositories keep a value that has to move with the image: a chart `appVersion`, a generated env file, a manifest that repeats the tag. That value and the overlay bump must reach the target branch in one commit. Two commits are two syncs, and between them a GitOps controller can observe the overlay and the file it tracks disagreeing. `extra-paths` stages files the caller already rewrote so they land in the same commit.

```yaml
- name: Render the version file
  run: printf 'APP_VERSION=1.2.3\n' > gitops/services/my-app/environments/production/version.env

- uses: qtsone/actions/kustomize/update-image@main
  with:
    overlay-path: gitops/services/my-app/environments/production
    image-name: ghcr.io/qtsone/my-app
    tag: 1.2.3
    extra-paths: |
      gitops/services/my-app/environments/production/version.env
```

Constraints, checked entry by entry before any commit or push:

- Each entry must be an existing regular file. A directory is rejected — `.` being the most plausible misreading. This action commits and pushes to `target-branch` unreviewed, so a directory entry would sweep whatever an earlier step happened to leave in the workspace into that commit.
- Each entry must resolve to a path inside the repository; anything outside it is rejected.
- Entries are resolved relative to the step's working directory, and blank lines are ignored.
- The action only stages what it is given. Writing the files is the caller's job.

A rejected entry fails the step. The overlay file has already been rewritten in the working tree at that point, but nothing has been committed or pushed.

`extra-paths` is only staged on the commit path. Under `dry-run: true` or `commit: false` the entries are neither validated nor staged, and the reported `changed` covers `kustomization.yaml` alone.

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
- Without `extra-paths`, an overlay already at the target image is a no-op: no commit, `changed=false`, exit `0`.
- With `extra-paths`, an overlay already at the target image is not by itself a no-op. If a listed file differs from `HEAD` the commit is still made, so a companion value the caller rewrote is not stranded by a redundant image bump. The staged diff is the authority: when nothing is staged at all, the run exits successfully with `changed=false` and no commit.
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
