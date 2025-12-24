#!/usr/bin/env bash
#
# blackboard.sh - Blackboard pattern implementation for inter-thread communication
#
# The blackboard provides a shared information bus where threads can:
# - Publish events that others can subscribe to
# - Send direct messages to specific threads
# - Share artifacts (files, data)
#
# Usage:
#   source lib/blackboard.sh
#   bb_init
#   bb_publish "STORY_COMPLETED" '{"story_id": "41.1"}'
#   bb_subscribe "my-thread" "STORY_COMPLETED"
#

# Prevent double-sourcing
[[ -n "${_CT_BB_LOADED:-}" ]] && return 0
_CT_BB_LOADED=1

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/db.sh"

# ============================================================
# Configuration
# ============================================================

_BB_DATA_DIR=""
_BB_ARTIFACTS_DIR=""

# ============================================================
# Initialization
# ============================================================

# Initialize blackboard
bb_init() {
    local data_dir="${1:-$(ct_data_dir)}"

    _BB_DATA_DIR="$data_dir/blackboard"
    _BB_ARTIFACTS_DIR="$data_dir/artifacts"

    mkdir -p "$_BB_DATA_DIR" "$_BB_ARTIFACTS_DIR"

    # Ensure database is initialized
    db_init "$data_dir"

    log_debug "Blackboard initialized"
}

# ============================================================
# Event Publishing
# ============================================================

# Publish an event to the blackboard
bb_publish() {
    local type="$1"
    local data="${2:-{}}"
    local source="${3:-orchestrator}"
    local targets="${4:-*}"

    # Validate JSON
    if ! echo "$data" | jq empty 2>/dev/null; then
        ct_error "Invalid JSON data for event: $data"
        return 1
    fi

    db_event_publish "$source" "$type" "$data" "$targets"

    log_debug "Event published: $type from $source"
}

# Publish event with automatic source detection
bb_emit() {
    local type="$1"
    local data="${2:-{}}"

    # Use current thread ID if set
    local source="${CT_CURRENT_THREAD:-orchestrator}"

    bb_publish "$type" "$data" "$source"
}

# ============================================================
# Event Subscription
# ============================================================

# Get pending events for a thread
bb_poll() {
    local thread_id="$1"
    local event_types="${2:-}"  # Optional: comma-separated list of types to filter

    local events
    events=$(db_events_pending "$thread_id")

    # Filter by type if specified
    if [[ -n "$event_types" ]]; then
        events=$(echo "$events" | jq --arg types "$event_types" '
            [.[] | select(.type as $t | ($types | split(",") | map(. == $t) | any))]
        ')
    fi

    echo "$events"
}

# Wait for a specific event type
bb_wait_for() {
    local thread_id="$1"
    local event_type="$2"
    local timeout="${3:-60}"  # seconds

    local start_time
    start_time=$(date +%s)

    while true; do
        local events
        events=$(bb_poll "$thread_id" "$event_type")

        if [[ $(echo "$events" | jq 'length') -gt 0 ]]; then
            echo "$events" | jq '.[0]'
            return 0
        fi

        local elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -ge $timeout ]]; then
            log_warn "Timeout waiting for event: $event_type"
            return 1
        fi

        sleep 1
    done
}

# Mark events as processed
bb_ack() {
    local event_ids="$1"  # Comma-separated list of IDs

    IFS=',' read -ra ids <<< "$event_ids"
    for id in "${ids[@]}"; do
        db_event_mark_processed "$id"
    done

    log_debug "Events acknowledged: $event_ids"
}

# ============================================================
# Direct Messaging
# ============================================================

# Send a direct message to a thread
bb_send() {
    local to_thread="$1"
    local type="$2"
    local content="${3:-{}}"
    local priority="${4:-0}"

    local from_thread="${CT_CURRENT_THREAD:-orchestrator}"

    db_message_send "$from_thread" "$to_thread" "$type" "$content" "$priority"

    log_debug "Message sent: $type to $to_thread"
}

# Get unread messages for a thread
bb_inbox() {
    local thread_id="$1"
    db_messages_unread "$thread_id"
}

