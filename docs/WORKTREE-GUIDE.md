# Worktree Guide for Agents

This guide explains how agents use git worktrees for isolated parallel development.

## Overview

Worktrees provide isolated git working directories, enabling:
- **Parallel development** - Multiple agents work simultaneously
- **No conflicts** - Each agent has its own branch
- **Memory efficiency** - Shared git objects (base + fork pattern)
- **Clean rollback** - Discard worktree to undo changes

## Worktree Types

### 1. Thread Worktree

Standard worktree for general thread isolation.

```
.claude-threads/worktrees/
└── thread-abc123/          ← One per thread
    ├── .git/               ← Link to main repo
    ├── .worktree-info      ← Metadata
    └── (project files)
```

**Usage:**
```bash
# Created automatically when thread starts with --worktree
ct spawn my-task --template developer.md --worktree

# Or explicitly
ct worktree create thread-abc123 feature/my-task main
```

### 2. PR Base Worktree

Long-lived worktree tracking a PR branch. Sub-agents fork from this.

```
.claude-threads/worktrees/
└── pr-123-base/            ← One per watched PR
    ├── .git/
    ├── .worktree-info
    │   ├── pr_number: 123
    │   ├── type: pr_base
    │   ├── fork_count: 2
    │   └── last_commit: abc123
    └── (project files)
```

**Usage:**
```bash
# Create when PR watch starts
ct worktree base-create 123 feature/my-pr main

# Update from remote
ct worktree base-update 123

# Status
ct worktree base-status 123
```

### 3. Fork Worktree

Short-lived worktree for sub-agent tasks (conflict resolution, comment handling).

```
.claude-threads/worktrees/
├── pr-123-base/                 ← Parent base
├── conflict-resolver-123/       ← Fork for conflicts
│   └── .worktree-info
│       ├── type: pr_fork
│       ├── forked_from: pr-123-base
│       └── purpose: conflict_resolution
└── comment-handler-456/         ← Fork for comments
    └── .worktree-info
        ├── type: pr_fork
        ├── forked_from: pr-123-base
        └── purpose: comment_handler
```

**Usage:**
```bash
# Create fork from base
ct worktree fork 123 conflict-resolver fix/conflict conflict_resolution

# Do work...

# Merge back and cleanup
ct worktree merge-back conflict-resolver
ct worktree remove-fork conflict-resolver
```

## Decision Tree: When to Use Which Worktree

```
                    ┌─────────────────────┐
                    │  Need isolated git  │
                    │     environment?    │
                    └──────────┬──────────┘
                               │
                      ┌────────┴────────┐
                      │                 │
                     Yes                No
                      │                 │
                      ▼                 ▼
            ┌─────────────────┐   ┌─────────────────┐
            │ Is this for a   │   │  Work in main   │
            │ PR lifecycle?   │   │  repo directly  │
            └────────┬────────┘   └─────────────────┘
                     │
            ┌────────┴────────┐
            │                 │
           Yes                No
            │                 │
            ▼                 ▼
  ┌─────────────────┐   ┌─────────────────┐
  │ Need parallel   │   │ Use standard    │
  │ sub-agents?     │   │ thread worktree │
  └────────┬────────┘   │ (--worktree)    │
           │            └─────────────────┘
  ┌────────┴────────┐
  │                 │
 Yes                No
  │                 │
  ▼                 ▼
┌────────────────┐  ┌────────────────┐
│ Use Base +     │  │ Use standard   │
│ Fork pattern   │  │ thread worktree│
└────────────────┘  └────────────────┘
```

## Base + Fork Pattern (PR Lifecycle)

### Why Use This Pattern?

| Without Pattern | With Pattern |
|----------------|--------------|
| Each sub-agent clones full repo | Sub-agents share git objects |
| ~100MB per worktree | ~1MB per fork (links only) |
| Slow to create | Fast to create |
| No coordination | Centralized through base |

### Complete Workflow

```bash
#!/bin/bash
# PR Shepherd workflow with base + fork pattern

PR_NUMBER=123
BRANCH="feature/my-pr"
TARGET="main"

# 1. Create base worktree (once when PR watch starts)
BASE_PATH=$(ct worktree base-create $PR_NUMBER $BRANCH $TARGET)
echo "Base created: $BASE_PATH"

# 2. When conflict detected, fork for resolver
if has_conflict; then
  FORK_PATH=$(ct worktree fork $PR_NUMBER conflict-fix fix/conflict conflict_resolution)

  # Spawn resolver agent with fork
  ct spawn conflict-resolver-$PR_NUMBER \
    --template merge-conflict.md \
    --context "{\"worktree_path\": \"$FORK_PATH\"}"

  # Wait for completion
  ct event wait CONFLICT_RESOLVED --timeout 300

  # Merge fork back to base
  ct worktree merge-back conflict-fix

  # Cleanup fork
  ct worktree remove-fork conflict-fix
fi

# 3. When comment needs handling, fork for handler
for comment_id in $(get_pending_comments); do
  FORK_PATH=$(ct worktree fork $PR_NUMBER comment-$comment_id fix/comment-$comment_id comment_handler)

  ct spawn comment-handler-$comment_id \
    --template review-comment.md \
    --context "{\"worktree_path\": \"$FORK_PATH\", \"comment_id\": \"$comment_id\"}"
done

# Wait for all comment handlers...

# 4. Push from base
cd $BASE_PATH
git push origin $BRANCH

# 5. Cleanup when PR is merged/closed
ct worktree base-remove $PR_NUMBER
```

## Agent Worktree Usage

### In Prompt Templates

