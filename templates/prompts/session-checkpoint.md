---
name: Session Checkpoint Protocol
description: Standard protocol for creating coordination checkpoints
version: "1.0"
variables:
  - thread_id
  - session_id
  - checkpoint_type
  - interval_minutes
---

# Session Checkpoint Protocol

You are maintaining state for thread `{{thread_id}}` in session `{{session_id}}`.

## Checkpoint Trigger

This checkpoint is triggered by: **{{checkpoint_type}}**
Checkpoint interval: {{interval_minutes}} minutes

## Required Actions

### 1. State Summary

Provide a concise summary of current work state:
- What task am I working on?
- What progress has been made?
- What is the immediate next step?

### 2. Key Decisions

Record important decisions made since last checkpoint:
```json
{
  "decisions": [
    {"decision": "description", "reasoning": "why", "timestamp": "when"}
  ]
}
```

### 3. Pending Tasks

List tasks that need to continue after checkpoint:
```json
{
  "pending": [
    {"task": "description", "priority": 1-10, "context_needed": "key info"}
  ]
}
```

### 4. Context Snapshot

Capture critical context that MUST be preserved:
- File paths being worked on
- Variable states
- Error messages encountered
- API responses to remember

### 5. Memory Updates

Store important learnings for future sessions:
```bash
# Store decision
memory_set "{{thread_id}}" "decision" "key" "value" importance

# Store error pattern
memory_set "{{thread_id}}" "error" "error_type" "how_to_fix" 8

# Store project knowledge
memory_set "" "project" "key" "value" 7  # Global memory
```

## Output Format

After completing checkpoint, output:
```json
{
  "event": "CHECKPOINT_CREATED",
  "thread_id": "{{thread_id}}",
  "session_id": "{{session_id}}",
  "checkpoint_type": "{{checkpoint_type}}",
  "state_summary": "...",
  "key_decisions": [...],
  "pending_tasks": [...],
  "memories_stored": count
}
```

## Context Compaction Warning

If context is approaching threshold:
1. Store all critical information in memory
2. Create checkpoint with full state
3. Output: `{"event": "CONTEXT_COMPACTION_PENDING", "tokens": current_count}`

## Coordination Sync

If coordinated with orchestrator:
1. Update shared context with current state
2. Check for any orchestrator directives
3. Acknowledge coordination sync
