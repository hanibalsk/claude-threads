---
name: ct-spawn
description: Spawn threads on claude-threads orchestrator
allowed-tools: Bash,Read
user-invocable: true
---

# Spawn Threads (claude-threads)

You are spawning threads on a claude-threads orchestrator. Threads automatically use isolated git worktrees.

## Auto-Spawn Process

Execute these steps:

### Step 1: Find the ct Command

The `ct` command is installed locally in `.claude-threads/bin/ct`:

```bash
CT_CMD=".claude-threads/bin/ct"
if [[ ! -x "$CT_CMD" ]]; then
    echo "Error: ct command not found. Run 'ct init' first."
    exit 1
fi
echo "Using: $CT_CMD"
$CT_CMD version
```

### Step 2: Check Connection

```bash
.claude-threads/bin/ct remote status
```

### Step 3: Connect if Needed

If not connected, try auto-discovery:

```bash
.claude-threads/bin/ct remote discover
```

### Step 4: Spawn the Thread

The user should specify what to spawn. Ask them for:
- Thread name (e.g., epic-7a, story-123, fix-ci)
- Template to use (e.g., bmad-developer.md, developer.md, fixer.md)
- Any context needed

Then run:

```bash
.claude-threads/bin/ct spawn <name> --template <template> [--context '<json>']
```

## Spawn Command

```bash
.claude-threads/bin/ct spawn <name> [options]
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
.claude-threads/bin/ct spawn my-task --template developer.md
```

### Epic Development (BMAD)

```bash
# Spawn epic with BMAD template
.claude-threads/bin/ct spawn epic-7a --template bmad-developer.md --context '{"epic_id":"7A"}'
```

### Feature Branch

```bash
# Spawn with custom base branch
.claude-threads/bin/ct spawn feature-login --template developer.md --worktree-base develop
```

### CI Fix

```bash
# Spawn fix thread and wait for completion
.claude-threads/bin/ct spawn ci-fix-pr-123 --template fixer.md --context '{"pr_number":"123"}' --wait
```

### Story Implementation

```bash
# Spawn story with full context
.claude-threads/bin/ct spawn story-42 --template developer.md --context '{
  "story_id": "42",
  "title": "Add user authentication",
  "acceptance_criteria": ["Login form", "Session management", "Logout"]
}'
```

### Multiple Parallel Epics

```bash
# Spawn multiple epics in parallel
for epic in 7A 8A 9A 10B; do
  .claude-threads/bin/ct spawn "epic-${epic}" \
    --template bmad-developer.md \
    --context "{\"epic_id\":\"${epic}\"}"
done
```

## Monitor Spawned Threads

```bash
# List running threads
.claude-threads/bin/ct thread list running

# Check specific thread
.claude-threads/bin/ct thread status <thread-id>

# View thread logs
.claude-threads/bin/ct thread logs <thread-id>

# List worktrees
.claude-threads/bin/ct worktree list
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
