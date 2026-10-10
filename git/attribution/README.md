# git/attribution

Reusable composite action that enforces attribution on agent work: each commit an agent account authored carries exactly one `Co-authored-by: <Name> <email>` line matching a roster pair, the body of a pull request an agent account opened carries none, and nothing else takes that role.

The email is what makes the trailer work: GitHub shows a co-author (avatar and profile link) only when the email belongs to a GitHub account. The default roster is the nine attribution-only GitHub Apps (QTS-1381), one per agent, each with a bot user and a fixed no-reply address. The PR body carries no trailer because the squash puts the body on `main` and Warden's merge step (`scripts/squash-merge.sh`, below) appends the one trailer it reads from the branch commits.

> :warning: **Important**
> The lines this rejects are written by tooling, not by a person who can be asked to amend. GitHub appends a host-identity `Co-authored-by:` to a squash commit whenever the commit author differs from the merger, and Claude Code appends its own trailer plus a `Generated with [Claude Code]` footer. Once either lands on `main` it is in the published history permanently, which is why the check runs before the merge.

## Scope: agent accounts only

Only agent work is checked (owner, QTS-1381). A commit is checked when its author email (`%ae`, case-insensitive) is on `agent-accounts`, and the PR body when `pr-author` is on `agent-logins`; the defaults are the two shared accounts every agent commits and opens pull requests as, `qtsone-developer` and `qtsone-reviewer`, under every address they appear with. Everything else — the owner's commits, Renovate, Dependabot, `github-actions` — is skipped whole, vendor lines included, and logged as `skipped: not an agent account`. Squash commits of agent pull requests keep the `qtsone-developer` author on `main`, so the `push` caller still covers them. Scope is decided by email, not name, because `%an` is free text: a name list could be dodged by renaming, whereas putting an agent email on a commit only opts it *into* the check.

## What it does

For each agent-account commit in `base-sha..head-sha`:

- Requires **exactly one** `Co-authored-by:` line naming a roster agent, and that line must carry the roster email for the name. A roster name with another email or none fails.
- Rejects `Co-Authored-By: Paperclip` unless `allow-paperclip-trailer` is `true`, which tolerates exactly one such line.
- Treats any other `Co-authored-by:` line — in practice a human or host identity — per `extra-coauthor-policy`.

For `pr-body`, when `pr-author` is an agent login:

- Rejects **any** `Co-authored-by:` line, whoever it names.

For both, rejects any line containing `noreply@anthropic.com` or `Generated with [Claude Code]`, and any `Co-Authored-By: Claude` trailer.

Every failure is a `::error::` annotation naming the commit sha and the offending or missing line, and the action exits non-zero. A per-target result table goes to the step summary.

The trailer **key** is matched case-insensitively, so `Co-Authored-By:`, `Co-authored-by:` and `CO-AUTHORED-BY:` are the same trailer; house style is GitHub's `Co-authored-by:`. The **name** is matched exactly (`atlas` is not `Atlas`), the **email** case-insensitively.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `agents` | no | the nine agent bot users | Newline-separated roster, one `Name <email>` per line. An entry without an email is an error, and so is an empty list. |
| `legacy-trailer-until` | no | `2026-10-24` | Cut-over grace, UTC `YYYY-MM-DD`. Before that day the pre-cut-over shapes only warn; see Cut-over. Empty disables it. |
| `base-sha` | no | `github.event.pull_request.base.sha` | Exclusive start of the range. On `push`, pass `github.event.before`. |
| `head-sha` | no | `github.event.pull_request.head.sha` | Inclusive end of the range. On `push`, pass `github.event.after`. |
| `pr-body` | no | `github.event.pull_request.body` | Body text to check alongside the commits. Empty skips the body check. |
| `pr-author` | no | `github.event.pull_request.user.login` | Login of the PR author. The body is checked only when it is on `agent-logins`; empty skips the body check. |
| `agent-accounts` | no | the two agent accounts' addresses | Newline-separated author emails (`%ae`, case-insensitive). Only commits authored by one of them are checked. An empty list is an error. |
| `agent-logins` | no | `qtsone-developer`, `qtsone-reviewer` | Newline-separated GitHub logins (case-insensitive) whose PR bodies are checked. An empty list is an error. |
| `allow-paperclip-trailer` | no | `false` | When `true`, one `Co-Authored-By: Paperclip <noreply@paperclip.ing>` line is tolerated alongside the agent trailer. |
| `extra-coauthor-policy` | no | `fail` | `fail` or `warn`, for a commit's `Co-authored-by:` line naming neither an agent nor Paperclip. Does not apply to the PR body. |

