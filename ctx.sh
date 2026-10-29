#!/bin/bash

# ctx — Context Management CLI for AI-Driven Projects
# https://github.com/nemory-dev/ctx-kit
#
# Usage: bash ctx.sh [command]
# See README.md for details.

set -e

# Windows compatibility for path translation in Python
py_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s' "$1"
  fi
}
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

# Selected lazily so help/version do not require a Python installation.
CTX_PYTHON=()

VERSION="1.1.0"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Support both project root and scripts/ subdirectory
if [ "$(basename "$SCRIPT_DIR")" = "scripts" ]; then
  PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
else
  PROJECT_ROOT="$SCRIPT_DIR"
fi

CONFIG="$PROJECT_ROOT/ctx.config.json"
DEFAULT_CONTEXT_DIR="$PROJECT_ROOT/sample-context"
CONTEXT_DIR="$DEFAULT_CONTEXT_DIR"

# Locate templates directory
TEMPLATES_DIR="$SCRIPT_DIR/templates"
if [ ! -d "$TEMPLATES_DIR" ]; then
  TEMPLATES_DIR="$(dirname "$SCRIPT_DIR")/templates"
fi

# ── Colors ─────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Utils ──────────────────────────────────────────────
ctx_git() (
  # Hook Git variables belong to the parent repository, not the local context.
  local ctx_git_env_names ctx_git_env_name
  ctx_git_env_names=$(git rev-parse --local-env-vars) || return $?
  for ctx_git_env_name in $ctx_git_env_names; do
    unset "$ctx_git_env_name"
  done
  git -c safe.directory=* -C "$CONTEXT_DIR" "$@"
)

# Shared storage primitives keep the copied CLI standalone.
context_python() {
  CTX_STORAGE_MODE="${1:-write}" CTX_STORAGE_DIR="$(py_path "$CONTEXT_DIR")" ctx_python -c '
import errno
import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager


def git_output(root, args, allow_no_repository=False, allow_unborn_head=False):
    # Decode bytes directly: text mode would translate CR/LF in file names.
    env = dict(os.environ, LC_ALL="C") if allow_no_repository else None
    try:
        result = subprocess.run(["git", "-C", root, *args], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except FileNotFoundError:
        if allow_no_repository:
            return None
        raise
    if result.returncode:
        # --verify --quiet HEAD returns 1 without diagnostics before the first commit.
        if allow_unborn_head and result.returncode == 1 and not result.stderr:
            return None
        no_repository = result.stderr.startswith((
            b"fatal: not a git repository (or any of the parent directories):",
            b"fatal: not a git repository (or any parent up to mount point ",
        ))
        if allow_no_repository and no_repository and not os.environ.get("GIT_DIR"):
            # Broken .git markers must not turn a repository error into standalone mode.
            directory = os.path.abspath(root)
            while not os.path.lexists(os.path.join(directory, ".git")):
                parent = os.path.dirname(directory)
                if parent == directory:
                    return None
                directory = parent
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise ValueError(f"Git {args[0]} failed: {detail}")
    return result.stdout.decode("utf-8")


def git_paths(root, args):
    output = git_output(root, args)
    if output and not output.endswith("\0"):
        raise ValueError("Incomplete NUL-delimited Git file list")
    return [path for path in output.split("\0") if path]


def read_jsonl(path):
    try:
        stream = open(path, encoding="utf-8")
    except FileNotFoundError:
        return []
    entries = []
    with stream:
        for number, line in enumerate(stream, 1):
            if not line.strip():
                continue
            try:
                entry = json.loads(line)
            except ValueError as error:
                raise ValueError(f"{path}: invalid JSON at line {number}: {error}") from error
            if not isinstance(entry, dict):
                raise ValueError(f"{path}: expected a JSON object at line {number}")
            entries.append(entry)
    return entries


def archive_timeline_paths():
    directory = os.path.join(os.environ["CTX_STORAGE_DIR"], "archive")
    try:
        names = os.listdir(directory)
    except FileNotFoundError:
        return []
    return [os.path.join(directory, name) for name in sorted(names)
            if name.startswith("timeline-") and name.endswith(".jsonl")]


def stage_text_writes(writes):
    staged = []
    try:
        for path, text in writes:
            path = os.fspath(path)
            mode = None
            try:
                existing = os.stat(path, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                if not stat.S_ISREG(existing.st_mode):
                    raise OSError(f"Refusing to replace non-regular file: {path}")
                mode = stat.S_IMODE(existing.st_mode)
            directory = os.path.dirname(os.path.abspath(path))
            os.makedirs(directory, exist_ok=True)
            fd, temporary = tempfile.mkstemp(prefix=".ctx-write-", dir=directory)
            staged.append((path, temporary))
            with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
                stream.write(text)
                stream.flush()
                if mode is not None:
                    os.chmod(temporary, mode)
                os.fsync(stream.fileno())
        return staged
    except BaseException:
        for _, temporary in staged:
            if os.path.exists(temporary):
                os.unlink(temporary)
        raise


def sync_directory(path):
    if os.name != "nt":
        directory = os.open(path, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)


def replace_staged_text_writes(staged):
    try:
        for path, temporary in staged:
            os.replace(temporary, path)
            sync_directory(os.path.dirname(os.path.abspath(path)))
    finally:
        for _, temporary in staged:
            if os.path.exists(temporary):
                os.unlink(temporary)


def atomic_write_text(path, text):
    replace_staged_text_writes(stage_text_writes([(path, text)]))


def append_jsonl(path, entry):
    entries = read_jsonl(path)
    entries.append(entry)
    atomic_write_text(path, "".join(json.dumps(item, ensure_ascii=False) + "\n"
                                  for item in entries))


def archive_journal_path():
    return os.path.join(os.environ["CTX_STORAGE_DIR"], "work-log", ".ctx-archive-transaction.json")


def file_digest(path):
    try:
        with open(path, "rb") as stream:
            return hashlib.sha256(stream.read()).hexdigest()
    except FileNotFoundError:
        return None


def clear_archive_journal():
    path = archive_journal_path()
    os.unlink(path)
    sync_directory(os.path.dirname(path))


def transactional_text_writes(writes):
    if not writes:
        return
    staged = stage_text_writes(writes)
    try:
        root = os.path.realpath(os.environ["CTX_STORAGE_DIR"])
        records = []
        for path, text in writes:
            if os.path.commonpath([root, os.path.realpath(path)]) != root:
                raise ValueError(f"Archive destination is outside the context directory: {path}")
            records.append({"path": os.path.relpath(path, root),
                            "before": file_digest(path), "after": text})
        # Persist newly created archive/work-log directory entries before intent.
        sync_directory(root)
        atomic_write_text(archive_journal_path(), json.dumps({"version": 1, "writes": records}))
        replace_staged_text_writes(staged)
        clear_archive_journal()
    finally:
        for _, temporary in staged:
            if os.path.exists(temporary):
                os.unlink(temporary)


def recover_archive():
    journal = archive_journal_path()
    if not os.path.lexists(journal):
        return
    if os.path.islink(journal):
        raise ValueError(f"Refusing a symlinked archive recovery journal: {journal}")
    with open(journal, encoding="utf-8") as stream:
        pending = json.load(stream)
    if not isinstance(pending, dict) or pending.get("version") != 1 or not isinstance(pending.get("writes"), list):
        raise ValueError(f"Invalid archive recovery journal: {journal}")
    root = os.path.realpath(os.environ["CTX_STORAGE_DIR"])
    writes = []
    seen = set()
    for record in pending["writes"]:
        if (not isinstance(record, dict) or not isinstance(record.get("path"), str)
                or not isinstance(record.get("after"), str)
                or not (record.get("before") is None or isinstance(record["before"], str))):
            raise ValueError(f"Invalid archive recovery record: {journal}")
        path = os.path.join(root, record["path"])
        if (os.path.isabs(record["path"]) or os.path.commonpath([root, os.path.realpath(path)]) != root
                or os.path.realpath(path) in seen or os.path.islink(path)):
            raise ValueError("Unsafe archive recovery path: " + record["path"])
        seen.add(os.path.realpath(path))
        current = file_digest(path)
        after = hashlib.sha256(record["after"].encode("utf-8")).hexdigest()
        if current not in (record["before"], after):
            raise ValueError(f"Cannot recover archive: file changed outside the pending transaction: {path}. Preserve the journal and reconcile the changes before retrying.")
        if current != after:
            writes.append((path, record["after"]))
    replace_staged_text_writes(stage_text_writes(writes))
    clear_archive_journal()
    print("Recovered interrupted archive transaction.", file=sys.stderr)


@contextmanager
def context_lock():
    directory = os.path.join(os.environ["CTX_STORAGE_DIR"], "work-log")
    os.makedirs(directory, exist_ok=True)
    sync_directory(os.environ["CTX_STORAGE_DIR"])
    path = os.path.join(directory, ".ctx.lock")
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    with os.fdopen(os.open(path, flags, 0o600), "r+b") as lock:
        if os.name == "nt":
            import msvcrt
            if os.fstat(lock.fileno()).st_size == 0:
                lock.write(b"\0")
                lock.flush()
            def acquire():
                lock.seek(0)
                msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
            def release():
                lock.seek(0)
                msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl
            def acquire():
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            def release():
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        deadline = time.monotonic() + 30
        while True:
            try:
                acquire()
                break
            except OSError as error:
                if error.errno not in (errno.EACCES, errno.EAGAIN, errno.EDEADLK):
                    raise
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"Timed out waiting for context writer lock: {path}") from error
                time.sleep(0.05)
        try:
            yield
        finally:
            release()


try:
    if os.environ["CTX_STORAGE_MODE"] == "--read-only":
        exec(compile(sys.stdin.read(), "<ctx storage>", "exec"), globals())
    else:
        with context_lock():
            recover_archive()
            exec(compile(sys.stdin.read(), "<ctx storage>", "exec"), globals())
except (OSError, ValueError) as error:
    print(f"Error: {error}", file=sys.stderr)
    sys.exit(1)
'
}

context_git_commit() {
  CTX_GIT_MESSAGE="$1" CTX_GIT_NOTICE="${2:-}" context_python <<'PYEOF'
import subprocess

command = ["git", "-c", "safe.directory=*", "-C", os.environ["CTX_STORAGE_DIR"]]
git_env = os.environ.copy()
for name in subprocess.check_output(["git", "rev-parse", "--local-env-vars"], text=True).splitlines():
    git_env.pop(name, None)

def git(args):
    result = subprocess.run(command + args, env=git_env)
    if result.returncode:
        raise SystemExit(result.returncode)

git(["add", "-A", "--", ".", ":(exclude,literal)work-log/.ctx.lock",
     ":(exclude,literal)work-log/.ctx-archive-transaction.json",
     ":(exclude,glob)**/.ctx-write-*"])
head = subprocess.run(command + ["rev-parse", "--verify", "HEAD"],
                      env=git_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
changed = head.returncode != 0
if not changed:
    result = subprocess.run(command + ["diff-index", "--quiet", "HEAD", "--"], env=git_env)
    if result.returncode not in (0, 1):
        raise SystemExit(result.returncode)
    changed = result.returncode == 1
if changed:
    git(["commit", "-m", os.environ["CTX_GIT_MESSAGE"], "--quiet"])
    if os.environ["CTX_GIT_NOTICE"]:
        print(os.environ["CTX_GIT_NOTICE"])
PYEOF
}

require_python() {
  if [ "${#CTX_PYTHON[@]}" -gt 0 ]; then
    return 0
  fi

  local candidate executable
  local -a command_args
  for candidate in python3 python py; do
    executable=$(type -P "$candidate") || continue
    command_args=("$executable")
    if [ "$candidate" = "py" ]; then
      command_args+=("-3")
    fi
    # Keep the probe parseable by Python 2 so old commands fail cleanly.
    if "${command_args[@]}" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 7) else 1)' </dev/null >/dev/null 2>&1; then
      CTX_PYTHON=("${command_args[@]}")
      return 0
    fi
  done

  echo -e "${RED}Error: Python 3.7 or newer is required.${NC}" >&2
  echo "  Install Python and add python3, python, or py -3 to PATH." >&2
  return 1
}

ctx_python() {
  require_python || return $?
  "${CTX_PYTHON[@]}" "$@"
}

# Configuration updates must not truncate the current file before publishing.
config_python() {
  CTX_CONFIG="$(py_path "$CONFIG")" ctx_python -c '
import json
import os
import stat
import sys
import tempfile


def write_config(data):
    path = os.environ["CTX_CONFIG"]
    existing = os.lstat(path)
    if not stat.S_ISREG(existing.st_mode):
        raise ValueError(f"Refusing to replace non-regular configuration file: {path}")
    descriptor = None
    temporary = None
    try:
        directory = os.path.dirname(os.path.abspath(path))
        descriptor, temporary = tempfile.mkstemp(prefix=".ctx-write-", dir=directory)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            descriptor = None
            json.dump(data, stream, ensure_ascii=False, indent=2)
            stream.flush()
            os.chmod(temporary, stat.S_IMODE(existing.st_mode))
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if temporary is not None:
            os.unlink(temporary)


try:
    exec(compile(sys.stdin.read(), "<ctx config>", "exec"), globals())
except (OSError, ValueError) as error:
    print(f"Error: {error}", file=sys.stderr)
    sys.exit(1)
'
}

require_config() {
  if [ ! -f "$CONFIG" ]; then
    echo -e "${RED}Error: ctx.config.json not found.${NC}"
    echo "  Run first: bash ctx.sh init"
    exit 1
  fi
}

resolve_context_dir() {
  require_config
  require_python
  local source_dir
  source_dir=$(ctx_python -c 'import json, os, sys
# Paths consumed by Bash must use LF even with native Windows Python.
sys.stdout.reconfigure(newline="\n")
with open(sys.argv[1], encoding="utf-8") as f: d=json.load(f)
print(os.path.dirname(d.get("source", "sample-context/AGENT_RULES.md")) or "sample-context")' "$(py_path "$CONFIG")")
  CONTEXT_DIR="$PROJECT_ROOT/$source_dir"
}

get_source() {
  require_python
  ctx_python -c 'import json, sys
sys.stdout.reconfigure(newline="\n")
with open(sys.argv[1], encoding="utf-8") as f: d=json.load(f)
print(d["source"])' "$(py_path "$CONFIG")"
}

get_agents() {
  require_python
  ctx_python -c 'import json, sys
sys.stdout.reconfigure(newline="\n")
with open(sys.argv[1], encoding="utf-8") as f: d=json.load(f)
for a in d["agent_rules"]: print("{name}|{path}|{enabled}".format(**a))' "$(py_path "$CONFIG")"
}

# ── help ───────────────────────────────────────────────
cmd_help() {
  echo ""
  echo -e "${BOLD}ctx v${VERSION} — AI Agent Context Manager${NC}"
  echo -e "${CYAN}https://github.com/nemory-dev/ctx-kit${NC}"
  echo ""
  echo -e "${BOLD}Commands:${NC}"
  printf "  %-20s %s\n" "init"           "Create context structure + symlinks for a new project"
  printf "  %-20s %s\n" "status"         "Show symlink status + project summary"
  printf "  %-20s %s\n" "sync"           "Rebuild symlinks based on ctx.config.json"
  printf "  %-20s %s\n" "export"         "Print context for web-based LLMs (paste into chat)"
  printf "  %-20s %s\n" "enable <n>"     "Enable an agent  (e.g. ctx enable Cursor)"
  printf "  %-20s %s\n" "disable <n>"    "Disable an agent (e.g. ctx disable Cursor)"
  printf "  %-20s %s\n" "list"           "List agents and their status"
  printf "  %-20s %s\n" "generate <type>" "Collect files for LLM context (e.g. generate policy)"
  printf "  %-20s %s\n" "log"            "Record a commit/work-unit summary into context work-log"
  printf "  %-20s %s\n" "timeline"       "Show recorded work-log entries by commit/work unit"
  printf "  %-20s %s\n" "view"           "Generate an offline HTML context snapshot (--open to browse)"
  printf "  %-20s %s\n" "backfill"       "Backfill past Git commits into context work-log"
  printf "  %-20s %s\n" "archive"        "Archive completed tasks, deprecated ADRs & split logs"
  printf "  %-20s %s\n" "hook [cmd]"     "Manage Git pre-commit hook (install|uninstall|status)"
  printf "  %-20s %s\n" "version"        "Show version"
  printf "  %-20s %s\n" "help"           "Show this help"
  echo ""
  echo -e "${BOLD}Config:${NC}"
  echo "  ctx.config.json              — Agent rule file paths & git_sync options"
  echo ""
  echo -e "${BOLD}Context files (3-Tier Hierarchical Context):${NC}"
  echo "  <context>/AGENT_RULES.md     — [Hot] Agent behavior rules (single source of truth)"
  echo "  <context>/MASTER_PLAN.md     — [Hot] Current state + next actions"
  echo "  <context>/decisions.md       — [Hot] Architecture decision records (ADR)"
  echo "  <context>/backlog.md         — [Hot] Ideas + future tasks"
  echo "  <context>/work-log/          — [Hot] Recent commit/work-unit timeline entries"
  echo "  <context>/work-log/timeline-digest.md — [Warm] Compressed milestone summary"
  echo "  <context>/archive/           — [Cold] Archived completed tasks and past logs"
  echo ""
  echo -e "${BOLD}Quick start:${NC}"
  echo "  bash ctx.sh init            # First time setup"
  echo "  bash ctx.sh status          # Check current state"
  echo "  bash ctx.sh sync            # After config changes"
  echo "  bash ctx.sh enable Cursor   # Enable Cursor"
  echo "  bash ctx.sh export          # Copy context for web LLM"
  echo "  bash ctx.sh log --summary \"Implemented feedback MVP\""
  echo "  bash ctx.sh timeline --limit 10"
  echo "  bash ctx.sh view --open     # Browse a local context snapshot"
  echo "  bash ctx.sh backfill --limit 30 # Backfill past commits"
  echo "  bash ctx.sh archive         # Compact context & archive completed tasks"
  echo "  bash ctx.sh hook install    # Install Git pre-commit auto-sync hook"
  echo ""
}

# ── init ───────────────────────────────────────────────
cmd_init() {
  local AUTO_BACKFILL=""
  local AUTO_HOOK=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --backfill)    AUTO_BACKFILL="true"; shift ;;
      --no-backfill) AUTO_BACKFILL="false"; shift ;;
      --hook)        AUTO_HOOK="true"; shift ;;
      --no-hook)     AUTO_HOOK="false"; shift ;;
      *) echo "Unknown option: $1" >&2; return 1 ;;
    esac
  done

  require_python
  echo -e "${BOLD}[ctx init] Initializing context structure${NC}"
  echo ""

  # 1) Create ctx.config.json
  if [ ! -f "$CONFIG" ]; then
    if [ -f "$TEMPLATES_DIR/../ctx.config.json" ]; then
      cp "$TEMPLATES_DIR/../ctx.config.json" "$CONFIG"
    else
      cat > "$CONFIG" << 'CONFIGEOF'
{
  "_comment": "ctx config. Add paths to agent_rules, then run ctx sync.",
  "_usage": "bash ctx.sh help",
  "source": "sample-context/AGENT_RULES.md",
  "git_sync": {
    "enabled": true,
    "auto_log": true
  },
  "generate": {
    "project": {
      "output": "sample-context/generated/project-raw.md",
      "collect": [
        "README.md",
        "docs/**/*.md",
        "src/**/*"
      ]
    }
  },
  "agent_rules": [
    { "name": "Claude",      "path": "CLAUDE.md",                "enabled": true,  "_note": "Claude Code" },
    { "name": "Codex",       "path": "AGENTS.md",                "enabled": true,  "_note": "OpenAI Codex (AGENTS.md spec)" },
    { "name": "Antigravity", "path": "AGENTS.md",                "enabled": true,  "_note": "Google Antigravity (shares AGENTS.md with Codex)" },
    { "name": "Cursor",      "path": ".cursor/rules/context.mdc", "enabled": true,  "_note": "Cursor IDE" }
  ]
}
CONFIGEOF
    fi
    echo -e "  ${GREEN}✓${NC} ctx.config.json created"
  else
    echo -e "  ${YELLOW}~${NC} ctx.config.json already exists (skipped)"
  fi

  resolve_context_dir

  # 2) Create sample-context/ directory + template files
  mkdir -p "$CONTEXT_DIR/visuals"

  _init_file "AGENT_RULES.md" << 'EOF'
