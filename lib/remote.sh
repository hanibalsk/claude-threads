#!/usr/bin/env bash
#
# remote.sh - Remote API client for claude-threads multi-instance coordination
#
# Enables external Claude Code instances to connect to a running orchestrator
# and spawn/manage threads remotely.
#
# Usage:
#   source lib/remote.sh
#   remote_connect "localhost:31337" "my-token"
#   remote_thread_create "epic-7a" "automatic" "bmad-developer.md" "" '{"epic_id":"7A"}'
#   remote_thread_start "$thread_id"
#

# Prevent double-sourcing
[[ -n "${_CT_REMOTE_LOADED:-}" ]] && return 0
_CT_REMOTE_LOADED=1

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# ============================================================
# Configuration
# ============================================================

_REMOTE_API_URL=""
_REMOTE_TOKEN=""
_REMOTE_CONNECTED=0
_REMOTE_CONFIG_FILE=""

# Default timeout for API calls (seconds)
_REMOTE_TIMEOUT=30

# ============================================================
# Connection Management
# ============================================================

# Initialize remote module with data directory
remote_init() {
    local data_dir="${1:-$(ct_data_dir)}"
    _REMOTE_CONFIG_FILE="$data_dir/remote.json"

    # Load existing connection if available
    if [[ -f "$_REMOTE_CONFIG_FILE" ]]; then
        _remote_load_config
    fi
}

# Load connection config from file
_remote_load_config() {
    if [[ ! -f "$_REMOTE_CONFIG_FILE" ]]; then
        return 1
    fi

    local config
    config=$(cat "$_REMOTE_CONFIG_FILE" 2>/dev/null) || return 1

    _REMOTE_API_URL=$(echo "$config" | jq -r '.api_url // empty')
    _REMOTE_TOKEN=$(echo "$config" | jq -r '.token // empty')

    if [[ -n "$_REMOTE_API_URL" ]]; then
        _REMOTE_CONNECTED=1
        return 0
    fi

    return 1
}

# Save connection config to file
_remote_save_config() {
    local dir
    dir=$(dirname "$_REMOTE_CONFIG_FILE")
    mkdir -p "$dir"

    local connected_at
    connected_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    jq -n \
        --arg url "$_REMOTE_API_URL" \
        --arg token "$_REMOTE_TOKEN" \
        --arg time "$connected_at" \
        '{
            api_url: $url,
            token: $token,
            connected_at: $time
        }' > "$_REMOTE_CONFIG_FILE"
}

# Connect to remote orchestrator
# Usage: remote_connect <host:port> [token]
remote_connect() {
    local endpoint="$1"
    local token="${2:-${CT_API_TOKEN:-${N8N_API_TOKEN:-}}}"

    if [[ -z "$endpoint" ]]; then
        ct_error "Remote endpoint required (host:port)"
        return 1
    fi

    # Normalize endpoint to URL
    if [[ "$endpoint" != http* ]]; then
        _REMOTE_API_URL="http://$endpoint"
    else
        _REMOTE_API_URL="$endpoint"
    fi

    _REMOTE_TOKEN="$token"

    # Test connection with health check
    if ! remote_health_check >/dev/null 2>&1; then
        ct_error "Failed to connect to $endpoint"
        _REMOTE_API_URL=""
        _REMOTE_TOKEN=""
        return 1
    fi

    _REMOTE_CONNECTED=1
    _remote_save_config

    ct_info "Connected to remote orchestrator at $_REMOTE_API_URL"
    return 0
}

# Disconnect from remote orchestrator
remote_disconnect() {
    _REMOTE_API_URL=""
    _REMOTE_TOKEN=""
    _REMOTE_CONNECTED=0

    if [[ -f "$_REMOTE_CONFIG_FILE" ]]; then
        rm -f "$_REMOTE_CONFIG_FILE"
    fi

    ct_info "Disconnected from remote orchestrator"
}

