# git/attribution

Reusable composite action that enforces one attribution line on every commit in a range and on the pull request body: exactly one `Co-Authored-By: <Agent Name>` naming a known agent, and nothing else in that role.

> :warning: **Important**
> The lines this rejects are written by tooling, not by a person who can be asked to amend. GitHub appends a host-identity `Co-authored-by:` to a squash commit whenever the commit author differs from the merger, and Claude Code appends its own trailer plus a `Generated with [Claude Code]` footer. Once either lands on `main` it is in the published history permanently, which is why the check runs before the merge.

## What it does

For each commit in `base-sha..head-sha`, and for `pr-body`:

- Requires **exactly one** `Co-Authored-By:` line whose value — after an optional ` <email>` suffix is stripped — is in `agents`.
- Rejects any line containing `noreply@anthropic.com` or `Generated with [Claude Code]`, and any `Co-Authored-By: Claude` trailer.
- Rejects `Co-Authored-By: Paperclip` unless `allow-paperclip-trailer` is `true`, which tolerates exactly one such line.
- Treats any other `Co-authored-by:` line — in practice a human or host identity — per `extra-coauthor-policy`.

Every failure is a `::error::` annotation naming the commit sha and the offending or missing line, and the action exits non-zero. A per-target result table goes to the step summary.

The trailer **key** is matched case-insensitively, so `Co-Authored-By:`, `Co-authored-by:` and `CO-AUTHORED-BY:` are the same trailer. The **value** is matched exactly: `atlas` is not `Atlas`.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `agents` | no | the thirteen agent names | Newline-separated names accepted in the trailer. An empty list is an error, not "accept anything". |
| `base-sha` | no | `github.event.pull_request.base.sha` | Exclusive start of the range. On `push`, pass `github.event.before`. |
| `head-sha` | no | `github.event.pull_request.head.sha` | Inclusive end of the range. On `push`, pass `github.event.after`. |
| `pr-body` | no | `github.event.pull_request.body` | Body text to check alongside the commits. Empty skips the body check. |
| `exempt-authors` | no | `renovate[bot]`, `github-actions[bot]`, `dependabot[bot]` | Commit author names (`%an`) that skip the agent-trailer requirement. |
| `allow-paperclip-trailer` | no | `false` | When `true`, one `Co-Authored-By: Paperclip <noreply@paperclip.ing>` line is tolerated alongside the agent trailer. |
| `extra-coauthor-policy` | no | `fail` | `fail` or `warn`, for a `Co-authored-by:` line naming neither an agent nor Paperclip. |

The default `agents` list is `Zeus, CPO, CTO, Design Lead, Ledger, Beacon, Lex, Anvil, Casa, Relay, Atlas, Warden, Sentinel`. It is declared only in `action.yaml`; the script defaults nothing, and `tests/scripts/test_attribution.sh` reads the list out of the action metadata rather than keeping a second copy that could drift.

There are no outputs. The exit status *is* the result.

## Usage

On a pull request, every default is already right:

```yaml
name: Attribution

on:
  pull_request:

permissions:
  contents: read

jobs:
  attribution:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0
      - uses: qtsone/actions/git/attribution@main
```

On `push`, the range comes from the event instead, and there is no body to check:

```yaml
on:
  push:
    branches: [main]

jobs:
  attribution:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0
      - uses: qtsone/actions/git/attribution@main
        with:
          base-sha: ${{ github.event.before }}
          head-sha: ${{ github.event.after }}
          pr-body: ""
```

`fetch-depth: 0` is not optional. The action walks `base..head` in the local object database, and a depth-1 clone contains neither end of that range; it fails with a message naming the fix rather than passing on an empty range.

## Exemptions

`exempt-authors` matches the commit author name (`%an`) exactly. A commit by an exempt author skips the **agent-trailer requirement only** — the vendor, Paperclip and extra-co-author checks still apply to it. Renovate cannot be asked to write an agent trailer, and failing its PRs on one would get the check removed rather than obeyed; a vendor trailer in a Renovate commit is still a vendor trailer.

