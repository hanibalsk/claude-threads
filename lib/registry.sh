#!/usr/bin/env bash
#
# registry.sh - Port allocation and instance registry for claude-threads
#
# Provides dynamic port allocation from a configurable range and maintains
# a shared registry of running instances for service discovery.
#
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
#

# Prevent double-sourcing
[[ -n "${_CT_REGISTRY_LOADED:-}" ]] && return 0
_CT_REGISTRY_LOADED=1

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

# ============================================================
# Constants
# ============================================================

# Default port range
readonly REGISTRY_PORT_START="${CT_PORT_RANGE_START:-31340}"
readonly REGISTRY_PORT_END="${CT_PORT_RANGE_END:-31399}"

# Heartbeat settings
readonly REGISTRY_HEARTBEAT_INTERVAL="${CT_HEARTBEAT_INTERVAL:-10}"
readonly REGISTRY_STALE_TIMEOUT="${CT_STALE_TIMEOUT:-30}"

# Registry file location (user home, shared across projects)
readonly REGISTRY_FILE="${CT_REGISTRY_FILE:-$HOME/.claude-threads/instances.json}"
readonly REGISTRY_LOCK_FILE="${REGISTRY_FILE}.lock"

# ============================================================
# Registry File Management
# ============================================================

# Initialize registry file if it doesn't exist
registry_init() {
    local registry_dir
    registry_dir="$(dirname "$REGISTRY_FILE")"

    # Create directory if needed
    if [[ ! -d "$registry_dir" ]]; then
        mkdir -p "$registry_dir" || {
            ct_error "Failed to create registry directory: $registry_dir"
            return 1
        }
    fi

    # Create empty registry if doesn't exist
    if [[ ! -f "$REGISTRY_FILE" ]]; then
        echo '{"instances": {}, "port_range": {"start": '"$REGISTRY_PORT_START"', "end": '"$REGISTRY_PORT_END"'}}' > "$REGISTRY_FILE" || {
            ct_error "Failed to create registry file: $REGISTRY_FILE"
            return 1
        }
    fi

    return 0
}

# Read registry with file locking
# Usage: registry_read
registry_read() {
    registry_init || return 1

    # Use portable locking (mkdir is atomic)
    local max_attempts=50
    local attempt=0
    local lock_dir="${REGISTRY_LOCK_FILE}.d"

    while ! mkdir "$lock_dir" 2>/dev/null; do
        (( ++attempt )) || true
        if [[ $attempt -ge $max_attempts ]]; then
            ct_error "Failed to acquire read lock on registry after $max_attempts attempts"
            return 1
        fi
        sleep 0.1
    done

    # Read file
    local content
    content=$(cat "$REGISTRY_FILE" 2>/dev/null)

    # Release lock
    rmdir "$lock_dir" 2>/dev/null

    echo "$content"
}

# Write registry with file locking
# Usage: echo "$json" | registry_write
registry_write() {
    local json
    json=$(cat)

    registry_init || return 1

    # Use portable locking (mkdir is atomic)
    local max_attempts=50
    local attempt=0
    local lock_dir="${REGISTRY_LOCK_FILE}.d"

    while ! mkdir "$lock_dir" 2>/dev/null; do
        (( ++attempt )) || true
        if [[ $attempt -ge $max_attempts ]]; then
            ct_error "Failed to acquire write lock on registry after $max_attempts attempts"
            return 1
        fi
        sleep 0.1
    done

    # Write file
    echo "$json" > "$REGISTRY_FILE"

    # Release lock
    rmdir "$lock_dir" 2>/dev/null
}

# Atomic registry update with function
# Usage: registry_update "jq_expression"
registry_update() {
    local jq_expr="$1"

    registry_init || return 1

    # Use portable locking (mkdir is atomic)
    local max_attempts=50
    local attempt=0
    local lock_dir="${REGISTRY_LOCK_FILE}.d"

    while ! mkdir "$lock_dir" 2>/dev/null; do
        (( ++attempt )) || true
        if [[ $attempt -ge $max_attempts ]]; then
            ct_error "Failed to acquire write lock on registry after $max_attempts attempts"
            return 1
        fi
        sleep 0.1
    done

    local current
    current=$(cat "$REGISTRY_FILE")

    local updated
    updated=$(echo "$current" | jq "$jq_expr")
    if [[ $? -ne 0 ]]; then
        rmdir "$lock_dir" 2>/dev/null
        ct_error "Failed to update registry with expression: $jq_expr"
        return 1
    fi

    echo "$updated" > "$REGISTRY_FILE"

    # Release lock
    rmdir "$lock_dir" 2>/dev/null
}

