---
name: threads
description: Multi-agent thread orchestration for Claude Code
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

### Create and Run a Developer Thread

```bash
# Create thread with developer template
ct thread create epic-42-dev --mode automatic --template prompts/developer.md --context '{"epic_id": "42"}'

# Start the thread
ct thread start <thread-id>

# Monitor progress
ct thread status <thread-id>
ct thread logs <thread-id>
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

## When to Use

Use claude-threads when you need to:
1. Run multiple Claude agents in parallel
2. Coordinate between agents via events
3. Resume long-running sessions
4. Schedule periodic tasks
5. Monitor and manage agent lifecycle
