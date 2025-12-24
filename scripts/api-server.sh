#!/usr/bin/env bash
#
# api-server.sh - HTTP API server for claude-threads (n8n integration)
#
# Provides a REST API for thread management, event publishing, and status queries.
# Designed for integration with n8n workflows and other automation tools.
#
# Usage:
#   ./scripts/api-server.sh start [--port 31337]
#   ./scripts/api-server.sh stop
#   ./scripts/api-server.sh status
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Source libraries
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/log.sh"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/db.sh"
source "$ROOT_DIR/lib/state.sh"
source "$ROOT_DIR/lib/blackboard.sh"
source "$ROOT_DIR/lib/registry.sh"

# ============================================================
# Configuration
# ============================================================

DATA_DIR=""
PID_FILE=""
PORT=""
API_TOKEN=""
BIND_ADDRESS="127.0.0.1"  # Default to localhost for security
ALLOW_NO_AUTH="false"
PORT_ALLOCATION="manual"  # 'auto' or 'manual'
HEARTBEAT_PID=""
ALLOCATED_PORT=""

# ============================================================
# Initialization
# ============================================================

init() {
    DATA_DIR="${CT_DATA_DIR:-$(ct_data_dir)}"
    PID_FILE="$DATA_DIR/api-server.pid"

    # Load configuration
    config_load "$DATA_DIR/config.yaml"

    PORT="${API_PORT:-$(config_get 'n8n.api_port' 31337)}"
    API_TOKEN="${N8N_API_TOKEN:-$(config_get 'n8n.api_token' '')}"
    PORT_ALLOCATION="${CT_PORT_ALLOCATION:-$(config_get 'ports.allocation' 'auto')}"

    # Initialize logging
    log_init "api" "$DATA_DIR/logs/api-server.log"
    log_set_level "$(config_get 'orchestrator.log_level' 'info')"

    # Initialize database
    db_init "$DATA_DIR"
    bb_init "$DATA_DIR"
    state_init "$DATA_DIR"

    log_debug "API server initialized (port=$PORT)"
}

# ============================================================
# Authentication
# ============================================================

verify_auth() {
    local auth_header="$1"

    if [[ -z "$API_TOKEN" ]]; then
        # No token configured, allow all
        return 0
    fi

    if [[ -z "$auth_header" ]]; then
        return 1
    fi

    # Support "Bearer <token>" or just "<token>"
    local token="${auth_header#Bearer }"

    if [[ "$token" == "$API_TOKEN" ]]; then
        return 0
    fi

    return 1
}

# ============================================================
# API Handlers
# ============================================================

# GET /api/threads - List threads
api_list_threads() {
    local query_params="$1"

    local status=""
    local mode=""
    local limit="50"

    # Parse query params (portable, no grep -P)
    if [[ -n "$query_params" ]]; then
        status=$(ct_query_param "$query_params" "status")
        mode=$(ct_query_param "$query_params" "mode")
        limit=$(ct_query_param "$query_params" "limit" "50")
    fi

    local sql="SELECT * FROM threads WHERE 1=1"
    [[ -n "$status" ]] && sql+=" AND status = $(db_quote "$status")"
    [[ -n "$mode" ]] && sql+=" AND mode = $(db_quote "$mode")"
    sql+=" ORDER BY updated_at DESC LIMIT $limit"

    local threads
    threads=$(db_query "$sql")

    echo "$threads"
}

# GET /api/threads/:id - Get thread details
api_get_thread() {
    local thread_id="$1"

    local thread
    thread=$(thread_get "$thread_id")

    if [[ -z "$thread" ]]; then
        echo '{"error": "Thread not found"}'
        return 1
    fi

    echo "$thread"
}

# POST /api/threads - Create thread
api_create_thread() {
    local body="$1"

    local name mode template workflow context
    name=$(echo "$body" | jq -r '.name // empty')
    mode=$(echo "$body" | jq -r '.mode // "automatic"')
    template=$(echo "$body" | jq -r '.template // empty')
    workflow=$(echo "$body" | jq -r '.workflow // empty')
    context=$(echo "$body" | jq -c '.context // {}')

    if [[ -z "$name" ]]; then
        echo '{"error": "Name is required"}'
        return 1
    fi

    local thread_id
    thread_id=$(thread_create "$name" "$mode" "$template" "$workflow" "$context")

    echo "{\"id\": \"$thread_id\", \"name\": \"$name\", \"mode\": \"$mode\", \"status\": \"created\"}"
}