# Check if connected to remote
remote_is_connected() {
    [[ $_REMOTE_CONNECTED -eq 1 && -n "$_REMOTE_API_URL" ]]
}

# Get connection status
remote_status() {
    if remote_is_connected; then
        local status
        status=$(remote_api_status 2>/dev/null) || status='{}'

        echo "Remote Connection"
        echo "================="
        echo ""
        echo "API URL: $_REMOTE_API_URL"
        echo "Token: ${_REMOTE_TOKEN:+configured}${_REMOTE_TOKEN:-NOT SET}"
        echo "Status: Connected"
        echo ""
        echo "Remote System:"
        echo "$status" | jq -r '
            "  Threads: \(.threads.running // 0) running / \(.threads.total // 0) total",
            "  Events pending: \(.events_pending // 0)",
            "  Orchestrator: \(if .orchestrator_running then "running" else "stopped" end)"
        ' 2>/dev/null || echo "  (unable to retrieve status)"
    else
        echo "Remote Connection"
        echo "================="
        echo ""
        echo "Status: Not connected"
        echo ""
        echo "To connect:"
        echo "  ct remote connect <host:port> [--token TOKEN]"
    fi
}

# ============================================================
# Auto-Discovery
# ============================================================

# Discover running orchestrator
# Checks multiple sources in order of priority
remote_discover() {
    local data_dir="${1:-$(ct_data_dir)}"

    # 1. Check CT_API_URL environment variable
    if [[ -n "${CT_API_URL:-}" ]]; then
        ct_debug "Trying CT_API_URL: $CT_API_URL"
        if _remote_try_connect "$CT_API_URL"; then
            return 0
        fi
    fi

    # 2. Check existing connection file
    if [[ -f "$data_dir/remote.json" ]]; then
        local url
        url=$(jq -r '.api_url // empty' "$data_dir/remote.json" 2>/dev/null)
        if [[ -n "$url" ]]; then
            ct_debug "Trying saved connection: $url"
            if _remote_try_connect "$url"; then
                return 0
            fi
        fi
    fi

    # 3. Check local API server
    local local_port
    local_port=$(config_get 'n8n.api_port' 31337)
    ct_debug "Trying local API: localhost:$local_port"
    if _remote_try_connect "http://localhost:$local_port"; then
        return 0
    fi

    # 4. Check config.yaml for n8n.api_port
    if [[ -f "$data_dir/config.yaml" ]]; then
        config_load "$data_dir/config.yaml"
        local configured_port
        configured_port=$(config_get 'n8n.api_port' '')
        if [[ -n "$configured_port" && "$configured_port" != "$local_port" ]]; then
            ct_debug "Trying configured port: localhost:$configured_port"
            if _remote_try_connect "http://localhost:$configured_port"; then
                return 0
            fi
        fi
    fi

    return 1
}

# Try to connect to an endpoint
_remote_try_connect() {
    local url="$1"
    local token="${CT_API_TOKEN:-${N8N_API_TOKEN:-}}"

    _REMOTE_API_URL="$url"
    _REMOTE_TOKEN="$token"

    if remote_health_check >/dev/null 2>&1; then
        _REMOTE_CONNECTED=1
        return 0
    fi

    _REMOTE_API_URL=""
    return 1
}

# ============================================================
# API Client
# ============================================================

