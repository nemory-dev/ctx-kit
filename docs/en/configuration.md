# Configuration reference

[한국어](../ko/configuration.md) · [README](../../README.md) · [Getting started](getting-started.md) · [Workflows](workflows.md) · [Troubleshooting](troubleshooting.md)

Use `ctx.config.json` to choose the shared rules file, register agent rule paths, and define source bundles. This page describes the shipped configuration and the CLI behavior; it does not verify that an agent loads a registered file.

## Prerequisites and path rules

- Install `ctx.sh` and `ctx.config.json` as described in [Getting started](getting-started.md). You need Bash and Python 3.7+; Git is needed for Git integration. The CLI validates `python3`, `python`, then `py -3` on `PATH` and uses the first runnable candidate meeting that minimum. Prefer a maintained Python 3 release.
- Keep `ctx.config.json` at the project root. Place the script at either `ctx.sh` or `scripts/ctx.sh`. When the script is in a directory named `scripts`, its parent is the project root; otherwise, its own directory is the root.
- Run the examples from the project root. For a `scripts/ctx.sh` installation, replace `bash ctx.sh` with `bash scripts/ctx.sh`.
- Write JSON without comments or trailing commas. Use JSON booleans (`true` and `false`), not quoted strings.
- Use project-relative paths for `source`, agent `path`, `output`, and `collect`. Spaces, Unicode, and apostrophes are supported in these paths, the project path, and the Python executable path. Avoid absolute paths, `..`, and symlinked parent directories. These options are configuration paths, not a sandbox.
- Keep context documents as plain UTF-8 Markdown (`.md`). The configured source and agent target must be different filesystem entries.

Use double quotes for shell paths, for example `bash "/path/to/팀's project/ctx.sh" status` after replacing the placeholder. In JSON, a field such as `"source": "팀's context/AGENT_RULES.md"` needs no escape for its apostrophe. Keep any `generate.<type>.output` prefix aligned with your context location. The standalone Python examples use `python3`; substitute your valid `python` or `py -3` candidate if needed.

## Complete example

This example uses the shipped context location, disables optional Git behavior, and collects an explicit allowlist of documentation. The `collect` entries must name files you have reviewed and intend to share.

```json
{
  "_comment": "Shared agent rules and reviewed source bundles",
  "_usage": "bash ctx.sh help",
  "source": "sample-context/AGENT_RULES.md",
  "git_sync": {
    "enabled": false,
    "auto_log": false
  },
  "generate": {
    "project": {
      "output": "sample-context/generated/project-raw.md",
      "collect": [
        "README.md",
        "docs/en/getting-started.md",
        "docs/en/configuration.md"
      ]
    }
  },
  "agent_rules": [
    {
      "name": "Claude",
      "path": "CLAUDE.md",
      "enabled": true,
      "_note": "Claude Code"
    },
    {
      "name": "Codex",
      "path": "AGENTS.md",
      "enabled": true,
      "_note": "OpenAI Codex"
    },
    {
      "name": "Antigravity",
      "path": "AGENTS.md",
      "enabled": true,
      "_note": "Shares this target with Codex"
    },
    {
      "name": "Cursor",
      "path": ".cursor/rules/context.mdc",
      "enabled": true,
      "_note": "Check rule activation in Cursor"
    }
  ]
}
```

Before enabling an entry, check whether its target already exists. For example, a project may already contain `AGENTS.md` or `CLAUDE.md`. Preserve and reconcile those instructions before creating a link; see [Troubleshooting](troubleshooting.md).

## Fields and defaults

The shipped `ctx.config.json` and the standalone `init` fallback use the defaults below. A shipped default is not necessarily a fallback for an omitted field: several fields are accessed directly, and there is no general configuration-schema validator.

