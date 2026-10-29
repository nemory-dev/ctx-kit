# Workflows

[한국어](../ko/workflows.md) · [README](../../README.md) · [Getting started](getting-started.md) · [Configuration](configuration.md) · [Troubleshooting](troubleshooting.md)

Use these workflows after initialization. Examples assume `ctx.sh` is in the project root and `source` is `sample-context/AGENT_RULES.md`. For a `scripts/` installation, use `bash scripts/ctx.sh`; for a custom `source`, replace the context paths below with its parent directory.

## Start a work session

1. Check the configured links and project summary:

   ```bash
   bash ctx.sh status
   ```

2. Read the current state, existing decisions, optional historical digest, and backlog in the order specified by your rules:

   ```bash
   cat sample-context/MASTER_PLAN.md
   cat sample-context/decisions.md
   if [ -f sample-context/work-log/timeline-digest.md ]; then
     cat sample-context/work-log/timeline-digest.md
   fi
   cat sample-context/backlog.md
   ```

3. Tell the agent the concrete task and any limits, such as “review only” or “edit these files only.” Confirm that its context-loaded response reflects the current state and relevant ADRs.

The rule file tells an agent what to read and record. The CLI does not enforce an agent's behavior or automatically retain its model memory. A digest exists only after applicable archived logs have been processed. Read individual archived files when the task needs older details instead of loading the entire archive every session.

## Make authorized changes and close the work unit

Within an authorized task, update only affected Current State and Next Actions in `MASTER_PLAN.md` when those facts change. Leave it unchanged when they do not. Ask before adopting a new technical decision, changing scope or priorities, or adding a backlog item unless that action is already authorized. For an ADR conflict, resolve the conflict with the user before changing the decision.

After a work unit changes project files, including documentation:

1. Review the actual diff and run the relevant available checks. State separately what was implemented, verified, committed, or merged.
2. Apply any authorized context updates.
3. Record an accurate summary, validation result, remaining issues, and relevant files:

   ```bash
   bash ctx.sh log \
     --summary "Updated setup guide; link check passed; no open issues" \
     --files "README.md,docs/en/getting-started.md" \
     --type docs
   bash ctx.sh timeline --limit 1 --json
   ```

4. Check that `log` exited successfully and that readback contains **your** summary, files, and type. Another writer may have added a newer row; increase the limit to locate your entry:

   ```bash
   bash ctx.sh timeline --limit 20 --json
   ```

An existing `timeline.jsonl` or an unrelated row does not verify this work unit. If recording or readback fails, report it as failed or unverified. Inspect for an existing entry before retrying: a later step can fail after the entry was written. Do not edit the JSONL directly to bypass the CLI. See [storage and logging failures](troubleshooting.md).

Read-only reviews need no context edits or work-log entry. Explicit no-logging or allowed-file restrictions take precedence; report skipped closure steps without extending the allowed scope.

### Log options

`record` is an alias for `log`.

| Option | Meaning |
| --- | --- |
| `--summary`, `-s` | Required nonempty description of the work. Quote text with spaces. |
| `--title`, `-t` | Optional title; defaults to the first summary line, up to 80 characters. |
| `--files`, `-f` | Comma-separated paths, such as `src/app.kt,README.md`. Supply the files that actually relate to the work. |
| `--commit`, `-c` | Explicit commit reference. Use it only when that reference accurately describes the recorded work. |
| `--type` | Label; defaults to `work`. Examples include `docs` and `release`. |

Without `--commit`, `log` records `uncommitted` when Git reports changes; otherwise it uses the current short commit when available. Without `--files`, it derives paths from that commit or the working tree. These are metadata defaults, so explicit relevant paths help keep the record accurate. Logging does not create a project commit.

Automatic paths preserve Unicode, whitespace, line breaks, quotes, and backslashes rather than Git display escaping. Working-tree renames and copies use the destination path. Untracked directories are expanded into file paths even when `status.showUntrackedFiles` hides them by default; the runtime lock remains excluded. A failed Git status or commit-file query stops logging before adding a row. Logging outside a Git repository remains supported.

Commit references are resolved before writing, including when `--files` is explicit. An invalid reference fails without adding a row. For a clean project, or an explicit commit, file names are read from the resolved full hash so a concurrent HEAD update cannot change which commit supplies them. A repository without its first commit still records `uncommitted`.

