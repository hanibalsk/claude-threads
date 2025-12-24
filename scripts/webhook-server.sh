#!/usr/bin/env bash
#
# webhook-server.sh - GitHub webhook receiver for claude-threads
#
# Lightweight HTTP server that receives GitHub webhooks and publishes
# events to the blackboard for thread processing.
#
# Usage:
#   ./scripts/webhook-server.sh start [--port 8080]
#   ./scripts/webhook-server.sh stop
#   ./scripts/webhook-server.sh status
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Source libraries
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/log.sh"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/db.sh"
source "$ROOT_DIR/lib/blackboard.sh"

# ============================================================
# Configuration
# ============================================================

DATA_DIR=""
PID_FILE=""
PORT=""
WEBHOOK_SECRET=""

# ============================================================
# Initialization
# ============================================================

init() {
    DATA_DIR="${CT_DATA_DIR:-$(ct_data_dir)}"
    PID_FILE="$DATA_DIR/webhook-server.pid"

    # Load configuration
    config_load "$DATA_DIR/config.yaml"

    PORT="${WEBHOOK_PORT:-$(config_get 'github.webhook_port' 8080)}"
    WEBHOOK_SECRET="${GITHUB_WEBHOOK_SECRET:-$(config_get 'github.webhook_secret' '')}"

    # Initialize logging
    log_init "webhook" "$DATA_DIR/logs/webhook-server.log"
    log_set_level "$(config_get 'orchestrator.log_level' 'info')"

    # Initialize database
    db_init "$DATA_DIR"
    bb_init "$DATA_DIR"

    log_debug "Webhook server initialized (port=$PORT)"
}

# ============================================================
# Signature Verification
# ============================================================

verify_signature() {
    local payload="$1"
    local signature="$2"

    if [[ -z "$WEBHOOK_SECRET" ]]; then
        log_warn "No webhook secret configured, skipping verification"
        return 0
    fi

    if [[ -z "$signature" ]]; then
        log_error "No signature provided"
        return 1
    fi

    # Extract signature (format: sha256=...)
    local expected_sig="${signature#sha256=}"

    # Calculate HMAC
    local calculated_sig
    calculated_sig=$(echo -n "$payload" | openssl dgst -sha256 -hmac "$WEBHOOK_SECRET" | awk '{print $2}')

    if [[ "$expected_sig" != "$calculated_sig" ]]; then
        log_error "Signature verification failed"
        return 1
    fi

    log_debug "Signature verified"
    return 0
}

# ============================================================
# Event Handlers
# ============================================================

handle_pull_request() {
    local payload="$1"

    local action pr_number title branch base_branch author
    action=$(echo "$payload" | jq -r '.action')
    pr_number=$(echo "$payload" | jq -r '.pull_request.number')
    title=$(echo "$payload" | jq -r '.pull_request.title')
    branch=$(echo "$payload" | jq -r '.pull_request.head.ref')
    base_branch=$(echo "$payload" | jq -r '.pull_request.base.ref')
    author=$(echo "$payload" | jq -r '.pull_request.user.login')

    log_info "Pull request event: #$pr_number $action"

    local event_type="PR_${action^^}"
    local event_data
    event_data=$(jq -n \
        --arg pr "$pr_number" \
        --arg title "$title" \
        --arg branch "$branch" \
        --arg base "$base_branch" \
        --arg author "$author" \
        --arg action "$action" \
        '{pr_number: $pr, title: $title, branch: $branch, base_branch: $base, author: $author, action: $action}')

    bb_publish "$event_type" "$event_data" "github"

    # Store webhook for processing
    store_webhook "github" "pull_request" "$payload"
}

handle_pull_request_review() {
    local payload="$1"

    local action pr_number state reviewer
    action=$(echo "$payload" | jq -r '.action')
    pr_number=$(echo "$payload" | jq -r '.pull_request.number')
    state=$(echo "$payload" | jq -r '.review.state')
    reviewer=$(echo "$payload" | jq -r '.review.user.login')

    log_info "PR review event: #$pr_number $state by $reviewer"

    local event_type
    case "$state" in
        approved) event_type="PR_APPROVED" ;;
        changes_requested) event_type="PR_CHANGES_REQUESTED" ;;
        commented) event_type="PR_REVIEW_COMMENT" ;;
        *) event_type="PR_REVIEW_$state" ;;
    esac

    local event_data
    event_data=$(jq -n \
        --arg pr "$pr_number" \
        --arg state "$state" \
        --arg reviewer "$reviewer" \
        '{pr_number: $pr, state: $state, reviewer: $reviewer}')

    bb_publish "$event_type" "$event_data" "github"
    store_webhook "github" "pull_request_review" "$payload"
}