| Field | Type | Shipped value or missing-field behavior | Effect |
| --- | --- | --- | --- |
| `source` | string | Shipped: `sample-context/AGENT_RULES.md`. Keep it present. | Shared rules file used by `sync`. Its parent directory is also the context directory used by `init`, `status`, `export`, `log`, `timeline`, `backfill`, `archive`, and hook operations. |
| `git_sync` | object | Shipped with `enabled: true` and `auto_log: true`. Missing object is read as `{}` by hook status/run. | Settings for the optional managed Git hook. A JSON setting alone does not install a hook. |
| `git_sync.enabled` | boolean | Shipped: `true`. Missing at runtime: `false`. | Allows the installed hook to run its context auto-log/local commit behavior. `false` makes that hook invocation exit without doing that work. |
| `git_sync.auto_log` | boolean | Shipped: `true`. Missing at runtime: `false`. | When the installed hook runs with `enabled: true`, records staged-file metadata and diff statistics before the main commit. It does not call an LLM or produce a semantic code summary. |
| `generate` | object | Shipped with a `project` type. Missing section makes `generate` fail. | Maps a type name to a bundle definition. The name is the exact, case-sensitive argument to `generate <type>`. |
| `generate.<type>.output` | string | Shipped `project`: `sample-context/generated/project-raw.md`. Missing or empty value makes `generate` fail. | File replaced after successful collection, preserving existing permissions. Parent directories are created as needed. This path stays unchanged when `source` changes. A symlink or other non-regular output is rejected. |
| `generate.<type>.collect` | array of strings | Shipped `project`: README, Markdown under `docs`, and files under `src`. Missing field is treated as an empty array. | Project-relative file paths or Python glob patterns. Matches are sorted within each pattern, then concatenated in pattern order. Missing matches and the output file's aliases are skipped. If no inputs remain, the command fails and preserves any existing output. |
| `agent_rules` | array of objects | Shipped with the four rows below. Keep it present, even if empty. | Registry read by `list`, `sync`, `status`, `enable`, and `disable`. |
| `agent_rules[].name` | string | Required per row; no fallback. | Display label and the name matched by `enable`/`disable`, without case sensitivity. Use distinct names: matching rows are all toggled. |
| `agent_rules[].path` | string | Required per row; no fallback. | Project-relative destination for a symlink to `source`. Multiple rows can share the same path. Do not set it to the source itself. |
| `agent_rules[].enabled` | boolean | Shipped: `true` for every row. Required per row; no fallback. | `true` requests a managed link. `false` permits removal of a link to the current source when no enabled row shares that path. |
| `agent_rules[]._note` | string | Optional. | Informational text for people editing JSON; ignored by the CLI. |
| `_comment`, `_usage` | string | Optional. | Informational metadata; ignored by the CLI. `_usage` does not change how commands are invoked. |

The default agent registrations are:

| Name | Path | Enabled |
| --- | --- | --- |
| Claude | `CLAUDE.md` | `true` |
| Codex | `AGENTS.md` | `true` |
| Antigravity | `AGENTS.md` | `true` |
| Cursor | `.cursor/rules/context.mdc` | `true` |