The default `agents` list mirrors the agent roster in company file §7, which is the source of truth; read the pairs out of `action.yaml` rather than from a copy here, because a copy is what drifts. Each email is `<bot user id>+qts-<agent>[bot]@users.noreply.github.com`, with the id from `gh api '/users/qts-<agent>%5Bbot%5D' -q .id` — the bot **user** id, not the app id. It is declared only in `action.yaml` — the script defaults nothing, and `tests/scripts/test_attribution.sh` reads the list out of the action metadata.

Roster drift is the failure mode to watch, and it fails in both directions: a newly named agent is rejected exactly like a nonsense name, wedging that agent's CI on every caller, and a retired persona keeps passing and can still claim authorship. A re-org is therefore a change to this default, not only to the company file. `.github/workflows/test-git-attribution.yml` asserts the committed default against an explicit list so that change has to be deliberate.

There are no outputs. The exit status *is* the result.

## Usage

On a pull request, every default is already right:

```yaml
name: Attribution

on:
  pull_request:
    # `edited` is not optional. The PR body is an input, so without it a body that fixes a
    # reported failure never re-runs the check and the PR stays red on a stale payload.
    types: [opened, synchronize, reopened, edited]

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
          extra-coauthor-policy: warn
```

`warn` on `push` because the owner merges in the browser, which has no `--body`: GitHub appends the agent trailer from the branch commits plus a `Co-authored-by:` per branch commit author, host identities included. The agent line still has to be the one roster pair; the host lines warn.

`fetch-depth: 0` is not optional. The action walks `base..head` in the local object database, and a depth-1 clone contains neither end of that range; it fails with a message naming the fix rather than passing on an empty range.

## As a required status check

A repository that gates merges on this check needs the workflow to run on **every** pull request, so it carries no `paths` filter. A path-filtered workflow does not report at all on a pull request that misses its paths, and a required check that never reports leaves that pull request blocked rather than passing. `.github/workflows/attribution.yml` in this repository is that shape and is the pattern to copy; the check name a ruleset needs is the **job** name, `Attribution`.

## Cut-over

Pull requests opened before this rule landed carry `Co-Authored-By: <Name>` with no email in their commits and the same line in their body, as the old rule required. Until `legacy-trailer-until` (default `2026-10-24`, two weeks after the change) both shapes produce a `::warning::` instead of an error, on pull requests and on `push` alike, so those branches merge as they are and their squash commits pass on `main`. The grace never covers a non-roster co-author in the body, a vendor line, or a second agent trailer.

The window is a date rather than a list of pull requests because the `push` caller sees only the squash commit and cannot tell which pull request it came from. From the date on the input is strict without any change. Removing it is one PR: delete the input, its `LEGACY_TRAILER_UNTIL` plumbing and `target_legacy` in the script (each call becomes `target_error`), and the grace-window tests.

A pull request merged during the window with its body trailer goes through `scripts/squash-merge.sh`, which refuses a body that already carries a trailer: delete the line from the body (`gh pr edit <n> --body-file …`) and merge again.

## Warden's merge: `scripts/squash-merge.sh`

```bash
GH_REPO=qtsone/<repo> scripts/squash-merge.sh <pr>
```

Reads every branch commit through `gh pr view`. Each must carry exactly one `Co-authored-by:` line and all must carry the same one; a body that already carries one is refused too. Any of those stops with the reason and merges nothing. Otherwise it runs `gh pr merge <pr> --squash --match-head-commit <head> --body "<PR body>\n\nCo-authored-by: <trailer>"`. The explicit body is still needed: without it GitHub composes the message and appends its own `Co-authored-by:` lines. `--match-head-commit` makes a push after the read fail the merge rather than land unread commits. It does not re-check the roster; this action already did on the same commits. Needs `gh` and `jq`.

## The `extra-coauthor-policy` input

GitHub appends a `Co-authored-by:` line carrying the commit author's identity to a squash commit whenever that author differs from the person clicking merge. Where agents commit with a workstation git identity, that line leaks a hostname into public history, which is why `fail` is the default.

`warn` exists for a repository whose `main` already carries such lines, so the check can be switched on to stop *new* ones before the backlog is cleaned up. It emits `::warning::` and keeps the exit status at zero.

## Failure modes

