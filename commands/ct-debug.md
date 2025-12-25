---
name: ct-debug
description: Debug and troubleshoot claude-threads issues
allowed-tools: Bash,Read,Grep,Glob
user-invocable: true
---

# Claude Threads Debug

You are diagnosing issues with claude-threads. Run these diagnostics to identify problems.

## Quick Health Check

Run all of these to get a quick overview:

```bash
# System status
echo "=== Orchestrator Status ==="
ct orchestrator status 2>&1

echo -e "\n=== API Status ==="
ct api status 2>&1

echo -e "\n=== Thread Summary ==="
ct thread list --all 2>&1 | head -20

echo -e "\n=== Worktree Summary ==="
ct worktree list 2>&1 | head -20

echo -e "\n=== Recent Events ==="
ct event list --limit 10 2>&1

echo -e "\n=== Database Check ==="
sqlite3 .claude-threads/threads.db "PRAGMA integrity_check;" 2>&1

echo -e "\n=== Worktree Consistency ==="
ct worktree reconcile 2>&1
```

## Specific Diagnostics

Based on the issue, run the appropriate section:

### Thread Issues

```bash
# List threads by status
ct thread list blocked
ct thread list running
ct thread list failed

# Check specific thread
ct thread status <thread-id> --verbose
ct thread logs <thread-id> --tail 100

# Check if thread process is running
ps aux | grep <thread-id>
```

### Orchestrator Issues

```bash
# Check orchestrator
ct orchestrator status
ps aux | grep orchestrator

# Check for stale lock
ls -la .claude-threads/orchestrator.lock

# View orchestrator logs
tail -100 .claude-threads/logs/orchestrator.log

# Remove stale lock if needed
# rm -f .claude-threads/orchestrator.lock
```

### Worktree Issues

```bash
# List all worktrees
ct worktree list
git worktree list

# Check consistency
ct worktree reconcile

# Fix orphaned worktrees
# ct worktree reconcile --fix

# Check base worktrees
ct worktree base-status <pr-number>

# Check forks
ct worktree list-forks <pr-number>
```

### Event Issues

```bash
# Recent events
ct event list --limit 50

# Failed events
ct event list --type THREAD_FAILED --limit 20

# Escalations
ct event list --type ESCALATION_NEEDED --limit 20

# Events from specific source
ct event list --source <thread-id> --limit 20
```

### Database Issues

```bash
# Integrity check
sqlite3 .claude-threads/threads.db "PRAGMA integrity_check;"

# Schema version
sqlite3 .claude-threads/threads.db "SELECT * FROM schema_migrations ORDER BY version DESC LIMIT 5;"

# Record counts
sqlite3 .claude-threads/threads.db "
SELECT 'threads', COUNT(*) FROM threads
UNION ALL SELECT 'events', COUNT(*) FROM events
UNION ALL SELECT 'pr_watches', COUNT(*) FROM pr_watches;
"

# Failed threads
sqlite3 .claude-threads/threads.db "
SELECT id, name, status, error_message
FROM threads WHERE status = 'failed'
ORDER BY updated_at DESC LIMIT 10;
"
```

### API Issues

```bash
# Health check
curl -s http://localhost:31337/api/health | jq .

# Check port
lsof -i :31337

# Test with auth
curl -s -H "Authorization: Bearer $CT_API_TOKEN" \
  http://localhost:31337/api/status | jq .
```

## Common Fixes

### Fix: Stale Orchestrator Lock

```bash
rm -f .claude-threads/orchestrator.lock
ct orchestrator start
```

### Fix: Stuck Thread

```bash
ct thread stop <thread-id> --force
ct thread start <thread-id>
```

### Fix: Orphaned Worktrees

```bash
ct worktree reconcile --fix
```

### Fix: Database Locked

```bash
ct orchestrator stop
sleep 5
ct orchestrator start
```

### Fix: Remote Connection Failed

```bash
ct remote disconnect
ct remote connect localhost:31337 --token $CT_API_TOKEN
```

## See Also

- `/threads` - Thread management
- [ct-debug skill](../skills/ct-debug/SKILL.md) - Full debug reference
- [ARCHITECTURE.md](../docs/ARCHITECTURE.md) - System architecture
