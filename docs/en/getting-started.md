# Get started with ctx-kit

[한국어](../ko/getting-started.md) · [README](../../README.md) · [Configuration](configuration.md) · [Workflows](workflows.md) · [Troubleshooting](troubleshooting.md)

Create a small working context, record a work unit, and verify that another session can read it. Start with a new demo directory before adopting an existing project.

## Prerequisites

| Tool | Why it is needed |
| --- | --- |
| Bash and standard Unix tools | Run `ctx.sh`, create links, and read/edit text files. On Windows, use Git Bash. |
| Python 3.7 or later | Parse JSON and manage logs. Use a maintained Python 3 release; 3.7 is the code baseline, not an installation recommendation. |
| Git | Clone this repository, import commit history, or enable local context snapshots. A project can initialize context without its own Git repository. |

```bash
bash --version
python3 --version
git --version
```

The CLI tries `python3`, `python`, then `py -3` from `PATH`. It runs each candidate and checks `sys.version_info >= (3, 7)`, skipping missing, unlaunchable, or older candidates. The first valid candidate is used for that command. If none works, it exits nonzero with an explanation; `init` validates Python before creating configuration or context files. `help` and `version` do not require Python. No private runtime location is searched.

The standalone Python examples in these guides use `python3`. If your valid candidate is `python` or `py -3`, use that command instead, including with `-m json.tool`. Use [Python diagnostics](troubleshooting.md#python-git-or-the-script-cannot-be-found) to check the candidates in the same shell.

Current verification uses macOS Apple Silicon, Bash 3.2.57, Python 3.11.8, and Git 2.42.0. Linux uses the same Bash commands. Windows setup is described below; it has not been execution-tested in this macOS environment. No Node.js, pip package, LLM API key, or running server is needed.

## 1. Create a demo

Run from a directory without an existing `ctx-kit` or `ctx-demo`. If you already have this checkout, use its `ctx.sh` and configuration instead of cloning another copy. Keep the script and documentation at the same revision.

```bash
git clone https://github.com/nemory-dev/ctx-kit.git
mkdir ctx-demo
cp ctx-kit/ctx.sh ctx-kit/ctx.config.json ctx-demo/
cd ctx-demo
bash ctx.sh init --no-hook --no-backfill
bash ctx.sh status
```

The first command installs nothing globally. The copy places the CLI in the demo project. `init` creates missing templates under `sample-context/` and links the enabled agent paths to `sample-context/AGENT_RULES.md`.

The explicit flags leave Git integration for a separate step:

- `--no-hook`: do not install a Git hook or configure its context exclusion/local Git repository.
- `--no-backfill`: do not import old commits.

Plain `init` can ask about history and hooks in a normal Git repository; hook installation defaults to yes. Use the explicit flags for a predictable setup in scripts and CI. `--hook` and `--backfill` explicitly opt into hook installation and importing the latest 30 commits; use them only after reviewing the Git integration below. These integration choices apply when the project has a normal `.git/` directory.

## 2. Verify and personalize the context

Inspect the source and each generated link from the demo root:

```bash
test -f sample-context/AGENT_RULES.md
readlink CLAUDE.md
readlink AGENTS.md
readlink .cursor/rules/context.mdc
bash ctx.sh list
```

For the default installation, `CLAUDE.md` and `AGENTS.md` point to `sample-context/AGENT_RULES.md`; the Cursor link points to `../../sample-context/AGENT_RULES.md`. Paths differ when you customize the context directory. `status` reports link existence, not whether a tool loaded the instructions or whether every link has the intended target.

Edit these files with your editor:

| File | Replace or add |
| --- | --- |
| `sample-context/AGENT_RULES.md` | Project name, phase, stack, and project-specific constraints in Project Context |
| `sample-context/MASTER_PLAN.md` | Actual Current State and a small set of Next Actions |
| `sample-context/decisions.md` | Project name; record only decisions actually adopted |
| `sample-context/backlog.md` | Project name and authorized ideas/open questions |

The generated rules are based on [AGENT_RULES.md](../../AGENT_RULES.md). They ask an agent to read context and verify closure; the CLI does not force an AI model to follow those instructions. Start a new agent session and explicitly ask it to read `sample-context/AGENT_RULES.md` and the referenced context files. Confirm its state summary against `MASTER_PLAN.md`.

## 3. Record and read back one work unit

```bash
bash ctx.sh log --summary "Initialized ctx-kit demo; checked rule links" --files "sample-context/AGENT_RULES.md,sample-context/MASTER_PLAN.md"
bash ctx.sh timeline --limit 1 --json
```

`log` creates `sample-context/work-log/timeline.jsonl`. Verify the returned JSON entry has the summary and file paths you supplied; IDs and timestamps vary. With concurrent writers, increase `--limit` until you find your entry. The full daily sequence is in [Workflows](workflows.md).

<a id="existing-projects"></a>
## Existing projects

Preserve existing settings and instructions before changing an established repository. All following `/path/to/...` locations are placeholders: replace them with your actual paths.

1. Copy the CLI and configuration without silently overwriting an existing installation:

   ```bash
   cp -i "/path/to/ctx-kit/ctx.sh" "/path/to/project/"
   cp -i "/path/to/ctx-kit/ctx.config.json" "/path/to/project/"
   cd "/path/to/project"
   ```

   If a destination already exists, decline replacement until you have compared it. Reuse your project's configured `source`, agents, and collection rules.

   Interpreter and project paths, plus configured context, agent, and collection paths, support spaces, Unicode, and apostrophes. Wrap shell paths in double quotes, for example `cd "/path/to/team's project"`; see [path rules](configuration.md#prerequisites-and-path-rules).

2. Inspect `ctx.config.json` and any rule files already in use:

   ```bash
   python3 -m json.tool ctx.config.json
   ls -ld CLAUDE.md AGENTS.md .cursor/rules/context.mdc
   ```

   Missing rule paths are normal; `ls` may report them. Also inspect any extra paths in `agent_rules`. Back up existing rule content and the configured context directory to a private location before merging instructions. A symlink is a pointer: read its target before moving anything.

3. Choose a context directory **before first initialization**. The default is `sample-context/AGENT_RULES.md`. To use `.ctx-local/AGENT_RULES.md`, edit `source` and the matching `generate.*.output` paths in the existing configuration. See the complete example in [Configuration](configuration.md). Do not replace the entire config with a partial example.

4. Initialize without automatic Git changes:

   ```bash
   bash ctx.sh init --no-hook --no-backfill
   ```

   If an enabled rule path contains an ordinary file, unrelated link, or directory, initialization reports a conflict and preserves it. Missing context templates may already have been created before the link check. Resolve each conflict explicitly:

   - Keep the existing entry point and disable the corresponding ctx-kit agent setting. For a shared `AGENTS.md`, disable both Codex and Antigravity rows if neither should be managed.
   - Or compare and merge the existing instructions into the configured source, verify your private backup, and move the conflicting entry out of the target path before running `init` again. Preserve project-specific constraints; do not replace customized rules wholesale.

   There is no `--force` or automatic import/merge command. A failed `enable`/`disable` sync can leave its configuration change saved; inspect both the config and file state before retrying.

5. Run `status`, inspect the actual links as in step 2 of the demo, then configure exclusions before your next project commit. Ordinary `init` preserves existing context files, and `sync` does not upgrade their text. Changing `source` on an existing installation does not move files or retarget old links automatically.

See [Troubleshooting](troubleshooting.md) for conflicts and context relocation. See [Workflows](workflows.md) for updating an existing installation.

## Install under scripts/

The CLI recognizes a directory named exactly `scripts` as one level below the project root. Configuration stays at the project root. For a new target project, run from the directory that contains `ctx-kit`:

```bash
mkdir ctx-scripts-demo
mkdir ctx-scripts-demo/scripts
cp ctx-kit/ctx.sh ctx-scripts-demo/scripts/
cp ctx-kit/ctx.config.json ctx-scripts-demo/
cd ctx-scripts-demo
bash scripts/ctx.sh init --no-hook --no-backfill
bash scripts/ctx.sh log --summary "Verified scripts installation" --files "scripts/ctx.sh"
bash scripts/ctx.sh timeline --limit 1 --json
```

Generated rule commands use `bash scripts/ctx.sh`. Arbitrary directories such as `tools/` are not resolved as project-root installations. Keep the documented root or `scripts/` layout.

<a id="local-git-exclusions"></a>
## Local Git exclusions

Skipping the hook does not add an ignore rule. In a Git project, first decide which files are personal and which the team intentionally shares. For an entirely personal default context and generated links, these **project-root** commands add local exclusions:

```bash
CTX_EXCLUDE_PATH=$(git rev-parse --git-path info/exclude)
printf '\n# Personal ctx-kit context and generated links\n/sample-context/\n/CLAUDE.md\n/AGENTS.md\n/.cursor/rules/context.mdc\n' >> "$CTX_EXCLUDE_PATH"
git check-ignore -v sample-context/AGENT_RULES.md
git ls-files -- sample-context/
git status --short
```

Use your real context and target paths if customized. `git ls-files -- sample-context/` should print nothing for a private, untracked context. Ignore rules do not remove tracked files or earlier commits; if paths are listed, stop and agree on a tracking/migration policy before sharing. Do not remove team-owned rules just to adopt this demo.

If the team shares rule links, their source files must be available to teammates too. A committed symlink pointing into your ignored personal directory will be broken in a fresh clone. `.git/info/exclude` is local to the repository; `.gitignore` is appropriate for exclusions the team wants to share. Hook installation excludes the context directory, not every generated link.

To opt into the hook later, first check your Git identity and existing hook configuration:

```bash
git var GIT_AUTHOR_IDENT
git config --get core.hooksPath
```

The second command normally prints nothing and exits 1 when unset. The installer currently requires a normal `.git/` directory and writes `.git/hooks/pre-commit`; worktrees and custom hook paths need the [Git limitations](troubleshooting.md). Once you have checked that setup:

```bash
bash ctx.sh hook install
bash ctx.sh hook status
```

This initializes a separate local Git repository inside the context directory, configures context exclusion, and enables Git sync. It can create local context commits. It does not push them. See [Workflows](workflows.md) for pre-commit behavior and disabling the integration.

## Windows

Install Git for Windows and a maintained Python 3 version, then ensure Git Bash can run it as `python3`, `python`, or through the Python launcher `py -3`. The CLI validates these candidates in that order and requires Python 3.7+. A Python installation visible only in a different terminal is insufficient. Allow symlink creation in Windows; if link creation fails, follow [Windows troubleshooting](troubleshooting.md). The CLI has no automatic copy fallback for symlinks.

For a new demo in PowerShell, from a directory without those two target directories:

```powershell
git clone https://github.com/nemory-dev/ctx-kit.git
New-Item -ItemType Directory -Path ctx-demo
Copy-Item -Path .\ctx-kit\ctx.sh,.\ctx-kit\ctx.cmd,.\ctx-kit\ctx.config.json -Destination .\ctx-demo\
Set-Location .\ctx-demo
.\ctx.cmd init --no-hook --no-backfill
.\ctx.cmd status
.\ctx.cmd log --summary "Initialized Windows demo" --files "ctx.config.json"
.\ctx.cmd timeline --limit 1 --json
```

`ctx.cmd` requires Git Bash; it is a wrapper, not a native PowerShell implementation. Copy it **next to `ctx.sh`**. For a `scripts/` installation, put both files in `scripts/`, keep the config at the project root, and invoke `.\scripts\ctx.cmd` from the project root. In CMD, use `ctx.cmd status`; in Git Bash, use the Bash commands above. If your Git Bash or Python installation is not discoverable by the wrapper, use the diagnostic steps in [Troubleshooting](troubleshooting.md).

## What you built

You now have a shared rules source, editable state/decision/backlog files, and a recorded work unit that another session can read. Continue with [Configuration](configuration.md) to adjust paths, [Workflows](workflows.md) for daily use, or [Troubleshooting](troubleshooting.md) if verification failed.