# POST /api/threads/:id/start - Start thread
api_start_thread() {
    local thread_id="$1"

    local thread
    thread=$(thread_get "$thread_id")

    if [[ -z "$thread" ]]; then
        echo '{"error": "Thread not found"}'
        return 1
    fi

    local status
    status=$(echo "$thread" | jq -r '.status')

    if [[ "$status" == "created" ]]; then
        thread_ready "$thread_id"
    fi

    # Start thread runner in background
    "$SCRIPT_DIR/thread-runner.sh" --thread-id "$thread_id" --data-dir "$DATA_DIR" --background

    echo "{\"id\": \"$thread_id\", \"status\": \"started\"}"
}

# POST /api/threads/:id/stop - Stop thread
api_stop_thread() {
    local thread_id="$1"

    local pid_file="$DATA_DIR/tmp/thread-${thread_id}.pid"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        kill -TERM "$pid" 2>/dev/null || true
        rm -f "$pid_file"
    fi

    thread_wait "$thread_id" "Stopped via API"

    echo "{\"id\": \"$thread_id\", \"status\": \"stopped\"}"
}

# DELETE /api/threads/:id - Delete thread
api_delete_thread() {
    local thread_id="$1"

    # Stop first if running
    api_stop_thread "$thread_id" >/dev/null 2>&1 || true

    thread_delete "$thread_id"

    echo "{\"id\": \"$thread_id\", \"deleted\": true}"
}

# GET /api/events - List events
api_list_events() {
    local query_params="$1"

    local type=""
    local source=""
    local limit="100"

    if [[ -n "$query_params" ]]; then
        type=$(ct_query_param "$query_params" "type")
        source=$(ct_query_param "$query_params" "source")
        limit=$(ct_query_param "$query_params" "limit" "100")
    fi

    bb_history "$limit" "$type" "$source"
}

# POST /api/events - Publish event
api_publish_event() {
    local body="$1"

    local type data source targets
    type=$(echo "$body" | jq -r '.type // empty')
    data=$(echo "$body" | jq -c '.data // {}')
    source=$(echo "$body" | jq -r '.source // "api"')
    targets=$(echo "$body" | jq -r '.targets // "*"')

    if [[ -z "$type" ]]; then
        echo '{"error": "Event type is required"}'
        return 1
    fi

    bb_publish "$type" "$data" "$source" "$targets"

    echo "{\"type\": \"$type\", \"published\": true}"
}

# GET /api/messages/:thread_id - Get messages for thread
api_get_messages() {
    local thread_id="$1"

    bb_inbox "$thread_id"
}

# POST /api/messages - Send message
api_send_message() {
    local body="$1"

    local to_thread type content priority
    to_thread=$(echo "$body" | jq -r '.to // empty')
    type=$(echo "$body" | jq -r '.type // "MESSAGE"')
    content=$(echo "$body" | jq -c '.content // {}')
    priority=$(echo "$body" | jq -r '.priority // 0')

    if [[ -z "$to_thread" ]]; then
        echo '{"error": "Target thread is required"}'
        return 1
    fi

    bb_send "$to_thread" "$type" "$content" "$priority"

    echo "{\"to\": \"$to_thread\", \"type\": \"$type\", \"sent\": true}"
}

# GET /api/status - System status
api_status() {
    local threads_total threads_running events_pending
    threads_total=$(db_scalar "SELECT COUNT(*) FROM threads")
    threads_running=$(db_scalar "SELECT COUNT(*) FROM threads WHERE status = 'running'")
    events_pending=$(db_scalar "SELECT COUNT(*) FROM events WHERE processed = 0")

    # Check orchestrator
    local orchestrator_running="false"
    if [[ -f "$DATA_DIR/orchestrator.pid" ]]; then
        local pid
        pid=$(cat "$DATA_DIR/orchestrator.pid")
        if kill -0 "$pid" 2>/dev/null; then
            orchestrator_running="true"
        fi
    fi

    jq -n \
        --arg total "$threads_total" \
        --arg running "$threads_running" \
        --arg events "$events_pending" \
        --arg orch "$orchestrator_running" \
        '{
            threads: {total: ($total | tonumber), running: ($running | tonumber)},
            events_pending: ($events | tonumber),
            orchestrator_running: ($orch == "true")
        }'
}

# GET /api/health - Health check
api_health() {
    echo '{"status": "ok"}'
}

# ============================================================
# HTTP Server (Python)
# ============================================================

