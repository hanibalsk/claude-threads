---
name: bmad
description: Run BMAD Autopilot autonomous development
allowed-tools: Bash,Read,Write,Edit,Grep,Glob,TodoWrite
user-invocable: true
version: "1.2.1"
---

# /bmad - BMAD Autopilot Command

Run autonomous development following the BMAD Method with git worktree isolation.

## Usage

```
/bmad [epic-pattern] [options]
```

## Arguments

- `epic-pattern` - Optional. Epic IDs to process (e.g., "7A", "7A 8A", "10.*")
  - If omitted, processes all available epics
- `--worktree` - Create isolated git worktree for development

## Quick Start

```bash
# Process all epics
/bmad

# Process specific epic with worktree isolation
/bmad 7A --worktree

# Process multiple epics in parallel (each gets own worktree)
/bmad "7A 8A 10B" --worktree

# Process epics matching pattern
/bmad "10.*"
```

## What It Does

1. **Finds Epics** - Scans for BMAD epic files
2. **Creates Worktree** - Isolated git worktree for development (if `--worktree`)
3. **Creates Branch** - `feature/epic-{id}`
4. **Develops Stories** - Implements each story with TDD
5. **Reviews Code** - Internal code review
6. **Creates PR** - Opens pull request
7. **Monitors CI** - Waits for checks to pass (uses PR Shepherd with worktree isolation)
8. **Fixes Issues** - Addresses review feedback in isolated worktree
9. **Merges** - Squash merges when approved
10. **Cleans Up** - Removes worktree after merge
11. **Repeats** - Moves to next epic

## Workflow Phases

```
FIND_EPIC → CREATE_BRANCH → DEVELOP_STORIES → CODE_REVIEW
                                                   ↓
DONE ← MERGE_PR ← WAIT_COPILOT ← CREATE_PR ← (approved)
                       ↓
                  FIX_ISSUES
```

## Thread Agents

BMAD uses specialized agent threads:

| Agent | Role |
|-------|------|
| **Coordinator** | Finds epics, manages workflow |
| **Developer** | Implements stories |
| **Reviewer** | Code review |
| **PR Manager** | Creates/manages PRs |
| **Fixer** | Fixes CI/review issues |
| **Monitor** | Watches PR status |

## Monitoring

```bash
# Check current status
ct thread status bmad-main

# Follow logs
ct thread logs bmad-main -f

# View events
ct event list --type "EPIC_*"

# List active worktrees
ct worktree list
```

## Configuration

Set in `.claude-threads/config.yaml`:

```yaml
bmad:
  epic_pattern: ""
  base_branch: main
  auto_merge: true
  max_concurrent_prs: 2
  check_interval: 300

worktrees:
  enabled: true
  max_age_days: 7
  auto_cleanup: true
  default_base_branch: main
  auto_push: true

pr_shepherd:
  max_fix_attempts: 5
  ci_poll_interval: 30
  auto_merge: false
```

## Manual Intervention

If autopilot gets stuck:

```bash
# Check why
ct thread status bmad-main --verbose

# Resume
ct thread resume bmad-main

# Or restart
ct thread stop bmad-main
ct thread start bmad-main
```

## Story Locations

BMAD expects stories in:
- `_bmad-output/stories/epic-{id}/`
- `docs/stories/{id}/`

## Event Stream

Watch the development progress:

```bash
# Real-time events
ct event subscribe "STORY_*,PR_*"

# Recent events
ct event list --limit 50
```

## GitHub Integration

Enable webhooks for real-time PR updates:

```bash
ct webhook start --port 31338
# Configure in GitHub: http://server:31338/webhook
```

## Examples

### Development Sprint

```bash
# Start fresh sprint
/bmad "sprint-12.*"

# Monitor progress
ct thread list running

# Check for issues
ct event list --type "*_BLOCKED,*_FAILED"
```

### Single Feature

```bash
# Develop one epic interactively
ct thread create epic-7a \
  --mode interactive \
  --template bmad-developer.md \
  --context '{"epic_id": "7A"}'

ct thread resume epic-7a
```

### Parallel Development with Worktrees

```bash
# Process multiple epics concurrently with isolated worktrees
ct thread create epic-7a --mode automatic --template bmad-developer.md --worktree --context '{"epic_id": "7A"}'
ct thread create epic-8a --mode automatic --template bmad-developer.md --worktree --context '{"epic_id": "8A"}'
ct thread create epic-9a --mode automatic --template bmad-developer.md --worktree --context '{"epic_id": "9A"}'

# Each epic runs in its own isolated worktree
ct orchestrator start

# Monitor all worktrees
ct worktree list
```

### PR Shepherd Integration

```bash
# Watch PRs with automatic fix handling
ct pr watch 123

# Shepherd creates isolated worktree for fixes
# Automatically fixes CI failures and review comments
ct pr status 123

# Run as background daemon
ct pr daemon
```
