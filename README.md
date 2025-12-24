# claude-threads

[![Version](https://img.shields.io/badge/version-0.2.0-blue.svg)](VERSION)

**Multi-Agent Thread Orchestration Framework for Claude Code**

claude-threads is a bash-based orchestration framework that enables parallel execution of Claude Code agents with shared state. It provides a state machine for thread lifecycle management, a blackboard pattern for inter-thread communication, and integrations with GitHub webhooks and n8n workflows.

## Features

- **Multi-Thread Orchestration** - Run multiple Claude agents in parallel with coordinated state
- **Thread Modes** - Automatic, semi-automatic, interactive, and sleeping modes
- **Blackboard Pattern** - Shared event bus for inter-thread communication
- **Session Management** - Persistent Claude sessions with resume capability
- **SQLite Persistence** - Thread-safe state storage with WAL mode
- **Template System** - Mustache-like templates for prompts and workflows
- **GitHub Integration** - Webhook receiver for PR events, CI status
- **n8n Integration** - HTTP API for workflow automation

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        ORCHESTRATOR                              │
│  (main process - manages thread lifecycle)                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │   Thread 1   │  │   Thread 2   │  │   Thread N   │           │
│  │  (foreground)│  │ (background) │  │   (sleeping) │           │
│  │  interactive │  │  automatic   │  │  scheduled   │           │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘           │
│         │                 │                 │                    │
│         └────────────┬────┴─────────────────┘                    │
│                      │                                           │
│              ┌───────▼───────┐                                   │
│              │  BLACKBOARD   │  (shared state bus)               │
│              │  - events     │                                   │
│              │  - messages   │                                   │
│              │  - artifacts  │                                   │
│              └───────────────┘                                   │
│                                                                   │
│              ┌───────────────┐                                   │
│              │  SQLite DB    │  (persistent, thread-safe)        │
│              │  - threads    │                                   │
│              │  - events     │                                   │
│              │  - sessions   │                                   │
│              └───────────────┘                                   │
└─────────────────────────────────────────────────────────────────┘
```

## Thread Modes

| Mode | Description | Execution |
|------|-------------|-----------|
| **automatic** | Fully autonomous, no interaction | Background with `claude -p` |
| **semi-auto** | Automatic with critical decision prompts | Foreground |
| **interactive** | Full interactive, every step confirmed | Foreground |
| **sleeping** | Waiting for trigger (time, event) | Periodic wake |

## Thread Lifecycle

```
CREATED → READY → RUNNING → [WAITING|SLEEPING|BLOCKED] → COMPLETED
                     ↑              ↓
                     └──────────────┘
```

## Prerequisites

Required tools:
- `sqlite3` - SQLite database engine
- `jq` - JSON processor
- `claude` - [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)
- `git` - Git version control

Optional:
- `gh` - [GitHub CLI](https://cli.github.com/) for GitHub integration
- `yq` - YAML processor for config parsing (falls back to Python/awk)

## Installation

```bash
# Clone the repository
git clone https://github.com/hanibalsk/claude-threads.git
cd claude-threads

# Run the install script
./install.sh

# Or install globally
./install.sh --global
```

After installation, add `~/.claude-threads/bin` to your PATH (for global install) or use the local `ct` command.

## Quick Start

```bash
# Initialize in your project
cd /path/to/your/project
ct init

# Create a new thread
ct thread create "developer" --mode automatic --template prompts/developer.md

# Start the thread
ct thread start <thread-id>

# List threads
ct thread list

# View thread status
ct thread status <thread-id>
```

## Project Structure

```
claude-threads/
├── VERSION                     # Version file (0.2.0)
├── config.example.yaml         # Example configuration
├── bin/
│   └── ct                      # CLI entry point
├── lib/
│   ├── utils.sh                # Common utilities
│   ├── log.sh                  # Logging utilities
│   ├── db.sh                   # SQLite operations
│   ├── state.sh                # Thread state management
│   ├── blackboard.sh           # Event bus operations
│   ├── template.sh             # Template rendering
│   ├── claude.sh               # Claude CLI wrapper
│   └── config.sh               # Configuration management
├── scripts/
│   ├── orchestrator.sh         # Main orchestrator daemon
│   └── thread-runner.sh        # Individual thread executor
├── sql/
│   └── schema.sql              # Database schema
├── templates/
│   ├── prompts/                # Prompt templates
│   └── workflows/              # Workflow templates
├── commands/
│   └── threads.md              # Claude Code slash command
└── docs/
    └── ...                     # Documentation
```

## Configuration

Copy `config.example.yaml` to `.claude-threads/config.yaml` and customize:

```yaml
threads:
  max_concurrent: 5
  default_max_turns: 80

orchestrator:
  poll_interval: 1
  log_level: info

claude:
  command: claude
  permission_mode: acceptEdits

github:
  enabled: true
  webhook_port: 8080
```

Settings can be overridden via environment variables:

```bash
CT_THREADS_MAX_CONCURRENT=10 ct orchestrator start
```

## SQLite Schema

The framework uses SQLite with WAL mode for concurrent access:

- `threads` - Thread state and configuration
- `events` - Blackboard event stream
- `messages` - Inter-thread messages
- `sessions` - Claude session tracking
- `artifacts` - Shared artifacts
- `webhooks` - Incoming webhook events

## Template System

Templates use a simple Mustache-like syntax:

```markdown
---
name: developer
variables:
  - epic_id
  - stories
---

# Developer Agent

You are developing Epic {{epic_id}}.

{{#if stories}}
Stories to implement: {{stories}}
{{/if}}

When complete, output:
```json
{"event": "STORY_COMPLETED", "story_id": "{{story_id}}"}
```
```

## API Reference

### Thread Management

```bash
# Create thread
thread_id=$(thread_create "my-thread" "automatic" "prompts/dev.md")

# Lifecycle
thread_ready "$thread_id"
thread_run "$thread_id"
thread_wait "$thread_id" "reason"
thread_complete "$thread_id"

# Query
thread_get "$thread_id"
thread_list "running"
```

### Blackboard

```bash
# Publish event
bb_publish "STORY_COMPLETED" '{"story_id": "41.1"}' "$thread_id"

# Poll events
events=$(bb_poll "$thread_id")

# Send direct message
bb_send "$target_thread" "REQUEST" '{"action": "review"}'
```

### Claude Execution

```bash
# Execute prompt
session_id=$(claude_start_session "$thread_id")
claude_execute "Implement the feature" "automatic" "$session_id"

# Resume session
claude_resume "$session_id" "Continue from here"
```

## CLI Reference

### ct thread

```bash
ct thread create <name> [options]    # Create a new thread
  --mode <mode>                      # automatic, semi-auto, interactive, sleeping
  --template <file>                  # Prompt template file
  --context <json>                   # Thread context as JSON

ct thread list [status]              # List threads (optionally by status)
ct thread start <id>                 # Start a thread
ct thread stop <id>                  # Stop a thread
ct thread status <id>                # Show thread status
ct thread logs <id>                  # View thread logs
ct thread resume <id>                # Resume interactively
ct thread delete <id>                # Delete a thread
```

### ct orchestrator

```bash
ct orchestrator start                # Start daemon
ct orchestrator stop                 # Stop daemon
ct orchestrator status               # Show status
ct orchestrator restart              # Restart daemon
ct orchestrator tick                 # Run single iteration
```

### ct event

```bash
ct event list                        # List recent events
ct event publish <type> [data]       # Publish an event
```

## Roadmap

- [x] Core infrastructure (v0.1.0)
  - SQLite schema and database operations
  - Thread state management
  - Blackboard pattern implementation
  - Template rendering
  - Configuration system

- [x] Orchestrator (v0.2.0)
  - Main orchestrator daemon
  - Thread runner script
  - Scheduling system
  - CLI tool (`ct`)
  - Claude Code slash command

- [ ] Integrations (v0.3.0)
  - GitHub webhook receiver
  - n8n HTTP API
  - Additional templates

- [ ] BMAD Migration (v1.0.0)
  - BMAD-specific templates
  - Workflow migration
  - Full documentation

## License

MIT License - see [LICENSE](LICENSE)

## Contributing

Contributions welcome! Please read the contributing guidelines first.

## Related Projects

- [BMAD Autopilot](https://github.com/hanibalsk/autopilot) - Original autonomous development orchestrator
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) - Anthropic's CLI for Claude
- [BMAD Method](https://github.com/bmad-method) - Agile development methodology