# Mark message as read
bb_read() {
    local message_id="$1"
    db_message_mark_read "$message_id"
}

# Reply to a message
bb_reply() {
    local original_message_id="$1"
    local content="$2"

    # Get original message info
    local original
    original=$(db_query "SELECT from_thread, type FROM messages WHERE id = $original_message_id" | jq '.[0]')

    local to_thread
    to_thread=$(echo "$original" | jq -r '.from_thread')

    local type
    type=$(echo "$original" | jq -r '.type')

    bb_send "$to_thread" "RE:$type" "$content"
}

# ============================================================
# Artifact Sharing
# ============================================================

# Store an artifact
bb_store_artifact() {
    local name="$1"
    local type="$2"
    local content="$3"  # Either file path or inline content
    local metadata="${4:-{}}"

    local thread_id="${CT_CURRENT_THREAD:-}"
    local artifact_id
    artifact_id=$(ct_generate_id "artifact")

    # Determine if content is a file path or inline
    local path=""
    local stored_content=""

    if [[ -f "$content" ]]; then
        # Copy file to artifacts directory
        path="$_BB_ARTIFACTS_DIR/$artifact_id/$(basename "$content")"
        mkdir -p "$(dirname "$path")"
        cp "$content" "$path"
        path="${path#$_BB_ARTIFACTS_DIR/}"
    else
        # Store inline
        stored_content="$content"
    fi

    db_exec "INSERT INTO artifacts (thread_id, type, name, path, content, metadata)
             VALUES ($(db_quote "$thread_id"), $(db_quote "$type"),
                     $(db_quote "$name"), $(db_quote "$path"),
                     $(db_quote "$stored_content"), $(db_quote "$metadata"))"

    log_debug "Artifact stored: $name (type=$type)"

    echo "$artifact_id"
}

# Get artifact by name
bb_get_artifact() {
    local name="$1"

    local artifact
    artifact=$(db_query "SELECT * FROM artifacts WHERE name = $(db_quote "$name") ORDER BY created_at DESC LIMIT 1" | jq '.[0] // empty')

    if [[ -z "$artifact" ]]; then
        return 1
    fi

    local path
    path=$(echo "$artifact" | jq -r '.path // empty')

    if [[ -n "$path" ]]; then
        cat "$_BB_ARTIFACTS_DIR/$path"
    else
        echo "$artifact" | jq -r '.content'
    fi
}

# List artifacts
bb_list_artifacts() {
    local thread_id="${1:-}"
    local type="${2:-}"

    local sql="SELECT id, name, type, created_at FROM artifacts WHERE 1=1"
    [[ -n "$thread_id" ]] && sql+=" AND thread_id = $(db_quote "$thread_id")"
    [[ -n "$type" ]] && sql+=" AND type = $(db_quote "$type")"
    sql+=" ORDER BY created_at DESC"

    db_query "$sql"
}

# ============================================================
# Convenience Event Types
# ============================================================

# Standard event types
readonly BB_EVENT_THREAD_STARTED="THREAD_STARTED"
readonly BB_EVENT_THREAD_COMPLETED="THREAD_COMPLETED"
readonly BB_EVENT_THREAD_FAILED="THREAD_FAILED"
readonly BB_EVENT_THREAD_BLOCKED="THREAD_BLOCKED"
readonly BB_EVENT_PHASE_CHANGED="PHASE_CHANGED"
readonly BB_EVENT_STORY_STARTED="STORY_STARTED"
readonly BB_EVENT_STORY_COMPLETED="STORY_COMPLETED"
readonly BB_EVENT_PR_CREATED="PR_CREATED"
readonly BB_EVENT_PR_MERGED="PR_MERGED"
readonly BB_EVENT_PR_UPDATED="PR_UPDATED"
readonly BB_EVENT_REVIEW_REQUESTED="REVIEW_REQUESTED"
readonly BB_EVENT_REVIEW_COMPLETED="REVIEW_COMPLETED"
readonly BB_EVENT_CI_PASSED="CI_PASSED"
readonly BB_EVENT_CI_FAILED="CI_FAILED"