# Agent Rules — [Project Name]
> **Single Source of Truth.**
> All agent rule files (CLAUDE.md, AGENTS.md, etc.) are symlinks to this file.
> Edit only this file. Run `bash ctx.sh status` to verify links.

---

## 1. Session Start Protocol (MANDATORY)

Before starting any task, read in this order:

```
1. sample-context/MASTER_PLAN.md               → Current state + next actions [Hot]
2. sample-context/decisions.md                 → Existing technical decisions [Hot]
3. sample-context/work-log/timeline-digest.md     → Past milestones summary (if present) [Warm]
4. sample-context/backlog.md                   → Pending ideas [Hot]
```

> 💡 **3-Tier Context Notice**: Detailed past logs and completed tasks are archived in `sample-context/archive/` [Cold] and excluded from session loading to optimize tokens and prevent context bloat.

Then output exactly:

```
[Context Loaded]
Current state: {one-line summary from MASTER_PLAN}
Today's task:  {requested task}
Related ADRs:  {relevant decisions, or "none"}
```

---

## 2. Auto-Detect + Record Protocol

Ask before adopting new decisions, changing scope or priorities, or adding backlog
items unless the user has already authorized that action. Factual progress updates
within an authorized task follow Trigger B and the session end protocol directly.
Explicit user restrictions, including read-only requests and allowed-file limits,
take precedence over these recording rules.

### Trigger A: Technical Decision
Detect: new library, architecture change, tech stack selection, reverting a decision

```
[Decision Detected] Record in decisions.md?
- Decision: {what}
- Reason:   {agent's reasoning}
- Tradeoff: {what is given up}
(yes / no / edit first)
```
yes → Add ADR to decisions.md, update MASTER_PLAN.md decision summary

---

### Trigger B: Task Status Change
Detect: progress or completion of an authorized task, plan changed, task added/removed/reprioritized

For factual progress or completion within the authorized scope, update only the
affected Current State and Next Actions in MASTER_PLAN.md without asking again.
If neither changed, leave the file unchanged. For new scope or priority changes
that have not been authorized, ask first:

```
[Status Change] Update MASTER_PLAN.md?
- {change description}
(yes / no)
```
yes → Update the relevant item in MASTER_PLAN.md

---

### Trigger C: Backlog Item
Detect: "later", "after MVP", "hold for now", "great idea but", "someday"

```
[Backlog] Add to backlog.md?
- Content:  {idea or question}
- Category: future-feature / open-question / research-needed
(yes / no)
```

---

### Trigger D: Conflict with Existing Decision
Detect: request conflicts with an ADR in decisions.md

```
[Conflict Detected] Conflicts with existing decision (ADR-NNN).
- Existing:  {content}
- Requested: {content}
Keep / Change? (update ADR if changed)
```

---

## 3. Session End Protocol

For each completed work unit that changes project files, including documentation:

1. Verify the actual changes and run relevant available checks. Distinguish work
   implemented, checks passed, committed, and merged; do not infer one from another.
2. Update MASTER_PLAN.md only if the current state or next actions changed, following
   Trigger B. Update decisions.md or backlog.md only when applicable and authorized.
3. Record the work through the CLI, using the actual summary and relevant file paths:

   ```bash
   bash ctx.sh log --summary "What changed; validation results; remaining issues" --files "path/to/file"
   bash ctx.sh timeline --limit 1 --json
   ```

   Check that `log` succeeded and that readback contains this work unit's summary
   and files. If another writer added a newer entry, increase the read limit to
   locate your entry. An existing file or JSONL row alone is not proof of success.
4. If recording or readback fails, report the cause and mark logging as failed or
   unverified. Do not directly create or edit timeline.jsonl to bypass the CLI.
   Check for an existing entry before retrying; use an allowed recovery or approval
   path, or leave recording pending when no such path is available.

Read-only analysis/review does not require context edits or a work-log entry.
Respect explicit no-logging and allowed-file restrictions; report any skipped
closure steps instead of expanding the scope. Without filesystem or CLI access,
provide proposed updates and commands for the user and mark them as unapplied.

Then output a summary (also for read-only tasks):

```
[Session Summary]
✅ Done:          {completed items}
📝 Files changed: {modified project and context files, or "none"}
📚 Work log:      {recorded / skipped with reason / failed / unverified}
⏭️ Next action:   {next priority from MASTER_PLAN}
🔖 Open items:    {issues for next session}
```

---

## 4. Absolute Rules

```
✗ Do not introduce tech stacks not listed in decisions.md
✗ Do not restructure MASTER_PLAN.md without user confirmation
✗ Do not make tech choices without explaining tradeoffs
✓ Follow existing architecture patterns when adding new modules
✗ Do not commit or push unless the user requests it
```

---

## 5. Project Context

> Edit this section to match your project.

**Project name**: [Project Name]
**Current phase**: [MVP / In development / Production]
**Tech stack**: [list main technologies]

**Detail files**:
- Current state / priorities: `sample-context/MASTER_PLAN.md`
- Decision rationale: `sample-context/decisions.md`
- Pending ideas: `sample-context/backlog.md`

---

## 6. ctx CLI

```bash
bash ctx.sh help              # Full help
bash ctx.sh status            # Symlink status + project summary
bash ctx.sh sync              # Rebuild symlinks (auto-updates Last Updated)
bash ctx.sh export            # Print context for web LLM
bash ctx.sh enable Cursor     # Enable Cursor
bash ctx.sh disable Cursor    # Disable Cursor
bash ctx.sh list              # List agents
bash ctx.sh generate project  # Collect configured source files
bash ctx.sh log --summary "..."  # Record a work-unit
bash ctx.sh timeline --limit 20  # Show recent work-units
```

To add a new agent: add an entry to `agent_rules` in `ctx.config.json` → `bash ctx.sh sync`
EOF

  _init_file "MASTER_PLAN.md" << 'EOF'
# Master Plan — [Project Name]
> Last Updated: YYYY-MM-DD
> Status: In progress

## Current State
- [ ] Task 1
- [ ] Task 2

## Next Actions
1. 

## Key Decisions Summary
> Details: sample-context/decisions.md

## Open Questions
> Details: sample-context/backlog.md
EOF

  _init_file "decisions.md" << 'EOF'
# Decisions (ADR) — [Project Name]
> Architecture Decision Records

## Format
### ADR-NNN: Title
- **Date**: YYYY-MM-DD
- **Status**: Decided / Under review / Deprecated
- **Decision**: What was decided
- **Reason**: Why
- **Tradeoff**: What was given up
EOF

  _init_file "backlog.md" << 'EOF'
# Backlog — [Project Name]
> Ideas, future features, open questions

## Future Features
- 

## Open Questions
- 

## Research Needed
- 
EOF

  echo ""

  # 3) Create symlinks
  cmd_sync

  # 4) Post-init guidance
  local context_label="${CONTEXT_DIR#$PROJECT_ROOT/}"
  echo ""
  echo -e "${YELLOW}⚠️  Update the placeholders in these files before using:${NC}"
  echo "  1. $context_label/AGENT_RULES.md — [Project Name], tech stack section"
  echo "  2. $context_label/MASTER_PLAN.md — [Project Name], Last Updated, first tasks"
  echo "  3. $context_label/decisions.md   — [Project Name]"
  echo "  4. $context_label/backlog.md     — [Project Name]"
  echo ""
  echo -e "  Then tell your agent: ${CYAN}\"Read MASTER_PLAN.md and get started\"${NC}"

  # 5) Git Hook & Backfill setup
  if [ -d "$PROJECT_ROOT/.git" ]; then
    echo ""
    echo -e "${BOLD}[ctx init] Git Integration${NC}"
    local commit_count
    commit_count=$(git -C "$PROJECT_ROOT" rev-list --count HEAD 2>/dev/null || echo "0")
    if [ "$commit_count" -gt 0 ]; then
      local do_backfill="false"
      if [ "$AUTO_BACKFILL" = "true" ]; then
        do_backfill="true"
      elif [ "$AUTO_BACKFILL" = "false" ]; then
        do_backfill="false"
      else
        echo -e "  🔍 Existing Git history detected (${CYAN}${commit_count} commit(s)${NC})."
        local bf_ans="n"
        if [ -t 0 ] || [ -e /dev/tty ]; then
          read -r -p "  Would you like to backfill past commits into timeline.jsonl? [y/N]: " bf_ans </dev/tty 2>/dev/null || bf_ans="n"
        fi
        if [[ "$bf_ans" =~ ^[Yy]$ ]]; then
          do_backfill="true"
        fi
      fi

      if [ "$do_backfill" = "true" ]; then
        cmd_backfill --limit 30
      fi
    fi

    local do_hook="true"
    if [ "$AUTO_HOOK" = "true" ]; then
      do_hook="true"
    elif [ "$AUTO_HOOK" = "false" ]; then
      do_hook="false"
    else
      local hk_ans="y"
      if [ -t 0 ] || [ -e /dev/tty ]; then
        read -r -p "  Install Git pre-commit hook to auto-sync ${context_label}? [Y/n]: " hk_ans </dev/tty 2>/dev/null || hk_ans="y"
      fi
      if [[ "$hk_ans" =~ ^[Nn]$ ]]; then
        do_hook="false"
      fi
    fi

    if [ "$do_hook" = "true" ]; then
      _hook_install
    fi
  fi
}

# Helper: create file only if it doesn't exist
_init_file() {
  local filename="$1"; shift
  local filepath="$CONTEXT_DIR/$filename"
  local relpath="${CONTEXT_DIR#$PROJECT_ROOT/}/$filename"
  if [ ! -f "$filepath" ]; then
    # Keep ctx.sh standalone while rendering the configured project-relative paths.
    CTX_TEMPLATE_CONTEXT="${CONTEXT_DIR#$PROJECT_ROOT/}" \
      CTX_TEMPLATE_COMMAND="bash ${SCRIPT_PATH#$PROJECT_ROOT/}" ctx_python -c '
import os, sys
template = sys.stdin.read()
template = template.replace("sample-context/", os.environ["CTX_TEMPLATE_CONTEXT"] + "/")
template = template.replace("bash ctx.sh", os.environ["CTX_TEMPLATE_COMMAND"])
sys.stdout.write(template)
' > "$filepath"
    echo -e "  ${GREEN}✓${NC} $relpath created"
  else
    echo -e "  ${YELLOW}~${NC} $relpath already exists (skipped)"
    cat > /dev/null  # consume heredoc
  fi
}

# ── status ─────────────────────────────────────────────
cmd_status() {
  require_config
  resolve_context_dir
  local agents
  agents=$(get_agents) || return $?
  echo -e "${BOLD}[ctx status] Current State${NC}"
  echo ""

  # Project summary from MASTER_PLAN.md
  MASTER_PLAN="$CONTEXT_DIR/MASTER_PLAN.md"
  if [ -f "$MASTER_PLAN" ]; then
    echo -e "${BOLD}📋 Project Summary${NC}"
    UPDATED=$(grep "Last Updated" "$MASTER_PLAN" | head -1 | sed 's/.*Last Updated: //')
    [ -n "$UPDATED" ] && echo -e "  Last Updated: ${CYAN}$UPDATED${NC}"
    echo ""
    echo -e "  ${BOLD}Current State:${NC}"
    awk '/^## Current State/{found=1; next} found && /^## /{exit} found && NF{print "  " $0}' "$MASTER_PLAN" | head -6
    echo ""
    echo -e "  ${BOLD}Next Actions:${NC}"
    awk '/^## Next Actions/{found=1; next} found && /^## /{exit} found && NF{print "  " $0}' "$MASTER_PLAN" | head -4
    echo ""
    echo -e "  ${CYAN}Details: ${CONTEXT_DIR#$PROJECT_ROOT/}/MASTER_PLAN.md${NC}"
    echo ""
  fi

  # Symlink status
  SOURCE=$(get_source)
  SOURCE_PATH="$PROJECT_ROOT/$SOURCE"

  echo -e "${BOLD}🔗 Symlink Status${NC}"
  echo -e "  Source: ${CYAN}$SOURCE${NC}"
  if [ -f "$SOURCE_PATH" ]; then
    echo -e "  ${GREEN}✓${NC} Source file exists"
  else
    echo -e "  ${RED}✗${NC} Source file missing — run ctx init"
  fi
  echo ""

  printf '%s\n' "$agents" | while IFS="|" read -r name path enabled; do
    [ -n "$name$path$enabled" ] || continue
    LINK_PATH="$PROJECT_ROOT/$path"
    if [ "$enabled" = "True" ] || [ "$enabled" = "true" ]; then
      if [ -L "$LINK_PATH" ] && [ -f "$LINK_PATH" ]; then
        echo -e "  [${GREEN}✓${NC}] ${BOLD}$name${NC} ($path) — linked → $(readlink "$LINK_PATH")"
      elif [ -L "$LINK_PATH" ]; then
        echo -e "  [${RED}✗${NC}] ${BOLD}$name${NC} ($path) — broken link (run ctx sync)"
      elif [ -f "$LINK_PATH" ]; then
        echo -e "  [${YELLOW}!${NC}] ${BOLD}$name${NC} ($path) — regular file exists (not a symlink)"
      else
        echo -e "  [${RED}✗${NC}] ${BOLD}$name${NC} ($path) — missing (run ctx sync)"
      fi
    else
      echo -e "  [${YELLOW}-${NC}] $name ($path) — disabled"
    fi
  done

  echo ""
  echo -e "  Enable agent:  ${CYAN}bash ctx.sh enable <n>${NC}"
  echo -e "  After changes: ${CYAN}bash ctx.sh sync${NC}"
}

# ── sync ───────────────────────────────────────────────
cmd_sync() {
  require_config
  resolve_context_dir
  local agents
  agents=$(get_agents) || return $?
  echo -e "${BOLD}[ctx sync] Syncing symlinks${NC}"
  echo ""

  SOURCE=$(get_source)
  SOURCE_PATH="$PROJECT_ROOT/$SOURCE"

  if [ ! -f "$SOURCE_PATH" ]; then
    echo -e "  ${RED}✗ Source file not found: $SOURCE${NC}"
    echo "    Create sample-context/AGENT_RULES.md first (run ctx init)."
    return 1
  fi

  # Detect every enabled target conflict before changing links or metadata.
  if ! ctx_python - "$(py_path "$CONFIG")" "$(py_path "$PROJECT_ROOT")" "$(py_path "$SOURCE_PATH")" <<'PY'
import json
import os
import sys

config_path, root, source = sys.argv[1:]
with open(config_path, encoding="utf-8") as stream:
    agents = json.load(stream)["agent_rules"]

def entry_path(path):
    return os.path.join(os.path.realpath(os.path.dirname(path)), os.path.basename(path))

conflicts = []
seen = set()
for agent in agents:
    if str(agent["enabled"]).lower() != "true" or agent["path"] in seen:
        continue
    path = agent["path"]
    seen.add(path)
    target = root + os.sep + path
    if entry_path(target) == entry_path(source):
        conflicts.append((path, "target is the configured source file; choose a different agent path in ctx.config.json."))
    elif os.path.lexists(target) and not (
        os.path.islink(target) and os.path.realpath(target) == os.path.realpath(source)
    ):
        conflicts.append((path, "already exists and is not a ctx-managed symlink. Move or rename it, then run bash ctx.sh sync."))

for path, reason in conflicts:
    print(f"  Conflict: {path}: {reason}", file=sys.stderr)
sys.exit(1 if conflicts else 0)
PY
  then
    return 1
  fi

  # Auto-update Last Updated in MASTER_PLAN.md
  MASTER_PLAN="$CONTEXT_DIR/MASTER_PLAN.md"
  if [ -f "$MASTER_PLAN" ] || [ -L "$MASTER_PLAN" ]; then
    TODAY=$(date +%Y-%m-%d)
    if ! ctx_python - "$(py_path "$MASTER_PLAN")" "$TODAY" <<'PY'
import os
import re
import stat
import sys
import tempfile

descriptor = None
temporary = None
try:
    path, today = sys.argv[1:]
    existing = os.lstat(path)
    if not stat.S_ISREG(existing.st_mode):
        raise ValueError(f"Refusing to replace non-regular master plan: {path}")
    with open(path, "rb") as stream:
        content = stream.read()
    updated = re.sub(br"^> Last Updated: [^\n]*",
                     b"> Last Updated: " + today.encode("ascii"), content, flags=re.MULTILINE)
    directory = os.path.dirname(os.path.abspath(path))
    descriptor, temporary = tempfile.mkstemp(prefix=".ctx-write-", dir=directory)
    with os.fdopen(descriptor, "wb") as stream:
        descriptor = None
        stream.write(updated)
        stream.flush()
        os.chmod(temporary, stat.S_IMODE(existing.st_mode))
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    temporary = None
except (OSError, ValueError) as error:
    print(f"Error: {error}", file=sys.stderr)
    sys.exit(1)
finally:
    if descriptor is not None:
        os.close(descriptor)
    if temporary is not None:
        os.unlink(temporary)
PY
    then
      return 1
    fi
    echo -e "  ${GREEN}✓${NC} MASTER_PLAN.md Last Updated → $TODAY"
  fi

  # Collect enabled paths first so disabled rows that share a path
  # (e.g. multiple AGENTS.md-spec tools) don't remove an active symlink.
  ENABLED_PATHS=$(printf '%s\n' "$agents" | awk -F'|' '$3=="True" || $3=="true" {print $2}' | sort -u)

  printf '%s\n' "$agents" | while IFS="|" read -r name path enabled; do
    [ -n "$name$path$enabled" ] || continue
    LINK_PATH="$PROJECT_ROOT/$path"
    if [ "$enabled" = "True" ] || [ "$enabled" = "true" ]; then
      if [ ! -L "$LINK_PATH" ]; then
        mkdir -p "$(dirname "$LINK_PATH")"
        RELATIVE=$(ctx_python -c 'import os, sys; sys.stdout.reconfigure(newline="\n"); print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))' "$(py_path "$SOURCE_PATH")" "$(py_path "$LINK_PATH")")
        ln -s "$RELATIVE" "$LINK_PATH"
      fi
      echo -e "  ${GREEN}✓${NC} $name: $path → $SOURCE"
    else
      if echo "$ENABLED_PATHS" | grep -qx "$path"; then
        echo -e "  ${YELLOW}-${NC} $name ($path) disabled — kept (shared with an enabled agent)"
      elif [ -L "$LINK_PATH" ] && ctx_python - "$(py_path "$CONFIG")" "$(py_path "$PROJECT_ROOT")" "$(py_path "$SOURCE_PATH")" "$(py_path "$LINK_PATH")" <<'PY'
import json
import os
import sys

def entry_path(path):
    return os.path.join(os.path.realpath(os.path.dirname(path)), os.path.basename(path))

config_path, root, source, target = sys.argv[1:]
with open(config_path, encoding="utf-8") as stream:
    agents = json.load(stream)["agent_rules"]
protected = [source] + [root + os.sep + agent["path"] for agent in agents
                        if str(agent["enabled"]).lower() == "true"]
target_entry = entry_path(target)
for path in protected:
    current = entry_path(path)
    seen = set()
    while current not in seen:
        # Keep dependencies of the source and every enabled rule link.
        if current == target_entry:
            sys.exit(1)
        seen.add(current)
        if not os.path.islink(current):
            break
        current = entry_path(os.path.join(os.path.dirname(current), os.readlink(current)))
sys.exit(0 if os.path.realpath(target) == os.path.realpath(source) else 1)
PY
      then
        rm "$LINK_PATH"
        echo -e "  ${YELLOW}-${NC} $name: $path symlink removed (disabled)"
      else
        echo -e "  ${YELLOW}-${NC} $name ($path) disabled — skipped"
      fi
    fi
  done

  echo ""
  echo -e "  ${GREEN}Sync complete.${NC} Verify: bash ctx.sh status"
}

