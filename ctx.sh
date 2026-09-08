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

# Fallback shim if python3 command is missing
if ! command -v python3 >/dev/null 2>&1; then
  if command -v python >/dev/null 2>&1; then
    python3() { python "$@"; }
  elif [ -x "/c/Users/ez/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe" ]; then
    python3() (
      export PYTHONUTF8=1
      export PYTHONIOENCODING=utf-8
      for name in CTX_ROOT CTX_LOG_FILE CTX_CONFIG; do
        value="${!name:-}"
        if [ -n "$value" ]; then
          export "$name=$(cygpath -w "$value" 2>/dev/null || echo "$value")"
        fi
      done
      converted=()
      for arg in "$@"; do
        converted+=("${arg//\/c\//C:\/}")
      done
      "/c/Users/ez/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe" "${converted[@]}"
    )
  fi
fi

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
ctx_git() {
  git -c safe.directory=* -C "$CONTEXT_DIR" "$@"
}

require_python() {
  if ! command -v python3 &>/dev/null; then
    echo -e "${RED}Error: python3 is required.${NC}" >&2; exit 1
  fi
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
  source_dir=$(python3 -c "import json, os
with open('$(py_path "$CONFIG")') as f: d=json.load(f)
print(os.path.dirname(d.get('source', 'sample-context/AGENT_RULES.md')) or 'sample-context')")
  CONTEXT_DIR="$PROJECT_ROOT/$source_dir"
}

get_source() {
  require_python
  python3 -c "import json
with open('$(py_path "$CONFIG")') as f: d=json.load(f)
print(d['source'])"
}

get_agents() {
  require_python
  python3 -c "import json
with open('$(py_path "$CONFIG")') as f: d=json.load(f)
for a in d['agent_rules']: print(f\"{a['name']}|{a['path']}|{a['enabled']}\")"
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
  printf "  %-20s %s\n" "archive"        "Archive completed tasks & split old timeline logs"
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
      *) shift ;;
    esac
  done

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
> Single Source of Truth. All agent rule files are symlinks to this file.
> Edit only this file. Run `bash ctx.sh status` to verify links.

## 1. Session Start Protocol (MANDATORY)

Before starting any task, read in this order:

```
1. sample-context/MASTER_PLAN.md   → Current state + next actions
2. sample-context/decisions.md     → Existing technical decisions
3. sample-context/backlog.md       → Pending ideas
```

Then output exactly:

```
[Context Loaded]
Current state: {one-line summary from MASTER_PLAN}
Today's task:  {requested task}
Related ADRs:  {relevant decisions, or "none"}
```

---

## 2. Auto-Detect + Record Protocol

During conversation, stop and ask the user whenever a trigger is detected.

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
Detect: task completed, plan changed, task added/removed/reprioritized

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

After completing work, always output:

```
[Session Summary]
✅ Done:          {completed items}
📝 Files changed: {modified context files}
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
    cat > "$filepath"
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

  get_agents | while IFS="|" read -r name path enabled; do
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
  echo -e "${BOLD}[ctx sync] Syncing symlinks${NC}"
  echo ""

  SOURCE=$(get_source)
  SOURCE_PATH="$PROJECT_ROOT/$SOURCE"

  if [ ! -f "$SOURCE_PATH" ]; then
    echo -e "  ${RED}✗ Source file not found: $SOURCE${NC}"
    echo "    Create sample-context/AGENT_RULES.md first (run ctx init)."
    return 1
  fi

  # Auto-update Last Updated in MASTER_PLAN.md
  MASTER_PLAN="$CONTEXT_DIR/MASTER_PLAN.md"
  if [ -f "$MASTER_PLAN" ]; then
    TODAY=$(date +%Y-%m-%d)
    sed -i.bak "s/^> Last Updated: .*/> Last Updated: $TODAY/" "$MASTER_PLAN" && rm -f "${MASTER_PLAN}.bak"
    echo -e "  ${GREEN}✓${NC} MASTER_PLAN.md Last Updated → $TODAY"
  fi

  # Collect enabled paths first so disabled rows that share a path
  # (e.g. multiple AGENTS.md-spec tools) don't remove an active symlink.
  ENABLED_PATHS=$(get_agents | awk -F'|' '$3=="True" || $3=="true" {print $2}' | sort -u)

  get_agents | while IFS="|" read -r name path enabled; do
    LINK_PATH="$PROJECT_ROOT/$path"
    if [ "$enabled" = "True" ] || [ "$enabled" = "true" ]; then
      ([ -L "$LINK_PATH" ] || [ -f "$LINK_PATH" ]) && rm "$LINK_PATH"
      mkdir -p "$(dirname "$LINK_PATH")"
      RELATIVE=$(python3 -c "import os; print(os.path.relpath('$SOURCE_PATH', os.path.dirname('$LINK_PATH')))")
      ln -s "$RELATIVE" "$LINK_PATH"
      echo -e "  ${GREEN}✓${NC} $name: $path → $SOURCE"
    else
      if echo "$ENABLED_PATHS" | grep -qx "$path"; then
        echo -e "  ${YELLOW}-${NC} $name ($path) disabled — kept (shared with an enabled agent)"
      elif [ -L "$LINK_PATH" ]; then
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
      *) shift ;;
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
  echo -e "${BOLD}[ctx list] Agents${NC}"
  echo ""
  get_agents | while IFS="|" read -r name path enabled; do
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
  CTX_AGENT_NAME="$1" CTX_AGENT_STATE="$2" CTX_CONFIG="$CONFIG" python3 << 'PYEOF'
import json, os

name   = os.environ["CTX_AGENT_NAME"]
state  = os.environ["CTX_AGENT_STATE"].lower() == "true"
config = os.environ["CTX_CONFIG"]

with open(config) as f:
    d = json.load(f)

found = False
for a in d["agent_rules"]:
    if a["name"].lower() == name.lower():
        a["enabled"] = state
        found = True
        label = "enabled" if state else "disabled"
        print(f"  → {a['name']} {label}")

if not found:
    print(f"  ✗ Agent '{name}' not found.")
    print(f"  Available: {[a['name'] for a in d['agent_rules']]}")

with open(config, "w") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
PYEOF
}

# ── generate ──────────────────────────────────────────
cmd_generate() {
  require_config
  resolve_context_dir
  require_python

  local TYPE="$1"
  [ -z "$TYPE" ] && { echo "Usage: bash ctx.sh generate <type>"; echo "Types are defined in ctx.config.json under \"generate\"."; exit 1; }

  # Read generate config
  local result
  result=$(CTX_TYPE="$TYPE" CTX_CONFIG="$CONFIG" python3 << 'PYEOF'
import json, os, sys

type_key = os.environ["CTX_TYPE"]
config   = os.environ["CTX_CONFIG"]

with open(config) as f:
    d = json.load(f)

if "generate" not in d:
    print("ERROR: no 'generate' section in ctx.config.json", file=sys.stderr)
    sys.exit(1)

if type_key not in d["generate"]:
    available = list(d["generate"].keys())
    print(f"ERROR: type '{type_key}' not found. Available: {available}", file=sys.stderr)
    sys.exit(1)

cfg = d["generate"][type_key]
print(json.dumps(cfg))
PYEOF
  )

  [ $? -ne 0 ] && { echo -e "${RED}$result${NC}"; exit 1; }

  local OUTPUT PATTERNS
  OUTPUT=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('output',''))")
  PATTERNS=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); [print(p) for p in d.get('collect',[])]")

  [ -z "$OUTPUT" ] && { echo -e "${RED}Error: 'output' not defined for type '$TYPE'.${NC}"; exit 1; }

  local OUTPUT_PATH="$PROJECT_ROOT/$OUTPUT"
  mkdir -p "$(dirname "$OUTPUT_PATH")"

  echo -e "${BOLD}[ctx generate $TYPE]${NC}"
  echo ""

  # Write header
  cat > "$OUTPUT_PATH" << HEADER
# ${TYPE} Context — generated by ctx
# $(date +%Y-%m-%d)
# Paste this into your LLM with a prompt like:
#   "Generate a ${TYPE} document based on the following source files:"

HEADER

  local found=0
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    # expand glob using Python (supports ** recursive patterns)
    while IFS= read -r filepath; do
      [ -f "$filepath" ] || continue
      local rel
      rel=$(python3 -c "import os; print(os.path.relpath('$filepath', '$PROJECT_ROOT'))")
      echo -e "  ${GREEN}+${NC} $rel"
      printf '\n## [%s]\n\n' "$rel" >> "$OUTPUT_PATH"
      cat "$filepath" >> "$OUTPUT_PATH"
      printf '\n' >> "$OUTPUT_PATH"
      found=$((found + 1))
    done < <(CTX_ROOT="$PROJECT_ROOT" CTX_PAT="$pattern" python3 -c "
import glob, os, sys
root = os.environ['CTX_ROOT']
pat  = os.environ['CTX_PAT']
matches = sorted(glob.glob(os.path.join(root, pat), recursive=True))
for m in matches: print(m)
")
  done <<< "$PATTERNS"

  echo ""
  if [ "$found" -eq 0 ]; then
    echo -e "  ${YELLOW}⚠️  No files matched. Check 'collect' patterns in ctx.config.json.${NC}"
    rm -f "$OUTPUT_PATH"
  else
    echo -e "  ${GREEN}✓${NC} $found file(s) collected → $OUTPUT"
    echo -e "  ${CYAN}Open and paste into your LLM.${NC}"
  fi
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

  CTX_ROOT="$(py_path "$PROJECT_ROOT")" CTX_LOG_FILE="$(py_path "$LOG_FILE")" CTX_SUMMARY="$SUMMARY" CTX_TITLE="$TITLE" CTX_COMMIT="$COMMIT" CTX_FILES="$FILES" CTX_TYPE="$TYPE" CTX_COMMAND="$CTX_COMMAND" python3 << 'PYEOF'
import json
import os
import subprocess
from datetime import datetime, timezone

root = os.environ["CTX_ROOT"]
log_file = os.environ["CTX_LOG_FILE"]
summary = os.environ["CTX_SUMMARY"].strip()
title = os.environ["CTX_TITLE"].strip() or summary.splitlines()[0][:80]
commit = os.environ["CTX_COMMIT"].strip()
files = [f.strip() for f in os.environ["CTX_FILES"].split(",") if f.strip()]
entry_type = os.environ["CTX_TYPE"].strip() or "work"
ctx_command = os.environ["CTX_COMMAND"].strip() or "bash ctx.sh"

def git(args, default=""):
    try:
        return subprocess.check_output(["git", "-C", root, *args], text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return default

branch = git(["branch", "--show-current"], "")
dirty = bool(git(["status", "--short"], ""))

if not commit:
    commit = "uncommitted" if dirty else git(["rev-parse", "--short", "HEAD"], "uncommitted")

full_commit = git(["rev-parse", commit], commit) if commit != "uncommitted" else "uncommitted"

if not files and commit != "uncommitted":
    changed = git(["show", "--name-only", "--format=", commit], "")
    files = [line for line in changed.splitlines() if line.strip()]
elif not files:
    try:
        raw = subprocess.check_output(
            ["git", "-C", root, "status", "--porcelain"],
            text=True, stderr=subprocess.DEVNULL,
        )
    except Exception:
        raw = ""
    files = [line[3:] for line in raw.splitlines() if len(line) > 3]

entry = {
    "id": f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{commit}",
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

with open(log_file, "a", encoding="utf-8") as f:
    f.write(json.dumps(entry, ensure_ascii=False) + "\n")

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

  local LOG_FILE="$CONTEXT_DIR/work-log/timeline.jsonl"
  if [ ! -f "$LOG_FILE" ]; then
    echo "No work-log entries yet. Add one with: bash ctx.sh log --summary \"what changed\""
    return 0
  fi

  CTX_ROOT="$(py_path "$PROJECT_ROOT")" CTX_LOG_FILE="$(py_path "$LOG_FILE")" CTX_LIMIT="$LIMIT" CTX_COMMIT="$COMMIT" CTX_JSON="$JSON_MODE" python3 << 'PYEOF'
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

  if ! git -C "$PROJECT_ROOT" rev-parse HEAD >/dev/null 2>&1; then
    echo -e "${YELLOW}No Git commits found to backfill.${NC}"
    return 0
  fi

  local LOG_DIR="$CONTEXT_DIR/work-log"
  local LOG_FILE="$LOG_DIR/timeline.jsonl"
  mkdir -p "$LOG_DIR"

  CTX_ROOT="$(py_path "$PROJECT_ROOT")" CTX_LOG_FILE="$(py_path "$LOG_FILE")" CTX_LIMIT="$LIMIT" CTX_ALL="$ALL_MODE" CTX_TYPE="$TYPE" python3 << 'PYEOF'
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
existing_entries = []
if os.path.exists(log_file):
    with open(log_file, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    entry = json.loads(line)
                    existing_entries.append(entry)
                    if entry.get("fullCommit"):
                        existing_commits.add(entry["fullCommit"])
                    if entry.get("commit"):
                        existing_commits.add(entry["commit"])
                except Exception:
                    pass

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

with open(log_file, "w", encoding="utf-8") as f:
    for entry in all_combined:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")

readme = os.path.join(os.path.dirname(log_file), "README.md")
if not os.path.exists(readme):
    with open(readme, "w", encoding="utf-8") as f:
        f.write("# Work Log\n\n")
        f.write("Commit/work-unit timeline generated by `ctx log` & `ctx backfill`.\n\n")
        f.write("- Source of truth: `timeline.jsonl`\n")
        f.write("- View: `ctx timeline --limit 20`\n")

print(f"[ctx backfill] ✓ Backfilled {len(new_entries)} commit(s) into timeline.jsonl")
PYEOF
}

# ── archive ────────────────────────────────────────────
cmd_archive() {
  require_config
  resolve_context_dir
  require_python

  local KEEP="30" DO_TASKS="true" DO_LOGS="true"
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep|-k) KEEP="$2"; shift 2 ;;
      --no-tasks) DO_TASKS="false"; shift ;;
      --no-logs)  DO_LOGS="false"; shift ;;
      --help|-h)
        echo "Usage: bash ctx.sh archive [--keep 30] [--no-tasks] [--no-logs]"
        echo ""
        echo "Options:"
        echo "  --keep, -k <N>  Number of recent timeline entries to keep in timeline.jsonl (default: 30)"
        echo "  --no-tasks      Do not archive completed tasks from MASTER_PLAN.md"
        echo "  --no-logs       Do not archive timeline.jsonl logs"
        return 0
        ;;
      *) echo "Unknown option: $1"; return 1 ;;
    esac
  done

  echo -e "${BOLD}[ctx archive] Archiving completed tasks and old logs${NC}"
  echo ""

  local ARCHIVE_DIR="$CONTEXT_DIR/archive"
  mkdir -p "$ARCHIVE_DIR"

  CTX_ROOT="$(py_path "$PROJECT_ROOT")" CTX_DIR="$(py_path "$CONTEXT_DIR")" CTX_KEEP="$KEEP" CTX_TASKS="$DO_TASKS" CTX_LOGS="$DO_LOGS" python3 << 'PYEOF'
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

today_str = datetime.now().strftime("%Y-%m-%d")

# 1. Archive Completed Tasks from MASTER_PLAN.md
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

            with open(master_plan_path, "w", encoding="utf-8") as f:
                f.writelines(new_lines)

            archive_task_path = os.path.join(archive_dir, "completed-tasks.md")
            exists = os.path.exists(archive_task_path)
            with open(archive_task_path, "a", encoding="utf-8") as f:
                if not exists:
                    f.write("# Completed Tasks Archive\n\n> Historical record of completed tasks moved from MASTER_PLAN.md\n\n")
                f.write(f"\n### Archived on {today_str}\n\n")
                for task in completed_tasks:
                    f.write(task + "\n")

            print(f"  ✓ Archived {len(completed_tasks)} completed task(s) → archive/completed-tasks.md")
        else:
            print(f"  ~ No completed tasks to archive in MASTER_PLAN.md")

# 2. Archive timeline logs & split by month
archived_log_count = 0
if do_logs:
    timeline_path = os.path.join(context_dir, "work-log", "timeline.jsonl")
    if os.path.exists(timeline_path):
        entries = []
        with open(timeline_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        entries.append(json.loads(line))
                    except Exception:
                        pass

        if len(entries) > keep_count:
            cutoff = len(entries) - keep_count
            to_archive = entries[:cutoff]
            to_keep = entries[cutoff:]

            monthly_groups = {}
            for item in to_archive:
                created = item.get("createdAt", "")
                month = created[:7] if len(created) >= 7 and created[:4].isdigit() else "legacy"
                monthly_groups.setdefault(month, []).append(item)

            for month, group in monthly_groups.items():
                month_file = os.path.join(archive_dir, f"timeline-{month}.jsonl")
                existing_ids = set()
                if os.path.exists(month_file):
                    with open(month_file, "r", encoding="utf-8") as f:
                        for l in f:
                            l = l.strip()
                            if l:
                                try:
                                    e = json.loads(l)
                                    if e.get("id"):
                                        existing_ids.add(e["id"])
                                except Exception:
                                    pass

                with open(month_file, "a", encoding="utf-8") as f:
                    for e in group:
                        if e.get("id") not in existing_ids:
                            f.write(json.dumps(e, ensure_ascii=False) + "\n")
                            archived_log_count += 1

            with open(timeline_path, "w", encoding="utf-8") as f:
                for e in to_keep:
                    f.write(json.dumps(e, ensure_ascii=False) + "\n")

            print(f"  ✓ Archived {archived_log_count} log entries → archive/timeline-YYYY-MM.jsonl (kept {len(to_keep)} active)")
        else:
            print(f"  ~ Timeline entries ({len(entries)}) <= keep threshold ({keep_count}), no logs to archive")

# 3. Generate Warm Digest: work-log/timeline-digest.md
archive_files = sorted([
    f for f in os.listdir(archive_dir)
    if f.startswith("timeline-") and f.endswith(".jsonl")
])

if archive_files:
    digest_path = os.path.join(context_dir, "work-log", "timeline-digest.md")
    with open(digest_path, "w", encoding="utf-8") as f:
        f.write("# Timeline Digest & Milestones\n\n")
        f.write("> Compressed summary of archived past work units and milestones.\n")
        f.write(f"> Last Generated: {today_str}\n\n")

        for fname in archive_files:
            month_label = fname.replace("timeline-", "").replace(".jsonl", "")
            fpath = os.path.join(archive_dir, fname)
            month_entries = []
            with open(fpath, "r", encoding="utf-8") as mf:
                for line in mf:
                    line = line.strip()
                    if line:
                        try:
                            month_entries.append(json.loads(line))
                        except Exception:
                            pass

            if month_entries:
                f.write(f"## Milestone {month_label} ({len(month_entries)} units)\n\n")
                for e in month_entries:
                    date_prefix = e.get("createdAt", "")[:10]
                    title = e.get("title", "")
                    commit = e.get("commit", "")
                    commit_tag = f" `[{commit}]`" if commit and commit != "uncommitted" and commit != "pending" else ""
                    f.write(f"- **{date_prefix}**: {title}{commit_tag}\n")
                f.write("\n")

    print(f"  ✓ Generated warm milestone digest → work-log/timeline-digest.md")
PYEOF

  # 4. Auto-commit archives to local context Git if initialized
  if [ -d "$CONTEXT_DIR/.git" ]; then
    ctx_git add -A
    if ! ctx_git diff-index --quiet HEAD -- 2>/dev/null; then
      local timestamp
      timestamp=$(date '+%Y-%m-%d %H:%M:%S')
      ctx_git commit -m "chore(context): archive completed tasks and past logs ($timestamp)" --quiet
      echo -e "  ${GREEN}✓${NC} Auto-committed archives to local context Git."
    fi
  fi

  echo ""
  echo -e "${GREEN}🎉 Archiving complete!${NC}"
  echo "  Active context is now compact and optimized for AI sessions."
}

# ── hook ───────────────────────────────────────────────
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

  local rel_context_dir="${CONTEXT_DIR#$PROJECT_ROOT/}"
  echo -e "${BOLD}[ctx hook install] Configuring Git integration for '${rel_context_dir}'${NC}"

  # 1) Check if already ignored (in .gitignore or .git/info/exclude)
  if git -C "$PROJECT_ROOT" check-ignore -q "$rel_context_dir/" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} ${rel_context_dir}/ is already ignored by Git (.gitignore or .git/info/exclude)"
  else
    local gitignore="$PROJECT_ROOT/.gitignore"
    printf "\n# Local private AI context (ctx-kit, never pushed)\n${rel_context_dir}/\n" >> "$gitignore"
    echo -e "  ${GREEN}✓${NC} Added ${rel_context_dir}/ to .gitignore"
  fi

  # 2) Initialize independent Git in context directory
  mkdir -p "$CONTEXT_DIR"
  if [ ! -d "$CONTEXT_DIR/.git" ]; then
    ctx_git init --quiet
    ctx_git add -A
    ctx_git commit -m "chore: initialize local context repository" --quiet 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} Initialized independent Git repository in ${rel_context_dir}/"
  else
    echo -e "  ${YELLOW}~${NC} ${rel_context_dir}/ is already an initialized Git repo"
  fi

  # 3) Ensure git_sync is enabled in ctx.config.json
  CTX_CONFIG="$(py_path "$CONFIG")" python3 << 'PYEOF'
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
with open(cfg_file, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PYEOF
  echo -e "  ${GREEN}✓${NC} Enabled git_sync in ctx.config.json (auto_log: true)"

  # 4) Install pre-commit hook in .git/hooks/pre-commit
  local hooks_dir="$PROJECT_ROOT/.git/hooks"
  local hook_file="$hooks_dir/pre-commit"
  mkdir -p "$hooks_dir"

  local HOOK_BEGIN="# --- BEGIN CTX-KIT GIT-SYNC HOOK ---"
  local HOOK_END="# --- END CTX-KIT GIT-SYNC HOOK ---"

  if [ -f "$hook_file" ] && grep -q "$HOOK_BEGIN" "$hook_file"; then
    echo -e "  ${YELLOW}~${NC} Pre-commit hook already installed in .git/hooks/pre-commit"
  else
    if [ ! -f "$hook_file" ]; then
      echo "#!/bin/sh" > "$hook_file"
    fi
    cat >> "$hook_file" << 'HOOKEOF'

# --- BEGIN CTX-KIT GIT-SYNC HOOK ---
if [ -f "ctx.sh" ]; then
  bash ctx.sh _hook_run_pre_commit
elif [ -f "scripts/ctx.sh" ]; then
  bash scripts/ctx.sh _hook_run_pre_commit
fi
# --- END CTX-KIT GIT-SYNC HOOK ---
HOOKEOF
    chmod +x "$hook_file" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} Installed pre-commit hook in .git/hooks/pre-commit"
  fi

  echo -e "\n${GREEN}🎉 Git sync hook setup complete!${NC}"
  echo "  - Changes in ${rel_context_dir}/ will be auto-committed locally on 'git commit'"
  echo "  - auto_log is ENABLED: commit changes will be summarized into timeline.jsonl before each commit"
  echo "  - (To disable auto-log, set \"auto_log\": false under \"git_sync\" in ctx.config.json)"
}

_hook_uninstall() {
  require_config
  local hook_file="$PROJECT_ROOT/.git/hooks/pre-commit"
  local HOOK_BEGIN="# --- BEGIN CTX-KIT GIT-SYNC HOOK ---"
  local HOOK_END="# --- END CTX-KIT GIT-SYNC HOOK ---"

  if [ -f "$hook_file" ] && grep -q "$HOOK_BEGIN" "$hook_file"; then
    python3 -c "
with open('$hook_file', 'r', encoding='utf-8') as f:
    content = f.read()
import re
pattern = re.compile(r'\n?# --- BEGIN CTX-KIT GIT-SYNC HOOK ---.*?# --- END CTX-KIT GIT-SYNC HOOK ---\n?', re.DOTALL)
new_content = pattern.sub('', content).strip()
with open('$hook_file', 'w', encoding='utf-8') as f:
    f.write(new_content + ('\n' if new_content else ''))
"
    echo -e "  ${GREEN}✓${NC} Removed ctx-kit hook from .git/hooks/pre-commit"
  else
    echo -e "  ${YELLOW}~${NC} ctx-kit hook is not installed in .git/hooks/pre-commit"
  fi

  CTX_CONFIG="$(py_path "$CONFIG")" python3 << 'PYEOF'
import json
import os
cfg_file = os.environ["CTX_CONFIG"]
with open(cfg_file, encoding="utf-8") as f:
    data = json.load(f)
if "git_sync" in data and isinstance(data["git_sync"], dict):
    data["git_sync"]["enabled"] = False
with open(cfg_file, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
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
  cfg_status=$(python3 -c "
import json
with open('$(py_path "$CONFIG")') as f: d=json.load(f)
gs = d.get('git_sync', {})
print(f\"{gs.get('enabled', False)}|{gs.get('auto_log', False)}\")")
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

  if git -C "$PROJECT_ROOT" check-ignore -q "$rel_context_dir/" 2>/dev/null; then
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
  cfg_status=$(python3 -c "
import json
with open('$(py_path "$CONFIG")') as f: d=json.load(f)
gs = d.get('git_sync', {})
print(f\"{gs.get('enabled', False)}|{gs.get('auto_log', False)}\")")
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

      CTX_ROOT="$(py_path "$PROJECT_ROOT")" CTX_LOG_FILE="$(py_path "$LOG_FILE")" python3 << 'PYEOF'
import json
import os
import subprocess
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
        "id": f"{now.strftime('%Y%m%dT%H%M%SZ')}-precommit",
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

    with open(log_file, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")

    print(f"[ctx] 📝 Auto-recorded work-log before commit: {title}")
PYEOF
    fi
  fi

  if [ -d "$CONTEXT_DIR/.git" ]; then
    ctx_git add -A
    if ! ctx_git diff-index --quiet HEAD -- 2>/dev/null; then
      local timestamp
      timestamp=$(date '+%Y-%m-%d %H:%M:%S')
      ctx_git commit -m "Auto-sync local context ($timestamp)" --quiet
      echo -e "[ctx] 🔒 Auto-committed local context (${rel_context_dir}) to local Git."
    fi
  fi

  exit 0
}

# ── version ────────────────────────────────────────────
cmd_version() {
  echo "ctx v${VERSION}"
}

# ── main ───────────────────────────────────────────────
case "${1:-help}" in
  init)    cmd_init "$@" ;;
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
  help|--help|-h|*) cmd_help ;;
esac