start_server_python() {
    log_info "Starting API server on $BIND_ADDRESS:$PORT..."

    export API_PORT="$PORT"
    export API_BIND_ADDRESS="$BIND_ADDRESS"
    export CT_DATA_DIR="$DATA_DIR"
    export CT_SCRIPT_DIR="$SCRIPT_DIR"
    export N8N_API_TOKEN="$API_TOKEN"

    python3 << 'PYEOF' &
import http.server
import json
import os
import subprocess
import urllib.parse

PORT = int(os.environ.get('API_PORT', 31337))
BIND_ADDRESS = os.environ.get('API_BIND_ADDRESS', '127.0.0.1')
DATA_DIR = os.environ.get('CT_DATA_DIR', '.claude-threads')
# NOTE: this script is executed via stdin heredoc, so __file__ may not exist.
# We pass CT_SCRIPT_DIR from the bash wrapper; fall back to <data-dir>/scripts.
SCRIPT_DIR = os.environ.get('CT_SCRIPT_DIR', os.path.join(DATA_DIR, 'scripts'))
API_TOKEN = os.environ.get('N8N_API_TOKEN', '')

class APIHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def verify_auth(self):
        if not API_TOKEN:
            return True
        auth = self.headers.get('Authorization', '')
        token = auth.replace('Bearer ', '')
        return token == API_TOKEN

    def send_json(self, status, data):
        if isinstance(data, str):
            body = data.encode('utf-8')
        else:
            body = json.dumps(data).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(body))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)

    def call_api(self, handler, *args):
        env = os.environ.copy()
        env['API_HANDLER'] = handler
        env['API_ARGS'] = json.dumps(args)

        result = subprocess.run(
            [os.path.join(SCRIPT_DIR, 'api-handler.sh')],
            env=env,
            capture_output=True,
            text=True
        )

        if result.returncode == 0:
            return result.stdout.strip()
        else:
            return json.dumps({'error': result.stderr.strip() or 'Unknown error'})

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type, Authorization')
        self.end_headers()

    def do_GET(self):
        if not self.verify_auth():
            self.send_json(401, {'error': 'Unauthorized'})
            return

        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = parsed.query

        if path == '/api/health':
            self.send_json(200, {'status': 'ok'})
        elif path == '/api/status':
            result = self.call_api('status')
            self.send_json(200, result)
        elif path == '/api/threads':
            result = self.call_api('list_threads', query)
            self.send_json(200, result)
        elif path.startswith('/api/threads/'):
            thread_id = path.split('/')[-1]
            result = self.call_api('get_thread', thread_id)
            status = 200 if 'error' not in result else 404
            self.send_json(status, result)
        elif path == '/api/events':
            result = self.call_api('list_events', query)
            self.send_json(200, result)
        elif path.startswith('/api/messages/'):
            thread_id = path.split('/')[-1]
            result = self.call_api('get_messages', thread_id)
            self.send_json(200, result)
        else:
            self.send_json(404, {'error': 'Not Found'})

    def do_POST(self):
        if not self.verify_auth():
            self.send_json(401, {'error': 'Unauthorized'})
            return

        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode('utf-8') if content_length else '{}'

        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == '/api/threads':
            result = self.call_api('create_thread', body)
            status = 201 if 'error' not in result else 400
            self.send_json(status, result)
        elif path.endswith('/start'):
            thread_id = path.split('/')[-2]
            result = self.call_api('start_thread', thread_id)
            self.send_json(200, result)
        elif path.endswith('/stop'):
            thread_id = path.split('/')[-2]
            result = self.call_api('stop_thread', thread_id)
            self.send_json(200, result)
        elif path == '/api/events':
            result = self.call_api('publish_event', body)
            status = 201 if 'error' not in result else 400
            self.send_json(status, result)
        elif path == '/api/messages':
            result = self.call_api('send_message', body)
            status = 201 if 'error' not in result else 400
            self.send_json(status, result)
        else:
            self.send_json(404, {'error': 'Not Found'})

    def do_DELETE(self):
        if not self.verify_auth():
            self.send_json(401, {'error': 'Unauthorized'})
            return

        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path.startswith('/api/threads/'):
            thread_id = path.split('/')[-1]
            result = self.call_api('delete_thread', thread_id)
            self.send_json(200, result)
        else:
            self.send_json(404, {'error': 'Not Found'})

if __name__ == '__main__':
    server = http.server.HTTPServer((BIND_ADDRESS, PORT), APIHandler)
    print(f'API server running on {BIND_ADDRESS}:{PORT}')
    server.serve_forever()
PYEOF

    echo $! > "$PID_FILE"
}

# ============================================================
# Daemon Control
# ============================================================

is_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        rm -f "$PID_FILE"
    fi
    return 1
}

