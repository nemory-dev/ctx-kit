# Troubleshooting and recovery

[한국어](../ko/troubleshooting.md) · [README](../../README.md) · [Getting started](getting-started.md) · [Configuration](configuration.md) · [Workflows](workflows.md)

Run the Bash examples from your project root. They assume `ctx.sh` is there and `source` is `sample-context/AGENT_RULES.md`. For a `scripts/` installation, use `bash scripts/ctx.sh`; replace `sample-context` with your configured context directory. The CLI finds the project from the script location, not your current directory.

## Preserve the current state first

Before editing logs, moving conflicting files, or reconciling an interrupted archive, stop context writers and make a private backup outside the project. The context may contain private project details, and the recovery journal contains complete pending file contents.

```bash
ctx_backup="$(mktemp -d "$HOME/ctx-kit-recovery.XXXXXX")"
cp -p ctx.config.json "$ctx_backup/"
cp -R sample-context "$ctx_backup/context"
printf 'Private backup: %s\n' "$ctx_backup"
```

Use a private local destination; copy only files that exist if initialization is incomplete. Keep the backup until recovery is verified. Do not paste the whole context or journal into a public issue.

## Python, Git, or the script cannot be found

| Symptom | Cause | Safe repair and verification |
| --- | --- | --- |
| `Error: Python 3.7 or newer is required.` | None of the `PATH` candidates `python3`, `python`, or `py -3` can run and pass the version probe. A candidate can be missing, unlaunchable, or too old. | Install a maintained Python 3 release or expose an existing installation on `PATH` in the same shell. Candidates are checked in order, and invalid candidates are skipped. Use the diagnostics below before retrying. |
| `git: command not found` or Git integration fails | Git is unavailable in that shell. Some commands suppress Git errors, so an empty Git field is not proof that Git works. | Check `command -v git` and `git --version`; make your existing Git executable available through `PATH` before retrying Git features. |
| `bash: ctx.sh: No such file or directory` | Wrong invocation path, or the CLI was copied to another directory. | Keep `ctx.sh` at the project root or in a directory named exactly `scripts`, then invoke that path. The standalone file includes its storage helpers; copying only `ctx.sh` is supported. |

```bash
command -v python3
python3 -c "import sys; print(sys.executable); print(sys.version); sys.exit(sys.version_info < (3, 7))"
command -v python
python -c "import sys; print(sys.executable); print(sys.version); sys.exit(sys.version_info < (3, 7))"
command -v py
py -3 -c "import sys; print(sys.executable); print(sys.version); sys.exit(sys.version_info < (3, 7))"
command -v git
git --version
bash --version
```

A missing or unlaunchable candidate returns nonzero; the version probes also return nonzero for Python older than 3.7. These failures are expected when another candidate is usable. The CLI selects the first passing candidate and uses it throughout the command. If all candidates fail, it explains the requirement and exits nonzero. `init` performs this check before creating configuration or context files; `help` and `version` work without Python.

For an installed Python outside `PATH`, add its executable's directory in the shell that runs ctx-kit, for example `export PATH="/path/to/Python directory:$PATH"` after replacing the placeholder. Keep the double quotes for spaces or apostrophes. If every candidate is too old, install a maintained Python 3 release and update `PATH`; the minimum remains 3.7. The CLI searches only these `PATH` candidates and has no private runtime fallback.

The standalone Python examples below use `python3`; substitute your passing `python` or `py -3` command if needed. The regression suite is verified on macOS with Bash 3.2 and Python 3.11.8; actual Windows execution has not been verified here. CI runs with Python 3.11 on Linux and macOS. The Python 3.7 baseline is not a claim that the suite was run on every later version.

## Missing or malformed configuration

`Error: ctx.config.json not found.` refers to the project root selected by the script location. A script in an arbitrary tools directory will look for configuration there. Move the standalone CLI to the supported root or `scripts/` location before creating another configuration by mistake.

For a new setup, follow [Getting started](getting-started.md). For an existing setup, recover your known configuration instead of overwriting it. Validate JSON without printing its contents:

```bash
python3 -m json.tool ctx.config.json >/dev/null
```