# Helper to publish common events
bb_story_completed() {
    local story_id="$1"
    local commit="${2:-}"

    bb_emit "$BB_EVENT_STORY_COMPLETED" "$(ct_json_object \
        "story_id" "$story_id" \
        "commit" "$commit")"
}

bb_pr_created() {
    local pr_number="$1"
    local branch="${2:-}"

    bb_emit "$BB_EVENT_PR_CREATED" "$(ct_json_object \
        "pr_number" "$pr_number" \
        "branch" "$branch")"
}

bb_ci_status() {
    local status="$1"  # "passed" or "failed"
    local details="${2:-{}}"

    if [[ "$status" == "passed" ]]; then
        bb_emit "$BB_EVENT_CI_PASSED" "$details"
    else
        bb_emit "$BB_EVENT_CI_FAILED" "$details"
    fi
}

# ============================================================
# PR Shepherd Events
# ============================================================

# PR-specific event types
readonly BB_EVENT_PR_STATE_CHANGED="PR_STATE_CHANGED"
readonly BB_EVENT_PR_FIX_STARTED="PR_FIX_STARTED"
readonly BB_EVENT_PR_FIX_COMPLETED="PR_FIX_COMPLETED"
readonly BB_EVENT_PR_READY_TO_MERGE="PR_READY_TO_MERGE"
readonly BB_EVENT_PR_MAX_ATTEMPTS="PR_MAX_ATTEMPTS_REACHED"
readonly BB_EVENT_PR_WATCH_STARTED="PR_WATCH_STARTED"
readonly BB_EVENT_PR_WATCH_STOPPED="PR_WATCH_STOPPED"

# Subscribe to PR events for a thread
bb_subscribe_pr_events() {
    local thread_id="$1"
    local pr_number="$2"

    # This is a conceptual subscription - we filter events when polling
    # Store subscription in thread context
    db_exec "UPDATE threads SET context = json_set(context, '\$.pr_subscription', $pr_number)
             WHERE id = $(db_quote "$thread_id")"

    log_debug "Thread $thread_id subscribed to PR #$pr_number events"
}

# Poll for PR-specific events
bb_poll_pr_events() {
    local thread_id="$1"
    local pr_number="$2"

    local events
    events=$(db_query "SELECT * FROM events
                       WHERE processed = 0
                       AND type LIKE 'PR_%'
                       AND json_extract(data, '\$.pr_number') = $pr_number
                       ORDER BY timestamp ASC")

    echo "$events"
}

# Wait for PR to reach a specific state
bb_wait_for_pr_state() {
    local pr_number="$1"
    local target_state="$2"
    local timeout="${3:-3600}"  # 1 hour default

    local start_time
    start_time=$(date +%s)

    while true; do
        local current_state
        current_state=$(db_scalar "SELECT state FROM pr_watches WHERE pr_number = $pr_number" 2>/dev/null || echo "unknown")

        if [[ "$current_state" == "$target_state" ]]; then
            return 0
        fi

        # Check for terminal states
        if [[ "$current_state" == "merged" || "$current_state" == "closed" ]]; then
            log_info "PR #$pr_number reached terminal state: $current_state"
            return 1
        fi

        local elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -ge $timeout ]]; then
            log_warn "Timeout waiting for PR #$pr_number to reach state: $target_state"
            return 1
        fi

        sleep 10
    done
}

# ============================================================
# Event History
# ============================================================

# Get event history
bb_history() {
    local limit="${1:-100}"
    local event_type="${2:-}"
    local source="${3:-}"

    local sql="SELECT * FROM events WHERE 1=1"
    [[ -n "$event_type" ]] && sql+=" AND type = $(db_quote "$event_type")"
    [[ -n "$source" ]] && sql+=" AND source = $(db_quote "$source")"
    sql+=" ORDER BY timestamp DESC LIMIT $limit"

    db_query "$sql"
}

# Get event count by type
bb_stats() {
    db_query "SELECT type, COUNT(*) as count, MAX(timestamp) as last_event
              FROM events
              GROUP BY type
              ORDER BY count DESC"
}
