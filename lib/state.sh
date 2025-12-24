#!/usr/bin/env bash
#
# state.sh - Thread state management for claude-threads
#
# High-level thread lifecycle management on top of db.sh
#
# Usage:
#   source lib/state.sh
#   state_init
#   thread_create "my-thread" "automatic"
#   thread_start "thread-id"
#

# Prevent double-sourcing
[[ -n "${_CT_STATE_LOADED:-}" ]] && return 0
_CT_STATE_LOADED=1

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/db.sh"
source "$(dirname "${BASH_SOURCE[0]}")/git.sh"

# ============================================================
# Initialization
# ============================================================

# Initialize state management
state_init() {
    local data_dir="${1:-$(ct_data_dir)}"

    # Initialize database
    db_init "$data_dir"

    log_debug "State management initialized"
}

# ============================================================
# Thread Lifecycle
# ============================================================

# Create a new thread
thread_create() {
    local name="$1"
    local mode="${2:-automatic}"
    local template="${3:-}"
    local workflow="${4:-}"
    local context="${5:-"{}"}"

    # Validate mode
    if ! ct_validate_mode "$mode"; then
        ct_error "Invalid thread mode: $mode"
        return 1
    fi

    # Generate thread ID
    local id
    id=$(ct_generate_id "thread")

    # Create config from defaults
    local config
    config=$(ct_json_object \
        "max_turns" "${CT_MAX_TURNS:-80}" \
        "timeout" "${CT_TIMEOUT:-3600}")

    # Insert into database
    db_thread_create "$id" "$name" "$mode" "$template" "$workflow" "$config" "$context"

    log_info "Thread created: $id ($name, mode=$mode)"

    # Return the thread ID
    echo "$id"
}

# Get thread info
thread_get() {
    local id="$1"
    db_thread_get "$id"
}

# List all threads
thread_list() {
    local status="${1:-}"

    if [[ -n "$status" ]]; then
        db_threads_by_status "$status"
    else
        db_query "SELECT * FROM threads ORDER BY updated_at DESC"
    fi
}

# Start a thread (transition to ready)
thread_ready() {
    local id="$1"

    local current_status
    current_status=$(db_scalar "SELECT status FROM threads WHERE id = $(db_quote "$id")")

    if [[ "$current_status" != "created" ]]; then
        ct_error "Thread $id cannot be made ready from status: $current_status"
        return 1
    fi

    db_thread_set_status "$id" "ready"
    log_info "Thread ready: $id"

    # Publish event
    db_event_publish "$id" "THREAD_READY" '{}' '*'
}

# Run a thread (transition to running)
thread_run() {
    local id="$1"
    local session_id="${2:-}"

    local current_status
    current_status=$(db_scalar "SELECT status FROM threads WHERE id = $(db_quote "$id")")

    if [[ "$current_status" != "ready" && "$current_status" != "waiting" && "$current_status" != "sleeping" ]]; then
        ct_error "Thread $id cannot run from status: $current_status"
        return 1
    fi

    # Generate session ID if not provided (must be UUID for Claude CLI)
    if [[ -z "$session_id" ]]; then
        session_id=$(ct_generate_uuid)
    fi

    # Update thread and create session
    db_thread_set_status "$id" "running"
    db_thread_set_session "$id" "$session_id"
    db_session_upsert "$session_id" "$id"

    log_info "Thread running: $id (session=$session_id)"

    # Publish event
    db_event_publish "$id" "THREAD_STARTED" "{\"session_id\": \"$session_id\"}" '*'

    echo "$session_id"
}

# Pause a thread (transition to waiting)
thread_wait() {
    local id="$1"
    local reason="${2:-}"

    db_thread_set_status "$id" "waiting"
    log_info "Thread waiting: $id${reason:+ ($reason)}"

    # Publish event
    local data="{}"
    [[ -n "$reason" ]] && data="{\"reason\": \"$reason\"}"
    db_event_publish "$id" "THREAD_WAITING" "$data" '*'
}

# Put thread to sleep (scheduled wake)
thread_sleep() {
    local id="$1"
    local wake_at="$2"  # ISO timestamp or duration string

    # Parse duration if provided
    if [[ "$wake_at" =~ ^[0-9]+[smhd]$ ]]; then
        local seconds
        seconds=$(ct_parse_duration "$wake_at")
        wake_at=$(date -u -v+${seconds}S '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
                  date -u -d "+${seconds} seconds" '+%Y-%m-%dT%H:%M:%SZ')
    fi

    local schedule
    schedule=$(ct_json_object "type" "once" "wake_at" "$wake_at")

    db_exec "UPDATE threads SET status = 'sleeping', schedule = $(db_quote "$schedule")
             WHERE id = $(db_quote "$id")"

    log_info "Thread sleeping: $id (wake at $wake_at)"

    db_event_publish "$id" "THREAD_SLEEPING" "{\"wake_at\": \"$wake_at\"}" '*'
}