# ── export ─────────────────────────────────────────────
cmd_export() {
  require_config
  resolve_context_dir

  local ALL_MODE="false"
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) ALL_MODE="true"; shift ;;
      *) echo "Unknown option: $1" >&2; return 1 ;;
    esac
  done

  echo -e "${BOLD}[ctx export] Context for web-based LLMs${NC}"
  echo -e "${CYAN}Copy the output below and paste it into Claude.ai, ChatGPT, etc.${NC}"
  echo ""

  SEPARATOR="=================================================================="

  echo "$SEPARATOR"
  echo "# Project Context (ctx-kit export)"
  echo "$SEPARATOR"
  echo ""

  if [ -f "$CONTEXT_DIR/MASTER_PLAN.md" ]; then
    echo "## [MASTER_PLAN]"
    cat "$CONTEXT_DIR/MASTER_PLAN.md"
    echo ""
  else
    echo -e "${YELLOW}⚠️  MASTER_PLAN.md not found — run ctx init${NC}"
  fi

  echo "$SEPARATOR"
  echo ""

  if [ -f "$CONTEXT_DIR/decisions.md" ]; then
    echo "## [DECISIONS]"
    cat "$CONTEXT_DIR/decisions.md"
    echo ""
  fi

  echo "$SEPARATOR"
  echo ""

  if [ -f "$CONTEXT_DIR/backlog.md" ]; then
    echo "## [BACKLOG]"
    cat "$CONTEXT_DIR/backlog.md"
    echo ""
  fi

  # Warm Digest (Milestones)
  if [ -f "$CONTEXT_DIR/work-log/timeline-digest.md" ]; then
    echo "$SEPARATOR"
    echo ""
    echo "## [PAST MILESTONES (WARM DIGEST)]"
    cat "$CONTEXT_DIR/work-log/timeline-digest.md"
    echo ""
  fi

  # Recent Work-log (Hot Context)
  if [ -f "$CONTEXT_DIR/work-log/timeline.jsonl" ]; then
    echo "$SEPARATOR"
    echo ""
    echo "## [RECENT WORK UNITS (HOT)]"
    cmd_timeline --limit 10 || return $?
  fi

  # Cold Archives (only if --all)
  if [ "$ALL_MODE" = "true" ] && [ -d "$CONTEXT_DIR/archive" ]; then
    echo "$SEPARATOR"
    echo ""
    echo "## [COLD ARCHIVES]"
    if [ -f "$CONTEXT_DIR/archive/completed-tasks.md" ]; then
      echo "### [Archived Tasks]"
      cat "$CONTEXT_DIR/archive/completed-tasks.md"
      echo ""
    fi
    if [ -f "$CONTEXT_DIR/archive/decisions-deprecated.md" ]; then
      echo "### [Archived Deprecated Decisions]"
      cat "$CONTEXT_DIR/archive/decisions-deprecated.md"
      echo ""
    fi
    context_python --read-only <<'PYEOF' || return $?
for path in archive_timeline_paths():
    entries = read_jsonl(path)
    print(f"### [Archived Timeline: {os.path.basename(path)}]\n")
    print("```jsonl")
    for entry in entries:
        print(json.dumps(entry, ensure_ascii=False))
    print("```\n")
PYEOF
  else
    if [ -d "$CONTEXT_DIR/archive" ]; then
      echo "$SEPARATOR"
      echo "> 📦 Cold archives omitted to save tokens. Use 'ctx export --all' to include full archives."
      echo ""
    fi
  fi

  echo "$SEPARATOR"
  echo ""
  echo -e "${GREEN}Export complete.${NC} Paste the above into your web LLM chat."
}

# ── list ───────────────────────────────────────────────
cmd_list() {
  require_config
  require_python
  local agents
  agents=$(get_agents) || return $?
  echo -e "${BOLD}[ctx list] Agents${NC}"
  echo ""
  printf '%s\n' "$agents" | while IFS="|" read -r name path enabled; do
    [ -n "$name$path$enabled" ] || continue
    if [ "$enabled" = "True" ] || [ "$enabled" = "true" ]; then
      echo -e "  ${GREEN}●${NC} $name  →  $path"
    else
      echo -e "  ${YELLOW}○${NC} $name  →  $path  (disabled)"
    fi
  done
  echo ""
  echo "  Enable:  bash ctx.sh enable <n>"
  echo "  Disable: bash ctx.sh disable <n>"
}

# ── enable / disable ───────────────────────────────────
cmd_enable() {
  require_config
  local NAME="$1"
  [ -z "$NAME" ] && { echo "Usage: bash ctx.sh enable <agent name>"; cmd_list; return 1; }
  _toggle_agent "$NAME" true
  cmd_sync
}

cmd_disable() {
  require_config
  local NAME="$1"
  [ -z "$NAME" ] && { echo "Usage: bash ctx.sh disable <agent name>"; cmd_list; return 1; }
  _toggle_agent "$NAME" false
  cmd_sync
}

_toggle_agent() {
  # Pass via env vars to prevent special character injection
  CTX_AGENT_NAME="$1" CTX_AGENT_STATE="$2" config_python << 'PYEOF'
import json, os

name   = os.environ["CTX_AGENT_NAME"]
state  = os.environ["CTX_AGENT_STATE"].lower() == "true"
config = os.environ["CTX_CONFIG"]

with open(config, encoding="utf-8") as f:
    d = json.load(f)

changed = []
for a in d["agent_rules"]:
    if a["name"].lower() == name.lower():
        a["enabled"] = state
        changed.append(a["name"])

if not changed:
    available = [a["name"] for a in d["agent_rules"]]
    raise ValueError(f"Agent {name!r} not found. Available: {available}")

write_config(d)
label = "enabled" if state else "disabled"
for agent_name in changed:
    print(f"  → {agent_name} {label}")
PYEOF
}

# ── generate ──────────────────────────────────────────
cmd_generate() {
  require_config
  resolve_context_dir
  require_python

  local TYPE="$1"
  [ -z "$TYPE" ] && { echo "Usage: bash ctx.sh generate <type>"; echo "Types are defined in ctx.config.json under \"generate\"."; exit 1; }

  echo -e "$BOLD[ctx generate $TYPE]$NC"
  echo ""

  CTX_TYPE="$TYPE" CTX_CONFIG="$(py_path "$CONFIG")" CTX_ROOT="$(py_path "$PROJECT_ROOT")" ctx_python << 'PYEOF'
import glob
import json
import os
import shutil
import stat
import sys
import tempfile
from datetime import datetime

sys.stdout.reconfigure(newline="\n")
root = os.environ["CTX_ROOT"]
type_key = os.environ["CTX_TYPE"]
temporary = None
descriptor = None


def output_state(path):
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(info.st_mode):
        raise ValueError(f"Output must be a regular file, not a symlink or other file type: {path}")
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, stat.S_IMODE(info.st_mode))


try:
    with open(os.environ["CTX_CONFIG"], encoding="utf-8") as stream:
        config = json.load(stream)
    generate = config.get("generate", {})
    if not isinstance(generate, dict) or type_key not in generate:
        raise ValueError(f"Generate type not found: {type_key}")
    settings = generate[type_key]
    if not isinstance(settings, dict):
        raise ValueError(f"Invalid generate settings for type: {type_key}")
    output = settings.get("output")
    patterns = settings.get("collect", [])
    if not isinstance(output, str) or not output:
        raise ValueError(f"Output is not defined for type: {type_key}")
    if not isinstance(patterns, list) or any(not isinstance(pattern, str) for pattern in patterns):
        raise ValueError("Generate collect must be an array of glob strings")

    output_path = root + os.sep + output
    previous = output_state(output_path)
    output_real = os.path.normcase(os.path.realpath(output_path))

    # Freeze the inputs before creating a temporary file or changing the output.
    inputs = []
    skipped = []
    for pattern in patterns:
        if not pattern:
            continue
        for path in sorted(glob.glob(os.path.join(root, pattern), recursive=True)):
            try:
                info = os.stat(path)
            except FileNotFoundError:
                continue
            if not stat.S_ISREG(info.st_mode):
                continue
            same_path = os.path.normcase(os.path.realpath(path)) == output_real
            same_inode = previous is not None and (info.st_dev, info.st_ino) == previous[:2]
            if same_path or same_inode:
                skipped.append(os.path.relpath(path, root))
                continue
            inputs.append((path, os.path.relpath(path, root)))
    if not inputs:
        raise ValueError("No input files remain after excluding the output. Check collect patterns.")

    directory = os.path.dirname(os.path.abspath(output_path))
    os.makedirs(directory, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".ctx-write-", dir=directory)
    with os.fdopen(descriptor, "wb") as stream:
        descriptor = None
        header = (
            f"# {type_key} Context — generated by ctx\n"
            f"# {datetime.now():%Y-%m-%d}\n"
            "# Paste this into your LLM with a prompt like:\n"
            f"#   \"Generate a {type_key} document based on the following source files:\"\n\n"
        )
        stream.write(header.encode("utf-8"))
        for path, relative in inputs:
            stream.write(f"\n## [{relative}]\n\n".encode("utf-8"))
            with open(path, "rb") as source:
                shutil.copyfileobj(source, stream)
            stream.write(b"\n")
        stream.flush()
        if previous is not None:
            os.chmod(temporary, previous[-1])
        os.fsync(stream.fileno())

    if output_state(output_path) != previous:
        raise ValueError(f"Output changed during generation; preserving it: {output_path}")
    os.replace(temporary, output_path)
    temporary = None

    for relative in skipped:
        print(f"  ~ Skipped output file: {relative}")
    for _, relative in inputs:
        print(f"  + {relative}")
    print(f"\n  ✓ {len(inputs)} file(s) collected → {output}")
    print("  Open and paste into your LLM.")
except (OSError, ValueError) as error:
    print(f"Error: {error}", file=sys.stderr)
    sys.exit(1)
finally:
    if descriptor is not None:
        os.close(descriptor)
    if temporary is not None:
        os.unlink(temporary)
PYEOF
}

# ── work-log ───────────────────────────────────────────
cmd_log() {
  require_config
  resolve_context_dir
  require_python

  local SUMMARY="" TITLE="" COMMIT="" FILES="" TYPE="work"
  while [ $# -gt 0 ]; do
    case "$1" in
      --summary|-s) SUMMARY="$2"; shift 2 ;;
      --title|-t) TITLE="$2"; shift 2 ;;
      --commit|-c) COMMIT="$2"; shift 2 ;;
      --files|-f) FILES="$2"; shift 2 ;;
      --type) TYPE="$2"; shift 2 ;;
      --help|-h)
        echo "Usage: bash ctx.sh log --summary \"...\" [--title \"...\"] [--commit <id>] [--files a,b] [--type work|docs|release]"
        return 0
        ;;
      -*) echo "Unknown option: $1" >&2; return 1 ;;
      *)
        if [ -z "$SUMMARY" ]; then SUMMARY="$1"; else SUMMARY="$SUMMARY $1"; fi
        shift
        ;;
    esac
  done

  if [ -z "$SUMMARY" ]; then
    echo "Usage: bash ctx.sh log --summary \"what changed\" [--commit <id>] [--title \"...\"]"
    return 1
  fi

  local LOG_DIR="$CONTEXT_DIR/work-log"
  local LOG_FILE="$LOG_DIR/timeline.jsonl"
  local CTX_COMMAND="bash ${SCRIPT_PATH#$PROJECT_ROOT/}"
  mkdir -p "$LOG_DIR"

  CTX_ROOT="$(py_path "$PROJECT_ROOT")" CTX_LOG_FILE="$(py_path "$LOG_FILE")" CTX_SUMMARY="$SUMMARY" CTX_TITLE="$TITLE" CTX_COMMIT="$COMMIT" CTX_FILES="$FILES" CTX_TYPE="$TYPE" CTX_COMMAND="$CTX_COMMAND" context_python << 'PYEOF'
import json
import os
from uuid import uuid4
from datetime import datetime, timezone

root = os.environ["CTX_ROOT"]
log_file = os.environ["CTX_LOG_FILE"]
summary = os.environ["CTX_SUMMARY"].strip()
if not summary:
    raise ValueError("Work-log summary must not be empty")
title = os.environ["CTX_TITLE"].strip() or summary.splitlines()[0][:80]
commit = os.environ["CTX_COMMIT"].strip()
files = [f.strip() for f in os.environ["CTX_FILES"].split(",") if f.strip()]
entry_type = os.environ["CTX_TYPE"].strip() or "work"
ctx_command = os.environ["CTX_COMMAND"].strip() or "bash ctx.sh"

status_args = ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."]
lock_path = os.path.relpath(os.path.join(os.environ["CTX_STORAGE_DIR"], "work-log", ".ctx.lock"), root)
if not (lock_path == ".." or lock_path.startswith(".." + os.sep)):
    status_args.append(":(exclude,literal)" + lock_path.replace(os.sep, "/"))
probe = git_output(root, ["rev-parse", "--is-inside-work-tree"], allow_no_repository=True)
in_worktree = probe is not None and probe.strip() == "true"
branch = git_output(root, ["branch", "--show-current"]).strip() if in_worktree else ""
status = git_output(root, status_args) if in_worktree else ""
dirty = bool(status)

full_commit = None
if not commit:
    commit = "uncommitted"
    if in_worktree and not dirty:
        full_commit = git_output(root, ["rev-parse", "--verify", "--quiet", "HEAD"],
                                 allow_unborn_head=True)
        if full_commit is not None:
            full_commit = full_commit.strip()
            commit = git_output(root, ["rev-parse", "--short", full_commit]).strip()

if commit == "uncommitted":
    full_commit = "uncommitted"
elif full_commit is None:
    full_commit = git_output(root, ["rev-parse", "--verify", "--end-of-options", commit]).strip()
else:
    full_commit = full_commit.strip()

if not files and commit != "uncommitted":
    files = git_paths(root, ["show", "--name-only", "--format=", "-z", full_commit, "--"])
elif not files:
    records = iter(status.split("\0"))
    for record in records:
        if not record:
            continue
        if len(record) < 4 or record[2] != " ":
            raise ValueError("Invalid Git status record")
        files.append(record[3:])
        # Porcelain -z lists the destination before the source for a rename/copy.
        if "R" in record[:2] or "C" in record[:2]:
            if not next(records, None):
                raise ValueError("Incomplete Git rename/copy status record")

entry = {
    "id": str(uuid4()),
    "createdAt": datetime.now(timezone.utc).isoformat(),
    "type": entry_type,
    "title": title,
    "summary": summary,
    "commit": commit,
    "fullCommit": full_commit,
    "branch": branch,
    "dirty": dirty,
    "files": files,
}

append_jsonl(log_file, entry)

readme = os.path.join(os.path.dirname(log_file), "README.md")
if not os.path.exists(readme):
    with open(readme, "w", encoding="utf-8") as f:
        f.write("# Work Log\n\n")
        f.write(f"Commit/work-unit timeline generated by `{ctx_command} log`.\n\n")
        f.write("- Source of truth: `timeline.jsonl`\n")
        f.write(f"- View: `{ctx_command} timeline --limit 20`\n")

print(f"Recorded work-log entry: {entry['commit']} — {entry['title']}")
print(f"Path: {os.path.relpath(log_file, root)}")
PYEOF
}

cmd_timeline() {
  require_config
  resolve_context_dir
  require_python

  local LIMIT="20" COMMIT="" JSON_MODE="false"
  while [ $# -gt 0 ]; do
    case "$1" in
      --limit|-n) LIMIT="$2"; shift 2 ;;
      --commit|-c) COMMIT="$2"; shift 2 ;;
      --json) JSON_MODE="true"; shift ;;
      --help|-h)
        echo "Usage: bash ctx.sh timeline [--limit 20] [--commit <id>] [--json]"
        return 0
        ;;
      *) echo "Unknown option: $1"; return 1 ;;
    esac
  done

  case "$LIMIT" in
    ''|*[!0-9]*) echo "Error: --limit requires a non-negative integer." >&2; return 1 ;;
  esac

  local LOG_FILE="$CONTEXT_DIR/work-log/timeline.jsonl"
  if [ ! -f "$LOG_FILE" ]; then
    echo "No work-log entries yet. Add one with: bash ctx.sh log --summary \"what changed\""
    return 0
  fi

  CTX_ROOT="$(py_path "$PROJECT_ROOT")" CTX_LOG_FILE="$(py_path "$LOG_FILE")" CTX_LIMIT="$LIMIT" CTX_COMMIT="$COMMIT" CTX_JSON="$JSON_MODE" ctx_python << 'PYEOF'
import json
import os

root = os.environ["CTX_ROOT"]
log_file = os.environ["CTX_LOG_FILE"]
limit = int(os.environ["CTX_LIMIT"])
commit_filter = os.environ["CTX_COMMIT"].strip()
json_mode = os.environ["CTX_JSON"] == "true"

entries = []
with open(log_file, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line:
            entries.append(json.loads(line))

if commit_filter:
    entries = [
        e for e in entries
        if e.get("commit", "").startswith(commit_filter) or e.get("fullCommit", "").startswith(commit_filter)
    ]

entries = list(reversed(entries))[:limit]

if json_mode:
    print(json.dumps(entries, ensure_ascii=False, indent=2))
    raise SystemExit

if not entries:
    print("No work-log entries matched.")
    raise SystemExit

print("[ctx timeline]")
print(f"Source: {os.path.relpath(log_file, root)}")
print("")

for entry in entries:
    dirty = " +dirty" if entry.get("dirty") else ""
    branch = f" ({entry.get('branch')})" if entry.get("branch") else ""
    print(f"- {entry.get('createdAt', '')[:10]} {entry.get('commit', 'uncommitted')}{dirty}{branch}")
    print(f"  {entry.get('title', '')}")
    summary = entry.get("summary", "")
    if summary and summary != entry.get("title", ""):
        for line in summary.splitlines()[:4]:
            print(f"  {line}")
    files = entry.get("files") or []
    if files:
        shown = ", ".join(files[:5])
        suffix = f" +{len(files) - 5} more" if len(files) > 5 else ""
        print(f"  files: {shown}{suffix}")
    print("")
PYEOF
}

# ── backfill ───────────────────────────────────────────
cmd_backfill() {
  require_config
  resolve_context_dir
  require_python

  local LIMIT="30" ALL_MODE="false" TYPE="work"
  while [ $# -gt 0 ]; do
    case "$1" in
      --limit|-n) LIMIT="$2"; shift 2 ;;
      --all)      ALL_MODE="true"; shift ;;
      --type)     TYPE="$2"; shift 2 ;;
      --help|-h)
        echo "Usage: bash ctx.sh backfill [--limit 30] [--all] [--type work|docs]"
        return 0
        ;;
      *) echo "Unknown option: $1"; return 1 ;;
    esac
  done

  case "$LIMIT" in
    ''|*[!0-9]*) echo "Error: --limit requires a non-negative integer." >&2; return 1 ;;
  esac

  if ! git -C "$PROJECT_ROOT" rev-parse HEAD >/dev/null 2>&1; then
    echo -e "${YELLOW}No Git commits found to backfill.${NC}"
    return 0
  fi

  local LOG_DIR="$CONTEXT_DIR/work-log"
  local LOG_FILE="$LOG_DIR/timeline.jsonl"
  mkdir -p "$LOG_DIR"

  CTX_ROOT="$(py_path "$PROJECT_ROOT")" CTX_LOG_FILE="$(py_path "$LOG_FILE")" CTX_LIMIT="$LIMIT" CTX_ALL="$ALL_MODE" CTX_TYPE="$TYPE" context_python << 'PYEOF'
import json
import os
import subprocess
from datetime import datetime, timezone

