#!/usr/bin/env bash
#
# utils.sh - Common utility functions for claude-threads
#
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
#

# Prevent double-sourcing
[[ -n "${_CT_UTILS_LOADED:-}" ]] && return 0
_CT_UTILS_LOADED=1

# ============================================================
# Constants
# ============================================================
readonly CT_VERSION="0.1.0"

# ============================================================
# Path utilities
# ============================================================

# Get the root directory of claude-threads installation
ct_root_dir() {
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    dirname "$lib_dir"
}

# Get the data directory (.claude-threads in project root)
ct_data_dir() {
    local root="${CT_PROJECT_ROOT:-$(pwd)}"
    echo "$root/.claude-threads"
}

# Ensure data directory exists
ct_ensure_data_dir() {
    local data_dir
    data_dir="$(ct_data_dir)"
    mkdir -p "$data_dir"/{threads,blackboard,artifacts,logs,tmp}
    echo "$data_dir"
}

# ============================================================
# ID generation
# ============================================================

# Generate a unique thread ID
ct_generate_id() {
    local prefix="${1:-thread}"
    local timestamp
    local random
    timestamp=$(date +%s)
    random=$(head -c 4 /dev/urandom | xxd -p)
    echo "${prefix}-${timestamp}-${random}"
}

# Generate a short ID (8 chars)
ct_short_id() {
    head -c 4 /dev/urandom | xxd -p
}

# ============================================================
# JSON utilities
# ============================================================

# Escape string for JSON
ct_json_escape() {
    local str="$1"
    printf '%s' "$str" | jq -Rs '.'
}

# Read JSON field
ct_json_get() {
    local json="$1"
    local field="$2"
    echo "$json" | jq -r "$field // empty"
}

# Create JSON object from key-value pairs
ct_json_object() {
    local result="{}"
    while [[ $# -ge 2 ]]; do
        local key="$1"
        local value="$2"
        shift 2
        result=$(echo "$result" | jq --arg k "$key" --arg v "$value" '. + {($k): $v}')
    done
    echo "$result"
}

# Merge JSON objects
ct_json_merge() {
    local base="$1"
    local overlay="$2"
    echo "$base" | jq --argjson overlay "$overlay" '. * $overlay'
}

# ============================================================
# Time utilities
# ============================================================

# Get current timestamp in ISO format
ct_timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# Get current timestamp for filenames
ct_timestamp_file() {
    date '+%Y%m%d_%H%M%S'
}

# Parse duration string (e.g., "5m", "1h", "30s") to seconds
ct_parse_duration() {
    local duration="$1"
    local value="${duration%[smhd]}"
    local unit="${duration: -1}"

    case "$unit" in
        s) echo "$value" ;;
        m) echo $((value * 60)) ;;
        h) echo $((value * 3600)) ;;
        d) echo $((value * 86400)) ;;
        *) echo "$duration" ;;  # Assume seconds if no unit
    esac
}

# ============================================================
# Validation
# ============================================================

# Check if a command exists
ct_require_cmd() {
    local cmd="$1"
    local msg="${2:-Command '$cmd' is required but not found}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        ct_error "$msg"
        return 1
    fi
}

# Validate thread mode
ct_validate_mode() {
    local mode="$1"
    case "$mode" in
        automatic|semi-auto|interactive|sleeping) return 0 ;;
        *) return 1 ;;
    esac
}

# Validate thread status
ct_validate_status() {
    local status="$1"
    case "$status" in
        created|ready|running|waiting|sleeping|blocked|completed|failed) return 0 ;;
        *) return 1 ;;
    esac
}

# ============================================================
# File operations
# ============================================================

# Atomic file write (write to temp, then rename)
ct_atomic_write() {
    local file="$1"
    local content="$2"
    local tmp_file="${file}.tmp.$$"

    echo "$content" > "$tmp_file"
    mv "$tmp_file" "$file"
}

# Read file or return default
ct_read_file() {
    local file="$1"
    local default="${2:-}"

    if [[ -f "$file" ]]; then
        cat "$file"
    else
        echo "$default"
    fi
}

# ============================================================
# Array/List utilities
# ============================================================

# Check if value is in array
ct_in_array() {
    local value="$1"
    shift
    for item in "$@"; do
        [[ "$item" == "$value" ]] && return 0
    done
    return 1
}

# Join array elements with delimiter
ct_join() {
    local delimiter="$1"
    shift
    local first="$1"
    shift
    printf '%s' "$first"
    printf '%s' "${@/#/$delimiter}"
}

# ============================================================
# Error handling
# ============================================================

# Exit with error message
ct_die() {
    echo "ERROR: $*" >&2
    exit 1
}

# Return with error (for use in functions)
ct_error() {
    echo "ERROR: $*" >&2
    return 1
}

# Warning message
ct_warn() {
    echo "WARNING: $*" >&2
}

# ============================================================
# Debug utilities
# ============================================================

# Debug output (only if CT_DEBUG is set)
ct_debug() {
    [[ -n "${CT_DEBUG:-}" ]] && echo "[DEBUG] $*" >&2
}

# Trace function entry/exit
ct_trace() {
    [[ -n "${CT_TRACE:-}" ]] && echo "[TRACE] ${FUNCNAME[1]}: $*" >&2
}
