# Getting Started with claude-threads

This guide will help you get up and running with claude-threads, a multi-agent orchestration framework for Claude Code.

## Prerequisites

- Claude Code CLI installed
- Git repository (for worktree isolation features)
- SQLite3 (included in most systems)
- jq (for JSON processing)

## Installation

```bash
# Install via curl
curl -fsSL https://raw.githubusercontent.com/hanibalsk/claude-threads/main/install.sh | bash

# Verify installation
ct version
```

## Quick Start

### 1. Initialize in Your Project

```bash
cd your-project
ct init
```

This creates a `.claude-threads/` directory with:
- Database for thread management
- Configuration file
- Template directory
- Scripts for orchestration

### 2. Create Your First Thread

The simplest way to get started:

```bash
ct spawn my-task --template developer.md
```

This creates and immediately starts a thread using the developer template.

### 3. Monitor Progress

```bash
# List all threads
ct thread list

# Check specific thread status
ct thread status <thread-id>

# View thread logs
ct thread logs <thread-id>
```

## Understanding Threads

### What is a Thread?

A thread is an isolated Claude Code session that runs a specific task. Threads can:
- Run autonomously in the background (automatic mode)
- Wait for user input (interactive mode)
- Be coordinated by an orchestrator
- Work in isolated git worktrees

### Thread Modes

| Mode | Description | Use Case |
|------|-------------|----------|
| `automatic` | Runs in background with `claude -p` | Long-running tasks, CI fixes |
| `semi-auto` | Automatic with prompts for decisions | Feature development |
| `interactive` | Full user interaction | Pair programming, complex decisions |
| `sleeping` | Waits for triggers | Scheduled tasks, event-driven work |

### Thread Lifecycle

```
CREATED → READY → RUNNING → [WAITING|SLEEPING|BLOCKED] → COMPLETED
                    ↑              ↓
                    └──────────────┘
```

## Working with Worktrees

Worktrees provide git branch isolation for each thread:

```bash
# Create thread with isolated worktree
ct thread create feature-auth --worktree --worktree-base develop

# List active worktrees
ct worktree list

# Cleanup old worktrees
ct worktree cleanup
```

**Why use worktrees?**
- Parallel development on multiple features
- No conflicts between threads
- Clean isolation of changes
- Easy cleanup when done

## Using Templates

Templates define how threads behave:

```bash
# List available templates
ct templates list

# View a template
ct templates show developer.md

# Use a template
ct spawn epic-7a --template bmad-developer.md
```

Templates are stored in `.claude-threads/templates/`.

## Running Multiple Threads

### Start the Orchestrator

```bash
ct orchestrator start
ct orchestrator status
```

The orchestrator:
- Manages thread lifecycle
- Processes events
- Coordinates parallel execution
- Handles triggers for sleeping threads

### Multi-Instance Coordination

Run threads from multiple terminals:

**Terminal 1 (Orchestrator):**
```bash
ct orchestrator start
ct api start
```

**Terminal 2 (External Claude Code):**
```bash
ct remote connect localhost:31337 --token my-token
ct spawn epic-7a --template bmad-developer.md
```

## Claude Code Integration

Use slash commands in Claude Code:

| Command | Description |
|---------|-------------|
| `/threads` | Full thread management |
| `/ct-connect` | Connect to remote orchestrator |
| `/ct-spawn` | Spawn threads remotely |

## Next Steps

- Read about [PR Shepherd](PR-SHEPHERD.md) for automatic CI/review fixes
- Learn about [Multi-Instance Coordination](MULTI-INSTANCE.md)
- Check the [Troubleshooting Guide](TROUBLESHOOTING.md) if you run into issues

## Getting Help

```bash
ct help                    # Main help
ct help <command>          # Command-specific help
ct help getting-started    # This guide (in CLI)
```
