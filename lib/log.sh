#!/usr/bin/env bash
#
# log.sh - Logging utilities for claude-threads
#
# Provides structured logging with levels, timestamps, and optional file output.
#
# Usage:
#   source lib/log.sh
#   log_init "my-component"
#   log_info "Something happened"
#   log_error "Something went wrong"
#

# Prevent double-sourcing
[[ -n "${_CT_LOG_LOADED:-}" ]] && return 0
_CT_LOG_LOADED=1

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

# ============================================================
# Configuration
# ============================================================

# Log levels (lower = more verbose)
readonly LOG_LEVEL_TRACE=0
readonly LOG_LEVEL_DEBUG=1
readonly LOG_LEVEL_INFO=2
readonly LOG_LEVEL_WARN=3
readonly LOG_LEVEL_ERROR=4
readonly LOG_LEVEL_FATAL=5

# Default settings
_LOG_LEVEL=${LOG_LEVEL_INFO}
_LOG_FILE=""
_LOG_COMPONENT=""
_LOG_TO_STDERR=1
_LOG_TIMESTAMPS=1
_LOG_COLORS=1

# ANSI colors
readonly _LOG_COLOR_RESET='\033[0m'
readonly _LOG_COLOR_RED='\033[0;31m'
readonly _LOG_COLOR_YELLOW='\033[0;33m'
readonly _LOG_COLOR_GREEN='\033[0;32m'
readonly _LOG_COLOR_BLUE='\033[0;34m'
readonly _LOG_COLOR_GRAY='\033[0;90m'

# ============================================================
# Initialization
# ============================================================

# Initialize logging for a component
log_init() {
    local component="${1:-main}"
    local log_file="${2:-}"
    local level="${3:-}"

    _LOG_COMPONENT="$component"

    if [[ -n "$log_file" ]]; then
        _LOG_FILE="$log_file"
        mkdir -p "$(dirname "$log_file")"
    fi

    if [[ -n "$level" ]]; then
        log_set_level "$level"
    fi

    # Check if we're in a terminal
    if [[ ! -t 2 ]]; then
        _LOG_COLORS=0
    fi
}

# Set log level by name or number
log_set_level() {
    local level="$1"
    case "$level" in
        trace|TRACE|0) _LOG_LEVEL=$LOG_LEVEL_TRACE ;;
        debug|DEBUG|1) _LOG_LEVEL=$LOG_LEVEL_DEBUG ;;
        info|INFO|2)   _LOG_LEVEL=$LOG_LEVEL_INFO ;;
        warn|WARN|3)   _LOG_LEVEL=$LOG_LEVEL_WARN ;;
        error|ERROR|4) _LOG_LEVEL=$LOG_LEVEL_ERROR ;;
        fatal|FATAL|5) _LOG_LEVEL=$LOG_LEVEL_FATAL ;;
        *) _LOG_LEVEL=$LOG_LEVEL_INFO ;;
    esac
}

# Set log file
log_set_file() {
    _LOG_FILE="$1"
    mkdir -p "$(dirname "$_LOG_FILE")"
}

# Disable/enable colors
log_colors() {
    _LOG_COLORS="$1"
}

# ============================================================
# Internal functions
# ============================================================

# Format and output a log message
_log_output() {
    local level="$1"
    local level_name="$2"
    local color="$3"
    shift 3
    local message="$*"

    # Check if we should output this level
    [[ $level -lt $_LOG_LEVEL ]] && return 0

    # Build the log line
    local timestamp=""
    if [[ $_LOG_TIMESTAMPS -eq 1 ]]; then
        timestamp="$(date '+%Y-%m-%d %H:%M:%S') "
    fi

    local component=""
    if [[ -n "$_LOG_COMPONENT" ]]; then
        component="[$_LOG_COMPONENT] "
    fi

    local log_line="${timestamp}${level_name} ${component}${message}"

    # Output to stderr with colors
    if [[ $_LOG_TO_STDERR -eq 1 ]]; then
        if [[ $_LOG_COLORS -eq 1 ]]; then
            echo -e "${color}${log_line}${_LOG_COLOR_RESET}" >&2
        else
            echo "$log_line" >&2
        fi
    fi

    # Output to file without colors
    if [[ -n "$_LOG_FILE" ]]; then
        echo "$log_line" >> "$_LOG_FILE"
    fi
}

