# Event Reference

Complete reference for all blackboard events in claude-threads.

## Event Structure

All events follow this structure:

```json
{
  "id": "evt-{uuid}",
  "type": "{EVENT_TYPE}",
  "source_thread_id": "{thread-id}",
  "target_thread_ids": ["{thread-id}", ...],
  "data": { ... },
  "created_at": "2024-01-15T10:00:00Z"
}
```

## Event Categories

### Thread Lifecycle Events

| Event Type | Publisher | Description |
|------------|-----------|-------------|
| `THREAD_CREATED` | Orchestrator | Thread record created |
| `THREAD_STARTED` | Orchestrator | Thread execution began |
| `THREAD_COMPLETED` | Thread/Orchestrator | Thread finished successfully |
| `THREAD_FAILED` | Thread/Orchestrator | Thread encountered fatal error |
| `THREAD_STOPPED` | Orchestrator | Thread manually stopped |
| `THREAD_BLOCKED` | Thread | Thread needs intervention |
| `THREAD_RESUMED` | Orchestrator | Blocked thread resumed |

**THREAD_STARTED:**
```json
{
  "type": "THREAD_STARTED",
  "data": {
    "thread_id": "thread-abc123",
    "name": "epic-7a",
    "mode": "automatic",
    "worktree_path": "/path/to/worktree",
    "template": "developer.md"
  }
}
```

**THREAD_COMPLETED:**
```json
{
  "type": "THREAD_COMPLETED",
  "data": {
    "thread_id": "thread-abc123",
    "result": "success",
    "output": { ... },
    "duration_seconds": 3600
  }
}
```

**THREAD_FAILED:**
```json
{
  "type": "THREAD_FAILED",
  "data": {
    "thread_id": "thread-abc123",
    "error": "Build failed",
    "error_type": "build_error",
    "recoverable": false,
    "context": { ... }
  }
}
```

### PR Lifecycle Events

| Event Type | Publisher | Description |
|------------|-----------|-------------|
| `PR_WATCH_STARTED` | PR Shepherd | Started watching a PR |
| `PR_STATUS_CHANGED` | PR Shepherd | PR status changed |
| `PR_READY_FOR_MERGE` | PR Shepherd | All criteria met |
| `PR_MERGED` | PR Shepherd | PR was merged |
| `PR_CLOSED` | PR Shepherd | PR was closed without merge |

**PR_STATUS_CHANGED:**
```json
{
  "type": "PR_STATUS_CHANGED",
  "data": {
    "pr_number": 123,
    "from_status": "pending_review",
    "to_status": "approved",
    "ci_passing": true,
    "has_conflicts": false,
    "pending_comments": 0
  }
}
```

**PR_READY_FOR_MERGE:**
```json
{
  "type": "PR_READY_FOR_MERGE",
  "data": {
    "pr_number": 123,
    "criteria_met": {
      "ci_passing": true,
      "no_conflicts": true,
      "comments_resolved": true,
      "approved": true
    }
  }
}
```

### Merge Conflict Events

| Event Type | Publisher | Description |
|------------|-----------|-------------|
| `CONFLICT_DETECTED` | PR Shepherd | Merge conflict found |
| `CONFLICT_RESOLUTION_STARTED` | Conflict Resolver | Starting resolution |
| `CONFLICT_RESOLVED` | Conflict Resolver | Conflict fixed |
| `CONFLICT_RESOLUTION_FAILED` | Conflict Resolver | Could not resolve |

**CONFLICT_DETECTED:**
```json
{
  "type": "CONFLICT_DETECTED",
  "data": {
    "pr_number": 123,
    "target_branch": "main",
    "conflicting_files": [
      "src/app.ts",
      "package.json"
    ],
    "conflict_type": "auto"
  }
}
```

**CONFLICT_RESOLVED:**
```json
{
  "type": "CONFLICT_RESOLVED",
  "data": {
    "pr_number": 123,
    "resolver_thread_id": "conflict-resolver-123",
    "resolution_strategy": "merge_both",
    "files_resolved": ["src/app.ts", "package.json"],
    "commit_sha": "abc123"
  }
}
```

### Review Comment Events

