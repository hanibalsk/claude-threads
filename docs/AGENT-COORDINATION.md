# Agent Coordination Guide

This guide covers multi-agent coordination patterns, communication protocols, and best practices for building agent workflows in claude-threads.

## Overview

claude-threads agents communicate through:
1. **Blackboard Events** - Async pub/sub messaging
2. **Shared Database** - Persistent state storage
3. **Session Memory** - Cross-session context
4. **Worktree Coordination** - Isolated file operations

## Agent Communication Protocol

### Event-Based Communication

Agents communicate asynchronously via the blackboard:

```
┌─────────────────┐                           ┌─────────────────┐
│  Parent Agent   │                           │  Child Agent    │
│                 │                           │                 │
│  bb_publish()   │──────Event Queue─────────►│  bb_poll()      │
│                 │                           │                 │
│  bb_wait_for()  │◄─────Event Queue──────────│  bb_publish()   │
│                 │                           │                 │
└─────────────────┘                           └─────────────────┘
```

### Event Format

```json
{
  "id": "evt-123abc",
  "type": "TASK_COMPLETED",
  "source_thread_id": "child-thread-id",
  "target_thread_ids": ["parent-thread-id"],
  "data": {
    "result": "success",
    "output": { ... }
  },
  "created_at": "2024-01-15T10:00:00Z"
}
```

### Core Event Types

| Event Type | Publisher | Consumer | Purpose |
|------------|-----------|----------|---------|
| `THREAD_STARTED` | Orchestrator | Parent | Thread began execution |
| `THREAD_COMPLETED` | Thread | Parent/Orchestrator | Thread finished |
| `THREAD_FAILED` | Thread | Parent/Orchestrator | Thread encountered error |
| `THREAD_BLOCKED` | Thread | Orchestrator | Needs intervention |
| `ESCALATION_NEEDED` | Any agent | Orchestrator | Human required |
| `CHECKPOINT_CREATED` | Any agent | Session Manager | State saved |

## Spawning Child Agents

### From Prompt Templates

```bash
# In an agent's prompt, spawn a child agent:
ct spawn conflict-resolver-{{pr_number}} \
  --template merge-conflict.md \
  --context '{
    "pr_number": {{pr_number}},
    "conflicting_files": ["src/app.ts"],
    "parent_thread_id": "$THREAD_ID"
  }'
```

### With Worktree Fork

```bash
# Fork from PR base for isolated work
FORK_PATH=$(ct worktree fork {{pr_number}} resolver-123 fix/conflict)

ct spawn resolver-123 \
  --template merge-conflict.md \
  --context "{\"worktree_path\": \"$FORK_PATH\"}"
```

### Waiting for Completion

```bash
# Publish start event
ct event publish RESOLVER_STARTED '{"pr_number": 123}'

# Wait for completion (blocks until event received)
ct event wait RESOLVER_COMPLETED --timeout 300

# Or poll periodically
while true; do
  status=$(ct thread status resolver-123 --json | jq -r '.status')
  if [[ "$status" == "completed" ]]; then
    break
  fi
  sleep 30
done
```

## Coordination Patterns

### 1. Sequential Chain

One agent completes before the next starts.

```
┌─────────┐     ┌─────────┐     ┌─────────┐     ┌─────────┐
│ Agent A │────►│ Agent B │────►│ Agent C │────►│ Done    │
└─────────┘     └─────────┘     └─────────┘     └─────────┘
```

**Implementation:**

```bash
# Agent A spawns B on completion
ct spawn agent-b --context '{"input": "result-from-a"}'
ct event publish AGENT_A_COMPLETED

# Agent B waits for A, then spawns C
ct event wait AGENT_A_COMPLETED
# ... do work ...
ct spawn agent-c --context '{"input": "result-from-b"}'
```

### 2. Parallel Fan-Out

Multiple agents work simultaneously.

```
              ┌─────────┐
              │ Agent A │
         ┌────┴─────────┴────┐
         │    │    │    │    │
         ▼    ▼    ▼    ▼    ▼
       ┌───┐┌───┐┌───┐┌───┐┌───┐
       │ 1 ││ 2 ││ 3 ││ 4 ││ 5 │
       └───┘└───┘└───┘└───┘└───┘
```

**Implementation:**

```bash
# Orchestrator spawns all in parallel
for i in 1 2 3 4 5; do
  ct spawn worker-$i \
    --template worker.md \
    --context "{\"task_id\": $i, \"parent\": \"$THREAD_ID\"}"
done

# Wait for all completions
for i in 1 2 3 4 5; do
  ct event wait WORKER_${i}_COMPLETED --timeout 600
done
```

