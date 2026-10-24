# How to contribute to ctx-kit

[한국어](CONTRIBUTING.ko.md) · [README](README.md) · [CLI workflows](docs/en/workflows.md) · [Troubleshooting](docs/en/troubleshooting.md)

Use this guide to change the ctx-kit repository, validate the change, and take it through a PR and merge. To install ctx-kit in another project, use [Getting started](docs/en/getting-started.md).

## Prerequisites

- Bash, standard Unix tools, and Git. Use macOS or Linux for the steps below.
- Python **3.11** to match CI. The tests need only the standard library.
- A GitHub account. The [GitHub CLI](https://cli.github.com/manual/) is optional if you use GitHub's web UI for PRs, checks, and merges. CLI examples assume `gh auth status` succeeds.

Run commands from the repository root. Tests create temporary projects; you do not need to run `ctx.sh init` in this checkout.

## CI and main protection

[CI configuration](.github/workflows/ci.yml) runs on PR creation, reopening, and new commits, and on pushes to `main`. Documentation changes also run CI. Each job uses Python 3.11 and runs `bash -n ctx.sh` followed by the full unittest suite.

| Runner | Required check name |
| --- | --- |
| `ubuntu-latest` | `Regression tests (ubuntu-latest)` |
| `macos-latest` | `Regression tests (macos-latest)` |

Both jobs must succeed. One job failing does not cancel the other, and each has a 10-minute timeout. Tool versions are printed in the logs; `-latest` runner images can change over time. Windows is outside this CI matrix.

The upstream repository's `main` policy, verified on **2026-10-25**, requires:

- A PR for every change, including administrator changes; no PR bypass is configured.
- Both check names above, provided by GitHub Actions, with the latest `main` changes included before merging.
- **0 required approving reviews.** A formal approval is not required, but the PR and CI requirements still apply. Address review feedback before merging.
- No force pushes or deletion of `main`.

Branch protection is a [GitHub repository setting](https://github.com/nemory-dev/ctx-kit/settings/branches), separate from the workflow YAML. Copying the workflow into another repository does not configure that repository's protection. Maintainers must keep the required check names aligned if CI jobs are renamed. See GitHub's [protected branch documentation](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches).

## 1. Create a work branch

With write access, clone the upstream repository into a new directory:

```bash
git clone https://github.com/nemory-dev/ctx-kit.git
cd ctx-kit
```

Without write access, fork the repository on GitHub and clone your fork instead. With the GitHub CLI, run this from a parent directory without an existing `ctx-kit` directory:

```bash
gh repo fork nemory-dev/ctx-kit --clone
cd ctx-kit
git remote -v
```

For a fork, confirm `origin` points to your fork and `upstream` to `nemory-dev/ctx-kit`. If `upstream` is missing, add it with `git remote add upstream https://github.com/nemory-dev/ctx-kit.git`. Use `BASE_REMOTE=upstream` in the following block; otherwise keep `origin`. If you already have a checkout, start here and inspect existing changes before switching branches. Use a unique branch name in place of the example throughout this guide.

```bash
BASE_REMOTE=origin
git status --short
git fetch "$BASE_REMOTE"
git switch main
git merge --ff-only "${BASE_REMOTE}/main"
git switch -c codex/my-change
```

If switching or fast-forwarding fails, inspect the reported local work or diverged history before continuing. Preserve existing files and unfinished work.

## 2. Make and validate the change

Keep changes focused and use existing patterns. Bug fixes should include a regression test that fails before the fix. Keep the English and Korean documentation in sync. When changing agent rules, update both the root `AGENT_RULES.md` and the embedded template in `ctx.sh`; initialization tests check their alignment.

```bash
bash -n ctx.sh
python3 -B -m unittest discover -s tests -v
git diff --check
```

All commands must succeed. The test summary should end with `OK`. Inspect any failure and fix it before pushing. These checks cover CLI behavior, including interrupted writes and concurrent writers; they do not prove AI instruction compliance.

## 3. Commit and push reviewed files

Review the diff and new files in your editor. Stage explicit paths so unrelated local files and private context stay outside the commit. For a documentation change, for example:

```bash
git add -- README.md README.ko.md CONTRIBUTING.md CONTRIBUTING.ko.md
git diff --cached --check
git diff --cached
git commit -m "docs: clarify the contribution workflow"
git push -u origin HEAD
```

Replace that file list and message with your actual change. Check the staged diff before committing. Push the work branch, not `main`. For a fork, `origin` remains your fork even when `BASE_REMOTE` is `upstream`.

## 4. Open a PR targeting main

Use the link printed by `git push` or [create a PR with GitHub CLI](https://cli.github.com/manual/gh_pr_create):

```bash
PR_SOURCE=codex/my-change
gh pr create --repo nemory-dev/ctx-kit --base main --head "$PR_SOURCE"
```

For a fork, set `PR_SOURCE` to `YOUR_LOGIN:codex/my-change`, replacing `YOUR_LOGIN` with the fork owner's GitHub login. The command asks for a title and body, then prints the PR URL. Describe the problem, resulting behavior, validation performed, and remaining limitations.

## 5. Check the PR and handle main updates

Replace `123` with the PR number you created. Capture its head commit and [wait for required checks](https://cli.github.com/manual/gh_pr_checks):

```bash
PR_NUMBER=123
PR_HEAD=$(gh pr view "$PR_NUMBER" --repo nemory-dev/ctx-kit --json headRefOid --jq .headRefOid)
gh pr checks "$PR_NUMBER" --repo nemory-dev/ctx-kit --required --watch --fail-fast
```

In GitHub, confirm both required check names show success for the current PR commit. A queued job, missing check, or local test result is not a passing PR check. Read new comments and resolve actionable feedback. If more commits are pushed, capture `PR_HEAD` again and wait for the new results.

If GitHub says the branch is behind `main`, stay on your work branch and merge the current base:

```bash
git fetch "$BASE_REMOTE"
git merge --no-edit "${BASE_REMOTE}/main"
```

If conflicts occur, resolve them, stage only the resolved files, and complete the merge commit before continuing. Then rerun the three local validation commands from step 2, push the work branch with `git push origin HEAD`, and repeat the PR check block. Protection requires the updated result; do not bypass it.

## 6. Merge the verified PR

A maintainer with merge permission checks the final diff, feedback, and both current CI results, then uses GitHub's merge button or:

```bash
gh pr merge "$PR_NUMBER" --repo nemory-dev/ctx-kit --merge --match-head-commit "$PR_HEAD"
gh pr view "$PR_NUMBER" --repo nemory-dev/ctx-kit --json state,mergedAt,mergeCommit
```

Keep the verified `PR_HEAD` from step 5. [The head-match option](https://cli.github.com/manual/gh_pr_merge) rejects the merge if the PR has moved; inspect the new commit and repeat validation. Continue only after the PR state is `MERGED`; if the merge command reports an error, read the PR state before trying anything else. Do not use `--admin` or disable protection to skip a requirement. Contributors without merge permission wait for a maintainer.

## 7. Verify the main push CI

Merging starts a separate CI run for the merged commit on `main`. PR CI success does not verify that later run. Find it by its merge SHA, branch, and event:

```bash
MERGE_SHA=$(gh pr view "$PR_NUMBER" --repo nemory-dev/ctx-kit --json mergeCommit --jq .mergeCommit.oid)
gh run list --repo nemory-dev/ctx-kit --workflow ci.yml --branch main --event push --commit "$MERGE_SHA" --json databaseId,status,conclusion,url
```

If the list is empty, wait briefly and repeat it. Replace `456` below with the returned `databaseId`; it is a workflow run ID, not a PR number:

```bash
RUN_ID=456
gh run watch "$RUN_ID" --repo nemory-dev/ctx-kit --exit-status --interval 10
```

Confirm the run and both OS jobs finish successfully, including **Check Bash syntax** and **Run regression tests**. In the browser, use the matching run in [Actions](https://github.com/nemory-dev/ctx-kit/actions/workflows/ci.yml). If it fails, inspect the failing step and prepare the fix through another PR.

## 8. Update local main and clean up

After the PR is merged and the `main` push CI succeeds, return to a working tree whose changes you have reviewed, then:

```bash
git fetch "$BASE_REMOTE"
git switch main
git merge --ff-only "${BASE_REMOTE}/main"
git branch -d codex/my-change
git push origin --delete codex/my-change
git status --short
```

Use your actual branch name. Skip remote deletion if the branch was already removed. The example merge method preserves ancestry for `git branch -d`; if deletion is refused, inspect the history rather than forcing it. Leave unrelated untracked files and private context untouched.

## Troubleshooting

| Symptom | Next step |
| --- | --- |
| Direct push to `main` is rejected | Push a work branch and open a PR; this is expected protection behavior. |
| Required check is queued or missing | Check the PR's Actions run and wait for both exact check names. Maintainers should also check fork-run approval and repository Actions settings. |
| Required check fails | Open the failing step's log, reproduce the local command, fix the cause, and push a new commit. |
| PR is out of date | Follow step 5, resolve conflicts, and wait for new CI results. |
| Merge fails because the head changed | Recapture the head after reviewing the new changes and rerun the PR checks. |
| CLI cannot read checks or watch a run | Check `gh auth status` and repository access, or inspect the PR and Actions run in GitHub's web UI. |
| Main push CI fails after merge | Inspect that push run, report its failure, and use a new PR for the fix. |

The [CLI troubleshooting guide](docs/en/troubleshooting.md) covers ctx-kit storage and rule-link problems.
