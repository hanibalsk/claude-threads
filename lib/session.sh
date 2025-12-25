#!/usr/bin/env bash
#
# session.sh - Session management for claude-threads
#
# Provides session persistence, resume, fork, and context management
# following Claude Code SDK best practices (2025).
#

# Prevent multiple sourcing
[[ -n "${_CT_SESSION_LOADED:-}" ]] && return 0
_CT_SESSION_LOADED=1

# ============================================================
# Session ID Management
# ============================================================

# Generate a new session ID
session_generate_id() {
    echo "ses_$(date +%s)_$(head -c 8 /dev/urandom | xxd -p)"
}

# Get current session ID for a thread
session_get_id() {
    local thread_id="$1"
    db_scalar "SELECT session_id FROM threads WHERE id = $(db_quote "$thread_id")"
}

# Set session ID for a thread
session_set_id() {
    local thread_id="$1"
    local session_id="$2"

    db_exec "UPDATE threads SET session_id = $(db_quote "$session_id") WHERE id = $(db_quote "$thread_id")"

    # Create session history entry
    db_exec "INSERT INTO session_history (thread_id, session_id, status)
             VALUES ($(db_quote "$thread_id"), $(db_quote "$session_id"), 'active')"
}

# Start a new session for a thread
session_start() {
    local thread_id="$1"
    local parent_session_id="${2:-}"

    local session_id
    session_id=$(session_generate_id)

    if [[ -n "$parent_session_id" ]]; then
        # This is a forked session
        db_exec "INSERT INTO session_history (thread_id, session_id, parent_session_id, status)
                 VALUES ($(db_quote "$thread_id"), $(db_quote "$session_id"), $(db_quote "$parent_session_id"), 'active')"

        # Mark parent as forked
        db_exec "UPDATE session_history SET status = 'forked'
                 WHERE session_id = $(db_quote "$parent_session_id") AND status = 'active'"
    else
        db_exec "INSERT INTO session_history (thread_id, session_id, status)
                 VALUES ($(db_quote "$thread_id"), $(db_quote "$session_id"), 'active')"
    fi

    db_exec "UPDATE threads SET session_id = $(db_quote "$session_id") WHERE id = $(db_quote "$thread_id")"

    echo "$session_id"
}

# End a session
session_end() {
    local session_id="$1"
    local context_tokens="${2:-0}"

    db_exec "UPDATE session_history
             SET status = 'completed',
                 ended_at = datetime('now'),
                 context_tokens_end = $context_tokens
             WHERE session_id = $(db_quote "$session_id") AND status = 'active'"
}

# Fork a session (create new session preserving parent context)
session_fork() {
    local thread_id="$1"
    local parent_session_id
    parent_session_id=$(session_get_id "$thread_id")

    if [[ -z "$parent_session_id" ]]; then
        log_error "Cannot fork: no active session for thread $thread_id"
        return 1
    fi

    session_start "$thread_id" "$parent_session_id"
}

# Get session history for a thread
session_history() {
    local thread_id="$1"
    local limit="${2:-10}"

    db_query "SELECT session_id, parent_session_id, started_at, ended_at, status,
                     context_tokens_start, context_tokens_end, compactions_count
              FROM session_history
              WHERE thread_id = $(db_quote "$thread_id")
              ORDER BY started_at DESC
              LIMIT $limit"
}

# Resume a previous session
session_resume() {
    local session_id="$1"

    # Get thread ID for session
    local thread_id
    thread_id=$(db_scalar "SELECT thread_id FROM session_history WHERE session_id = $(db_quote "$session_id")")

    if [[ -z "$thread_id" ]]; then
        log_error "Session not found: $session_id"
        return 1
    fi

    # Check session status
    local status
    status=$(db_scalar "SELECT status FROM session_history WHERE session_id = $(db_quote "$session_id")")

    if [[ "$status" == "active" ]]; then
        # Already active, just return thread ID
        echo "$thread_id"
        return 0
    fi

    # Start a new session linked to the previous one
    local new_session_id
    new_session_id=$(session_start "$thread_id" "$session_id")

    log_info "Resumed session $session_id as $new_session_id for thread $thread_id"
    echo "$thread_id"
}

# ============================================================
# Context Token Management
# ============================================================

# Update context token count for a thread
session_update_tokens() {
    local thread_id="$1"
    local token_count="$2"

    db_exec "UPDATE threads SET context_tokens = $token_count WHERE id = $(db_quote "$thread_id")"
    db_exec "UPDATE session_history SET context_tokens_end = $token_count
             WHERE thread_id = $(db_quote "$thread_id") AND status = 'active'"
}