root = os.environ["CTX_ROOT"]
log_file = os.environ["CTX_LOG_FILE"]
limit = int(os.environ["CTX_LIMIT"])
all_mode = os.environ["CTX_ALL"] == "true"
entry_type = os.environ["CTX_TYPE"]

existing_commits = set()
legacy_commits = set()
existing_entries = read_jsonl(log_file)
for path in [log_file] + archive_timeline_paths():
    entries = existing_entries if path == log_file else read_jsonl(path)
    for entry in entries:
        if entry.get("fullCommit"):
            existing_commits.add(entry["fullCommit"])
        if entry.get("commit"):
            commit = entry["commit"]
            existing_commits.add(commit)
            if (not entry.get("fullCommit") and isinstance(commit, str)
                    and 4 <= len(commit) <= 64
                    and all(char in "0123456789abcdefABCDEF" for char in commit)):
                legacy_commits.add(commit)

if legacy_commits:
    references = sorted(legacy_commits)
    result = subprocess.run(
        ["git", "-C", root, "cat-file", "--batch-check=%(objectname) %(objecttype)"],
        input="\n".join(references) + "\n", text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode:
        raise ValueError("Cannot resolve existing commit references: " + result.stderr.strip())
    resolved = result.stdout.splitlines()
    if len(resolved) != len(references):
        raise ValueError("Incomplete Git response while resolving existing commit references")
    for reference, record in zip(references, resolved):
        object_id, kind = record.rsplit(" ", 1)
        if kind == "ambiguous":
            raise ValueError(f"Ambiguous existing commit reference: {reference}; record its full commit ID before backfill")
        if kind == "commit" and object_id.startswith(reference.lower()):
            existing_commits.add(object_id)

git_cmd = ["log", "-z", "--date=iso-strict", "--encoding=UTF-8", "--no-show-signature", "--no-notes"]
if not all_mode:
    git_cmd.extend(["-n", str(limit)])

git_cmd.extend(["--format=%x00%H%x00%h%x00%ad%x00%s%x00%b", "--name-only"])

fields = git_output(root, git_cmd).split("\0")
new_entries = []
index = 0

while index < len(fields) - 1:
    if fields[index] != "" or index + 6 >= len(fields):
        raise ValueError("Invalid NUL-delimited Git commit record")
    full_commit, short_commit, date_str, subject, body = fields[index + 1:index + 6]
    body = body.strip()
    index += 6
    files = []
    if fields[index]:
        # Git inserts one formatting newline before the first path, even with -z.
        if not fields[index].startswith("\n"):
            raise ValueError("Invalid Git commit file-list separator")
        files.append(fields[index][1:])
        index += 1
        while index < len(fields) and fields[index]:
            files.append(fields[index])
            index += 1

    if full_commit in existing_commits or short_commit in existing_commits:
        continue

    try:
        dt = datetime.fromisoformat(date_str)
        created_at = dt.astimezone(timezone.utc).isoformat()
        ts_id = dt.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    except Exception:
        created_at = date_str
        ts_id = "historic"

    summary = f"{subject}\n\n{body}".strip() if body else subject

    entry = {
        "id": f"{ts_id}-{short_commit}",
        "createdAt": created_at,
        "type": entry_type,
        "title": subject or f"Commit {short_commit}",
        "summary": summary,
        "commit": short_commit,
        "fullCommit": full_commit,
        "branch": "",
        "dirty": False,
        "files": files,
    }
    new_entries.append(entry)

if not new_entries:
    print(f"[ctx backfill] No new Git commits to backfill (already up to date).")
    raise SystemExit(0)

all_combined = existing_entries + new_entries
all_combined.sort(key=lambda x: x.get("createdAt", ""))

writes = []
readme = os.path.join(os.path.dirname(log_file), "README.md")
if not os.path.exists(readme):
    writes.append((readme,
        "# Work Log\n\n"
        "Commit/work-unit timeline generated by `ctx log` & `ctx backfill`.\n\n"
        "- Source of truth: `timeline.jsonl`\n"
        "- View: `ctx timeline --limit 20`\n"
    ))
writes.append((log_file, "".join(
    json.dumps(entry, ensure_ascii=False) + "\n" for entry in all_combined
)))
replace_staged_text_writes(stage_text_writes(writes))

print(f"[ctx backfill] ✓ Backfilled {len(new_entries)} commit(s) into timeline.jsonl")
PYEOF
}

# ── archive ────────────────────────────────────────────
cmd_archive() {
  require_config
  resolve_context_dir
  require_python

  local KEEP="30" DO_TASKS="true" DO_LOGS="true" DO_DECISIONS="true"
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep|-k)
        if [ $# -lt 2 ]; then
          echo "Error: --keep requires a non-negative integer." >&2
          return 1
        fi
        KEEP="$2"; shift 2
        ;;
      --no-tasks)     DO_TASKS="false"; shift ;;
      --no-logs)      DO_LOGS="false"; shift ;;
      --no-decisions) DO_DECISIONS="false"; shift ;;
      --help|-h)
        echo "Usage: bash ctx.sh archive [--keep 30] [--no-tasks] [--no-logs] [--no-decisions]"
        echo ""
        echo "Options:"
        echo "  --keep, -k <N>  Number of recent timeline entries to keep in timeline.jsonl (default: 30)"
        echo "  --no-tasks      Do not archive completed tasks from MASTER_PLAN.md"
        echo "  --no-logs       Do not archive timeline.jsonl logs"
        echo "  --no-decisions  Do not archive deprecated/superseded ADRs from decisions.md"
        return 0
        ;;
      *) echo "Unknown option: $1"; return 1 ;;
    esac
  done

  case "$KEEP" in
    ''|*[!0-9]*)
      echo "Error: --keep requires a non-negative integer." >&2
      return 1
      ;;
  esac

  echo -e "${BOLD}[ctx archive] Archiving completed tasks, old logs, and deprecated decisions${NC}"
  echo ""

  local ARCHIVE_DIR="$CONTEXT_DIR/archive"
  mkdir -p "$ARCHIVE_DIR"

  CTX_ROOT="$(py_path "$PROJECT_ROOT")" CTX_DIR="$(py_path "$CONTEXT_DIR")" CTX_KEEP="$KEEP" CTX_TASKS="$DO_TASKS" CTX_LOGS="$DO_LOGS" CTX_DECISIONS="$DO_DECISIONS" context_python << 'PYEOF'
import json
import os
import re
from datetime import datetime

context_dir = os.environ["CTX_DIR"]
archive_dir = os.path.join(context_dir, "archive")
os.makedirs(archive_dir, exist_ok=True)
keep_count = int(os.environ["CTX_KEEP"])
do_tasks = os.environ["CTX_TASKS"] == "true"
do_logs = os.environ["CTX_LOGS"] == "true"
do_decisions = os.environ.get("CTX_DECISIONS", "true") == "true"

today_str = datetime.now().strftime("%Y-%m-%d")

# Validate every JSONL input before preparing any source changes. Existing
# archive months also feed the digest, including months receiving no new logs.
timeline_path = os.path.join(context_dir, "work-log", "timeline.jsonl")
entries = read_jsonl(timeline_path) if do_logs else []
archive_entries = {
    name: read_jsonl(os.path.join(archive_dir, name))
    for name in sorted(os.listdir(archive_dir))
    if name.startswith("timeline-") and name.endswith(".jsonl")
}
destination_writes = []
source_writes = []
messages = []


def read_text(path):
    if not os.path.exists(path):
        return ""
    with open(path, encoding="utf-8") as stream:
        return stream.read()


def jsonl_text(records):
    return "".join(json.dumps(record, ensure_ascii=False) + "\n" for record in records)


# Prepare task archival without changing MASTER_PLAN.md yet.
if do_tasks:
    master_plan_path = os.path.join(context_dir, "MASTER_PLAN.md")
    if os.path.exists(master_plan_path):
        with open(master_plan_path, "r", encoding="utf-8") as f:
            lines = f.readlines()

        new_lines = []
        completed_tasks = []
        task_regex = re.compile(r"^\s*[-*]\s*\[[xX]\]\s*(.*)$")

        for line in lines:
            m = task_regex.match(line)
            if m:
                completed_tasks.append(line.rstrip())
            else:
                new_lines.append(line)

        if completed_tasks:
            full_text = "".join(new_lines)
            if "archive/completed-tasks.md" not in full_text:
                header_m = re.search(r"(#\s+.*?\n)", full_text)
                notice = f"\n> 📦 Archived completed tasks: `archive/completed-tasks.md`\n"
                if header_m:
                    idx = header_m.end()
                    full_text = full_text[:idx] + notice + full_text[idx:]
                else:
                    full_text = notice + full_text
                new_lines = [full_text]

            archive_task_path = os.path.join(archive_dir, "completed-tasks.md")
            archived = read_text(archive_task_path)
            if not os.path.exists(archive_task_path):
                archived = "# Completed Tasks Archive\n\n> Historical record of completed tasks moved from MASTER_PLAN.md\n\n"
            archived += f"\n### Archived on {today_str}\n\n"
            archived += "".join(task + "\n" for task in completed_tasks)
            destination_writes.append((archive_task_path, archived))
            source_writes.append((master_plan_path, "".join(new_lines)))
            messages.append(f"  ✓ Archived {len(completed_tasks)} completed task(s) → archive/completed-tasks.md")
        else:
            messages.append("  ~ No completed tasks to archive in MASTER_PLAN.md")

# Prepare deprecated/superseded decision archival.
if do_decisions:
    decisions_path = os.path.join(context_dir, "decisions.md")
    if os.path.exists(decisions_path):
        with open(decisions_path, "r", encoding="utf-8") as f:
            content = f.read()

        adr_pattern = re.compile(r"(?=(?:^#{2,4}\s+(?:\[?ADR[-_#\d]|\[ADR|ADR\s*:\s*|ADR\s+\d+)))", re.MULTILINE)
        sections = adr_pattern.split(content)
        header = sections[0]
        adrs = sections[1:]

        active_adrs = []
        deprecated_adrs = []
        dep_regex = re.compile(
            r"(?:\*{0,2}(?:상태|Status)\*{0,2}\s*:\s*\*{0,2}(?:대체됨|폐기됨|Superseded|Deprecated|Obsolete|Cancelled)|\[\s*(?:Status|상태)\s*:\s*(?:대체됨|폐기됨|Superseded|Deprecated|Obsolete|Cancelled)[^\]]*\])",
            re.IGNORECASE
        )

        for adr in adrs:
            if dep_regex.search(adr):
                deprecated_adrs.append(adr.strip())
            else:
                active_adrs.append(adr.strip())

        if deprecated_adrs:
            archive_dec_path = os.path.join(archive_dir, "decisions-deprecated.md")
            archived = read_text(archive_dec_path)
            if not os.path.exists(archive_dec_path):
                archived = "# Deprecated Architecture Decisions Archive\n\n> Historical record of deprecated or superseded ADRs moved from decisions.md\n\n---\n\n"
            archived += f"\n### Archived on {today_str}\n\n"
            archived += "".join(adr + "\n\n---\n\n" for adr in deprecated_adrs)
            destination_writes.append((archive_dec_path, archived))

            if "archive/decisions-deprecated.md" not in header:
                header_m = re.search(r"(#\s+.*?\n)", header)
                notice = f"\n> 📦 Archived Deprecated ADRs: `archive/decisions-deprecated.md`\n"
                if header_m:
                    idx = header_m.end()
                    header = header[:idx] + notice + header[idx:]
                else:
                    header = notice + header

            new_decisions_content = header.rstrip() + "\n\n"
            for a in active_adrs:
                new_decisions_content += a + "\n\n"

            source_writes.append((decisions_path, new_decisions_content))
            messages.append(f"  ✓ Archived {len(deprecated_adrs)} deprecated ADR(s) → archive/decisions-deprecated.md")
        else:
            messages.append("  ~ No deprecated ADRs to archive in decisions.md")

# Every moving row is a distinct occurrence, even with identical legacy data.
# The transaction journal identifies interrupted retries without deduplication.
archived_log_count = 0
if do_logs and os.path.exists(timeline_path):
    if len(entries) > keep_count:
        cutoff = len(entries) - keep_count
        to_archive = entries[:cutoff]
        to_keep = entries[cutoff:]

        monthly_groups = {}
        for item in to_archive:
            created = item.get("createdAt", "")
            month = created[:7] if re.match(r"^\d{4}-\d{2}", created) else "legacy"
            monthly_groups.setdefault(month, []).append(item)

        for month, group in monthly_groups.items():
            name = f"timeline-{month}.jsonl"
            monthly_entries = list(archive_entries.get(name, []))
            monthly_entries.extend(group)
            archived_log_count += len(group)
            archive_entries[name] = monthly_entries
            destination_writes.append((os.path.join(archive_dir, name), jsonl_text(monthly_entries)))

        source_writes.append((timeline_path, jsonl_text(to_keep)))
        messages.append(f"  ✓ Archived {archived_log_count} log entries → archive/timeline-YYYY-MM.jsonl (kept {len(to_keep)} active)")
    else:
        messages.append(f"  ~ Timeline entries ({len(entries)}) <= keep threshold ({keep_count}), no logs to archive")

# Build the digest from the prospective archive before replacing any files.
digest_writes = []
if archive_entries:
    digest_path = os.path.join(context_dir, "work-log", "timeline-digest.md")
    digest = [
        "# Timeline Digest & Milestones\n\n",
        "> Compressed summary of archived past work units and milestones.\n",
        f"> Last Generated: {today_str}\n\n",
    ]
    for name, month_entries in sorted(archive_entries.items()):
        month_label = name[len("timeline-"):-len(".jsonl")]
        if month_entries:
            digest.append(f"## Milestone {month_label} ({len(month_entries)} units)\n\n")
            for entry in month_entries:
                date_prefix = entry.get("createdAt", "")[:10]
                title = entry.get("title", "")
                commit = entry.get("commit", "")
                commit_tag = f" `[{commit}]`" if commit and commit not in ("uncommitted", "pending") else ""
                digest.append(f"- **{date_prefix}**: {title}{commit_tag}\n")
            digest.append("\n")
    digest_writes.append((digest_path, "".join(digest)))
    messages.append("  ✓ Generated warm milestone digest → work-log/timeline-digest.md")

# Stage everything before persisting the recovery journal and replacing files.
# The journal rolls interrupted replacements forward before the next writer,
# preserving each occurrence without mistaking matching new rows for retries.
writes = destination_writes + digest_writes + source_writes
transactional_text_writes(writes)
for message in messages:
    print(message)
PYEOF

  # 4. Auto-commit archives to local context Git if initialized
  if [ -d "$CONTEXT_DIR/.git" ]; then
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    context_git_commit "chore(context): archive completed tasks, past logs, and decisions ($timestamp)" \
      "  ✓ Auto-committed archives to local context Git."
  fi

  echo ""
  echo -e "${GREEN}🎉 Archiving complete!${NC}"
  echo "  Active context is now compact and optimized for AI sessions."
}

# ── hook ───────────────────────────────────────────────
_manage_pre_commit_hook() {
  ctx_python - "$1" "$(py_path "$PROJECT_ROOT/.git/hooks/pre-commit")" <<'PYEOF'
import errno
import os
import stat
import sys
import tempfile

action, hook = sys.argv[1:]
backup = hook + ".ctx-kit-original"
begin = b"# --- BEGIN CTX-KIT GIT-SYNC HOOK ---"
end = b"# --- END CTX-KIT GIT-SYNC HOOK ---"
ctx_block = b'''if [ -f "ctx.sh" ]; then
  bash ctx.sh _hook_run_pre_commit
elif [ -f "scripts/ctx.sh" ]; then
  bash scripts/ctx.sh _hook_run_pre_commit
fi
'''
legacy = b"\n" + begin + b"\n" + ctx_block + end + b"\n"
previous = b'''ctx_original_hook="$(dirname "$0")/pre-commit.ctx-kit-original"
'''
with_original = previous + b'''if [ ! -e "$ctx_original_hook" ] && [ ! -L "$ctx_original_hook" ]; then
  echo "Error: original pre-commit hook is missing: $ctx_original_hook" >&2
  exit 1
fi
if [ -x "$ctx_original_hook" ]; then
  "$ctx_original_hook" "$@"
  ctx_original_status=$?
  if [ "$ctx_original_status" -ne 0 ]; then
    exit "$ctx_original_status"
  fi
fi
'''
without_original = previous + b'''if [ -e "$ctx_original_hook" ] || [ -L "$ctx_original_hook" ]; then
  echo "Error: unexpected pre-commit hook backup: $ctx_original_hook" >&2
  exit 1
fi
'''

def wrapper(original):
    return (b"#!/bin/sh\n" + begin + b"\n"
            + (with_original if original else without_original) + ctx_block + end + b"\n")

def inspect(path):
    if not os.path.lexists(path):
        return None
    info = os.lstat(path)
    if not (stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)):
        raise ValueError(f"Refusing non-file hook path: {path}")
    return info

def replace_text(path, content, mode):
    fd, temporary = tempfile.mkstemp(prefix=".ctx-hook-", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            os.chmod(temporary, mode)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

try:
    info = inspect(hook)
    saved = inspect(backup)
    if info is not None and stat.S_ISLNK(info.st_mode):
        try:
            os.stat(hook)
        except FileNotFoundError:
            pass
        except OSError as error:
            if error.errno == errno.ELOOP:
                raise ValueError(f"Refusing cyclic original hook symlink: {hook}") from error
            raise
    content = None
    legacy_hook = False
    if info is not None and os.path.isfile(hook):
        with open(hook, "rb") as stream:
            content = stream.read()
    managed = info is not None and not stat.S_ISLNK(info.st_mode) and content in (wrapper(True), wrapper(False))
    if managed:
        original = content == wrapper(True)
        if original != (saved is not None):
            raise ValueError(f"Original pre-commit hook backup is missing or unexpected: {backup}. Preserve both paths and reconcile before retrying.")
    else:
        if saved is not None:
            raise ValueError(f"Hook backup already exists: {backup}. Preserve both hooks; refusing to overwrite either.")
        original = info is not None
        if content is not None and (begin in content or end in content):
            if (stat.S_ISLNK(info.st_mode) or not content.endswith(legacy)
                    or content.count(begin) != 1 or content.count(end) != 1):
                raise ValueError(f"Modified or unrecognized ctx hook: {hook}. Preserve it and reconcile before retrying.")
            content = content[:-len(legacy)]
            legacy_hook = True

    if action == "check-install":
        pass
    elif action == "install":
        if managed:
            print("  Pre-commit hook already installed in .git/hooks/pre-commit")
        else:
            os.makedirs(os.path.dirname(hook), exist_ok=True)
            if original:
                if stat.S_ISLNK(info.st_mode):
                    os.symlink(os.readlink(hook), backup)
                elif content is not None:
                    # Exclusive creation protects an unrelated or concurrent backup.
                    with open(backup, "xb") as stream:
                        stream.write(content)
                        os.chmod(backup, stat.S_IMODE(info.st_mode))
                        stream.flush()
                        os.fsync(stream.fileno())
            replace_text(hook, wrapper(original), 0o755)
            print("  Installed pre-commit wrapper in .git/hooks/pre-commit")
    elif action == "uninstall":
        if managed:
            if original:
                os.replace(backup, hook)
                print("  Restored original pre-commit hook")
            else:
                os.unlink(hook)
                print("  Removed ctx-kit pre-commit hook")
        elif legacy_hook:
            replace_text(hook, content, stat.S_IMODE(info.st_mode))
            print("  Removed legacy ctx-kit hook block")
        else:
            print("  ctx-kit hook is not installed in .git/hooks/pre-commit")
    else:
        raise ValueError(f"Unknown hook action: {action}")
except (OSError, ValueError) as error:
    print(f"Error: {error}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

cmd_hook() {
  case "${1:-status}" in
    install)   _hook_install ;;
    uninstall) _hook_uninstall ;;
    status)    _hook_status ;;
    *)
      echo "Usage: bash ctx.sh hook [install|uninstall|status]"
      return 1
      ;;
  esac
}

