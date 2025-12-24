---
name: ct-spawn
description: Spawn threads on claude-threads orchestrator
allowed-tools: Bash,Read
user-invocable: true
---

# Spawn Threads (claude-threads)

Quickly spawn threads on a running claude-threads orchestrator. Threads automatically use isolated git worktrees when spawned remotely.

## Quick Spawn

```bash
# Spawn a thread (auto-connects if needed)
ct spawn epic-7a --template bmad-developer.md

# Spawn multiple parallel threads
ct spawn epic-7a --template bmad-developer.md
ct spawn epic-8a --template bmad-developer.md
ct spawn epic-9a --template bmad-developer.md
```

## Prerequisites

Ensure orchestrator is running:

```bash
# Check connection
ct remote status

# If not connected, connect first
ct remote connect localhost:31337 --token $CT_API_TOKEN
```

## Spawn Command

```bash
ct spawn <name> [options]
```

### Options

| Option | Description |
|--------|-------------|
| `--template, -t <file>` | Prompt template file |
| `--mode, -m <mode>` | Thread mode (automatic, semi-auto, interactive) |
| `--context, -c <json>` | Thread context as JSON |
| `--worktree-base <branch>` | Base branch for worktree (default: main) |
| `--no-worktree` | Disable worktree isolation (not recommended) |
| `--wait` | Wait for thread completion |
| `--remote` | Force use of remote API |
| `--local` | Force use of local database |

## Examples

### Basic Spawn

```bash
# Simple spawn with template
ct spawn my-task --template developer.md
```

### Epic Development (BMAD)

```bash
# Spawn epic with BMAD template
ct spawn epic-7a --template bmad-developer.md --context '{"epic_id":"7A"}'
```

### Feature Branch

```bash
# Spawn with custom base branch
ct spawn feature-login --template developer.md --worktree-base develop
```

### CI Fix

```bash
# Spawn fix thread and wait for completion
ct spawn ci-fix-pr-123 --template fixer.md --context '{"pr_number":"123"}' --wait
```

### Story Implementation

```bash
# Spawn story with full context
ct spawn story-42 --template developer.md --context '{
  "story_id": "42",
  "title": "Add user authentication",
  "acceptance_criteria": ["Login form", "Session management", "Logout"]
}'
```

### Multiple Parallel Epics

```bash
# Spawn multiple epics in parallel
for epic in 7A 8A 9A 10B; do
  ct spawn "epic-${epic}" \
    --template bmad-developer.md \
    --context "{\"epic_id\":\"${epic}\"}"
done
```

## Monitor Spawned Threads

```bash
# List running threads
ct thread list running

# Check specific thread
ct thread status <thread-id>

# View thread logs
ct thread logs <thread-id>

# List worktrees
ct worktree list
```

## Worktree Isolation

Remote threads ALWAYS use isolated git worktrees by default:

- Each thread gets its own working directory
- No conflicts between parallel threads
- Changes are isolated until merged
- Automatic cleanup when thread completes

```
.claude-threads/worktrees/
├── epic-7a-ct-abc123/     # Thread 1 worktree
├── epic-8a-ct-def456/     # Thread 2 worktree
└── epic-9a-ct-ghi789/     # Thread 3 worktree
```

## See Also

- `/connect` - Connect to orchestrator
- `/threads` - Full thread management
