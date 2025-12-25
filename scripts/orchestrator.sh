#!/usr/bin/env bash
#
# orchestrator.sh - Main orchestrator daemon for claude-threads
#
# Manages thread lifecycle, scheduling, and coordination.
# Runs as a daemon process monitoring threads and events.
#
# Usage:
#   ./scripts/orchestrator.sh start       # Start orchestrator daemon
#   ./scripts/orchestrator.sh stop        # Stop orchestrator
#   ./scripts/orchestrator.sh status      # Show status
#   ./scripts/orchestrator.sh tick        # Run one iteration (for cron)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Source libraries
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/log.sh"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/db.sh"
source "$ROOT_DIR/lib/git.sh"
source "$ROOT_DIR/lib/state.sh"
source "$ROOT_DIR/lib/blackboard.sh"
source "$ROOT_DIR/lib/progress.sh"

# Check if git-poller is available (as separate script, not sourced)
GIT_POLLER_SCRIPT="$SCRIPT_DIR/git-poller.sh"
if [[ -f "$GIT_POLLER_SCRIPT" && -x "$GIT_POLLER_SCRIPT" ]]; then
    GIT_POLLER_AVAILABLE=1
else
    GIT_POLLER_AVAILABLE=0
fi

# ============================================================
# Configuration
# ============================================================

DATA_DIR=""
PID_FILE=""
RUNNING=0
FOREGROUND_THREAD=""

# Adaptive polling state
_IDLE_TICKS=0
_LAST_ACTIVITY_TICK=0

# ============================================================
# Initialization
# ============================================================

init() {
    DATA_DIR="${CT_DATA_DIR:-$(ct_data_dir)}"
    PID_FILE="$DATA_DIR/orchestrator.pid"

    export CT_PROJECT_ROOT="${CT_PROJECT_ROOT:-$(pwd)}"

    # Load configuration
    config_load "$DATA_DIR/config.yaml"

    # Initialize logging
    log_init "orchestrator" "$DATA_DIR/logs/orchestrator.log"
    log_set_level "$(config_get 'orchestrator.log_level' 'info')"

    # Initialize database
    db_init "$DATA_DIR"
    bb_init "$DATA_DIR"

    log_debug "Orchestrator initialized"
}

# ============================================================
# Git Poller Management
# ============================================================

start_git_poller() {
    if [[ $GIT_POLLER_AVAILABLE -ne 1 ]]; then
        log_debug "Git poller not available, skipping"
        return 0
    fi

    # Check if git poller should be auto-started
    local auto_start
    auto_start=$(config_get_bool 'pr_lifecycle.auto_start_poller' true)

    if [[ "$auto_start" != "true" ]]; then
        log_debug "Git poller auto-start disabled"
        return 0
    fi

    # Check if there are any active PR watches
    local active_prs=0
    if db_scalar "SELECT 1 FROM sqlite_master WHERE type='table' AND name='pr_watches'" 2>/dev/null | grep -q 1; then
        active_prs=$(db_scalar "SELECT COUNT(*) FROM pr_watches WHERE state NOT IN ('completed', 'merged', 'closed')" 2>/dev/null) || active_prs=0
    fi

    if [[ "$active_prs" =~ ^[0-9]+$ && $active_prs -gt 0 ]]; then
        log_info "Starting git poller (active PR watches: $active_prs)"
        "$GIT_POLLER_SCRIPT" start --data-dir "$DATA_DIR" || {
            log_warn "Failed to start git poller"
        }
    else
        log_debug "No active PR watches, git poller not needed"
    fi
}

stop_git_poller() {
    if [[ $GIT_POLLER_AVAILABLE -ne 1 ]]; then
        return 0
    fi

    if [[ -f "$DATA_DIR/git-poller.pid" ]]; then
        log_info "Stopping git poller..."
        "$GIT_POLLER_SCRIPT" stop --data-dir "$DATA_DIR" || true
    fi
}