_hook_install() {
  require_config
  resolve_context_dir

  if [ ! -d "$PROJECT_ROOT/.git" ]; then
    echo -e "${RED}Error: $PROJECT_ROOT is not a Git repository (.git not found).${NC}" >&2
    return 1
  fi

  # Refuse ambiguous hook/backup state before changing project configuration.
  _manage_pre_commit_hook check-install

  local rel_context_dir="${CONTEXT_DIR#$PROJECT_ROOT/}"
  local ignore_pattern
  ignore_pattern=$(ctx_python - "$(py_path "$CONFIG")" "$rel_context_dir" <<'PY'
import json
import os
import sys

# Bash command substitution strips trailing LF; validate the original JSON path.
with open(sys.argv[1], encoding="utf-8") as stream:
    source = json.load(stream).get("source", "sample-context/AGENT_RULES.md")
raw_context = os.path.dirname(source) or "sample-context"
if "\n" in raw_context or "\r" in raw_context:
    print("Error: context paths with line breaks cannot be added to .gitignore.", file=sys.stderr)
    sys.exit(1)
path = os.path.normpath(sys.argv[2]).replace(os.sep, "/")
sys.stdout.reconfigure(newline="\n")
escaped = "".join("\\" + char if char in "\\*?[]!# " else char for char in path)
print("/" + escaped + "/")
PY
  ) || return $?
  echo -e "${BOLD}[ctx hook install] Configuring Git integration for '${rel_context_dir}'${NC}"

  # 1) Check if already ignored (in .gitignore or .git/info/exclude)
  if git -C "$PROJECT_ROOT" check-ignore -q -- "$rel_context_dir/"; then
    echo -e "  ${GREEN}✓${NC} ${rel_context_dir}/ is already ignored by Git (.gitignore or .git/info/exclude)"
  else
    local ignore_status=$?
    if [ "$ignore_status" -ne 1 ]; then
      echo "Error: git check-ignore failed; leaving Git integration unchanged." >&2
      return "$ignore_status"
    fi
    local gitignore="$PROJECT_ROOT/.gitignore"
    printf '\n%s\n%s\n' '# Local private AI context (ctx-kit, never pushed)' "$ignore_pattern" >> "$gitignore" || return $?
    if ! git -C "$PROJECT_ROOT" check-ignore -q -- "$rel_context_dir/"; then
      echo "Error: context directory is still not ignored; stopping Git integration setup." >&2
      return 1
    fi
    echo -e "  ${GREEN}✓${NC} Added ${rel_context_dir}/ to .gitignore"
  fi

  # 2) Initialize independent Git in context directory
  mkdir -p "$CONTEXT_DIR"
  if [ ! -d "$CONTEXT_DIR/.git" ]; then
    ctx_git init --quiet
    context_git_commit "chore: initialize local context repository" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} Initialized independent Git repository in ${rel_context_dir}/"
  else
    echo -e "  ${YELLOW}~${NC} ${rel_context_dir}/ is already an initialized Git repo"
  fi

  # 3) Ensure git_sync is enabled in ctx.config.json
  config_python << 'PYEOF'
import json
import os
cfg_file = os.environ["CTX_CONFIG"]
with open(cfg_file, encoding="utf-8") as f:
    data = json.load(f)
if "git_sync" not in data or not isinstance(data["git_sync"], dict):
    data["git_sync"] = {}
data["git_sync"]["enabled"] = True
if "auto_log" not in data["git_sync"]:
    data["git_sync"]["auto_log"] = True
write_config(data)
PYEOF
  echo -e "  ${GREEN}✓${NC} Enabled git_sync in ctx.config.json (auto_log: true)"

  # 4) Chain the original hook without changing its interpreter or exit behavior.
  _manage_pre_commit_hook install

  echo -e "\n${GREEN}🎉 Git sync hook setup complete!${NC}"
  echo "  - Changes in ${rel_context_dir}/ will be auto-committed locally on 'git commit'"
  echo "  - auto_log is ENABLED: commit changes will be summarized into timeline.jsonl before each commit"
  echo "  - (To disable auto-log, set \"auto_log\": false under \"git_sync\" in ctx.config.json)"
}

_hook_uninstall() {
  require_config
  require_python
  _manage_pre_commit_hook uninstall

  config_python << 'PYEOF'
import json
import os
cfg_file = os.environ["CTX_CONFIG"]
with open(cfg_file, encoding="utf-8") as f:
    data = json.load(f)
if "git_sync" in data and isinstance(data["git_sync"], dict):
    data["git_sync"]["enabled"] = False
write_config(data)
PYEOF
  echo -e "  ${GREEN}✓${NC} Disabled git_sync in ctx.config.json"
}

_hook_status() {
  require_config
  resolve_context_dir
  local rel_context_dir="${CONTEXT_DIR#$PROJECT_ROOT/}"
  local hook_file="$PROJECT_ROOT/.git/hooks/pre-commit"
  local HOOK_BEGIN="# --- BEGIN CTX-KIT GIT-SYNC HOOK ---"

  echo -e "${BOLD}[ctx hook status]${NC}"
  echo "  Project root:    $PROJECT_ROOT"
  echo "  Context dir:     $rel_context_dir"

  local cfg_status
  cfg_status=$(ctx_python -c '
import json, sys
sys.stdout.reconfigure(newline="\n")
with open(sys.argv[1], encoding="utf-8") as f: d=json.load(f)
gs = d.get("git_sync", {})
print("{}|{}".format(gs.get("enabled", False), gs.get("auto_log", False)))' "$(py_path "$CONFIG")")
  local cfg_enabled="${cfg_status%|*}"
  local cfg_autolog="${cfg_status#*|}"

  if [ "$cfg_enabled" = "True" ]; then
    echo -e "  git_sync:        ${GREEN}Enabled${NC} (auto_log: $cfg_autolog)"
  else
    echo -e "  git_sync:        ${YELLOW}Disabled${NC} (auto_log: $cfg_autolog)"
  fi

  if [ -f "$hook_file" ] && grep -q "$HOOK_BEGIN" "$hook_file"; then
    echo -e "  pre-commit hook: ${GREEN}Installed${NC} ($hook_file)"
  else
    echo -e "  pre-commit hook: ${RED}Not installed${NC}"
  fi

  if git -C "$PROJECT_ROOT" check-ignore -q -- "$rel_context_dir/" 2>/dev/null; then
    echo -e "  Git exclusion:   ${GREEN}Ignored${NC} (${rel_context_dir}/ is safe from remote push)"
  else
    echo -e "  Git exclusion:   ${RED}Not ignored!${NC} (Warning: context may be tracked by main repo)"
  fi

  if [ -d "$CONTEXT_DIR/.git" ]; then
    local ctx_commits
    ctx_commits=$(ctx_git rev-list --count HEAD 2>/dev/null || echo "0")
    echo -e "  Local Git repo:  ${GREEN}Active${NC} (${ctx_commits} local commit(s))"
  else
    echo -e "  Local Git repo:  ${RED}Not initialized${NC}"
  fi
}

_hook_run_pre_commit() {
  require_config
  resolve_context_dir
  require_python

  local rel_context_dir="${CONTEXT_DIR#$PROJECT_ROOT/}"

  local cfg_status
  cfg_status=$(ctx_python -c '
import json, sys
sys.stdout.reconfigure(newline="\n")
with open(sys.argv[1], encoding="utf-8") as f: d=json.load(f)
gs = d.get("git_sync", {})
print("{}|{}".format(gs.get("enabled", False), gs.get("auto_log", False)))' "$(py_path "$CONFIG")")
  local cfg_enabled="${cfg_status%|*}"
  local cfg_autolog="${cfg_status#*|}"

  if [ "$cfg_enabled" != "True" ]; then
    exit 0
  fi

  if [ "$cfg_autolog" = "True" ]; then
    local LOG_DIR="$CONTEXT_DIR/work-log"
    local LOG_FILE="$LOG_DIR/timeline.jsonl"
    mkdir -p "$LOG_DIR"

    CTX_ROOT="$(py_path "$PROJECT_ROOT")" CTX_LOG_FILE="$(py_path "$LOG_FILE")" context_python << 'PYEOF'
import os
from uuid import uuid4
from datetime import datetime, timezone

root = os.environ["CTX_ROOT"]
log_file = os.environ["CTX_LOG_FILE"]

diff_args = ["diff", "--cached", "--", "."]
context_relative = os.path.relpath(os.environ["CTX_STORAGE_DIR"], root)
if not (context_relative == ".." or context_relative.startswith(".." + os.sep)):
    diff_args.append(":(exclude,literal)" + context_relative.replace(os.sep, "/") + "/")
staged_names = git_paths(root, diff_args[:2] + ["--name-only", "-z"] + diff_args[2:])

if staged_names:
    diff_stat = git_output(root, diff_args[:2] + ["--stat"] + diff_args[2:]).strip()
    branch = git_output(root, ["branch", "--show-current"]).strip()
    short_files = staged_names[:3]
    file_summary = ", ".join(os.path.basename(f) for f in short_files)
    if len(staged_names) > 3:
        file_summary += f" +{len(staged_names)-3} more"

    title = f"Changes in {file_summary}"
    summary = f"Pre-commit auto-log for {len(staged_names)} staged file(s).\n\nDiff stat:\n{diff_stat}"
    now = datetime.now(timezone.utc)

    entry = {
        "id": str(uuid4()),
        "createdAt": now.isoformat(),
        "type": "work",
        "title": title,
        "summary": summary,
        "commit": "pending",
        "fullCommit": "pending",
        "branch": branch,
        "dirty": True,
        "files": staged_names,
    }

    append_jsonl(log_file, entry)

    print(f"[ctx] 📝 Auto-recorded work-log before commit: {title}")
PYEOF
  fi

  if [ -d "$CONTEXT_DIR/.git" ]; then
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    context_git_commit "Auto-sync local context ($timestamp)" \
      "[ctx] 🔒 Auto-committed local context (${rel_context_dir}) to local Git."
  fi

  exit 0
}

# ── view ───────────────────────────────────────────────
cmd_view() {
  local view_output="" view_open="0"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h)
        echo "Usage: bash ${SCRIPT_PATH#$PROJECT_ROOT/} view [--output PATH.html] [--open]"
        echo "Generate one offline HTML snapshot from context documents and work logs."
        echo "  --output PATH  Project-relative or in-project absolute .html path"
        echo "                 Default: <context>/generated/view.html"
        echo "  --open         Open the generated snapshot in the default browser"
        echo "Regenerate to refresh. The HTML contains full logs; review before sharing."
        return 0
        ;;
      --output)
        if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then
          echo "Error: --output requires a non-empty .html path." >&2
          return 1
        fi
        view_output="$2"
        shift 2
        ;;
      --open) view_open="1"; shift ;;
      *) echo "Error: unknown view argument: $1" >&2; return 1 ;;
    esac
  done
  require_config
  require_python
  CONTEXT_DIR=$(ctx_python - "$(py_path "$CONFIG")" "$(py_path "$PROJECT_ROOT")" <<'PYEOF'
import json
import os
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        config = json.load(stream)
    if not isinstance(config, dict):
        raise ValueError("ctx.config.json must contain an object")
    source = config.get("source", "sample-context/AGENT_RULES.md")
    if not isinstance(source, str) or not source or "\0" in source:
        raise ValueError("Configuration source must be a non-empty path")
    sys.stdout.reconfigure(newline="\n")
    print(os.path.abspath(os.path.join(sys.argv[2], os.path.dirname(source) or "sample-context")))
except (OSError, ValueError, RecursionError) as error:
    print("Error: {}".format(error), file=sys.stderr)
    sys.exit(1)
PYEOF
  ) || return $?
  CTX_VIEW_PROJECT="$(py_path "$PROJECT_ROOT")" CTX_VIEW_CONFIG="$(py_path "$CONFIG")" \
    CTX_VIEW_SCRIPT="$(py_path "$SCRIPT_PATH")" CTX_VIEW_OUTPUT="$view_output" \
    CTX_VIEW_OPEN="$view_open" context_python --read-only <<'PYEOF'
# CTX_VIEW_IMPLEMENTATION_START
# Viewer sources are read under the existing writer lock without recovery.
import datetime
import math
import re


VIEW_INPUT_BYTES = 20 * 1024 * 1024
VIEW_ENTRY_LIMIT = 20000
VIEW_DOCUMENTS = (
    ("plan", "MASTER_PLAN.md"), ("decisions", "decisions.md"),
    ("backlog", "backlog.md"), ("digest", "work-log/timeline-digest.md"),
    ("completed", "archive/completed-tasks.md"),
    ("deprecated", "archive/decisions-deprecated.md"),
)


def _view_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def _view_warning(code, message, source=None):
    return {"code": code, "message": message, "source": source}


def _view_inside(root, path):
    try:
        return os.path.commonpath([root, os.path.realpath(path)]) == root
    except ValueError:
        return False


def _view_check_input_path(context, relative):
    path = context
    parts = relative.split("/")
    for index, part in enumerate(parts):
        path = os.path.join(path, part)
        if not _view_inside(context, path):
            raise ValueError("Viewer input is outside context: " + relative)
        try:
            info = os.lstat(path)
        except FileNotFoundError:
            return
        if stat.S_ISLNK(info.st_mode):
            raise ValueError("Viewer refuses symbolic-link input: " + relative)
        if index < len(parts) - 1 and not stat.S_ISDIR(info.st_mode):
            raise ValueError("Viewer input parent is not a directory: " + relative)
        if index == len(parts) - 1 and not stat.S_ISREG(info.st_mode):
            raise ValueError("Viewer input is not a regular file: " + relative)


def _view_read_regular(path, label, limit):
    try:
        initial = os.lstat(path)
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(initial.st_mode):
        raise ValueError("Viewer input is not a regular file: " + label)
    if initial.st_size > limit:
        raise ValueError("Viewer input exceeds 20 MiB limit: " + label)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    descriptor = os.open(path, flags)
    with os.fdopen(descriptor, "rb") as stream:
        opened = os.fstat(stream.fileno())
        if (not stat.S_ISREG(opened.st_mode)
                or (initial.st_dev, initial.st_ino) != (opened.st_dev, opened.st_ino)):
            raise ValueError("Viewer input changed while opening: " + label)
        data = stream.read(limit + 1)
        finished = os.fstat(stream.fileno())
    if len(data) > limit:
        raise ValueError("Viewer input exceeds 20 MiB limit: " + label)
    fingerprint = (finished.st_dev, finished.st_ino, finished.st_size,
                   finished.st_mtime_ns, finished.st_ctime_ns,
                   hashlib.sha256(data).digest())
    # A subsequent complete read also checks replacement and same-size edits.
    return data, fingerprint


def _view_source_paths(context):
    for name in ("work-log", "archive"):
        path = os.path.join(context, name)
        if os.path.lexists(path):
            info = os.lstat(path)
            if not stat.S_ISDIR(info.st_mode):
                raise ValueError("Viewer input directory is not a real directory: " + name)
    paths = [relative for _, relative in VIEW_DOCUMENTS]
    paths.append("work-log/timeline.jsonl")
    archive = os.path.join(context, "archive")
    if os.path.isdir(archive):
        paths.extend("archive/" + name for name in sorted(os.listdir(archive))
                     if name.startswith("timeline-") and name.endswith(".jsonl"))
    return paths


def _view_read_sources(context, config_path):
    paths = _view_source_paths(context)
    result = {}
    total = 0
    config = _view_read_regular(config_path, "ctx.config.json", VIEW_INPUT_BYTES)
    if config is None:
        raise ValueError("ctx.config.json is missing; run bash ctx.sh init")
    total += len(config[0])
    for relative in paths:
        _view_check_input_path(context, relative)
        read = _view_read_regular(os.path.join(context, *relative.split("/")), relative,
                                  max(0, VIEW_INPUT_BYTES - total))
        result[relative] = read
        if read is not None:
            total += len(read[0])
    return paths, config, result


def _view_decode(data, label):
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as error:
        number = data[:error.start].count(b"\n") + 1
        raise ValueError("{}: invalid UTF-8 at line {}".format(label, number)) from error


def _view_json_constant(value):
    raise ValueError("Non-standard JSON constant: " + value)


def _view_json_float(value):
    number = float(value)
    if not math.isfinite(number):
        raise ValueError("Out-of-range JSON number: " + value)
    return number


def _view_commit_ref(record):
    commit = record.get("commit")
    if isinstance(commit, str) and commit:
        return commit
    if commit is not None and not isinstance(commit, str):
        return None
    full_commit = record.get("fullCommit")
    return full_commit if isinstance(full_commit, str) and full_commit else None


def collect_snapshot(project_root, context_dir, config_path, output_path):
    project = os.path.realpath(os.fspath(project_root))
    context = os.path.realpath(os.fspath(context_dir))
    config_path = os.path.abspath(os.fspath(config_path))
    if not _view_inside(project, context):
        raise ValueError("Viewer context must be inside the project")
    if not os.path.isdir(context):
        raise ValueError("Context directory is missing; run bash ctx.sh init")
    started = _view_now()
    # Validate parents and lock before context_lock can create or open anything.
    _view_source_paths(context)
    _view_check_input_path(context, "work-log/.ctx.lock")
    for attempt in range(2):
        with context_lock():
            journal = os.path.join(context, "work-log", ".ctx-archive-transaction.json")
            if os.path.lexists(journal):
                raise ValueError("Incomplete archive transaction: work-log/.ctx-archive-transaction.json. "
                                 "Viewer will not recover it; follow the archive recovery guide before retrying.")
            first = _view_read_sources(context, config_path)
            second = _view_read_sources(context, config_path)
            if first != second:
                if attempt == 0:
                    continue
                raise ValueError("Viewer sources changed during collection; retry after editing stops")
            paths, config_data, source_data = first
            config_text = _view_decode(config_data[0], "ctx.config.json")
            try:
                config = json.loads(config_text, parse_constant=_view_json_constant, parse_float=_view_json_float)
            except (ValueError, RecursionError) as error:
                raise ValueError("Invalid viewer configuration: " + str(error)) from error
            if not isinstance(config, dict):
                raise ValueError("Viewer configuration must be a JSON object")
            source = config.get("source", "sample-context/AGENT_RULES.md")
            if not isinstance(source, str) or not source:
                raise ValueError("Viewer configuration source must be a nonempty string")
            selected = os.path.dirname(source) or "sample-context"
            configured_context = os.path.realpath(os.path.join(project, selected))
            if configured_context != context:
                raise ValueError("Viewer configuration changed context; retry the command")
            break
    documents = []
    for key, relative in VIEW_DOCUMENTS:
        content = source_data[relative]
        documents.append({"key": key, "path": relative, "sourceKind": "document",
                          "status": "present" if content is not None else "missing",
                          "text": _view_decode(content[0], relative) if content is not None else ""})
    entries = []
    for relative in paths:
        if not relative.endswith(".jsonl") or source_data[relative] is None:
            continue
        text = _view_decode(source_data[relative][0], relative)
        for number, line in enumerate(text.split("\n"), 1):
            if not line.strip():
                continue
            try:
                record = json.loads(line, parse_constant=_view_json_constant, parse_float=_view_json_float)
            except (ValueError, RecursionError) as error:
                raise ValueError("{}: invalid JSON at line {}: {}".format(relative, number, error)) from error
            if not isinstance(record, dict):
                raise ValueError("{}: expected a JSON object at line {}".format(relative, number))
            entries.append({"key": "{}:{}".format(relative, number), "sourceKind": "work_log",
                            "sourcePath": relative, "sourceLine": number, "record": record,
                            "recordText": line})
            if len(entries) > VIEW_ENTRY_LIMIT:
                raise ValueError("Viewer exceeds 20000 work-log entries; no records were omitted")
    refs = sorted({ref for ref in (_view_commit_ref(entry["record"]) for entry in entries)
                   if ref is not None and ref not in ("pending", "uncommitted")})
    protected = [config_path] + [os.path.join(context, *path.split("/")) for path in paths]
    script = os.environ.get("CTX_VIEW_SCRIPT", os.path.join(project, "ctx.sh"))
    protected.extend([script, os.path.join(context, "work-log", ".ctx.lock"), journal])
    return {"project": {"name": os.path.basename(project),
                        "contextPath": os.path.relpath(context, project).replace(os.sep, "/")},
            "documents": documents, "entries": entries, "warnings": [],
            "collectionStartedAt": started, "collectionFinishedAt": _view_now(),
            "protectedInputs": protected,
            "excludedPaths": [os.path.abspath(os.fspath(output_path)),
                              os.path.realpath(os.fspath(output_path)),
                              os.path.join(context, "work-log", ".ctx.lock")],
            "commitRefs": refs}


