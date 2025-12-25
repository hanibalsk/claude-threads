# Architecture Guide

This document provides a comprehensive architectural overview of claude-threads, focusing on multi-agent coordination, distributed deployment, and system internals.

## System Overview

claude-threads is a multi-agent orchestration system that enables parallel autonomous Claude Code agents to work on complex software engineering tasks.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           claude-threads Architecture                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                        COORDINATION LAYER                            │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐   │   │
│  │  │ Orchestrator │  │  Blackboard  │  │    Session Manager       │   │   │
│  │  │   Daemon     │◄─┤    Events    │◄─┤  (Memory, Checkpoints)   │   │   │
│  │  └──────────────┘  └──────────────┘  └──────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    │                                        │
│                                    ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                          EXECUTION LAYER                             │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────────┐    │   │
│  │  │ Thread 1 │  │ Thread 2 │  │ Thread 3 │  │  PR Shepherd     │    │   │
│  │  │ Agent A  │  │ Agent B  │  │ Agent C  │  │  (Lifecycle Mgr) │    │   │
│  │  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────────┬─────────┘    │   │
│  └───────┼─────────────┼─────────────┼─────────────────┼────────────────┘   │
│          │             │             │                 │                    │
│          ▼             ▼             ▼                 ▼                    │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         ISOLATION LAYER                              │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐   │   │
│  │  │  Worktree 1  │  │  Worktree 2  │  │  PR Base + Forks         │   │   │
│  │  │  /epic-7a    │  │  /epic-8a    │  │  /pr-123-base            │   │   │
│  │  └──────────────┘  └──────────────┘  │   ├─ /conflict-fix       │   │   │
│  │                                       │   └─ /comment-fix       │   │   │
│  │                                       └──────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                          STORAGE LAYER                               │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐   │   │
│  │  │   SQLite     │  │    Logs      │  │     Config (YAML)        │   │   │
│  │  │   Database   │  │  (per-thread)│  │                          │   │   │
│  │  └──────────────┘  └──────────────┘  └──────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. Orchestrator Daemon

The orchestrator is the central coordinator that manages thread lifecycle.

**Responsibilities:**
- Thread creation, starting, stopping, and cleanup
- Event routing between threads
- Resource allocation (worktrees, database connections)
- Health monitoring and recovery

**State Machine:**

```
                    ┌─────────┐
                    │ created │
                    └────┬────┘
                         │ start
                         ▼
    ┌──────────┐    ┌─────────┐
    │  paused  │◄───│ running │───►┌──────────┐
    └────┬─────┘    └────┬────┘    │  blocked │
         │               │         └────┬─────┘
         │               │              │
         └───────┬───────┴──────────────┘
                 │ complete/fail
                 ▼
           ┌───────────┐
           │ completed │
           │  /failed  │
           └───────────┘
```

### 2. Blackboard (Event System)

The blackboard provides asynchronous communication between components.

**Event Flow:**

```
Producer                    Blackboard                    Consumers
   │                            │                             │
   │  bb_publish(type, data)    │                             │
   ├───────────────────────────►│                             │
   │                            │   Store in events table     │
   │                            ├────────────────────────────►│
   │                            │                             │
   │                            │◄────────bb_poll(types)──────│
   │                            ├────────────────────────────►│
   │                            │   Return matching events    │
   │                            │                             │
   │                            │◄────bb_wait_for(type)───────│
   │                            ├─────(blocks until match)───►│
   │                            │                             │
```

**Event Delivery Guarantees:**
- At-least-once delivery (events persist in database)
- Events have TTL (default 24 hours)
- No ordering guarantee for concurrent publishers

### 3. Session Manager

Manages agent state persistence across context windows and restarts.

**Components:**
- **Sessions**: Track thread execution history
- **Checkpoints**: Periodic state snapshots
- **Memory**: Cross-session persistent storage
- **Coordination**: Parent-child session linking

### 4. Worktree Manager

Provides isolated git environments for parallel development.

**Worktree Types:**
| Type | Purpose | Lifecycle |
|------|---------|-----------|
| Thread Worktree | General thread isolation | Thread lifetime |
| PR Base Worktree | PR branch tracking | PR lifetime |
| Fork Worktree | Sub-agent work (conflicts, comments) | Task lifetime |

## Agent Hierarchy

