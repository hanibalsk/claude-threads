---
name: bmad-autopilot-skill
description: Autonomous BMAD development orchestration
allowed-tools: Bash,Read
version: "1.0.0"
---

# BMAD Autopilot Skill

This skill provides autonomous development capabilities following the BMAD (Breakthrough Method for Agile Development) methodology.

## When to Use

Activate this skill when the user wants to:
- Automatically process BMAD epics end-to-end
- Develop stories following TDD principles
- Create and manage pull requests automatically
- Handle CI feedback and code reviews
- Run the full BMAD development pipeline

## BMAD Workflow Phases

```
CHECK_PENDING_PR → FIND_EPIC → CREATE_BRANCH → DEVELOP_STORIES
       ↓                                              ↓
   (resume)                                    CODE_REVIEW
                                                     ↓
DONE ← MERGE_PR ← WAIT_COPILOT ← CREATE_PR ← (approved)
       ↓              ↓
    BLOCKED      FIX_ISSUES
```

## Essential Commands

### Start BMAD Autopilot

```bash
# Initialize claude-threads
ct init

# Create BMAD workflow thread
ct thread create bmad-main \
  --mode automatic \
  --template bmad-autopilot.yaml \
  --context '{"epic_pattern": "", "base_branch": "main"}'

# Start the thread
ct thread start bmad-main
```

### Process Specific Epics

```bash
# Single epic
ct thread create bmad-7a \
  --template bmad-developer.md \
  --context '{"epic_id": "7A"}'

# Multiple epics (space-separated)
ct thread create bmad-batch \
  --template bmad-autopilot.yaml \
  --context '{"epic_pattern": "7A 8A 10B"}'

# Pattern matching
ct thread create bmad-all-10 \
  --template bmad-autopilot.yaml \
  --context '{"epic_pattern": "10.*"}'
```

### Monitor Progress

```bash
# Check thread status
ct thread status bmad-main

# View logs
ct thread logs bmad-main -f

# List all BMAD events
ct event list --type "EPIC_*,STORY_*,PR_*"
```

## Agent Threads

The BMAD workflow spawns specialized agent threads:

| Agent | Template | Purpose |
|-------|----------|---------|
| Coordinator | `planner.md` | Find epics, manage workflow |
| Developer | `bmad-developer.md` | Implement stories with TDD |
| Reviewer | `bmad-reviewer.md` | Code review before PR |
| PR Manager | `bmad-pr-manager.md` | Create/manage pull requests |
| Fixer | `bmad-fixer.md` | Fix CI/review issues |
| Monitor | `pr-monitor.md` | Watch for PR status changes |

## Event Types

Events published during BMAD execution:

| Event | Description |
|-------|-------------|
| `NEXT_EPIC_READY` | Coordinator found next epic |
| `BRANCH_CREATED` | Feature branch created |
| `STORY_STARTED` | Developer starting story |
| `STORY_COMPLETED` | Story implementation done |
| `DEVELOPMENT_COMPLETED` | All stories finished |
| `REVIEW_COMPLETED` | Code review done |
| `PR_CREATED` | Pull request opened |
| `CI_PASSED` / `CI_FAILED` | CI status update |
| `COPILOT_REVIEW` | Copilot review received |
| `FIXES_NEEDED` | Issues require fixing |
| `PR_APPROVED` | PR approved |
| `PR_MERGED` | PR merged successfully |
| `EPIC_COMPLETED` | Epic fully processed |

## Configuration

In `.claude-threads/config.yaml`:

```yaml
bmad:
  epic_pattern: ""          # Process all, or specify "7A 8A"
  base_branch: main
  auto_merge: true          # Merge when approved
  max_concurrent_prs: 2     # Limit parallel PRs
  check_interval: 300       # PR check interval (seconds)
```

## Story File Locations

BMAD stories are typically in:
- `_bmad-output/stories/epic-{id}/`
- `docs/stories/{id}/`

## Commit Message Format

```
feat(epic-{id}): implement story X.Y

Story {id}.{story}:
- Change description
- Another change
```

## Handling Blocked State

If autopilot becomes blocked:

```bash
# Check why
ct thread status bmad-main --verbose

# View recent events
ct event list --source bmad-main --limit 20

# Check logs
ct thread logs bmad-main

# Resume manually
ct thread resume bmad-main
```

## GitHub Integration

For automatic PR status updates:

```bash
# Start webhook server
ct webhook start --port 8080

# GitHub webhook settings:
# URL: http://your-server:8080/webhook
# Events: Pull requests, Check runs, Reviews
```

## Auto-Approval Conditions

PRs are auto-approved when:
1. 10+ minutes since last push
2. Copilot review exists
3. All review threads resolved
4. All CI checks passed

## Parallel vs Sequential Mode

**Sequential** (default):
- One epic at a time
- Simpler state management
- Good for small teams

**Parallel**:
- Multiple epics concurrently
- Uses git worktrees
- Higher throughput
- Configure with `max_concurrent_prs`
