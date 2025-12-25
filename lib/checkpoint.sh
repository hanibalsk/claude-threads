#!/usr/bin/env bash
#
# checkpoint.sh - Work checkpointing and recovery for claude-threads
#
# Enables fault-tolerant work preservation when threads are killed/paused
# and provides recovery mechanisms for interrupted work.
#
# Usage:
#   source lib/checkpoint.sh
#   checkpoint_init "$DATA_DIR"
#   checkpoint_create "$thread_id" "periodic"
#   checkpoint_restore "$thread_id" "$checkpoint_id"
#

# Prevent double-sourcing
[[ -n "${_CT_CHECKPOINT_LOADED:-}" ]] && return 0
_CT_CHECKPOINT_LOADED=1

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/db.sh"
source "$(dirname "${BASH_SOURCE[0]}")/git.sh"
source "$(dirname "${BASH_SOURCE[0]}")/blackboard.sh"

# ============================================================
# Configuration
# ============================================================

_CHECKPOINT_INITIALIZED=0

# ============================================================
# Initialization
# ============================================================

checkpoint_init() {
    local data_dir="${1:-$(ct_data_dir)}"
    _CHECKPOINT_INITIALIZED=1
    log_debug "Checkpoint library initialized"
}

checkpoint_check() {
    if [[ $_CHECKPOINT_INITIALIZED -ne 1 ]]; then
        checkpoint_init
    fi
}

# ============================================================
# Checkpoint Creation
# ============================================================

# Create a checkpoint for a thread
# Args: thread_id, type (periodic|signal|state_transition|error|manual)
checkpoint_create() {
    checkpoint_check
    local thread_id="$1"
    local checkpoint_type="${2:-periodic}"

    # Check if recovery is enabled
    local enabled
    enabled=$(config_get 'recovery.enabled' 'true')
    if [[ "$enabled" != "true" ]]; then
        log_debug "Recovery disabled, skipping checkpoint"
        return 0
    fi

    # Check checkpoint strategy
    local strategy
    strategy=$(config_get 'recovery.checkpoint_strategy' 'all')
    case "$strategy" in
        periodic)
            [[ "$checkpoint_type" != "periodic" ]] && return 0
            ;;
        signals)
            [[ "$checkpoint_type" != "signal" ]] && return 0
            ;;
        all)
            # Allow all types
            ;;
    esac

    # Get thread info
    local thread_json
    thread_json=$(db_thread_get "$thread_id")
    if [[ -z "$thread_json" || "$thread_json" == "null" ]]; then
        log_error "Cannot create checkpoint: thread not found: $thread_id"
        return 1
    fi

    local worktree session_id
    worktree=$(echo "$thread_json" | jq -r '.worktree // empty')
    session_id=$(echo "$thread_json" | jq -r '.session_id // empty')

    # Get git info from worktree
    local git_branch="" git_commit="" has_uncommitted=0 uncommitted_diff="" stash_ref=""

    if [[ -n "$worktree" && -d "$worktree" ]]; then
        git_branch=$(git_current_branch "$worktree")
        git_commit=$(cd "$worktree" && git rev-parse HEAD 2>/dev/null || echo "")

        # Check for uncommitted changes
        if ! git_is_clean "$worktree"; then
            has_uncommitted=1
            uncommitted_diff=$(_checkpoint_preserve_work "$thread_id" "$worktree")
        fi
    fi

    # Create context snapshot
    local context_snapshot
    context_snapshot=$(echo "$thread_json" | jq -c '{
        name: .name,
        mode: .mode,
        status: .status,
        phase: .phase,
        context: .context
    }')

    # Insert checkpoint into database
    db_exec "INSERT INTO work_checkpoints (
                thread_id, checkpoint_type, git_branch, git_commit_sha,
                has_uncommitted_changes, uncommitted_diff, stash_ref,
                worktree_path, session_id, context_snapshot
             ) VALUES (
                $(db_quote "$thread_id"),
                $(db_quote "$checkpoint_type"),
                $(db_quote "$git_branch"),
                $(db_quote "$git_commit"),
                $has_uncommitted,
                $(db_quote "$uncommitted_diff"),
                $(db_quote "$stash_ref"),
                $(db_quote "$worktree"),
                $(db_quote "$session_id"),
                $(db_quote "$context_snapshot")
             )"

    local checkpoint_id
    checkpoint_id=$(db_scalar "SELECT last_insert_rowid()")

    log_info "Checkpoint created: $checkpoint_id (type=$checkpoint_type, thread=$thread_id)"

    # Publish event
    bb_publish "CHECKPOINT_CREATED" "{\"thread_id\": \"$thread_id\", \"checkpoint_id\": $checkpoint_id, \"type\": \"$checkpoint_type\", \"has_uncommitted\": $has_uncommitted}" "$thread_id"

    echo "$checkpoint_id"
}

