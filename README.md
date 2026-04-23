# kyverno/.github

Shared GitHub configuration and reusable workflows for the [Kyverno](https://kyverno.io) organization.

## Reusable Workflows

Reusable workflows live in [`.github/workflows/`](.github/workflows/) and are called from consumer repositories via `uses: kyverno/.github/.github/workflows/<name>.yml@main`.

### `pr-branch-updater.yml`

Finds open, non-draft pull requests whose branches have fallen behind their base branch and triggers GitHub's built-in branch-update mechanism for each one.

**How it works**

1. Fetches all open non-draft PRs via the REST API.
2. Re-fetches each PR individually to get a reliable `mergeable_state` (the bulk endpoint returns `"unknown"` for most PRs).
3. Calls `PUT /repos/{owner}/{repo}/pulls/{pull_number}/update-branch` for every PR with `mergeable_state == "behind"`.
4. Per-PR failures are non-fatal — the job logs and continues. The job exits non-zero only if unexpected errors occur.

**Inputs**

| Input | Required | Default | Description |
|---|---|---|---|
| `base_branch` | No | repo default branch | Only update PRs targeting this branch. |

**Secrets**

| Secret | Required | Description |
|---|---|---|
| `GH_TOKEN` | No | Token with `contents:write` and `pull-requests:write`. Falls back to the built-in `github.token`. |

**Usage — minimal caller workflow**

```yaml
name: PR Branch Auto-Updater

on:
  schedule:
    - cron: "39 */1 * * *"
  workflow_dispatch:

permissions: {}

concurrency:
  group: pr-branch-updater
  cancel-in-progress: false

jobs:
  update:
    uses: kyverno/.github/.github/workflows/pr-branch-updater.yml@main
    secrets:
      GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

To restrict updates to a specific base branch, pass the optional input:

```yaml
    with:
      base_branch: main
```

## Testing

The shell script logic is extracted from the workflow into `scripts/` and covered by [bats](https://github.com/bats-core/bats-core) unit tests in `tests/`. A fake `gh` CLI stub is injected via `PATH` so tests run with no GitHub credentials and no network access.

**Run locally:**

```bash
# Install bats (once)
brew install bats-core        # macOS
sudo apt-get install bats     # Ubuntu/Debian

# Run all tests from the repo root
bats tests/update-pr-branches.bats
```

CI runs `shellcheck` (linting) and `bats` (unit tests) automatically on every push or PR that touches `scripts/` or `tests/` — see [`.github/workflows/test.yml`](.github/workflows/test.yml).

## Adding a New Reusable Workflow

1. Add the workflow file to `.github/workflows/` using `on: workflow_call`.
2. Document it in this README under **Reusable Workflows**.
3. Add a thin caller wrapper to each consumer repository.

## Repository Structure

```
.github/
  workflows/
    pr-branch-updater.yml   # Reusable: update behind PR branches
    test.yml                # CI: shellcheck + bats on every scripts/ / tests/ change
scripts/
  update-pr-branches.sh     # Standalone bash implementation (called by the workflow)
tests/
  update-pr-branches.bats   # Bats unit tests with a fake gh stub
profile/
  README.md                 # GitHub org profile page (kyverno.io)
```