## Find recent work or import Git history

```bash
bash ctx.sh timeline
bash ctx.sh timeline --limit 5 --json
bash ctx.sh timeline --commit abc123 --limit 20
```

`timeline` reads the active `work-log/timeline.jsonl`, with the last stored rows first. It does not search monthly archives.

| Option | Meaning |
| --- | --- |
| `--limit`, `-n` | Number of rows to display; default `20`. Use a positive integer. |
| `--commit`, `-c` | Prefix filter against `commit` or `fullCommit`. |
| `--json` | Print the selected rows as a JSON array. If the log file does not exist, the command prints an explanatory message instead. |

To bring an existing project's Git history into the active log:

```bash
bash ctx.sh backfill --limit 30
bash ctx.sh timeline --limit 5 --json
```

`backfill` imports Git commit messages, dates, and file names. It cannot reconstruct uncommitted work or validation results that were not recorded in Git.

File paths and commit fields are read with NUL separators, so unusual file names and message text such as `__CTX_FILES__` or `__CTX_COMMIT_START__` do not split or truncate imported records. Empty commits keep an empty file list.

| Option | Meaning |
| --- | --- |
| `--limit`, `-n` | Number of recent Git commits to inspect; default `30`. |
| `--all` | Inspect the entire Git history instead of applying the limit. Review the possible volume before using it. |
| `--type` | Label applied to imported entries; default `work`. |

With no Git commits, `backfill` reports that there is nothing to import. It skips commits represented by `commit` or `fullCommit` in the active log or any `archive/timeline-*.jsonl` file, including the legacy archive. Legacy hash-only references are resolved in one Git batch, so a change to `core.abbrev` does not reimport them. An ambiguous reference stops backfill; preserve the record and identify its full commit ID before retrying. Repeating a backfill after archiving leaves those commits archived. Invalid archive JSONL stops backfill before rewriting the active log. Existing work-unit records and archived occurrences are preserved. Choose a limited range appropriate to your adoption workflow and inspect the result.

## Keep the active context small

Review the plan and decisions first, then archive when their completed or retired content can leave the active context:

```bash
bash ctx.sh archive --keep 30
bash ctx.sh timeline --limit 5 --json
```

| Option | Meaning |
| --- | --- |
| `--keep`, `-k` | Keep this many rows at the end of the active timeline; default `30`, nonnegative integer required. `0` moves all active rows. |
| `--no-tasks` | Leave completed task lines in `MASTER_PLAN.md`. |
| `--no-logs` | Leave active timeline rows in place. |
| `--no-decisions` | Leave ADR sections in `decisions.md`. |

For example, to archive only old active log rows:

```bash
bash ctx.sh archive --keep 20 --no-tasks --no-decisions
```

The default operation moves:

- Completed checkbox **lines** beginning with `-` or `*` and `[x]` or `[X]` to `archive/completed-tasks.md`. It does not move a whole nested task block or its surrounding prose. Review indented explanations and child tasks afterward.
- Retired ADR sections to `archive/decisions-deprecated.md`. Use recognizable level 2–4 ADR headings, such as `## ADR-001 Use local storage`, and a status marker such as `Status: Deprecated` or `상태: 폐기됨`. The parser also recognizes `Superseded`, `Obsolete`, `Cancelled`, and `대체됨` status values, case-insensitively for English. It searches section text for these markers; arbitrary headings or custom status formats may not be detected.
- Older timeline rows to `archive/timeline-YYYY-MM.jsonl`. Rows without a recognizable date prefix go to `timeline-legacy.jsonl`. Existing IDs and distinct occurrences of legacy rows are preserved; archival does not deduplicate them.

When monthly archived logs exist, the command generates `work-log/timeline-digest.md`: a month-by-month list of each archived entry's date, title, and applicable commit reference. This is a deterministic index, not an AI-written synthesis. The digest and export may reduce the material you load, but no fixed token reduction is guaranteed.

Inspect the retained plan and ADRs, the relevant archive files, and the digest after the command. `--no-logs` still permits digest regeneration from existing monthly archives. If the context directory has its own Git repository, `archive` also attempts a local snapshot; a Git identity or commit failure can occur after the archive files changed.