def _view_git_changes(raw):
    if raw and not raw.endswith(b"\0"):
        raise ValueError("Incomplete NUL-delimited Git status")
    fields = raw.split(b"\0")
    changes = []
    index = 0
    while index < len(fields) - 1:
        item = fields[index]
        index += 1
        if len(item) < 4 or item[2:3] != b" ":
            raise ValueError("Malformed Git status record")
        status_text = item[:2].decode("ascii")
        path = item[3:].decode("utf-8")
        previous = None
        if "R" in status_text or "C" in status_text:
            if index >= len(fields) - 1:
                raise ValueError("Incomplete Git rename/copy status")
            previous = fields[index].decode("utf-8")
            index += 1
        changes.append({"path": path, "status": status_text, "previousPath": previous})
    return changes


def collect_git_snapshot(project_root, excluded_paths, commit_refs):
    root = os.path.realpath(os.fspath(project_root))
    result = {"status": "unavailable", "observedAt": _view_now(), "branch": None,
              "head": None, "changes": [], "commitObjects": {}, "warnings": []}
    env = os.environ.copy()
    for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
                 "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
                 "GIT_PREFIX", "GIT_SHALLOW_FILE", "GIT_GRAFT_FILE",
                 "GIT_QUARANTINE_PATH", "GIT_IMPLICIT_WORK_TREE"):
        env.pop(name, None)
    env.update(LC_ALL="C", GIT_OPTIONAL_LOCKS="0")
    command = ["git", "-c", "safe.directory=*", "-C", root]

    def query(args, input_data=None, allowed=()):
        completed = subprocess.run(command + args, env=env, input=input_data,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
        if completed.returncode and completed.returncode not in allowed:
            message = completed.stderr.decode("utf-8", errors="replace").strip()
            raise ValueError("Git {} failed: {}".format(args[0], message or completed.returncode))
        return completed

    try:
        probe = query(["rev-parse", "--is-inside-work-tree"], allowed=(128,))
        if probe.returncode:
            directory = root
            marker = False
            while True:
                marker = marker or os.path.lexists(os.path.join(directory, ".git"))
                parent = os.path.dirname(directory)
                if parent == directory:
                    break
                directory = parent
            if not marker and probe.stderr.startswith(b"fatal: not a git repository"):
                result["status"] = "not_repository"
                return result
            raise ValueError("Git repository probe failed: " + probe.stderr.decode("utf-8", errors="replace").strip())
        if probe.stdout.strip() != b"true":
            result["status"] = "not_repository"
            return result
        status_args = ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."]
        for path in excluded_paths:
            if _view_inside(root, os.fspath(path)):
                relative = os.path.relpath(os.fspath(path), root).replace(os.sep, "/")
                status_args.append(":(exclude,literal)" + relative)

        def head():
            current = query(["rev-parse", "--verify", "--quiet", "HEAD"], allowed=(1,))
            if current.returncode == 1 and not current.stderr:
                return None
            if current.returncode:
                raise ValueError("Git HEAD query failed: " + current.stderr.decode("utf-8", errors="replace"))
            return current.stdout.decode("ascii").strip()

        for attempt in range(2):
            before_head = head()
            before_status = query(status_args).stdout
            branch_result = query(["symbolic-ref", "--quiet", "--short", "HEAD"], allowed=(1,))
            if branch_result.returncode and branch_result.stderr:
                raise ValueError("Git branch query failed: " + branch_result.stderr.decode("utf-8", errors="replace"))
            branch = branch_result.stdout.decode("utf-8").rstrip("\n") if not branch_result.returncode else None
            after_head = head()
            after_status = query(status_args).stdout
            if before_head == after_head and before_status == after_status:
                result.update(status="available", head=before_head, branch=branch,
                              changes=_view_git_changes(before_status))
                break
            if attempt == 1:
                raise ValueError("Git changed during observation; snapshot is unavailable")
        if result["head"] is None:
            result["warnings"].append(_view_warning("git_unborn", "Git HEAD is not recorded yet"))
        if result["branch"] is None:
            result["warnings"].append(_view_warning("git_detached", "Git HEAD is detached"))
        valid_refs = []
        for ref in sorted(set(commit_refs)):
            result["commitObjects"][ref] = {"status": "unavailable", "objectId": None}
            if re.fullmatch(r"[0-9A-Fa-f]{4,64}", ref):
                valid_refs.append(ref)
        if valid_refs:
            try:
                batch = query(["cat-file", "--batch-check=%(objectname) %(objecttype)"],
                              ("\n".join(valid_refs) + "\n").encode("ascii"))
                lines = batch.stdout.decode("ascii").splitlines()
                if len(lines) != len(valid_refs):
                    raise ValueError("Incomplete Git commit object batch")
                for ref, line in zip(valid_refs, lines):
                    fields = line.split()
                    if len(fields) == 2 and fields[1] == "commit" and re.fullmatch(r"[0-9a-f]{40,64}", fields[0]):
                        result["commitObjects"][ref] = {"status": "verified", "objectId": fields[0]}
            except (OSError, ValueError, subprocess.TimeoutExpired) as error:
                result["warnings"].append(_view_warning("git_commit_query_failed", "Git commit query unavailable: " + str(error)))
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        result.update(status="unavailable", branch=None, head=None, changes=[])
        message = "Git observation timeout (5 seconds)" if isinstance(error, subprocess.TimeoutExpired) else str(error)
        result["warnings"].append(_view_warning("git_unavailable", message))
    result["observedAt"] = _view_now()
    return result


def _view_timestamp(value):
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
        if parsed.tzinfo is None or parsed.utcoffset() is None:
            return None
        return parsed.timestamp()
    except (ValueError, OverflowError, OSError):
        return None


def build_view_model(snapshot, git_snapshot, generated_at):
    warnings = list(snapshot.get("warnings", [])) + list(git_snapshot.get("warnings", []))
    entries = []
    for original in snapshot["entries"]:
        item = dict(original)
        record = item["record"]
        item["timestampUtc"] = _view_timestamp(record.get("createdAt"))
        invalid = [name for name in ("createdAt", "type", "title", "summary", "commit", "branch")
                   if not isinstance(record.get(name), str)]
        if not isinstance(record.get("files"), list) or not all(isinstance(path, str) for path in record.get("files", [])):
            invalid.append("files")
        if not isinstance(record.get("dirty"), bool):
            invalid.append("dirty")
        if invalid:
            warnings.append(_view_warning("legacy_fields", "Line {} has missing or invalid fields: {}. Original record preserved.".format(
                item["sourceLine"], ", ".join(invalid)), item["sourcePath"]))
        if item["timestampUtc"] is None:
            warnings.append(_view_warning("timestamp_unknown", "Line {} has no timezone-aware timestamp".format(item["sourceLine"]), item["sourcePath"]))
        ref = _view_commit_ref(record)
        item["commitObjectRef"] = ref
        if ref is None or ref in ("pending", "uncommitted"):
            item["commitObjectStatus"] = "not_recorded"
        else:
            item["commitObjectStatus"] = git_snapshot["commitObjects"].get(ref, {}).get("status", "unavailable")
            if item["commitObjectStatus"] != "verified":
                warnings.append(_view_warning("commit_unavailable", "Line {}: cannot verify recorded commit reference {} in this checkout".format(
                    item["sourceLine"], ref), item["sourcePath"]))
        entries.append(item)
    entries.sort(key=lambda entry: (entry["timestampUtc"] is None,
                                   -entry["timestampUtc"] if entry["timestampUtc"] is not None else 0,
                                   entry["sourcePath"], entry["sourceLine"]))
    return {"viewModelVersion": 1, "generatedAt": generated_at, "project": snapshot["project"],
            "documents": snapshot["documents"], "entries": entries, "git": git_snapshot,
            "warnings": warnings, "collectionStartedAt": snapshot["collectionStartedAt"],
            "collectionFinishedAt": snapshot["collectionFinishedAt"]}


# The renderer has no external resources or runtime file reads.
import base64
import hashlib
import json

VIEW_CSS = r""".warning-box summary {
  cursor: pointer;
  font-weight: 650;
}
.warning-box .pagination {
  max-width: 32rem;
}
:root {
  color-scheme:light;
  --ink:#182d34;
  --muted:#52666d;
  --line:#ced9dc;
  --paper:#fff;
  --wash:#f3f6f6;
  --accent:#086e68;
  --soft:#e3f3ef;
  font:16px/1.55 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
}
* {
  box-sizing:border-box;
}
body {
  margin:0;
  color:var(--ink);
  background:var(--paper);
}
button,input,select {
  font:inherit;
  color:inherit;
}
button,a,input,select {
  touch-action:manipulation;
}
button {
  cursor:pointer;
  background:white;
  border:1px solid var(--line);
  border-radius:5px;
  padding:.45rem .75rem;
}
button:hover {
  background:var(--wash);
}
button:disabled {
  cursor:default;
  opacity:.48;
}
a {
  color:var(--accent);
  text-underline-offset:.18em;
}
button:focus-visible,a:focus-visible,input:focus-visible,select:focus-visible {
  outline:3px solid #10857c;
  outline-offset:3px;
}
h1,h2,h3,h4 {
  line-height:1.25;
  margin:0 0 .8rem;
}
h1 {
  font-size:1.6rem;
  letter-spacing:-.035em;
}
h2 {
  font-size:1.35rem;
}
h3 {
  font-size:1.08rem;
}
p {
  margin:.5rem 0 1rem;
}
pre,code {
  font: .88rem/1.6 ui-monospace,SFMono-Regular,Menlo,monospace;
}
pre {
  margin:.8rem 0;
  background:var(--wash);
  padding:1rem;
  border:1px solid var(--line);
  border-radius:5px;
  white-space:pre-wrap;
  overflow-wrap:anywhere;
}
code {
  background:var(--wash);
  padding:.1rem .2rem;
}
pre code {
  padding:0;
}
header {
  padding:1.4rem 2rem 1.1rem;
  border-bottom:1px solid var(--line);
}
header .eyebrow {
  font-size:.75rem;
  font-weight:700;
  letter-spacing:.12em;
  color:var(--accent);
  margin-bottom:.25rem;
}
header p {
  margin:.25rem 0;
  font-size:.88rem;
  color:var(--muted);
}
.layout {
  display:grid;
  grid-template-columns:11rem minmax(0,1fr);
  min-height:calc(100vh - 170px);
}
nav {
  border-right:1px solid var(--line);
  padding:1.5rem 1rem;
}
nav button {
  display:block;
  width:100%;
  text-align:left;
  border:0;
  margin-bottom:.4rem;
  color:var(--muted);
  padding:.65rem .8rem;
}
nav button[aria-current=page] {
  background:var(--soft);
  color:var(--accent);
  font-weight:700;
}
main {
  min-width:0;
  padding:1.7rem 2rem;
  max-width:1400px;
  width:100%;
}
[hidden] {
  display:none!important;
}
.muted,.source-note {
  color:var(--muted);
  font-size:.85rem;
}
.source-note {
  margin-top:.25rem;
}
.overview-grid {
  display:grid;
  grid-template-columns:1fr 1fr;
  gap:2rem;
  margin-bottom:1.8rem;
}
.overview-section {
  border-top:3px solid var(--accent);
  padding-top:1rem;
  min-width:0;
}
.section-heading {
  display:flex;
  gap:1rem;
  justify-content:space-between;
  align-items:baseline;
  margin-bottom:.25rem;
}
.section-heading button {
  font-size:.8rem;
  white-space:nowrap;
}
.git-snapshot {
  border-top:1px solid var(--line);
  padding:1.2rem 0;
  margin-bottom:1.5rem;
}
.git-snapshot summary {
  cursor:pointer;
  color:var(--accent);
}
.git-snapshot ul {
  margin:.5rem 0;
  padding-left:1.2rem;
}
.warning-box {
  background:#fff7e8;
  border-left:3px solid #a56a08;
  padding:.8rem 1rem;
  margin-bottom:1.5rem;
}
.warning-box h2 {
  font-size:1rem;
}
.warning-box ul {
  padding-left:1.2rem;
  margin:.4rem 0;
}
.filters {
  display:grid;
  grid-template-columns:minmax(12rem,2fr) minmax(8rem,1fr) minmax(10rem,1fr) minmax(10rem,1fr);
  gap:.75rem;
  margin-bottom:.8rem;
}
.field {
  display:flex;
  flex-direction:column;
  gap:.25rem;
  min-width:0;
}
.field label {
  font-size:.8rem;
  font-weight:650;
}
.field input,.field select {
  width:100%;
  border:1px solid var(--line);
  border-radius:5px;
  background:white;
  padding:.5rem .6rem;
  min-height:2.5rem;
}
.file-field {
  grid-column:1/4;
}
.reset-field {
  align-self:end;
}
.filter-meta {
  display:flex;
  flex-wrap:wrap;
  justify-content:space-between;
  gap:.5rem;
  color:var(--muted);
  font-size:.85rem;
  margin-bottom:1rem;
}
.timeline-grid {
  display:grid;
  grid-template-columns:minmax(15rem,.95fr) minmax(18rem,1.2fr);
  gap:1.5rem;
  align-items:start;
}
.entry-list {
  display:flex;
  flex-direction:column;
  gap:0;
  border-top:1px solid var(--line);
}
.entry-row {
  display:block;
  width:100%;
  text-align:left;
  border:0;
  border-bottom:1px solid var(--line);
  border-radius:0;
  padding:.85rem .75rem;
  overflow-wrap:anywhere;
}
.entry-row[aria-pressed=true] {
  background:var(--soft);
  box-shadow:inset 3px 0 var(--accent);
}
.entry-title {
  display:block;
  font-weight:650;
}
.entry-summary {
  display:block;
  font-size:.85rem;
  color:var(--muted);
  margin-top:.2rem;
  white-space:pre-wrap;
}
.entry-meta {
  display:block;
  font-size:.75rem;
  color:var(--muted);
  margin-top:.4rem;
}
.entry-detail {
  min-width:0;
  background:var(--wash);
  border:1px solid var(--line);
  border-radius:5px;
  padding:1.15rem;
  overflow-wrap:anywhere;
}
.entry-detail h3 {
  font-size:1.15rem;
}
.entry-detail p {
  white-space:pre-wrap;
}
.entry-detail dl {
  display:grid;
  grid-template-columns:6rem minmax(0,1fr);
  gap:.4rem .7rem;
  font-size:.85rem;
}
.entry-detail dt {
  color:var(--muted);
}
.entry-detail dd {
  margin:0;
  white-space:pre-wrap;
  overflow-wrap:anywhere;
}
.file-list {
  list-style:none;
  padding:0;
}
.file-list li {
  margin:.3rem 0;
}
.file-button {
  font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
  font-size:.8rem;
  text-align:left;
  white-space:pre-wrap;
  overflow-wrap:anywhere;
  max-width:100%;
}
.pagination {
  display:flex;
  align-items:center;
  justify-content:space-between;
  gap:.6rem;
  margin-top:1rem;
  font-size:.85rem;
}
.recent-list {
  border-top:1px solid var(--line);
}
.document-toolbar {
  max-width:32rem;
  margin-bottom:1.2rem;
}
.document-body {
  max-width:80ch;
  overflow-wrap:anywhere;
}
.document-body p {
  white-space:pre-wrap;
}
.document-body h1,.document-body h2,.document-body h3,.document-body h4,.document-body h5,.document-body h6 {
  scroll-margin-top:1rem;
  margin-top:1.5rem;
}
.document-body ul,.document-body ol {
  padding-left:1.6rem;
}
.document-body blockquote {
  border-left:3px solid var(--line);
  margin:1rem 0;
  padding:.1rem 1rem;
  color:var(--muted);
}
.document-body li {
  margin:.25rem 0;
  white-space:pre-wrap;
}
.document-body .raw-block {
  white-space:pre-wrap;
}
.document-body .image-alt {
  color:var(--muted);
  font-style:italic;
}
.empty-state {
  padding:1rem 0;
  color:var(--muted);
}
footer {
  padding:1rem 2rem;
  border-top:1px solid var(--line);
  font-size:.8rem;
  color:var(--muted);
}
.skip-link {
  position:absolute;
  left:1rem;
  top:-5rem;
  background:white;
  padding:.6rem;
  z-index:5;
}
.skip-link:focus {
  top:1rem;
}
@media(min-width:1000px) {
  nav {
    position:sticky;
    top:0;
    align-self:start;
  }
  .entry-detail {
    position:sticky;
    top:1rem;
    max-height:calc(100vh - 2rem);
    overflow:auto;
  }
}
@media(max-width:900px) {
  header {
    padding:1.2rem;
  }
  .layout {
    grid-template-columns:8.5rem minmax(0,1fr);
  }
  nav {
    padding:1rem .5rem;
  }
  main {
    padding:1.25rem;
  }
  .overview-grid {
    grid-template-columns:1fr;
    gap:1.5rem;
  }
  .timeline-grid {
    grid-template-columns:1fr;
  }
  .filters {
    grid-template-columns:1fr 1fr;
  }
  .file-field {
    grid-column:1/-1;
  }
  .reset-field {
    grid-column:1/-1;
  }
  .entry-detail {
    position:static;
  }
}
@media(max-width:540px) {
  :root {
    font-size:15px;
  }
  header {
    padding:1rem;
  }
  .layout {
    display:block;
  }
  nav {
    display:flex;
    gap:.3rem;
    padding:.6rem 1rem;
    border-right:0;
    border-bottom:1px solid var(--line);
  }
  nav button {
    margin:0;
    width:auto;
    text-align:center;
    padding:.5rem .7rem;
  }
  main {
    padding:1.1rem 1rem;
  }
  .filters {
    grid-template-columns:1fr 1fr;
    gap:.6rem;
  }
  .search-field {
    grid-column:1/-1;
  }
  .field label {
    font-size:.75rem;
  }
  .section-heading {
    flex-wrap:wrap;
    gap:.3rem;
  }
  .entry-detail dl {
    grid-template-columns:1fr;
    gap:.1rem;
  }
  .entry-detail dd {
    margin-bottom:.4rem;
  }
  footer {
    padding:1rem;
  }
  .pagination {
    flex-wrap:wrap;
  }
}
@media(prefers-reduced-motion:reduce) {
  * {
    scroll-behavior:auto!important;
  }
}
"""

VIEW_JS = r"""(function () {
  "use strict";
  const model = JSON.parse(document.getElementById("ctx-view-data").textContent);
  const $ = function (id) { return document.getElementById(id); };
  const text = function (value, fallback) { return typeof value === "string" ? value : (fallback === undefined ? "미기록" : fallback); };
  const node = function (tag, content, className) {
    const element = document.createElement(tag);
    if (content !== undefined) element.textContent = content;
    if (className) element.className = className;
    return element;
  };
  const clear = function (element) { while (element.firstChild) element.removeChild(element.firstChild); };
  const normalized = function (value) { return text(value, "").normalize("NFC").toLocaleLowerCase(); };
  const recordOf = function (entry) { return entry.record && typeof entry.record === "object" && !Array.isArray(entry.record) ? entry.record : {}; };
  const filesOf = function (entry) { const files = recordOf(entry).files; return Array.isArray(files) ? files.filter(function (f) { return typeof f === "string"; }) : []; };
  const entries = (Array.isArray(model.entries) ? model.entries : []).slice().sort(function (a, b) {
    const ta = typeof a.timestampUtc === "number" && Number.isFinite(a.timestampUtc) ? a.timestampUtc : null;
    const tb = typeof b.timestampUtc === "number" && Number.isFinite(b.timestampUtc) ? b.timestampUtc : null;
    if (ta !== tb) return ta === null ? 1 : (tb === null ? -1 : tb - ta);
    const pa = text(a.sourcePath, ""), pb = text(b.sourcePath, "");
    return (pa < pb ? -1 : (pa > pb ? 1 : 0)) || (a.sourceLine - b.sourceLine);
  });
  const documents = Array.isArray(model.documents) ? model.documents : [];
  const byKey = new Map(entries.map(function (entry) { return [entry.key, entry]; }));
  const docsByKey = new Map(documents.map(function (doc) { return [doc.key, doc]; }));
  const typeValues = Array.from(new Set(entries.map(function (entry) { return text(recordOf(entry).type, ""); }).filter(Boolean))).sort();
  const fileValues = Array.from(new Set([].concat.apply([], entries.map(filesOf)))).sort();
  const searchValues = new Map(entries.map(function (entry) {
    const record = recordOf(entry);
    return [entry.key, normalized([text(record.title, ""), text(record.summary, "")].concat(filesOf(entry)).join("\n"))];
  }));
  const labels = {plan:"계획 / MASTER_PLAN", decisions:"결정 / decisions", backlog:"백로그 / backlog", digest:"다이제스트 / timeline digest", completed:"보관된 완료 작업", deprecated:"보관된 결정"};
  const emptyState = function () { return {tab:"overview", q:"", type:"", from:"", to:"", file:"", entry:"", doc:docsByKey.has("plan") ? "plan" : (documents[0] ? documents[0].key : ""), anchor:"", page:1}; };
  const validDate = function (value) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
    const date = new Date(value + "T12:00:00");
    return !Number.isNaN(date.getTime()) && date.getFullYear() === Number(value.slice(0,4)) && date.getMonth() + 1 === Number(value.slice(5,7)) && date.getDate() === Number(value.slice(8,10));
  };
  const localDate = function (seconds) {
    if (typeof seconds !== "number" || !Number.isFinite(seconds)) return null;
    const date = new Date(seconds * 1000);
    if (Number.isNaN(date.getTime())) return null;
    return String(date.getFullYear()).padStart(4,"0") + "-" + String(date.getMonth()+1).padStart(2,"0") + "-" + String(date.getDate()).padStart(2,"0");
  };
  const headings = function (source) {
    const result = [], counts = new Map(); let fence = null;
    text(source, "").split(/\r?\n/).forEach(function (line, index) {
      const marker = line.match(/^\s{0,3}(`{3,}|~{3,})/);
      if (marker) {
        if (!fence) fence = {char:marker[1][0], length:marker[1].length};
        else if (marker[1][0] === fence.char && marker[1].length >= fence.length && !line.slice(marker[0].length).trim()) fence = null;
        return;
      }
      if (fence) return;
      const match = line.match(/^\s{0,3}(#{1,6})\s+(.+)$/);
      if (!match) return;
      const body = match[2].trim();
      if (!body) return;
      let end = body.length;
      while (end > 0 && body[end - 1] === "#") end -= 1;
      const closing = end > 0 && end < body.length && /\s/.test(body[end - 1]);
      const title = closing ? body.slice(0, end).trim() : body;
      const base = normalized(title).replace(/[^\p{L}\p{N}_\-\s]/gu, "").trim().replace(/\s+/g,"-") || "section";
      const count = counts.get(base) || 0; counts.set(base, count + 1);
      result.push({line:index, level:match[1].length, title:title, anchor:base + (count ? "-" + count : "")});
    });
    return result;
  };
  const docHeadings = new Map(documents.map(function (doc) { return [doc.key, headings(doc.text)]; }));
  const anchorExists = function (key, anchor) { return !anchor || (docHeadings.get(key) || []).some(function (h) { return h.anchor === anchor; }); };
  const readHash = function () {
    const defaults = emptyState();
    try {
      const raw = location.hash.slice(1);
      decodeURIComponent(raw);
      const params = new URLSearchParams(raw);
      const tabs = ["overview", "timeline", "documents"];
      if (tabs.indexOf(params.get("tab")) >= 0) defaults.tab = params.get("tab");
      if (params.has("q")) defaults.q = params.get("q");
      if (typeValues.indexOf(params.get("type")) >= 0) defaults.type = params.get("type");
      if (fileValues.indexOf(params.get("file")) >= 0) defaults.file = params.get("file");
      if (validDate(params.get("from") || "")) defaults.from = params.get("from");
      if (validDate(params.get("to") || "")) defaults.to = params.get("to");
      if (defaults.from && defaults.to && defaults.from > defaults.to) { defaults.from = ""; defaults.to = ""; }
      if (byKey.has(params.get("entry"))) defaults.entry = params.get("entry");
      if (docsByKey.has(params.get("doc"))) defaults.doc = params.get("doc");
      if (params.has("anchor") && anchorExists(defaults.doc, params.get("anchor"))) defaults.anchor = params.get("anchor");
      if (/^[1-9]\d{0,6}$/.test(params.get("page") || "")) defaults.page = Number(params.get("page"));
      return defaults;
    } catch (_) { return defaults; }
  };
  let state = readHash(), composing = false, filtered = [];
  const writeHash = function () {
    const params = new URLSearchParams();
    ["tab", "q", "type", "from", "to", "file", "entry", "doc", "anchor"].forEach(function (key) { if (state[key]) params.set(key, state[key]); });
    if (state.page > 1) params.set("page", String(state.page));
    const hash = "#" + params.toString();
    if (location.hash !== hash) {
      try { history.replaceState(null, "", hash); } catch (_) { location.hash = hash; }
    }
  };
  const setState = function (changes) { Object.assign(state, changes); render(); writeHash(); };
  const goDocument = function (key, anchor) { setState({tab:"documents", doc:key, anchor:anchor || ""}); };
  const resolvedLink = function (href, sourceDoc) {
    if (/[\u0000-\u0020\u007f]/.test(href)) return null;
    if (/^https?:\/\//i.test(href)) {
      try { const url = new URL(href); return /^(https?:)$/.test(url.protocol) ? {url:url.href} : null; } catch (_) { return null; }
    }
    try {
      const parts = href.split("#");
      if (parts.length > 2) return null;
      const fragment = parts.length === 2 ? decodeURIComponent(parts[1]) : "";
      const path = decodeURIComponent(parts[0]);
      if (/[\u0000-\u001f\u007f]/.test(path + fragment) || /[:?\\]/.test(path) || path[0] === "/") return null;
      let target = sourceDoc;
      if (path) {
        const segments = text(sourceDoc.path, "").split("/").slice(0, -1);
        path.split("/").forEach(function (part) { if (part === "..") { if (!segments.length) throw new Error("Outside document scope"); segments.pop(); } else if (part && part !== ".") segments.push(part); });
        target = documents.find(function (doc) { return doc.path === segments.join("/"); });
      }
      if (!target || target.status !== "present" || !anchorExists(target.key, fragment)) return null;
      return {doc:target.key, anchor:fragment};
    } catch (_) { return null; }
  };
  const inline = function (parent, source, sourceDoc) {
    // Cache failed delimiter searches so unfinished Markdown stays linear in input size.
    let offset = 0, cursor = 0, lineEnd = source.indexOf("\n"), labelEnd = -2, hrefEnd = -2;
    let noLinks = false, noLinkBefore = -1;
    const flush = function (until) { parent.appendChild(document.createTextNode(source.slice(offset, until))); };
    while (cursor < source.length) {
      if (lineEnd >= 0 && cursor > lineEnd) lineEnd = source.indexOf("\n", cursor);
      const boundary = lineEnd < 0 ? source.length : lineEnd;
      if (source[cursor] === "`") {
        const close = source.indexOf("`", cursor + 1);
        if (close > cursor + 1 && close < boundary) {
          flush(cursor); parent.appendChild(node("code", source.slice(cursor + 1, close)));
          cursor = close + 1; offset = cursor; continue;
        }
      }
      const image = source[cursor] === "!" && source[cursor + 1] === "[";
      if (!noLinks && cursor > noLinkBefore && (source[cursor] === "[" || image)) {
        const labelStart = cursor + (image ? 2 : 1);
        if (labelEnd < labelStart) labelEnd = source.indexOf("](", labelStart);
        if (labelEnd < 0) noLinks = true;
        else if (labelEnd >= boundary) noLinkBefore = boundary;
        else {
          if (hrefEnd < labelEnd + 2) hrefEnd = source.indexOf(")", labelEnd + 2);
          if (hrefEnd < 0) noLinks = true;
          else if (hrefEnd >= boundary) noLinkBefore = boundary;
          else {
            flush(cursor);
            const label = source.slice(labelStart, labelEnd), href = source.slice(labelEnd + 2, hrefEnd);
            if (image) parent.appendChild(node("span", "[이미지: " + label + "]", "image-alt"));
            else {
              const target = resolvedLink(href, sourceDoc);
              if (!target) parent.appendChild(document.createTextNode(source.slice(cursor, hrefEnd + 1)));
              else {
                const a = node("a", label);
                if (target.url) { a.href = target.url; a.target = "_blank"; a.rel = "noopener noreferrer"; }
                else { a.href = "#"; a.addEventListener("click", function (event) { event.preventDefault(); goDocument(target.doc, target.anchor); }); }
                parent.appendChild(a);
              }
            }
            cursor = hrefEnd + 1; offset = cursor; continue;
          }
        }
      }
      cursor += 1;
    }
    flush(source.length);
  };
  const markdown = function (target, source, doc, idPrefix, depth) {
    const nesting = depth || 0;
    if (nesting >= 32) {
      target.appendChild(node("pre", text(source, ""), "raw-block"));
      return;
    }
    const lines = text(source, "").split(/\r?\n/), indexed = new Map(headings(source).map(function (h) { return [h.line, h]; }));
    let i = 0;
    const startBlock = function (line) { return /^\s*$|^\s{0,3}(?:#{1,6}\s|`{3,}|~{3,}|>\s?|[-+*]\s|\d+[.)]\s)|^\s*\|/.test(line); };
    while (i < lines.length) {
      const line = lines[i];
      if (!line.trim()) { i += 1; continue; }
      const fence = line.match(/^\s{0,3}(`{3,}|~{3,})/);
      if (fence) {
        const body = []; i += 1;
        while (i < lines.length && !(new RegExp("^\\s{0,3}" + fence[1][0] + "{" + fence[1].length + ",}\\s*$")).test(lines[i])) body.push(lines[i++]);
        if (i < lines.length) i += 1;
        const pre = node("pre"); pre.appendChild(node("code", body.join("\n"))); target.appendChild(pre); continue;
      }
      if (indexed.has(i)) {
        const heading = indexed.get(i), h = node("h" + heading.level);
        h.id = idPrefix + heading.anchor; inline(h, heading.title, doc); target.appendChild(h); i += 1; continue;
      }
      if (/^\s*\|/.test(line)) {
        const body = []; while (i < lines.length && lines[i].trim()) body.push(lines[i++]);
        target.appendChild(node("pre", body.join("\n"), "raw-block")); continue;
      }
      if (/^\s{0,3}>/.test(line)) {
        const body = []; while (i < lines.length && /^\s{0,3}>/.test(lines[i])) body.push(lines[i++].replace(/^\s{0,3}>\s?/, ""));
        const quote = node("blockquote"); markdown(quote, body.join("\n"), doc, idPrefix + "quote-", nesting + 1); target.appendChild(quote); continue;
      }
      const list = line.match(/^\s{0,3}([-+*]|\d+[.)])\s+(.*)$/);
      if (list) {
        const ordered = /^\d/.test(list[1]), container = node(ordered ? "ol" : "ul");
        if (ordered) container.start = parseInt(list[1], 10);
        while (i < lines.length) {
          const item = lines[i].match(/^\s{0,3}([-+*]|\d+[.)])\s+(.*)$/);
          if (!item || /^\d/.test(item[1]) !== ordered) break;
          const li = node("li"), check = item[2].match(/^\[([ xX])\]\s*(.*)$/);
          inline(li, check ? (check[1] === " " ? "☐ " : "☑ ") + check[2] : item[2], doc); container.appendChild(li); i += 1;
        }
        target.appendChild(container); continue;
      }
      const body = [line]; i += 1;
      while (i < lines.length && !startBlock(lines[i])) body.push(lines[i++]);
      const paragraph = node("p"); inline(paragraph, body.join("\n"), doc); target.appendChild(paragraph);
    }
  };
  const sectionText = function (doc, names) {
    if (!doc || doc.status !== "present") return null;
    const hs = headings(doc.text), found = hs.find(function (h) { return h.level === 2 && names.indexOf(h.title.toLocaleLowerCase()) >= 0; });
    if (!found) return null;
    const next = hs.find(function (h) { return h.line > found.line && h.level <= found.level; });
    return text(doc.text, "").split(/\r?\n/).slice(found.line + 1, next ? next.line : undefined).join("\n");
  };
  const showSection = function (id, names) {
    const target = $(id), plan = docsByKey.get("plan"), content = sectionText(plan, names); clear(target);
    if (content === null) target.appendChild(node("p", "해당 섹션 없음 · 전체 계획 문서에서 확인하세요.", "empty-state"));
    else if (!content.trim()) target.appendChild(node("p", "해당 섹션에 기재된 내용 없음", "empty-state"));
    else markdown(target, content, plan, id + "-");
  };
  const entryLabel = function (entry) { const r = recordOf(entry); return text(r.title, "제목 미기록"); };
  const row = function (entry, recent) {
    const r = recordOf(entry), button = node("button", undefined, "entry-row"); button.type = "button";
    button.setAttribute("aria-pressed", String(state.entry === entry.key));
    button.appendChild(node("span", entryLabel(entry), "entry-title"));
    const summary = text(r.summary, "요약 미기록");
    button.appendChild(node("span", summary.length > 180 ? summary.slice(0, 180) + "…" : summary, "entry-summary"));
    button.appendChild(node("span", text(r.createdAt) + " · " + text(r.type) + " · 기록 당시 로그", "entry-meta"));
    button.addEventListener("click", function () { setState({tab:"timeline", entry:entry.key, page:recent ? 1 : state.page}); });
    return button;
  };
  const renderOverview = function () {
    showSection("current-state", ["current state", "현재 상태"]);
    showSection("next-actions", ["next actions", "다음 행동"]);
    const recent = $("recent-entries"); clear(recent);
    entries.slice(0, 5).forEach(function (entry) { recent.appendChild(row(entry, true)); });
    if (!entries.length) recent.appendChild(node("p", "아직 작업 기록이 없습니다.", "empty-state"));
  };
  const renderGit = function () {
    const target = $("git-content"), git = model.git || {}; clear(target);
    if (git.status !== "available") {
      target.appendChild(node("p", git.status === "not_repository" ? "Git 관리 밖 · 생성 시점 Git 정보 없음" : "Git 조회 불가 · 아래 경고에서 원인을 확인하세요.")); return;
    }
    target.appendChild(node("p", "브랜치: " + text(git.branch, "확인 불가 / detached HEAD") + " · HEAD: " + text(git.head, "아직 커밋 없음")));
    const changes = Array.isArray(git.changes) ? git.changes : [];
    const details = node("details"), summary = node("summary", "생성 시점 변경 파일 " + changes.length + "개"); details.appendChild(summary);
    const list = node("ul");
    changes.forEach(function (change) { list.appendChild(node("li", text(change.status, "") + " " + text(change.path) + (typeof change.previousPath === "string" ? " ← " + change.previousPath : ""))); });
    details.appendChild(list); target.appendChild(details);
    target.appendChild(node("p", "로그의 dirty 값은 기록 당시 상태입니다. Git 조회는 작업 완료·현재 브랜치 포함·배포를 증명하지 않습니다.", "source-note"));
  };
  const renderWarnings = function () {
    const warnings = Array.isArray(model.warnings) ? model.warnings : [], box = $("warnings"), list = $("warning-list");
    const details = $("warnings-details"), panel = $("warnings-panel");
    let page = 1;
    box.hidden = warnings.length === 0;
    $("warnings-summary").textContent = "확인이 필요한 내용 · 경고 " + warnings.length + "건";
    const showPage = function () {
      clear(list);
      panel.hidden = !details.open;
      if (!details.open) return;
      const pages = Math.max(1, Math.ceil(warnings.length / 50));
      page = Math.max(1, Math.min(page, pages));
      warnings.slice((page - 1) * 50, page * 50).forEach(function (warning) {
        list.appendChild(node("li", text(warning.message, "알 수 없는 경고") + (typeof warning.source === "string" ? " (" + warning.source + ")" : "")));
      });
      $("warning-page-status").textContent = page + " / " + pages + " 페이지 · 최대 50건";
      $("warning-previous-page").disabled = page <= 1;
      $("warning-next-page").disabled = page >= pages;
    };
    details.addEventListener("toggle", showPage);
    $("warning-previous-page").addEventListener("click", function () { page -= 1; showPage(); });
    $("warning-next-page").addEventListener("click", function () { page += 1; showPage(); });
    showPage();
  };
  const renderDetail = function () {
    const target = $("entry-detail"); clear(target);
    const entry = byKey.get(state.entry);
    if (!entry) { target.appendChild(node("h3", "작업 상세")); target.appendChild(node("p", "목록에서 작업을 선택하세요.", "empty-state")); return; }
    const r = recordOf(entry); target.appendChild(node("h3", entryLabel(entry)));
    target.appendChild(node("p", "기록 당시 로그 · 원문 보고이며 현재 검증 결과가 아닙니다.", "source-note"));
    target.appendChild(node("p", text(r.summary, "요약 미기록")));
    const dl = node("dl");
    const add = function (label, value) { dl.appendChild(node("dt", label)); dl.appendChild(node("dd", value)); };
    add("출처", text(entry.sourcePath) + ":" + entry.sourceLine);
    add("기록 시각", text(r.createdAt) + (entry.timestampUtc === null ? " · 시간대/시각 미확인" : ""));
    add("유형", text(r.type)); add("브랜치", text(r.branch));
    add("조회한 커밋 참조", text(entry.commitObjectRef, text(r.commit)));
    if (typeof r.commit === "string") add("기록된 commit", r.commit);
    if (typeof r.fullCommit === "string") add("기록된 fullCommit", r.fullCommit);
    const statusLabel = entry.commitObjectStatus === "verified" ? "기록의 참조 대상을 Git에서 확인" : (entry.commitObjectStatus === "not_recorded" ? "커밋 미확인" : "이 checkout에서 참조 대상을 확인할 수 없음");
    add("참조 조회", statusLabel);
    add("기록 당시 dirty", typeof r.dirty === "boolean" ? String(r.dirty) : "미기록");
    target.appendChild(dl); target.appendChild(node("h4", "기록된 파일"));
    const files = filesOf(entry), list = node("ul", undefined, "file-list");
    files.forEach(function (file) {
      const li = node("li"), button = node("button", file, "file-button"); button.type = "button";
      button.addEventListener("click", function () { setState({file:file, page:1, tab:"timeline"}); }); li.appendChild(button); list.appendChild(li);
    });
    if (!files.length) target.appendChild(node("p", "파일 미기록", "muted")); else target.appendChild(list);
    const raw = node("details"); raw.appendChild(node("summary", "원문 JSON 보기")); raw.appendChild(node("pre", typeof entry.recordText === "string" ? entry.recordText : JSON.stringify(entry.record, null, 2))); target.appendChild(raw);
  };
  const renderTimeline = function () {
    $("search").value = state.q; $("type-filter").value = state.type; $("date-from").value = state.from;
    $("date-to").value = state.to; $("file-filter").value = state.file;
    const query = normalized(state.q), dateActive = !!(state.from || state.to);
    filtered = entries.filter(function (entry) {
      if (query && searchValues.get(entry.key).indexOf(query) < 0) return false;
      if (state.type && recordOf(entry).type !== state.type) return false;
      if (state.file && filesOf(entry).indexOf(state.file) < 0) return false;
      if (dateActive) {
        const day = localDate(entry.timestampUtc);
        if (!day || (state.from && day < state.from) || (state.to && day > state.to)) return false;
      }
      return true;
    });
    const pages = Math.max(1, Math.ceil(filtered.length / 50)); state.page = Math.min(state.page, pages);
    const visible = filtered.slice((state.page - 1) * 50, state.page * 50), list = $("entry-list"); clear(list);
    visible.forEach(function (entry) { list.appendChild(row(entry, false)); });
    if (!visible.length) list.appendChild(node("p", entries.length ? "조건에 맞는 작업 기록이 없습니다." : "아직 작업 기록이 없습니다.", "empty-state"));
    $("result-count").textContent = "결과 " + filtered.length + "건 / 전체 " + entries.length + "건";
    const unknown = entries.filter(function (entry) { return localDate(entry.timestampUtc) === null; }).length;
    $("unknown-dates").textContent = "시각 미확인 " + unknown + "건" + (dateActive ? " · 날짜 필터에서 제외" : " · 날짜 필터 사용 시 제외");
    $("page-status").textContent = state.page + " / " + pages + " 페이지 · 최대 50건";
    $("previous-page").disabled = state.page <= 1; $("next-page").disabled = state.page >= pages;
    renderDetail();
  };
  const renderDocument = function () {
    $("document-select").value = state.doc;
    const target = $("document-content"), doc = docsByKey.get(state.doc); clear(target);
    if (!doc || doc.status !== "present") { target.appendChild(node("p", "기록 없음 · 이 문서가 아직 없습니다.", "empty-state")); return; }
    target.appendChild(node("p", "문서 기재 · " + text(doc.path), "source-note"));
    markdown(target, doc.text, doc, "doc-" + doc.key + "-");
    if (state.anchor) {
      const heading = $("doc-" + doc.key + "-" + state.anchor);
      if (heading) heading.scrollIntoView({block:"start"});
    }
  };
  const render = function () {
    ["overview", "timeline", "documents"].forEach(function (tab) {
      $("view-" + tab).hidden = state.tab !== tab;
      const button = $("nav-" + tab); if (state.tab === tab) button.setAttribute("aria-current", "page"); else button.removeAttribute("aria-current");
    });
    if (state.tab === "overview") renderOverview();
    if (state.tab === "timeline") renderTimeline();
    if (state.tab === "documents") renderDocument();
  };
  $("project-name").textContent = text((model.project || {}).name, "Context viewer");
  $("context-path").textContent = "조회 범위: " + text((model.project || {}).contextPath, "") + " · 허용 문서와 활성·보관 작업 기록";
  $("generated-at").textContent = "생성 시각: " + text(model.generatedAt);
  const updateAge = function () {
    const generated = Date.parse(model.generatedAt), elapsed = Math.max(0, Date.now() - generated);
    $("snapshot-age").textContent = Number.isFinite(generated) ? "생성 후 약 " + Math.floor(elapsed / 60000) + "분 경과 · 원본 변경 여부는 감지하지 않습니다." : "생성 시각 확인 불가";
  };
  updateAge(); setInterval(updateAge, 60000);
  const addOptions = function (target, values) { values.forEach(function (value) { const option = node("option", value); option.value = value; target.appendChild(option); }); };
  addOptions($("type-filter"), typeValues); addOptions($("file-filter"), fileValues);
  documents.forEach(function (doc) { const option = node("option", (labels[doc.key] || doc.key) + (doc.status === "present" ? "" : " · 기록 없음")); option.value = doc.key; $("document-select").appendChild(option); });
  ["overview", "timeline", "documents"].forEach(function (tab) { $("nav-" + tab).addEventListener("click", function () { setState({tab:tab}); }); });
  ["open-plan-current", "open-plan-next"].forEach(function (id) { $(id).addEventListener("click", function () { goDocument("plan", ""); }); });
  $("search").addEventListener("compositionstart", function () { composing = true; });
  $("search").addEventListener("compositionend", function () { composing = false; setState({q:$("search").value, page:1}); });
  $("search").addEventListener("input", function (event) { if (!composing && !event.isComposing) setState({q:$("search").value, page:1}); });
  [["type-filter", "type"], ["file-filter", "file"], ["date-from", "from"], ["date-to", "to"]].forEach(function (pair) {
    $(pair[0]).addEventListener("change", function () { const changes = {page:1}; changes[pair[1]] = $(pair[0]).value; setState(changes); });
  });
  $("clear-filters").addEventListener("click", function () { setState({q:"", type:"", from:"", to:"", file:"", entry:"", page:1}); });
  $("previous-page").addEventListener("click", function () { setState({page:Math.max(1, state.page - 1)}); });
  $("next-page").addEventListener("click", function () { setState({page:state.page + 1}); });
  $("document-select").addEventListener("change", function () { setState({doc:$("document-select").value, anchor:""}); });
  window.addEventListener("hashchange", function () { state = readHash(); render(); });
  $("skip-main").addEventListener("click", function (event) { event.preventDefault(); $("main-content").focus(); });
  renderGit(); renderWarnings(); render();
}());
"""

VIEW_HTML = r"""<!-- ctx-kit-viewer:1 -->
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="__CSP__">
<title>ctx · Local Context Viewer</title>
<style>__CSS__</style>
</head>
<body>
<a id="skip-main" class="skip-link" href="#main-content">본문으로 이동</a>
<header>
<div class="eyebrow">CTX / LOCAL CONTEXT</div>
<h1 id="project-name">로컬 컨텍스트</h1>
<p>생성 시점의 스냅샷 · <span id="generated-at"></span></p>
<p id="snapshot-age"></p>
<p id="context-path"></p>
<p>갱신: <code>bash ctx.sh view</code> 또는 <code>bash scripts/ctx.sh view</code>를 다시 실행하세요. 브라우저 새로고침만으로 원본이 갱신되지는 않습니다.</p>
</header>
<div class="layout">
<nav aria-label="컨텍스트 탐색">
<button id="nav-overview" type="button" aria-current="page">개요</button>
<button id="nav-timeline" type="button">작업 기록</button>
<button id="nav-documents" type="button">문서</button>
</nav>
<main id="main-content" tabindex="-1">
<aside id="warnings" class="warning-box" aria-label="수집 경고" hidden>
<details id="warnings-details"><summary id="warnings-summary">확인이 필요한 내용</summary>
<div id="warnings-panel" hidden><ul id="warning-list"></ul>
<div class="pagination"><button id="warning-previous-page" type="button">이전 경고</button><span id="warning-page-status"></span><button id="warning-next-page" type="button">다음 경고</button></div></div>
</details>
</aside>
<section id="view-overview" aria-labelledby="overview-heading">
<h2 id="overview-heading">현재 컨텍스트</h2>
<p class="source-note">문서 기재와 기록 당시 로그, 생성 시점 Git 조회를 출처별로 표시합니다.</p>
<div class="overview-grid">
<section class="overview-section"><div class="section-heading"><h3>현재 상태</h3><button id="open-plan-current" type="button">전체 계획 문서</button></div><p class="source-note">문서 기재 · MASTER_PLAN</p><div id="current-state" class="document-body"></div></section>
<section class="overview-section"><div class="section-heading"><h3>다음 행동</h3><button id="open-plan-next" type="button">전체 계획 문서</button></div><p class="source-note">문서 기재 · 체크 표시는 원문을 따릅니다.</p><div id="next-actions" class="document-body"></div></section>
</div>
<section class="git-snapshot" aria-labelledby="git-heading"><h3 id="git-heading">생성 시점 Git 조회</h3><div id="git-content"></div></section>
<section aria-labelledby="recent-heading"><h3 id="recent-heading">최근 작업 5건</h3><div id="recent-entries" class="recent-list"></div></section>
</section>
<section id="view-timeline" aria-labelledby="timeline-heading" hidden>
<h2 id="timeline-heading">작업 기록</h2>
<p class="source-note">활성·보관 기록을 모두 표시합니다. 같은 내용의 기록도 별개로 보존합니다.</p>
<div class="filters">
<div class="field search-field"><label for="search">제목·요약·파일명 검색</label><input id="search" type="search" autocomplete="off" placeholder="검색어 입력"></div>
<div class="field"><label for="type-filter">유형</label><select id="type-filter"><option value="">모든 유형</option></select></div>
<div class="field"><label for="date-from">시작일 · 브라우저 현지 날짜</label><input id="date-from" type="date"></div>
<div class="field"><label for="date-to">종료일 · 브라우저 현지 날짜</label><input id="date-to" type="date"></div>
<div class="field file-field"><label for="file-filter">정확한 파일 경로 · 원문 문자열 기준</label><select id="file-filter"><option value="">모든 파일</option></select></div>
<div class="reset-field"><button id="clear-filters" type="button">필터 해제</button></div>
</div>
<div class="filter-meta"><span id="result-count" role="status" aria-live="polite"></span><span id="unknown-dates"></span></div>
<div class="timeline-grid"><div><div id="entry-list" class="entry-list" aria-label="작업 목록"></div><div class="pagination"><button id="previous-page" type="button">이전</button><span id="page-status"></span><button id="next-page" type="button">다음</button></div></div><section id="entry-detail" class="entry-detail" aria-label="선택한 작업 상세"></section></div>
</section>
<section id="view-documents" aria-labelledby="documents-heading" hidden>
<h2 id="documents-heading">문서</h2>
<p class="source-note">문서 기재 · 내용과 완료 여부를 자동 판정하지 않습니다. 지원하지 않는 문법은 원문으로 표시합니다.</p>
<div class="document-toolbar field"><label for="document-select">열람할 문서</label><select id="document-select"></select></div>
<article id="document-content" class="document-body" aria-label="문서 원문"></article>
</section>
<noscript>이 오프라인 뷰어의 열람·검색에는 JavaScript가 필요합니다. 원본 Markdown과 JSONL은 변경되지 않습니다.</noscript>
</main>
</div>
<footer>로컬 오프라인 HTML · 문서와 로그 원문이 포함됩니다. 공유 전 내용을 검토하세요. 외부 링크는 직접 눌렀을 때만 열립니다.</footer>
<script id="ctx-view-data" type="application/json">__DATA__</script>
<script>__JS__</script>
</body>
</html>
"""

def render_view_html(model):
    """Build one inert-data, offline HTML document from a collected model."""
    payload = json.dumps(model, ensure_ascii=True, allow_nan=False, separators=(",", ":"))
    for character, escaped in (("<", "\\u003c"), (">", "\\u003e"), ("&", "\\u0026"),
                               ("\u2028", "\\u2028"), ("\u2029", "\\u2029")):
        payload = payload.replace(character, escaped)
    def digest(content):
        return base64.b64encode(hashlib.sha256(content.encode("utf-8")).digest()).decode("ascii")
    csp = ("default-src 'none'; connect-src 'none'; img-src 'none'; object-src 'none'; "
           "base-uri 'none'; form-action 'none'; script-src 'sha256-" + digest(VIEW_JS) +
           "'; style-src 'sha256-" + digest(VIEW_CSS) + "'")
    # Substitute trusted constants before inserting the untrusted JSON last.
    return (VIEW_HTML.replace("__CSP__", csp).replace("__CSS__", VIEW_CSS)
            .replace("__JS__", VIEW_JS).replace("__DATA__", payload))


"""Embedded viewer output and browser helpers; Python 3.7 standard library."""

import hashlib
import os
import stat
from pathlib import Path
import webbrowser
import tempfile


VIEW_MARKER = b"<!-- ctx-kit-viewer:1 -->"


def _view_stat_signature(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns)


def _view_existing_output(path):
    try:
        before = os.lstat(path)
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(before.st_mode):
        raise ValueError("Viewer output must be a regular file, not a symlink or other file type: " + path)
    if before.st_nlink != 1:
        raise ValueError("Refusing to replace hardlinked viewer output: " + path)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    descriptor = os.open(path, flags)
    with os.fdopen(descriptor, "rb") as stream:
        opened = os.fstat(stream.fileno())
        if _view_stat_signature(opened) != _view_stat_signature(before):
            raise ValueError("Viewer output changed during inspection; preserving it: " + path)
        if stream.readline(len(VIEW_MARKER) + 3).rstrip(b"\r\n") != VIEW_MARKER:
            raise ValueError("Refusing to overwrite HTML without the ctx-kit viewer marker; choose another --output path: " + path)
        stream.seek(0)
        digest = hashlib.sha256()
        while True:
            chunk = stream.read(65536)
            if not chunk:
                break
            digest.update(chunk)
        if (_view_stat_signature(os.fstat(stream.fileno())) != _view_stat_signature(before)
                or _view_stat_signature(os.lstat(path)) != _view_stat_signature(before)):
            raise ValueError("Viewer output changed during inspection; preserving it: " + path)
    return (_view_stat_signature(before), digest.digest())


def validate_view_output(output_path, project_root, protected_inputs=()):
    """Validate without writing; return an absolute path, retaining safe aliases."""
    root = os.path.realpath(os.path.abspath(os.fspath(project_root)))
    supplied = os.fspath(output_path)
    if not supplied or not supplied.endswith(".html"):
        raise ValueError("Viewer --output must have the .html extension")
    path = os.path.abspath(supplied if os.path.isabs(supplied) else os.path.join(root, supplied))
    actual = os.path.realpath(path)
    try:
        inside = os.path.commonpath([root, actual]) == root
    except ValueError:
        inside = False
    if not inside or actual == root:
        raise ValueError("Viewer --output must remain inside the project: " + path)
    existing = _view_existing_output(path)
    identity = existing[0][:2] if existing is not None else None
    for protected in protected_inputs:
        protected = os.fspath(protected)
        if os.path.realpath(protected) == actual:
            raise ValueError("Viewer output conflicts with a protected input: " + path)
        if identity is not None:
            try:
                item = os.stat(protected)
            except FileNotFoundError:
                continue
            if (item.st_dev, item.st_ino) == identity:
                raise ValueError("Viewer output shares an inode with a protected input: " + path)
    return path


def _view_parent_signature(path, project_root):
    root = os.path.abspath(os.fspath(project_root))
    directory = os.path.dirname(path)
    result = []
    while True:
        try:
            info = os.lstat(directory)
        except FileNotFoundError:
            pass
        else:
            # Creation of the temporary file changes parent times, not its identity.
            followed = os.stat(directory)
            result.append((directory, info.st_dev, info.st_ino, info.st_mode,
                           followed.st_dev, followed.st_ino, followed.st_mode,
                           os.readlink(directory) if stat.S_ISLNK(info.st_mode) else None))
        if directory == root:
            break
        parent = os.path.dirname(directory)
        if parent == directory:
            break
        directory = parent
    return tuple(result)


def write_view_html(output_path, html_text, project_root, protected_inputs):
    """Publish one complete snapshot while preserving an existing safe output."""
    if not isinstance(html_text, str) or not html_text.startswith(VIEW_MARKER.decode("ascii") + "\n"):
        raise ValueError("Viewer HTML is missing its generated-file marker")
    path = validate_view_output(output_path, project_root, protected_inputs)
    actual = os.path.realpath(path)
    original = _view_existing_output(path)
    parents_before = _view_parent_signature(path, project_root)
    directory = os.path.dirname(path)
    descriptor = None
    temporary = None
    try:
        os.makedirs(directory, exist_ok=True)
        parents = _view_parent_signature(path, project_root)
        if any(item not in parents for item in parents_before):
            raise ValueError("Viewer output parent changed during generation; preserving output: " + path)
        validate_view_output(path, project_root, protected_inputs)
        if os.path.realpath(path) != actual or _view_existing_output(path) != original:
            raise ValueError("Viewer output changed during generation; preserving it: " + path)
        descriptor, temporary = tempfile.mkstemp(prefix=".ctx-view-", suffix=".tmp", dir=directory)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            descriptor = None
            stream.write(html_text)
            stream.flush()
            mode = stat.S_IMODE(original[0][2]) if original is not None else 0o600
            os.chmod(temporary, mode)
            os.fsync(stream.fileno())
        validate_view_output(path, project_root, protected_inputs)
        if (os.path.realpath(path) != actual
                or _view_parent_signature(path, project_root) != parents
                or _view_existing_output(path) != original):
            raise ValueError("Viewer output changed during generation; preserving it: " + path)
        os.replace(temporary, path)
        temporary = None
        try:
            if os.name != "nt":
                directory_fd = os.open(directory, os.O_RDONLY)
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)
        except OSError as error:
            raise OSError("Viewer saved at " + path + ", but directory sync failed: " + str(error)) from error
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def open_view(output_path):
    """Open the generated file URI using Python's system browser selection."""
    path = os.path.abspath(os.fspath(output_path))
    try:
        opened = webbrowser.open(Path(path).as_uri(), new=2)
    except (OSError, webbrowser.Error) as error:
        raise OSError("Viewer HTML was saved at " + path + "; browser launch failed: " + str(error)) from error
    if not opened:
        raise OSError("Viewer HTML was saved at " + path + "; browser launch failed; open the file manually")
    return True