# Get context settings for a thread
session_get_context_settings() {
    local thread_id="$1"

    local settings
    settings=$(db_query "SELECT * FROM context_settings WHERE thread_id = $(db_quote "$thread_id")")

    if [[ -z "$settings" || "$settings" == "[]" ]]; then
        # Return defaults
        jq -n '{
            compaction_threshold: 50000,
            keep_recent_tool_uses: 5,
            excluded_tools: ["Task"],
            memory_enabled: true,
            checkpoint_interval_minutes: 30,
            auto_resume_enabled: true
        }'
    else
        echo "$settings" | jq '.[0]'
    fi
}

# Set context settings for a thread
session_set_context_settings() {
    local thread_id="$1"
    local settings="$2"

    local threshold keep_tools excluded memory_enabled checkpoint_interval auto_resume
    threshold=$(echo "$settings" | jq -r '.compaction_threshold // 50000')
    keep_tools=$(echo "$settings" | jq -r '.keep_recent_tool_uses // 5')
    excluded=$(echo "$settings" | jq -c '.excluded_tools // ["Task"]')
    memory_enabled=$(echo "$settings" | jq -r '.memory_enabled // true')
    checkpoint_interval=$(echo "$settings" | jq -r '.checkpoint_interval_minutes // 30')
    auto_resume=$(echo "$settings" | jq -r '.auto_resume_enabled // true')

    [[ "$memory_enabled" == "true" ]] && memory_enabled=1 || memory_enabled=0
    [[ "$auto_resume" == "true" ]] && auto_resume=1 || auto_resume=0

    db_exec "INSERT OR REPLACE INTO context_settings
             (thread_id, compaction_threshold, keep_recent_tool_uses, excluded_tools,
              memory_enabled, checkpoint_interval_minutes, auto_resume_enabled)
             VALUES ($(db_quote "$thread_id"), $threshold, $keep_tools, $(db_quote "$excluded"),
                     $memory_enabled, $checkpoint_interval, $auto_resume)"
}

# Record a context compaction event
session_record_compaction() {
    local thread_id="$1"
    local tokens_before="$2"
    local tokens_after="$3"

    db_exec "UPDATE threads SET context_compactions = context_compactions + 1 WHERE id = $(db_quote "$thread_id")"
    db_exec "UPDATE session_history SET compactions_count = compactions_count + 1
             WHERE thread_id = $(db_quote "$thread_id") AND status = 'active'"

    log_info "Context compaction for thread $thread_id: $tokens_before -> $tokens_after tokens"
}

# ============================================================
# Checkpoint Management
# ============================================================

# Create a checkpoint for a thread
checkpoint_create() {
    local thread_id="$1"
    local checkpoint_type="${2:-periodic}"
    local state_summary="${3:-}"
    local key_decisions="${4:-[]}"
    local pending_tasks="${5:-[]}"
    local context_snapshot="${6:-}"

    local session_id
    session_id=$(session_get_id "$thread_id")

    db_exec "INSERT INTO checkpoints
             (thread_id, session_id, checkpoint_type, state_summary, key_decisions, pending_tasks, context_snapshot)
             VALUES ($(db_quote "$thread_id"), $(db_quote "$session_id"), $(db_quote "$checkpoint_type"),
                     $(db_quote "$state_summary"), $(db_quote "$key_decisions"),
                     $(db_quote "$pending_tasks"), $(db_quote "$context_snapshot"))"

    db_exec "UPDATE threads SET last_checkpoint_at = datetime('now') WHERE id = $(db_quote "$thread_id")"
    db_exec "UPDATE session_history SET checkpoint_count = checkpoint_count + 1
             WHERE thread_id = $(db_quote "$thread_id") AND status = 'active'"

    log_debug "Checkpoint created for thread $thread_id (type: $checkpoint_type)"
}

# Get latest checkpoint for a thread
checkpoint_get_latest() {
    local thread_id="$1"

    db_query "SELECT * FROM checkpoints
              WHERE thread_id = $(db_quote "$thread_id")
              ORDER BY created_at DESC LIMIT 1" | jq '.[0] // null'
}

# Get checkpoints for a session
checkpoint_get_for_session() {
    local session_id="$1"

    db_query "SELECT * FROM checkpoints
              WHERE session_id = $(db_quote "$session_id")
              ORDER BY created_at DESC"
}