### 3. Fan-Out / Fan-In (Map-Reduce)

Parallel work with aggregation.

```
              ┌─────────┐
              │ Mapper  │
         ┌────┴─────────┴────┐
         ▼    ▼    ▼    ▼    ▼
       ┌───┐┌───┐┌───┐┌───┐┌───┐
       │ 1 ││ 2 ││ 3 ││ 4 ││ 5 │  (parallel workers)
       └─┬─┘└─┬─┘└─┬─┘└─┬─┘└─┬─┘
         │    │    │    │    │
         └────┴────┼────┴────┘
                   ▼
              ┌─────────┐
              │ Reducer │  (aggregator)
              └─────────┘
```

**Implementation:**

```bash
# Mapper spawns workers
RESULTS=()
for i in 1 2 3 4 5; do
  ct spawn worker-$i --template worker.md
done

# Reducer collects results
for i in 1 2 3 4 5; do
  result=$(ct event wait WORKER_${i}_RESULT | jq -r '.data.result')
  RESULTS+=("$result")
done

# Aggregate
aggregate "${RESULTS[@]}"
```

### 4. Pipeline with Backpressure

Work flows through stages with rate limiting.

```
┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐
│ Stage 1 │═══►│ Stage 2 │═══►│ Stage 3 │═══►│ Stage 4 │
│ (3 max) │    │ (2 max) │    │ (1 max) │    │         │
└─────────┘    └─────────┘    └─────────┘    └─────────┘
```

**Implementation:**

```bash
# Use database for queue management
function acquire_slot() {
  local stage=$1
  local max=$2

  while true; do
    current=$(ct thread list running --stage $stage | wc -l)
    if [[ $current -lt $max ]]; then
      return 0
    fi
    sleep 5
  done
}

acquire_slot "stage-2" 2
ct spawn stage-2-worker --template stage2.md
```

### 5. PR Lifecycle Coordination

Specialized pattern for PR management.

```
┌─────────────────────────────────────────────────────────────────┐
│                    PR Shepherd (Long-Running)                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Poll Loop:                                                     │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ while PR not merged:                                     │   │
│  │   1. Check PR status (CI, conflicts, comments)           │   │
│  │   2. If conflict → spawn Conflict Resolver               │   │
│  │   3. If comment  → spawn Comment Handler                 │   │
│  │   4. Wait for sub-agents or timeout                      │   │
│  │   5. Merge back results                                  │   │
│  │   6. Sleep poll_interval                                 │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  Sub-Agent Coordination:                                        │
│                                                                 │
│  PR Shepherd          Conflict Resolver       Comment Handler   │
│       │                      │                      │           │
│       │   Fork worktree      │                      │           │
│       ├─────────────────────►│                      │           │
│       │                      │  Resolve conflict    │           │
│       │                      │                      │           │
│       │◄──CONFLICT_RESOLVED──│                      │           │
│       │   Merge back fork    │                      │           │
│       │                      │                      │           │
│       │   Fork worktree                             │           │
│       ├─────────────────────────────────────────────►           │
│       │                                             │  Fix code │
│       │                                             │  Reply    │
│       │◄──────────────COMMENT_RESPONDED─────────────│           │
│       │   Merge back fork                                       │
│       │                                                         │
└───────┴─────────────────────────────────────────────────────────┘
```

## Session and Memory Coordination

### Sharing Context Between Agents

```bash
# Parent stores context for children
ct memory set --category context \
  --key "pr_123_strategy" \
  --value "Use feature flags for backward compatibility"

# Child reads parent's context
strategy=$(ct memory get --category context --key "pr_123_strategy")
```

### Session Coordination

```bash
# Register with orchestrator
ct session coordinate --register \
  --orchestrator-session $ORCHESTRATOR_SESSION_ID \
  --agent-thread $THREAD_ID

# Periodic checkpoints
ct session checkpoint --type coordination \
  --state-summary "Processing file 3 of 10" \
  --pending-tasks '[{"task": "validate", "priority": 8}]'

# Update shared context
ct session coordinate --update-context \
  --shared-context '{"files_processed": 3, "errors": 0}'
```

## Worktree Coordination for Agents

### Base Worktree Pattern

```
PR #123 Workflow:

1. PR Shepherd creates base
   ct worktree base-create 123 feature/my-pr main

2. Conflict Resolver forks from base
   ct worktree fork 123 conflict-fix fix/conflict conflict_resolution

3. Comment Handler forks from base
   ct worktree fork 123 comment-fix fix/comment comment_handler

4. After work, merge back
   ct worktree merge-back conflict-fix
   ct worktree remove-fork conflict-fix

5. Base pushes to remote
   cd $(ct worktree base-path 123)
   git push
```