# CTX_VIEW_IMPLEMENTATION_END

project_root = os.environ["CTX_VIEW_PROJECT"]
context_dir = os.environ["CTX_STORAGE_DIR"]
config_path = os.environ["CTX_VIEW_CONFIG"]
output_path = os.environ["CTX_VIEW_OUTPUT"] or os.path.join(context_dir, "generated", "view.html")
if not os.path.isabs(output_path):
    output_path = os.path.join(project_root, output_path)
output_path = os.path.abspath(output_path)
validate_view_output(output_path, project_root, [config_path, os.environ["CTX_VIEW_SCRIPT"]])
initial_output = _view_existing_output(output_path)
initial_realpath = os.path.realpath(output_path)
initial_parents = _view_parent_signature(output_path, project_root)
snapshot = collect_snapshot(project_root, context_dir, config_path, output_path)
git_snapshot = collect_git_snapshot(project_root, snapshot["excludedPaths"], snapshot["commitRefs"])
generated_at = _view_now()
model = build_view_model(snapshot, git_snapshot, generated_at)
html_text = render_view_html(model)
validate_view_output(output_path, project_root, snapshot["protectedInputs"])
current_parents = _view_parent_signature(output_path, project_root)
if (os.path.realpath(output_path) != initial_realpath
        or _view_existing_output(output_path) != initial_output
        or any(parent not in current_parents for parent in initial_parents)):
    raise ValueError("Viewer output changed during generation; preserving it: " + output_path)
