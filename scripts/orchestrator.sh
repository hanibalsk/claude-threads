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
# Daemon Control
# ============================================================

is_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        rm -f "$PID_FILE"
    fi
    return 1
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
        echo $$ > "$PID_FILE"
        RUNNING=1
        main_loop
    ) &

    local pid=$!
    echo "$pid" > "$PID_FILE"

    echo "Orchestrator started (PID: $pid)"
    log_info "Orchestrator daemon started: PID=$pid"
}

stop_daemon() {
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
    active_prs=$(db_scalar "SELECT COUNT(*) FROM pr_watches WHERE state NOT IN ('merged', 'closed')" 2>/dev/null || echo 0)
    [[ $active_prs -gt 0 ]] && has_activity=1

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
  start       Start orchestrator daemon
  stop        Stop orchestrator daemon
  restart     Restart orchestrator
  status      Show orchestrator status
  tick        Run single iteration (for cron/testing)

Options:
  --data-dir DIR    Data directory (default: .claude-threads)
  --foreground      Run in foreground (don't daemonize)
  --help            Show this help

Examples:
  $(basename "$0") start
  $(basename "$0") status
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
