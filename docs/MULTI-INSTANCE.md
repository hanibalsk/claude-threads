# Multi-Instance Coordination

claude-threads supports connecting multiple Claude Code instances to a single orchestrator, enabling parallel thread execution and coordination across terminals.

## Overview

The multi-instance architecture allows:

- **External Claude Code sessions** to spawn threads on a running orchestrator
- **Parallel execution** of epics, stories, or tasks in isolated worktrees
- **Centralized coordination** through the shared SQLite database
- **Token-based authentication** for secure API access

**IMPORTANT**: Remote threads ALWAYS run in isolated git worktrees by default. This is required to prevent conflicts between parallel threads working on the same codebase.

## Architecture

```
Terminal 1: Orchestrator                    Terminal 2: External Claude Code
┌────────────────────────────┐             ┌────────────────────────────┐
│  ct orchestrator start     │             │  ct remote connect         │
│  ct api start              │◄────────────│  ct spawn epic-7a          │
│                            │   HTTP API  │  ct spawn epic-8a          │
│  Manages:                  │             │                            │
│  - Thread lifecycle        │             │  Uses:                     │
│  - Event coordination      │             │  - Remote API client       │
│  - Worktree allocation     │             │  - Token authentication    │
└─────────────┬──────────────┘             └────────────────────────────┘
              │
              │ Creates & manages
              ▼
     ┌────────────────────────────────────────────────────────────┐
     │                    Parallel Threads                        │
     │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
     │  │  epic-7a     │  │  epic-8a     │  │  epic-9a     │     │
     │  │  worktree/   │  │  worktree/   │  │  worktree/   │     │
     │  │  7a          │  │  8a          │  │  9a          │     │
     │  └──────────────┘  └──────────────┘  └──────────────┘     │
     └────────────────────────────────────────────────────────────┘
```

## Quick Start

### 1. Start the Orchestrator and API

```bash
# Terminal 1: Start orchestrator
ct orchestrator start

# Start API server with authentication token
export N8N_API_TOKEN=my-secret-token
ct api start
```

### 2. Connect from External Instance

```bash
# Terminal 2: Connect to orchestrator
export CT_API_TOKEN=my-secret-token
ct remote connect localhost:31337

# Verify connection
ct remote status
```

### 3. Spawn Threads

```bash
# Spawn a thread (uses remote API automatically)
ct spawn epic-7a --template bmad-developer.md --worktree

# Spawn multiple in parallel
ct spawn epic-7a --template bmad-developer.md --worktree
ct spawn epic-8a --template bmad-developer.md --worktree
ct spawn epic-9a --template bmad-developer.md --worktree
```

## Setup Guide

### API Server Configuration

The API server provides the HTTP interface for external connections.

#### Starting the API Server

```bash
# With token from environment
export N8N_API_TOKEN=your-secret-token
ct api start

# With explicit port
ct api start --port 31337

# Check status
ct api status
```

#### Configuration Options

In `config.yaml`:
```yaml
n8n:
  enabled: true
  api_port: 31337
  api_token: your-secret-token  # Or use N8N_API_TOKEN env var
```

#### Security Considerations

- **Always use a token** in production environments
- API binds to `127.0.0.1` by default (localhost only)
- For remote access, use `--bind 0.0.0.0` (with caution)
- Use HTTPS reverse proxy for production deployments

### Remote Connection

#### Connection Methods

1. **Explicit Connection**
   ```bash
   ct remote connect localhost:31337 --token my-token
   ```

2. **Auto-Discovery**
   ```bash
   export CT_API_TOKEN=my-token
   ct remote discover
   ```

3. **Environment-Based**
   ```bash
   export CT_API_URL=http://localhost:31337
   export CT_API_TOKEN=my-token
   ct spawn epic-7a  # Auto-connects
   ```

#### Connection State

Connection info is stored in `.claude-threads/remote.json`:
```json
{
  "api_url": "http://localhost:31337",
  "token": "your-token",
  "connected_at": "2024-01-15T10:00:00Z"
}
```

## Commands Reference

### Remote Commands

```bash
ct remote connect <host:port> [--token TOKEN]  # Connect to orchestrator
ct remote disconnect                            # Disconnect
ct remote status                                # Show connection status
ct remote discover                              # Auto-discover orchestrator
```

### Spawn Command

```bash
ct spawn <name> [options]
```

| Option | Description |
|--------|-------------|
| `--template, -t <file>` | Prompt template file |
| `--mode, -m <mode>` | Thread mode (automatic, semi-auto, interactive) |
| `--context, -c <json>` | Thread context as JSON |
| `--worktree, -w` | Create with isolated git worktree (DEFAULT for remote) |
| `--no-worktree` | Disable worktree isolation (not recommended for remote) |
| `--worktree-base <branch>` | Base branch for worktree |
| `--wait` | Wait for thread completion |
| `--remote` | Force use of remote API |
| `--local` | Force use of local database |

