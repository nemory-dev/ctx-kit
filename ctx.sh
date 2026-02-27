#!/bin/bash

# ctx — Context Management CLI for AI-Driven Projects
# https://github.com/nemory-dev/ctx-kit
#
# Usage: bash ctx.sh [command]
# See README.md for details.

set -e

VERSION="1.0.0"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Support both project root and scripts/ subdirectory
if [ "$(basename "$SCRIPT_DIR")" = "scripts" ]; then
  PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
else
  PROJECT_ROOT="$SCRIPT_DIR"
fi

CONFIG="$PROJECT_ROOT/ctx.config.json"
CONTEXT_DIR="$PROJECT_ROOT/sample-context"

# Locate templates directory
TEMPLATES_DIR="$SCRIPT_DIR/templates"
if [ ! -d "$TEMPLATES_DIR" ]; then
  TEMPLATES_DIR="$(dirname "$SCRIPT_DIR")/templates"
fi

# ── Colors ─────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Utils ──────────────────────────────────────────────
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

get_source() {
  require_python
  python3 -c "import json
with open('$CONFIG') as f: d=json.load(f)
print(d['source'])"
}

get_agents() {
  require_python
  python3 -c "import json
with open('$CONFIG') as f: d=json.load(f)
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
  printf "  %-20s %s\n" "version"        "Show version"
  printf "  %-20s %s\n" "help"           "Show this help"
  echo ""
  echo -e "${BOLD}Config:${NC}"
  echo "  ctx.config.json              — Agent rule file paths (edit here to add agents)"
  echo ""
  echo -e "${BOLD}Context files:${NC}"
  echo "  sample-context/AGENT_RULES.md  — Agent behavior rules (single source of truth)"
  echo "  sample-context/MASTER_PLAN.md  — Current status + next actions"
  echo "  sample-context/decisions.md    — Architecture decision records (ADR)"
  echo "  sample-context/backlog.md      — Ideas + future tasks"
  echo ""
  echo -e "${BOLD}Quick start:${NC}"
  echo "  bash ctx.sh init            # First time setup"
  echo "  bash ctx.sh status          # Check current state"
  echo "  bash ctx.sh sync            # After config changes"
  echo "  bash ctx.sh enable Cursor   # Enable Cursor"
  echo "  bash ctx.sh export          # Copy context for web LLM"
  echo ""
}

# ── init ───────────────────────────────────────────────
cmd_init() {
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
  "agent_rules": [
    { "name": "Claude Code", "path": "CLAUDE.md",      "enabled": true  },
    { "name": "OpenCode",    "path": "AGENTS.md",       "enabled": true  },
    { "name": "Cursor",      "path": ".cursorrules",    "enabled": false },
    { "name": "Gemini CLI",  "path": "GEMINI.md",       "enabled": false },
    { "name": "Codex",       "path": "CODEX.md",        "enabled": false }
  ]
}
CONFIGEOF
    fi
    echo -e "  ${GREEN}✓${NC} ctx.config.json created"
  else
    echo -e "  ${YELLOW}~${NC} ctx.config.json already exists (skipped)"
  fi

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
  echo ""
  echo -e "${YELLOW}⚠️  Update the placeholders in these files before using:${NC}"
  echo "  1. sample-context/AGENT_RULES.md — [Project Name], tech stack section"
  echo "  2. sample-context/MASTER_PLAN.md — [Project Name], Last Updated, first tasks"
  echo "  3. sample-context/decisions.md   — [Project Name]"
  echo "  4. sample-context/backlog.md     — [Project Name]"
  echo ""
  echo -e "  Then tell your agent: ${CYAN}\"Read MASTER_PLAN.md and get started\"${NC}"
}

# Helper: create file only if it doesn't exist
_init_file() {
  local filename="$1"; shift
  local filepath="$CONTEXT_DIR/$filename"
  if [ ! -f "$filepath" ]; then
    cat > "$filepath"
    echo -e "  ${GREEN}✓${NC} sample-context/$filename created"
  else
    echo -e "  ${YELLOW}~${NC} sample-context/$filename already exists (skipped)"
    cat > /dev/null  # consume heredoc
  fi
}

# ── status ─────────────────────────────────────────────
cmd_status() {
  require_config
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
    awk '/^## Current State/{found=1; next} found && /^##/{exit} found{print "  " $0}' "$MASTER_PLAN" | head -6
    echo ""
    echo -e "  ${BOLD}Next Actions:${NC}"
    awk '/^## Next Actions/{found=1; next} found && /^##/{exit} found{print "  " $0}' "$MASTER_PLAN" | head -4
    echo ""
    echo -e "  ${CYAN}Details: sample-context/MASTER_PLAN.md${NC}"
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

  get_agents | while IFS="|" read -r name path enabled; do
    LINK_PATH="$PROJECT_ROOT/$path"
    if [ "$enabled" = "True" ] || [ "$enabled" = "true" ]; then
      [ -L "$LINK_PATH" ] || [ -f "$LINK_PATH" ] && rm "$LINK_PATH"
      RELATIVE=$(python3 -c "import os; print(os.path.relpath('$SOURCE_PATH', os.path.dirname('$LINK_PATH')))")
      ln -s "$RELATIVE" "$LINK_PATH"
      echo -e "  ${GREEN}✓${NC} $name: $path → $SOURCE"
    else
      if [ -L "$LINK_PATH" ]; then
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

# ── version ────────────────────────────────────────────
cmd_version() {
  echo "ctx v${VERSION}"
}

# ── main ───────────────────────────────────────────────
case "${1:-help}" in
  init)    cmd_init ;;
  status)  cmd_status ;;
  sync)    cmd_sync ;;
  export)  cmd_export ;;
  list)    cmd_list ;;
  enable)  cmd_enable "$2" ;;
  disable) cmd_disable "$2" ;;
  version) cmd_version ;;
  help|--help|-h|*) cmd_help ;;
esac