# ============================================================
# Public logging functions
# ============================================================

log_trace() {
    _log_output $LOG_LEVEL_TRACE "TRACE" "$_LOG_COLOR_GRAY" "$@"
}

log_debug() {
    _log_output $LOG_LEVEL_DEBUG "DEBUG" "$_LOG_COLOR_BLUE" "$@"
}

log_info() {
    _log_output $LOG_LEVEL_INFO "INFO " "$_LOG_COLOR_GREEN" "$@"
}

log_warn() {
    _log_output $LOG_LEVEL_WARN "WARN " "$_LOG_COLOR_YELLOW" "$@"
}

log_error() {
    _log_output $LOG_LEVEL_ERROR "ERROR" "$_LOG_COLOR_RED" "$@"
}

log_fatal() {
    _log_output $LOG_LEVEL_FATAL "FATAL" "$_LOG_COLOR_RED" "$@"
    exit 1
}

# ============================================================
# Structured logging
# ============================================================

# Log with key-value pairs
log_kv() {
    local level="$1"
    local message="$2"
    shift 2

    local kv_pairs=""
    while [[ $# -ge 2 ]]; do
        kv_pairs+=" $1=$2"
        shift 2
    done

    case "$level" in
        trace) log_trace "$message$kv_pairs" ;;
        debug) log_debug "$message$kv_pairs" ;;
        info)  log_info "$message$kv_pairs" ;;
        warn)  log_warn "$message$kv_pairs" ;;
        error) log_error "$message$kv_pairs" ;;
        fatal) log_fatal "$message$kv_pairs" ;;
    esac
}

# Log JSON event (for structured logging)
log_json() {
    local level="$1"
    shift

    local json
    json=$(ct_json_object "$@")

    # Add timestamp and level
    json=$(echo "$json" | jq --arg ts "$(ct_timestamp)" --arg lvl "$level" \
        '. + {timestamp: $ts, level: $lvl}')

    # Output to file in JSON format
    if [[ -n "$_LOG_FILE" ]]; then
        echo "$json" >> "${_LOG_FILE%.log}.jsonl"
    fi

    # Output human-readable to stderr
    local message
    message=$(echo "$json" | jq -r '.message // .event // "event"')
    case "$level" in
        trace) log_trace "$message" ;;
        debug) log_debug "$message" ;;
        info)  log_info "$message" ;;
        warn)  log_warn "$message" ;;
        error) log_error "$message" ;;
    esac
}

# ============================================================
# Progress logging
# ============================================================

# Log with spinner (for long-running operations)
log_progress() {
    local message="$1"
    local pid="$2"

    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        local c=${spinstr:i++%${#spinstr}:1}
        printf "\r${_LOG_COLOR_BLUE}[%s]${_LOG_COLOR_RESET} %s" "$c" "$message" >&2
        sleep 0.1
    done

    printf "\r${_LOG_COLOR_GREEN}[✓]${_LOG_COLOR_RESET} %s\n" "$message" >&2
}

# ============================================================
# Thread-specific logging
# ============================================================

# Log for a specific thread
log_thread() {
    local thread_id="$1"
    local level="$2"
    shift 2
    local message="$*"

    local old_component="$_LOG_COMPONENT"
    _LOG_COMPONENT="thread:$thread_id"

    case "$level" in
        trace) log_trace "$message" ;;
        debug) log_debug "$message" ;;
        info)  log_info "$message" ;;
        warn)  log_warn "$message" ;;
        error) log_error "$message" ;;
    esac

    _LOG_COMPONENT="$old_component"
}
