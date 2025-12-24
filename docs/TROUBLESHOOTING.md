# Troubleshooting Guide

Common issues and solutions for claude-threads.

## Installation Issues

### "ct: command not found"

The `ct` command is not in your PATH.

**Solution:**
```bash
# Add to PATH (add to your shell rc file)
export PATH="$HOME/.claude-threads/bin:$PATH"

# Or reinstall
curl -fsSL https://raw.githubusercontent.com/hanibalsk/claude-threads/main/install.sh | bash
```

### "Error: claude-threads not found. Run 'ct init' first."

The current directory doesn't have claude-threads initialized.

**Solution:**
```bash
ct init
```

## Thread Issues

### Thread Stuck in "running" Status

The thread process may have crashed or been killed.

**Solutions:**
```bash
# Check if process is actually running
ct thread status <thread-id>

# Force stop the thread
ct thread stop <thread-id>

# If still stuck, check for orphaned PID file
ls -la .claude-threads/tmp/thread-*.pid

# Remove orphaned PID file
rm .claude-threads/tmp/thread-<id>.pid

# Update status in database
ct thread delete <thread-id>
```

### "Thread has no session to resume"

The thread was created but never started, or the session was lost.

**Solution:**
```bash
# Restart the thread
ct thread start <thread-id>
```

### Thread Logs Empty

The thread may not have produced output yet, or logs were rotated.

**Solutions:**
```bash
# Check if thread is running
ct thread status <thread-id>

# View raw log files
ls -la .claude-threads/logs/thread-*.log

# Check Claude output file
cat .claude-threads/tmp/thread-<id>-output.txt
```

## Worktree Issues

### "fatal: worktree already exists"

A worktree with the same name already exists.

**Solutions:**
```bash
# List existing worktrees
ct worktree list
git worktree list

# Remove the old worktree
git worktree remove .claude-threads/worktrees/<name>

# Or cleanup all orphaned worktrees
ct worktree cleanup --force
```

### "Cannot create worktree: branch already checked out"

The branch is already checked out in another worktree.

**Solutions:**
```bash
# Use a different branch name
ct thread create my-task --worktree --worktree-branch my-task-v2

# Or remove the conflicting worktree
git worktree remove <path-to-worktree>
```

### Worktree Changes Not Visible

Each worktree has its own working directory.

**Solution:**
```bash
# Navigate to the worktree directory
cd .claude-threads/worktrees/<thread-name>

# Check git status there
git status
git log
```

## Orchestrator Issues

### "Orchestrator script not found"

The scripts weren't copied during initialization.

**Solution:**
```bash
# Re-initialize (preserves existing data)
ct init

# Verify scripts exist
ls -la .claude-threads/scripts/
```

### Orchestrator Not Starting

Check for existing instances or port conflicts.

**Solutions:**
```bash
# Check if already running
ct orchestrator status

# Check for zombie processes
ps aux | grep orchestrator

# Kill orphaned processes
pkill -f orchestrator.sh

# Restart
ct orchestrator start
```

### Threads Not Being Processed

The orchestrator might not be running or events aren't being published.

**Solutions:**
```bash
# Verify orchestrator is running
ct orchestrator status

# Check event history
ct event list

# Manually trigger a tick
ct orchestrator tick
```

## API/Remote Connection Issues

### "Connection refused" on ct remote connect

The API server isn't running.

**Solution:**
```bash
# Start the API server
ct api start

# Verify it's running
ct api status
curl http://localhost:31337/api/health
```

### "401 Unauthorized"

Authentication token mismatch.

**Solutions:**
```bash
# Verify tokens match
echo $N8N_API_TOKEN   # Server side
echo $CT_API_TOKEN    # Client side

# Reconnect with correct token
ct remote connect localhost:31337 --token <correct-token>
```

### "No running orchestrator found" on ct remote discover

Auto-discovery failed.

**Solutions:**
```bash
# Check API server is running
ct api status

# Check network connectivity
nc -zv localhost 31337

# Connect manually
ct remote connect localhost:31337 --token $CT_API_TOKEN
```

## Database Issues

### "database is locked"

Multiple processes trying to access the database.

**Solutions:**
```bash
# Wait for other operations to complete

# Check for locked processes
fuser .claude-threads/threads.db

# If stuck, stop all threads and orchestrator
ct orchestrator stop
ct thread list running | while read id; do ct thread stop "$id"; done
```

### "no such table: threads"

Database schema not initialized.

**Solution:**
```bash
# Re-run migrations
ct migrate --up

# Or reinitialize (creates fresh database)
rm .claude-threads/threads.db
ct init
```

### Migration Issues

```bash
# Check migration status
ct migrate --status

# Run pending migrations
ct migrate --up

# Rollback if needed
ct migrate --down
```

## PR Shepherd Issues

### PR Not Being Watched

Check if the shepherd daemon is running.

**Solutions:**
```bash
# Check shepherd status
ct pr status

# Start the daemon
ct pr daemon

# Or manually start watching
ct pr watch <pr-number>
```

### CI Fixes Not Being Applied

Shepherd might have reached max attempts or there's a configuration issue.

**Solutions:**
```bash
# Check PR status
ct pr status <pr-number>

# Check config
ct config show | grep pr_shepherd

# Restart watching
ct pr stop <pr-number>
ct pr watch <pr-number>
```

## Configuration Issues

### Config Changes Not Taking Effect

Configuration is loaded at startup.

**Solution:**
```bash
# Restart services after config changes
ct orchestrator restart
ct api stop && ct api start
```

### Finding Config File

```bash
# Show current config
ct config show

# Edit config
ct config edit

# Config location
ls -la .claude-threads/config.yaml
```

## Getting More Help

### Enable Debug Output

```bash
export CT_DEBUG=1
ct thread list
```

### Check Log Files

```bash
# View orchestrator logs
tail -f .claude-threads/logs/orchestrator.log

# View thread-specific logs
tail -f .claude-threads/logs/thread-*.log

# View API server logs
tail -f .claude-threads/logs/api.log
```

### Report Issues

If you encounter a bug:

1. Gather information:
   ```bash
   ct version
   ct orchestrator status
   ct thread list
   ```

2. Check logs for errors

3. Report at: https://github.com/hanibalsk/claude-threads/issues