write_view_html(output_path, html_text, project_root, snapshot["protectedInputs"])
print("Generated context snapshot: {}".format(output_path))
print("Snapshot only: regenerate to refresh. Full logs are included; review before sharing.")
if os.environ["CTX_VIEW_OPEN"] == "1":
    try:
        opened = open_view(output_path)
        if not opened:
            raise OSError("the browser launcher reported failure")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("Error: HTML was generated at {}, but opening the browser failed: {}".format(
            output_path, error), file=sys.stderr)
        sys.exit(1)
PYEOF
}

# ── version ────────────────────────────────────────────
cmd_version() {
  echo "ctx v${VERSION}"
}

# ── main ───────────────────────────────────────────────
case "${1:-help}" in
  init)    cmd_init "${@:2}" ;;
  status)  cmd_status ;;
  sync)    cmd_sync ;;
  export)  cmd_export "${@:2}" ;;
  list)    cmd_list ;;
  enable)  cmd_enable "$2" ;;
  disable) cmd_disable "$2" ;;
  generate) cmd_generate "$2" ;;
  log|record) cmd_log "${@:2}" ;;
  timeline) cmd_timeline "${@:2}" ;;
  view)     cmd_view "${@:2}" ;;
  backfill) cmd_backfill "${@:2}" ;;
  archive)  cmd_archive "${@:2}" ;;
  hook)     cmd_hook "${@:2}" ;;
  _hook_run_pre_commit) _hook_run_pre_commit ;;
  version) cmd_version ;;
  help|--help|-h) cmd_help ;;
  *) echo "Unknown command: $1" >&2; cmd_help; exit 1 ;;
esac