```markdown
# templates/prompts/pr-fix.md

You are working in an isolated worktree at: {{worktree_path}}

## Your Task
Fix the issue described below.

## Working Directory
All git operations should be in your worktree:
```bash
cd {{worktree_path}}
git status
# Make changes...
git add .
git commit -m "Fix: description"
```

## IMPORTANT
- Do NOT push directly - your parent will handle pushing
- When done, publish completion event:
```bash
ct event publish FIX_COMPLETED '{"thread_id": "$THREAD_ID"}'
```
```

### In Agent Definitions

```markdown
# .claude/agents/merge-conflict-resolver.md

## Worktree Protocol

1. **Receive worktree path** from context
2. **Work exclusively** in that worktree
3. **Commit changes** to worktree
4. **Do NOT push** - parent merges back
5. **Publish event** when done
```

## Worktree Commands Reference

### Standard Worktree Commands

```bash
# List all worktrees
ct worktree list

# Status of specific worktree
ct worktree status <thread-id>

# Cleanup orphaned worktrees
ct worktree cleanup [--force]
```

### PR Base Worktree Commands

```bash
# Create/update base worktree
ct worktree base-create <pr> <branch> [target] [remote]
ct worktree base-update <pr>

# Status and info
ct worktree base-status <pr>

# Remove base and all forks
ct worktree base-remove <pr> [--force]
```

### Fork Commands

```bash
# Create fork from base
ct worktree fork <pr> <fork-id> <branch> [purpose]

# Purpose options:
#   conflict_resolution
#   comment_handler
#   ci_fix
#   general

# Merge fork back to base
ct worktree merge-back <fork-id> [--no-push]

# Remove fork
ct worktree remove-fork <fork-id> [--force]

# List forks for PR
ct worktree list-forks <pr>
```

### Maintenance

```bash
# Reconcile database with filesystem
ct worktree reconcile        # Check only
ct worktree reconcile --fix  # Auto-repair
```

## Error Handling

### Merge Conflicts During merge-back

```bash
# merge-back returns exit code 1 on conflict
if ! ct worktree merge-back my-fork; then
  echo "Merge conflict - manual resolution needed"

  # Option 1: Force remove and retry
  ct worktree remove-fork my-fork --force
  # Re-fork from updated base and try again

  # Option 2: Escalate
  ct event publish MERGE_CONFLICT_ESCALATION '{
    "fork_id": "my-fork",
    "requires_human": true
  }'
fi
```

### Push Failures

```bash
# merge-back returns exit code 2 on push failure
result=$?
if [[ $result -eq 2 ]]; then
  echo "Push failed but merge succeeded locally"

  # Retry push manually
  cd $(ct worktree base-path $PR_NUMBER)
  git push origin $BRANCH
fi
```

### Orphaned Worktrees

```bash
# Find inconsistencies
ct worktree reconcile

# Example output:
# Fork conflict-fix exists on disk but not in database
# Base pr-999-base in database but directory missing
#
# Found 2 issue(s)
# Run with 'fix' argument to automatically repair

# Auto-fix
ct worktree reconcile --fix
```

## Best Practices

### 1. Always Cleanup Forks

```bash
# After merge-back, always remove
ct worktree merge-back my-fork && ct worktree remove-fork my-fork

# Or use trap for cleanup on exit
trap "ct worktree remove-fork $FORK_ID --force" EXIT
```

### 2. Use Appropriate Purpose

```bash
# Helps with debugging and metrics
ct worktree fork 123 fix-1 branch conflict_resolution  # For conflicts
ct worktree fork 123 fix-2 branch comment_handler      # For comments
ct worktree fork 123 fix-3 branch ci_fix               # For CI issues
```

### 3. Check Base Freshness

```bash
# Before forking, consider updating base
ct worktree base-update $PR_NUMBER

# Then fork
ct worktree fork $PR_NUMBER my-fork fix/branch
```

### 4. Handle Race Conditions

```bash
# Multiple agents might try to fork simultaneously
# The locking mechanism handles this, but check for existing forks:

FORK_PATH=$(ct worktree fork 123 my-fork branch)
if [[ -z "$FORK_PATH" ]]; then
  echo "Failed to create fork (may already exist)"
  exit 1
fi
```

### 5. Monitor Fork Count

```bash
# Check before creating more forks
ct worktree base-status 123

# If fork_count is high, wait for some to complete
while true; do
  count=$(ct worktree base-status 123 --json | jq '.fork_count')
  if [[ $count -lt 5 ]]; then
    break
  fi
  sleep 10
done
```

## Troubleshooting

### "Base worktree not found"

```bash
# Check if PR is being watched
ct pr list

# If not, create base first
ct worktree base-create 123 feature/branch main
```

### "Fork already exists"

```bash
# Check existing forks
ct worktree list-forks 123

# Remove stale fork
ct worktree remove-fork old-fork --force
```

### "Merge conflict when merging fork"

```bash
# Base may have been updated while fork was working
# Option 1: Rebase fork
cd $(ct worktree fork-path my-fork)
git fetch
git rebase origin/main

# Option 2: Abandon fork and retry
ct worktree remove-fork my-fork --force
# Create new fork from updated base
```

### "Permission denied on worktree"

```bash
# Check ownership
ls -la .claude-threads/worktrees/

# May need to fix permissions
chmod -R u+rw .claude-threads/worktrees/
```

## See Also

- [ARCHITECTURE.md](ARCHITECTURE.md) - System architecture
- [AGENT-COORDINATION.md](AGENT-COORDINATION.md) - Agent communication
- [PR-SHEPHERD.md](PR-SHEPHERD.md) - PR lifecycle management
- [lib/git.sh](../lib/git.sh) - Implementation details