`JSONDecodeError` usually means invalid JSON, such as a trailing comma. `KeyError: 'source'` or `KeyError: 'agent_rules'` means a required field is absent; valid JSON alone does not validate configuration structure. Compare the fields with [Configuration](configuration.md), edit a backed-up copy, and rerun `bash ctx.sh status`.

`init` derives the context directory from `source`, but creates the rules template with the fixed basename `AGENT_RULES.md`. A custom directory such as `.ctx-local/AGENT_RULES.md` works; setting `source` to `.ctx-local/team-rules.md` does not make `init` create that filename. Either use the supported basename or deliberately prepare your existing source before `sync`.

Project and interpreter paths, configured context and agent paths, and collected filenames support spaces, Unicode, and apostrophes. Quote shell paths with double quotes, for example `bash "/path/to/team's project/ctx.sh" status`. In JSON, use ordinary double-quoted strings, such as `"source": "team's context/AGENT_RULES.md"`; an apostrophe needs no JSON escape. Check quoting and the actual configured paths when diagnosing a missing file. If an older copied CLI still reports a Python syntax error for such a path, update `ctx.sh` and use documentation from the same revision.

## Rules conflict, are missing, or point to the wrong source

`Conflict: ... already exists and is not a ctx-managed symlink` protects an existing regular file, directory, unrelated symlink, or broken unrelated symlink. `sync` checks all enabled targets before changing links or the plan's date. An initial `init` may already have created templates before reaching this conflict.

Inspect the configured source and the actual target before making changes:

```bash
python3 - <<'PY'
import json
from pathlib import Path

root = Path.cwd()
config = json.loads((root / "ctx.config.json").read_text(encoding="utf-8"))
source = root / config["source"]
print("Expected source:", source.resolve())
print("Source is a file:", source.is_file())
for agent in config["agent_rules"]:
    if str(agent["enabled"]).lower() != "true":
        continue
    target = root / agent["path"]
    print(agent["path"], "symlink:", target.is_symlink(),
          "file:", target.is_file(), "resolves to:", target.resolve(),
          "matches source:", target.resolve() == source.resolve())
PY
readlink CLAUDE.md
readlink AGENTS.md
```

The Python check diagnoses paths; `is_file()` checks existence/type rather than a full permissions test. `readlink` returns nonzero for a regular or missing file. Compare the resolved path with the configured source, then inspect the rules content locally.

Choose a repair that preserves existing rules:

1. Back up the conflicting entry and its intended target. Merge any instructions you still need into the configured source.
2. Move or rename only the reviewed conflicting entry to a safe location, or change/disable its `agent_rules` entry in the configuration. Do not delete the context directory or source to clear a link conflict.
3. Run `bash ctx.sh sync`, then rerun the diagnostic above and `bash ctx.sh status`.

`target is the configured source file` requires a different agent target path. Disabling one of Codex/Antigravity does not remove their shared `AGENTS.md` while the other remains enabled. A source can itself be a symlink; preserve its link chain while inspecting it.

A green `status` line only establishes that a symlink currently resolves to a file. It does **not** establish that it resolves to the configured source. `status` can also exit 0 while reporting a missing source or broken targets; use the explicit comparison above.

After a fresh clone, tracked agent symlinks can be broken because the local context directory is ignored and was never shared. Set up your local context with `init --no-hook --no-backfill`, review the generated placeholders, then `sync`. If there are existing rules or a custom source, use the preservation procedure first. A shared symlink does not distribute the private file it points to; agree on whether your team shares source rules or initializes them locally.

## Links are correct but an agent does not use the rules