These rows describe the supplied registry. The shared source is ordinary Markdown. In particular, `init` does not add Cursor MDC frontmatter or activation settings to it. Cursor documents MDC Project Rules and plain `AGENTS.md` instructions as separate formats; choose the path and activation behavior using the [official Cursor rules documentation](https://prod.cursor.com/docs/rules). Check each agent's loading requirements before relying on a registration; see [Getting started](getting-started.md).

## Custom context directory

Choose the location before the first `init`. For example, this complete configuration keeps context under `.ctx-local/` and enables only the `CLAUDE.md` destination:

```json
{
  "source": ".ctx-local/AGENT_RULES.md",
  "git_sync": {
    "enabled": false,
    "auto_log": false
  },
  "generate": {
    "project": {
      "output": ".ctx-local/generated/project-raw.md",
      "collect": [
        "README.md"
      ]
    }
  },
  "agent_rules": [
    {
      "name": "Claude",
      "path": "CLAUDE.md",
      "enabled": true
    }
  ]
}
```

Then initialize with explicit choices for optional integration:

```bash
bash ctx.sh init --no-hook --no-backfill
```

Keep the `AGENT_RULES.md` basename: `init` creates that filename inside the directory derived from `source`; it does not create an arbitrary source basename. It renders new template references for the configured context directory and installed script location. It preserves existing context files rather than upgrading their contents.

Changing `source` does not move context files, migrate existing links, or rewrite any `generate.<type>.output`. Existing links to an old source can become conflicts under the new configuration. Back up and reconcile the existing installation before changing this field; see [Troubleshooting](troubleshooting.md).

## Configuration writes

`enable`, `disable`, `hook install`, and `hook uninstall` save an existing regular `ctx.config.json` by writing the complete JSON to a temporary file in the same directory, flushing and syncing it, then atomically replacing the configuration. Existing file permissions are retained. A temporary write or replacement failure exits nonzero, leaves the existing configuration unchanged, and cleans up the temporary file. A symlink or other non-regular configuration entry is rejected without changing that entry or its target.

This protects the configuration file during replacement; it does not roll back the whole command. A later `sync` failure can leave an agent flag already saved, and a failed hook operation can leave earlier hook, ignore-rule, or context-repository changes in place. Concurrent configuration edits are not locked. See [Troubleshooting](troubleshooting.md#configuration-save-fails) before retrying a failed save.

## Agent registration and link behavior

Add a row to `agent_rules`, then run `sync`. Use a distinct label; the destination must be a file path the intended tool actually reads. The CLI does not discover agent installations.

```bash
bash ctx.sh list
bash ctx.sh disable cursor
bash ctx.sh enable Cursor
bash ctx.sh sync
bash ctx.sh status
```

`enable` and `disable` update the JSON and immediately run `sync`. Name matching is case insensitive. If synchronization fails, inspect the configuration too: the enabled value has already been written.

`sync` applies these rules:

- The source file must exist. An enabled target cannot be the source itself.
- It checks all enabled destinations for conflicts before changing links or the plan's `Last Updated` field. A regular file, directory, or symlink that does not resolve to the configured source causes failure and is preserved.
- It creates missing enabled links using relative targets. Existing symlinks resolving to the source are accepted and left in place; `sync` does not replace their link text or upgrade document contents.
- If multiple rows use the same path, the link stays while at least one row is enabled. With the defaults, disabling Codex alone keeps `AGENTS.md` for Antigravity.
- When every row for a path is disabled, it removes a symlink resolving to the current source, except a link needed in the source's or an enabled rule link's resolution chain. It preserves disabled regular files and unrelated or broken unmanaged links.
- After conflict checks pass, it updates the `> Last Updated:` line in the context's `MASTER_PLAN.md`, when that file and line exist.

The date update writes to a unique temporary file in the context directory, then atomically replaces the regular `MASTER_PLAN.md`, preserving its permissions. Existing `MASTER_PLAN.md.bak` files, symlinks, and directories are left untouched. A write or replacement failure returns a nonzero status before changing agent links, preserves the existing plan and backups, and removes only this update's temporary file. A symlinked plan, including a broken link, is refused without changing the link or its target.

If this update fails, check the reported path, available space, and the context directory's write permissions, then retry `bash ctx.sh sync`. For a symlinked plan, preserve the link and target while deciding how to provide a regular `MASTER_PLAN.md`.

There is no `force`, `import`, or `doctor` command. Resolve conflicts by reviewing and backing up existing instructions, then choosing a non-conflicting target or intentionally reconciling the files. Follow [Troubleshooting](troubleshooting.md) for concrete steps.

## Source-bundle collection

Run a configured type with:

```bash
bash ctx.sh generate project
```

`generate` concatenates the selected files with headings. It does not generate a finished specification, run an LLM, or enforce a token budget. Review the output before sharing it with any model or service.

The command expands all input patterns before writing. It excludes the output itself and paths that resolve to it or share its inode, including symlink and hard-link aliases; other matching files are still collected. If no inputs remain, it reports an error on stderr and exits nonzero. Any existing output is preserved, and a missing output is not created.

The final output entry must be absent or a regular file. A symlink, including a broken one, directory, FIFO, or other non-regular entry is rejected without changing it or its target. The command writes the complete bundle to a temporary file in the output directory, flushes and syncs it, then atomically replaces the output. Existing file permissions are retained. A read, write, or replacement error before replacement exits nonzero; this run leaves the output untouched and removes its temporary file. It also stops if it detects an output change before replacement; concurrent writers are not locked.

Treat `collect` as an explicit allowlist. Glob expansion is not a security filter: it does not consult `.gitignore`, remove secrets, detect binary data, reject unrelated input symlinks, or deduplicate overlapping patterns. Prefer reviewed text files such as `README.md` and specific documentation paths. Avoid broad recursive collection of an entire project, credentials, environment files, local context history, build output, and dependency directories. Keep generated files reproducible and separate from authored documents.

## Optional Git settings

The copied configuration ships with both Git settings set to `true`, but the managed hook must also be installed for them to affect pre-commit behavior. For a manual setup, keep both values `false` and initialize with `--no-hook --no-backfill`.

`hook install` sets `git_sync.enabled` to `true`. It sets `auto_log` to `true` only when that field is missing, so an explicit `false` remains `false`. It also installs the hook, configures context Git exclusion when needed, and initializes a separate local context repository. Review [Workflows](workflows.md) before opting in. `hook uninstall` restores the saved original hook, or removes the managed wrapper if there was no original, and sets `enabled` to `false`; it does not remove the local context repository or exclusion rule. A modified wrapper, conflicting backup, or missing required backup causes an error instead of overwriting hook files.

## Validate and apply changes

Validate JSON syntax before applying a configuration:

```bash
python3 -m json.tool ctx.config.json > /dev/null
bash ctx.sh list
bash ctx.sh sync
bash ctx.sh status
```

`json.tool` validates JSON syntax, not ctx field types, path safety, or agent compatibility. `list` shows configured flags. `status` shows source existence and link state; its linked indicator does not verify that a link resolves to the configured source or that an agent loaded it. Use `sync` to check enabled-target conflicts, and inspect the actual link target when investigating a mismatch.

After changing rules or registrations, start a new agent session or use the agent's supported reload/re-read mechanism. A changed file on disk does not prove an already-running session has refreshed its instructions. See [Workflows](workflows.md) for daily use and [Troubleshooting](troubleshooting.md) for conflicts or missing context.
