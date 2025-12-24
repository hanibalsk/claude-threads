#!/usr/bin/env bash
#
# claude.sh - Claude CLI wrapper for claude-threads
#
# Provides high-level functions for interacting with Claude Code CLI,
# including session management, prompt execution, and output parsing.
#
# Usage:
#   source lib/claude.sh
#   claude_init
#   session_id=$(claude_start_session "thread-123" "automatic")
#   claude_execute "$session_id" "Implement story 41.1"
#

# Prevent double-sourcing
[[ -n "${_CT_CLAUDE_LOADED:-}" ]] && return 0
_CT_CLAUDE_LOADED=1

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/db.sh"

# ============================================================
# Configuration
# ============================================================

# Claude CLI settings
CLAUDE_CMD="${CLAUDE_CMD:-claude}"
CLAUDE_MAX_TURNS="${CLAUDE_MAX_TURNS:-80}"
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-3600}"

# Output directory for Claude responses
_CLAUDE_OUTPUT_DIR=""

# ============================================================
# Initialization
# ============================================================

# Initialize Claude wrapper
claude_init() {
    local data_dir="${1:-$(ct_data_dir)}"

    # Check Claude CLI is available
    ct_require_cmd "$CLAUDE_CMD" "Claude CLI not found. Install from: https://docs.anthropic.com/en/docs/claude-code" || return 1

    _CLAUDE_OUTPUT_DIR="$data_dir/tmp"
    mkdir -p "$_CLAUDE_OUTPUT_DIR"

    log_debug "Claude wrapper initialized"
}

# ============================================================
# Session Management
# ============================================================

# Start a new Claude session
claude_start_session() {
    local thread_id="$1"
    local mode="${2:-automatic}"

    # Generate session ID
    local session_id
    session_id=$(ct_generate_id "session")

    # Record in database
    db_session_upsert "$session_id" "$thread_id"

    log_info "Claude session started: $session_id for thread $thread_id"

    echo "$session_id"
}

# Get session info
claude_get_session() {
    local session_id="$1"
    db_query "SELECT * FROM sessions WHERE id = $(db_quote "$session_id")" | jq '.[0] // empty'
}

# Check if session is active
claude_session_active() {
    local session_id="$1"

    local status
    status=$(db_scalar "SELECT status FROM sessions WHERE id = $(db_quote "$session_id")")

    [[ "$status" == "active" ]]
}

# Pause session
claude_pause_session() {
    local session_id="$1"
    db_exec "UPDATE sessions SET status = 'paused' WHERE id = $(db_quote "$session_id")"
    log_debug "Session paused: $session_id"
}

# End session
claude_end_session() {
    local session_id="$1"
    db_exec "UPDATE sessions SET status = 'completed' WHERE id = $(db_quote "$session_id")"
    log_info "Session ended: $session_id"
}

# ============================================================
# Prompt Execution
# ============================================================

# Build Claude command arguments based on mode
_claude_build_args() {
    local mode="$1"
    local session_id="$2"
    local max_turns="${3:-$CLAUDE_MAX_TURNS}"

    local args=()

    # Session handling
    if [[ -n "$session_id" ]]; then
        args+=(--session-id "$session_id")
    fi

    # Mode-specific settings
    case "$mode" in
        automatic)
            args+=(--permission-mode acceptEdits)
            args+=(--max-turns "$max_turns")
            ;;
        semi-auto)
            # Uses default permissions, but with max turns
            args+=(--max-turns "$max_turns")
            ;;
        interactive)
            # Full interactive, no special flags
            ;;
    esac

    echo "${args[@]}"
}

# Execute a prompt with Claude
claude_execute() {
    local prompt="$1"
    local mode="${2:-automatic}"
    local session_id="${3:-}"
    local output_file="${4:-}"

    # Generate output file if not provided
    if [[ -z "$output_file" ]]; then
        output_file="$_CLAUDE_OUTPUT_DIR/claude-output-$(ct_timestamp_file).txt"
    fi

    local args
    args=$(_claude_build_args "$mode" "$session_id" "$CLAUDE_MAX_TURNS")

    log_info "Executing Claude prompt (mode=$mode, session=$session_id)"
    log_debug "Prompt: ${prompt:0:100}..."

    local exit_code=0

    case "$mode" in
        automatic)
            # Non-interactive execution with -p flag
            $CLAUDE_CMD -p "$prompt" $args 2>&1 | tee "$output_file"
            exit_code=${PIPESTATUS[0]}
            ;;

        semi-auto|interactive)
            # Interactive execution
            if [[ -n "$session_id" ]]; then
                # Resume existing session
                $CLAUDE_CMD --resume "$session_id" -p "$prompt" $args 2>&1 | tee "$output_file"
            else
                $CLAUDE_CMD -p "$prompt" $args 2>&1 | tee "$output_file"
            fi
            exit_code=${PIPESTATUS[0]}
            ;;
    esac

    # Update session stats
    if [[ -n "$session_id" ]]; then
        db_session_update "$session_id" 1 0
    fi

    log_debug "Claude execution completed with exit code: $exit_code"

    return $exit_code
}