start_daemon() {
    if is_running; then
        echo "API server already running (PID: $(cat "$PID_FILE"))"
        exit 1
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo "Error: Python 3 is required for the API server"
        exit 1
    fi

    # Security check: require token unless explicitly disabled
    if [[ -z "$API_TOKEN" && "$ALLOW_NO_AUTH" != "true" ]]; then
        echo "Error: No API token configured."
        echo ""
        echo "For security, an API token is required. Set one of:"
        echo "  - Environment variable: N8N_API_TOKEN=your-secret-token"
        echo "  - Config file: n8n.api_token in config.yaml"
        echo ""
        echo "To run without authentication (NOT recommended for production):"
        echo "  --insecure-allow-no-auth"
        exit 1
    fi

    if [[ "$ALLOW_NO_AUTH" == "true" ]]; then
        log_warn "Running without authentication - NOT recommended for production"
        echo "WARNING: Running without authentication"
    fi

    # Handle port allocation
    if [[ "$PORT" == "auto" || "$PORT_ALLOCATION" == "auto" ]]; then
        local project_root
        project_root="${CT_PROJECT_ROOT:-$(pwd)}"

        ALLOCATED_PORT=$(registry_allocate_port "$project_root" "api")
        if [[ -z "$ALLOCATED_PORT" ]]; then
            echo "Error: Failed to allocate port from registry"
            exit 1
        fi
        PORT="$ALLOCATED_PORT"
        log_info "Allocated port $PORT from registry"

        # Set up cleanup trap
        trap 'cleanup_registry' EXIT INT TERM
    fi

    start_server_python

    # Start heartbeat if using registry
    if [[ -n "$ALLOCATED_PORT" ]]; then
        HEARTBEAT_PID=$(registry_start_heartbeat "$ALLOCATED_PORT")
        log_debug "Started heartbeat process (PID: $HEARTBEAT_PID)"
    fi

    echo "API server started on $BIND_ADDRESS:$PORT (PID: $(cat "$PID_FILE"))"
    log_info "API server daemon started"
}

# Cleanup registry on exit
cleanup_registry() {
    if [[ -n "$HEARTBEAT_PID" ]]; then
        registry_stop_heartbeat "$HEARTBEAT_PID"
    fi
    if [[ -n "$ALLOCATED_PORT" ]]; then
        registry_release_port "$ALLOCATED_PORT"
        log_info "Released port $ALLOCATED_PORT from registry"
    fi
}

stop_daemon() {
    if ! is_running; then
        echo "API server not running"
        return 0
    fi

    local pid
    pid=$(cat "$PID_FILE")

    log_info "Stopping API server (PID: $pid)..."
    kill -TERM "$pid" 2>/dev/null || true

    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
    fi

    rm -f "$PID_FILE"

    # Cleanup registry if we allocated a port
    cleanup_registry

    echo "API server stopped"
    log_info "API server stopped"
}

show_status() {
    echo "API Server Status"
    echo "================="
    echo ""

    if is_running; then
        echo "Status: Running (PID: $(cat "$PID_FILE"))"
    else
        echo "Status: Stopped"
    fi

    echo "Bind: $BIND_ADDRESS:$PORT"
    echo "Token: ${API_TOKEN:+configured}${API_TOKEN:-NOT SET}"
    echo ""
    echo "Endpoints:"
    echo "  GET  /api/health           Health check"
    echo "  GET  /api/status           System status"
    echo "  GET  /api/threads          List threads"
    echo "  POST /api/threads          Create thread"
    echo "  GET  /api/threads/:id      Get thread"
    echo "  POST /api/threads/:id/start  Start thread"
    echo "  POST /api/threads/:id/stop   Stop thread"
    echo "  DELETE /api/threads/:id    Delete thread"
    echo "  GET  /api/events           List events"
    echo "  POST /api/events           Publish event"
    echo "  GET  /api/messages/:id     Get messages"
    echo "  POST /api/messages         Send message"
}

# ============================================================
# Main
# ============================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  start       Start API server
  stop        Stop API server
  status      Show status

Options:
  --port PORT                Server port (default: 31337, use 'auto' for dynamic allocation)
  --bind ADDRESS             Bind address (default: 127.0.0.1)
  --data-dir DIR             Data directory
  --insecure-allow-no-auth   Allow running without API token (NOT recommended)

Environment:
  N8N_API_TOKEN        API authentication token
  API_PORT             Server port
  API_BIND_ADDRESS     Bind address
  CT_PORT_ALLOCATION   Port allocation mode ('auto' or 'manual')
EOF
    exit 0
}

main() {
    local command="${1:-}"
    shift || true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port|-p)
                API_PORT="$2"
                shift 2
                ;;
            --bind|-b)
                BIND_ADDRESS="$2"
                shift 2
                ;;
            --data-dir)
                export CT_DATA_DIR="$2"
                shift 2
                ;;
            --insecure-allow-no-auth)
                ALLOW_NO_AUTH="true"
                shift
                ;;
            --help|-h)
                usage
                ;;
            *)
                break
                ;;
        esac
    done

    init

    case "$command" in
        start)
            start_daemon
            ;;
        stop)
            stop_daemon
            ;;
        status)
            show_status
            ;;
        ""|--help|-h)
            usage
            ;;
        *)
            echo "Unknown command: $command"
            usage
            ;;
    esac
}

main "$@"
