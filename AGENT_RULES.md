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
