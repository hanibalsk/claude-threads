---
name: ct-connect
description: Connect to a running claude-threads orchestrator
allowed-tools: Bash,Read
user-invocable: true
---

# Connect to Claude Threads Orchestrator

You are connecting this Claude Code instance to a running claude-threads orchestrator.

## Finding the ct Command

First, find the `ct` command. It's installed in `.claude-threads/bin/ct`:

```bash
# Use local installation
CT_CMD=".claude-threads/bin/ct"
if [[ ! -x "$CT_CMD" ]]; then
    CT_CMD="$(command -v ct 2>/dev/null || echo "")"
fi
if [[ -z "$CT_CMD" ]]; then
    echo "Error: ct command not found. Run the installer first."
    exit 1
fi
echo "Using: $CT_CMD"
$CT_CMD version
```

## Auto-Connect Process

Execute these steps automatically:

### Step 1: Check Current Connection Status

```bash
.claude-threads/bin/ct remote status
```

### Step 2: Try Auto-Discovery

If not connected, try to auto-discover a running orchestrator:

```bash
.claude-threads/bin/ct remote discover
```

### Step 3: Manual Connect (if auto-discovery fails)

If auto-discovery fails, connect manually. The user needs to provide the token:

```bash
# Connect with token from environment
.claude-threads/bin/ct remote connect localhost:31337 --token "$CT_API_TOKEN"
```

### Step 4: Verify Connection

```bash
.claude-threads/bin/ct remote status
```

## After Connection

Once connected, you can spawn threads:

```bash
# Spawn a thread (worktree isolation is automatic)
.claude-threads/bin/ct spawn <name> --template <template.md>

# Example:
.claude-threads/bin/ct spawn epic-7a --template bmad-developer.md
```

## If Orchestrator Not Running

Start the orchestrator first (in another terminal or the main instance):

```bash
# Start orchestrator
.claude-threads/bin/ct orchestrator start

# Start API server
export N8N_API_TOKEN=<token>
.claude-threads/bin/ct api start
```

## Troubleshooting

If connection fails:

```bash
# Check if API is responding
curl -s http://localhost:31337/api/health

# Check orchestrator status
.claude-threads/bin/ct orchestrator status

# Check API status
.claude-threads/bin/ct api status
```
