# Multi-Instance Coordination

claude-threads supports connecting multiple Claude Code instances to a single orchestrator, enabling parallel thread execution and coordination across terminals, machines, or clusters.

## Overview

The multi-instance architecture allows:

- **External Claude Code sessions** to spawn threads on a running orchestrator
- **Parallel execution** of epics, stories, or tasks in isolated worktrees
- **Centralized coordination** through the shared SQLite database
- **Token-based authentication** for secure API access
- **Distributed deployments** across multiple machines
- **Cross-instance agent coordination** via blackboard events

**IMPORTANT**: Remote threads ALWAYS run in isolated git worktrees by default. This is required to prevent conflicts between parallel threads working on the same codebase.

## Deployment Patterns

### Pattern 1: Single Machine (Default)

All instances share the same orchestrator on localhost.

```
┌─────────────────────────────────────────────────────────────────┐
│                         Local Machine                           │
│                                                                 │
│  Terminal 1        Terminal 2        Terminal 3                 │
│  ┌──────────┐      ┌──────────┐      ┌──────────┐              │
│  │Orchestrator│◄───│ Claude   │◄───  │ Claude   │              │
│  │ + API    │      │ Code #1  │      │ Code #2  │              │
│  └────┬─────┘      └──────────┘      └──────────┘              │
│       │                                                         │
│       ▼                                                         │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                Shared .claude-threads/                   │   │
│  │  threads.db  │  worktrees/  │  sessions/  │  events/    │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### Pattern 2: Multi-Machine (Distributed)

Orchestrator runs on a central server, workers on separate machines.

```
┌────────────────────┐     ┌────────────────────┐
│   Central Server   │     │   Worker Machine   │
│  ┌──────────────┐  │     │  ┌──────────────┐  │
│  │ Orchestrator │  │◄────│  │ Claude Code  │  │
│  │    + API     │  │ API │  │   Session    │  │
│  └──────┬───────┘  │     │  └──────────────┘  │
│         │          │     │         │          │
│         ▼          │     │         ▼          │
│  ┌──────────────┐  │     │  ┌──────────────┐  │
│  │   Database   │  │     │  │   Local      │  │
│  │   + State    │  │     │  │   Worktree   │  │
│  └──────────────┘  │     │  └──────────────┘  │
└────────────────────┘     └────────────────────┘
                                    │
                           ┌────────┴────────┐
                           ▼                 ▼
                   ┌──────────────┐  ┌──────────────┐
                   │ Worker 2     │  │ Worker 3     │
                   └──────────────┘  └──────────────┘
```

### Pattern 3: Federated (Multi-Orchestrator)

Multiple orchestrators coordinate through shared events.

```
┌─────────────────────────────────────────────────────────────────┐
│                      Federation Network                          │
│                                                                 │
│  ┌─────────────────┐          ┌─────────────────┐              │
│  │  Orchestrator A │◄────────►│  Orchestrator B │              │
│  │  (Team Alpha)   │  Events  │  (Team Beta)    │              │
│  └────────┬────────┘          └────────┬────────┘              │
│           │                            │                        │
│           ▼                            ▼                        │
│    ┌─────────────┐              ┌─────────────┐                │
│    │ DB + State  │              │ DB + State  │                │
│    │   Local     │              │   Local     │                │
│    └─────────────┘              └─────────────┘                │
│                                                                 │
│                    Shared Event Bus                             │
│         ┌───────────────────────────────────────┐              │
│         │  Redis/NATS/Webhook Bridge            │              │
│         └───────────────────────────────────────┘              │
└─────────────────────────────────────────────────────────────────┘
```

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

**Option A: Using Claude Code slash command (recommended)**

In Claude Code, simply run:
```
/ct-connect
```

Claude will automatically:
1. Check current connection status
2. Try auto-discovery to find the running orchestrator
3. Connect and verify the connection

**Option B: Manual connection**

```bash
# Terminal 2: Connect to orchestrator
export CT_API_TOKEN=my-secret-token
ct remote connect localhost:31337