```
                        ┌─────────────────────────┐
                        │   Thread Orchestrator   │
                        │   (Master Controller)   │
                        └───────────┬─────────────┘
                                    │
           ┌────────────────────────┼────────────────────────┐
           │                        │                        │
           ▼                        ▼                        ▼
┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
│  PR Lifecycle    │    │  Story Developer │    │   Issue Fixer    │
│    Shepherd      │    │                  │    │                  │
└────────┬─────────┘    └──────────────────┘    └──────────────────┘
         │
         ├──────────────────────────┐
         │                          │
         ▼                          ▼
┌──────────────────┐    ┌──────────────────┐
│  Merge Conflict  │    │  Review Comment  │
│    Resolver      │    │     Handler      │
└──────────────────┘    └──────────────────┘
```

## Database Schema Overview

```sql
-- Core tables (simplified)
threads         -- Thread state and metadata
events          -- Blackboard events
pr_watches      -- PR lifecycle tracking
pr_comments     -- Review comment status
merge_conflicts -- Conflict resolution tracking

-- Session management
session_history    -- Session lifecycle
checkpoints        -- State snapshots
memory_entries     -- Persistent memory
session_coordination -- Parent-child links

-- Worktree tracking
pr_base_worktrees  -- Base worktrees per PR
pr_worktree_forks  -- Fork worktrees for sub-agents
```

## Multi-Instance Architecture

### Local Multi-Terminal

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Single Machine                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Terminal 1                Terminal 2              Terminal 3           │
│  ┌───────────────┐        ┌───────────────┐       ┌───────────────┐    │
│  │ Orchestrator  │        │ Claude Code   │       │ Claude Code   │    │
│  │ + API Server  │◄───────│ (Remote)      │       │ (Remote)      │    │
│  │ Port: 31337   │        │               │       │               │    │
│  └───────────────┘        └───────────────┘       └───────────────┘    │
│         │                        │                       │             │
│         ▼                        ▼                       ▼             │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                     Shared SQLite Database                       │   │
│  │                  .claude-threads/threads.db                      │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Distributed Multi-Machine

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Network Architecture                             │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Machine A (Orchestrator)                                               │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                       ┌──────────────┐                            │  │
│  │  ct orchestrator      │  API Server  │                            │  │
│  │  ct api start         │  :31337      │◄───────────────────────┐   │  │
│  │                       │              │                        │   │  │
│  │  ┌─────────────┐      └──────────────┘                        │   │  │
│  │  │  Database   │                                              │   │  │
│  │  │  (SQLite)   │                                              │   │  │
│  │  └─────────────┘                                              │   │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                    │    │
│                            HTTPS/TLS                               │    │
│                                                                    │    │
│  Machine B                         Machine C                       │    │
│  ┌─────────────────────────┐      ┌─────────────────────────┐     │    │
│  │  Claude Code Instance   │      │  Claude Code Instance   │     │    │
│  │  ct remote connect A    │──────┤  ct remote connect A    │─────┘    │
│  │                         │      │                         │          │
│  │  ct spawn epic-7a       │      │  ct spawn epic-8a       │          │
│  └─────────────────────────┘      └─────────────────────────┘          │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Production Deployment Pattern

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Production Setup                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐ │
│  │                      Load Balancer (optional)                      │ │
│  │                         nginx / HAProxy                            │ │
│  └────────────────────────────┬──────────────────────────────────────┘ │
│                               │                                         │
│            ┌──────────────────┼──────────────────┐                     │
│            │                  │                  │                     │
│            ▼                  ▼                  ▼                     │
│  ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐          │
│  │  Orchestrator 1 │ │  Orchestrator 2 │ │  Orchestrator 3 │          │
│  │  (Project A)    │ │  (Project B)    │ │  (Project C)    │          │
│  └────────┬────────┘ └────────┬────────┘ └────────┬────────┘          │
│           │                   │                   │                    │
│           ▼                   ▼                   ▼                    │
│  ┌─────────────────────────────────────────────────────────────────┐  │
│  │                    Shared Storage (NFS/EFS)                      │  │
│  │                    /mnt/claude-threads/                          │  │
│  └─────────────────────────────────────────────────────────────────┘  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Communication Patterns

### 1. Parent-Child Agent Communication

```
Parent Agent                    Child Agent
    │                               │
    │  spawn with context           │
    ├──────────────────────────────►│
    │                               │
    │                               │  AGENT_STARTED
    │◄──────────────────────────────┤  (via blackboard)
    │                               │
    │     bb_wait_for(COMPLETED)    │
    │◄ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ │  Working...
    │                               │
    │                               │  AGENT_COMPLETED
    │◄──────────────────────────────┤  {result: ...}
    │                               │
```

### 2. PR Shepherd Coordination

