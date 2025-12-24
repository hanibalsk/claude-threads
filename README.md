# claude-threads

[![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)](VERSION)

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
- `python3` - Required for webhook and API servers

## Installation

```bash
# Clone the repository
git clone https://github.com/hanibalsk/claude-threads.git
cd claude-threads

# Run the install script
./install.sh

# Or install globally
./install.sh --global

# Or target a specific project directory
./install.sh --target /path/to/your/project
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
├── VERSION                     # Version file (1.0.0)
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
│   ├── threads.md              # /threads slash command
│   └── bmad.md                 # /bmad slash command
├── skills/
│   ├── threads/                # Thread orchestration skill
│   │   └── SKILL.md
│   └── bmad-autopilot/         # BMAD autonomous development skill
│       └── SKILL.md
├── .claude/
│   └── agents/                 # Claude Code agent definitions
│       ├── thread-orchestrator.md
│       ├── story-developer.md
│       ├── code-reviewer.md
│       ├── security-reviewer.md
│       ├── test-writer.md
│       ├── issue-fixer.md
│       ├── pr-manager.md
│       └── explorer.md
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

### ct webhook

```bash
ct webhook start                     # Start GitHub webhook server
ct webhook stop                      # Stop webhook server
ct webhook status                    # Show status
```

### ct api

```bash
ct api start                         # Start REST API server
ct api stop                          # Stop API server
ct api status                        # Show status and endpoints
```

### ct pr (PR Shepherd)

```bash
ct pr watch <pr_number>              # Start watching a PR
ct pr status [pr_number]             # Show PR status (or list all)
ct pr list                           # List all watched PRs
ct pr stop <pr_number>               # Stop watching a PR
ct pr daemon                         # Run shepherd as daemon
```

## PR Shepherd (Automatic PR Feedback Loop)

The PR Shepherd monitors your pull requests and automatically:
1. Detects CI failures and spawns fix threads
2. Detects review change requests and addresses them
3. Waits for approval and optionally auto-merges

### How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                    PR SHEPHERD LOOP                          │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│   WATCHING ───► CI_PENDING ───► CI_PASSED ───► APPROVED     │
│       │              │              │              │         │
│       │              ▼              │              ▼         │
│       │         CI_FAILED           │         MERGED         │
│       │              │              │                        │
│       │              ▼              │                        │
│       │          FIXING ────────────┘                        │
│       │         (spawn fix                                   │
│       │          thread)                                     │
│       │              │                                       │
│       │              ▼                                       │
│       └──────── REVIEW_PENDING ──► CHANGES_REQUESTED         │
│                                           │                  │
│                                           ▼                  │
│                                       FIXING ────────────►   │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Usage

```bash
# Start watching a PR
ct pr watch 123

# The shepherd will:
# 1. Poll CI status every 30 seconds
# 2. If CI fails, spawn a fix thread using prompts/pr-fix.md
# 3. Wait for the fix thread to complete
# 4. Check CI again
# 5. If CI passes, wait for review
# 6. If changes requested, spawn another fix thread
# 7. Repeat until approved and merged (or max attempts reached)

# Check status
ct pr status 123

# Run shepherd as background daemon
ct pr daemon
```

### Configuration

```yaml
# config.yaml
pr_shepherd:
  max_fix_attempts: 5       # Max auto-fix attempts before giving up
  ci_poll_interval: 30      # Seconds between CI checks
  idle_poll_interval: 300   # Seconds when no active PRs
  push_cooldown: 120        # Seconds to wait after push
  auto_merge: false         # Auto-merge when ready
```

### Adaptive Polling

The orchestrator uses adaptive polling to reduce resource usage:
- **Active**: 1-second polling when threads are running or PRs are active
- **Idle**: 10-second polling when system is idle for 30+ ticks

```yaml
orchestrator:
  poll_interval: 1          # Active polling interval
  idle_poll_interval: 10    # Idle polling interval
  idle_threshold: 30        # Ticks before switching to idle
```

## GitHub Webhook Integration

The webhook server receives GitHub events and publishes them to the blackboard:

```bash
# Start webhook server
ct webhook start --port 8080

# Configure in GitHub repository settings:
# Webhook URL: http://your-server:8080/webhook
# Content type: application/json
# Events: Pull requests, Check runs, Issue comments
```

Supported events:
- `pull_request` → `PR_OPENED`, `PR_CLOSED`, `PR_MERGED`
- `pull_request_review` → `PR_APPROVED`, `PR_CHANGES_REQUESTED`
- `check_run` → `CI_PASSED`, `CI_FAILED`
- `issue_comment` → `PR_COMMENT`
- `push` → `PUSH`

## n8n REST API

The API server provides a REST interface for automation tools:

```bash
# Start API server
ct api start --port 8081

# Example: Create thread via API
curl -X POST http://localhost:8081/api/threads \
  -H "Content-Type: application/json" \
  -d '{"name": "developer", "mode": "automatic"}'

# Example: Publish event
curl -X POST http://localhost:8081/api/events \
  -H "Content-Type: application/json" \
  -d '{"type": "TASK_STARTED", "data": {"task_id": "123"}}'