# Verify connection
ct remote status
```

### 3. Spawn Threads

**Option A: Using Claude Code slash command**

In Claude Code, run:
```
/ct-spawn
```

Then tell Claude what to spawn (e.g., "spawn epic-7a with bmad-developer template").

**Option B: Direct command**

```bash
# Spawn a thread (worktree isolation is automatic for remote)
ct spawn epic-7a --template bmad-developer.md

# Spawn multiple in parallel
ct spawn epic-7a --template bmad-developer.md
ct spawn epic-8a --template bmad-developer.md
ct spawn epic-9a --template bmad-developer.md
```

## Claude Code Slash Commands

| Command | Description |
|---------|-------------|
| `/ct-connect` | Auto-connect to running orchestrator |
| `/ct-spawn` | Spawn threads (connects automatically if needed) |

These commands execute automatically - Claude will run the necessary `ct` commands for you.

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

## Distributed Deployment Guide

### Setting Up Multi-Machine Deployment

#### Central Server Setup

```bash
# 1. Clone repository on central server
git clone <repo-url> /opt/claude-threads
cd /opt/claude-threads

# 2. Initialize database
ct db migrate

# 3. Configure for remote access
cat > config.yaml <<EOF
n8n:
  enabled: true
  api_port: 31337
  api_bind: 0.0.0.0  # Accept remote connections
  api_token: $(openssl rand -hex 32)

orchestrator:
  max_parallel_threads: 20
  cleanup_on_start: true

events:
  ttl_hours: 48
  max_per_thread: 2000
EOF

# 4. Start orchestrator and API
ct orchestrator start --daemonize
ct api start --daemonize

# 5. Note the token for workers
echo "Token: $(grep api_token config.yaml | cut -d: -f2 | tr -d ' ')"
```

#### Worker Machine Setup

```bash
# 1. Clone repository on worker
git clone <repo-url> ~/claude-threads
cd ~/claude-threads

# 2. Configure remote connection
export CT_API_URL=http://central-server:31337
export CT_API_TOKEN=<token-from-central>

# 3. Test connection
ct remote connect central-server:31337

# 4. Verify
ct remote status
```

### Cross-Instance Agent Coordination

When agents on different machines need to coordinate:

#### Event-Based Coordination

```bash
# Agent on Worker A publishes event
ct event publish TASK_COMPLETED '{
  "worker_id": "worker-a",
  "thread_id": "epic-7a",
  "result": "success",
  "output_branch": "feature/epic-7a"
}'

# Agent on Worker B waits for event
ct event wait TASK_COMPLETED --filter '{"worker_id": "worker-a"}' --timeout 600
```

#### Shared Memory Pattern

```bash
# Parent agent stores shared state
ct memory set --category shared \
  --key "project-config" \
  --value '{"feature_flags": {"dark_mode": true}}'

# Child agents on any worker can read
config=$(ct memory get --category shared --key "project-config")
```

#### Worktree Coordination

Workers operate on local worktrees but coordinate through central:

```
Central Server                    Worker A                    Worker B
     │                               │                           │
     │  spawn thread-a               │                           │
     ├──────────────────────────────►│                           │
     │                               │ clone + worktree          │
     │                               │                           │
     │  spawn thread-b                                           │
     ├───────────────────────────────────────────────────────────►
     │                                                           │
     │                               │ commit + push             │
     │◄──────────────────────────────┤                           │
     │  THREAD_COMPLETED             │                           │
     │                                                           │
     │                               │                           │
     │◄──────────────────────────────────────────────────────────┤
     │  THREAD_COMPLETED             │     commit + push         │
```

### High Availability Setup

For production deployments:

#### Database Replication

```yaml
# config.yaml for HA
database:
  primary: /opt/claude-threads/data/threads.db
  replicas:
    - /backup/threads-replica.db
  sync_interval: 60