handle_check_run() {
    local payload="$1"

    local action name status conclusion pr_numbers
    action=$(echo "$payload" | jq -r '.action')
    name=$(echo "$payload" | jq -r '.check_run.name')
    status=$(echo "$payload" | jq -r '.check_run.status')
    conclusion=$(echo "$payload" | jq -r '.check_run.conclusion // "pending"')
    pr_numbers=$(echo "$payload" | jq -r '[.check_run.pull_requests[].number] | join(",")')

    log_info "Check run event: $name $status ($conclusion)"

    local event_type
    if [[ "$status" == "completed" ]]; then
        case "$conclusion" in
            success) event_type="CI_PASSED" ;;
            failure|cancelled|timed_out) event_type="CI_FAILED" ;;
            *) event_type="CI_COMPLETED" ;;
        esac
    else
        event_type="CI_RUNNING"
    fi

    local event_data
    event_data=$(jq -n \
        --arg name "$name" \
        --arg status "$status" \
        --arg conclusion "$conclusion" \
        --arg prs "$pr_numbers" \
        '{check_name: $name, status: $status, conclusion: $conclusion, pr_numbers: $prs}')

    bb_publish "$event_type" "$event_data" "github"
    store_webhook "github" "check_run" "$payload"
}

handle_check_suite() {
    local payload="$1"

    local action status conclusion pr_numbers
    action=$(echo "$payload" | jq -r '.action')
    status=$(echo "$payload" | jq -r '.check_suite.status')
    conclusion=$(echo "$payload" | jq -r '.check_suite.conclusion // "pending"')
    pr_numbers=$(echo "$payload" | jq -r '[.check_suite.pull_requests[].number] | join(",")')

    log_info "Check suite event: $status ($conclusion)"

    if [[ "$action" == "completed" ]]; then
        local event_type
        case "$conclusion" in
            success) event_type="CI_SUITE_PASSED" ;;
            failure) event_type="CI_SUITE_FAILED" ;;
            *) event_type="CI_SUITE_COMPLETED" ;;
        esac

        local event_data
        event_data=$(jq -n \
            --arg status "$status" \
            --arg conclusion "$conclusion" \
            --arg prs "$pr_numbers" \
            '{status: $status, conclusion: $conclusion, pr_numbers: $prs}')

        bb_publish "$event_type" "$event_data" "github"
    fi

    store_webhook "github" "check_suite" "$payload"
}

handle_issue_comment() {
    local payload="$1"

    local action issue_number body author is_pr
    action=$(echo "$payload" | jq -r '.action')
    issue_number=$(echo "$payload" | jq -r '.issue.number')
    body=$(echo "$payload" | jq -r '.comment.body')
    author=$(echo "$payload" | jq -r '.comment.user.login')
    is_pr=$(echo "$payload" | jq -r 'if .issue.pull_request then "true" else "false" end')

    if [[ "$is_pr" == "true" ]]; then
        log_info "PR comment event: #$issue_number by $author"

        local event_data
        event_data=$(jq -n \
            --arg pr "$issue_number" \
            --arg body "$body" \
            --arg author "$author" \
            --arg action "$action" \
            '{pr_number: $pr, body: $body, author: $author, action: $action}')

        bb_publish "PR_COMMENT" "$event_data" "github"
    fi

    store_webhook "github" "issue_comment" "$payload"
}

handle_push() {
    local payload="$1"

    local ref branch commits_count
    ref=$(echo "$payload" | jq -r '.ref')
    branch="${ref#refs/heads/}"
    commits_count=$(echo "$payload" | jq -r '.commits | length')

    log_info "Push event: $branch ($commits_count commits)"

    local event_data
    event_data=$(jq -n \
        --arg branch "$branch" \
        --arg commits "$commits_count" \
        '{branch: $branch, commits_count: $commits}')

    bb_publish "PUSH" "$event_data" "github"
    store_webhook "github" "push" "$payload"
}

