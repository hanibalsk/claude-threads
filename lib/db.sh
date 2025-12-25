#!/usr/bin/env bash
#
# db.sh - SQLite database operations for claude-threads
#
# Provides thread-safe database access with proper locking.
#
# Usage:
#   source lib/db.sh
#   db_init "/path/to/data"
#   db_exec "INSERT INTO threads ..."
#   db_query "SELECT * FROM threads"
#

# Prevent double-sourcing
[[ -n "${_CT_DB_LOADED:-}" ]] && return 0
_CT_DB_LOADED=1

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/log.sh"

# ============================================================
# Configuration
# ============================================================

_DB_PATH=""
_DB_INITIALIZED=0
_DB_TIMEOUT=5000  # SQLite busy timeout in ms

# ============================================================
# Initialization
# ============================================================

# Initialize database connection
db_init() {
    local data_dir="${1:-$(ct_data_dir)}"

    ct_require_cmd "sqlite3" "SQLite3 is required but not installed" || return 1

    # Ensure data_dir is absolute path (critical for worktree support)
    if [[ ! "$data_dir" = /* ]]; then
        data_dir="$(cd "$(dirname "$data_dir")" 2>/dev/null && pwd)/$(basename "$data_dir")"
    fi

    _DB_PATH="$data_dir/threads.db"

    # Create data directory
    mkdir -p "$data_dir"

    # Check if database needs initialization
    if [[ ! -f "$_DB_PATH" ]]; then
        log_info "Creating new database at $_DB_PATH"
        _db_create_schema
    fi

    _DB_INITIALIZED=1
    log_debug "Database initialized: $_DB_PATH"
}

# Create database schema
_db_create_schema() {
    local schema_file
    schema_file="$(ct_root_dir)/sql/schema.sql"

    if [[ ! -f "$schema_file" ]]; then
        ct_error "Schema file not found: $schema_file"
        return 1
    fi

    sqlite3 "$_DB_PATH" < "$schema_file"
    log_info "Database schema created"
}

# Check if database is initialized
db_check() {
    if [[ $_DB_INITIALIZED -ne 1 ]]; then
        ct_error "Database not initialized. Call db_init first."
        return 1
    fi
}

# ============================================================
# Core operations
# ============================================================

# Execute a SQL statement (INSERT, UPDATE, DELETE)
db_exec() {
    db_check || return 1

    local sql="$1"
    shift

    log_trace "db_exec: $sql"

    sqlite3 -bail "$_DB_PATH" \
        -cmd ".timeout $_DB_TIMEOUT" \
        "$sql" "$@" 2>&1

    local rc=$?
    if [[ $rc -ne 0 ]]; then
        log_error "Database error executing: $sql"
        return $rc
    fi
}

# Query the database (SELECT)
db_query() {
    db_check || return 1

    local sql="$1"
    shift

    log_trace "db_query: $sql"

    sqlite3 -bail "$_DB_PATH" \
        -cmd ".timeout $_DB_TIMEOUT" \
        -cmd ".mode json" \
        "$sql" "$@" 2>&1
}

# Query returning single value
db_scalar() {
    db_check || return 1

    local sql="$1"

    sqlite3 -bail "$_DB_PATH" \
        -cmd ".timeout $_DB_TIMEOUT" \
        "$sql" 2>&1
}

# Query returning single row as variables
db_row() {
    db_check || return 1

    local sql="$1"

    sqlite3 -bail "$_DB_PATH" \
        -cmd ".timeout $_DB_TIMEOUT" \
        -cmd ".mode line" \
        "$sql" 2>&1
}

# Query returning CSV
db_csv() {
    db_check || return 1

    local sql="$1"

    sqlite3 -bail "$_DB_PATH" \
        -cmd ".timeout $_DB_TIMEOUT" \
        -cmd ".mode csv" \
        -cmd ".headers on" \
        "$sql" 2>&1
}

# ============================================================
# Transaction support
# ============================================================

# Begin a transaction
db_begin() {
    db_exec "BEGIN IMMEDIATE"
}

# Commit a transaction
db_commit() {
    db_exec "COMMIT"
}

# Rollback a transaction
db_rollback() {
    db_exec "ROLLBACK"
}

# Execute multiple statements in a transaction
db_transaction() {
    local statements="$1"

    db_exec "BEGIN IMMEDIATE; $statements; COMMIT" 2>&1 || {
        db_exec "ROLLBACK"
        return 1
    }
}

# ============================================================
# Prepared statement helpers
# ============================================================

# Escape a string for SQLite
db_escape() {
    local str="$1"
    echo "${str//\'/\'\'}"
}

# Quote a string for SQLite
db_quote() {
    local str="$1"
    echo "'$(db_escape "$str")'"
}

# ============================================================
# Thread operations
# ============================================================

# Insert a new thread
db_thread_create() {
    local id="$1"
    local name="$2"
    local mode="${3:-automatic}"
    local template="${4:-}"
    local workflow="${5:-}"
    local config="${6:-"{}"}"
    local context="${7:-"{}"}"

    db_exec "INSERT INTO threads (id, name, mode, status, template, workflow, config, context)
             VALUES ($(db_quote "$id"), $(db_quote "$name"), $(db_quote "$mode"), 'created',
                     $(db_quote "$template"), $(db_quote "$workflow"),
                     $(db_quote "$config"), $(db_quote "$context"))"
}

# Get a thread by ID
db_thread_get() {
    local id="$1"
    db_query "SELECT * FROM threads WHERE id = $(db_quote "$id")" | jq '.[0] // empty'
}

# Update thread status
db_thread_set_status() {
    local id="$1"
    local status="$2"

    if ! ct_validate_status "$status"; then
        ct_error "Invalid status: $status"
        return 1
    fi

    db_exec "UPDATE threads SET status = $(db_quote "$status") WHERE id = $(db_quote "$id")"
}

# Update thread phase
db_thread_set_phase() {
    local id="$1"
    local phase="$2"

    db_exec "UPDATE threads SET phase = $(db_quote "$phase") WHERE id = $(db_quote "$id")"
}

# Update thread session
db_thread_set_session() {
    local id="$1"
    local session_id="$2"

    db_exec "UPDATE threads SET session_id = $(db_quote "$session_id") WHERE id = $(db_quote "$id")"
}

# Update thread context
db_thread_update_context() {
    local id="$1"
    local context="$2"

    db_exec "UPDATE threads SET context = json_patch(context, $(db_quote "$context")) WHERE id = $(db_quote "$id")"
}

# List threads by status
db_threads_by_status() {
    local status="$1"
    db_query "SELECT * FROM threads WHERE status = $(db_quote "$status") ORDER BY updated_at DESC"
}

# List active threads
db_threads_active() {
    db_query "SELECT * FROM v_active_threads ORDER BY updated_at DESC"
}

# ============================================================
# Event operations
# ============================================================

# Publish an event
db_event_publish() {
    local source="$1"
    local type="$2"
    local data="${3:-"{}"}"
    local targets="${4:-*}"

    db_exec "INSERT INTO events (source, type, data, targets)
             VALUES ($(db_quote "$source"), $(db_quote "$type"),
                     $(db_quote "$data"), $(db_quote "$targets"))"
}

# Get pending events for a thread
db_events_pending() {
    local thread_id="$1"
    local since="${2:-}"

    local sql="SELECT * FROM events WHERE processed = 0
               AND (targets = '*' OR targets LIKE '%\"${thread_id}\"%')"

    if [[ -n "$since" ]]; then
        sql+=" AND timestamp > $(db_quote "$since")"
    fi

    sql+=" ORDER BY timestamp ASC"

    db_query "$sql"
}

# Mark event as processed
db_event_mark_processed() {
    local event_id="$1"

    db_exec "UPDATE events SET processed = 1, processed_at = datetime('now')
             WHERE id = $event_id"
}

# ============================================================
# Message operations
# ============================================================

# Send a message to a thread
db_message_send() {
    local from_thread="$1"
    local to_thread="$2"
    local type="$3"
    local content="${4:-"{}"}"
    local priority="${5:-0}"

    db_exec "INSERT INTO messages (from_thread, to_thread, type, content, priority)
             VALUES ($(db_quote "$from_thread"), $(db_quote "$to_thread"),
                     $(db_quote "$type"), $(db_quote "$content"), $priority)"
}

# Get unread messages for a thread
db_messages_unread() {
    local thread_id="$1"

    db_query "SELECT * FROM v_inbox WHERE to_thread = $(db_quote "$thread_id")"
}

# Mark message as read
db_message_mark_read() {
    local message_id="$1"

    db_exec "UPDATE messages SET read_at = datetime('now') WHERE id = $message_id"
}

# ============================================================
# Session operations
# ============================================================

# Create or update session
db_session_upsert() {
    local session_id="$1"
    local thread_id="$2"

    db_exec "INSERT INTO sessions (id, thread_id)
             VALUES ($(db_quote "$session_id"), $(db_quote "$thread_id"))
             ON CONFLICT(id) DO UPDATE SET
                 thread_id = $(db_quote "$thread_id"),
                 last_activity = datetime('now')"
}

# Update session stats
db_session_update() {
    local session_id="$1"
    local turns="${2:-0}"
    local tokens="${3:-0}"

    db_exec "UPDATE sessions SET
                 turns = turns + $turns,
                 tokens_used = tokens_used + $tokens,
                 last_activity = datetime('now')
             WHERE id = $(db_quote "$session_id")"
}

# ============================================================
# Cleanup operations
# ============================================================

# Clean up old events
db_cleanup_events() {
    local days="${1:-7}"

    db_exec "DELETE FROM events
             WHERE processed = 1
             AND timestamp < datetime('now', '-$days days')"
}

# Clean up old messages
db_cleanup_messages() {
    local days="${1:-30}"

    db_exec "DELETE FROM messages
             WHERE read_at IS NOT NULL
             AND created_at < datetime('now', '-$days days')"
}

# Vacuum database
db_vacuum() {
    log_info "Vacuuming database..."
    sqlite3 "$_DB_PATH" "VACUUM"
}

# ============================================================
# PR Comment operations
# ============================================================

# Insert or update a PR comment
db_pr_comment_upsert() {
    local pr_number="$1"
    local github_comment_id="$2"
    local thread_id="$3"
    local path="$4"
    local line="$5"
    local body="$6"
    local author="$7"

    db_exec "INSERT INTO pr_comments (pr_number, github_comment_id, thread_id, path, line, body, author)
             VALUES ($pr_number, $(db_quote "$github_comment_id"), $(db_quote "$thread_id"),
                     $(db_quote "$path"), $line, $(db_quote "$body"), $(db_quote "$author"))
             ON CONFLICT(github_comment_id) DO UPDATE SET
                 body = $(db_quote "$body"),
                 updated_at = datetime('now')"
}

# Get pending comments for a PR
db_pr_comments_pending() {
    local pr_number="$1"
    db_query "SELECT * FROM pr_comments WHERE pr_number = $pr_number AND state IN ('pending', 'responded') ORDER BY created_at ASC"
}

# Get all comments for a PR
db_pr_comments_get() {
    local pr_number="$1"
    db_query "SELECT * FROM pr_comments WHERE pr_number = $pr_number ORDER BY created_at ASC"
}

# Update comment state
db_pr_comment_set_state() {
    local comment_id="$1"
    local state="$2"
    local response_text="${3:-}"

    if [[ -n "$response_text" ]]; then
        db_exec "UPDATE pr_comments SET state = $(db_quote "$state"), response_text = $(db_quote "$response_text"), response_at = datetime('now') WHERE id = $comment_id"
    else
        db_exec "UPDATE pr_comments SET state = $(db_quote "$state") WHERE id = $comment_id"
    fi
}

# Set comment handler thread
db_pr_comment_set_handler() {
    local comment_id="$1"
    local handler_thread_id="$2"

    db_exec "UPDATE pr_comments SET handler_thread_id = $(db_quote "$handler_thread_id") WHERE id = $comment_id"
}

# Get comment by ID
db_pr_comment_get() {
    local comment_id="$1"
    db_query "SELECT * FROM pr_comments WHERE id = $comment_id" | jq '.[0] // empty'
}

# Count comments by state for a PR
db_pr_comments_count() {
    local pr_number="$1"
    db_query "SELECT state, COUNT(*) as count FROM pr_comments WHERE pr_number = $pr_number GROUP BY state"
}

# ============================================================
# Merge Conflict operations
# ============================================================

# Create a merge conflict record
db_merge_conflict_create() {
    local pr_number="$1"
    local target_branch="$2"
    local conflicting_files="$3"  # JSON array

    db_exec "INSERT INTO merge_conflicts (pr_number, target_branch, conflicting_files)
             VALUES ($pr_number, $(db_quote "$target_branch"), $(db_quote "$conflicting_files"))"

    # Return the ID of the new record
    db_scalar "SELECT last_insert_rowid()"
}

# Get active conflict for a PR
db_merge_conflict_get_active() {
    local pr_number="$1"
    db_query "SELECT * FROM merge_conflicts WHERE pr_number = $pr_number AND resolution_status NOT IN ('resolved', 'manual_required') ORDER BY detected_at DESC LIMIT 1" | jq '.[0] // empty'
}

# Update conflict status
db_merge_conflict_set_status() {
    local conflict_id="$1"
    local status="$2"
    local notes="${3:-}"

    local sql="UPDATE merge_conflicts SET resolution_status = $(db_quote "$status"), resolution_attempts = resolution_attempts + 1"

    if [[ "$status" == "resolved" ]]; then
        sql+=", resolved_at = datetime('now')"
    fi

    if [[ -n "$notes" ]]; then
        sql+=", resolution_notes = $(db_quote "$notes")"
    fi

    sql+=" WHERE id = $conflict_id"

    db_exec "$sql"
}

# Set conflict resolver thread
db_merge_conflict_set_resolver() {
    local conflict_id="$1"
    local thread_id="$2"

    db_exec "UPDATE merge_conflicts SET resolution_thread_id = $(db_quote "$thread_id"), resolution_status = 'resolving' WHERE id = $conflict_id"
}

# Get conflict by ID
db_merge_conflict_get() {
    local conflict_id="$1"
    db_query "SELECT * FROM merge_conflicts WHERE id = $conflict_id" | jq '.[0] // empty'
}

# ============================================================
# PR Config operations
# ============================================================

# Get or create PR config
db_pr_config_get() {
    local pr_number="$1"

    # Try to get existing config
    local config
    config=$(db_query "SELECT * FROM pr_config WHERE pr_number = $pr_number" | jq '.[0] // empty')

    if [[ -z "$config" || "$config" == "null" ]]; then
        # Create default config
        db_exec "INSERT INTO pr_config (pr_number) VALUES ($pr_number)"
        config=$(db_query "SELECT * FROM pr_config WHERE pr_number = $pr_number" | jq '.[0] // empty')
    fi

    echo "$config"
}

# Update PR config
db_pr_config_update() {
    local pr_number="$1"
    local auto_merge="${2:-}"
    local interactive_mode="${3:-}"
    local poll_interval="${4:-}"

    local sql="UPDATE pr_config SET updated_at = datetime('now')"

    [[ -n "$auto_merge" ]] && sql+=", auto_merge = $auto_merge"
    [[ -n "$interactive_mode" ]] && sql+=", interactive_mode = $interactive_mode"
    [[ -n "$poll_interval" ]] && sql+=", poll_interval_seconds = $poll_interval"

    sql+=" WHERE pr_number = $pr_number"

    db_exec "$sql"
}

# ============================================================
# PR Watch extensions
# ============================================================

# Update PR watch comment counts
db_pr_watch_update_comments() {
    local pr_number="$1"
    local pending="$2"
    local responded="$3"
    local resolved="$4"

    db_exec "UPDATE pr_watches SET
             comments_pending = $pending,
             comments_responded = $responded,
             comments_resolved = $resolved,
             updated_at = datetime('now')
             WHERE pr_number = $pr_number"
}

# Update PR watch conflict status
db_pr_watch_set_conflict() {
    local pr_number="$1"
    local has_conflict="$2"

    db_exec "UPDATE pr_watches SET
             has_merge_conflict = $has_conflict,
             updated_at = datetime('now')
             WHERE pr_number = $pr_number"
}

# Update PR watch last poll time
db_pr_watch_set_polled() {
    local pr_number="$1"

    db_exec "UPDATE pr_watches SET
             last_poll_at = datetime('now'),
             updated_at = datetime('now')
             WHERE pr_number = $pr_number"
}

# Get PR lifecycle status
db_pr_lifecycle_status() {
    local pr_number="$1"
    db_query "SELECT * FROM v_pr_lifecycle_status WHERE pr_number = $pr_number" | jq '.[0] // empty'
}

# Get all PRs needing polling
db_pr_watches_needing_poll() {
    local default_interval="${1:-30}"

    db_query "SELECT pw.*,
              COALESCE(pc.poll_interval_seconds, pw.poll_interval_seconds, $default_interval) as effective_interval
              FROM pr_watches pw
              LEFT JOIN pr_config pc ON pw.pr_number = pc.pr_number
              WHERE pw.state NOT IN ('merged', 'closed')
              AND (pw.last_poll_at IS NULL
                   OR datetime(pw.last_poll_at, '+' || COALESCE(pc.poll_interval_seconds, pw.poll_interval_seconds, $default_interval) || ' seconds') < datetime('now'))
              ORDER BY pw.last_poll_at ASC NULLS FIRST"
}
