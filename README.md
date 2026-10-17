# ctx-kit

> A lightweight CLI that gives all your AI agents the same project context.
>
> 🇰🇷 한국어 버전: [README.ko.md](README.ko.md)

When working with multiple AI agents (Claude Code, Codex, Antigravity, Cursor, etc.), each agent starts a session without knowing what decisions were made, what's already built, or what the current priorities are.

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

`ctx.config.json` also defines the context directory through `source`. By default this is `sample-context/AGENT_RULES.md`, but projects can point it at another directory such as `docs/context/AGENT_RULES.md`; `status`, `sync`, `export`, `generate`, `log`, and `timeline` will follow that context directory.

---

## Commands

| Command | Description |
|---------|-------------|
| `bash ctx.sh init` | Initialize context files + symlinks for a new project |
| `bash ctx.sh status` | Show symlink status + project summary from MASTER_PLAN |
| `bash ctx.sh sync` | Rebuild symlinks + auto-update Last Updated date |
| `bash ctx.sh export` | Print full context for web LLMs (Claude.ai, ChatGPT, etc.) |
| `bash ctx.sh generate <type>` | Collect configured source files into a generated context bundle |
| `bash ctx.sh log --summary "..."` | Record a commit/work-unit summary in `<context>/work-log/timeline.jsonl` |
| `bash ctx.sh timeline --limit 20` | Show recent work-log entries |
| `bash ctx.sh backfill [--limit N]` | Backfill past Git commits into timeline.jsonl |
| `bash ctx.sh archive [--keep N]` | Archive completed tasks, split old logs & archive deprecated ADRs |
| `bash ctx.sh hook install` | Install Git pre-commit hook for auto-sync & auto-log |
| `bash ctx.sh hook uninstall` | Remove Git pre-commit hook |
| `bash ctx.sh hook status` | Show Git integration and context repository status |
| `bash ctx.sh list` | List all agents and their enabled status |
| `bash ctx.sh enable <n>` | Enable a specific agent |
| `bash ctx.sh disable <n>` | Disable a specific agent |
| `bash ctx.sh help` | Show full help |

> **Windows Users**: You can use `ctx.cmd` directly (e.g. `ctx status`, `ctx log`, `ctx hook install`, `ctx archive`) from CMD or PowerShell!

---

## 3-Tier Hierarchical Context & Archiving (Prevent Context Bloat)

As projects grow, completed tasks and hundreds of commit logs accumulate, causing **context window bloat, token waste, and AI distraction**. `ctx-kit` provides a **3-tier hierarchical context structure**:

```text
your-project/
└── .ctx-local/ (or sample-context/)
    ├── AGENT_RULES.md         ← [Hot] Loaded every session (Rules)
    ├── MASTER_PLAN.md         ← [Hot] Active tasks & next actions only
    ├── decisions.md           ← [Hot] Current active architecture decisions
    ├── backlog.md             ← [Hot] Ideas and open questions
    ├── work-log/
    │   ├── timeline.jsonl     ← [Hot] Recent 20~30 work unit logs
    │   └── timeline-digest.md ← [Warm] Compressed milestone summary of past work
    └── archive/               ← [Cold] Excluded from AI context loading!
        ├── completed-tasks.md ← Completed [x] tasks moved from MASTER_PLAN
        ├── decisions-deprecated.md ← Deprecated/superseded ADRs from decisions.md
        └── timeline-YYYY-MM.jsonl ← Monthly partitioned historical logs
```

### Run Archiving with One Command
```bash
bash ctx.sh archive            # Keep top 30 logs, move completed tasks & deprecated ADRs to archive
bash ctx.sh archive --keep 20  # Keep top 20 logs
bash ctx.sh archive --no-decisions # Archive tasks and logs only
```