is_git_poller_running() {
    if [[ -f "$DATA_DIR/git-poller.pid" ]]; then
        local pid
        pid=$(cat "$DATA_DIR/git-poller.pid")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# ============================================================
# Controller Agent Management
# ============================================================

CONTROLLER_THREAD_ID=""

# Start controller agent if enabled in config
start_controller_agent() {
    local enabled
    enabled=$(config_get 'orchestrator_control.enabled' 'false')

    if [[ "$enabled" != "true" ]]; then
        log_debug "Controller agent disabled in config"
        return 0
    fi

    # Check if controller already running
    if is_controller_running; then
        log_debug "Controller agent already running"
        return 0
    fi

    log_info "Starting controller agent..."

    local mode check_interval
    mode=$(config_get 'orchestrator_control.mode' 'automatic')
    check_interval=$(config_get 'orchestrator_control.check_interval' '60')

    # Check if controller template exists
    local template_file="$DATA_DIR/templates/prompts/orchestrator-control.md"
    if [[ ! -f "$template_file" ]]; then
        log_warn "Controller template not found: $template_file"
        log_info "Creating default controller template..."
        _create_controller_template "$template_file"
    fi

    # Create controller thread context
    local context
    context=$(jq -n \
        --arg mode "$mode" \
        --arg interval "$check_interval" \
        --arg auto_shepherds "$(config_get 'orchestrator_control.auto_spawn_shepherds' 'true')" \
        --arg max_shepherds "$(config_get 'orchestrator_control.max_concurrent_shepherds' '5')" \
        --arg auto_escalations "$(config_get 'orchestrator_control.auto_handle_escalations' 'false')" \
        '{
            mode: $mode,
            check_interval: ($interval | tonumber),
            auto_spawn_shepherds: ($auto_shepherds == "true"),
            max_concurrent_shepherds: ($max_shepherds | tonumber),
            auto_handle_escalations: ($auto_escalations == "true"),
            role: "orchestrator-controller"
        }')

    # Spawn controller thread
    local thread_runner="$DATA_DIR/scripts/thread-runner.sh"

    CONTROLLER_THREAD_ID=$("$thread_runner" \
        --create \
        --name "orchestrator-controller" \
        --mode "$mode" \
        --template "prompts/orchestrator-control.md" \
        --context "$context" \
        --data-dir "$DATA_DIR" \
        --background 2>/dev/null) || {
        log_error "Failed to start controller agent"
        return 1
    }

    log_info "Controller agent started: $CONTROLLER_THREAD_ID"

    # Store controller thread ID
    echo "$CONTROLLER_THREAD_ID" > "$DATA_DIR/controller.thread"

    bb_publish "CONTROLLER_STARTED" "{\"thread_id\": \"$CONTROLLER_THREAD_ID\"}" "orchestrator"
}

# Stop controller agent
stop_controller_agent() {
    if [[ -f "$DATA_DIR/controller.thread" ]]; then
        local thread_id
        thread_id=$(cat "$DATA_DIR/controller.thread")

        if [[ -n "$thread_id" ]]; then
            log_info "Stopping controller agent: $thread_id"

            # Mark thread as completed/stopped
            db_thread_set_status "$thread_id" "completed" 2>/dev/null || true

            bb_publish "CONTROLLER_STOPPED" "{\"thread_id\": \"$thread_id\"}" "orchestrator"
        fi

        rm -f "$DATA_DIR/controller.thread"
    fi

    CONTROLLER_THREAD_ID=""
}

# Check if controller is running
is_controller_running() {
    if [[ ! -f "$DATA_DIR/controller.thread" ]]; then
        return 1
    fi

    local thread_id
    thread_id=$(cat "$DATA_DIR/controller.thread")

    if [[ -z "$thread_id" ]]; then
        return 1
    fi

    local status
    status=$(db_scalar "SELECT status FROM threads WHERE id = $(db_quote "$thread_id")" 2>/dev/null)

    [[ "$status" == "running" ]]
}

# Get controller thread ID
get_controller_thread_id() {
    if [[ -f "$DATA_DIR/controller.thread" ]]; then
        cat "$DATA_DIR/controller.thread"
    fi
}

# Create default controller template
_create_controller_template() {
    local template_file="$1"

    mkdir -p "$(dirname "$template_file")"

    cat > "$template_file" << 'TEMPLATE_EOF'
# Orchestrator Controller

You are the orchestrator controller agent for claude-threads. Your role is to monitor the system, coordinate agents, and make intelligent decisions.

## System Context

- Mode: {{mode}}
- Check Interval: {{check_interval}} seconds
- Auto-spawn Shepherds: {{auto_spawn_shepherds}}
- Max Concurrent Shepherds: {{max_concurrent_shepherds}}
- Auto-handle Escalations: {{auto_handle_escalations}}

## Your Responsibilities

1. **Monitor System Health**
   - Check orchestrator status regularly
   - Monitor running threads
   - Watch for blocked or failed threads

2. **Coordinate PR Shepherds**
   - Spawn shepherds for watched PRs (if auto_spawn_shepherds is true)
   - Monitor shepherd progress
   - Handle shepherd escalations

3. **Handle Events**
   - Process ESCALATION_NEEDED events
   - React to PR_WATCH_REQUESTED events
   - Handle PR_READY_FOR_MERGE events

4. **Make Decisions**
   - Determine when to spawn new agents
   - Decide on conflict resolution strategies
   - Escalate to user when needed

## Available Commands

```bash
# Check system status
ct orchestrator status

# List threads
ct thread list
ct thread list running

# Manage PRs
ct pr list
ct pr status <number>
ct pr watch <number>

# Publish events
ct event publish <type> '<json>'

# View recent events
ct event list
```

## Control Loop

Every {{check_interval}} seconds:

1. Run `ct orchestrator status` to check health
2. Run `ct thread list running` to see active threads
3. Check for pending events that need handling
4. Take appropriate actions based on findings
5. Log status update

## Event Handling

When you see events:
- **ESCALATION_NEEDED**: Analyze and either resolve or notify user
- **PR_WATCH_REQUESTED**: Spawn a PR shepherd if auto_spawn_shepherds is true
- **PR_READY_FOR_MERGE**: Merge if auto-merge enabled, otherwise notify
- **MERGE_CONFLICT_DETECTED**: Spawn conflict resolver or block

## Decision Making

For each decision, consider:
1. Current system load (running threads count)
2. Configuration settings
3. Whether to act autonomously or escalate

When in doubt, log the situation and continue monitoring.
TEMPLATE_EOF

    log_info "Created controller template: $template_file"
}

# ============================================================
# Daemon Control
# ============================================================

is_running() {
    ct_is_pid_running "$PID_FILE"
}

# ============================================================
# Progress Display
# ============================================================

# Show progress for all running threads
show_running_progress() {
    local running_threads
    running_threads=$(db_query "SELECT id, name FROM threads WHERE status = 'running' ORDER BY updated_at DESC LIMIT 10")

    if [[ -z "$running_threads" || "$running_threads" == "[]" ]]; then
        echo "  No running threads"
        return
    fi

    echo "$running_threads" | jq -r '.[] | "\(.id)|\(.name)"' | while IFS='|' read -r thread_id thread_name; do
        echo "  [$thread_name] ($thread_id)"

        local progress
        progress=$(progress_get "$thread_id")

        if [[ -n "$progress" && "$progress" != "{}" ]]; then
            local pct step output_lines last_output
            pct=$(echo "$progress" | jq -r '.percentage // 0')
            step=$(echo "$progress" | jq -r '.current_step // "Running"')
            output_lines=$(echo "$progress" | jq -r '.output_lines // 0')
            last_output=$(echo "$progress" | jq -r '.last_output // ""' | head -c 50)

            echo "    $(progress_bar "$pct") - $step"
            if [[ -n "$last_output" && "$last_output" != "null" ]]; then
                echo "    └─ $last_output..."
            fi
            echo "    Lines: $output_lines"
        else
            echo "    (no progress data)"
        fi
        echo ""
    done
}

# Show progress for a specific thread
show_thread_progress() {
    local thread_id="$1"

    local thread_json
    thread_json=$(db_thread_get "$thread_id")

    if [[ -z "$thread_json" || "$thread_json" == "null" ]]; then
        echo "Thread not found: $thread_id"
        return 1
    fi

    local name status
    name=$(echo "$thread_json" | jq -r '.name')
    status=$(echo "$thread_json" | jq -r '.status')

    echo "Thread: $name ($thread_id)"
    echo "Status: $status"
    echo ""

    progress_format "$thread_id"

    echo ""
    echo "Recent Output:"
    echo "--------------"
    progress_get_output "$thread_id" 10 "$DATA_DIR" | sed 's/^/  /'
}

# Watch threads with live updates
watch_threads() {
    local interval="${1:-2}"
    local thread_filter="${2:-}"

    echo "Watching threads (Ctrl+C to stop)..."
    echo ""

    while true; do
        # Clear screen
        printf "\033[H\033[2J"

        echo "claude-threads Live Monitor ($(date '+%H:%M:%S'))"
        echo "=============================================="
        echo ""

        if [[ -n "$thread_filter" ]]; then
            # Watch specific thread
            show_thread_progress "$thread_filter"
        else
            # Watch all running threads
            local running
            running=$(db_scalar "SELECT COUNT(*) FROM threads WHERE status = 'running'")

            if [[ "$running" -gt 0 ]]; then
                echo "Running Threads: $running"
                echo ""
                show_running_progress
            else
                echo "No running threads"
                echo ""

                # Show recently completed
                echo "Recently Completed:"
                echo "-------------------"
                db_query "SELECT name, status, updated_at FROM threads
                          WHERE status IN ('completed', 'failed')
                          ORDER BY updated_at DESC LIMIT 5" | \
                    jq -r '.[] | "  [\(.status)] \(.name) at \(.updated_at)"'
            fi
        fi

        sleep "$interval"
    done
}

start_daemon() {
    if is_running; then
        log_warn "Orchestrator already running"
        echo "Orchestrator already running (PID: $(cat "$PID_FILE"))"
        exit 1
    fi

    log_info "Starting orchestrator daemon..."

    # Fork to background
    (
        # Use $BASHPID to get actual subshell PID (not $$, which is parent's PID)
        local my_pid="$BASHPID"

        # Use atomic PID file creation to prevent race conditions
        if ! ct_atomic_create_pid_file "$PID_FILE" "$my_pid"; then
            log_error "Failed to create PID file - another instance may have started"
            exit 1
        fi
        RUNNING=1

        # Ensure PID file is cleaned up on exit
        trap 'ct_remove_pid_file "$PID_FILE" '"$my_pid" EXIT

        main_loop
    ) &

    local pid=$!

    # Wait briefly for the background process to create PID file
    sleep 0.2

    # Verify PID file was created with correct PID
    if [[ -f "$PID_FILE" ]]; then
        echo "Orchestrator started (PID: $pid)"
        log_info "Orchestrator daemon started: PID=$pid"

        # Start git poller if there are active PR watches
        start_git_poller

        # Start controller agent if enabled
        start_controller_agent
    else
        echo "Failed to start orchestrator"
        log_error "Orchestrator failed to start"
        exit 1
    fi
}

stop_daemon() {
    # Stop controller agent first
    stop_controller_agent

    # Stop git poller
    stop_git_poller

    if ! is_running; then
        echo "Orchestrator not running"
        return 0
    fi

    local pid
    pid=$(cat "$PID_FILE")

    log_info "Stopping orchestrator (PID: $pid)..."

    kill -TERM "$pid" 2>/dev/null || true

    # Wait for graceful shutdown
    local timeout=10
    while [[ $timeout -gt 0 ]] && kill -0 "$pid" 2>/dev/null; do
        sleep 1
        ((timeout--))
    done

    if kill -0 "$pid" 2>/dev/null; then
        log_warn "Force killing orchestrator"
        kill -KILL "$pid" 2>/dev/null || true
    fi

    rm -f "$PID_FILE"
    echo "Orchestrator stopped"
    log_info "Orchestrator stopped"
}

show_status() {
    echo "claude-threads Orchestrator Status"
    echo "==================================="
    echo ""

    if is_running; then
        echo "Status: Running (PID: $(cat "$PID_FILE"))"
    else
        echo "Status: Stopped"
    fi

    echo ""
    echo "Threads:"
    echo "--------"

    # Count by status
    local created ready running waiting sleeping blocked completed failed
    created=$(db_scalar "SELECT COUNT(*) FROM threads WHERE status = 'created'")
    ready=$(db_scalar "SELECT COUNT(*) FROM threads WHERE status = 'ready'")
    running=$(db_scalar "SELECT COUNT(*) FROM threads WHERE status = 'running'")
    waiting=$(db_scalar "SELECT COUNT(*) FROM threads WHERE status = 'waiting'")
    sleeping=$(db_scalar "SELECT COUNT(*) FROM threads WHERE status = 'sleeping'")
    blocked=$(db_scalar "SELECT COUNT(*) FROM threads WHERE status = 'blocked'")
    completed=$(db_scalar "SELECT COUNT(*) FROM threads WHERE status = 'completed'")
    failed=$(db_scalar "SELECT COUNT(*) FROM threads WHERE status = 'failed'")

    echo "  Created:   $created"
    echo "  Ready:     $ready"
    echo "  Running:   $running"
    echo "  Waiting:   $waiting"
    echo "  Sleeping:  $sleeping"
    echo "  Blocked:   $blocked"
    echo "  Completed: $completed"
    echo "  Failed:    $failed"

    # Show running thread progress
    if [[ "$running" -gt 0 ]]; then
        echo ""
        echo "Running Threads Progress:"
        echo "-------------------------"
        show_running_progress
    fi

    echo ""
    echo "Recent Events:"
    echo "--------------"
    db_query "SELECT timestamp, type, source FROM events ORDER BY timestamp DESC LIMIT 5" | \
        jq -r '.[] | "  \(.timestamp) \(.type) (\(.source))"'

    echo ""
    echo "Worktrees:"
    echo "----------"
    local active_worktrees
    active_worktrees=$(db_scalar "SELECT COUNT(*) FROM worktrees WHERE status = 'active'" 2>/dev/null || echo 0)
    echo "  Active: $active_worktrees"

    if [[ $active_worktrees -gt 0 ]]; then
        db_query "SELECT w.thread_id, w.branch, t.name, w.commits_ahead, w.is_dirty
                  FROM worktrees w
                  JOIN threads t ON w.thread_id = t.id
                  WHERE w.status = 'active'
                  LIMIT 5" 2>/dev/null | \
            jq -r '.[] | "    \(.thread_id[0:8])... \(.branch) (\(.name)) +\(.commits_ahead)\(if .is_dirty == 1 then " [dirty]" else "" end)"' 2>/dev/null || true
    fi

    echo ""
    echo "Controller Agent:"
    echo "-----------------"
    if is_controller_running; then
        local controller_id
        controller_id=$(get_controller_thread_id)
        echo "  Status: Running ($controller_id)"

        # Show controller progress if available
        local ctrl_progress
        ctrl_progress=$(progress_get "$controller_id" 2>/dev/null)
        if [[ -n "$ctrl_progress" && "$ctrl_progress" != "{}" ]]; then
            local step
            step=$(echo "$ctrl_progress" | jq -r '.current_step // "Monitoring"')
            echo "  Activity: $step"
        fi
    else
        local enabled
        enabled=$(config_get 'orchestrator_control.enabled' 'false')
        if [[ "$enabled" == "true" ]]; then
            echo "  Status: Not Running (should be started)"
        else
            echo "  Status: Disabled (set orchestrator_control.enabled: true)"
        fi
    fi

    echo ""
    echo "Git Poller:"
    echo "-----------"
    if is_git_poller_running; then
        local poller_pid
        poller_pid=$(cat "$DATA_DIR/git-poller.pid" 2>/dev/null || echo "unknown")
        echo "  Status: Running (PID: $poller_pid)"
    else
        echo "  Status: Stopped"
    fi

    # Show PR watches if table exists
    if db_scalar "SELECT 1 FROM sqlite_master WHERE type='table' AND name='pr_watches'" 2>/dev/null | grep -q 1; then
        echo ""
        echo "PR Lifecycle:"
        echo "-------------"

        local active_watches pending_comments active_conflicts
        active_watches=$(db_scalar "SELECT COUNT(*) FROM pr_watches WHERE state NOT IN ('completed', 'merged', 'closed')" 2>/dev/null || echo 0)
        pending_comments=$(db_scalar "SELECT COUNT(*) FROM pr_comments WHERE state = 'pending'" 2>/dev/null || echo 0)
        active_conflicts=$(db_scalar "SELECT COUNT(*) FROM merge_conflicts WHERE resolution_status IN ('detected', 'resolving')" 2>/dev/null || echo 0)

        echo "  Watched PRs:      $active_watches"
        echo "  Pending Comments: $pending_comments"
        echo "  Active Conflicts: $active_conflicts"

        # Show active PR agents
        local shepherd_agents conflict_agents comment_agents
        shepherd_agents=$(db_scalar "SELECT COUNT(*) FROM threads WHERE name LIKE 'pr-shepherd-%' AND status IN ('running', 'ready')")
        conflict_agents=$(db_scalar "SELECT COUNT(*) FROM threads WHERE name LIKE 'conflict-resolver-%' AND status IN ('running', 'ready')")
        comment_agents=$(db_scalar "SELECT COUNT(*) FROM threads WHERE name LIKE 'comment-handler-%' AND status IN ('running', 'ready')")

        echo ""
        echo "  Active Agents:"
        echo "    PR Shepherds:       $shepherd_agents"
        echo "    Conflict Resolvers: $conflict_agents"
        echo "    Comment Handlers:   $comment_agents"

        # Show watched PRs
        if [[ "$active_watches" -gt 0 ]]; then
            echo ""
            echo "  Watched PRs:"
            db_query "SELECT pr_number, branch, state, comments_pending, has_merge_conflict
                      FROM pr_watches
                      WHERE state NOT IN ('completed', 'merged', 'closed')
                      LIMIT 5" 2>/dev/null | \
                jq -r '.[] | "    PR #\(.pr_number) (\(.branch)) - \(.state)\(if .comments_pending > 0 then " [\(.comments_pending) comments]" else "" end)\(if .has_merge_conflict == 1 then " [CONFLICT]" else "" end)"' 2>/dev/null || true
        fi
    fi

    echo ""
    echo "Configuration:"
    echo "--------------"
    echo "  Max concurrent: $(config_get 'threads.max_concurrent' 5)"
    echo "  Poll interval:  $(config_get 'orchestrator.poll_interval' 1)s"
    echo "  Data directory: $DATA_DIR"
}

# ============================================================
# Main Loop
# ============================================================

main_loop() {
    log_info "Orchestrator main loop started"

    local base_poll_interval idle_poll_interval idle_threshold
    base_poll_interval=$(config_get_int 'orchestrator.poll_interval' 1)
    idle_poll_interval=$(config_get_int 'orchestrator.idle_poll_interval' 10)
    idle_threshold=$(config_get_int 'orchestrator.idle_threshold' 30)

    while [[ $RUNNING -eq 1 ]]; do
        tick

        # Adaptive polling: use longer interval when idle
        local current_interval
        current_interval=$(get_adaptive_interval "$base_poll_interval" "$idle_poll_interval" "$idle_threshold")

        sleep "$current_interval"
    done

    log_info "Orchestrator main loop ended"
}

# Calculate adaptive polling interval based on activity
get_adaptive_interval() {
    local base_interval="$1"
    local idle_interval="$2"
    local idle_threshold="$3"

    # Check for any activity indicators
    local has_activity=0

    # Check running threads
    local running_count
    running_count=$(db_scalar "SELECT COUNT(*) FROM threads WHERE status = 'running'")
    [[ $running_count -gt 0 ]] && has_activity=1

    # Check ready threads
    local ready_count
    ready_count=$(db_scalar "SELECT COUNT(*) FROM threads WHERE status = 'ready'")
    [[ $ready_count -gt 0 ]] && has_activity=1

    # Check pending events
    local pending_events
    pending_events=$(db_scalar "SELECT COUNT(*) FROM events WHERE processed = 0")
    [[ $pending_events -gt 0 ]] && has_activity=1

    # Check active PR watches (if pr_watches table exists)
    local active_prs=0
    if db_scalar "SELECT 1 FROM sqlite_master WHERE type='table' AND name='pr_watches'" 2>/dev/null | grep -q 1; then
        active_prs=$(db_scalar "SELECT COUNT(*) FROM pr_watches WHERE state NOT IN ('merged', 'closed')" 2>/dev/null) || active_prs=0
    fi
    [[ "$active_prs" =~ ^[0-9]+$ && $active_prs -gt 0 ]] && has_activity=1

    if [[ $has_activity -eq 1 ]]; then
        _IDLE_TICKS=0
        _LAST_ACTIVITY_TICK=$_TICK_COUNT
        echo "$base_interval"
    else
        ((_IDLE_TICKS++)) || true

        if [[ $_IDLE_TICKS -ge $idle_threshold ]]; then
            log_trace "System idle, using longer poll interval ($idle_interval s)"
            echo "$idle_interval"
        else
            echo "$base_interval"
        fi
    fi
}

# Single iteration of the main loop
tick() {
    log_trace "Orchestrator tick"

    # 1. Process blackboard events
    process_events

    # 2. Check scheduled threads (wake sleeping ones)
    check_scheduled

    # 3. Monitor running threads
    monitor_threads

    # 4. Start pending threads
    start_pending_threads

    # 5. Cleanup old data
    periodic_cleanup
}

# ============================================================
# Event Processing
# ============================================================

process_events() {
    local max_events
    max_events=$(config_get_int 'blackboard.max_events_per_poll' 100)

    # Security: sanitize max_events to prevent SQL injection
    max_events=$(ct_sanitize_int "$max_events" 100 1 1000)

    # Get unprocessed events
    local events
    events=$(db_query "SELECT * FROM events WHERE processed = 0 ORDER BY timestamp ASC LIMIT $max_events")

    local count
    count=$(echo "$events" | jq 'length')

    if [[ $count -eq 0 ]]; then
        return
    fi

    log_debug "Processing $count events"

    echo "$events" | jq -c '.[]' | while read -r event; do
        local event_id type source targets
        event_id=$(echo "$event" | jq -r '.id')
        type=$(echo "$event" | jq -r '.type')
        source=$(echo "$event" | jq -r '.source')
        targets=$(echo "$event" | jq -r '.targets')

        log_debug "Event: $type from $source"

        # Route event to target threads
        if [[ "$targets" == "*" ]]; then
            # Broadcast to all active threads
            route_event_broadcast "$event"
        else
            # Send to specific threads
            route_event_targeted "$event" "$targets"
        fi

        # Mark as processed
        db_event_mark_processed "$event_id"
    done
}

route_event_broadcast() {
    local event="$1"
    local type
    type=$(echo "$event" | jq -r '.type')

    # Handle orchestrator-level events
    case "$type" in
        THREAD_BLOCKED)
            handle_blocked_thread "$event"
            ;;
        THREAD_COMPLETED)
            handle_completed_thread "$event"
            ;;
        # PR Lifecycle events
        MERGE_CONFLICT_DETECTED)
            handle_merge_conflict "$event"
            ;;
        REVIEW_COMMENTS_PENDING)
            handle_review_comments "$event"
            ;;
        PR_READY_FOR_MERGE)
            handle_pr_ready "$event"
            ;;
        ESCALATION_NEEDED)
            handle_escalation "$event"
            ;;
        PR_WATCH_ADDED)
            # Start git poller if not running when new PR watch is added
            if ! is_git_poller_running && [[ $GIT_POLLER_AVAILABLE -eq 1 ]]; then
                start_git_poller
            fi
            ;;
    esac
}