## The `extra-coauthor-policy` input

GitHub appends a `Co-authored-by:` line carrying the commit author's identity to a squash commit whenever that author differs from the person clicking merge. Where agents commit with a workstation git identity, that line leaks a hostname into public history, which is why `fail` is the default.

`warn` exists for a repository whose `main` already carries such lines, so the check can be switched on to stop *new* ones before the backlog is cleaned up. It emits `::warning::` and keeps the exit status at zero.

## Failure modes

| Condition | Behaviour |
| --- | --- |
| No agent trailer on a non-exempt commit | fails: `missing the required trailer line …` |
| More than one agent trailer | fails: `expected exactly one agent trailer, found N` |
| `noreply@anthropic.com`, `Generated with [Claude Code]`, or a `Co-Authored-By: Claude` trailer | fails: `vendor attribution is not allowed` |
| `Co-Authored-By: Paperclip` with `allow-paperclip-trailer: false` | fails |
| Two Paperclip trailers with `allow-paperclip-trailer: true` | fails: the input tolerates one |
| Any other `Co-authored-by:` line | `extra-coauthor-policy`: `fail` errors, `warn` annotates |
| `agents` empty or whitespace-only | fails: refusing to accept every trailer |
| `extra-coauthor-policy` or `allow-paperclip-trailer` not one of its allowed values | fails |
| `base-sha` set, `head-sha` empty | fails: the range is undefined |
| `base-sha` not present locally | fails, naming `fetch-depth: 0` as the likely cause |
| Empty range **and** empty `pr-body` | fails: a check that inspected nothing must not report success |
| `base-sha` all zeros | the head commit alone is checked — GitHub's `before` for the first push of a branch |

A single line that matches both a vendor needle and the Claude trailer name is reported once, not twice.

## Limits

- **Merge commits in the range are checked like any other commit.** A `git merge` commit carries a tooling-generated message with no trailer and will fail. The house convention is to rebase, so this does not normally arise; if a repository merges `main` into its PR branches, this action is the wrong shape for it as written.
- **The trailer must start its line.** A mid-sentence mention — a PR body explaining the rule, say — is not read as a trailer. Leading whitespace is tolerated.
- **Only the commits in the range are checked.** A squash merge composes a *new* message from the PR body and the commit list, and GitHub adds its co-author line at that moment; the pre-merge run cannot see it. Checking the PR body is what covers most of that gap, since the body is what the squash message is built from.
- **Author matching for exemptions is by name, not verified identity.** `%an` is whatever the committer set. The input exists to avoid false failures on bot PRs, not as a security boundary.
- **Text that *describes* the rule trips it.** The vendor needles are matched as substrings on any line, so a commit message or PR body quoting `noreply@anthropic` + `.com` verbatim fails — as the first version of this action's own PR body did. That is the intended trade: the needles are cheap to match and should never legitimately appear in a commit message. Refer to them descriptively ("the anthropic noreply address", "the Claude Code footer") in prose, and keep the literals in files, which are never scanned.

## Requirements

- A checkout with `fetch-depth: 0`, so both ends of the range are in the object database.
- `git` and `bash`. No network calls, no other tooling.
- Permissions: `contents: read`.

## Running it locally

The script is callable outside Actions, which is how its behaviour tests drive it. Inputs come from the uppercased env vars (`AGENTS`, `BASE_SHA`, `HEAD_SHA`, `PR_BODY`, `EXEMPT_AUTHORS`, `ALLOW_PAPERCLIP_TRAILER`, `EXTRA_COAUTHOR_POLICY`). With `GITHUB_STEP_SUMMARY` unset the result table goes to stdout:

```bash
AGENTS=$'Atlas\nWarden' \
BASE_SHA=origin/main HEAD_SHA=HEAD \
  bash git/attribution/scripts/attribution.sh
```

Use it to check a branch before opening the PR. Note that `AGENTS` has no default in the script — the list lives in `action.yaml` — so a local run must pass it.
