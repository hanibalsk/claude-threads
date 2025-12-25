#!/usr/bin/env bash
#
# progress.sh - Real-time progress tracking for claude-threads
#
# Tracks thread progress, captures output streams, and provides
# live monitoring capabilities.
#
# Usage:
#   source lib/progress.sh
#   progress_init "$DATA_DIR"
#   progress_start "$thread_id"
#   progress_update "$thread_id" "50" "Running tests"
#   progress_stream "$thread_id" "$output_file"
#

# Prevent double-sourcing
[[ -n "${_CT_PROGRESS_LOADED:-}" ]] && return 0
_CT_PROGRESS_LOADED=1

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/log.sh"

# ============================================================
# Configuration
# ============================================================

_PROGRESS_DIR=""
_PROGRESS_INITIALIZED=0

# ============================================================
# Initialization
# ============================================================

# Initialize progress tracking
progress_init() {
    local data_dir="${1:-$(ct_data_dir)}"

    _PROGRESS_DIR="$data_dir/progress"
    mkdir -p "$_PROGRESS_DIR"

    _PROGRESS_INITIALIZED=1
    log_debug "Progress tracking initialized: $_PROGRESS_DIR"
}

# Check if initialized
progress_check() {
    if [[ $_PROGRESS_INITIALIZED -ne 1 ]]; then
        # Auto-initialize with default
        progress_init
    fi
}

# ============================================================
# Progress State Management
# ============================================================

# Start tracking a thread
progress_start() {
    progress_check
    local thread_id="$1"
    local total_steps="${2:-0}"

    local progress_file="$_PROGRESS_DIR/${thread_id}.json"

    cat > "$progress_file" <<EOF
{
    "thread_id": "$thread_id",
    "status": "running",
    "percentage": 0,
    "current_step": "Starting",
    "completed_steps": 0,
    "total_steps": $total_steps,
    "started_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "updated_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "output_lines": 0,
    "last_output": ""
}
EOF

    log_debug "Progress started for $thread_id"
}

# Update progress
progress_update() {
    progress_check
    local thread_id="$1"
    local percentage="${2:-}"
    local current_step="${3:-}"
    local completed_steps="${4:-}"

    local progress_file="$_PROGRESS_DIR/${thread_id}.json"

    if [[ ! -f "$progress_file" ]]; then
        progress_start "$thread_id"
    fi

    local updates=""
    [[ -n "$percentage" ]] && updates+=", \"percentage\": $percentage"
    [[ -n "$current_step" ]] && updates+=", \"current_step\": $(echo "$current_step" | jq -Rs '.')"
    [[ -n "$completed_steps" ]] && updates+=", \"completed_steps\": $completed_steps"
    updates+=", \"updated_at\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\""

    local current
    current=$(cat "$progress_file")
    echo "$current" | jq ". + {${updates:2}}" > "$progress_file"
}

# Update last output line
progress_set_output() {
    progress_check
    local thread_id="$1"
    local output_line="$2"
    local line_count="${3:-0}"

    local progress_file="$_PROGRESS_DIR/${thread_id}.json"

    if [[ -f "$progress_file" ]]; then
        local escaped_output
        escaped_output=$(echo "$output_line" | jq -Rs '.' | head -c 500)

        local current
        current=$(cat "$progress_file")
        echo "$current" | jq \
            --argjson lines "$line_count" \
            --argjson output "$escaped_output" \
            '. + {"output_lines": $lines, "last_output": $output, "updated_at": "'"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"'"}' \
            > "$progress_file"
    fi
}

# Mark progress complete
progress_complete() {
    progress_check
    local thread_id="$1"
    local final_status="${2:-completed}"

    local progress_file="$_PROGRESS_DIR/${thread_id}.json"

    if [[ -f "$progress_file" ]]; then
        local current
        current=$(cat "$progress_file")
        echo "$current" | jq \
            --arg status "$final_status" \
            '. + {"status": $status, "percentage": 100, "completed_at": "'"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"'"}' \
            > "$progress_file"
    fi
}

# Get progress for a thread
progress_get() {
    progress_check
    local thread_id="$1"

    local progress_file="$_PROGRESS_DIR/${thread_id}.json"

    if [[ -f "$progress_file" ]]; then
        cat "$progress_file"
    else
        echo "{}"
    fi
}

