# ctx-kit

Keep project decisions, progress, and next actions available when you switch AI coding agents.

[한국어](README.ko.md) · [Getting started](docs/en/getting-started.md) · [Configuration](docs/en/configuration.md) · [Workflows](docs/en/workflows.md) · [Troubleshooting](docs/en/troubleshooting.md) · [Contributing](CONTRIBUTING.md)

ctx-kit is a small Bash CLI backed by Python's standard library. It creates editable project context, links instruction-file paths to one rules file, and records work units in a local JSONL timeline. It makes no LLM API calls and needs no API key or hosted service.

Use it when a new session needs to know **what was decided, what changed, what was verified, and what comes next**. The files travel between tools; the agent still has to read and follow them.

## Quick start

Requires Bash, Python 3.7 or later, and standard Unix tools. Git is needed to clone this repository and use Git integration. CI runs on Linux and macOS with Python 3.11; macOS verification includes Apple Silicon and Bash 3.2. Windows needs Git Bash, Python, and symlink creation permission; see [Windows installation](docs/en/getting-started.md#windows).

The CLI checks `python3`, `python`, then `py -3` on `PATH`, selecting the first that runs and reports Python 3.7+. Prefer a maintained Python 3 release. If none qualifies, commands fail with an explanation; `init` checks before creating configuration or context files. `help` and `version` work without Python. See [Python diagnostics](docs/en/troubleshooting.md#python-git-or-the-script-cannot-be-found) if detection fails.

Try a **new demo directory** first. Run this from a directory without an existing `ctx-kit` or `ctx-demo`:

```bash
git clone https://github.com/nemory-dev/ctx-kit.git
mkdir ctx-demo
cp ctx-kit/ctx.sh ctx-kit/ctx.config.json ctx-demo/
cd ctx-demo
bash ctx.sh init --no-hook --no-backfill
bash ctx.sh status
```

This creates `sample-context/` and the configured rule links. The flags skip Git hook installation and history import. For an existing project, follow the [existing-project procedure](docs/en/getting-started.md#existing-projects) to preserve its configuration and rules.

Record and read back the setup:

```bash
bash ctx.sh log --summary "Initialized ctx-kit demo; checked rule links" --files "sample-context/AGENT_RULES.md,sample-context/MASTER_PLAN.md"
bash ctx.sh timeline --limit 1 --json
```

The entry contains that summary and those file paths. Edit the generated project-name, stack, current-state, and next-action placeholders before using the context with an agent.

## How the context fits together

```text
project/
├── ctx.sh
├── ctx.config.json
├── CLAUDE.md ─────────────────┐
├── AGENTS.md ─────────────────┼──> sample-context/AGENT_RULES.md
├── .cursor/rules/context.mdc ─┘
└── sample-context/
    ├── MASTER_PLAN.md              current state and next actions
    ├── decisions.md                architecture decisions and reasons
    ├── backlog.md                  ideas and open questions
    ├── work-log/timeline.jsonl      records created by log/backfill/hook
    ├── work-log/timeline-digest.md  archived titles created by archive
    └── archive/                    completed tasks, retired decisions, monthly logs
```

The context directory comes from `source` in `ctx.config.json`. Plan and decision files are edited by you or an authorized agent. `sync` maintains links and refreshes the plan date; it does not infer progress or upgrade customized rule content.

The rules ask agents to read current context at session start, update affected context after authorized changes, and verify their `log` entry at closure. These are instructions, not automatic enforcement. The [workflow guide](docs/en/workflows.md) covers the sequence and what the Git hook actually records.

## Storage and sharing

- **Existing rules are preserved.** `init`/`sync` report conflicts with ordinary files or unrelated links. They do not merge instructions for you. See [conflict recovery](docs/en/troubleshooting.md).
- **Storage is local, but privacy needs configuration.** `--no-hook` also skips automatic Git exclusion. Hook installation adds or recognizes a context exclusion, but already tracked files remain tracked. Check [local Git exclusions](docs/en/getting-started.md#local-git-exclusions) before committing; generated links can otherwise point teammates at a missing private directory.
- **Review text before sharing.** `generate` does not apply `.gitignore` or scan for secrets. `export --all` adds archived task/decision Markdown, not monthly log files. There is no fixed token-saving guarantee. See [export and collection](docs/en/workflows.md).

Work-log writes use a shared lock and atomic file replacement. Archive records pending writes in a recovery journal before removing source content. Interrupted operations recover before the next context write; unexpected external edits cause an error instead of being overwritten. [Recovery details](docs/en/troubleshooting.md) explain how to preserve and inspect affected files.

## Commands

Run commands from the project root. If installed under `scripts/`, use `bash scripts/ctx.sh` instead.

| Command | Purpose |
| --- | --- |
| `bash ctx.sh init --no-hook --no-backfill` | Create missing context templates and rule links |
| `bash ctx.sh status` | Display the plan summary and link status |
| `bash ctx.sh sync` | Check conflicts, maintain links, and refresh the plan date |
| `bash ctx.sh list` | List configured agents |
| `bash ctx.sh enable Cursor` / `disable Cursor` | Change an agent setting and run sync |
| `bash ctx.sh log --summary "..."` | Record a work unit; `record` is an alias |
| `bash ctx.sh timeline --limit 20` | Read active timeline entries |
| `bash ctx.sh backfill --limit 30` | Import recent Git commits into the active timeline |
| `bash ctx.sh archive --keep 30` | Archive completed tasks, retired decisions, and older logs |
| `bash ctx.sh export` | Print selected context for review and manual sharing |
| `bash ctx.sh generate project` | Combine files selected by `generate.project.collect` |
| `bash ctx.sh hook install` | Opt into pre-commit logging and local context snapshots |
| `bash ctx.sh hook status` / `hook uninstall` | Inspect or remove ctx-kit's hook integration |
| `bash ctx.sh version` / `help` | Show the script version or command overview |

Flags, verification commands, and limitations are in [Workflows](docs/en/workflows.md). `status` is a display command, not a CI health check: inspect its output and verify the actual link targets.

## Agent instruction files

The shipped configuration enables these paths. A linked file alone is not proof that an agent loaded or obeyed it.

| Agent | Configured path | Loading notes |
| --- | --- | --- |
| Claude Code | `CLAUDE.md` | Kept for compatibility; newer versions also support `AGENTS.md` under documented conditions. [Official docs](https://code.claude.com/docs/en/memory) |
| Codex | `AGENTS.md` | Guidance is discovered at startup; start a new session after changing instructions. [Official docs](https://learn.chatgpt.com/docs/agent-configuration/agents-md) |
| Antigravity | `AGENTS.md` | Shares the configured path with Codex. [Official docs](https://antigravity.google/docs/rules) |
| Cursor | `.cursor/rules/context.mdc` | The template has no MDC activation frontmatter. Cursor also supports the generated `AGENTS.md`; verify loading rather than assuming always-on MDC behavior. [Official docs](https://prod.cursor.com/docs/rules) |

Loading notes were checked against official documentation on 2026-10-24. For other agents, add a path to `agent_rules` and verify that tool's requirements. [Configuration](docs/en/configuration.md) explains shared paths and custom context directories.

## Related tools

| Need | Starting point |
| --- | --- |
| Generate or import configuration across many coding tools | [Rulesync](https://github.com/dyoshikawa/rulesync) |
| Distribute centralized and directory-scoped agent rules | [Ruler](https://github.com/intellectronica/ruler) |
| Package repository content with token reporting and security checks | [Repomix](https://repomix.com/guide/) |
| Keep a small, editable record of decisions, work units, and next actions across sessions | ctx-kit |

## Documentation

| Guide | What you can do |
| --- | --- |
| [Getting started](docs/en/getting-started.md) | Install in new or existing projects, use `scripts/` or Windows, verify setup |
| [Configuration](docs/en/configuration.md) | Set paths, agents, collection rules, and Git options |
| [Workflows](docs/en/workflows.md) | Start and close work, inspect logs, archive, share, and update an installation |
| [Troubleshooting](docs/en/troubleshooting.md) | Resolve conflicts, loading problems, Git limitations, and interrupted writes |
| [Contributing](CONTRIBUTING.md) | Validate locally, open a PR, satisfy required CI, merge, and verify the main push |

Each guide links its Korean counterpart at the top. These documents describe the source in this checkout; use documentation and `ctx.sh` from the same revision.

## Development and contribution

No additional test dependencies are required:

```bash
bash -n ctx.sh
python3 -B -m unittest discover -s tests -v
git diff --check
```

Tests use temporary projects to cover initialization, rule preservation, recording, concurrent writers, archive failures, and recovery. They do not run AI models or prove instruction compliance. Windows execution has not been verified in the current macOS test environment.

Keep the root `AGENT_RULES.md` and the embedded template in `ctx.sh` aligned. The embedded copy lets users install by copying only the script and configuration; initialization tests check for drift.

[CI](.github/workflows/ci.yml) runs the Bash syntax check and full unittest command above on every PR and `main` push, including documentation changes. Each run uses Python 3.11 on `ubuntu-latest` and `macos-latest`.

Changes to this repository's `main` must go through a PR, including administrator changes. Both GitHub Actions checks are required:

- `Regression tests (ubuntu-latest)`
- `Regression tests (macos-latest)`

The PR must include the latest `main` changes. Force pushes and deletion of `main` are disabled. Required approving reviews are set to **0**; the PR and both CI results remain mandatory. These protection settings live in GitHub and are configured separately from the workflow file.

Use a work branch, run local checks, push only reviewed files, and open a PR targeting `main`. Verify both required checks before merging and the separate `main` push CI afterward. [The contribution guide](CONTRIBUTING.md) provides commands for this flow, forks, updating an outdated PR, and branch cleanup.

## License

MIT
