---
name: threads
description: Multi-agent thread orchestration for Claude Code
allowed-tools: Bash,Read,Write,Edit,Grep,Glob,TodoWrite
user-invocable: true
---

# Claude Threads - Multi-Agent Orchestration

You are managing claude-threads, a multi-agent orchestration framework.

## Quick Start for Multi-Instance

If you want other Claude Code instances to connect and spawn threads, first start the orchestrator and API:

### Step 1: Start Orchestrator and API

```bash
# Start orchestrator daemon
ct orchestrator start

# Start API server (enables external connections)
ct api start
```

### Step 2: Check Status

```bash
ct orchestrator status
ct api status
```

Now other Claude Code instances can connect using `/ct-connect`.

---

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

### Base Worktree (Memory-Efficient Pattern)

```bash
# Create base worktree when watching a PR
ct worktree base-create <pr> <branch> [target] [remote]

# Update base worktree from remote
ct worktree base-update <pr>

# Show base worktree status
ct worktree base-status <pr>

# Remove base worktree and all forks
ct worktree base-remove <pr> [--force]
```

### Fork Worktrees (For Sub-Agents)

```bash
# Create fork from base (shares git objects, ~1MB vs ~100MB)
ct worktree fork <pr> <fork-id> <branch> [purpose]
# Purposes: conflict_resolution, comment_handler, ci_fix, general

# Merge fork changes back to base
ct worktree merge-back <fork-id> [--no-push]

# Remove fork worktree
ct worktree remove-fork <fork-id> [--force]

# List all forks for a PR
ct worktree list-forks <pr>

# Reconcile database with filesystem
ct worktree reconcile [--fix]
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

### Remote Connection (Multi-Instance)

```bash
# Connect to a remote orchestrator
ct remote connect <host:port> --token <token>

# Disconnect from remote
ct remote disconnect

# Show connection status
ct remote status

# Auto-discover running orchestrator
ct remote discover
```

### Spawn (Create + Start)

```bash
# Spawn a thread locally or remotely
ct spawn <name> [options]

# Examples:
ct spawn epic-7a --template bmad-developer.md --worktree
ct spawn story-123 --mode automatic --context '{"story_id":"123"}'
ct spawn ci-fix --template fixer.md --wait

# Options:
#   --template, -t <file>   Prompt template
#   --mode, -m <mode>       Thread mode
#   --context, -c <json>    Context JSON
#   --worktree, -w          Use isolated worktree
#   --worktree-base <br>    Base branch
#   --wait                  Wait for completion
#   --remote                Force remote API
#   --local                 Force local database
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

### Multi-Instance Workflow

**Instance 1 (this one):** Run `/threads` to start orchestrator and API

**Instance 2 (external):** Run `/ct-connect` to connect and spawn threads

```
Instance 1: /threads           →  Starts orchestrator + API
Instance 2: /ct-connect        →  Auto-discovers and connects
Instance 2: /ct-spawn epic-7a  →  Spawns thread with worktree
```

Monitor spawned threads from either instance:
```bash
ct thread list running
ct worktree list
```

## Base + Fork Pattern

For PR lifecycle management, use the memory-efficient base + fork pattern:

```
PR Base Worktree (created when watching PR)
    │
    ├── Fork: conflict-resolver (on conflict)
    │   └── Shares git objects with base (~1MB vs ~100MB)
    │
    ├── Fork: comment-handler-1 (per comment)
    │
    └── Fork: comment-handler-2

Workflow:
1. Create base: ct worktree base-create 123 feature/my-pr main
2. Fork for sub-agent: ct worktree fork 123 conflict-fix fix/conflict
3. After sub-agent: ct worktree merge-back conflict-fix
4. Cleanup fork: ct worktree remove-fork conflict-fix
5. Push from base: cd $(ct worktree base-path 123) && git push
6. When PR done: ct worktree base-remove 123
```

## Documentation

- [ARCHITECTURE.md](../docs/ARCHITECTURE.md) - System architecture
- [AGENT-COORDINATION.md](../docs/AGENT-COORDINATION.md) - Coordination patterns
- [WORKTREE-GUIDE.md](../docs/WORKTREE-GUIDE.md) - Worktree management
- [EVENT-REFERENCE.md](../docs/EVENT-REFERENCE.md) - Event types
- [MULTI-INSTANCE.md](../docs/MULTI-INSTANCE.md) - Distributed deployment

## When to Use

Use claude-threads when you need to:
1. Run multiple Claude agents in parallel
2. Develop on multiple branches simultaneously (with worktrees)
3. Coordinate between agents via events
4. Resume long-running sessions
5. Schedule periodic tasks
6. Monitor and manage agent lifecycle
7. Automatically fix CI failures and address review comments (PR Shepherd)
8. Spawn threads from external Claude Code instances (Multi-Instance)
9. Memory-efficient sub-agent coordination (base + fork pattern)