# Create checkpoint on signal (SIGTERM/SIGINT)
# This is called from signal handler in thread-runner
checkpoint_on_signal() {
    checkpoint_check
    local thread_id="$1"
    local signal="${2:-SIGTERM}"

    log_info "Creating signal checkpoint for thread $thread_id (signal: $signal)"

    # Create checkpoint
    local checkpoint_id
    checkpoint_id=$(checkpoint_create "$thread_id" "signal")

    # Update thread with interrupt info
    db_exec "UPDATE threads SET
                interrupted_at = datetime('now'),
                interrupt_reason = $(db_quote "signal:$signal")
             WHERE id = $(db_quote "$thread_id")"

    # Publish recovery event
    bb_publish "THREAD_INTERRUPTED" "{\"thread_id\": \"$thread_id\", \"signal\": \"$signal\", \"checkpoint_id\": ${checkpoint_id:-0}}" "$thread_id"

    echo "$checkpoint_id"
}

# ============================================================
# Work Preservation
# ============================================================

# Preserve uncommitted work using configured method
# Returns: diff/stash reference for storage
_checkpoint_preserve_work() {
    local thread_id="$1"
    local worktree="$2"

    local method
    method=$(config_get 'recovery.preservation_method' 'diff')

    cd "$worktree" || return 1

    case "$method" in
        diff)
            # Store full diff (staged + unstaged + untracked)
            {
                # Staged changes
                git diff --cached 2>/dev/null
                # Unstaged changes
                git diff 2>/dev/null
                # Untracked files (as patches)
                git ls-files --others --exclude-standard | while read -r file; do
                    if [[ -f "$file" ]]; then
                        echo "--- /dev/null"
                        echo "+++ b/$file"
                        echo "@@ -0,0 +1,$(wc -l < "$file" | tr -d ' ') @@"
                        sed 's/^/+/' "$file"
                    fi
                done
            } 2>/dev/null
            ;;
        stash)
            # Create a stash and return reference
            git stash push -m "checkpoint:$thread_id:$(date +%s)" --include-untracked 2>/dev/null
            git stash list | head -1 | cut -d: -f1
            ;;
        temp_commit)
            # Create a temporary commit
            git add -A 2>/dev/null
            git commit -m "CHECKPOINT: $thread_id (auto-save)" --no-verify 2>/dev/null || true
            git rev-parse HEAD 2>/dev/null
            ;;
    esac
}

# ============================================================
# Checkpoint Restoration
# ============================================================

# Restore checkpoint for a thread
checkpoint_restore() {
    checkpoint_check
    local thread_id="$1"
    local checkpoint_id="${2:-}"

    # If no checkpoint_id provided, get the latest available
    if [[ -z "$checkpoint_id" ]]; then
        checkpoint_id=$(db_scalar "SELECT id FROM work_checkpoints
                                   WHERE thread_id = $(db_quote "$thread_id")
                                   AND recovery_status = 'available'
                                   ORDER BY created_at DESC LIMIT 1")
    fi

    if [[ -z "$checkpoint_id" ]]; then
        log_error "No checkpoint available for thread: $thread_id"
        return 1
    fi

    # Get checkpoint data
    local checkpoint_json
    checkpoint_json=$(db_query "SELECT * FROM work_checkpoints WHERE id = $checkpoint_id" | jq '.[0]')

    if [[ -z "$checkpoint_json" || "$checkpoint_json" == "null" ]]; then
        log_error "Checkpoint not found: $checkpoint_id"
        return 1
    fi

    local worktree has_uncommitted uncommitted_diff stash_ref
    worktree=$(echo "$checkpoint_json" | jq -r '.worktree_path // empty')
    has_uncommitted=$(echo "$checkpoint_json" | jq -r '.has_uncommitted_changes // 0')
    uncommitted_diff=$(echo "$checkpoint_json" | jq -r '.uncommitted_diff // empty')
    stash_ref=$(echo "$checkpoint_json" | jq -r '.stash_ref // empty')

    if [[ ! -d "$worktree" ]]; then
        log_error "Worktree no longer exists: $worktree"
        return 1
    fi

    # Restore work if there were uncommitted changes
    if [[ "$has_uncommitted" -eq 1 ]]; then
        local method
        method=$(config_get 'recovery.preservation_method' 'diff')

        cd "$worktree" || return 1

        case "$method" in
            diff)
                if [[ -n "$uncommitted_diff" ]]; then
                    echo "$uncommitted_diff" | git apply --3way 2>/dev/null || \
                    echo "$uncommitted_diff" | git apply --reject 2>/dev/null || \
                    log_warn "Could not fully apply diff, some changes may be in .rej files"
                fi
                ;;
            stash)
                if [[ -n "$stash_ref" ]]; then
                    git stash pop "$stash_ref" 2>/dev/null || \
                    git stash apply "$stash_ref" 2>/dev/null || \
                    log_warn "Could not apply stash: $stash_ref"
                fi
                ;;
            temp_commit)
                # Temp commits are already in history, nothing to restore
                log_debug "Temp commit method - changes already in history"
                ;;
        esac

        log_info "Restored uncommitted work for thread: $thread_id"
    fi

    # Mark checkpoint as recovered
    db_exec "UPDATE work_checkpoints SET
                recovery_status = 'recovered',
                recovered_at = datetime('now')
             WHERE id = $checkpoint_id"

    # Clear interrupt status on thread
    db_exec "UPDATE threads SET
                interrupted_at = NULL,
                interrupt_reason = NULL
             WHERE id = $(db_quote "$thread_id")"

    log_info "Checkpoint restored: $checkpoint_id for thread $thread_id"

    bb_publish "CHECKPOINT_RESTORED" "{\"thread_id\": \"$thread_id\", \"checkpoint_id\": $checkpoint_id}" "$thread_id"

    return 0
}