- **Tasks**: Completed `- [x]` items in `MASTER_PLAN.md` are moved to `archive/completed-tasks.md` under date headers, keeping your active plan slim and focused.
- **Decisions**: Deprecated or superseded ADRs (`Status: Deprecated / Superseded` / `상태: 폐기됨 / 대체됨`) in `decisions.md` are moved to `archive/decisions-deprecated.md`.
- **Logs**: Older entries in `timeline.jsonl` are split by month into `archive/timeline-YYYY-MM.jsonl`.
- **Digest**: A compressed milestone summary is generated in `work-log/timeline-digest.md` so agents can understand past history without token waste.
- **Token-Optimized Export**: `ctx export` automatically excludes the `archive/` folder to save 70~80% tokens (use `ctx export --all` to include cold archives).
- **Auto Git Commit**: All archives are automatically committed to the local private context Git repository.

---

## Git Sync & Auto-Log (Private Local Versioning)

Manage private AI context without polluting public team commits or leaking private notes to remote repositories:

1. **Zero Remote Leakage**: The context directory (e.g. `.ctx-local/` or `sample-context/`) is automatically added to `.gitignore`. Running `git push` will never push your private context.
2. **Independent Local Git Tracking**: `ctx hook install` initializes an independent Git repository inside your context directory and installs a `pre-commit` hook.
3. **Auto-Log Before Commit**: When `auto_log` is enabled in `ctx.config.json`, staged changes and diff statistics are automatically summarized and recorded into `timeline.jsonl` right before each `git commit`.
4. **Historical Backfill**: Adopting `ctx-kit` in an existing project? Run `bash ctx.sh backfill --limit 30` to reconstruct past commits into `timeline.jsonl`.

```json
// ctx.config.json
{
  "source": ".ctx-local/AGENT_RULES.md",
  "git_sync": {
    "enabled": true,
    "auto_log": true
  }
}
```

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
    ├── generated/                ← Output from ctx generate
    ├── work-log/
    │   └── timeline.jsonl        ← Append-only work-unit timeline
    └── visuals/                 ← Mermaid diagrams, etc.