```
PR Shepherd                    Sub-Agents
    │
    │  1. Detect conflict
    ├───────────────────────────────►  Merge Conflict Resolver
    │      (fork worktree)              │
    │                                   │  Resolving...
    │                                   │
    │◄──────────────────────────────────┤  CONFLICT_RESOLVED
    │      (merge back fork)
    │
    │  2. Handle comment
    ├───────────────────────────────►  Comment Handler
    │      (fork worktree)              │
    │                                   │  Fixing...
    │                                   │
    │◄──────────────────────────────────┤  COMMENT_RESPONDED
    │      (merge back fork)
    │
    │  3. Push changes
    ├───────────────────────────────►  Remote
    │
```

### 3. Cross-Instance Thread Spawning

```
Machine B                    Machine A (Orchestrator)
    │                               │
    │  POST /api/threads            │
    ├──────────────────────────────►│
    │  {name, template, context}    │  Create thread
    │                               │
    │  {"id": "thread-123"}         │
    │◄──────────────────────────────┤
    │                               │
    │  POST /api/threads/123/start  │
    ├──────────────────────────────►│
    │                               │  Start in worktree
    │  {"status": "running"}        │
    │◄──────────────────────────────┤
    │                               │
    │  GET /api/threads/123         │
    ├──────────────────────────────►│  (poll for status)
    │                               │
    │  {"status": "completed"}      │
    │◄──────────────────────────────┤
```

## Security Model

### Authentication

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Token-Based Authentication                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Environment Variables:                                                 │
│    N8N_API_TOKEN (server)  ───────►  API Server validates               │
│    CT_API_TOKEN (client)   ◄───────  Bearer token in header             │
│                                                                         │
│  Flow:                                                                  │
│  ┌─────────────┐                    ┌─────────────┐                    │
│  │   Client    │  Authorization:    │   Server    │                    │
│  │             ├───Bearer TOKEN────►│             │                    │
│  │             │                    │  Validate   │                    │
│  │             │◄───200 OK / 401────│  TOKEN      │                    │
│  └─────────────┘                    └─────────────┘                    │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Network Security

```
Production Recommendations:

1. API Binding
   - Default: 127.0.0.1 (localhost only)
   - Remote: Use reverse proxy (nginx) with TLS

2. Token Management
   - Rotate tokens periodically
   - Use environment variables, not config files
   - Different tokens per environment

3. Network Isolation
   - Use private network for orchestrator
   - Expose only through authenticated proxy
```

## Performance Considerations

### Resource Limits

| Resource | Default Limit | Configuration |
|----------|---------------|---------------|
| Concurrent Threads | 10 | `config.yaml: max_threads` |
| Worktrees per Thread | 1 | Automatic |
| Forks per PR Base | 5 | `config.yaml: max_comment_handlers` |
| Event TTL | 24 hours | `config.yaml: event_ttl` |
| Checkpoint Interval | 30 minutes | `config.yaml: checkpoint_interval` |

### Scaling Patterns

```
Small (1-5 threads)         Medium (5-20 threads)       Large (20+ threads)
┌─────────────────┐         ┌─────────────────┐         ┌─────────────────┐
│ Single Machine  │         │ Multi-Terminal  │         │ Multi-Machine   │
│ SQLite DB       │         │ SQLite DB       │         │ SQLite + NFS    │
│ Local Worktrees │         │ Shared Worktrees│         │ Distributed WT  │
└─────────────────┘         └─────────────────┘         └─────────────────┘
```

## Error Handling

### Recovery Patterns

```
Thread Failure
      │
      ├─► Transient Error ───► Retry with backoff
      │
      ├─► Resource Conflict ──► Wait and retry (lock timeout)
      │
      ├─► Agent Error ────────► Escalate to parent/orchestrator
      │
      └─► System Error ───────► Mark as failed, cleanup worktree
```

### Orphan Cleanup

```bash
# Periodic cleanup (run via cron or orchestrator)
ct worktree cleanup --force     # Clean old worktrees
ct worktree reconcile --fix     # Sync DB with filesystem
ct thread cleanup               # Remove completed threads
```

## See Also

- [AGENT-COORDINATION.md](AGENT-COORDINATION.md) - Multi-agent patterns
- [MULTI-INSTANCE.md](MULTI-INSTANCE.md) - Remote deployment
- [WORKTREE-GUIDE.md](WORKTREE-GUIDE.md) - Worktree management
- [EVENT-REFERENCE.md](EVENT-REFERENCE.md) - Event types
