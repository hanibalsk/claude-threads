#!/usr/bin/env bash
#
# config.sh - Configuration management for claude-threads
#
# Loads configuration from YAML file and provides access to settings.
# Supports environment variable overrides.
#
# Usage:
#   source lib/config.sh
#   config_load
#   max_threads=$(config_get "threads.max_concurrent" 5)
#

# Prevent double-sourcing
[[ -n "${_CT_CONFIG_LOADED:-}" ]] && return 0
_CT_CONFIG_LOADED=1

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

# ============================================================
# Configuration
# ============================================================

_CONFIG_FILE=""
_CONFIG_DATA=""
_CONFIG_LOADED=0

# Default configuration values (bash 3.2 compatible - no associative arrays)
# Returns default value for a given key
_config_default() {
    local key="$1"
    case "$key" in
        threads.max_concurrent) echo "5" ;;
        threads.max_background) echo "4" ;;
        threads.default_max_turns) echo "80" ;;
        threads.default_timeout) echo "3600" ;;
        threads.cleanup_after_days) echo "7" ;;
        orchestrator.poll_interval) echo "1" ;;
        orchestrator.idle_poll_interval) echo "10" ;;
        orchestrator.idle_threshold) echo "30" ;;
        orchestrator.background_check_interval) echo "5" ;;
        orchestrator.enable_scheduling) echo "true" ;;
        orchestrator.log_level) echo "info" ;;
        blackboard.event_retention_days) echo "7" ;;
        blackboard.message_retention_days) echo "30" ;;
        blackboard.max_events_per_poll) echo "100" ;;
        claude.command) echo "claude" ;;
        claude.session_timeout) echo "3600" ;;
        claude.permission_mode) echo "acceptEdits" ;;
        github.enabled) echo "false" ;;
        github.webhook_port) echo "31338" ;;
        n8n.enabled) echo "false" ;;
        n8n.api_port) echo "31337" ;;
        logging.directory) echo "logs" ;;
        logging.json_enabled) echo "false" ;;
        logging.max_size_mb) echo "10" ;;
        logging.max_files) echo "5" ;;
        templates.directory) echo "templates" ;;
        templates.cache_enabled) echo "true" ;;
        pr_shepherd.max_fix_attempts) echo "5" ;;
        pr_shepherd.ci_poll_interval) echo "30" ;;
        pr_shepherd.idle_poll_interval) echo "300" ;;
        pr_shepherd.push_cooldown) echo "120" ;;
        pr_shepherd.auto_merge) echo "false" ;;
        # Port allocation and registry settings
        ports.allocation) echo "auto" ;;
        ports.range_start) echo "31340" ;;
        ports.range_end) echo "31399" ;;
        ports.heartbeat_interval) echo "10" ;;
        ports.stale_timeout) echo "30" ;;
        ports.debug_port) echo "31339" ;;
        *) echo "" ;;
    esac
}

# ============================================================
# YAML Parsing
# ============================================================

# Simple YAML to JSON converter
# Handles basic YAML with indentation-based nesting
_yaml_to_json() {
    local yaml_file="$1"

    if command -v yq >/dev/null 2>&1; then
        # Use yq if available (more robust)
        yq -o=json "$yaml_file"
    else
        # Fallback: use Python if available
        if command -v python3 >/dev/null 2>&1; then
            python3 -c "
import yaml
import json
import sys

with open('$yaml_file', 'r') as f:
    data = yaml.safe_load(f)
    print(json.dumps(data))
" 2>/dev/null
        else
            # Ultimate fallback: basic parsing with awk
            # This handles simple cases only
            awk '
                BEGIN {
                    depth = 0
                    printf "{"
                }
                /^[[:space:]]*#/ { next }  # Skip comments
                /^[[:space:]]*$/ { next }  # Skip empty lines
                {
                    # Count leading spaces
                    match($0, /^[[:space:]]*/)
                    indent = RLENGTH / 2

                    # Remove leading/trailing whitespace
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "")

                    # Skip if no content
                    if (length($0) == 0) next

                    # Handle key: value pairs
                    if (match($0, /^([^:]+):[[:space:]]*(.*)/)) {
                        key = substr($0, RSTART, RLENGTH)
                        gsub(/:.*/, "", key)
                        gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)

                        value = substr($0, index($0, ":") + 1)
                        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)

                        if (length(value) > 0) {
                            # Leaf value
                            if (value ~ /^[0-9]+$/) {
                                printf "%s\"%s\": %s", (first ? "" : ", "), key, value
                            } else if (value == "true" || value == "false") {
                                printf "%s\"%s\": %s", (first ? "" : ", "), key, value
                            } else {
                                gsub(/"/, "\\\"", value)
                                printf "%s\"%s\": \"%s\"", (first ? "" : ", "), key, value
                            }
                            first = 0
                        }
                    }
                }
                END {
                    printf "}"
                }
            ' "$yaml_file" 2>/dev/null
        fi
    fi
}

