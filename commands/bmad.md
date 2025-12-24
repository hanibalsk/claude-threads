---
name: bmad
description: Run BMAD Autopilot autonomous development
allowed-tools: Bash,Read,Write,Edit,Grep,Glob,TodoWrite
user-invocable: true
---

# /bmad - BMAD Autopilot Command

Run autonomous development following the BMAD Method.

## Usage

```
/bmad [epic-pattern] [options]
```

## Arguments

- `epic-pattern` - Optional. Epic IDs to process (e.g., "7A", "7A 8A", "10.*")
  - If omitted, processes all available epics

## Quick Start

```bash
# Process all epics
/bmad

# Process specific epic
/bmad 7A

# Process multiple epics
/bmad "7A 8A 10B"

# Process epics matching pattern
/bmad "10.*"
```

## What It Does

1. **Finds Epics** - Scans for BMAD epic files
2. **Creates Branch** - `feature/epic-{id}`
3. **Develops Stories** - Implements each story with TDD
4. **Reviews Code** - Internal code review
5. **Creates PR** - Opens pull request
6. **Monitors CI** - Waits for checks to pass
7. **Fixes Issues** - Addresses review feedback
8. **Merges** - Squash merges when approved
9. **Repeats** - Moves to next epic

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
ct webhook start --port 8080
# Configure in GitHub: http://server:8080/webhook
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

### Parallel Development

```bash
# Process multiple epics concurrently
ct thread create bmad-parallel \
  --mode automatic \
  --template bmad-autopilot.yaml \
  --context '{"epic_pattern": "7A 8A 9A", "max_concurrent_prs": 3}'

ct orchestrator start
ct thread start bmad-parallel
```
