---
name: ct-connect
description: Connect to a running claude-threads orchestrator
allowed-tools: Bash,Read
user-invocable: true
---

# Connect to Claude Threads Orchestrator

You are connecting this Claude Code instance to a running claude-threads orchestrator.

## Auto-Connect Process

Execute these steps automatically:

### Step 1: Check Current Connection Status

```bash
ct remote status
```

### Step 2: Try Auto-Discovery

If not connected, try to auto-discover a running orchestrator:

```bash
ct remote discover
```

### Step 3: Manual Connect (if auto-discovery fails)

If auto-discovery fails, connect manually. The user needs to provide the token:

```bash
# Connect with token from environment
ct remote connect localhost:31337 --token "$CT_API_TOKEN"
```

### Step 4: Verify Connection

```bash
ct remote status
```

## After Connection

Once connected, you can spawn threads:

```bash
# Spawn a thread (worktree isolation is automatic)
ct spawn <name> --template <template.md>

# Example:
ct spawn epic-7a --template bmad-developer.md
```

## If Orchestrator Not Running

Start the orchestrator first (in another terminal or the main instance):

```bash
# Start orchestrator
ct orchestrator start

# Start API server
export N8N_API_TOKEN=<token>
ct api start
```

## Troubleshooting

If connection fails:

```bash
# Check if API is responding
curl -s http://localhost:31337/api/health

# Check orchestrator status
ct orchestrator status

# Check API status
ct api status
```
