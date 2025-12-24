# PR Shepherd - Automatic PR Feedback Loop

The PR Shepherd is a persistent agent that monitors your pull requests and automatically fixes CI failures and addresses review comments until the PR is merged.

## Overview

Traditional PR workflows require manual intervention when CI fails or reviewers request changes. The PR Shepherd automates this by:

1. **Creating isolation** - Each PR gets its own git worktree for fixes
2. **Detecting failures** - Monitors CI status and review state
3. **Spawning fix threads** - Launches Claude agents in isolated worktrees
4. **Verifying fixes** - Re-checks CI after each fix attempt
5. **Iterating until success** - Repeats until approved and merged (or max attempts reached)
6. **Cleaning up** - Removes worktree when PR is merged or closed

## Quick Start

```bash
# Initialize claude-threads in your project
ct init

# Start watching a PR (creates isolated worktree)
ct pr watch 123

# Check status (shows worktree path)
ct pr status 123

# View all watched PRs
ct pr list

# View active worktrees
ct worktree list

# Stop watching (cleans up worktree)
ct pr stop 123
```

## How It Works

### State Machine

```
┌─────────────────────────────────────────────────────────────────────┐
│                         PR SHEPHERD STATE MACHINE                    │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────┐                                                        │
│  │ WATCHING │ ← Initial state after `ct pr watch`                    │
│  └────┬─────┘                                                        │
│       │                                                              │
│       ▼                                                              │
│  ┌────────────┐    CI running     ┌───────────┐                     │
│  │ CI_PENDING │ ◄───────────────► │ CI_FAILED │                     │
│  └─────┬──────┘                   └─────┬─────┘                     │
│        │                                │                            │
│        │ CI passes                      │ Spawn fix thread           │
│        ▼                                ▼                            │
│  ┌───────────┐                    ┌──────────┐                      │
│  │ CI_PASSED │ ◄──────────────────│  FIXING  │                      │
│  └─────┬─────┘    Fix completes   └──────────┘                      │
│        │                                                             │
│        ▼                                                             │
│  ┌────────────────┐              ┌───────────────────┐              │
│  │ REVIEW_PENDING │ ──────────►  │ CHANGES_REQUESTED │              │
│  └───────┬────────┘              └─────────┬─────────┘              │
│          │                                 │                         │
│          │ Approved                        │ Spawn fix thread        │
│          ▼                                 ▼                         │
│  ┌──────────┐                       ┌──────────┐                    │
│  │ APPROVED │ ◄─────────────────────│  FIXING  │                    │
│  └────┬─────┘     Fix completes     └──────────┘                    │
│       │                                                              │
│       │ Auto-merge (if enabled)                                      │
│       ▼                                                              │
│  ┌──────────┐                                                        │
│  │  MERGED  │ ← Terminal state (success)                             │
│  └──────────┘                                                        │
│                                                                      │
│  Other terminal states: CLOSED, BLOCKED (max attempts reached)       │
└─────────────────────────────────────────────────────────────────────┘
```

### Polling Behavior

The shepherd uses **adaptive polling** to minimize resource usage:

| Condition | Poll Interval | Purpose |
|-----------|---------------|---------|
| Active PR (CI pending) | 30 seconds | Fast feedback on CI status |
| Active PR (fixing) | 5 seconds | Monitor fix thread progress |
| No active PRs | 5 minutes | Idle mode, minimal overhead |
| Push cooldown | 2 minutes | Wait for CI to start after push |

### Fix Threads

When CI fails or changes are requested, the shepherd spawns a **fix thread** in an isolated worktree:

1. Creates isolated git worktree for the PR branch (if not exists)
2. Creates a new thread using `templates/prompts/pr-fix.md`
3. Passes context including worktree path
4. The fix thread runs Claude in the isolated worktree
5. Claude analyzes and fixes the issue without affecting main workspace
6. Pushes fixes from worktree
7. After completion, the shepherd re-checks CI status

**Fix thread context:**
```json
{
  "pr_number": 123,
  "fix_type": "ci",
  "details": "[{\"name\": \"tests\", \"conclusion\": \"failure\"}]",
  "attempt": 1,
  "worktree_path": ".claude-threads/worktrees/pr-123-feature-branch",
  "branch": "feature-branch"
}
```

### Worktree Isolation Benefits

- **No conflicts** - Fix operations don't interfere with your current work
- **Parallel fixes** - Multiple PRs can be fixed simultaneously
- **Clean state** - Each PR starts with a clean working directory
- **Automatic cleanup** - Worktrees removed when PR is merged/closed