# Block a thread (needs intervention)
thread_block() {
    local id="$1"
    local reason="$2"

    db_exec "UPDATE threads SET status = 'blocked', error = $(db_quote "$reason")
             WHERE id = $(db_quote "$id")"

    log_warn "Thread blocked: $id - $reason"

    db_event_publish "$id" "THREAD_BLOCKED" "{\"reason\": \"$reason\"}" '*'
}

# Complete a thread
thread_complete() {
    local id="$1"

    db_thread_set_status "$id" "completed"
    log_info "Thread completed: $id"

    # Mark session as completed
    local session_id
    session_id=$(db_scalar "SELECT session_id FROM threads WHERE id = $(db_quote "$id")")
    if [[ -n "$session_id" ]]; then
        db_exec "UPDATE sessions SET status = 'completed' WHERE id = $(db_quote "$session_id")"
    fi

    db_event_publish "$id" "THREAD_COMPLETED" '{}' '*'
}

# Fail a thread
thread_fail() {
    local id="$1"
    local error="$2"

    db_exec "UPDATE threads SET status = 'failed', error = $(db_quote "$error")
             WHERE id = $(db_quote "$id")"

    log_error "Thread failed: $id - $error"

    db_event_publish "$id" "THREAD_FAILED" "{\"error\": \"$error\"}" '*'
}

# ============================================================
# Phase Management
# ============================================================

# Set thread phase
thread_set_phase() {
    local id="$1"
    local phase="$2"

    local old_phase
    old_phase=$(db_scalar "SELECT phase FROM threads WHERE id = $(db_quote "$id")")

    db_thread_set_phase "$id" "$phase"
    log_info "Thread phase: $id $old_phase -> $phase"

    db_event_publish "$id" "PHASE_CHANGED" \
        "{\"old_phase\": \"$old_phase\", \"new_phase\": \"$phase\"}" '*'
}

# Get thread phase
thread_get_phase() {
    local id="$1"
    db_scalar "SELECT phase FROM threads WHERE id = $(db_quote "$id")"
}

# ============================================================
# Context Management
# ============================================================

# Update thread context
thread_update_context() {
    local id="$1"
    local context="$2"

    db_thread_update_context "$id" "$context"
    log_debug "Thread context updated: $id"
}

# Get thread context
thread_get_context() {
    local id="$1"
    db_scalar "SELECT context FROM threads WHERE id = $(db_quote "$id")"
}

# Get single context value
thread_get_context_value() {
    local id="$1"
    local key="$2"

    local context
    context=$(thread_get_context "$id")
    echo "$context" | jq -r ".$key // empty"
}

# ============================================================
# Scheduled Threads
# ============================================================

# Check for threads that need to wake up
thread_check_scheduled() {
    local now
    now=$(ct_timestamp)

    db_query "SELECT id FROM threads
              WHERE status = 'sleeping'
              AND json_extract(schedule, '\$.wake_at') <= $(db_quote "$now")" | \
    jq -r '.[].id' | while read -r id; do
        log_info "Waking thread: $id"
        thread_ready "$id"
    done
}

# Set interval schedule for a thread
thread_set_interval() {
    local id="$1"
    local interval="$2"  # Duration string (e.g., "5m", "1h")

    local seconds
    seconds=$(ct_parse_duration "$interval")

    local schedule
    schedule=$(ct_json_object "type" "interval" "interval" "$seconds")

    db_exec "UPDATE threads SET schedule = $(db_quote "$schedule")
             WHERE id = $(db_quote "$id")"

    log_debug "Thread interval set: $id every ${interval}"
}

# ============================================================
# Thread Queries
# ============================================================

# Get running thread count
thread_count_running() {
    db_scalar "SELECT COUNT(*) FROM threads WHERE status = 'running'"
}

# Get threads by mode
thread_list_by_mode() {
    local mode="$1"
    db_query "SELECT * FROM threads WHERE mode = $(db_quote "$mode") ORDER BY updated_at DESC"
}

# Find thread by name
thread_find_by_name() {
    local name="$1"
    db_query "SELECT * FROM threads WHERE name = $(db_quote "$name") LIMIT 1" | jq '.[0] // empty'
}

# ============================================================
# Cleanup
# ============================================================

# Delete a thread and all related data
thread_delete() {
    local id="$1"

    db_transaction "
        DELETE FROM messages WHERE from_thread = $(db_quote "$id") OR to_thread = $(db_quote "$id");
        DELETE FROM events WHERE source = $(db_quote "$id");
        DELETE FROM artifacts WHERE thread_id = $(db_quote "$id");
        DELETE FROM sessions WHERE thread_id = $(db_quote "$id");
        DELETE FROM threads WHERE id = $(db_quote "$id")
    "

    log_info "Thread deleted: $id"
}