| Condition | Behaviour |
| --- | --- |
| No agent trailer on an agent-account commit | fails: `missing the required trailer line …` |
| Roster name with no email, or another email, in a commit | fails, naming the expected line (warns before `legacy-trailer-until`) |
| Any `Co-authored-by:` line in the PR body | fails (a roster name warns before `legacy-trailer-until`) |
| `agents` entry without ` <email>` | fails: a name without its email credits nobody |
| `legacy-trailer-until` not `YYYY-MM-DD` or empty | fails |
| More than one agent trailer | fails: `expected exactly one agent trailer, found N` |
| `noreply@anthropic.com`, `Generated with [Claude Code]`, or a `Co-Authored-By: Claude` trailer | fails: `vendor attribution is not allowed` |
| `Co-Authored-By: Paperclip` with `allow-paperclip-trailer: false` | fails |
| Two Paperclip trailers with `allow-paperclip-trailer: true` | fails: the input tolerates one |
| Any other `Co-authored-by:` line | `extra-coauthor-policy`: `fail` errors, `warn` annotates |
| `agents` empty or whitespace-only | fails: refusing to accept every trailer |
| `agent-accounts` or `agent-logins` empty or whitespace-only | fails: refusing to skip everything |
| `extra-coauthor-policy` or `allow-paperclip-trailer` not one of its allowed values | fails |
| `base-sha` set, `head-sha` empty | fails: the range is undefined |
| `base-sha` not present locally | fails, naming `fetch-depth: 0` as the likely cause |
| Empty range **and** empty `pr-body` | fails: a check that inspected nothing must not report success |
| `base-sha` all zeros | the head commit alone is checked — GitHub's `before` for the first push of a branch |

A single line that matches both a vendor needle and the Claude trailer name is reported once, not twice.

## Limits

- **Merge commits in the range are checked like any other commit.** A `git merge` commit carries a tooling-generated message with no trailer and will fail. The house convention is to rebase, so this does not normally arise; if a repository merges `main` into its PR branches, this action is the wrong shape for it as written.
- **The trailer must start its line.** A mid-sentence mention — a PR body explaining the rule, say — is not read as a trailer. Leading whitespace is tolerated.
- **Only the commits in the range are checked, and the squash message is neither of them.** A squash merge composes a *new* message at merge time, and GitHub adds its co-author line then, so the pre-merge run cannot see it. What that body is composed *from* is the repository's `squash_merge_commit_message` setting, and the two values behave oppositely here. On `PR_BODY` the squash body **is** the PR body, so the `pr-body` check covers it, and `scripts/squash-merge.sh` appends the one trailer. On `COMMIT_MESSAGES` — GitHub's default — it is the concatenated commit messages, so an N-commit PR lands **N** copies of the agent trailer on `main`, exactly the duplicate this action rejects, and checking the PR body covers none of it. Either way, merge with `scripts/squash-merge.sh`, which passes the body explicitly. The `push`-on-`main` caller above is the only thing that observes the message that actually landed.
- **The author email is not verified identity.** `%ae` is whatever the committer set, so a commit can leave scope by using another email. The check keeps honest agents on the rule; it is not a security boundary.
- **Text that *describes* the rule trips it.** The vendor needles are matched as substrings on any line, so a commit message or PR body quoting `noreply@anthropic` + `.com` verbatim fails — as the first version of this action's own PR body did. That is the intended trade: the needles are cheap to match and should never legitimately appear in a commit message. Refer to them descriptively ("the anthropic noreply address", "the Claude Code footer") in prose, and keep the literals in files, which are never scanned.

## Requirements

- `types: [opened, synchronize, reopened, edited]` on the `pull_request` trigger. The default type list omits `edited`, and the PR body is an input.
- A checkout with `fetch-depth: 0`, so both ends of the range are in the object database.
- `git` and `bash`. No network calls, no other tooling.
- Permissions: `contents: read`.
- On a repository that squash-merges: every merge through `scripts/squash-merge.sh`, so `main` gets the inspected body plus exactly one trailer. See Limits.

## Running it locally

The script is callable outside Actions, which is how its behaviour tests drive it. Inputs come from the uppercased env vars (`AGENTS`, `LEGACY_TRAILER_UNTIL`, `BASE_SHA`, `HEAD_SHA`, `PR_BODY`, `PR_AUTHOR`, `AGENT_ACCOUNTS`, `AGENT_LOGINS`, `ALLOW_PAPERCLIP_TRAILER`, `EXTRA_COAUTHOR_POLICY`). With `GITHUB_STEP_SUMMARY` unset the result table goes to stdout:

```bash
AGENTS=$'Atlas <340611218+qts-atlas[bot]@users.noreply.github.com>' \
AGENT_ACCOUNTS=336271639+qtsone-developer@users.noreply.github.com AGENT_LOGINS=qtsone-developer \
BASE_SHA=origin/main HEAD_SHA=HEAD \
  bash git/attribution/scripts/attribution.sh
```

Use it to check a branch before opening the PR. Note that `AGENTS`, `AGENT_ACCOUNTS` and `AGENT_LOGINS` have no default in the script — the lists live in `action.yaml` — so a local run must pass them.