# ============================================================
# Loading
# ============================================================

# Load configuration from file
config_load() {
    local config_file="${1:-}"

    # Find config file
    if [[ -z "$config_file" ]]; then
        local data_dir
        data_dir=$(ct_data_dir)

        if [[ -f "$data_dir/config.yaml" ]]; then
            config_file="$data_dir/config.yaml"
        elif [[ -f "$data_dir/config.yml" ]]; then
            config_file="$data_dir/config.yml"
        fi
    fi

    _CONFIG_FILE="$config_file"

    # Load and parse config
    if [[ -n "$config_file" && -f "$config_file" ]]; then
        _CONFIG_DATA=$(_yaml_to_json "$config_file")

        if [[ -z "$_CONFIG_DATA" || "$_CONFIG_DATA" == "{}" ]]; then
            ct_warn "Failed to parse config file: $config_file"
            _CONFIG_DATA="{}"
        fi
    else
        _CONFIG_DATA="{}"
    fi

    _CONFIG_LOADED=1

    ct_debug "Configuration loaded from: ${config_file:-defaults}"
}

# Ensure config is loaded
_config_ensure_loaded() {
    if [[ $_CONFIG_LOADED -ne 1 ]]; then
        config_load
    fi
}

# ============================================================
# Access Functions
# ============================================================

# Get a configuration value
# Usage: config_get "threads.max_concurrent" [default]
config_get() {
    local key="$1"
    local default="${2:-$(_config_default "$key")}"

    _config_ensure_loaded

    # Check environment variable override first
    # threads.max_concurrent -> CT_THREADS_MAX_CONCURRENT
    local env_key="CT_${key^^}"
    env_key="${env_key//./_}"

    if [[ -n "${!env_key:-}" ]]; then
        echo "${!env_key}"
        return
    fi

    # Get from config data
    local value
    value=$(echo "$_CONFIG_DATA" | jq -r "$(printf '.%s // empty' "$key")" 2>/dev/null)

    if [[ -n "$value" && "$value" != "null" ]]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# Get a configuration value as integer
config_get_int() {
    local key="$1"
    local default="${2:-0}"

    local value
    value=$(config_get "$key" "$default")

    # Validate it's a number
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# Get a configuration value as boolean
config_get_bool() {
    local key="$1"
    local default="${2:-false}"

    local value
    value=$(config_get "$key" "$default")

    case "$value" in
        true|1|yes|on) echo "true" ;;
        false|0|no|off) echo "false" ;;
        *) echo "$default" ;;
    esac
}

# Get a configuration section as JSON
config_get_section() {
    local section="$1"

    _config_ensure_loaded

    echo "$_CONFIG_DATA" | jq ".$section // {}"
}

# Check if a configuration key exists
config_has() {
    local key="$1"

    _config_ensure_loaded

    local value
    value=$(echo "$_CONFIG_DATA" | jq -r "$(printf '.%s // empty' "$key")" 2>/dev/null)

    [[ -n "$value" && "$value" != "null" ]]
}

# ============================================================
# Validation
# ============================================================

# Validate configuration
config_validate() {
    _config_ensure_loaded

    local errors=()

    # Validate thread settings
    local max_concurrent
    max_concurrent=$(config_get_int "threads.max_concurrent")
    if [[ $max_concurrent -lt 1 || $max_concurrent -gt 100 ]]; then
        errors+=("threads.max_concurrent must be between 1 and 100")
    fi

    # Validate log level
    local log_level
    log_level=$(config_get "orchestrator.log_level")
    case "$log_level" in
        trace|debug|info|warn|error) ;;
        *) errors+=("Invalid log level: $log_level") ;;
    esac

    # Output errors
    if [[ ${#errors[@]} -gt 0 ]]; then
        for error in "${errors[@]}"; do
            ct_error "Config validation: $error"
        done
        return 1
    fi

    return 0
}

# ============================================================
# Export Functions
# ============================================================

# Export all config as environment variables
config_export() {
    _config_ensure_loaded

    # Export config from JSON data
    echo "$_CONFIG_DATA" | jq -r '
        paths(scalars) as $p |
        "\($p | join("_") | ascii_upcase)=\(getpath($p))"
    ' | while IFS='=' read -r key value; do
        export "CT_$key"="$value"
    done
}

# Print current configuration
config_print() {
    _config_ensure_loaded

    echo "Configuration file: ${_CONFIG_FILE:-none}"
    echo ""
    echo "Current settings:"
    echo "$_CONFIG_DATA" | jq .
}