First check the resolved link and actual rules content using the diagnostic above. Rule discovery, file precedence, and automatic loading differ by tool; see [Configuration](configuration.md). Start a new Codex session after updating instructions so it rebuilds its instruction chain ([Codex instruction discovery](https://learn.chatgpt.com/docs/agent-configuration/agents-md)). For Cursor, check whether your `.mdc` rule has the metadata needed for the intended activation mode ([Cursor rules](https://prod.cursor.com/docs/rules)); a file appearing in the rules directory does not establish that it activated. Confirm the effective instructions inside the agent before relying on them.

## Hook installation succeeds but commits do not sync

Inspect the Git layout and settings before running `hook install`:

```bash
git rev-parse --show-toplevel
git rev-parse --git-dir
git config --get core.hooksPath
bash ctx.sh hook status
```

`git config --get core.hooksPath` prints nothing and exits 1 when unset. That result is normal. Inspect your effective `pre-commit` file locally before changing it.

| Finding | Meaning and safe next step |
| --- | --- |
| `.git` is a file, as in a Git worktree | The installer requires a `.git` **directory**, so it can report `.git not found` inside a valid worktree. Use manual `log`/`backfill` workflows; have the repository owner review any hook integration with the real Git directory. |
| `core.hooksPath` is set | The installer and `hook status` use `.git/hooks/pre-commit` and do not honor that setting. An “Installed” label does not prove Git runs that file. Integrate through your existing hook system after reviewing it. |
| An older inline hook exits before ctx-kit runs | Run `bash ctx.sh hook install` with the updated CLI to migrate the known inline block to a wrapper. It runs an executable saved original first; a nonzero exit still blocks the commit and skips ctx-kit. |
| Modified wrapper, backup collision, or missing original backup | Preserve `.git/hooks/pre-commit` and `.git/hooks/pre-commit.ctx-kit-original` if present. Installation/removal refuses unsafe replacement; inspect the reported files and recover the intended original before retrying. Do not delete a backup to bypass the error. |
| The hook cannot find the CLI | The installed wrapper checks only root `ctx.sh` and `scripts/ctx.sh`. Restore one of those supported locations. |
| `Author identity unknown` or local Git commit failure | The context has its own Git repository, and the initial local commit failure can be suppressed by installation. Inspect the identity available to that repository below; configure the intended identity yourself before retrying. |

```bash
git -C sample-context config --get user.name
git -C sample-context config --get user.email
git -C sample-context status --short
git -C sample-context log -1 --oneline
```

Unset identity fields return 1, and a repository without a commit makes `git log` fail. Installation modifies `.gitignore`, configuration, the context Git repository, and the hook; it is not a read-only repair. Review your layout before reinstalling. A failed context write or local commit can also block the outer Git commit; repair the reported cause and inspect the timeline before retrying, because an auto-log may already have been recorded.

## “Ignored” does not prove context is private

Ignore rules prevent new untracked files from being added normally. They do not untrack files already in the main repository, remove old commits, or prevent forced/manual staging.

```bash
git ls-files -- sample-context
git check-ignore -v sample-context/AGENT_RULES.md
git diff --cached --name-only
```

Use the actual context path. Any output from `git ls-files` deserves review before pushing. A directory-only `git check-ignore` check or the green hook status message is insufficient. `git check-ignore` may print nothing and exit 1 for an already tracked file. Review the tracked files, staged changes, and team sharing policy before choosing what to untrack; do not apply a blanket removal command. If private material was already pushed, ignoring it now does not remove it from history.

Tracked agent symlinks and ignored context are separate decisions: a symlink stores its target path in Git. Review both the source sharing policy and the checkout behavior on each supported platform.

## Invalid JSONL, permission errors, or a failed log

Writers reject malformed JSONL with a filename and line number, for example `invalid JSON at line 2` or `expected a JSON object at line 1`. Each nonblank line must be a JSON object. `null`, arrays, and strings are invalid records. Blank lines are ignored; a valid last record without a trailing newline is supported.

Stop writers, back up the context, and inspect the indicated line in a local editor. Restore a known valid record or make a reviewed correction from original evidence. Do not silently drop invalid rows, invent replacement history, or truncate the file. `archive` also validates existing monthly archives; the problem may be in `archive/timeline-YYYY-MM.jsonl` rather than the hot log.

This read-only check validates object-per-line syntax for the hot log and monthly archives without printing record contents:

```bash
python3 - <<'PY'
import json
from pathlib import Path

root = Path("sample-context")
paths = [root / "work-log/timeline.jsonl"]
paths += sorted((root / "archive").glob("timeline-*.jsonl"))
failed = False
for path in paths:
    if not path.exists():
        continue
    with path.open(encoding="utf-8") as stream:
        for number, line in enumerate(stream, 1):
            if not line.strip():
                continue
            try:
                entry = json.loads(line)
                if not isinstance(entry, dict):
                    raise ValueError("expected a JSON object")
            except ValueError as error:
                print(f"{path}: line {number}: {error}")
                failed = True
raise SystemExit(1 if failed else 0)
PY
bash ctx.sh timeline --limit 20 --json
```

Object syntax is not a full validation of every record field. `timeline` may report a traceback for malformed data; run it directly because `export` suppresses its errors.

`Refusing to replace non-regular file`, `Permission denied`, or an I/O error requires inspecting the exact path, permissions, and available storage. A directory or symlink at a log/destination path is intentionally not replaced by the atomic writer. Preserve it and resolve the file-type conflict deliberately. Do not make the entire project world-writable.

A command can fail after a log entry has been persisted, for example while creating its companion README or committing local context. Before retrying `log` or a Git commit, inspect the timeline for the entry you intended to record. A successful retry of a new work unit receives a new ID and can duplicate the intended event.

## Writer lock timeout

`Timed out waiting for context writer lock: .../.ctx.lock` means another writer held the lock for the 30-second wait. The `.ctx.lock` file normally remains after commands complete; its presence alone does not mean a lock is held.

Wait for the other operation or stop it normally. On macOS, `lsof sample-context/work-log/.ctx.lock` can help identify a process using the file. Do not remove an active lock file: another writer could lock a replacement file and bypass mutual exclusion. Retry only after writers have stopped, and inspect the timeline if the previous command may have appended a record. A pre-commit hook uses the same lock and may block a commit on this error.

## Interrupted archive and recovery journal

`work-log/.ctx-archive-transaction.json` records a pending archive transaction. Every context writer using the shared storage helper attempts recovery under the lock before doing its own work, including `log`, `backfill`, `archive`, and hook writes. Read-only commands such as `timeline` do not perform that recovery.

If only the archive was interrupted and no files were manually changed, preserve a backup, fix the underlying permission/storage failure, then rerun the intended operation. You may see `Recovered interrupted archive transaction.` The transaction completes the pending file replacements before the new operation proceeds. Verify the hot log, relevant monthly archives, digest, completed tasks, and decisions against your backup.

`Cannot recover archive: file changed outside the pending transaction` means a current file matches neither its recorded **before** hash nor its intended **after** hash. Recovery stops to preserve that unexpected edit. Invalid journals, unsafe paths, or a symlinked journal are also rejected. Do not delete or edit the journal to force a retry; there is no `recover`, `repair`, or reset CLI command.

With writers stopped and a private backup made, this read-only inspection prints paths and hashes rather than pending content:

```bash
python3 - <<'PY'
import hashlib
import json
from pathlib import Path

root = Path("sample-context").resolve()
journal = root / "work-log/.ctx-archive-transaction.json"
if journal.is_symlink():
    raise SystemExit("Refusing to inspect a symlinked journal")
pending = json.loads(journal.read_text(encoding="utf-8"))
if not isinstance(pending, dict) or not isinstance(pending.get("writes"), list):
    raise SystemExit("Invalid journal structure")
print("version:", pending.get("version"), "records:", len(pending["writes"]))
for index, record in enumerate(pending["writes"], 1):
    if not isinstance(record, dict) or not isinstance(record.get("path"), str):
        print(index, "invalid path record")
        continue
    relative = Path(record["path"])
    target = root / relative
    try:
        target.resolve().relative_to(root)
    except ValueError:
        print(index, "path outside context; stop")
        continue
    if relative.is_absolute() or target.is_symlink():
        print(index, "unsafe path; stop")
        continue
    after = record.get("after")
    after_hash = hashlib.sha256(after.encode("utf-8")).hexdigest() if isinstance(after, str) else "invalid"
    current = hashlib.sha256(target.read_bytes()).hexdigest() if target.is_file() else None
    print(index, repr(record["path"]), "before:", record.get("before"),
          "current:", current, "after:", after_hash)
PY
```

For a conflict, reconcile the backup, the external edit, and the pending transaction locally with someone familiar with the data. Preserve every version. A retry is allowed only when each target matches a known before or intended after state; save external changes separately before restoring a known copy, then reapply those changes after recovery. Guessing hashes, replacing the journal, or writing fabricated records defeats the safety check.

`.ctx-write-*` files are internal staging files used for atomic replacement, not user configuration. Normal writes clean them up; abrupt termination may leave one behind. Preserve them during diagnosis. The CLI's local Git commit helper excludes these staging files, the lock, and journal, but manual `git add` is outside that protection. Review staged runtime files in both repositories.

## `generate` fails or `export` is incomplete

| Symptom | Cause | Repair and verification |
| --- | --- | --- |
| `No input files remain after excluding the output` and exit 1 | No inputs remain after matching `collect` and excluding the output and its real-path or inode aliases. Existing output is preserved; a missing output is not created. | Correct the project-relative patterns to include at least one intended input other than the output, rerun `bash ctx.sh generate project`, and verify its sections. Old output after a failed run is not a newly generated bundle. |
| `Output must be a regular file, not a symlink or other file type` | `generate` rejects a symlink, including a broken one, directory, FIFO, or other non-regular output without changing it or its target. | Inspect the configured path with the diagnostic below. Preserve the existing entry and choose an unused output path or a regular file you intend to replace. |
| An input read, output write, or replacement fails | A permission or I/O error prevents replacement. This run leaves the output untouched and removes its temporary file. | Inspect the reported input/output path, output directory permissions, and available storage; correct the cause and rerun. A replacement needs write access to the output directory. Do not make the project world-writable. |
| `Output changed during generation; preserving it` | The output changed between the initial check and the check before replacement, so this run stops without replacing it. Concurrent writers are not locked. | Inspect and preserve the current output, finish or stop the other writer, then rerun the command. |
| Generated output contains unexpected data | Collection uses filesystem globbing and concatenates matching files. It does not honor Git ignore rules or exclude binary/private files; only the output and its aliases are automatically excluded. | Prefer an explicit, reviewed `collect` list. Inspect collected paths and the result locally, and exclude credentials, private context, large files, and binary files before sharing. |
| `export --all` omits archived timeline records | `--all` adds archived completed tasks and deprecated decisions, but does not include monthly `archive/timeline-*.jsonl` files. | Inspect those files separately when you need full history. `timeline` also reads only the hot log. |
| Export reports success but recent work is missing | Export suppresses `timeline` errors and can exit 0 even when that section failed. | Run `bash ctx.sh timeline --limit 20 --json` directly and use the JSONL diagnostic above before trusting the export. |

From the project root, inspect the configured `project` output without following a final symlink:

```bash
python3 - <<'PY'
import json
import os
import stat
from pathlib import Path

config = json.loads(Path("ctx.config.json").read_text(encoding="utf-8"))
output = Path(config["generate"]["project"]["output"])
print("output:", output)
print("parent:", output.parent)
if os.path.lexists(output):
    print("entry type and permissions:", stat.filemode(output.lstat().st_mode))
else:
    print("output does not exist")
PY
```

The first character is `-` for a regular file, `l` for a symlink, `d` for a directory, or `p` for a FIFO. Change `project` in the diagnostic when investigating another configured type. For `scripts/ctx.sh`, retry with `bash scripts/ctx.sh generate project`.

Do not treat generated or exported output as a secret-filtered bundle. Review it before pasting into an external LLM.

## Windows wrapper or symlink failures

Copy `ctx.cmd` **beside** `ctx.sh`. Use `ctx.cmd` in Command Prompt, `./ctx.cmd` or `.\ctx.cmd` in PowerShell, or `bash ctx.sh` in Git Bash. For a `scripts/` installation, keep both files there and invoke `.\scripts\ctx.cmd` from PowerShell; configuration remains at the parent project root.

`[Error] Git Bash is required to run ctx on Windows.` means the wrapper did not find Git Bash in its checked locations. Git Bash and a suitable Python executable must be available to the wrapper's shell, not just to a different terminal. In Git Bash, run the Python diagnostics above: the CLI checks `python3`, `python`, then `py -3`, and only accepts a candidate that runs Python 3.7+. Configure `PATH` for your installation; the CLI does not search private runtime locations.

Symlink creation also requires Windows support and sufficient privileges, commonly provided through Developer Mode or an appropriately authorized shell. If `ln -s` fails, check that environment before retrying. Git may check out symlinks as ordinary text files when symlink support is disabled; inspect the actual file type and content before running `sync`, which preserves a conflicting regular file. These are compatibility requirements; an actual Windows end-to-end run has not been verified here.