```

---

## Adding Agents

Add an entry to `agent_rules` in `ctx.config.json`:

```json
{
  "source": "sample-context/AGENT_RULES.md",
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
    { "name": "Cursor",      "path": ".cursor/rules/context.mdc", "enabled": true,  "_note": "Cursor IDE" },
    { "name": "MyAgent",     "path": "MY_AGENT.md",              "enabled": false }
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
bash ctx.sh disable Antigravity
```

Keep `name` short because it is used by `enable` and `disable`. Put longer tool notes in `_note`.

When two agents share the same rule file (e.g. Codex and Antigravity both follow the AGENTS.md spec), list them as separate rows pointing to the same `path`. `sync` keeps the symlink as long as at least one of them is enabled.

To collect more project-specific files, extend `generate.project.collect`:

```json
{
  "generate": {
    "project": {
      "output": "sample-context/generated/project-raw.md",
      "collect": [
        "README.md",
        "docs/**/*.md",
        "src/**/*",
        "app/**/*",
        "server/**/*",
        "web/src/**/*"
      ]
    }
  }
}
```

---

## Customizing AGENT_RULES.md

`sample-context/AGENT_RULES.md` defines how agents behave. The default template includes:

- **Session start protocol** — guides agents to read current state, decisions, the optional milestone digest, and backlog
- **Auto-detect + record protocol** — asks before new decisions or scope/priority changes; records factual progress within an authorized task directly
- **Session end protocol** — verifies changes, updates affected context, records through `ctx log`, and checks readback before reporting closure
- **Absolute rules** — project-specific constraints

Edit the `## 5. Project Context` section to match your project name, tech stack, and current phase.

### Closing a work unit

For work that changes project files (including documentation), the agent follows this sequence:

1. Inspect the actual changes and run relevant checks. Report implementation, validation, commit, and merge status separately.
2. Update `MASTER_PLAN.md` only when current state or next actions changed. Decisions and backlog updates still require applicable authorization; unchanged files stay untouched.
3. Run `ctx log`, check its exit status, and read back the matching entry through `ctx timeline`. Include validation results and remaining issues in the summary; supply the relevant files explicitly.

```bash
bash ctx.sh log --summary "Updated documentation; checks passed; no open issues" --files "README.md" --type docs
bash ctx.sh timeline --limit 1 --json
```

If another writer added a newer entry, increase the read limit and find your own summary and files. If recording or verification fails, report the cause and mark logging as failed or unverified. Check for an existing entry before retrying, and use only an allowed recovery/approval path. Do not bypass the CLI by editing `timeline.jsonl` directly.

Read-only analysis/review needs no context edits or work-log entry. Explicit allowed-file or no-logging restrictions take precedence; report skipped steps. An agent without filesystem/CLI access provides proposed updates and commands, marked as unapplied. These are agent instructions, not automatic enforcement by the CLI; the Git hook does not replace this closure procedure.

### Template paths and existing installations

`init` renders document references using the context directory from `ctx.config.json` and CLI examples using the installed script location. For example, `source: "docs/context/AGENT_RULES.md"` and `scripts/ctx.sh` produce references to `docs/context/MASTER_PLAN.md` and commands starting with `bash scripts/ctx.sh`. Document paths are relative to the project root; run commands there.

Existing rule files are skipped by `init`, and `sync` rebuilds links rather than upgrading their content (it also refreshes the plan's `Last Updated` date). To adopt these rules in an existing project:

1. Back up the file identified by `source` in `ctx.config.json`.
2. Compare it with this repository's `AGENT_RULES.md`. Merge the session-start, authorization, closure, and CLI guidance while preserving project-specific instructions and Project Context.
3. Adapt document paths and CLI examples to your installation, then run `bash ctx.sh status` (or `bash scripts/ctx.sh status`). Check the source and enabled links, and verify the closure flow on your next authorized write task.

Do not delete your context directory or replace customized rules wholesale to upgrade.

---

## Context Files

### MASTER_PLAN.md
The starting point for every session. Tracks what's done, what's next, and open questions. The `Last Updated` date is automatically refreshed on every `ctx sync`.

### decisions.md
Records technical decisions in ADR (Architecture Decision Record) format — what was decided, why, and what was given up. Prevents relitigating the same choices with every new agent session.

### backlog.md
Captures ideas, future features, and open questions that aren't urgent but shouldn't be lost.

### generated/
Contains source bundles created by `ctx generate <type>`. Configure each type in `ctx.config.json` under `generate`.

### work-log/
Contains an append-only `timeline.jsonl` created by `ctx log`. Use it to track commit-level or work-unit summaries without depending on a specific AI session history.

```bash
bash ctx.sh log --summary "Implemented feedback MVP" --type work
bash ctx.sh log --commit abc1234 --summary "Release cleanup" --type release
bash ctx.sh timeline --limit 10
bash ctx.sh timeline --json
```

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
| Claude (Claude Code) | `CLAUDE.md` | ✅ enabled |
| Codex (OpenAI Codex) | `AGENTS.md` | ✅ enabled |
| Antigravity (Google) | `AGENTS.md` (shared with Codex) | ✅ enabled |
| Cursor | `.cursor/rules/context.mdc` | ✅ enabled |

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

## Development checks

No additional test dependencies are required:

```bash
bash -n ctx.sh
python3 -B -m unittest discover -s tests -v
git diff --check
```

Tests run in temporary projects and cover standalone/default initialization, custom context paths, `scripts/` commands, preservation of customized context, and successful/failed log recording. They do not run an AI model or verify that an agent obeys the instructions.

Keep the root `AGENT_RULES.md` and the embedded rules in `ctx.sh`'s `cmd_init` in sync. The embedded copy preserves installation by copying only `ctx.sh` and configuration; the tests compare generated rules with the root template to catch drift.

---

## License

MIT