```

API Endpoints:
- `GET /api/health` - Health check
- `GET /api/status` - System status
- `GET /api/threads` - List threads
- `POST /api/threads` - Create thread
- `GET /api/threads/:id` - Get thread
- `POST /api/threads/:id/start` - Start thread
- `POST /api/threads/:id/stop` - Stop thread
- `DELETE /api/threads/:id` - Delete thread
- `GET /api/events` - List events
- `POST /api/events` - Publish event
- `GET /api/messages/:id` - Get messages
- `POST /api/messages` - Send message

## Prompt Templates

Included templates in `templates/prompts/`:

| Template | Description |
|----------|-------------|
| `developer.md` | Epic/story implementation agent |
| `reviewer.md` | Code review agent |
| `planner.md` | Feature planning and breakdown |
| `pr-monitor.md` | Pull request monitoring |
| `fixer.md` | Issue/feedback fixing |
| `tester.md` | Test writing and execution |
| `bmad-developer.md` | BMAD epic/story developer |
| `bmad-reviewer.md` | BMAD code review agent |
| `bmad-pr-manager.md` | BMAD PR lifecycle manager |
| `bmad-fixer.md` | BMAD issue fixer |

## Workflow Templates

Included workflows in `templates/workflows/`:

| Workflow | Description |
|----------|-------------|
| `epic-development.yaml` | Full epic development lifecycle |
| `pr-review.yaml` | Automated PR review process |
| `feature-planning.yaml` | Feature breakdown workflow |
| `bmad-autopilot.yaml` | Full autonomous BMAD development |

## Slash Commands

Claude Code slash commands in `commands/`:

| Command | Description |
|---------|-------------|
| `/threads` | Manage thread orchestration - create, start, stop, monitor threads |
| `/bmad` | Run BMAD Autopilot autonomous development |

### Usage

```bash
# In Claude Code, use:
/threads list
/threads create my-agent --mode automatic --template developer.md
/threads start <id>

# BMAD autopilot:
/bmad 7A              # Process specific epic
/bmad "7A 8A 10B"     # Multiple epics
/bmad                 # All epics
```

## Skills

Skills in `skills/` provide specialized agent capabilities:

| Skill | Description |
|-------|-------------|
| `threads` | Thread orchestration - parallel agents, events, scheduling |
| `bmad-autopilot` | BMAD autonomous development - epics, PRs, CI |

Skills are activated automatically when Claude Code detects relevant user requests.

## Claude Code Agents

Built-in agents in `.claude/agents/` for multi-agent orchestration:

| Agent | Model | Purpose |
|-------|-------|---------|
| `thread-orchestrator` | Sonnet | Coordinate multi-agent workflows |
| `story-developer` | Sonnet | Implement features with TDD |
| `code-reviewer` | Sonnet | Quality and best practices review |
| `security-reviewer` | Sonnet | Security audit and vulnerability detection |
| `test-writer` | Sonnet | Write comprehensive tests |
| `issue-fixer` | Sonnet | Fix CI and review issues |
| `pr-manager` | Sonnet | PR lifecycle management |
| `explorer` | Haiku | Fast codebase exploration |

Agents are invoked via Claude Code's Task tool:

```
User: "Review this code for security issues"
→ Claude automatically delegates to security-reviewer agent
```

See [docs/AGENTS.md](docs/AGENTS.md) for detailed documentation on creating and using agents.

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

- [x] Integrations (v0.3.0)
  - GitHub webhook receiver
  - n8n REST API server
  - Additional prompt templates (planner, pr-monitor, fixer, tester)
  - Workflow templates (epic-development, pr-review, feature-planning)

- [x] BMAD Migration (v1.0.0)
  - BMAD-specific templates (bmad-developer, bmad-reviewer, bmad-pr-manager, bmad-fixer)
  - Workflow migration from autopilot (bmad-autopilot.yaml)
  - Migration guide (docs/MIGRATION.md)
  - Full documentation

## BMAD Autopilot Integration

claude-threads provides a complete replacement for the original `bmad-autopilot.sh` script with enhanced capabilities:

```bash
# Quick start with BMAD
ct init
ct thread create bmad-autopilot --mode automatic --template prompts/bmad-developer.md

# Or run the full workflow
ct workflow start bmad-autopilot --context '{"epic_pattern": "7A"}'
```

Key advantages over the original script:
- **Parallel epic processing** - Multiple epics can be developed concurrently
- **Resilient state** - SQLite persistence survives crashes
- **Real-time events** - GitHub webhooks instead of polling
- **Modular agents** - Separate threads for development, review, PR management, fixing

See [docs/MIGRATION.md](docs/MIGRATION.md) for a complete migration guide.

## License

MIT License - see [LICENSE](LICENSE)

## Contributing

Contributions welcome! Please read the contributing guidelines first.

## Related Projects

- [BMAD Autopilot](https://github.com/hanibalsk/autopilot) - Original autonomous development orchestrator
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) - Anthropic's CLI for Claude
- [BMAD Method](https://github.com/bmad-method) - Agile development methodology