# Make authenticated API request
# Usage: remote_api_call <method> <path> [body]
remote_api_call() {
    local method="$1"
    local path="$2"
    local body="${3:-}"

    if [[ -z "$_REMOTE_API_URL" ]]; then
        ct_error "Not connected to remote orchestrator"
        return 1
    fi

    local url="${_REMOTE_API_URL}${path}"
    local curl_args=(
        -s
        -X "$method"
        --max-time "$_REMOTE_TIMEOUT"
        -H "Content-Type: application/json"
    )

    # Add authentication if token is set
    if [[ -n "$_REMOTE_TOKEN" ]]; then
        curl_args+=(-H "Authorization: Bearer $_REMOTE_TOKEN")
    fi

    # Add body for POST/PUT/PATCH
    if [[ -n "$body" && "$method" =~ ^(POST|PUT|PATCH)$ ]]; then
        curl_args+=(-d "$body")
    fi

    local response
    local http_code

    # Make request and capture both body and status code
    response=$(curl "${curl_args[@]}" -w '\n%{http_code}' "$url" 2>/dev/null)
    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | sed '$d')

    # Check for HTTP errors
    case "$http_code" in
        2*)
            echo "$response"
            return 0
            ;;
        401)
            ct_error "Authentication failed (401 Unauthorized)"
            return 1
            ;;
        404)
            ct_error "Resource not found (404)"
            return 1
            ;;
        *)
            ct_error "API request failed (HTTP $http_code)"
            ct_debug "Response: $response"
            return 1
            ;;
    esac
}

# ============================================================
# Thread Operations
# ============================================================

# Create thread via API
# Usage: remote_thread_create <name> [mode] [template] [workflow] [context] [worktree] [worktree_base]
remote_thread_create() {
    local name="$1"
    local mode="${2:-automatic}"
    local template="${3:-}"
    local workflow="${4:-}"
    local context="${5:-{}}"
    local use_worktree="${6:-true}"  # Default to true for remote threads
    local worktree_base="${7:-main}"

    local body
    body=$(jq -n \
        --arg name "$name" \
        --arg mode "$mode" \
        --arg template "$template" \
        --arg workflow "$workflow" \
        --argjson context "$context" \
        --argjson worktree "$use_worktree" \
        --arg worktree_base "$worktree_base" \
        '{
            name: $name,
            mode: $mode,
            template: (if $template != "" then $template else null end),
            workflow: (if $workflow != "" then $workflow else null end),
            context: $context,
            worktree: $worktree,
            worktree_base: $worktree_base
        }')

    remote_api_call POST "/api/threads" "$body"
}

# Start thread via API
remote_thread_start() {
    local thread_id="$1"

    remote_api_call POST "/api/threads/$thread_id/start" '{}'
}

# Stop thread via API
remote_thread_stop() {
    local thread_id="$1"

    remote_api_call POST "/api/threads/$thread_id/stop" '{}'
}

# Get thread details via API
remote_thread_get() {
    local thread_id="$1"

    remote_api_call GET "/api/threads/$thread_id"
}

# List threads via API
# Usage: remote_thread_list [status] [mode] [limit]
remote_thread_list() {
    local status="${1:-}"
    local mode="${2:-}"
    local limit="${3:-50}"

    local query=""
    [[ -n "$status" ]] && query+="status=$status&"
    [[ -n "$mode" ]] && query+="mode=$mode&"
    query+="limit=$limit"

    remote_api_call GET "/api/threads?$query"
}

# Delete thread via API
remote_thread_delete() {
    local thread_id="$1"

    remote_api_call DELETE "/api/threads/$thread_id"
}

# ============================================================
# Event Operations
# ============================================================

# Publish event via API
# Usage: remote_event_publish <type> [data] [source] [targets]
remote_event_publish() {
    local type="$1"
    local data="${2:-{}}"
    local source="${3:-remote}"
    local targets="${4:-*}"

    local body
    body=$(jq -n \
        --arg type "$type" \
        --argjson data "$data" \
        --arg source "$source" \
        --arg targets "$targets" \
        '{
            type: $type,
            data: $data,
            source: $source,
            targets: $targets
        }')

    remote_api_call POST "/api/events" "$body"
}

# List events via API
# Usage: remote_event_list [type] [source] [limit]
remote_event_list() {
    local type="${1:-}"
    local source="${2:-}"
    local limit="${3:-100}"

    local query=""
    [[ -n "$type" ]] && query+="type=$type&"
    [[ -n "$source" ]] && query+="source=$source&"
    query+="limit=$limit"

    remote_api_call GET "/api/events?$query"
}

# ============================================================
# Message Operations
# ============================================================

