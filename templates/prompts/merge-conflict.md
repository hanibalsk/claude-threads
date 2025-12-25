---
name: Merge Conflict Resolution
description: Resolves merge conflicts for a PR by analyzing and merging conflicting changes
version: "1.0"
variables:
  - pr_number
  - branch
  - target_branch
  - worktree_path
  - conflicting_files
  - attempt_number
---

# Merge Conflict Resolution

Resolve merge conflicts for PR #{{pr_number}}.

## Context

- PR: #{{pr_number}}
- Branch: {{branch}}
- Target: {{target_branch}}
- Worktree: {{worktree_path}}
- Attempt: {{attempt_number}}

## Conflicting Files

{{#each conflicting_files}}
- {{this}}
{{/each}}

## Resolution Steps

### 1. Setup

```bash
cd {{worktree_path}}
git fetch origin {{target_branch}}
git status
```

### 2. Attempt Merge

```bash
git merge origin/{{target_branch}} --no-commit
```

### 3. Resolve Each Conflict

For each file in the conflicting list:

1. **Read the conflict**
   ```bash
   cat <file>
   ```

2. **Understand both sides**
   - What does our branch (HEAD) want?
   - What does target branch want?

3. **Determine strategy**
   - Simple addition: merge both
   - Deletion vs modification: usually keep modification
   - Complex: analyze intent carefully

4. **Apply resolution**
   - Use Edit tool to fix the file
   - Remove conflict markers: `<<<<<<<`, `=======`, `>>>>>>>`

5. **Stage the file**
   ```bash
   git add <file>
   ```

### 4. Verify

```bash
# Run tests (adjust command for project)
npm test
# or
pytest
# or
go test ./...
```

### 5. Commit

```bash
git commit -m "fix: resolve merge conflict with {{target_branch}}

Resolved conflicts in:
{{#each conflicting_files}}
- {{this}}
{{/each}}

Resolution strategy:
- [Describe your approach for each file]"
```

### 6. Push

```bash
git push
```

## Conflict Markers

When you see:
```
<<<<<<< HEAD
Your changes (PR branch)
=======
Their changes (target branch)
>>>>>>> origin/{{target_branch}}
```

You must:
1. Analyze both sections
2. Produce a merged result
3. Remove ALL conflict markers
4. Ensure code is syntactically valid

## Resolution Strategies

### Additive Changes
If both sides add code (imports, functions, etc.):
- Keep both additions
- Ensure no duplicates
- Maintain proper ordering

### Conflicting Modifications
If both sides modify the same code:
- Understand the intent of each
- Apply the more complete/correct version
- Possibly combine logic if both are needed

### Deletions
If one side deletes, other modifies:
- Usually keep the modification
- Unless the deletion was intentional cleanup

## Safety Rules

1. **NEVER lose code** - when uncertain, keep both
2. **ALWAYS test** - never push without verification
3. **Document** - explain resolution in commit message
4. **Escalate** - if too complex, request help

## Output Events

### Success
```json
{"event": "MERGE_CONFLICT_RESOLVED", "pr_number": {{pr_number}}, "files_resolved": [...], "commit": "<sha>", "tests_passed": true}
```

### Failure
```json
{"event": "MERGE_CONFLICT_FAILED", "pr_number": {{pr_number}}, "reason": "...", "files_remaining": [...]}
```

### Escalation
```json
{"event": "ESCALATION_NEEDED", "pr_number": {{pr_number}}, "reason": "Complex conflict requires human review", "files": [...]}
```

## Recovery

If merge fails or you need to start over:
```bash
git merge --abort
git reset --hard HEAD
git clean -fd
```