### Concurrent Fork Safety

```
Base Worktree (pr-123-base)
        │
        ├───► Fork 1 (conflict-fix)     ← Conflict Resolver
        │     └── Branch: fix/conflict-123
        │
        ├───► Fork 2 (comment-fix-456)  ← Comment Handler
        │     └── Branch: fix/comment-456
        │
        └───► Fork 3 (ci-fix)           ← CI Fixer
              └── Branch: fix/ci-123

Each fork:
- Has own branch (no conflicts)
- Shares git objects with base (memory efficient)
- Merges back independently
- Cleaned up after merge
```

## Error Handling and Escalation

### Escalation Chain

```
Agent Error
     │
     ├─► Retry (if transient)
     │
     ├─► Escalate to Parent Agent
     │         │
     │         ├─► Parent handles
     │         │
     │         └─► Escalate to Orchestrator
     │                    │
     │                    ├─► Orchestrator handles
     │                    │
     │                    └─► Escalate to Human
     │                              │
     │                              └─► ESCALATION_NEEDED event
     │
     └─► Mark as BLOCKED (wait for intervention)
```

### Escalation Event

```bash
# Agent publishes when stuck
ct event publish ESCALATION_NEEDED '{
  "thread_id": "'$THREAD_ID'",
  "reason": "Merge conflict requires human review",
  "context": {
    "pr_number": 123,
    "files": ["src/core.ts"],
    "attempts": 3
  }
}'
```

### Timeout Handling

```bash
# Set timeout for child agent
ct spawn child-agent --timeout 600  # 10 minutes

# Handle timeout in parent
if ! ct event wait CHILD_COMPLETED --timeout 600; then
  # Timeout - check status
  status=$(ct thread status child-agent --json | jq -r '.status')

  if [[ "$status" == "running" ]]; then
    # Still running - extend or kill
    ct thread stop child-agent
    ct event publish CHILD_TIMEOUT
  fi
fi
```

## Best Practices

### 1. Event Naming Convention

```
{COMPONENT}_{ACTION}_{STATUS}

Examples:
  PR_FIX_STARTED
  PR_FIX_COMPLETED
  CONFLICT_RESOLUTION_FAILED
  COMMENT_RESPONSE_BLOCKED
```

### 2. Context Passing

```bash
# Always include parent reference
--context '{
  "parent_thread_id": "'$THREAD_ID'",
  "parent_session_id": "'$SESSION_ID'",
  "task_context": { ... }
}'
```

### 3. Cleanup Responsibility

| Resource | Creator Cleans | Notes |
|----------|----------------|-------|
| Thread | Orchestrator | After completion/failure |
| Fork Worktree | Parent Agent | After merge-back |
| Base Worktree | PR Shepherd | After PR merge/close |
| Events | TTL/Cleanup job | Automatic after 24h |

### 4. Idempotency

```bash
# Check before creating
if ct thread status my-task --json 2>/dev/null | jq -e '.status' >/dev/null; then
  echo "Thread already exists"
else
  ct spawn my-task --template task.md
fi
```

### 5. Graceful Shutdown

```bash
# Trap signals for cleanup
trap cleanup EXIT

cleanup() {
  # Publish shutdown event
  ct event publish AGENT_SHUTTING_DOWN

  # Cleanup any forks
  ct worktree remove-fork $FORK_ID --force

  # Final checkpoint
  ct session checkpoint --type shutdown
}
```

## Debugging Multi-Agent Issues

### Event Tracing

```bash
# List recent events
ct event list --limit 50

# Filter by type
ct event list --type CONFLICT --limit 20

# Watch events in real-time
ct event watch --types "STARTED,COMPLETED,FAILED"
```

### Thread State Inspection

```bash
# List all threads with status
ct thread list --all

# Detailed thread info
ct thread status $THREAD_ID --json

# Thread logs
ct thread logs $THREAD_ID --tail 100
```

### Database Queries

```bash
# Direct database access for debugging
sqlite3 .claude-threads/threads.db "
  SELECT t.id, t.status, e.type, e.data
  FROM threads t
  LEFT JOIN events e ON t.id = e.source_thread_id
  WHERE t.created_at > datetime('now', '-1 hour')
  ORDER BY e.created_at DESC
  LIMIT 20
"
```

## See Also

- [ARCHITECTURE.md](ARCHITECTURE.md) - System architecture
- [EVENT-REFERENCE.md](EVENT-REFERENCE.md) - Complete event reference
- [WORKTREE-GUIDE.md](WORKTREE-GUIDE.md) - Worktree management
- [templates/prompts/](../templates/prompts/) - Agent prompt templates