# Execute prompt and capture structured output
claude_execute_json() {
    local prompt="$1"
    local mode="${2:-automatic}"
    local session_id="${3:-}"

    local output_file="$_CLAUDE_OUTPUT_DIR/claude-json-$(ct_timestamp_file).txt"

    # Add instruction to output JSON
    local json_prompt="$prompt

Please output your response in the following JSON format:
\`\`\`json
{
  \"status\": \"success\" | \"error\" | \"blocked\",
  \"message\": \"description of what was done\",
  \"data\": { ... any relevant data ... }
}
\`\`\`"

    claude_execute "$json_prompt" "$mode" "$session_id" "$output_file"
    local exit_code=$?

    # Extract JSON from output
    local json
    json=$(grep -oP '```json\s*\K.*?(?=```)' "$output_file" | head -1)

    if [[ -z "$json" ]]; then
        # Try to extract any JSON object
        json=$(grep -oP '\{[^{}]*\}' "$output_file" | tail -1)
    fi

    if [[ -n "$json" ]]; then
        echo "$json"
    else
        # Return a default response
        echo "{\"status\": \"unknown\", \"exit_code\": $exit_code}"
    fi

    return $exit_code
}

# ============================================================
# Resume Operations
# ============================================================

# Resume a previous session
claude_resume() {
    local session_id="$1"
    local prompt="${2:-}"

    if ! claude_session_active "$session_id"; then
        log_warn "Session $session_id is not active"
        # Reactivate session
        db_exec "UPDATE sessions SET status = 'active' WHERE id = $(db_quote "$session_id")"
    fi

    if [[ -n "$prompt" ]]; then
        $CLAUDE_CMD --resume "$session_id" -p "$prompt"
    else
        $CLAUDE_CMD --resume "$session_id"
    fi
}

# Continue session with a follow-up prompt
claude_continue() {
    local session_id="$1"
    local prompt="$2"

    claude_execute "$prompt" "automatic" "$session_id"
}

# ============================================================
# Output Parsing
# ============================================================

# Parse Claude output for events
claude_parse_events() {
    local output="$1"

    # Look for JSON event markers in output
    # Expected format: {"event": "TYPE", ...}

    local events=()

    while IFS= read -r line; do
        if [[ "$line" =~ \{\"event\":\ *\"([^\"]+)\" ]]; then
            events+=("$line")
        fi
    done <<< "$output"

    printf '%s\n' "${events[@]}"
}

# Parse Claude output for specific event type
claude_find_event() {
    local output="$1"
    local event_type="$2"

    local events
    events=$(claude_parse_events "$output")

    echo "$events" | jq -s --arg type "$event_type" '
        [.[] | select(.event == $type)] | .[0] // empty
    '
}

# Check if output indicates completion
claude_is_complete() {
    local output="$1"

    # Check for completion indicators
    if [[ "$output" =~ "COMPLETED" ]] || \
       [[ "$output" =~ "All tasks completed" ]] || \
       [[ "$output" =~ "\"status\":\"success\"" ]]; then
        return 0
    fi

    return 1
}

# Check if output indicates error
claude_is_error() {
    local output="$1"

    if [[ "$output" =~ "ERROR" ]] || \
       [[ "$output" =~ "Failed" ]] || \
       [[ "$output" =~ "\"status\":\"error\"" ]]; then
        return 0
    fi

    return 1
}

# Check if output indicates blocked state
claude_is_blocked() {
    local output="$1"

    if [[ "$output" =~ "BLOCKED" ]] || \
       [[ "$output" =~ "needs manual intervention" ]] || \
       [[ "$output" =~ "\"status\":\"blocked\"" ]]; then
        return 0
    fi

    return 1
}

# ============================================================
# Utility Functions
# ============================================================

# Get Claude version
claude_version() {
    $CLAUDE_CMD --version 2>/dev/null || echo "unknown"
}

# Check Claude is available and authenticated
claude_check() {
    if ! command -v "$CLAUDE_CMD" >/dev/null 2>&1; then
        ct_error "Claude CLI not found"
        return 1
    fi

    # Basic check - this may need adjustment based on actual CLI behavior
    if ! $CLAUDE_CMD --help >/dev/null 2>&1; then
        ct_error "Claude CLI not working properly"
        return 1
    fi

    return 0
}

# Get output file path
claude_output_file() {
    echo "$_CLAUDE_OUTPUT_DIR/claude-output-$(ct_timestamp_file).txt"
}

# Clean old output files
claude_cleanup() {
    local days="${1:-7}"

    find "$_CLAUDE_OUTPUT_DIR" -name "claude-*.txt" -mtime +"$days" -delete 2>/dev/null

    log_debug "Cleaned Claude output files older than $days days"
}