# Delete completed threads older than N days
thread_cleanup_old() {
    local days="${1:-7}"

    db_exec "DELETE FROM threads
             WHERE status IN ('completed', 'failed')
             AND updated_at < datetime('now', '-$days days')"

    log_info "Cleaned up threads older than $days days"
}

# ============================================================
# Worktree Management
# ============================================================

# Create a thread with worktree
# Uses proper cleanup if any step fails
thread_create_with_worktree() {
    local name="$1"
    local mode="${2:-automatic}"
    local branch_name="$3"
    local base_branch="${4:-main}"
    local template="${5:-}"
    local context="${6:-"{}"}"

    # Security: validate branch name if provided
    if [[ -n "$branch_name" ]] && ! ct_validate_branch_name "$branch_name"; then
        ct_error "Invalid branch name: $branch_name"
        return 1
    fi

    # Security: validate base branch
    if ! ct_validate_branch_name "$base_branch"; then
        ct_error "Invalid base branch: $base_branch"
        return 1
    fi

    # Create the thread first
    local id
    id=$(thread_create "$name" "$mode" "$template" "" "$context")

    if [[ -z "$id" ]]; then
        ct_error "Failed to create thread"
        return 1
    fi

    # Auto-generate branch name if not provided
    if [[ -z "$branch_name" ]]; then
        local safe_name
        safe_name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g')
        branch_name="ct/${safe_name}-${id:0:8}"
    fi

    # Create worktree
    local worktree_path
    worktree_path=$(git_worktree_create "$id" "$branch_name" "$base_branch")

    if [[ -z "$worktree_path" || ! -d "$worktree_path" ]]; then
        ct_error "Failed to create worktree for thread $id"
        # Cleanup: delete the thread since worktree failed
        thread_delete "$id" 2>/dev/null || true
        return 1
    fi

    # Update thread with worktree info (use transaction for atomicity)
    local update_result
    update_result=$(db_exec "BEGIN IMMEDIATE;
        UPDATE threads SET
            worktree = $(db_quote "$worktree_path"),
            worktree_branch = $(db_quote "$branch_name"),
            worktree_base = $(db_quote "$base_branch")
        WHERE id = $(db_quote "$id");
        INSERT INTO worktrees (id, thread_id, path, branch, base_branch)
        VALUES ($(db_quote "$id"), $(db_quote "$id"), $(db_quote "$worktree_path"),
                $(db_quote "$branch_name"), $(db_quote "$base_branch"));
        COMMIT;" 2>&1)

    if [[ $? -ne 0 ]]; then
        ct_error "Failed to update thread with worktree info: $update_result"
        # Cleanup: remove worktree and delete thread
        git_worktree_remove "$id" force 2>/dev/null || true
        thread_delete "$id" 2>/dev/null || true
        return 1
    fi

    log_info "Thread created with worktree: $id ($worktree_path)"

    # Publish event
    db_event_publish "$id" "WORKTREE_CREATED" \
        "{\"path\": \"$worktree_path\", \"branch\": \"$branch_name\", \"base\": \"$base_branch\"}" '*'

    echo "$id"
}

# Get worktree path for a thread
thread_get_worktree() {
    local id="$1"
    db_scalar "SELECT worktree FROM threads WHERE id = $(db_quote "$id")"
}

# Check if thread has a worktree
thread_has_worktree() {
    local id="$1"
    local worktree
    worktree=$(thread_get_worktree "$id")
    [[ -n "$worktree" && -d "$worktree" ]]
}

# Update worktree status in database
thread_update_worktree_status() {
    local id="$1"

    local worktree_path
    worktree_path=$(thread_get_worktree "$id")

    if [[ -z "$worktree_path" || ! -d "$worktree_path" ]]; then
        return 1
    fi

    # Get git status info
    local is_dirty=0
    local commits_ahead=0
    local commits_behind=0

    if ! git_is_clean "$worktree_path"; then
        is_dirty=1
    fi

    local base_branch
    base_branch=$(db_scalar "SELECT worktree_base FROM threads WHERE id = $(db_quote "$id")")
    local current_branch
    current_branch=$(git_current_branch "$worktree_path")

    if [[ -n "$base_branch" && -n "$current_branch" ]]; then
        commits_ahead=$(cd "$worktree_path" && git rev-list --count "$base_branch..$current_branch" 2>/dev/null || echo 0)
        commits_behind=$(cd "$worktree_path" && git rev-list --count "$current_branch..$base_branch" 2>/dev/null || echo 0)
    fi

    db_exec "UPDATE worktrees SET
                is_dirty = $is_dirty,
                commits_ahead = $commits_ahead,
                commits_behind = $commits_behind
             WHERE id = $(db_quote "$id")"
}

# Push changes from worktree
thread_push_worktree() {
    local id="$1"
    local force="${2:-false}"

    local worktree_path
    worktree_path=$(thread_get_worktree "$id")

    if [[ -z "$worktree_path" ]]; then
        ct_error "Thread $id has no worktree"
        return 1
    fi

    local branch
    branch=$(git_current_branch "$worktree_path")

    if git_push_branch "$worktree_path" "$branch" "origin" "$force"; then
        log_info "Pushed worktree changes: $id ($branch)"
        db_event_publish "$id" "WORKTREE_PUSHED" "{\"branch\": \"$branch\"}" '*'
        return 0
    else
        log_error "Failed to push worktree: $id"
        return 1
    fi
}

# Cleanup worktree for a thread
thread_cleanup_worktree() {
    local id="$1"
    local force="${2:-false}"
    local delete_remote_branch="${3:-false}"

    local worktree_path
    worktree_path=$(thread_get_worktree "$id")

    if [[ -z "$worktree_path" ]]; then
        log_debug "Thread $id has no worktree to cleanup"
        return 0
    fi

    # Get branch before removal
    local branch
    branch=$(db_scalar "SELECT worktree_branch FROM threads WHERE id = $(db_quote "$id")")

    # Remove the worktree
    if git_worktree_remove "$id" "$force"; then
        # Update database
        db_exec "UPDATE worktrees SET status = 'deleted', deleted_at = datetime('now')
                 WHERE id = $(db_quote "$id")"
        db_exec "UPDATE threads SET worktree = NULL WHERE id = $(db_quote "$id")"

        log_info "Worktree cleaned up: $id"

        # Optionally delete remote branch
        if [[ "$delete_remote_branch" == "true" && -n "$branch" ]]; then
            git_delete_remote_branch "$branch"
        fi

        db_event_publish "$id" "WORKTREE_DELETED" "{\"path\": \"$worktree_path\"}" '*'
        return 0
    else
        log_error "Failed to cleanup worktree: $id"
        return 1
    fi
}

# Cleanup all orphaned worktrees
thread_cleanup_orphaned_worktrees() {
    local worktrees_dir
    worktrees_dir=$(git_worktrees_dir)

    if [[ ! -d "$worktrees_dir" ]]; then
        return 0
    fi

    for dir in "$worktrees_dir"/*/; do
        if [[ -d "$dir" && -f "$dir/.worktree-info" ]]; then
            local thread_id
            thread_id=$(basename "$dir")

            # Check if thread exists and is not completed
            local status
            status=$(db_scalar "SELECT status FROM threads WHERE id = $(db_quote "$thread_id")")

            if [[ -z "$status" ]]; then
                log_warn "Found orphaned worktree (no thread): $thread_id"
                git_worktree_remove "$thread_id" "true"
            elif [[ "$status" == "completed" || "$status" == "failed" ]]; then
                log_info "Cleaning up worktree for finished thread: $thread_id"
                thread_cleanup_worktree "$thread_id" "true"
            fi
        fi
    done

    # Prune git worktrees
    git_worktree_prune
}

# List threads with worktrees
thread_list_with_worktrees() {
    db_query "SELECT t.*, w.path as worktree_path, w.branch, w.base_branch,
                     w.commits_ahead, w.commits_behind, w.is_dirty
              FROM threads t
              JOIN worktrees w ON t.id = w.thread_id
              WHERE w.status = 'active'
              ORDER BY t.updated_at DESC"
}

# Merge worktree changes back to base branch
thread_merge_worktree() {
    local id="$1"
    local squash="${2:-false}"

    local worktree_path
    worktree_path=$(thread_get_worktree "$id")
    local base_branch
    base_branch=$(db_scalar "SELECT worktree_base FROM threads WHERE id = $(db_quote "$id")")

    if [[ -z "$worktree_path" || -z "$base_branch" ]]; then
        ct_error "Thread $id has no worktree or base branch"
        return 1
    fi

    # Check for uncommitted changes
    if ! git_is_clean "$worktree_path"; then
        ct_error "Worktree has uncommitted changes"
        return 1
    fi

    # Check if merge is possible
    if ! git_can_merge "$worktree_path" "$base_branch"; then
        ct_error "Merge would have conflicts"
        thread_block "$id" "Merge conflict with $base_branch"
        return 1
    fi

    # Perform merge
    if git_merge_to_base "$worktree_path" "$base_branch" "$squash"; then
        log_info "Merged worktree to $base_branch: $id"
        db_event_publish "$id" "WORKTREE_MERGED" "{\"base\": \"$base_branch\", \"squash\": $squash}" '*'
        return 0
    else
        ct_error "Merge failed"
        return 1
    fi
}