# ============================================================
# Interrupted Thread Detection
# ============================================================

# Detect interrupted threads that need recovery
# Returns JSON array of threads with recovery info
checkpoint_detect_interrupted() {
    checkpoint_check

    # Find threads that appear to be interrupted:
    # 1. Status is 'running' but no PID file exists
    # 2. Have interrupted_at set
    # 3. Have dirty worktrees without running thread

    local interrupted_threads
    interrupted_threads=$(db_query "
        SELECT
            t.id,
            t.name,
            t.status,
            t.interrupted_at,
            t.interrupt_reason,
            t.worktree,
            wc.id as checkpoint_id,
            wc.checkpoint_type,
            wc.has_uncommitted_changes,
            wc.created_at as checkpoint_created,
            w.is_dirty,
            w.branch
        FROM threads t
        LEFT JOIN work_checkpoints wc ON wc.id = t.last_checkpoint_id
        LEFT JOIN worktrees w ON w.thread_id = t.id
        WHERE (
            t.interrupted_at IS NOT NULL
            OR (t.status = 'running' AND t.updated_at < datetime('now', '-5 minutes'))
        )
        AND t.status NOT IN ('completed', 'failed')
        ORDER BY t.updated_at DESC
    ")

    echo "$interrupted_threads"
}

# Check if a specific thread needs recovery
checkpoint_needs_recovery() {
    checkpoint_check
    local thread_id="$1"

    local needs_recovery
    needs_recovery=$(db_scalar "
        SELECT 1 FROM threads t
        LEFT JOIN work_checkpoints wc ON wc.thread_id = t.id AND wc.recovery_status = 'available'
        WHERE t.id = $(db_quote "$thread_id")
        AND (t.interrupted_at IS NOT NULL OR wc.id IS NOT NULL)
        LIMIT 1
    ")

    [[ "$needs_recovery" == "1" ]]
}

# ============================================================
# Checkpoint Management
# ============================================================

# List checkpoints for a thread
checkpoint_list() {
    checkpoint_check
    local thread_id="$1"
    local status="${2:-}"

    local where_clause="thread_id = $(db_quote "$thread_id")"
    if [[ -n "$status" ]]; then
        where_clause="$where_clause AND recovery_status = $(db_quote "$status")"
    fi

    db_query "SELECT * FROM work_checkpoints WHERE $where_clause ORDER BY created_at DESC"
}

# Abandon a checkpoint (mark as not needed)
checkpoint_abandon() {
    checkpoint_check
    local checkpoint_id="$1"

    db_exec "UPDATE work_checkpoints SET recovery_status = 'abandoned' WHERE id = $checkpoint_id"
    log_info "Checkpoint abandoned: $checkpoint_id"
}

# Cleanup old checkpoints
checkpoint_cleanup() {
    checkpoint_check
    local days="${1:-}"

    if [[ -z "$days" ]]; then
        days=$(config_get 'recovery.cleanup_after_days' '14')
    fi

    # Mark old checkpoints as expired
    db_exec "UPDATE work_checkpoints SET recovery_status = 'expired'
             WHERE recovery_status = 'available'
             AND created_at < datetime('now', '-$days days')"

    # Delete expired and abandoned checkpoints
    local deleted
    deleted=$(db_exec "DELETE FROM work_checkpoints
                       WHERE recovery_status IN ('expired', 'abandoned', 'recovered')
                       AND created_at < datetime('now', '-$days days')")

    log_info "Cleaned up checkpoints older than $days days"
}

# Get checkpoint statistics
checkpoint_stats() {
    checkpoint_check
    local thread_id="${1:-}"

    if [[ -n "$thread_id" ]]; then
        db_query "SELECT * FROM v_checkpoint_stats WHERE thread_id = $(db_quote "$thread_id")"
    else
        db_query "SELECT * FROM v_checkpoint_stats"
    fi
}

# ============================================================
# Periodic Checkpoint Timer
# ============================================================

# Should be called periodically from thread-runner to create checkpoints
checkpoint_periodic() {
    checkpoint_check
    local thread_id="$1"

    # Check if periodic checkpoints are enabled
    local strategy
    strategy=$(config_get 'recovery.checkpoint_strategy' 'all')
    if [[ "$strategy" == "signals" ]]; then
        return 0
    fi

    # Get interval from config
    local interval
    interval=$(config_get 'recovery.checkpoint_interval_minutes' '5')

    # Check last checkpoint time
    local last_checkpoint
    last_checkpoint=$(db_scalar "SELECT datetime(created_at) FROM work_checkpoints
                                 WHERE thread_id = $(db_quote "$thread_id")
                                 AND checkpoint_type = 'periodic'
                                 ORDER BY created_at DESC LIMIT 1")

    if [[ -n "$last_checkpoint" ]]; then
        # Check if enough time has passed
        local now_ts last_ts diff_minutes
        now_ts=$(date +%s)
        last_ts=$(date -j -f "%Y-%m-%d %H:%M:%S" "$last_checkpoint" +%s 2>/dev/null || \
                  date -d "$last_checkpoint" +%s 2>/dev/null || echo 0)

        if [[ "$last_ts" -gt 0 ]]; then
            diff_minutes=$(( (now_ts - last_ts) / 60 ))
            if [[ $diff_minutes -lt $interval ]]; then
                return 0
            fi
        fi
    fi

    # Check if there are uncommitted changes worth checkpointing
    local worktree
    worktree=$(db_scalar "SELECT worktree FROM threads WHERE id = $(db_quote "$thread_id")")

    if [[ -n "$worktree" && -d "$worktree" ]]; then
        if git_is_clean "$worktree"; then
            log_debug "No changes to checkpoint for thread: $thread_id"
            return 0
        fi
    fi

    # Create periodic checkpoint
    checkpoint_create "$thread_id" "periodic"
}

# ============================================================
# Recovery Workflow
# ============================================================

# Resume an interrupted thread
# Restores checkpoint and transitions thread back to ready state
checkpoint_resume() {
    checkpoint_check
    local thread_id="$1"

    # Restore checkpoint
    if ! checkpoint_restore "$thread_id"; then
        log_error "Failed to restore checkpoint for thread: $thread_id"
        return 1
    fi

    # Transition thread to ready state
    db_exec "UPDATE threads SET status = 'ready' WHERE id = $(db_quote "$thread_id")"

    log_info "Thread resumed: $thread_id"

    bb_publish "THREAD_RESUMED" "{\"thread_id\": \"$thread_id\"}" "$thread_id"

    return 0
}

# Auto-recover all interrupted threads
# Called from orchestrator on startup if auto_recover_on_startup is enabled
checkpoint_auto_recover() {
    checkpoint_check

    local auto_recover
    auto_recover=$(config_get 'recovery.auto_recover_on_startup' 'true')
    if [[ "$auto_recover" != "true" ]]; then
        log_debug "Auto-recovery disabled"
        return 0
    fi

    local auto_resume
    auto_resume=$(config_get 'recovery.auto_resume_interrupted' 'false')

    # Get interrupted threads
    local interrupted
    interrupted=$(checkpoint_detect_interrupted)

    echo "$interrupted" | jq -r '.[].id' 2>/dev/null | while read -r thread_id; do
        if [[ -n "$thread_id" ]]; then
            log_info "Found interrupted thread: $thread_id"

            if [[ "$auto_resume" == "true" ]]; then
                checkpoint_resume "$thread_id"
            else
                bb_publish "THREAD_RECOVERY_AVAILABLE" "{\"thread_id\": \"$thread_id\"}" "orchestrator"
            fi
        fi
    done
}
