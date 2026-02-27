# ctx-kit

> A lightweight CLI that gives all your AI agents the same project context.

When working with multiple AI agents (Claude Code, OpenCode, Cursor, Gemini CLI, etc.), each agent starts a session without knowing what decisions were made, what's already built, or what the current priorities are.

```
Problem: Every agent starts blind → repeated explanations, forgotten decisions, inconsistent direction
Solution: One AGENT_RULES.md as the single source of truth, symlinked to every agent's rule file
```

---

## Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/nemory-dev/ctx-kit.git

# 2. Copy to your project root
cp ctx-kit/ctx.sh /your/project/
cp ctx-kit/ctx.config.json /your/project/

# 3. Initialize (once per project)
cd /your/project
bash ctx.sh init

# 4. Check status
bash ctx.sh status
```

Or if you prefer `scripts/` subdirectory:

```bash
cp ctx-kit/ctx.sh /your/project/scripts/
cp ctx-kit/ctx.config.json /your/project/

cd /your/project
bash scripts/ctx.sh init
```

---

## How It Works

```
ctx.config.json            ← Agent path registry (only edit this to add agents)
        ↓  ctx sync
CLAUDE.md ──┐
AGENTS.md ──┼──→ sample-context/AGENT_RULES.md  (Single Source of Truth)
GEMINI.md ──┘
```

Register agent rule file paths in `ctx.config.json`, run `ctx sync`, and all rule files become symlinks pointing to `AGENT_RULES.md`. Edit that one file and every agent picks up the change instantly.

---

## Commands

| Command | Description |
|---------|-------------|
| `bash ctx.sh init` | Initialize context files + symlinks for a new project |
| `bash ctx.sh status` | Show symlink status + project summary from MASTER_PLAN |
| `bash ctx.sh sync` | Rebuild symlinks + auto-update Last Updated date |
| `bash ctx.sh export` | Print full context for web LLMs (Claude.ai, ChatGPT, etc.) |
| `bash ctx.sh list` | List all agents and their enabled status |
| `bash ctx.sh enable <n>` | Enable a specific agent |
| `bash ctx.sh disable <n>` | Disable a specific agent |
| `bash ctx.sh help` | Show full help |

---

## File Structure

```
your-project/
├── ctx.config.json              ← Agent path config
├── CLAUDE.md                    → symlink → sample-context/AGENT_RULES.md
├── AGENTS.md                    → symlink → sample-context/AGENT_RULES.md
└── sample-context/
    ├── AGENT_RULES.md           ← Agent behavior rules (edit only this)
    ├── MASTER_PLAN.md           ← Current state + next actions
    ├── decisions.md             ← Architecture decision records (ADR)
    ├── backlog.md               ← Ideas + future tasks
    └── visuals/                 ← Mermaid diagrams, etc.
```

---

## Adding Agents

Add an entry to `agent_rules` in `ctx.config.json`:

```json
{
  "agent_rules": [
    { "name": "Claude Code", "path": "CLAUDE.md",   "enabled": true },
    { "name": "Cursor",      "path": ".cursorrules", "enabled": true },
    { "name": "My Agent",    "path": "MY_AGENT.md",  "enabled": true }
  ]
}
```

Then run:

```bash
bash ctx.sh sync
```

To enable or disable without editing the file:

```bash
bash ctx.sh enable Cursor
bash ctx.sh disable "Gemini CLI"
```

---

## Customizing AGENT_RULES.md

`sample-context/AGENT_RULES.md` defines how agents behave. The default template includes:

- **Session start protocol** — forces agents to read context files before starting work
- **Auto-detect + record protocol** — prompts to record decisions, status changes, and backlog items as they arise
- **Session end protocol** — agents output a summary of what changed
- **Absolute rules** — project-specific constraints

Edit the `## 5. Project Context` section to match your project name, tech stack, and current phase.

---

## Context Files

### MASTER_PLAN.md
The starting point for every session. Tracks what's done, what's next, and open questions. The `Last Updated` date is automatically refreshed on every `ctx sync`.

### decisions.md
Records technical decisions in ADR (Architecture Decision Record) format — what was decided, why, and what was given up. Prevents relitigating the same choices with every new agent session.

### backlog.md
Captures ideas, future features, and open questions that aren't urgent but shouldn't be lost.

---

## Web-Based LLMs (Claude.ai, ChatGPT, Gemini)

Web LLMs can't read files directly. Use `ctx export` to print your full context as text, then paste it into the chat:

```bash
bash ctx.sh export
# Copy the output → paste into Claude.ai / ChatGPT
```

When working in a web LLM, the agent will output file changes in this format for you to apply manually:

```
📝 File update needed
Add to sample-context/decisions.md:
---
### ADR-NNN: ...
...
---
```

---

## Supported Agents

Default configuration includes:

| Agent | Rule file | Default |
|-------|-----------|---------|
| Claude Code | `CLAUDE.md` | ✅ enabled |
| OpenCode | `AGENTS.md` | ✅ enabled |
| Cursor | `.cursorrules` | ○ disabled |
| Gemini CLI | `GEMINI.md` | ○ disabled |
| Codex | `CODEX.md` | ○ disabled |

Any agent that reads a rule file from a fixed path can be added.

---

## Requirements

- bash (macOS / Linux)
- python3 (for JSON parsing)

---

## Reuse Across Projects

```bash
# Clone once
git clone https://github.com/nemory-dev/ctx-kit.git ~/ctx-kit

# For each new project
cp ~/ctx-kit/ctx.sh /new/project/
cp ~/ctx-kit/ctx.config.json /new/project/
cd /new/project && bash ctx.sh init
```

Or add an alias:

```bash
# Add to ~/.zshrc or ~/.bashrc
alias ctx-setup='cp ~/ctx-kit/ctx.sh . && cp ~/ctx-kit/ctx.config.json . && bash ctx.sh init'
```

---

## License

MIT