| Event Type | Publisher | Description |
|------------|-----------|-------------|
| `COMMENT_PENDING` | PR Shepherd | New comment needs handling |
| `COMMENT_HANDLER_STARTED` | Comment Handler | Started handling comment |
| `COMMENT_RESPONDED` | Comment Handler | Reply posted |
| `COMMENT_RESOLVED` | Comment Handler | Thread marked resolved |
| `COMMENT_DISMISSED` | PR Shepherd | Comment no longer relevant |

**COMMENT_PENDING:**
```json
{
  "type": "COMMENT_PENDING",
  "data": {
    "pr_number": 123,
    "comment_id": "456",
    "github_thread_id": "RT_789",
    "path": "src/app.ts",
    "line": 42,
    "author": "reviewer",
    "body": "Consider using a constant here"
  }
}
```

**COMMENT_RESPONDED:**
```json
{
  "type": "COMMENT_RESPONDED",
  "data": {
    "pr_number": 123,
    "comment_id": "456",
    "handler_thread_id": "comment-handler-456",
    "response": "Good point! I've extracted this to a constant.",
    "code_changed": true,
    "commit_sha": "def456"
  }
}
```

### CI/Build Events

| Event Type | Publisher | Description |
|------------|-----------|-------------|
| `CI_FAILED` | PR Shepherd | CI check failed |
| `CI_FIX_STARTED` | CI Fixer | Started fixing CI |
| `CI_FIX_COMPLETED` | CI Fixer | CI fix applied |
| `CI_FIX_FAILED` | CI Fixer | Could not fix CI |
| `CI_PASSING` | PR Shepherd | All CI checks green |

**CI_FAILED:**
```json
{
  "type": "CI_FAILED",
  "data": {
    "pr_number": 123,
    "check_name": "tests",
    "failure_type": "test_failure",
    "logs_url": "https://...",
    "failing_tests": [
      "test_user_login",
      "test_user_logout"
    ]
  }
}
```

### Worktree Events

| Event Type | Publisher | Description |
|------------|-----------|-------------|
| `WORKTREE_BASE_CREATED` | Git Manager | PR base worktree created |
| `WORKTREE_FORK_CREATED` | Git Manager | Fork created from base |
| `WORKTREE_FORK_MERGED` | Git Manager | Fork merged back |
| `WORKTREE_MERGE_CONFLICT` | Git Manager | Conflict during merge-back |
| `WORKTREE_PUSH_FAILED` | Git Manager | Push to remote failed |
| `WORKTREE_FORK_REMOVED` | Git Manager | Fork worktree cleaned up |
| `WORKTREE_BASE_REMOVED` | Git Manager | Base worktree removed |

**WORKTREE_FORK_CREATED:**
```json
{
  "type": "WORKTREE_FORK_CREATED",
  "data": {
    "pr_number": 123,
    "fork_id": "conflict-resolver-123",
    "purpose": "conflict_resolution",
    "base_commit": "abc123",
    "path": "/path/to/fork"
  }
}
```

**WORKTREE_FORK_MERGED:**
```json
{
  "type": "WORKTREE_FORK_MERGED",
  "data": {
    "fork_id": "conflict-resolver-123",
    "pr_number": 123,
    "pushed": true,
    "merge_commit": "def456"
  }
}
```

### Session Events

| Event Type | Publisher | Description |
|------------|-----------|-------------|
| `SESSION_STARTED` | Session Manager | New session began |
| `SESSION_FORKED` | Session Manager | Session forked for child |
| `CHECKPOINT_CREATED` | Any Agent | State checkpoint saved |
| `CONTEXT_COMPACTION_PENDING` | Agent | Approaching context limit |
| `SESSION_RESUMED` | Session Manager | Session restored |

**CHECKPOINT_CREATED:**
```json
{
  "type": "CHECKPOINT_CREATED",
  "data": {
    "thread_id": "thread-abc123",
    "session_id": "sess-xyz789",
    "checkpoint_type": "periodic",
    "state_summary": "Processing PR #123, 3 comments resolved",
    "pending_tasks": [
      {"task": "resolve_comment_456", "priority": 8}
    ],
    "memories_stored": 5
  }
}
```