```

#### Load Balancer Configuration

```nginx
# nginx.conf
upstream claude_threads {
    least_conn;
    server orchestrator1:31337 weight=5;
    server orchestrator2:31337 weight=5 backup;
}

server {
    listen 443 ssl;
    server_name api.claude-threads.local;

    location / {
        proxy_pass http://claude_threads;
        proxy_set_header Authorization $http_authorization;
    }
}
```

#### Health Monitoring

```bash
# Health check script
#!/bin/bash
while true; do
    if ! curl -sf http://localhost:31337/api/health > /dev/null; then
        # Restart orchestrator
        ct orchestrator restart

        # Alert
        ct event publish ORCHESTRATOR_RESTARTED '{
          "host": "'$(hostname)'",
          "reason": "health_check_failed"
        }'
    fi
    sleep 30
done
```

### Federated Orchestrator Setup

When multiple teams need independent orchestrators with coordination:

#### Event Bridge Configuration

```yaml
# config.yaml
federation:
  enabled: true
  node_id: team-alpha
  event_bridge:
    type: webhook  # or redis, nats
    url: https://event-hub.example.com/events
    subscribe_events:
      - PR_MERGED
      - EPIC_COMPLETED
      - ESCALATION_NEEDED
    publish_events:
      - THREAD_COMPLETED
      - PR_READY_FOR_MERGE
```

#### Cross-Orchestrator Communication

```bash
# Team Alpha completes epic, publishes to federation
ct event publish --federated EPIC_COMPLETED '{
  "team": "alpha",
  "epic_id": "7A",
  "branch": "feature/epic-7a",
  "ready_for_integration": true
}'

# Team Beta receives notification (via webhook)
# Their orchestrator can then:
#   1. Pull the branch
#   2. Run integration tests
#   3. Merge to main
```

## Agent Spawn Patterns

### Spawning from External Claude Code

When an external Claude Code instance needs to spawn work:

```bash
# Option 1: Spawn and forget
ct spawn review-pr-123 \
  --template code-reviewer.md \
  --context '{"pr_number": 123}'

# Option 2: Spawn and wait
ct spawn fix-ci-123 \
  --template ci-fixer.md \
  --context '{"pr_number": 123}' \
  --wait

# Option 3: Spawn batch
for pr in 123 124 125; do
  ct spawn "review-pr-$pr" \
    --template code-reviewer.md \
    --context "{\"pr_number\": $pr}" &
done
wait
```

### Agent Hierarchy Control

```bash
# Master orchestrator spawns shepherds
ct spawn pr-shepherd-123 \
  --template pr-lifecycle.md \
  --context '{
    "pr_number": 123,
    "can_spawn_children": true,
    "max_children": 5
  }'

# Shepherd spawns sub-agents (limited)
# Inside shepherd prompt:
ct spawn conflict-fix-123 \
  --template merge-conflict.md \
  --parent "$THREAD_ID"
```

### Rate Limiting

```yaml
# config.yaml
spawn_limits:
  global_max_running: 50
  per_api_client: 10
  per_minute: 30
  queue_overflow: reject  # or queue
```

## See Also

- [README.md](../README.md) - Getting started
- [ARCHITECTURE.md](ARCHITECTURE.md) - System architecture overview
- [AGENT-COORDINATION.md](AGENT-COORDINATION.md) - Agent coordination patterns
- [WORKTREE-GUIDE.md](WORKTREE-GUIDE.md) - Worktree management for agents
- [EVENT-REFERENCE.md](EVENT-REFERENCE.md) - Event types reference
- [PR-SHEPHERD.md](PR-SHEPHERD.md) - Automatic PR fixing
- [MIGRATIONS.md](MIGRATIONS.md) - Database migrations
- [thread-spawner skill](../skills/thread-spawner/SKILL.md) - Claude Code skill
- [/ct-connect command](../commands/ct-connect.md) - Auto-connect slash command
- [/ct-spawn command](../commands/ct-spawn.md) - Spawn slash command