# Send message via API
# Usage: remote_message_send <to_thread> <type> [content] [priority]
remote_message_send() {
    local to_thread="$1"
    local type="$2"
    local content="${3:-{}}"
    local priority="${4:-0}"

    local body
    body=$(jq -n \
        --arg to "$to_thread" \
        --arg type "$type" \
        --argjson content "$content" \
        --arg priority "$priority" \
        '{
            to: $to,
            type: $type,
            content: $content,
            priority: ($priority | tonumber)
        }')

    remote_api_call POST "/api/messages" "$body"
}

# Get messages for thread via API
remote_message_list() {
    local thread_id="$1"

    remote_api_call GET "/api/messages/$thread_id"
}

# ============================================================
# Status Operations
# ============================================================

# Health check
remote_health_check() {
    remote_api_call GET "/api/health"
}

# Get system status
remote_api_status() {
    remote_api_call GET "/api/status"
}

# ============================================================
# Spawn Helper
# ============================================================

# Spawn a thread (create + start in one operation)
# Usage: remote_spawn <name> [options...]
#   --template <file>     Template file
#   --mode <mode>         Thread mode (automatic|manual|batch)
#   --context <json>      Context JSON
#   --worktree            Enable worktree isolation (DEFAULT for remote)
#   --no-worktree         Disable worktree isolation
#   --worktree-base <br>  Base branch for worktree
#   --wait                Wait for thread completion
#
# NOTE: Worktree is ENABLED by default for remote spawns because external
# Claude Code instances MUST work in isolated worktrees to avoid conflicts.
remote_spawn() {
    local name="$1"
    shift

    local template=""
    local mode="automatic"
    local context="{}"
    local worktree=1  # DEFAULT: enabled for remote spawns
    local worktree_base="main"
    local wait=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --template|-t)
                template="$2"
                shift 2
                ;;
            --mode|-m)
                mode="$2"
                shift 2
                ;;
            --context|-c)
                context="$2"
                shift 2
                ;;
            --worktree|-w)
                worktree=1
                shift
                ;;
            --no-worktree)
                worktree=0
                shift
                ;;
            --worktree-base)
                worktree_base="$2"
                shift 2
                ;;
            --wait)
                wait=1
                shift
                ;;
            *)
                ct_warn "Unknown option: $1"
                shift
                ;;
        esac
    done

    # Convert worktree flag to boolean for JSON
    local use_worktree="true"
    if [[ $worktree -eq 0 ]]; then
        use_worktree="false"
    fi

    # Create thread with worktree parameters
    local result
    result=$(remote_thread_create "$name" "$mode" "$template" "" "$context" "$use_worktree" "$worktree_base")

    if [[ $? -ne 0 ]]; then
        ct_error "Failed to create thread: $name"
        return 1
    fi

    local thread_id worktree_path
    thread_id=$(echo "$result" | jq -r '.id // empty')
    worktree_path=$(echo "$result" | jq -r '.worktree // empty')

    if [[ -z "$thread_id" ]]; then
        ct_error "Failed to get thread ID from response"
        echo "$result"
        return 1
    fi

    ct_info "Created thread: $thread_id"
    if [[ -n "$worktree_path" ]]; then
        ct_info "Worktree: $worktree_path"
    fi

    # Start thread
    result=$(remote_thread_start "$thread_id")

    if [[ $? -ne 0 ]]; then
        ct_error "Failed to start thread: $thread_id"
        return 1
    fi

    ct_info "Started thread: $thread_id"

    # Wait for completion if requested
    if [[ $wait -eq 1 ]]; then
        ct_info "Waiting for thread completion..."

        while true; do
            local status
            status=$(remote_thread_get "$thread_id" | jq -r '.status // empty')

            case "$status" in
                completed|failed|cancelled)
                    ct_info "Thread $thread_id finished with status: $status"
                    break
                    ;;
                *)
                    sleep 5
                    ;;
            esac
        done
    fi

    echo "$result"
}
