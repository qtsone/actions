# git/content-id

Reusable composite action that digests the tracked git content able to reach a build artifact, so a later workflow can ask "has this exact content already been built?" and republish instead of rebuilding.

> :warning: **Important**
> The id covers tracked git content and nothing else. Build args, a floating base image tag, and files generated during the build are invisible to it, and a cache hit on a moved input republishes an image that no longer matches. Read [Limits](#limits) before wiring this to a promotion path.

## What it does

- Reads `mode + blob id + path` for the selected tracked entries at `ref` and digests them to a 16-character id.
- Reads from the object database, never the working tree, so the id is identical between a PR checkout and a tag checkout of the same content.
- Selects paths by `exclude` (everything tracked counts unless listed) or `include` (only what is listed), never both.
- Fails loudly on the misconfigurations that would silently widen or narrow the id, rather than emitting a digest the caller cannot trust.
- Folds arbitrary caller-supplied strings into the digest through `extra`, for the inputs git cannot see.
- Optionally reads the path lists from a JSON config file, so the PR workflow and the release workflow cannot drift apart.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `include` | no* | `""` | Newline-separated paths to hash. Git pathspecs, resolved one at a time. An entry matching no tracked path is an error. |
| `exclude` | no* | `""` | Newline-separated paths to skip; everything else tracked is hashed. Matched as whole path components, literally. |
| `extra` | no | `""` | Newline-separated arbitrary strings folded into the digest. |
| `target` | no | `""` | Key to read `include`/`exclude`/`extra` from the config file. |
| `config` | no | `.github/image-content.json` | JSON file the `target` key is read from. Only consulted when `target` is set. |
| `ref` | no | `HEAD` | Git ref to read the tree from. Must exist locally. |

`include` and `exclude` are mutually exclusive; supplying both is an error. Supplying neither hashes every tracked path at `ref`.

## Outputs

| Output | Description |
| --- | --- |
| `id` | 16-character digest of the selected tracked content. |

## What the id is computed from

For each selected entry in `git ls-tree -r <ref>`: the octal file mode, the object id, and the path. Those lines are sorted, `extra` entries are appended (each prefixed `extra ` and sorted independently), and the result is `sha256sum`'d and truncated to the first 16 hex characters.

Consequences worth knowing before you trust it:

- **Commit metadata is not in it.** Author, date, message, ref name, and commit id do not move the id. Two commits with the same tree produce the same id, which is the entire point: a release commit that only touches an excluded changelog reuses the PR's artifact.
- **File modes are in it.** A `chmod +x` leaves every blob id untouched but moves the tree entry's mode, so it moves the id. Without that, a commit that only makes an entrypoint executable would hit the cache and republish an image where it is not.
- **The working tree is not read.** Untracked and gitignored files are invisible, as is any local modification that has not been committed.
- **Submodules contribute their gitlink only.** The tree records the pinned commit id, so bumping a submodule moves the id; the files inside the submodule are never enumerated, so anything that changes what that pin resolves to on the runner does not.
- **The id is stable across runners.** `LC_ALL=C` and `core.quotePath=true` are pinned inside the action so a runner's locale or global git config cannot reach the digest.
- **16 hex characters is a truncated sha256.** Sized to be tag-friendly and collision-free in practice across one repository's history, not to resist a deliberately crafted collision.

## Choosing paths: exclude is the safer default

The direction that causes harm is a path that reaches the artifact without being hashed, because that republishes stale bytes under a new release tag. `exclude` fails in the harmless direction:

- With `exclude`, a newly added path is covered automatically and a wrong list only costs a needless rebuild.
- With `include`, a path you forgot to list is silently omitted from the id forever, and every later change to it promotes stale content.

Reach for `include` only when a denylist would make unrelated changes invalidate an artifact that contains none of them — a monorepo where one service's image must not be rebuilt because a sibling service changed.

Matching rules:

- `exclude` matches **whole path components**, compared as literal prefixes. `docs` drops `docs` and everything under `docs/`, but not `docker/`. A trailing slash is ignored, so `docs/` and `docs` are the same entry.
- `exclude` is **not a regex and not a glob**. `docs/*.md` matches nothing; a path containing regex metacharacters such as `weird(dir)` or `a+b` is excluded exactly as written.
- An `exclude` entry that matches nothing is **not** an error — `doc` simply leaves the id unchanged, with no warning. The action logs the id and nothing else, so verify a list by computing the id with and without an entry (see [Running it locally](#running-it-locally)): if it does not move, the entry matched nothing.
- `include` entries are git pathspecs, resolved one per line. An entry matching no tracked entry at `ref` is a **hard error**. Order does not affect the id, and overlapping entries do not double-count.
- Non-ASCII paths appear in the listing C-quoted and wrapped in double quotes (a consequence of pinning `core.quotePath`, which keeps the id off a runner's git config). An `exclude` entry cannot practically address one: the literal `café` does not match `"caf\303\251/f.txt"`. Use `include` for those paths — entries there are pathspecs and take the path as written.

## Failure modes

| Condition | Behaviour |
| --- | --- |
| `include` entry matches no tracked path at `ref` | fails: `include path matched no tracked entry` |
| `include` set but whitespace-only | fails: `include is set but lists no paths` |
| `exclude` set but whitespace-only | ignored; hashes the whole tree |
| `include` and `exclude` both non-empty | fails: `give include or exclude, not both` |
| Selection resolves to no entries at all | fails: `refusing to emit the digest of an empty set` |
| `target` set and `config` empty or missing on disk | fails |
| `target` is not a key in `config` | fails |
| `target` declares `"include": []` | fails: an empty include list is rejected rather than falling through to "hash everything" |

A whitespace-only `include` is fatal while a whitespace-only `exclude` is not, for the same reason `exclude` is the safer default: an expression that renders to nothing would turn a narrow allowlist into "everything" without a word, whereas the same slip on a denylist only costs a rebuild.

## Config file

The id only saves work if every workflow that computes it computes the *same* one. Once more than one workflow needs it, put the lists in a file instead of duplicating them.

`.github/image-content.json`:

```json
{
  "api": {
    "exclude": [
      "docs",
      "CHANGELOG.md",
      ".github"
    ],
    "extra": [
      "NODE_ENV=production"
    ]
  },
  "worker": {
    "include": [
      "services/worker",
      "libs/common",
      "Dockerfile.worker"
    ]
  }
}
```

```yaml
- uses: actions/checkout@v5
- name: Content id
  id: content
  uses: qtsone/actions/git/content-id@main
  with:
    target: api
```

`config` defaults to `.github/image-content.json`; pass it explicitly for any other location. When `target` is set the config file is the only source of paths — `exclude` and `extra` passed alongside it are discarded silently, and `include` passed alongside a target that declares no include fails with `include is set but lists no paths`. Use one form or the other, not both.

## Limits

The id is a digest of tracked git content. Everything below changes the image a build would produce **without** moving the id, so a hit republishes an image that no longer matches:

| Invisible to the id | Why |
| --- | --- |
| Build args | Passed at build time; nothing in the tree records them. |
| A floating base image (`FROM node:20`) | The Dockerfile bytes are unchanged when the upstream tag is repointed. |
| Anything resolved from the network during the build | `apt-get install`, `npm install` against a floating range, a downloaded toolchain. |
| Files generated during the build | Codegen output, a lockfile the build writes, vendored dependencies fetched at build time. |
| Files inside a submodule | Only the pinned commit id is hashed, not the tree it names. |
| Untracked or gitignored files | Not present in the tree object. |
| The build definition itself | The action or reusable workflow doing the build lives in another repository, and a floating `@main` moves under you. Excluding `.github` drops your own workflow file too. |

A related consequence of time: a hit republishes bytes built at some earlier point, so whatever the build resolved from the network back then is frozen into the promoted image. Pin what must not drift, and fold the rest into `extra`.

`extra` is the escape hatch. Resolve the moving input to a stable string in the caller and pass it in — then a change to it moves the id and forces a rebuild:

```yaml
- uses: actions/checkout@v5

- name: Resolve base image digest
  id: base
  run: |
    digest="$(docker buildx imagetools inspect node:20-alpine --format '{{.Manifest.Digest}}')"
    echo "digest=${digest}" >> "$GITHUB_OUTPUT"

- name: Content id
  id: content
  uses: qtsone/actions/git/content-id@main
  with:
    exclude: |
      docs
      CHANGELOG.md
    extra: |
      base=node:20-alpine@${{ steps.base.outputs.digest }}
      BUILD_MODE=production

- name: Preview readiness
  uses: qtsone/actions/docker/tests@main
  with:
    image-name: qtsone/my-service
    github-token: ${{ secrets.GITHUB_TOKEN }}
    content-tag: src-${{ steps.content.outputs.id }}
    build-args: |
      BUILD_MODE=production
```

Note that `BUILD_MODE` appears twice: once as the build arg that reaches the build, once in `extra` so it reaches the id. Nothing enforces that pairing — a build arg you forget to mirror into `extra` is exactly the failure this section is about.

## Wiring it to a promotion path

The id is not a tag by itself. Prefix it (`src-` by convention here) and hand the resulting tag to `docker/tests`, `docker/build`, or `docker/promote`.

PR side — `docker/tests` re-tags an existing image instead of rebuilding, and publishes the content tag itself once its scan and stale-head checks pass:

```yaml
jobs:
  preview:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
      issues: write
      packages: write
    steps:
      - uses: actions/checkout@v5
      - id: content
        uses: qtsone/actions/git/content-id@main
        with:
          target: api
      - uses: qtsone/actions/docker/tests@main
        with:
          image-name: qtsone/my-service
          github-token: ${{ secrets.GITHUB_TOKEN }}
          content-tag: src-${{ steps.content.outputs.id }}
```

Release side — try the registry-side copy first, and build only on a miss. `docker/promote` prefixes bare values in `tags` with the image; `docker/build`'s `extra-tags` takes full references:

```yaml
jobs:
  release-image:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v5
      - id: content
        uses: qtsone/actions/git/content-id@main
        with:
          target: api
      - id: promote
        uses: qtsone/actions/docker/promote@main
        with:
          image-name: qtsone/my-service
          content-tag: src-${{ steps.content.outputs.id }}
          tags: |
            1.2.3
            latest
      - if: ${{ steps.promote.outputs.promoted != 'true' }}
        uses: qtsone/actions/docker/build@main
        with:
          image-name: qtsone/my-service
          github-token: ${{ secrets.GITHUB_TOKEN }}
          extra-tags: ghcr.io/qtsone/my-service:src-${{ steps.content.outputs.id }}
```

Both jobs use `target: api`, which is the point of the config file: the release commit's id has to match the PR's or nothing is ever promoted. Excluding `CHANGELOG.md` is usually what makes that true, since a semantic-release commit touches little else.

## Requirements

- A checkout. `actions/checkout` at its default `fetch-depth: 1` is enough for `ref: HEAD`; any other `ref` — `HEAD~1`, a tag — has to be present locally, which a depth-1 clone will not have.
- `git`, `bash`, and GNU coreutils `sha256sum` — GitHub-hosted Linux runners have all three. macOS runners ship `shasum`, not `sha256sum`, so the action does not run there.
- `jq`, only when `target` is set.
- Permissions: `contents: read`. The action reads the local repository and makes no network calls.

## Running it locally

The script is callable outside Actions, which is how its behaviour tests in `tests/scripts/test_content_id.sh` drive it. Inputs come from the uppercased env vars (`INCLUDE`, `EXCLUDE`, `EXTRA`, `TARGET`, `CONFIG`, `REF`). With `GITHUB_OUTPUT` unset it writes `id=<digest>` to stdout, and always logs `content id (<ref>): <digest>` to stderr:

```bash
EXCLUDE=$'docs\nCHANGELOG.md' bash git/content-id/scripts/content_id.sh
```

Use it to check what an `exclude` list actually drops before committing to it — compare the id with and without an entry, and if it does not move, the entry matched nothing.