store_webhook() {
    local source="$1"
    local event_type="$2"
    local payload="$3"

    db_exec "INSERT INTO webhooks (source, event_type, payload)
             VALUES ($(db_quote "$source"), $(db_quote "$event_type"), $(db_quote "$payload"))"
}

# ============================================================
# HTTP Server
# ============================================================

handle_request() {
    local request_file="$1"

    # Read request
    local method path headers body
    read -r method path _ < "$request_file"
    path="${path%$'\r'}"

    # Read headers
    declare -A headers
    while IFS=': ' read -r key value; do
        [[ -z "$key" || "$key" == $'\r' ]] && break
        headers["${key,,}"]="${value%$'\r'}"
    done < <(tail -n +2 "$request_file")

    # Read body if present
    local content_length="${headers[content-length]:-0}"
    body=""
    if [[ $content_length -gt 0 ]]; then
        body=$(tail -c "$content_length" "$request_file")
    fi

    log_debug "Request: $method $path"

    # Route request
    case "$path" in
        /webhook|/github)
            if [[ "$method" == "POST" ]]; then
                handle_webhook_post "$body" "${headers[x-hub-signature-256]:-}" "${headers[x-github-event]:-}"
            else
                send_response 405 "Method Not Allowed"
            fi
            ;;
        /health)
            send_response 200 '{"status": "ok"}'
            ;;
        *)
            send_response 404 "Not Found"
            ;;
    esac
}

handle_webhook_post() {
    local body="$1"
    local signature="$2"
    local event_type="$3"

    # Verify signature
    if ! verify_signature "$body" "$signature"; then
        send_response 401 "Unauthorized"
        return
    fi

    # Validate JSON
    if ! echo "$body" | jq empty 2>/dev/null; then
        log_error "Invalid JSON payload"
        send_response 400 "Invalid JSON"
        return
    fi

    log_info "Webhook received: $event_type"

    # Route to handler
    case "$event_type" in
        pull_request)
            handle_pull_request "$body"
            ;;
        pull_request_review)
            handle_pull_request_review "$body"
            ;;
        check_run)
            handle_check_run "$body"
            ;;
        check_suite)
            handle_check_suite "$body"
            ;;
        issue_comment)
            handle_issue_comment "$body"
            ;;
        push)
            handle_push "$body"
            ;;
        *)
            log_debug "Unhandled event type: $event_type"
            store_webhook "github" "$event_type" "$body"
            ;;
    esac

    send_response 200 '{"status": "received"}'
}

send_response() {
    local status="$1"
    local body="$2"

    local status_text
    case "$status" in
        200) status_text="OK" ;;
        400) status_text="Bad Request" ;;
        401) status_text="Unauthorized" ;;
        404) status_text="Not Found" ;;
        405) status_text="Method Not Allowed" ;;
        500) status_text="Internal Server Error" ;;
        *) status_text="Unknown" ;;
    esac

    local content_length=${#body}

    printf "HTTP/1.1 %s %s\r\n" "$status" "$status_text"
    printf "Content-Type: application/json\r\n"
    printf "Content-Length: %d\r\n" "$content_length"
    printf "Connection: close\r\n"
    printf "\r\n"
    printf "%s" "$body"
}

start_server() {
    log_info "Starting webhook server on port $PORT..."

    # Check if nc supports -l -p or just -l
    local nc_cmd
    if nc -h 2>&1 | grep -q '\-p'; then
        nc_cmd="nc -l -p $PORT"
    else
        nc_cmd="nc -l $PORT"
    fi

    while true; do
        local tmp_file
        tmp_file=$(mktemp)

        # Listen for connection
        $nc_cmd > "$tmp_file" 2>/dev/null &
        local nc_pid=$!

        wait $nc_pid 2>/dev/null || true

        if [[ -s "$tmp_file" ]]; then
            handle_request "$tmp_file" | $nc_cmd 2>/dev/null || true
        fi

        rm -f "$tmp_file"
    done
}

