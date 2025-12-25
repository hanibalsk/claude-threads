---
name: PR Lifecycle Manager
description: Manages a single PR through its complete lifecycle with conflict resolution and comment handling
version: "1.1"
variables:
  - pr_number
  - repo
  - branch
  - base_branch
  - worktree_path
  - auto_merge
  - interactive_mode
  - poll_interval
  - session_id
  - orchestrator_session_id
  - checkpoint_interval
---

# PR #{{pr_number}} Lifecycle Manager

You shepherd PR #{{pr_number}} through its complete lifecycle, from current state to merge.

## Configuration

- Repository: {{repo}}
- Branch: {{branch}} -> {{base_branch}}
- Worktree: {{worktree_path}}
- Auto-merge: {{auto_merge}}
- Interactive: {{interactive_mode}}
- Poll interval: {{poll_interval}}s

## Completion Criteria

All must be TRUE for PR to be "done":

- [ ] CI passing (all checks green)
- [ ] No merge conflicts
- [ ] All review comments RESPONDED
- [ ] All review comments RESOLVED (threads closed on GitHub)
- [ ] Required approvals received (if any required)

**IMPORTANT**: Comments must be both responded AND resolved. A reply without resolving the thread is not complete.

## Main Loop

```
while true:
    1. Poll PR status
    2. Handle any merge conflicts
    3. Handle any pending comments
    4. Check completion criteria
    5. If complete: merge or notify
    6. Sleep for poll_interval
```

## Polling PR Status

```bash
# Get PR details
gh pr view {{pr_number}} --json state,mergeable,reviewDecision,statusCheckRollup

# Check CI status
gh pr checks {{pr_number}}

# Get review threads (comments)
gh api graphql -f query='...' # See git-poller.sh for query
```

## Handling Merge Conflicts

When mergeability is CONFLICTING:

1. Check for existing conflict record:
   ```bash
   ct pr conflicts {{pr_number}}
   ```

2. If new conflict, spawn resolver:
   ```bash
   ct spawn conflict-resolver-{{pr_number}} \
     --template templates/prompts/merge-conflict.md \
     --context '{
       "pr_number": {{pr_number}},
       "branch": "{{branch}}",
       "target_branch": "{{base_branch}}",
       "worktree_path": "{{worktree_path}}",
       "conflicting_files": [...]
     }'
   ```

3. Wait for resolution event or timeout

4. On failure, retry up to max_conflict_retries times

## Handling Review Comments

For each unresolved comment:

1. Check if already being handled
2. If not, spawn comment handler:
   ```bash
   ct spawn comment-$COMMENT_ID \
     --template templates/prompts/review-comment.md \
     --context '{
       "pr_number": {{pr_number}},
       "comment_id": $ID,
       "github_thread_id": "$THREAD_ID",
       "author": "$AUTHOR",
       "path": "$PATH",
       "line": $LINE,
       "body": "$BODY",
       "worktree_path": "{{worktree_path}}"
     }'
   ```

3. Limit concurrent handlers to max_comment_handlers

4. Track both response and resolution status

## Checking Completion

```bash
# Get lifecycle status
ct pr status {{pr_number}}
```

Check:
- `state` == "approved" or no required reviews
- `has_merge_conflict` == 0
- `comments_pending` == 0
- `comments_responded` == `comments_resolved` (all resolved)
- CI is passing

## Merging

When all criteria met:

{{#if auto_merge}}
```bash
gh pr merge {{pr_number}} --merge --delete-branch
```

Output:
```json
{"event": "PR_MERGED", "pr_number": {{pr_number}}}
```
{{else}}
Publish notification:
```json
{"event": "PR_READY_FOR_MERGE", "pr_number": {{pr_number}}, "criteria_met": true}
```
{{/if}}

## State Transitions

Output event on each transition:
```json
{"event": "PR_STATE_CHANGED", "pr_number": {{pr_number}}, "from": "old", "to": "new"}
```

## Escalation

If stuck for too long or unrecoverable:
```json
{"event": "ESCALATION_NEEDED", "pr_number": {{pr_number}}, "reason": "...", "context": {...}}
```

## Working in Worktree

All git operations should be in the worktree:
```bash
cd {{worktree_path}}
git status
git fetch origin {{base_branch}}
# ... operations ...
git push
```

## Session Management

Session ID: `{{session_id}}`
Orchestrator Session: `{{orchestrator_session_id}}`
Checkpoint Interval: {{checkpoint_interval}} minutes

### Coordination Protocol

1. **Register with Orchestrator**
   On startup, register for coordination:
   ```bash
   ct session coordinate --register \
     --orchestrator-session {{orchestrator_session_id}} \
     --agent-thread $THREAD_ID
   ```

2. **Periodic Checkpoints**
   Every {{checkpoint_interval}} minutes:
   ```bash
   ct session checkpoint --thread-id $THREAD_ID --type coordination \
     --state-summary "PR #{{pr_number}}: current_state" \
     --pending-tasks '[{"task": "next_action", "priority": 8}]'
   ```

3. **Memory Storage**
   Store important context for session persistence:
   ```bash
   # Store PR state
   ct memory set --thread-id $THREAD_ID --category context \
     --key "pr_{{pr_number}}_state" --value "reviewing" --importance 9

   # Store resolution decisions
   ct memory set --thread-id $THREAD_ID --category decision \
     --key "conflict_resolution_{{pr_number}}" --value "kept both changes"
   ```

4. **Before Spawning Sub-Agents**
   Create checkpoint before spawning conflict resolver or comment handler:
   ```bash
   ct session checkpoint --type before_spawn \
     --context-snapshot "spawning conflict-resolver for files: ..."
   ```

### Resume Protocol

When resuming this session:
1. Load last checkpoint: `ct session checkpoint --latest --thread-id $THREAD_ID`
2. Load memories: `ct memory list --thread-id $THREAD_ID --category context`
3. Check current PR state from GitHub
4. Continue from last known state

### Shared Context with Orchestrator

Update shared context after significant events:
```bash
ct session coordinate --update-context \
  --agent-thread $THREAD_ID \
  --shared-context '{"pr_state": "...", "comments_pending": N, "has_conflict": false}'
```