### Orchestrator Events

| Event Type | Publisher | Description |
|------------|-----------|-------------|
| `ORCHESTRATOR_STARTED` | Orchestrator | Daemon started |
| `ORCHESTRATOR_STOPPED` | Orchestrator | Daemon stopping |
| `SHEPHERD_SPAWNED` | Orchestrator | PR shepherd created |
| `SYSTEM_STATUS` | Orchestrator | Periodic status report |
| `ESCALATION_HANDLED` | Orchestrator | Escalation resolved |

**SYSTEM_STATUS:**
```json
{
  "type": "SYSTEM_STATUS",
  "data": {
    "orchestrator_id": "orch-main",
    "threads_running": 5,
    "threads_blocked": 1,
    "prs_watching": 3,
    "events_pending": 12,
    "uptime_seconds": 3600
  }
}
```

### Escalation Events

| Event Type | Publisher | Description |
|------------|-----------|-------------|
| `ESCALATION_NEEDED` | Any Agent | Human intervention required |
| `ESCALATION_ACKNOWLEDGED` | Orchestrator | Escalation seen |
| `ESCALATION_RESOLVED` | Human/Orchestrator | Issue resolved |

**ESCALATION_NEEDED:**
```json
{
  "type": "ESCALATION_NEEDED",
  "data": {
    "thread_id": "conflict-resolver-123",
    "pr_number": 123,
    "reason": "Complex merge conflict requires human review",
    "severity": "high",
    "context": {
      "files": ["src/core.ts"],
      "conflict_markers": 15,
      "attempts": 3
    },
    "suggested_actions": [
      "Review conflict in src/core.ts",
      "Consider reverting feature-x changes"
    ]
  }
}
```

## Event Usage

### Publishing Events

```bash
# From shell
ct event publish EVENT_TYPE '{"key": "value"}'

# From agent prompt (conceptual)
bb_publish "EVENT_TYPE" '{"key": "value"}' "$THREAD_ID"
```

### Consuming Events

```bash
# Poll for events
ct event list --type EVENT_TYPE --limit 10

# Wait for specific event
ct event wait EVENT_TYPE --timeout 300

# Watch events in real-time
ct event watch --types "COMPLETED,FAILED"
```

### Event Filtering

```bash
# By type
ct event list --type THREAD_COMPLETED

# By source
ct event list --source thread-abc123

# By time range
ct event list --since "1 hour ago"

# Combined
ct event list --type CONFLICT --source pr-shepherd-123 --limit 5
```

## Event Retention

| Setting | Default | Description |
|---------|---------|-------------|
| TTL | 24 hours | Events older than this are cleaned up |
| Max per thread | 1000 | Oldest events removed when exceeded |
| Cleanup interval | 1 hour | How often cleanup runs |

Configure in `config.yaml`:
```yaml
events:
  ttl_hours: 24
  max_per_thread: 1000
  cleanup_interval_minutes: 60
```

## Event Best Practices

### 1. Include Context

```json
{
  "type": "FIX_COMPLETED",
  "data": {
    "what": "Type error in user.ts",
    "how": "Added missing null check",
    "commit": "abc123",
    "duration_ms": 45000
  }
}
```

### 2. Use Standard Fields

Always include when relevant:
- `thread_id` - Source thread
- `pr_number` - Related PR
- `commit_sha` - Git commit
- `error` - Error message (for failures)

### 3. Be Idempotent

Events may be delivered multiple times. Consumers should handle duplicates:
```bash
# Check if already processed
if already_handled "$event_id"; then
  continue
fi
```

### 4. Naming Convention

```
{COMPONENT}_{ACTION}[_{STATUS}]

Examples:
  THREAD_STARTED
  PR_STATUS_CHANGED
  CONFLICT_RESOLUTION_FAILED
  WORKTREE_FORK_CREATED
```

## See Also

- [AGENT-COORDINATION.md](AGENT-COORDINATION.md) - Using events for coordination
- [lib/blackboard.sh](../lib/blackboard.sh) - Event system implementation
- [ARCHITECTURE.md](ARCHITECTURE.md) - System architecture