### Behavior

- If connected to remote: Uses API automatically with worktree isolation
- If not connected: Uses local database (worktree optional)
- Remote threads ALWAYS use worktrees by default (use `--no-worktree` to disable)
- Use `--remote` or `--local` to force behavior

## Use Cases

### 1. Parallel Epic Implementation

When implementing multiple epics from a BMAD plan:

```bash
# Terminal 1: Orchestrator
ct orchestrator start
ct api start

# Terminal 2: Claude Code session (BMAD orchestrator)
ct remote connect localhost:31337 --token $CT_API_TOKEN

# Spawn parallel epics
ct spawn epic-7a --template bmad-developer.md --worktree --context '{"epic_id":"7A"}'
ct spawn epic-8a --template bmad-developer.md --worktree --context '{"epic_id":"8A"}'
ct spawn epic-9a --template bmad-developer.md --worktree --context '{"epic_id":"9A"}'

# Monitor progress
ct thread list running
```

### 2. CI/Review Fix Helpers

When a PR needs fixes, spawn helper threads:

```bash
# From PR shepherd or manual trigger
ct spawn ci-fix-pr-123 \
    --template bmad-fixer.md \
    --worktree \
    --context '{"pr_number":"123","issue":"test failures"}'
```

### 3. Story Implementation Queue

Process stories from a backlog:

```bash
# Read stories from artifact or input
for story in "$@"; do
    ct spawn "story-$story" \
        --template developer.md \
        --context "{\"story_id\":\"$story\"}"
done
```

### 4. Hybrid Local/Remote

Mix local and remote operations:

```bash
# Create locally, spawn remote helpers
ct thread create main-task --mode automatic
ct spawn helper-1 --remote --template helper.md
ct spawn helper-2 --remote --template helper.md
ct thread start main-task --local
```

## API Reference

The remote client uses the claude-threads REST API.

### Endpoints Used

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/health` | GET | Health check |
| `/api/status` | GET | System status |
| `/api/threads` | GET | List threads |
| `/api/threads` | POST | Create thread |
| `/api/threads/:id` | GET | Get thread |
| `/api/threads/:id/start` | POST | Start thread |
| `/api/threads/:id/stop` | POST | Stop thread |
| `/api/events` | POST | Publish event |

### Authentication

All requests include:
```
Authorization: Bearer <token>
```

### Example: Create and Start Thread

```bash
# Create
curl -X POST http://localhost:31337/api/threads \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"epic-7a","mode":"automatic","template":"bmad-developer.md"}'

# Response: {"id":"thread-abc123","name":"epic-7a","status":"created"}

# Start
curl -X POST http://localhost:31337/api/threads/thread-abc123/start \
  -H "Authorization: Bearer $TOKEN"
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `CT_API_TOKEN` | Authentication token |
| `CT_API_URL` | API URL for auto-discovery |
| `N8N_API_TOKEN` | Alternative token variable |
| `CT_DATA_DIR` | Data directory path |

## Troubleshooting

### Connection Failed

```bash
# Check API server is running
ct api status

# Check token is correct
curl -H "Authorization: Bearer $TOKEN" http://localhost:31337/api/health

# Check firewall/network
nc -zv localhost 31337
```

### Authentication Errors

```bash
# Ensure token matches
echo $CT_API_TOKEN
echo $N8N_API_TOKEN

# Re-connect with explicit token
ct remote connect localhost:31337 --token correct-token
```

### Thread Not Starting

```bash
# Check orchestrator is running
ct orchestrator status

# Check thread status
ct thread status <thread-id>

# Check logs
ct thread logs <thread-id>
```

### Worktree Conflicts

```bash
# List existing worktrees
ct worktree list

# Cleanup orphaned worktrees
ct worktree cleanup

# Force cleanup old worktrees
ct worktree cleanup --force
```

## Best Practices

1. **Use Tokens in Production**
   - Never run API without authentication in production
   - Rotate tokens periodically

2. **Isolate with Worktrees**
   - Always use `--worktree` for parallel implementations
   - Set appropriate `--worktree-base` for feature branches

3. **Monitor Progress**
   - Use `ct thread list running` to track active threads
   - Set up log rotation for long-running orchestrators

4. **Clean Up**
   - Stop threads when done: `ct thread stop <id>`
   - Cleanup worktrees: `ct worktree cleanup`

5. **Context Passing**
   - Pass relevant context via `--context` JSON
   - Include IDs, references, and configuration

## See Also

- [README.md](../README.md) - Getting started
- [PR-SHEPHERD.md](PR-SHEPHERD.md) - Automatic PR fixing
- [MIGRATIONS.md](MIGRATIONS.md) - Database migrations
- [thread-spawner skill](../skills/thread-spawner/SKILL.md) - Claude Code skill