# Get all active progress
progress_get_all() {
    progress_check

    local result="[]"
    for file in "$_PROGRESS_DIR"/*.json; do
        [[ -f "$file" ]] || continue
        local data
        data=$(cat "$file")
        local status
        status=$(echo "$data" | jq -r '.status // "unknown"')
        if [[ "$status" == "running" ]]; then
            result=$(echo "$result" | jq --argjson item "$data" '. + [$item]')
        fi
    done

    echo "$result"
}

# ============================================================
# Output Streaming
# ============================================================

# Stream output from a file in real-time, updating progress
# This runs in background and updates progress as output comes in
progress_stream() {
    local thread_id="$1"
    local output_file="$2"
    local callback="${3:-}"  # Optional callback function for each line

    progress_check

    local line_count=0
    local last_line=""

    # Use tail -f to follow the file
    tail -f "$output_file" 2>/dev/null | while IFS= read -r line; do
        ((line_count++))
        last_line="$line"

        # Update progress with output info
        progress_set_output "$thread_id" "$line" "$line_count"

        # Check for progress markers in output
        if [[ "$line" =~ \[PROGRESS:([0-9]+)%\] ]]; then
            progress_update "$thread_id" "${BASH_REMATCH[1]}"
        elif [[ "$line" =~ \[STEP:(.+)\] ]]; then
            progress_update "$thread_id" "" "${BASH_REMATCH[1]}"
        fi

        # Call callback if provided
        if [[ -n "$callback" ]] && declare -f "$callback" > /dev/null; then
            "$callback" "$thread_id" "$line"
        fi
    done
}

# Capture output with progress tracking (replacement for tee)
# Usage: command | progress_capture "$thread_id" "$output_file"
progress_capture() {
    local thread_id="$1"
    local output_file="$2"

    progress_check
    progress_start "$thread_id"

    local line_count=0

    while IFS= read -r line; do
        ((line_count++))

        # Write to output file
        echo "$line" >> "$output_file"

        # Also echo to stdout for normal processing
        echo "$line"

        # Update progress periodically (every 10 lines to avoid overhead)
        if (( line_count % 10 == 0 )); then
            progress_set_output "$thread_id" "$line" "$line_count"
        fi

        # Check for progress markers
        if [[ "$line" =~ \[PROGRESS:([0-9]+)%?\] ]]; then
            progress_update "$thread_id" "${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^###.*PROGRESS.*([0-9]+) ]]; then
            progress_update "$thread_id" "${BASH_REMATCH[1]}"
        elif [[ "$line" =~ \[STEP:(.+)\] ]]; then
            progress_update "$thread_id" "" "${BASH_REMATCH[1]}"
        elif [[ "$line" == *"Working on"* ]] || [[ "$line" == *"Starting"* ]] || [[ "$line" == *"Running"* ]]; then
            # Capture common progress phrases
            progress_update "$thread_id" "" "$line"
        fi
    done

    # Final update
    progress_set_output "$thread_id" "$line" "$line_count"
}

# ============================================================
# Output Retrieval
# ============================================================

# Get last N lines of output for a thread
progress_get_output() {
    local thread_id="$1"
    local lines="${2:-20}"
    local data_dir="${3:-$(ct_data_dir)}"

    local output_file="$data_dir/tmp/thread-${thread_id}-output.txt"

    if [[ -f "$output_file" ]]; then
        tail -n "$lines" "$output_file"
    fi
}

# Get output since a specific line number
progress_get_output_since() {
    local thread_id="$1"
    local since_line="${2:-0}"
    local data_dir="${3:-$(ct_data_dir)}"

    local output_file="$data_dir/tmp/thread-${thread_id}-output.txt"

    if [[ -f "$output_file" ]]; then
        tail -n +"$((since_line + 1))" "$output_file"
    fi
}

# ============================================================
# Display Helpers
# ============================================================

# Format progress as a bar
progress_bar() {
    local percentage="$1"
    local width="${2:-30}"

    local filled=$((percentage * width / 100))
    local empty=$((width - filled))

    printf "["
    printf "%${filled}s" | tr ' ' '='
    if [[ $filled -lt $width ]]; then
        printf ">"
        printf "%$((empty - 1))s" | tr ' ' ' '
    fi
    printf "] %3d%%" "$percentage"
}

# Format progress summary for display
progress_format() {
    local thread_id="$1"

    local progress
    progress=$(progress_get "$thread_id")

    if [[ -z "$progress" || "$progress" == "{}" ]]; then
        echo "  No progress data"
        return
    fi

    local pct step status output_lines last_output
    pct=$(echo "$progress" | jq -r '.percentage // 0')
    step=$(echo "$progress" | jq -r '.current_step // "Unknown"')
    status=$(echo "$progress" | jq -r '.status // "unknown"')
    output_lines=$(echo "$progress" | jq -r '.output_lines // 0')
    last_output=$(echo "$progress" | jq -r '.last_output // ""' | head -c 60)

    echo "  $(progress_bar "$pct") - $step"
    if [[ -n "$last_output" ]]; then
        echo "    └─ $last_output..."
    fi
}

# ============================================================
# Cleanup
# ============================================================

# Clean up old progress files
progress_cleanup() {
    progress_check
    local days="${1:-1}"

    find "$_PROGRESS_DIR" -name "*.json" -mtime +"$days" -delete 2>/dev/null
    log_debug "Cleaned up progress files older than $days days"
}