## Configuration

Add to your `config.yaml`:

```yaml
pr_shepherd:
  # Maximum fix attempts before marking PR as blocked
  max_fix_attempts: 5

  # Seconds between CI status checks
  ci_poll_interval: 30

  # Seconds between checks when no active PRs
  idle_poll_interval: 300

  # Seconds to wait after push before checking CI
  push_cooldown: 120

  # Automatically merge when CI passes and approved
  auto_merge: false

worktrees:
  # Enable worktree isolation (recommended)
  enabled: true

  # Auto-cleanup worktrees for completed PRs
  auto_cleanup: true

  # Maximum age before forced cleanup (days)
  max_age_days: 7
```

### Environment Variables

```bash
# Override config via environment
CT_PR_SHEPHERD_MAX_FIX_ATTEMPTS=10
CT_PR_SHEPHERD_CI_POLL_INTERVAL=60
CT_PR_SHEPHERD_AUTO_MERGE=true
```

## CLI Reference

### ct pr watch

Start watching a pull request:

```bash
ct pr watch <pr_number>

# Example
ct pr watch 123
```

The shepherd will:
1. Fetch PR info from GitHub
2. Create an isolated git worktree for the PR branch
3. Create a tracking entry in the database
4. Begin monitoring CI and review status
5. Output current state including worktree path

### ct pr status

Show status of watched PRs:

```bash
# Show specific PR
ct pr status 123

# Show all PRs (same as `ct pr list`)
ct pr status
```

Output:
```
PR #123 Status
====================
State: ci_pending
Repository: owner/repo
Branch: feature-branch
Worktree: .claude-threads/worktrees/pr-123-feature-branch
Fix Attempts: 0
Last Push: 2024-01-15 10:30:00
Last CI Check: 2024-01-15 10:31:00
Current Fix Thread: none
Created: 2024-01-15 10:30:00
Updated: 2024-01-15 10:31:00
```

### ct pr list

List all watched PRs:

```bash
ct pr list
```

Output:
```
Watched PRs
===========
#123    ci_pending    0 fixes    owner/repo
#124    fixing        2 fixes    owner/repo
#125    approved      1 fixes    owner/repo
```

### ct pr stop

Stop watching a PR:

```bash
ct pr stop <pr_number>

# Example
ct pr stop 123
```

This will:
1. Stop any running fix thread
2. Remove the worktree for this PR
3. Remove the PR from the watch list
4. Publish a `PR_WATCH_STOPPED` event

### ct pr daemon

Run the shepherd as a background daemon:

```bash
ct pr daemon
```

The daemon will:
1. Create a PID file at `.claude-threads/pr-shepherd.pid`
2. Continuously monitor all watched PRs
3. Use adaptive polling based on activity
4. Log to `.claude-threads/logs/pr-shepherd.log`

### ct pr tick

Run a single check for a specific PR (useful for testing):

```bash
ct pr tick 123
```

## Events

The shepherd publishes events to the blackboard:

| Event | Data | Trigger |
|-------|------|---------|
| `PR_WATCH_STARTED` | `{pr_number, repo, branch, worktree_path}` | `ct pr watch` |
| `PR_WATCH_STOPPED` | `{pr_number}` | `ct pr stop` |
| `WORKTREE_CREATED` | `{pr_number, path, branch}` | Worktree created for PR |
| `PR_STATE_CHANGED` | `{pr_number, state}` | Any state transition |
| `PR_FIX_STARTED` | `{pr_number, thread_id, fix_type, attempt, worktree_path}` | Fix thread spawned |
| `WORKTREE_PUSHED` | `{pr_number, path, commits}` | Changes pushed from worktree |
| `CI_PASSED` | `{pr_number}` | CI checks pass |
| `CI_FAILED` | `{pr_number}` | CI checks fail |
| `PR_APPROVED` | `{pr_number}` | PR approved |
| `PR_CHANGES_REQUESTED` | `{pr_number}` | Changes requested |
| `PR_READY_TO_MERGE` | `{pr_number}` | Approved + CI passed |
| `PR_MERGED` | `{pr_number, auto_merged}` | PR merged |
| `WORKTREE_DELETED` | `{pr_number, path}` | Worktree cleaned up |
| `PR_MAX_ATTEMPTS_REACHED` | `{pr_number, attempts}` | Max fixes exceeded |

### Subscribing to Events

Other threads can subscribe to PR events:

```bash
# In a thread script
source lib/blackboard.sh

# Subscribe to events for a specific PR
bb_subscribe_pr_events "$THREAD_ID" 123

# Poll for PR events
events=$(bb_poll_pr_events "$THREAD_ID" 123)

# Wait for PR to reach a state
bb_wait_for_pr_state 123 "merged" 3600  # 1 hour timeout
```

## Database Schema

The shepherd uses dedicated tables:

```sql
CREATE TABLE pr_watches (
    pr_number INTEGER PRIMARY KEY,
    repo TEXT NOT NULL,
    branch TEXT,
    base_branch TEXT DEFAULT 'main',
    worktree_path TEXT,
    state TEXT NOT NULL DEFAULT 'watching',
    fix_attempts INTEGER DEFAULT 0,
    last_push_at TEXT,
    last_ci_check_at TEXT,
    last_fix_at TEXT,
    shepherd_thread_id TEXT,
    current_fix_thread_id TEXT,
    error TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE worktrees (
    id TEXT PRIMARY KEY,
    thread_id TEXT,
    pr_number INTEGER,
    path TEXT NOT NULL,
    branch TEXT NOT NULL,
    base_branch TEXT NOT NULL,
    status TEXT DEFAULT 'active',
    commits_ahead INTEGER DEFAULT 0,
    commits_behind INTEGER DEFAULT 0,
    is_dirty INTEGER DEFAULT 0,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);
```

Query examples:
```bash
# List all PRs in fixing state
sqlite3 .claude-threads/threads.db \
  "SELECT pr_number, fix_attempts, worktree_path FROM pr_watches WHERE state = 'fixing'"

# Get fix history
sqlite3 .claude-threads/threads.db \
  "SELECT id, name, status FROM threads WHERE name LIKE 'pr-123-fix%'"

# List active worktrees for PRs
sqlite3 .claude-threads/threads.db \
  "SELECT pr_number, path, branch FROM worktrees WHERE status = 'active' AND pr_number IS NOT NULL"
```

## Integration with Orchestrator

The PR Shepherd integrates with the main orchestrator:

1. **Adaptive polling** - The orchestrator checks for active PRs and adjusts its poll interval
2. **Thread spawning** - Fix threads are created via the standard thread lifecycle
3. **Event routing** - PR events flow through the blackboard to other threads

### Orchestrator Configuration

```yaml
orchestrator:
  poll_interval: 1          # Normal polling (seconds)
  idle_poll_interval: 10    # Idle polling (seconds)
  idle_threshold: 30        # Ticks before switching to idle
```

The orchestrator considers a PR "active" if:
- State is not `merged` or `closed`
- There's a fix thread running

## Troubleshooting

### PR stuck in FIXING state

The fix thread may have crashed. Check:

```bash
# View fix thread status
ct thread status <fix_thread_id>

# View fix thread logs
ct thread logs <fix_thread_id>

# Manually retry
ct pr stop 123
ct pr watch 123
```

### Max attempts reached

The PR is marked as BLOCKED. Options:

1. Increase `max_fix_attempts` in config
2. Manually fix the issue and restart:
   ```bash
   ct pr stop 123
   ct pr watch 123
   ```
3. Check why fixes are failing in the thread logs

### CI not detected

Ensure:
1. The `gh` CLI is authenticated: `gh auth status`
2. You have access to the repository
3. CI checks are configured in the repo

### Webhook vs Polling

The shepherd uses **polling** by default. For faster response, enable webhooks:

```bash
# Start webhook server
ct webhook start --port 31338

# Configure GitHub webhook to send events to:
# http://your-server:31338/webhook
```

With webhooks, CI status changes trigger immediate shepherd ticks.

## Best Practices

1. **Start with low max_fix_attempts** - Set to 3-5 initially to catch repeated failures early
2. **Use push cooldown** - Give CI time to start before checking status
3. **Monitor fix threads** - Review what Claude is actually fixing
4. **Enable auto-merge carefully** - Only for repos with good test coverage
5. **Use with branch protection** - Ensure required reviews are in place

## Example Workflow

```bash
# 1. Create a PR from your feature branch
git checkout -b feature-xyz
# ... make changes ...
git push -u origin feature-xyz
gh pr create --fill

# 2. Start watching the PR
ct pr watch $(gh pr view --json number -q '.number')

# 3. Let the shepherd handle CI failures and reviews
ct pr status

# 4. Once merged, the shepherd stops automatically
ct pr list  # PR should be gone or show "merged"
```

## See Also

- [README.md](../README.md) - Main documentation
- [AGENTS.md](AGENTS.md) - Agent documentation
- [templates/prompts/pr-fix.md](../templates/prompts/pr-fix.md) - Fix thread template