route_event_targeted() {
    local event="$1"
    local targets="$2"

    # Parse targets and send messages
    echo "$targets" | jq -r '.[]' 2>/dev/null | while read -r thread_id; do
        [[ -z "$thread_id" ]] && continue

        local type data
        type=$(echo "$event" | jq -r '.type')
        data=$(echo "$event" | jq -r '.data')

        db_message_send "orchestrator" "$thread_id" "$type" "$data"
    done
}

handle_blocked_thread() {
    local event="$1"
    local source reason
    source=$(echo "$event" | jq -r '.source')
    reason=$(echo "$event" | jq -r '.data.reason // "Unknown"')

    log_warn "Thread blocked: $source - $reason"

    # Could trigger notifications, escalation, etc.
}

handle_completed_thread() {
    local event="$1"
    local source
    source=$(echo "$event" | jq -r '.source')

    log_info "Thread completed: $source"

    # Check for dependent threads to wake
    check_dependencies "$source"
}

check_dependencies() {
    local completed_thread="$1"

    # Find threads waiting for this one
    # (Simple implementation - could be extended with proper dependency tracking)
    local waiting_threads
    waiting_threads=$(db_query "SELECT id FROM threads WHERE status = 'waiting'
                                AND json_extract(context, '\$.wait_for') = $(db_quote "$completed_thread")")

    echo "$waiting_threads" | jq -r '.[].id' | while read -r thread_id; do
        [[ -z "$thread_id" ]] && continue
        log_info "Waking thread $thread_id (dependency $completed_thread completed)"
        thread_ready "$thread_id"
    done
}

# ============================================================
# PR Lifecycle Event Handlers
# ============================================================

handle_merge_conflict() {
    local event="$1"
    local pr_number branch target_branch worktree_path

    # Parse .data as JSON string first, then extract fields
    local data
    data=$(echo "$event" | jq -r '.data | if type == "string" then fromjson else . end')
    pr_number=$(echo "$data" | jq -r '.pr_number')
    branch=$(echo "$data" | jq -r '.branch')
    target_branch=$(echo "$data" | jq -r '.target_branch // "main"')
    worktree_path=$(echo "$data" | jq -r '.worktree_path // empty')
    local conflicting_files
    conflicting_files=$(echo "$data" | jq -c '.conflicting_files // []')

    log_warn "Merge conflict detected for PR #$pr_number"

    # Check if there's already an active conflict resolver for this PR
    local existing_resolver
    existing_resolver=$(db_scalar "SELECT COUNT(*) FROM threads
                                   WHERE name = 'conflict-resolver-$pr_number'
                                   AND status IN ('running', 'ready', 'created')")

    if [[ "$existing_resolver" -gt 0 ]]; then
        log_debug "Conflict resolver already running for PR #$pr_number"
        return
    fi

    # Get attempt number
    local attempt=1
    local conflict_record
    conflict_record=$(db_merge_conflict_get_active "$pr_number" 2>/dev/null || echo "")

    if [[ -n "$conflict_record" && "$conflict_record" != "null" ]]; then
        attempt=$(echo "$conflict_record" | jq -r '.attempts // 0')
        ((attempt++))
    fi

    # Check max retries
    local max_retries
    max_retries=$(config_get_int 'pr_lifecycle.max_conflict_retries' 3)

    if [[ $attempt -gt $max_retries ]]; then
        log_error "Max conflict resolution retries reached for PR #$pr_number"
        bb_publish "ESCALATION_NEEDED" "{\"pr_number\": $pr_number, \"reason\": \"Max conflict resolution retries exceeded\"}" "orchestrator"
        return
    fi

    # Create context for conflict resolver
    local context
    context=$(jq -n \
        --arg pr "$pr_number" \
        --arg branch "$branch" \
        --arg target "$target_branch" \
        --arg worktree "$worktree_path" \
        --argjson files "$conflicting_files" \
        --arg attempt "$attempt" \
        '{
            pr_number: ($pr | tonumber),
            branch: $branch,
            target_branch: $target,
            worktree_path: $worktree,
            conflicting_files: $files,
            attempt_number: ($attempt | tonumber)
        }')

    # Spawn conflict resolver thread
    local thread_id
    thread_id=$(thread_create "conflict-resolver-$pr_number" "automatic" "templates/prompts/merge-conflict.md" "" "$context")
    thread_ready "$thread_id"

    log_info "Spawned conflict resolver thread: $thread_id for PR #$pr_number (attempt $attempt)"

    # Update conflict record
    db_merge_conflict_set_status "$pr_number" "resolving" "$thread_id"
}

handle_review_comments() {
    local event="$1"
    local pr_number worktree_path

    # Parse .data as JSON string first, then extract fields
    local data
    data=$(echo "$event" | jq -r '.data | if type == "string" then fromjson else . end')
    pr_number=$(echo "$data" | jq -r '.pr_number')
    worktree_path=$(echo "$data" | jq -r '.worktree_path // empty')
    local comments
    comments=$(echo "$data" | jq -c '.comments // []')

    local comment_count
    comment_count=$(echo "$comments" | jq 'length')

    log_info "Review comments pending for PR #$pr_number: $comment_count"

    # Get max concurrent handlers
    local max_handlers
    max_handlers=$(config_get_int 'pr_lifecycle.max_comment_handlers' 5)

    # Process each comment
    echo "$comments" | jq -c '.[]' | while read -r comment; do
        local comment_id thread_id author path line body

        comment_id=$(echo "$comment" | jq -r '.id')
        thread_id=$(echo "$comment" | jq -r '.thread_id')
        author=$(echo "$comment" | jq -r '.author')
        path=$(echo "$comment" | jq -r '.path // ""')
        line=$(echo "$comment" | jq -r '.line // 0')
        body=$(echo "$comment" | jq -r '.body')

        # Check if already being handled
        local existing_handler
        existing_handler=$(db_scalar "SELECT COUNT(*) FROM threads
                                      WHERE name = 'comment-handler-$comment_id'
                                      AND status IN ('running', 'ready', 'created')")

        if [[ "$existing_handler" -gt 0 ]]; then
            log_debug "Comment handler already running for comment $comment_id"
            continue
        fi

        # Check handler limit
        local active_handlers
        active_handlers=$(db_scalar "SELECT COUNT(*) FROM threads
                                     WHERE name LIKE 'comment-handler-%'
                                     AND status IN ('running', 'ready')")

        if [[ "$active_handlers" -ge "$max_handlers" ]]; then
            log_debug "Max comment handlers reached, deferring comment $comment_id"
            continue
        fi

        # Create context for comment handler
        local context
        context=$(jq -n \
            --arg pr "$pr_number" \
            --arg cid "$comment_id" \
            --arg tid "$thread_id" \
            --arg author "$author" \
            --arg path "$path" \
            --arg line "$line" \
            --arg body "$body" \
            --arg worktree "$worktree_path" \
            '{
                pr_number: ($pr | tonumber),
                comment_id: $cid,
                github_thread_id: $tid,
                author: $author,
                path: $path,
                line: (if $line == "" or $line == "0" then null else ($line | tonumber) end),
                body: $body,
                worktree_path: $worktree
            }')

        # Spawn comment handler thread
        local handler_thread_id
        handler_thread_id=$(thread_create "comment-handler-$comment_id" "automatic" "templates/prompts/review-comment.md" "" "$context")
        thread_ready "$handler_thread_id"

        log_info "Spawned comment handler thread: $handler_thread_id for comment $comment_id"

        # Update comment record
        db_pr_comment_set_handler "$comment_id" "$handler_thread_id"
    done
}

handle_pr_ready() {
    local event="$1"
    local pr_number auto_merge

    # Parse .data as JSON string first, then extract fields
    local data
    data=$(echo "$event" | jq -r '.data | if type == "string" then fromjson else . end')
    pr_number=$(echo "$data" | jq -r '.pr_number')

    log_info "PR #$pr_number is ready for merge"

    # Check if auto-merge is enabled for this PR
    local config
    config=$(db_pr_config_get "$pr_number" 2>/dev/null || echo "{}")

    auto_merge=$(echo "$config" | jq -r '.auto_merge // 0')

    if [[ "$auto_merge" == "1" || "$auto_merge" == "true" ]]; then
        log_info "Auto-merging PR #$pr_number"

        # Merge the PR
        if gh pr merge "$pr_number" --merge --delete-branch 2>/dev/null; then
            log_info "Successfully merged PR #$pr_number"
            bb_publish "PR_MERGED" "{\"pr_number\": $pr_number}" "orchestrator"

            # Update watch status
            db_exec "UPDATE pr_watches SET status = 'merged' WHERE pr_number = $pr_number"
        else
            log_error "Failed to merge PR #$pr_number"
            bb_publish "ESCALATION_NEEDED" "{\"pr_number\": $pr_number, \"reason\": \"Auto-merge failed\"}" "orchestrator"
        fi
    else
        log_info "PR #$pr_number ready but auto-merge disabled - notifying only"
        # The event itself serves as notification
    fi
}

handle_escalation() {
    local event="$1"
    local pr_number reason

    # Parse .data as JSON string first, then extract fields
    local data
    data=$(echo "$event" | jq -r '.data | if type == "string" then fromjson else . end')
    pr_number=$(echo "$data" | jq -r '.pr_number // "unknown"')
    reason=$(echo "$data" | jq -r '.reason // "Unknown reason"')

    log_error "ESCALATION: PR #$pr_number - $reason"

    # TODO: Could send notifications (slack, email, etc.)
    # For now, just log and mark in database

    if [[ "$pr_number" != "unknown" && "$pr_number" =~ ^[0-9]+$ ]]; then
        db_exec "UPDATE pr_watches SET state = 'escalated', last_error = $(db_quote "$reason")
                 WHERE pr_number = $pr_number"
    fi
}

# ============================================================
# Thread Scheduling
# ============================================================

check_scheduled() {
    local enable_scheduling
    enable_scheduling=$(config_get_bool 'orchestrator.enable_scheduling' true)

    if [[ "$enable_scheduling" != "true" ]]; then
        return
    fi

    # Check for sleeping threads that should wake
    thread_check_scheduled

    # Check for interval-scheduled threads
    check_interval_threads
}

check_interval_threads() {
    local now
    now=$(ct_timestamp)

    # Find threads with interval schedules that are due
    db_query "SELECT id, schedule FROM threads
              WHERE status = 'sleeping'
              AND json_extract(schedule, '\$.type') = 'interval'" | \
    jq -c '.[]' | while read -r row; do
        local thread_id interval last_run
        thread_id=$(echo "$row" | jq -r '.id')
        interval=$(echo "$row" | jq -r '.schedule.interval // 300')
        last_run=$(echo "$row" | jq -r '.schedule.last_run // ""')

        # Check if interval has passed
        if [[ -z "$last_run" ]]; then
            # First run
            thread_ready "$thread_id"
            db_exec "UPDATE threads SET schedule = json_set(schedule, '\$.last_run', $(db_quote "$now"))
                     WHERE id = $(db_quote "$thread_id")"
        else
            local last_epoch now_epoch
            last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_run" +%s 2>/dev/null || \
                        date -d "$last_run" +%s 2>/dev/null || echo 0)
            now_epoch=$(date +%s)

            if [[ $((now_epoch - last_epoch)) -ge $interval ]]; then
                log_debug "Interval thread $thread_id due for execution"
                thread_ready "$thread_id"
                db_exec "UPDATE threads SET schedule = json_set(schedule, '\$.last_run', $(db_quote "$now"))
                         WHERE id = $(db_quote "$thread_id")"
            fi
        fi
    done
}

# ============================================================
# Thread Monitoring
# ============================================================

monitor_threads() {
    # Check for stale running threads
    local timeout
    timeout=$(config_get_int 'threads.default_timeout' 3600)

    local stale_threads
    stale_threads=$(db_query "SELECT id, name FROM threads
                              WHERE status = 'running'
                              AND datetime(updated_at, '+$timeout seconds') < datetime('now')")

    echo "$stale_threads" | jq -c '.[]' | while read -r row; do
        local thread_id name
        thread_id=$(echo "$row" | jq -r '.id')
        name=$(echo "$row" | jq -r '.name')

        log_warn "Thread $thread_id ($name) appears stale (no update for ${timeout}s)"

        # Check if process is still running
        local pid_file="$DATA_DIR/tmp/thread-${thread_id}.pid"
        if [[ -f "$pid_file" ]]; then
            local pid
            pid=$(cat "$pid_file")
            if ! kill -0 "$pid" 2>/dev/null; then
                log_warn "Thread process died, marking as failed"
                thread_fail "$thread_id" "Process died unexpectedly"
                rm -f "$pid_file"
            fi
        else
            # No PID file, might be foreground or orphaned
            log_debug "No PID file for thread $thread_id"
        fi
    done
}

# ============================================================
# Thread Starting
# ============================================================

start_pending_threads() {
    local max_concurrent
    max_concurrent=$(config_get_int 'threads.max_concurrent' 5)

    local running_count
    running_count=$(thread_count_running)

    if [[ $running_count -ge $max_concurrent ]]; then
        log_trace "At max concurrent threads ($running_count/$max_concurrent)"
        return
    fi

    local available=$((max_concurrent - running_count))

    # Security: sanitize available to prevent SQL injection
    available=$(ct_sanitize_int "$available" 1 0 100)

    # Get ready threads, prioritizing by mode
    # Interactive/semi-auto get priority (they need foreground)
    local ready_threads
    ready_threads=$(db_query "SELECT id, mode FROM threads
                              WHERE status = 'ready'
                              ORDER BY
                                CASE mode
                                  WHEN 'interactive' THEN 1
                                  WHEN 'semi-auto' THEN 2
                                  WHEN 'automatic' THEN 3
                                  ELSE 4
                                END,
                                updated_at ASC
                              LIMIT $available")

    echo "$ready_threads" | jq -c '.[]' | while read -r row; do
        local thread_id mode
        thread_id=$(echo "$row" | jq -r '.id')
        mode=$(echo "$row" | jq -r '.mode')

        case "$mode" in
            interactive|semi-auto)
                # These need foreground - check if we have one
                if [[ -n "$FOREGROUND_THREAD" ]]; then
                    log_debug "Foreground occupied, skipping $mode thread $thread_id"
                    continue
                fi
                log_info "Starting foreground thread: $thread_id ($mode)"
                start_foreground_thread "$thread_id"
                ;;
            automatic)
                log_info "Starting background thread: $thread_id"
                start_background_thread "$thread_id"
                ;;
        esac
    done
}

start_foreground_thread() {
    local thread_id="$1"
    FOREGROUND_THREAD="$thread_id"

    # Run thread-runner in foreground
    "$SCRIPT_DIR/thread-runner.sh" --thread-id "$thread_id" --data-dir "$DATA_DIR"

    FOREGROUND_THREAD=""
}

start_background_thread() {
    local thread_id="$1"

    # Run thread-runner in background
    "$SCRIPT_DIR/thread-runner.sh" --thread-id "$thread_id" --data-dir "$DATA_DIR" --background
}

# ============================================================
# Cleanup
# ============================================================

periodic_cleanup() {
    # Run cleanup periodically (every 100 ticks or so)
    local tick_count="${_TICK_COUNT:-0}"
    _TICK_COUNT=$((tick_count + 1))

    if [[ $((_TICK_COUNT % 100)) -ne 0 ]]; then
        return
    fi

    log_debug "Running periodic cleanup"

    # Cleanup old events
    local event_retention
    event_retention=$(config_get_int 'blackboard.event_retention_days' 7)
    db_cleanup_events "$event_retention"

    # Cleanup old messages
    local message_retention
    message_retention=$(config_get_int 'blackboard.message_retention_days' 30)
    db_cleanup_messages "$message_retention"

    # Cleanup old completed threads
    local thread_retention
    thread_retention=$(config_get_int 'threads.cleanup_after_days' 7)
    thread_cleanup_old "$thread_retention"

    # Cleanup orphaned worktrees (for completed/failed threads)
    thread_cleanup_orphaned_worktrees

    # Cleanup old worktrees by age
    local worktree_retention
    worktree_retention=$(config_get_int 'worktrees.max_age_days' 7)
    git_cleanup_old_worktrees "$worktree_retention"

    # Cleanup old output files
    find "$DATA_DIR/tmp" -name "*.txt" -mtime +"$thread_retention" -delete 2>/dev/null || true
}

# ============================================================
# Signal Handling
# ============================================================

shutdown() {
    log_info "Orchestrator shutting down..."
    RUNNING=0

    # Wait for foreground thread if any
    if [[ -n "$FOREGROUND_THREAD" ]]; then
        log_info "Waiting for foreground thread to complete..."
        # The thread runner handles its own cleanup
    fi

    rm -f "$PID_FILE"
    log_info "Orchestrator shutdown complete"
    exit 0
}

trap shutdown SIGINT SIGTERM

# ============================================================
# Main
# ============================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  start             Start orchestrator daemon
  stop              Stop orchestrator daemon
  restart           Restart orchestrator
  status            Show orchestrator status with thread progress
  tick              Run single iteration (for cron/testing)
  watch [INT] [ID]  Live monitor threads (refresh every INT seconds)
  progress [ID]     Show progress for thread ID or all running threads

Options:
  --data-dir DIR    Data directory (default: .claude-threads)
  --foreground      Run in foreground (don't daemonize)
  --help            Show this help

Examples:
  $(basename "$0") start
  $(basename "$0") status
  $(basename "$0") watch 2                    # Watch all threads, refresh every 2s
  $(basename "$0") watch 1 thread-123456789   # Watch specific thread
  $(basename "$0") progress thread-123456789  # Show thread progress
  $(basename "$0") tick --data-dir /path/to/.claude-threads
EOF
    exit 0
}

main() {
    local command="${1:-}"
    shift || true

    # Parse global options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --data-dir)
                export CT_DATA_DIR="$2"
                shift 2
                ;;
            --foreground)
                FOREGROUND=1
                shift
                ;;
            --help|-h)
                usage
                ;;
            *)
                break
                ;;
        esac
    done

    init

    case "$command" in
        start)
            if [[ "${FOREGROUND:-0}" -eq 1 ]]; then
                RUNNING=1
                echo "Running in foreground..."
                main_loop
            else
                start_daemon
            fi
            ;;
        stop)
            stop_daemon
            ;;
        restart)
            stop_daemon
            sleep 1
            start_daemon
            ;;
        status)
            show_status
            ;;
        tick)
            tick
            ;;
        watch)
            # Watch threads with live updates
            local interval="${1:-2}"
            local thread_id="${2:-}"
            watch_threads "$interval" "$thread_id"
            ;;
        progress)
            # Show progress for a specific thread or all running
            local thread_id="${1:-}"
            if [[ -n "$thread_id" ]]; then
                show_thread_progress "$thread_id"
            else
                show_running_progress
            fi
            ;;
        ""|--help|-h)
            usage
            ;;
        *)
            echo "Unknown command: $command"
            usage
            ;;
    esac
}

main "$@"
