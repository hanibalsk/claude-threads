---
name: Review Comment Handler
description: Handles a single review comment by implementing changes, replying, and resolving the thread
version: "1.0"
variables:
  - pr_number
  - comment_id
  - github_thread_id
  - author
  - path
  - line
  - body
  - worktree_path
---

# Review Comment Handler

Handle and resolve review comment on PR #{{pr_number}}.

## Comment Details

- Comment ID: {{comment_id}}
- GitHub Thread ID: {{github_thread_id}}
- Author: @{{author}}
- File: {{path}}:{{line}}
- Worktree: {{worktree_path}}

## Comment Body

{{body}}

## Your Task

You must complete THREE things:
1. **Implement** the requested change
2. **Reply** to the comment explaining what you did
3. **Resolve** the thread on GitHub

A comment is NOT done until all three are complete.

## Workflow

### 1. Analyze the Comment

Read and understand what @{{author}} is asking for:
- Is it a code change request?
- Is it a question that needs answering?
- Is it a suggestion to consider?
- Is it informational/FYI?

### 2. Implement the Change

```bash
cd {{worktree_path}}
```

Read the file and context:
```bash
cat {{path}}
```

Make the requested change using Edit tool.

Stage and commit:
```bash
git add {{path}}
git commit -m "fix: address review comment on {{path}}

Addresses feedback from @{{author}}:
- [Summary of change]"
```

Push:
```bash
git push
```

### 3. Reply to the Comment

Get the commit SHA:
```bash
COMMIT=$(git rev-parse --short HEAD)
```

Post reply:
```bash
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

gh api repos/$REPO/pulls/{{pr_number}}/comments/{{comment_id}}/replies \
  -f body="Thanks for the feedback, @{{author}}!

I've addressed this in commit \`$COMMIT\`:
- [Description of what was changed]

[Optional: any additional explanation]"
```

### 4. Resolve the Thread

```bash
gh api graphql -f query='
mutation {
  resolveReviewThread(input: {threadId: "{{github_thread_id}}"}) {
    thread {
      isResolved
    }
  }
}'
```

## Response Templates

### For Code Changes
```
Thanks for catching this, @{{author}}!

I've fixed this in commit `<sha>`:
- <description of fix>

Let me know if you'd like any other changes.
```

### For Questions
```
Good question, @{{author}}!

<Answer to the question>

I've added a clarifying comment in the code: commit `<sha>`.
```

### For Suggestions
```
Great suggestion, @{{author}}!

I've implemented this in commit `<sha>`:
- <what was implemented>

This improves <benefit>.
```

### For Informational Comments
```
Thanks for the note, @{{author}}!

<Brief acknowledgment>
```

## Special Cases

### Clarification Needed
If the comment is unclear:
1. Reply asking for clarification
2. Do NOT resolve the thread
3. Output:
```json
{"event": "COMMENT_BLOCKED", "comment_id": {{comment_id}}, "reason": "Needs clarification from reviewer"}
```

### Disagreement
If you disagree with the suggestion:
1. Reply explaining your reasoning respectfully
2. Ask for reviewer's input
3. Do NOT resolve until consensus

### Already Fixed
If the issue is already addressed:
1. Reply pointing to the relevant commit
2. Resolve the thread

### Out of Scope
If the request is out of scope:
1. Acknowledge the feedback
2. Suggest creating a follow-up issue
3. Resolve with explanation

## Output Events

### After Responding
```json
{"event": "COMMENT_RESPONDED", "pr_number": {{pr_number}}, "comment_id": {{comment_id}}, "commit": "<sha>"}
```

### After Resolving
```json
{"event": "COMMENT_RESOLVED", "pr_number": {{pr_number}}, "comment_id": {{comment_id}}, "thread_id": "{{github_thread_id}}"}
```

### Completion
```json
{"event": "COMMENT_HANDLED", "pr_number": {{pr_number}}, "comment_id": {{comment_id}}, "responded": true, "resolved": true}
```

## Best Practices

1. Be professional and thankful
2. Reference specific commits
3. Explain the "why" not just "what"
4. Keep responses concise but complete
5. Don't resolve until truly addressed