### Interrupted writes and concurrent work

CLI storage writers use an exclusive `work-log/.ctx.lock`, waiting up to 30 seconds, and stage replacement files before changing their destinations. Local context Git snapshot operations use the same lock. This does not coordinate arbitrary manual edits by other tools.

An archive records its pending replacements in the internal `work-log/.ctx-archive-transaction.json` journal. After an interruption, the next storage writer attempts to finish those replacements. If affected files changed outside that transaction, recovery refuses to overwrite them. Preserve the journal and files and follow [troubleshooting](troubleshooting.md); do not delete the journal or blindly repeat `log`. Read-only `timeline` and `export` do not perform this recovery.

## Share selected context with a web LLM

```bash
bash ctx.sh export
bash ctx.sh export --all
```

Review the output before pasting it into an external service. The default export includes available `MASTER_PLAN.md`, `decisions.md`, `backlog.md`, the warm digest, and a rendered view of the latest 10 active timeline rows. It does not include `AGENT_RULES.md` or generated source bundles.

`--all` additionally includes `archive/completed-tasks.md`, `archive/decisions-deprecated.md`, and every `archive/timeline-*.jsonl` file, including legacy records. Timeline files appear in filename order as JSONL blocks with their filenames. Each complete record retains its summary, files, metadata, and repeated occurrences. Review sensitive details and output volume before sharing; default export still omits these monthly details.

Export prints terminal headers and ANSI color escapes; there is no `--plain` option. Redirecting output preserves those bytes. A recent-timeline rendering error or an archived-JSONL read/validation error returns nonzero without printing “Export complete.” Output emitted before an error may be incomplete; discard it, fix the reported source, and retry. Export remains read-only: it creates no writer lock and does not recover a pending archive transaction.

## Collect reviewed source files for an LLM

Edit the `generate.project` section of `ctx.config.json`, keeping the rest of your configuration. Start with an explicit allowlist of files you have reviewed:

```json
{
  "generate": {
    "project": {
      "output": "sample-context/generated/project-raw.md",
      "collect": [
        "README.md",
        "docs/architecture.md"
      ]
    }
  }
}
```

With both files present:

```bash
bash ctx.sh generate project
```

The terminal output includes the following, with color formatting omitted here:

```text
[ctx generate project]

  + README.md
  + docs/architecture.md

  ✓ 2 file(s) collected → sample-context/generated/project-raw.md
  Open and paste into your LLM.
```

Open `sample-context/generated/project-raw.md` and verify its `## [README.md]` and `## [docs/architecture.md]` sections and contents before sharing. The command concatenates matching files with headings; it does not summarize them. Paths are relative to the project root, and recursive glob patterns are supported. Overlapping patterns can include a file more than once.

Input patterns are expanded before writing. The output and its symlink or hard-link aliases are excluded, and other matching files are collected. A missing configured type or output is an error. If no inputs remain, the command reports an error on stderr and exits nonzero without changing an existing output or creating a new one.