# Alternative: Use Python for more robust HTTP handling
start_server_python() {
    log_info "Starting webhook server (Python) on port $PORT..."

    python3 << 'PYEOF' &
import http.server
import json
import hmac
import hashlib
import subprocess
import os
import sys

PORT = int(os.environ.get('WEBHOOK_PORT', 8080))
SECRET = os.environ.get('GITHUB_WEBHOOK_SECRET', '')
DATA_DIR = os.environ.get('CT_DATA_DIR', '.claude-threads')

class WebhookHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress default logging

    def do_GET(self):
        if self.path == '/health':
            self.send_json(200, {'status': 'ok'})
        else:
            self.send_json(404, {'error': 'Not Found'})

    def do_POST(self):
        if self.path not in ['/webhook', '/github']:
            self.send_json(404, {'error': 'Not Found'})
            return

        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode('utf-8')

        # Verify signature
        signature = self.headers.get('X-Hub-Signature-256', '')
        if SECRET and not self.verify_signature(body, signature):
            self.send_json(401, {'error': 'Unauthorized'})
            return

        # Get event type
        event_type = self.headers.get('X-GitHub-Event', 'unknown')

        # Parse JSON
        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            self.send_json(400, {'error': 'Invalid JSON'})
            return

        # Process webhook
        self.process_webhook(event_type, payload)
        self.send_json(200, {'status': 'received'})

    def verify_signature(self, body, signature):
        if not signature.startswith('sha256='):
            return False
        expected = signature[7:]
        calculated = hmac.new(
            SECRET.encode(), body.encode(), hashlib.sha256
        ).hexdigest()
        return hmac.compare_digest(expected, calculated)

    def process_webhook(self, event_type, payload):
        # Call bash script to handle the webhook
        env = os.environ.copy()
        env['WEBHOOK_EVENT'] = event_type
        env['WEBHOOK_PAYLOAD'] = json.dumps(payload)

        subprocess.run([
            f'{DATA_DIR}/scripts/webhook-handler.sh'
        ], env=env, capture_output=True)

    def send_json(self, status, data):
        body = json.dumps(data).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(body))
        self.end_headers()
        self.wfile.write(body)

if __name__ == '__main__':
    server = http.server.HTTPServer(('', PORT), WebhookHandler)
    print(f'Webhook server running on port {PORT}')
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
        echo "Webhook server already running (PID: $(cat "$PID_FILE"))"
        exit 1
    fi

    # Check for Python 3
    if command -v python3 >/dev/null 2>&1; then
        export WEBHOOK_PORT="$PORT"
        export CT_DATA_DIR="$DATA_DIR"
        start_server_python
    else
        # Fallback to netcat
        (start_server) &
        echo $! > "$PID_FILE"
    fi

    echo "Webhook server started on port $PORT (PID: $(cat "$PID_FILE"))"
    log_info "Webhook server daemon started"
}

stop_daemon() {
    if ! is_running; then
        echo "Webhook server not running"
        return 0
    fi

    local pid
    pid=$(cat "$PID_FILE")

    log_info "Stopping webhook server (PID: $pid)..."
    kill -TERM "$pid" 2>/dev/null || true

    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
    fi

    rm -f "$PID_FILE"
    echo "Webhook server stopped"
    log_info "Webhook server stopped"
}

show_status() {
    echo "Webhook Server Status"
    echo "====================="
    echo ""

    if is_running; then
        echo "Status: Running (PID: $(cat "$PID_FILE"))"
    else
        echo "Status: Stopped"
    fi

    echo "Port: $PORT"
    echo "Secret: ${WEBHOOK_SECRET:+configured}"
    echo ""
    echo "Recent webhooks:"
    db_query "SELECT received_at, source, event_type, processed FROM webhooks ORDER BY received_at DESC LIMIT 5" | \
        jq -r '.[] | "  \(.received_at) \(.source) \(.event_type) (processed: \(.processed))"'
}

# ============================================================
# Main
# ============================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  start       Start webhook server
  stop        Stop webhook server
  status      Show status

Options:
  --port PORT       Server port (default: 8080)
  --data-dir DIR    Data directory

Environment:
  GITHUB_WEBHOOK_SECRET    Webhook secret for signature verification
  WEBHOOK_PORT             Server port
EOF
    exit 0
}

main() {
    local command="${1:-}"
    shift || true

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port|-p)
                WEBHOOK_PORT="$2"
                shift 2
                ;;
            --data-dir)
                export CT_DATA_DIR="$2"
                shift 2
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