# Check if checkpoint is due
checkpoint_is_due() {
    local thread_id="$1"

    local settings
    settings=$(session_get_context_settings "$thread_id")
    local interval
    interval=$(echo "$settings" | jq -r '.checkpoint_interval_minutes')

    local last_checkpoint
    last_checkpoint=$(db_scalar "SELECT last_checkpoint_at FROM threads WHERE id = $(db_quote "$thread_id")")

    if [[ -z "$last_checkpoint" ]]; then
        return 0  # No checkpoint yet, one is due
    fi

    # Check if interval has passed
    local now_epoch last_epoch
    now_epoch=$(date +%s)
    last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_checkpoint" +%s 2>/dev/null || \
                date -d "$last_checkpoint" +%s 2>/dev/null || echo 0)

    local elapsed_minutes=$(( (now_epoch - last_epoch) / 60 ))

    [[ $elapsed_minutes -ge $interval ]]
}

# ============================================================
# Memory Management
# ============================================================

# Store a memory entry
memory_set() {
    local thread_id="$1"  # Can be empty for global memories
    local category="$2"
    local key="$3"
    local value="$4"
    local importance="${5:-5}"

    if [[ -z "$thread_id" ]]; then
        db_exec "INSERT OR REPLACE INTO memory_entries
                 (thread_id, category, key, value, importance, updated_at)
                 VALUES (NULL, $(db_quote "$category"), $(db_quote "$key"),
                         $(db_quote "$value"), $importance, datetime('now'))"
    else
        db_exec "INSERT OR REPLACE INTO memory_entries
                 (thread_id, category, key, value, importance, updated_at)
                 VALUES ($(db_quote "$thread_id"), $(db_quote "$category"), $(db_quote "$key"),
                         $(db_quote "$value"), $importance, datetime('now'))"
    fi
}