# ============================================================
# Port Allocation
# ============================================================

# Check if a port is available (not in use)
# Usage: registry_port_available 31340
registry_port_available() {
    local port="$1"

    # Validate port number
    if ! ct_validate_positive_int "$port" 65535; then
        return 1
    fi

    # Check if port is in use using nc
    if nc -z 127.0.0.1 "$port" 2>/dev/null; then
        return 1  # Port is in use
    fi

    return 0  # Port is available
}

# Allocate a port from the range
# Usage: registry_allocate_port "/path/to/project" "api"
# Returns: allocated port number on stdout
registry_allocate_port() {
    local project_root="$1"
    local service_type="${2:-api}"  # api, debug, webhook

    if [[ -z "$project_root" ]]; then
        ct_error "Project root is required for port allocation"
        return 1
    fi

    registry_init || return 1

    # Use portable locking (mkdir is atomic)
    local max_attempts=50
    local attempt=0
    local lock_dir="${REGISTRY_LOCK_FILE}.d"

    while ! mkdir "$lock_dir" 2>/dev/null; do
        (( ++attempt )) || true
        if [[ $attempt -ge $max_attempts ]]; then
            ct_error "Failed to acquire write lock on registry after $max_attempts attempts"
            return 1
        fi
        sleep 0.1
    done

    local allocated_port=""
    local registry
    registry=$(cat "$REGISTRY_FILE")

    # First, cleanup stale instances
    local now
    now=$(date +%s)

    registry=$(echo "$registry" | jq --argjson now "$now" --argjson timeout "$REGISTRY_STALE_TIMEOUT" '
        .instances |= with_entries(
            select(
                (.value.last_heartbeat | fromdateiso8601) > ($now - $timeout)
            )
        )
    ')

    # Check if this project already has a port allocated for this service
    local existing_port
    existing_port=$(echo "$registry" | jq -r --arg root "$project_root" --arg svc "$service_type" '
        .instances | to_entries[] |
        select(.value.project_root == $root and .value.services[$svc] != null) |
        .value.services[$svc].port
    ' | head -n1)

    if [[ -n "$existing_port" && "$existing_port" != "null" ]]; then
        # Verify the port is still valid and in use by us
        local existing_pid
        existing_pid=$(echo "$registry" | jq -r --arg root "$project_root" --arg svc "$service_type" '
            .instances | to_entries[] |
            select(.value.project_root == $root) |
            .value.services[$svc].pid
        ' | head -n1)

        if [[ -n "$existing_pid" && "$existing_pid" != "null" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            rmdir "$lock_dir" 2>/dev/null
            echo "$existing_port"
            return 0
        fi
    fi

    # Find first available port in range
    local port_start port_end
    port_start=$(echo "$registry" | jq -r '.port_range.start // 31340')
    port_end=$(echo "$registry" | jq -r '.port_range.end // 31399')

    local port
    for port in $(seq "$port_start" "$port_end"); do
        # Check if port is registered
        local is_registered
        is_registered=$(echo "$registry" | jq -r --arg port "$port" '
            .instances[$port] != null
        ')

        if [[ "$is_registered" == "true" ]]; then
            continue
        fi

        # Check if port is actually available on the system
        if ! nc -z 127.0.0.1 "$port" 2>/dev/null; then
            allocated_port="$port"
            break
        fi
    done

    if [[ -z "$allocated_port" ]]; then
        rmdir "$lock_dir" 2>/dev/null
        ct_error "No available ports in range $port_start-$port_end"
        return 1
    fi

    # Register the instance
    local timestamp
    timestamp=$(ct_timestamp)
    local pid="$$"

    registry=$(echo "$registry" | jq --arg port "$allocated_port" \
        --arg root "$project_root" \
        --argjson pid "$pid" \
        --arg ts "$timestamp" \
        --arg svc "$service_type" '
        .instances[$port] = {
            "project_root": $root,
            "pid": $pid,
            "started_at": $ts,
            "last_heartbeat": $ts,
            "services": {
                ($svc): {
                    "port": ($port | tonumber),
                    "pid": $pid
                }
            },
            "metadata": {
                "threads_active": 0,
                "threads_total": 0,
                "recent_events": []
            }
        }
    ')

    # Write updated registry
    echo "$registry" > "$REGISTRY_FILE"

    # Release lock
    rmdir "$lock_dir" 2>/dev/null

    echo "$allocated_port"
}

# Release a port back to the pool
# Usage: registry_release_port 31340
registry_release_port() {
    local port="$1"

    if [[ -z "$port" ]]; then
        ct_error "Port is required for release"
        return 1
    fi

    registry_update --arg port "$port" '
        del(.instances[$port])
    '
}

# Add a service to an existing instance
# Usage: registry_add_service 31340 "debug" 31341 12345
registry_add_service() {
    local instance_port="$1"
    local service_type="$2"
    local service_port="$3"
    local service_pid="${4:-$$}"

    registry_update --arg iport "$instance_port" \
        --arg svc "$service_type" \
        --argjson sport "$service_port" \
        --argjson pid "$service_pid" '
        if .instances[$iport] then
            .instances[$iport].services[$svc] = {
                "port": $sport,
                "pid": $pid
            }
        else
            .
        end
    '
}

# Remove a service from an instance
# Usage: registry_remove_service 31340 "debug"
registry_remove_service() {
    local instance_port="$1"
    local service_type="$2"

    registry_update --arg iport "$instance_port" --arg svc "$service_type" '
        if .instances[$iport] then
            del(.instances[$iport].services[$svc])
        else
            .
        end
    '
}

# ============================================================
# Heartbeat Management
# ============================================================

# Update heartbeat timestamp for an instance
# Usage: registry_update_heartbeat 31340
registry_update_heartbeat() {
    local port="$1"
    local timestamp
    timestamp=$(ct_timestamp)

    registry_update --arg port "$port" --arg ts "$timestamp" '
        if .instances[$port] then
            .instances[$port].last_heartbeat = $ts
        else
            .
        end
    '
}

# Start a background heartbeat process
# Usage: registry_start_heartbeat 31340
# Returns: PID of heartbeat process
registry_start_heartbeat() {
    local port="$1"
    local interval="${2:-$REGISTRY_HEARTBEAT_INTERVAL}"

    (
        while true; do
            registry_update_heartbeat "$port"
            sleep "$interval"
        done
    ) &

    echo $!
}

# Stop heartbeat process
# Usage: registry_stop_heartbeat $heartbeat_pid
registry_stop_heartbeat() {
    local pid="$1"

    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
    fi
}

# ============================================================
# Instance Queries
# ============================================================

# Get all registered instances
# Usage: registry_get_instances
registry_get_instances() {
    registry_read
}

# Get instance by port
# Usage: registry_get_instance 31340
registry_get_instance() {
    local port="$1"

    registry_read | jq --arg port "$port" '.instances[$port] // null'
}

# Find instance for a project
# Usage: registry_find_by_project "/path/to/project"
registry_find_by_project() {
    local project_root="$1"

    registry_read | jq -r --arg root "$project_root" '
        .instances | to_entries[] |
        select(.value.project_root == $root) |
        .key
    ' | head -n1
}

# Get all instances as a formatted list
# Usage: registry_list_instances
registry_list_instances() {
    local instances
    instances=$(registry_read)

    echo "$instances" | jq -r '
        .instances | to_entries[] |
        "\(.key)\t\(.value.project_root)\t\(.value.metadata.threads_active)/\(.value.metadata.threads_total)\t\(.value.last_heartbeat)"
    '
}

# Count active instances
# Usage: registry_count_instances
registry_count_instances() {
    registry_read | jq '.instances | length'
}

# ============================================================
# Metadata Updates
# ============================================================

# Update instance metadata
# Usage: registry_update_metadata 31340 threads_active 3
registry_update_metadata() {
    local port="$1"
    local key="$2"
    local value="$3"

    # Determine if value is numeric or string
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        registry_update --arg port "$port" --arg key "$key" --argjson val "$value" '
            if .instances[$port] then
                .instances[$port].metadata[$key] = $val
            else
                .
            end
        '
    else
        registry_update --arg port "$port" --arg key "$key" --arg val "$value" '
            if .instances[$port] then
                .instances[$port].metadata[$key] = $val
            else
                .
            end
        '
    fi
}

# Update thread counts for an instance
# Usage: registry_update_thread_counts 31340 3 10
registry_update_thread_counts() {
    local port="$1"
    local active="$2"
    local total="$3"

    registry_update --arg port "$port" --argjson active "$active" --argjson total "$total" '
        if .instances[$port] then
            .instances[$port].metadata.threads_active = $active |
            .instances[$port].metadata.threads_total = $total
        else
            .
        end
    '
}

# Add recent event to instance
# Usage: registry_add_event 31340 "TASK_COMPLETED"
registry_add_event() {
    local port="$1"
    local event="$2"
    local max_events="${3:-10}"

    registry_update --arg port "$port" --arg event "$event" --argjson max "$max_events" '
        if .instances[$port] then
            .instances[$port].metadata.recent_events = (
                [$event] + .instances[$port].metadata.recent_events | .[:$max]
            )
        else
            .
        end
    '
}

# ============================================================
# Cleanup
# ============================================================

# Remove stale instances (heartbeat older than timeout)
# Usage: registry_cleanup_stale
registry_cleanup_stale() {
    local now
    now=$(date +%s)
    local timeout="${1:-$REGISTRY_STALE_TIMEOUT}"
    local removed=0

    # Use portable locking
    local max_attempts=50
    local attempt=0
    local lock_dir="${REGISTRY_LOCK_FILE}.d"

    while ! mkdir "$lock_dir" 2>/dev/null; do
        (( ++attempt )) || true
        if [[ $attempt -ge $max_attempts ]]; then
            ct_error "Failed to acquire write lock on registry after $max_attempts attempts"
            return 1
        fi
        sleep 0.1
    done

    local registry
    registry=$(cat "$REGISTRY_FILE")

    # Get list of stale instances before removing
    local stale_ports
    stale_ports=$(echo "$registry" | jq -r --argjson now "$now" --argjson timeout "$timeout" '
        .instances | to_entries[] |
        select((.value.last_heartbeat | fromdateiso8601) <= ($now - $timeout)) |
        .key
    ')

    if [[ -n "$stale_ports" ]]; then
        # Remove stale instances
        registry=$(echo "$registry" | jq --argjson now "$now" --argjson timeout "$timeout" '
            .instances |= with_entries(
                select(
                    (.value.last_heartbeat | fromdateiso8601) > ($now - $timeout)
                )
            )
        ')

        echo "$registry" > "$REGISTRY_FILE"

        # Count removed
        removed=$(echo "$stale_ports" | wc -l | tr -d ' ')
    fi

    # Release lock
    rmdir "$lock_dir" 2>/dev/null

    echo "$removed"
}

# Cleanup instance and release resources
# Usage: registry_cleanup_instance 31340 [heartbeat_pid]
registry_cleanup_instance() {
    local port="$1"
    local heartbeat_pid="${2:-}"

    # Stop heartbeat if running
    if [[ -n "$heartbeat_pid" ]]; then
        registry_stop_heartbeat "$heartbeat_pid"
    fi

    # Release the port
    registry_release_port "$port"
}

# ============================================================
# Discovery Helpers
# ============================================================

# Discover instance for current project or any available
# Usage: registry_discover [project_root]
# Returns: port number or empty if none found
registry_discover() {
    local project_root="${1:-${CT_PROJECT_ROOT:-$(pwd)}}"

    # First try to find instance for this project
    local port
    port=$(registry_find_by_project "$project_root")

    if [[ -n "$port" ]]; then
        # Verify it's still alive
        local instance
        instance=$(registry_get_instance "$port")
        local pid
        pid=$(echo "$instance" | jq -r '.pid // empty')

        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "$port"
            return 0
        else
            # Stale entry, clean it up
            registry_release_port "$port"
        fi
    fi

    # If no project-specific instance, return first available
    local first_port
    first_port=$(registry_read | jq -r '.instances | keys | .[0] // empty')

    if [[ -n "$first_port" ]]; then
        echo "$first_port"
        return 0
    fi

    return 1
}

# Get API URL for an instance
# Usage: registry_get_api_url 31340
registry_get_api_url() {
    local port="$1"
    echo "http://127.0.0.1:$port"
}

# ============================================================
# Validation
# ============================================================

# Validate port is in allowed range
# Usage: registry_validate_port 31340
registry_validate_port() {
    local port="$1"

    if ! ct_validate_positive_int "$port" 65535; then
        return 1
    fi

    if [[ "$port" -lt "$REGISTRY_PORT_START" || "$port" -gt "$REGISTRY_PORT_END" ]]; then
        return 1
    fi

    return 0
}
