---
name: threads
description: Multi-agent thread orchestration for Claude Code
allowed-tools: Bash,Read,Write,Edit,Grep,Glob,TodoWrite
user-invocable: true
---

# Claude Threads - Multi-Agent Orchestration

You are managing claude-threads, a multi-agent orchestration framework.

## Available Commands

Execute these commands to manage threads:

### Thread Management

```bash
# List all threads
ct thread list

# List threads by status
ct thread list running
ct thread list ready
ct thread list completed

# Create a new thread
ct thread create <name> --mode <mode> --template <template>
# Modes: automatic, semi-auto, interactive, sleeping

# Create a thread with isolated git worktree
ct thread create <name> --mode automatic --worktree
ct thread create <name> --worktree --worktree-base develop  # Custom base branch

# Start a thread
ct thread start <thread-id>

# Stop a thread
ct thread stop <thread-id>

# Show thread status
ct thread status <thread-id>

# View thread logs
ct thread logs <thread-id>

# Resume a thread interactively
ct thread resume <thread-id>

# Delete a thread
ct thread delete <thread-id>
```

### Worktree Management

```bash
# List all active worktrees
ct worktree list

# Show worktree details
ct worktree status <worktree-id>

# Cleanup orphaned worktrees
ct worktree cleanup
```

### PR Shepherd

```bash
# Watch a PR (creates isolated worktree)
ct pr watch <pr_number>

# Show PR status
ct pr status <pr_number>

# List all watched PRs
ct pr list

# Stop watching a PR
ct pr stop <pr_number>

# Run shepherd as daemon
ct pr daemon
```

### Orchestrator

```bash
# Start the orchestrator daemon
ct orchestrator start

# Stop the orchestrator
ct orchestrator stop

# Show orchestrator status
ct orchestrator status

# Restart the orchestrator
ct orchestrator restart
```

### Events

```bash
# List recent events
ct event list

# Publish an event
ct event publish <type> '<json-data>'
```

## Thread Modes

| Mode | Description |
|------|-------------|
| `automatic` | Fully autonomous, runs in background with `claude -p` |
| `semi-auto` | Automatic with prompts for critical decisions |
| `interactive` | Full interactive mode, every step confirmed |
| `sleeping` | Waiting for trigger (time or event) |

## Thread Lifecycle

```
CREATED → READY → RUNNING → [WAITING|SLEEPING|BLOCKED] → COMPLETED
                     ↑              ↓
                     └──────────────┘
```

## Example Workflows

### Create and Run a Developer Thread with Worktree

```bash
# Create thread with developer template and isolated worktree
ct thread create epic-42-dev --mode automatic --template prompts/developer.md --worktree --context '{"epic_id": "42"}'

# Start the thread
ct thread start <thread-id>

# Monitor progress
ct thread status <thread-id>
ct thread logs <thread-id>
ct worktree list
```

### Resume an Interactive Session

```bash
# Find the thread
ct thread list waiting

# Resume it
ct thread resume <thread-id>
```

### Monitor Multiple Threads

```bash
# Start orchestrator
ct orchestrator start

# Check status
ct orchestrator status

# View all threads
ct thread list
```

## Data Location

Thread data is stored in `.claude-threads/`:
- `threads.db` - SQLite database
- `logs/` - Log files
- `templates/` - Prompt templates
- `config.yaml` - Configuration
- `worktrees/` - Git worktrees for isolated development

## When to Use

Use claude-threads when you need to:
1. Run multiple Claude agents in parallel
2. Develop on multiple branches simultaneously (with worktrees)
3. Coordinate between agents via events
4. Resume long-running sessions
5. Schedule periodic tasks
6. Monitor and manage agent lifecycle
7. Automatically fix CI failures and address review comments (PR Shepherd)
