---
name: ct-connect
description: Connect to a running claude-threads orchestrator
allowed-tools: Bash,Read
user-invocable: true
---

# Connect to Claude Threads Orchestrator

Connect this Claude Code instance to a running claude-threads orchestrator to spawn parallel threads.

## Quick Connect

```bash
# Auto-discover and connect to local orchestrator
ct remote discover

# Or connect with explicit host and token
ct remote connect localhost:31337 --token $CT_API_TOKEN
```

## Setup Steps

### 1. Check if Orchestrator is Running

```bash
# Check orchestrator status
ct orchestrator status

# Check API server status
ct api status
```

### 2. Start Orchestrator (if not running)

```bash
# Start orchestrator daemon
ct orchestrator start

# Start API server with token
export N8N_API_TOKEN=my-secret-token
ct api start
```

### 3. Connect from This Instance

```bash
# Set token
export CT_API_TOKEN=my-secret-token

# Connect
ct remote connect localhost:31337

# Verify connection
ct remote status
```

## Connection Commands

```bash
# Connect to orchestrator
ct remote connect <host:port> [--token TOKEN]

# Disconnect
ct remote disconnect

# Check connection status
ct remote status

# Auto-discover running orchestrator
ct remote discover
```

## Spawn Threads (After Connected)

Once connected, spawn threads that run in isolated worktrees:

```bash
# Spawn with template
ct spawn epic-7a --template bmad-developer.md

# Spawn with custom base branch
ct spawn feature-123 --template developer.md --worktree-base develop

# Spawn with context
ct spawn story-42 --template developer.md --context '{"story_id":"42"}'

# Spawn and wait for completion
ct spawn fix-task --template fixer.md --wait
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `CT_API_TOKEN` | Authentication token for API |
| `CT_API_URL` | API URL for auto-discovery |
| `N8N_API_TOKEN` | Alternative token variable |

## Troubleshooting

### Connection Failed

```bash
# Check if API is running
ct api status

# Test API endpoint
curl http://localhost:31337/api/health

# Check token
echo $CT_API_TOKEN
```

### Already Connected

```bash
# Check current connection
ct remote status

# Disconnect and reconnect
ct remote disconnect
ct remote connect localhost:31337 --token $CT_API_TOKEN
```

## See Also

- `/threads` - Full thread management
- `/ct-spawn` - Spawn threads directly