# Get a memory entry
memory_get() {
    local thread_id="$1"
    local category="$2"
    local key="$3"

    local result
    if [[ -z "$thread_id" ]]; then
        result=$(db_scalar "SELECT value FROM memory_entries
                           WHERE thread_id IS NULL AND category = $(db_quote "$category")
                           AND key = $(db_quote "$key")")
    else
        result=$(db_scalar "SELECT value FROM memory_entries
                           WHERE thread_id = $(db_quote "$thread_id") AND category = $(db_quote "$category")
                           AND key = $(db_quote "$key")")
    fi

    if [[ -n "$result" ]]; then
        # Update access count
        if [[ -z "$thread_id" ]]; then
            db_exec "UPDATE memory_entries SET access_count = access_count + 1, last_accessed_at = datetime('now')
                     WHERE thread_id IS NULL AND category = $(db_quote "$category") AND key = $(db_quote "$key")"
        else
            db_exec "UPDATE memory_entries SET access_count = access_count + 1, last_accessed_at = datetime('now')
                     WHERE thread_id = $(db_quote "$thread_id") AND category = $(db_quote "$category") AND key = $(db_quote "$key")"
        fi
    fi

    echo "$result"
}

# Get all memories for a thread (including global)
memory_get_all() {
    local thread_id="$1"
    local category="${2:-}"

    local sql="SELECT * FROM memory_entries WHERE (thread_id = $(db_quote "$thread_id") OR thread_id IS NULL)"
    [[ -n "$category" ]] && sql+=" AND category = $(db_quote "$category")"
    sql+=" ORDER BY importance DESC, updated_at DESC"

    db_query "$sql"
}

# Delete a memory entry
memory_delete() {
    local thread_id="$1"
    local category="$2"
    local key="$3"

    if [[ -z "$thread_id" ]]; then
        db_exec "DELETE FROM memory_entries
                 WHERE thread_id IS NULL AND category = $(db_quote "$category") AND key = $(db_quote "$key")"
    else
        db_exec "DELETE FROM memory_entries
                 WHERE thread_id = $(db_quote "$thread_id") AND category = $(db_quote "$category") AND key = $(db_quote "$key")"
    fi
}

# Cleanup expired memories
memory_cleanup_expired() {
    db_exec "DELETE FROM memory_entries WHERE expires_at IS NOT NULL AND expires_at < datetime('now')"
}

# Get memory summary for context injection
memory_get_context_summary() {
    local thread_id="$1"
    local max_entries="${2:-20}"

    # Get most important/recent memories
    local memories
    memories=$(db_query "SELECT category, key, value FROM memory_entries
                        WHERE (thread_id = $(db_quote "$thread_id") OR thread_id IS NULL)
                        ORDER BY importance DESC, updated_at DESC
                        LIMIT $max_entries")

    # Format as markdown for context injection
    echo "$memories" | jq -r '
        group_by(.category) |
        map("## " + .[0].category + "\n" + (map("- **" + .key + "**: " + .value) | join("\n"))) |
        join("\n\n")
    '
}

# ============================================================
# Coordination Management
# ============================================================

# Register agent with orchestrator session
coordination_register() {
    local orchestrator_session_id="$1"
    local agent_thread_id="$2"
    local agent_session_id="${3:-}"
    local checkpoint_interval="${4:-30}"

    local next_checkpoint
    next_checkpoint=$(date -v+${checkpoint_interval}M "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                     date -d "+${checkpoint_interval} minutes" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)

    db_exec "INSERT OR REPLACE INTO session_coordination
             (orchestrator_session_id, agent_thread_id, agent_session_id,
              coordination_state, next_checkpoint_at)
             VALUES ($(db_quote "$orchestrator_session_id"), $(db_quote "$agent_thread_id"),
                     $(db_quote "$agent_session_id"), 'active', $(db_quote "$next_checkpoint"))"
}

# Update coordination state
coordination_update_state() {
    local agent_thread_id="$1"
    local state="$2"
    local shared_context="${3:-}"

    if [[ -n "$shared_context" ]]; then
        db_exec "UPDATE session_coordination
                 SET coordination_state = $(db_quote "$state"),
                     last_sync_at = datetime('now'),
                     shared_context = $(db_quote "$shared_context")
                 WHERE agent_thread_id = $(db_quote "$agent_thread_id")"
    else
        db_exec "UPDATE session_coordination
                 SET coordination_state = $(db_quote "$state"), last_sync_at = datetime('now')
                 WHERE agent_thread_id = $(db_quote "$agent_thread_id")"
    fi
}

# Get agents needing checkpoint
coordination_get_due_checkpoints() {
    db_query "SELECT * FROM session_coordination
              WHERE coordination_state = 'active'
              AND next_checkpoint_at <= datetime('now')"
}

# Get all coordinated agents for an orchestrator session
coordination_get_agents() {
    local orchestrator_session_id="$1"

    db_query "SELECT sc.*, t.name, t.status
              FROM session_coordination sc
              JOIN threads t ON sc.agent_thread_id = t.id
              WHERE sc.orchestrator_session_id = $(db_quote "$orchestrator_session_id")"
}

# ============================================================
# Session Notes Management
# ============================================================

SESSION_NOTES_FILE="SESSION_NOTES.md"

# Initialize session notes file
session_notes_init() {
    local data_dir="$1"
    local notes_file="$data_dir/$SESSION_NOTES_FILE"

    if [[ ! -f "$notes_file" ]]; then
        cat > "$notes_file" << 'EOF'
# Session Notes

This file maintains context across sessions for quick resumption.
Updated automatically by the orchestrator.

## Current State

_No active state recorded._

## Key Decisions

_No decisions recorded._

## Pending Tasks

_No pending tasks._

## Recent Activity

_No recent activity._
EOF
    fi
}

# Update session notes
session_notes_update() {
    local data_dir="$1"
    local section="$2"
    local content="$3"
    local notes_file="$data_dir/$SESSION_NOTES_FILE"

    # Create if doesn't exist
    [[ ! -f "$notes_file" ]] && session_notes_init "$data_dir"

    # Update the specified section
    local temp_file
    temp_file=$(mktemp)

    awk -v section="$section" -v content="$content" '
        BEGIN { in_section = 0; printed = 0 }
        /^## / {
            if (in_section && !printed) {
                print content
                print ""
                printed = 1
            }
            in_section = ($0 ~ "^## " section)
        }
        {
            if (!in_section) print
            else if (/^## /) { print; getline }
        }
        END {
            if (in_section && !printed) {
                print content
            }
        }
    ' "$notes_file" > "$temp_file"

    mv "$temp_file" "$notes_file"
}

# Get session notes content
session_notes_get() {
    local data_dir="$1"
    local notes_file="$data_dir/$SESSION_NOTES_FILE"

    if [[ -f "$notes_file" ]]; then
        cat "$notes_file"
    else
        echo "_No session notes available._"
    fi
}

# ============================================================
# Claude CLI Integration
# ============================================================

# Build Claude CLI resume flags
session_build_resume_flags() {
    local session_id="$1"

    if [[ -n "$session_id" ]]; then
        echo "--resume $session_id"
    fi
}

# Build Claude CLI context management flags
session_build_context_flags() {
    local thread_id="$1"

    local settings
    settings=$(session_get_context_settings "$thread_id")

    local threshold keep_tools
    threshold=$(echo "$settings" | jq -r '.compaction_threshold')
    keep_tools=$(echo "$settings" | jq -r '.keep_recent_tool_uses')

    # These would be used in API calls, not CLI
    echo "--context-threshold $threshold --keep-tools $keep_tools"
}
