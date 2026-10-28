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
  CTX_STORAGE_DIR="$(py_path "$CONTEXT_DIR")" ctx_python -c '
import errno
import hashlib
import json
import os
import stat
import sys
import tempfile
import time
from contextlib import contextmanager


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
    cmd_timeline --limit 10 2>/dev/null || true
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
import subprocess
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

def git(args, default="", strip=True):
    try:
        output = subprocess.check_output(["git", "-C", root, *args], text=True, stderr=subprocess.DEVNULL)
        return output.strip() if strip else output
    except Exception:
        return default

branch = git(["branch", "--show-current"], "")
status_args = ["status", "--porcelain", "--", "."]
lock_path = os.path.relpath(os.path.join(os.environ["CTX_STORAGE_DIR"], "work-log", ".ctx.lock"), root)
if not (lock_path == ".." or lock_path.startswith(".." + os.sep)):
    status_args.append(":(exclude,literal)" + lock_path.replace(os.sep, "/"))
status = git(status_args, "", strip=False)
dirty = bool(status)

if not commit:
    commit = "uncommitted" if dirty else git(["rev-parse", "--short", "HEAD"], "uncommitted")

full_commit = git(["rev-parse", commit], commit) if commit != "uncommitted" else "uncommitted"

if not files and commit != "uncommitted":
    changed = git(["show", "--name-only", "--format=", commit], "")
    files = [line for line in changed.splitlines() if line.strip()]
elif not files:
    files = [line[3:] for line in status.splitlines() if len(line) > 3]

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
existing_entries = read_jsonl(log_file)
for entry in existing_entries:
    if entry.get("fullCommit"):
        existing_commits.add(entry["fullCommit"])
    if entry.get("commit"):
        existing_commits.add(entry["commit"])

git_cmd = ["git", "-C", root, "log", "--date=iso-strict"]
if not all_mode:
    git_cmd.extend(["-n", str(limit)])

git_cmd.extend(["--format=__CTX_COMMIT_START__%n%H%n%h%n%ad%n%s%n%b%n__CTX_FILES__", "--name-only"])

try:
    raw_log = subprocess.check_output(git_cmd, text=True, stderr=subprocess.DEVNULL)
except Exception as e:
    print(f"Error reading git log: {e}")
    raise SystemExit(1)

raw_commits = raw_log.split("__CTX_COMMIT_START__\n")
new_entries = []

for block in raw_commits:
    block = block.strip()
    if not block:
        continue

    parts = block.split("__CTX_FILES__\n")
    header_part = parts[0].strip()
    files_part = parts[1].strip() if len(parts) > 1 else ""

    lines = header_part.splitlines()
    if len(lines) < 4:
        continue

    full_commit = lines[0].strip()
    short_commit = lines[1].strip()
    date_str = lines[2].strip()
    subject = lines[3].strip()
    body = "\n".join(lines[4:]).strip() if len(lines) > 4 else ""

    if full_commit in existing_commits or short_commit in existing_commits:
        continue

    files = [f.strip() for f in files_part.splitlines() if f.strip()]

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
    local staged_files
    staged_files=$(git -C "$PROJECT_ROOT" diff --cached --name-only 2>/dev/null || true)
    staged_files=$(echo "$staged_files" | grep -v -E "^\s*$" | grep -v "^${rel_context_dir}/" || true)

    if [ -n "$staged_files" ]; then
      local LOG_DIR="$CONTEXT_DIR/work-log"
      local LOG_FILE="$LOG_DIR/timeline.jsonl"
      mkdir -p "$LOG_DIR"

      CTX_ROOT="$(py_path "$PROJECT_ROOT")" CTX_LOG_FILE="$(py_path "$LOG_FILE")" context_python << 'PYEOF'
import json
import os
import subprocess
from uuid import uuid4
from datetime import datetime, timezone

root = os.environ["CTX_ROOT"]
log_file = os.environ["CTX_LOG_FILE"]

def git(args):
    try:
        return subprocess.check_output(["git", "-C", root, *args], text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return ""

diff_stat = git(["diff", "--cached", "--stat"])
staged_names = [f.strip() for f in git(["diff", "--cached", "--name-only"]).splitlines() if f.strip()]
branch = git(["branch", "--show-current"])

if staged_names:
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
        "dirty": False,
        "files": staged_names,
    }

    append_jsonl(log_file, entry)

    print(f"[ctx] 📝 Auto-recorded work-log before commit: {title}")
PYEOF
    fi
  fi

  if [ -d "$CONTEXT_DIR/.git" ]; then
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    context_git_commit "Auto-sync local context ($timestamp)" \
      "[ctx] 🔒 Auto-committed local context (${rel_context_dir}) to local Git."
  fi

  exit 0
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
  backfill) cmd_backfill "${@:2}" ;;
  archive)  cmd_archive "${@:2}" ;;
  hook)     cmd_hook "${@:2}" ;;
  _hook_run_pre_commit) _hook_run_pre_commit ;;
  version) cmd_version ;;
  help|--help|-h) cmd_help ;;
  *) echo "Unknown command: $1" >&2; cmd_help; exit 1 ;;
esac
