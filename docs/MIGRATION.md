# Migration Guide: bmad-autopilot.sh → claude-threads

This guide helps you migrate from the original `bmad-autopilot.sh` bash script to the claude-threads framework.

## Overview

The claude-threads framework replaces the monolithic bash script with a modular, event-driven architecture:

| Feature | bmad-autopilot.sh | claude-threads |
|---------|-------------------|----------------|
| State persistence | Files + Git | SQLite database |
| Parallel execution | Limited | Full support |
| Inter-thread comms | None | Blackboard pattern |
| PR monitoring | Polling loop | Background thread |
| Configuration | Hard-coded | YAML config |
| Extensibility | Modify script | Add templates |

## Quick Start

### 1. Install claude-threads

```bash
# Clone the repository
git clone https://github.com/hanibalsk/claude-threads.git
cd claude-threads

# Run installation
./install.sh

# Initialize in your project
cd /path/to/your/project
ct init
```

### 2. Configure for BMAD

```bash
# Copy BMAD templates
cp -r /path/to/claude-threads/templates/prompts/bmad-*.md .claude-threads/templates/prompts/
cp /path/to/claude-threads/templates/workflows/bmad-autopilot.yaml .claude-threads/templates/workflows/

# Edit configuration
cat >> .claude-threads/config.yaml << 'EOF'

# BMAD Autopilot Settings
bmad:
  epic_pattern: ""          # Process all epics, or specify "7A 8A 10B"
  base_branch: main
  auto_merge: true
  max_concurrent_prs: 2
  check_interval: 300       # 5 minutes
EOF
```

### 3. Start the Orchestrator

```bash
# Start in background
ct orchestrator start

# Or run the BMAD workflow directly
ct thread create --template bmad-autopilot --name "bmad-main"
ct thread start bmad-main
```

## Feature Mapping

### State Machine Phases

| bmad-autopilot.sh Phase | claude-threads Equivalent |
|-------------------------|---------------------------|
| `CHECK_PENDING_PR` | `CHECK_PENDING_PR` transition |
| `FIND_EPIC` | `coordinator` thread |
| `CREATE_BRANCH` | `create_branch` action |
| `DEVELOP_STORIES` | `developer` thread |
| `CODE_REVIEW` | `reviewer` thread |
| `CREATE_PR` | `pr-manager` thread |
| `WAIT_COPILOT` | `monitor` thread (sleeping) |
| `FIX_ISSUES` | `fixer` thread |
| `MERGE_PR` | `merge_pr` action |

### Functions → Templates

| Original Function | New Template |
|-------------------|--------------|
| `develop_epic()` | `templates/prompts/bmad-developer.md` |
| `review_code()` | `templates/prompts/bmad-reviewer.md` |
| `create_pr()` | `templates/prompts/bmad-pr-manager.md` |
| `fix_issues()` | `templates/prompts/bmad-fixer.md` |
| `find_next_epic()` | `templates/prompts/planner.md` |

### State Persistence

**Old approach** (file-based):
```bash
# bmad-autopilot.sh stored state in files
echo "$CURRENT_PHASE" > "$STATE_DIR/phase"
echo "$CURRENT_EPIC" > "$STATE_DIR/epic"
```

**New approach** (SQLite):
```bash
# claude-threads uses SQLite
ct thread status bmad-main --json

# Query state directly
sqlite3 .claude-threads/threads.db \
  "SELECT phase, context FROM threads WHERE name='bmad-main'"
```

### PR Monitoring

**Old approach** (blocking loop):
```bash
# bmad-autopilot.sh ran a blocking loop
while true; do
    check_pr_status
    sleep 300
done
```

**New approach** (sleeping thread):
```yaml
# In bmad-autopilot.yaml workflow
monitor:
  name: "bmad-pr-monitor"
  mode: sleeping
  schedule:
    type: interval
    interval: 300  # 5 minutes
```

The monitor thread wakes periodically, checks status, publishes events, then sleeps.

## Configuration Migration

### Environment Variables

| Old Variable | New Config Path |
|--------------|-----------------|
| `BMAD_EPIC_PATTERN` | `bmad.epic_pattern` |
| `BMAD_BASE_BRANCH` | `bmad.base_branch` |
| `BMAD_AUTO_MERGE` | `bmad.auto_merge` |
| `CLAUDE_SESSION_ID` | Managed per-thread |