Successful collection replaces the output atomically and preserves its existing permissions. Errors before replacement leave the output untouched by this run. A detected output change before replacement also stops the command; concurrent writers are not locked. The final output cannot be a symlink, including a broken link, or another non-regular entry such as a directory or FIFO; the command rejects it without changing the entry or its target. See [Troubleshooting](troubleshooting.md#generate-fails-or-export-is-incomplete).

Collection does not honor `.gitignore` as a filter and performs no secret or binary scan. Review patterns and output yourself, especially before replacing exact paths with broad globs. Output exclusion does not filter other private files or deduplicate overlapping patterns.

## Opt in to local Git snapshots and pre-commit logs

The hook changes `.gitignore`, `ctx.config.json`, `.git/hooks/pre-commit`, and the context directory. Use it when you want those local changes. A standard project `.git` directory and a usable Git author identity are prerequisites. Check your identity before installation:

```bash
git var GIT_AUTHOR_IDENT
bash ctx.sh hook install
bash ctx.sh hook status
```

If the identity check fails, configure your normal project or global Git identity first. A project-only identity is not automatically a configuration for the independent context repository; see [Git identity troubleshooting](troubleshooting.md).

Installation initializes an independent Git repository inside the context directory, adds a context ignore rule when needed, enables `git_sync.enabled`, and installs a pre-commit wrapper. It defaults `auto_log` to `true` only when the key is absent; an existing `false` value is preserved. Inspect the reported configuration with `hook status`.

New ignore rules are anchored at the project root and escape pattern characters so the configured directory is matched literally. Names containing `%`, backslashes, `*`, `?`, brackets, `#`, `!`, spaces, Unicode, or apostrophes do not become formatting instructions or broader patterns. Installation verifies the new rule with Git before proceeding. A Git exclusion-check error or a context path containing CR/LF line breaks stops installation before enabling integration. Existing `.gitignore` and `.git/info/exclude` rules are preserved; an already ignored directory needs no new rule. Review broad or malformed rules from older installations manually.

An existing hook is saved as `.git/hooks/pre-commit.ctx-kit-original`, preserving its contents, permissions, and any symlink. The wrapper runs an executable original first with the same working directory, arguments, and input. A nonzero exit blocks the commit and skips ctx-kit; a successful exit allows ctx-kit to run. A non-executable original remains saved and is skipped. Reinstalling an unchanged wrapper is safe; reinstalling an older inline integration migrates the known ctx-kit block while retaining the rest of the hook.

With `git_sync.enabled` and `auto_log` both `true`, a normal project commit attempt can append a log **before** the commit. Its title uses staged file names and its summary contains a staged diff stat. It uses `pending` for both commit fields; it does not later attach the real commit hash or produce a semantic AI summary. A later hook or the commit itself can fail, leaving the pre-commit entry in place. Use the explicit work-unit closure workflow for validation results and outcomes.

These pending entries have `dirty: true`. Staged paths preserve their actual names, and both the file list and diff stat exclude the configured context directory literally, including already tracked context files. A context-only change adds no auto-log. Git metadata query errors stop the hook before adding a row and block the project commit; fix the reported cause before retrying.

The installed hook also snapshots context changes in the independent local Git repository. Context Git commands clear inherited repository-local Git environment variables so they use the context repository's own index; project inspection keeps the commit's active index, including `git commit --only`. ctx-kit contains no remote push step, but local Git and ignore rules are not a secrecy guarantee: already tracked files, separately configured remotes, exports, and generated bundles still require review.

The installer uses `.git/hooks/pre-commit` directly. A linked worktree with a `.git` file and a custom `core.hooksPath` are not supported automatically. See [hook troubleshooting](troubleshooting.md) before relying on automatic execution.

To remove the ctx-kit wrapper and disable Git sync:

```bash
bash ctx.sh hook uninstall
bash ctx.sh hook status
```

Uninstall restores the saved original hook exactly, including permissions or a symlink, or removes the wrapper if no original existed. It keeps context history, the ignore rule, and the independent context repository. Installation and removal refuse to overwrite a modified wrapper or conflicting backup, or proceed without a required backup; preserve those files and inspect the reported error before retrying.

Both operations save configuration through [atomic replacement](configuration.md#configuration-writes). A failed configuration write or replacement preserves the existing JSON, but earlier hook, ignore-rule, or context-repository changes are not rolled back. Inspect `ctx.config.json` and `bash ctx.sh hook status` before retrying; after an uninstall failure, the original hook may already have been restored or the wrapper removed.

## Upgrade an existing installation

Keep a recoverable copy of your existing configuration and context, including customized rules. Obtain the new `ctx.sh` from a reviewed repository revision and replace the script at its current location. Preserve `ctx.config.json` and the directory selected by `source`.

Compare that revision's root `AGENT_RULES.md` with your configured source file and merge relevant protocol changes into your customized rules. Adapt `sample-context/` references to your configured directory and `bash ctx.sh` examples to `bash scripts/ctx.sh` when applicable. Re-running `init` preserves existing context files; it does not upgrade their customized content.

Verify the result:

```bash
bash ctx.sh version
bash ctx.sh sync
bash ctx.sh status
bash ctx.sh timeline --limit 5 --json
bash ctx.sh hook status
```

Resolve any link conflicts without overwriting existing agent instructions; see [configuration](configuration.md) and [troubleshooting](troubleshooting.md). Run only the checks relevant to enabled features, then record the upgrade and its verification through the normal closure workflow when authorized.