### Example config.yaml

```yaml
# .claude-threads/config.yaml
version: "1.0"

orchestrator:
  max_concurrent_threads: 5
  poll_interval: 1

threads:
  default_mode: automatic
  default_max_turns: 80
  default_timeout: 3600

bmad:
  epic_pattern: ""
  base_branch: main
  auto_merge: true
  max_concurrent_prs: 2
  check_interval: 300
```

## CLI Command Mapping

| bmad-autopilot.sh | claude-threads |
|-------------------|----------------|
| `./bmad-autopilot.sh` | `ct thread start bmad-main` |
| `./bmad-autopilot.sh --epic 7A` | `ct thread create --template bmad-autopilot --context '{"epic_pattern":"7A"}'` |
| `./bmad-autopilot.sh --status` | `ct thread status bmad-main` |
| `./bmad-autopilot.sh --resume` | `ct thread resume bmad-main` |
| `tail -f logs/autopilot.log` | `ct thread logs bmad-main -f` |

## Event System

claude-threads introduces an event-driven architecture. Key BMAD events:

### Published Events

```bash
# View all BMAD events
ct event list --type "EPIC_*,STORY_*,PR_*"

# Subscribe to events in real-time
ct event subscribe "PR_*"
```

### Event Types

| Event | Description | Data |
|-------|-------------|------|
| `NEXT_EPIC_READY` | Coordinator found next epic | `{epic_id, epic_file}` |
| `STORY_STARTED` | Developer starting story | `{epic_id, story_id}` |
| `STORY_COMPLETED` | Story implementation done | `{epic_id, story_id, commit}` |
| `DEVELOPMENT_COMPLETED` | All stories done | `{epic_id}` |
| `REVIEW_COMPLETED` | Code review finished | `{epic_id, status}` |
| `PR_CREATED` | Pull request created | `{epic_id, pr_number}` |
| `CI_PASSED` / `CI_FAILED` | CI status update | `{pr_number, status}` |
| `PR_APPROVED` | PR approved | `{epic_id, pr_number}` |
| `PR_MERGED` | PR merged | `{epic_id, pr_number}` |
| `EPIC_COMPLETED` | Epic fully processed | `{epic_id}` |

## GitHub Webhook Integration

Instead of polling, use webhooks for real-time updates:

```bash
# Start webhook server
ct webhook start --port 8080

# Configure GitHub webhook:
# URL: https://your-server:8080/webhook
# Secret: (from config.yaml)
# Events: Pull requests, Check runs, Reviews
```

## Troubleshooting

### Common Issues

**Thread stuck in BLOCKED state:**
```bash
# Check what's blocking
ct thread status bmad-main --verbose

# View recent events
ct event list --source bmad-main --limit 20

# Resume manually
ct thread resume bmad-main
```

**Database locked:**
```bash
# Claude-threads uses WAL mode, but if issues occur:
ct orchestrator stop
sqlite3 .claude-threads/threads.db "PRAGMA wal_checkpoint(TRUNCATE);"
ct orchestrator start
```

**Session expired:**
```bash
# Create new session for thread
ct thread stop bmad-main
ct thread start bmad-main --new-session
```

### Logs

```bash
# Orchestrator logs
tail -f .claude-threads/logs/orchestrator.log

# Thread-specific logs
ct thread logs bmad-main

# All logs
ls -la .claude-threads/logs/
```

## Rollback

If you need to return to bmad-autopilot.sh:

```bash
# Stop claude-threads
ct orchestrator stop

# Your bmad-autopilot.sh should still work
./bmad-autopilot.sh --resume
```

The old script and new framework can coexist, but avoid running both simultaneously on the same epic.

## Benefits of Migration

1. **Parallel Processing**: Multiple epics can be developed concurrently
2. **Resilient State**: SQLite survives crashes, supports transactions
3. **Better Monitoring**: Real-time events, structured logs
4. **Extensibility**: Add custom templates without modifying core code
5. **Integration Ready**: GitHub webhooks, n8n workflows, REST API
6. **Foreground/Background**: Interactive debugging + autonomous execution

## Getting Help

- Documentation: `docs/` directory
- Architecture: `docs/ARCHITECTURE.md`
- API Reference: `docs/API.md`
- Issues: https://github.com/hanibalsk/claude-threads/issues
