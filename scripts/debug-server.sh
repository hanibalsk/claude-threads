#!/usr/bin/env bash
#
# debug-server.sh - Debug web server for claude-threads
#
# Serves a web dashboard showing:
# - Active threads and their states
# - Thread logs
# - Blackboard events
# - Orchestrator status
#
# Usage:
#   ./scripts/debug-server.sh [port]
#
# Default port: 31339
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

# Configuration
PORT="${1:-31339}"
DATA_DIR="${CT_DATA_DIR:-$(ct_data_dir)}"
PID_FILE="$DATA_DIR/debug-server.pid"
PORT_ALLOCATION=""
ALLOCATED_PORT=""
HEARTBEAT_PID=""

# Initialize
config_load "$DATA_DIR/config.yaml" 2>/dev/null || true
db_init "$DATA_DIR" 2>/dev/null || true
PORT_ALLOCATION="${CT_PORT_ALLOCATION:-$(config_get 'ports.allocation' 'auto')}"

# ============================================================
# HTTP Response Helpers
# ============================================================

send_response() {
    local status="$1"
    local content_type="$2"
    local body="$3"
    local length=${#body}

    printf "HTTP/1.1 %s\r\n" "$status"
    printf "Content-Type: %s\r\n" "$content_type"
    printf "Content-Length: %d\r\n" "$length"
    printf "Access-Control-Allow-Origin: *\r\n"
    printf "Connection: close\r\n"
    printf "\r\n"
    printf "%s" "$body"
}

send_json() {
    local body="$1"
    send_response "200 OK" "application/json" "$body"
}

send_html() {
    local body="$1"
    send_response "200 OK" "text/html; charset=utf-8" "$body"
}

send_404() {
    send_response "404 Not Found" "application/json" '{"error": "Not found"}'
}

# ============================================================
# API Handlers
# ============================================================

api_status() {
    local threads_total threads_running threads_ready events_pending
    local orchestrator_running="false"
    local api_running="false"

    threads_total=$(db_scalar "SELECT COUNT(*) FROM threads" 2>/dev/null || echo "0")
    threads_running=$(db_scalar "SELECT COUNT(*) FROM threads WHERE status = 'running'" 2>/dev/null || echo "0")
    threads_ready=$(db_scalar "SELECT COUNT(*) FROM threads WHERE status = 'ready'" 2>/dev/null || echo "0")
    events_pending=$(db_scalar "SELECT COUNT(*) FROM events WHERE processed = 0" 2>/dev/null || echo "0")

    if ct_is_pid_running "$DATA_DIR/orchestrator.pid"; then
        orchestrator_running="true"
    fi

    if ct_is_pid_running "$DATA_DIR/api-server.pid"; then
        api_running="true"
    fi

    jq -n \
        --arg total "$threads_total" \
        --arg running "$threads_running" \
        --arg ready "$threads_ready" \
        --arg events "$events_pending" \
        --arg orch "$orchestrator_running" \
        --arg api "$api_running" \
        '{
            threads: {
                total: ($total | tonumber),
                running: ($running | tonumber),
                ready: ($ready | tonumber)
            },
            events_pending: ($events | tonumber),
            orchestrator_running: ($orch == "true"),
            api_running: ($api == "true"),
            timestamp: now | todate
        }'
}

api_threads() {
    db_query "SELECT id, name, mode, status, phase, template, session_id, worktree,
              context, created_at, updated_at
              FROM threads ORDER BY updated_at DESC LIMIT 100"
}

api_thread_detail() {
    local thread_id="$1"
    if ! ct_validate_thread_id "$thread_id"; then
        echo '{"error": "Invalid thread ID"}'
        return
    fi
    db_query "SELECT * FROM threads WHERE id = $(db_quote "$thread_id")" | jq '.[0] // {}'
}

api_events() {
    local limit="${1:-50}"
    limit=$(ct_sanitize_int "$limit" 50 1 500)
    db_query "SELECT id, type, source, target, data, processed, timestamp
              FROM events ORDER BY timestamp DESC LIMIT $limit"
}

api_worktrees() {
    db_query "SELECT w.id, w.thread_id, w.path, w.branch, w.base_branch, w.status,
              t.name as thread_name, t.status as thread_status
              FROM worktrees w
              LEFT JOIN threads t ON w.thread_id = t.id
              ORDER BY w.created_at DESC"
}

api_logs() {
    local log_file="$DATA_DIR/logs/orchestrator.log"
    local lines="${1:-100}"
    lines=$(ct_sanitize_int "$lines" 100 10 1000)

    if [[ -f "$log_file" ]]; then
        local content
        content=$(tail -n "$lines" "$log_file" 2>/dev/null | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
        echo "{\"file\": \"orchestrator.log\", \"lines\": $lines, \"content\": \"$content\"}"
    else
        echo '{"file": "orchestrator.log", "lines": 0, "content": "", "error": "Log file not found"}'
    fi
}

api_thread_logs() {
    local thread_id="$1"
    local lines="${2:-50}"

    if ! ct_validate_thread_id "$thread_id"; then
        echo '{"error": "Invalid thread ID"}'
        return
    fi

    lines=$(ct_sanitize_int "$lines" 50 10 500)
    local log_file="$DATA_DIR/logs/thread-${thread_id}.log"

    if [[ -f "$log_file" ]]; then
        local content
        content=$(tail -n "$lines" "$log_file" 2>/dev/null | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
        echo "{\"thread_id\": \"$thread_id\", \"lines\": $lines, \"content\": \"$content\"}"
    else
        echo "{\"thread_id\": \"$thread_id\", \"lines\": 0, \"content\": \"\", \"error\": \"Log file not found\"}"
    fi
}

# ============================================================
# Dashboard HTML
# ============================================================

serve_dashboard() {
    cat << 'DASHBOARD_HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>claude-threads Debug Dashboard</title>
    <style>
        :root {
            --bg-primary: #1a1a2e;
            --bg-secondary: #16213e;
            --bg-card: #0f3460;
            --text-primary: #eee;
            --text-secondary: #aaa;
            --accent: #e94560;
            --success: #4ade80;
            --warning: #fbbf24;
            --info: #60a5fa;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'SF Mono', 'Monaco', 'Inconsolata', 'Roboto Mono', monospace;
            background: var(--bg-primary);
            color: var(--text-primary);
            min-height: 100vh;
            padding: 20px;
        }
        .container { max-width: 1600px; margin: 0 auto; }
        header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 20px;
            padding-bottom: 20px;
            border-bottom: 1px solid var(--bg-card);
        }
        h1 { font-size: 1.5rem; color: var(--accent); }
        .status-bar {
            display: flex;
            gap: 20px;
            font-size: 0.85rem;
        }
        .status-item {
            display: flex;
            align-items: center;
            gap: 8px;
        }
        .status-dot {
            width: 10px;
            height: 10px;
            border-radius: 50%;
            background: var(--text-secondary);
        }
        .status-dot.active { background: var(--success); animation: pulse 2s infinite; }
        .status-dot.warning { background: var(--warning); }
        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.5; }
        }
        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(400px, 1fr));
            gap: 20px;
        }
        .card {
            background: var(--bg-secondary);
            border-radius: 8px;
            padding: 16px;
            border: 1px solid var(--bg-card);
        }
        .card-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 12px;
            padding-bottom: 12px;
            border-bottom: 1px solid var(--bg-card);
        }
        .card-title { font-size: 1rem; color: var(--accent); }
        .card-actions { display: flex; gap: 8px; }
        .btn {
            background: var(--bg-card);
            border: none;
            color: var(--text-primary);
            padding: 6px 12px;
            border-radius: 4px;
            cursor: pointer;
            font-size: 0.75rem;
            font-family: inherit;
        }
        .btn:hover { background: var(--accent); }
        .btn.active { background: var(--accent); }
        table {
            width: 100%;
            border-collapse: collapse;
            font-size: 0.8rem;
        }
        th, td {
            text-align: left;
            padding: 8px;
            border-bottom: 1px solid var(--bg-card);
        }
        th { color: var(--text-secondary); font-weight: normal; }
        .badge {
            display: inline-block;
            padding: 2px 8px;
            border-radius: 4px;
            font-size: 0.7rem;
            font-weight: bold;
        }
        .badge-running { background: var(--success); color: #000; }
        .badge-ready { background: var(--info); color: #000; }
        .badge-waiting { background: var(--warning); color: #000; }
        .badge-completed { background: var(--text-secondary); color: #000; }
        .badge-failed { background: var(--accent); color: #fff; }
        .badge-created { background: var(--bg-card); color: var(--text-primary); }
        .log-viewer {
            background: #000;
            border-radius: 4px;
            padding: 12px;
            font-size: 0.75rem;
            max-height: 400px;
            overflow-y: auto;
            white-space: pre-wrap;
            word-break: break-all;
            line-height: 1.4;
        }
        .log-line { margin: 2px 0; }
        .log-info { color: #4ade80; }
        .log-warn { color: #fbbf24; }
        .log-error { color: #f87171; }
        .log-debug { color: #94a3b8; }
        .thread-row { cursor: pointer; }
        .thread-row:hover { background: var(--bg-card); }
        .thread-detail {
            display: none;
            padding: 12px;
            background: var(--bg-card);
            border-radius: 4px;
            margin-top: 8px;
        }
        .thread-detail.visible { display: block; }
        .stats {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 12px;
            margin-bottom: 20px;
        }
        .stat-card {
            background: var(--bg-card);
            border-radius: 8px;
            padding: 16px;
            text-align: center;
        }
        .stat-value {
            font-size: 2rem;
            font-weight: bold;
            color: var(--accent);
        }
        .stat-label {
            font-size: 0.75rem;
            color: var(--text-secondary);
            margin-top: 4px;
        }
        .refresh-indicator {
            font-size: 0.7rem;
            color: var(--text-secondary);
        }
        .context-preview {
            max-width: 200px;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
            color: var(--text-secondary);
            font-size: 0.75rem;
        }
        .full-width { grid-column: 1 / -1; }
        .event-type { color: var(--info); }
        .event-source { color: var(--text-secondary); }
        .tabs { display: flex; gap: 4px; margin-bottom: 12px; }
        .tab {
            padding: 8px 16px;
            background: var(--bg-card);
            border: none;
            color: var(--text-primary);
            cursor: pointer;
            border-radius: 4px 4px 0 0;
            font-family: inherit;
            font-size: 0.8rem;
        }
        .tab.active { background: var(--accent); }
        .tab-content { display: none; }
        .tab-content.active { display: block; }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>🧵 claude-threads Debug Dashboard</h1>
            <div class="status-bar">
                <div class="status-item">
                    <span class="status-dot" id="orch-status"></span>
                    <span>Orchestrator</span>
                </div>
                <div class="status-item">
                    <span class="status-dot" id="api-status"></span>
                    <span>API Server</span>
                </div>
                <div class="refresh-indicator">
                    Auto-refresh: <span id="refresh-countdown">5</span>s
                </div>
            </div>
        </header>

        <div class="stats">
            <div class="stat-card">
                <div class="stat-value" id="stat-total">-</div>
                <div class="stat-label">Total Threads</div>
            </div>
            <div class="stat-card">
                <div class="stat-value" id="stat-running">-</div>
                <div class="stat-label">Running</div>
            </div>
            <div class="stat-card">
                <div class="stat-value" id="stat-ready">-</div>
                <div class="stat-label">Ready</div>
            </div>
            <div class="stat-card">
                <div class="stat-value" id="stat-events">-</div>
                <div class="stat-label">Pending Events</div>
            </div>
        </div>

        <div class="grid">
            <div class="card">
                <div class="card-header">
                    <span class="card-title">Threads</span>
                    <div class="card-actions">
                        <button class="btn" onclick="refreshThreads()">Refresh</button>
                    </div>
                </div>
                <table>
                    <thead>
                        <tr>
                            <th>Name</th>
                            <th>Mode</th>
                            <th>Status</th>
                            <th>Phase</th>
                            <th>Updated</th>
                        </tr>
                    </thead>
                    <tbody id="threads-table"></tbody>
                </table>
            </div>

            <div class="card">
                <div class="card-header">
                    <span class="card-title">Worktrees</span>
                    <div class="card-actions">
                        <button class="btn" onclick="refreshWorktrees()">Refresh</button>
                    </div>
                </div>
                <table>
                    <thead>
                        <tr>
                            <th>Thread</th>
                            <th>Branch</th>
                            <th>Status</th>
                        </tr>
                    </thead>
                    <tbody id="worktrees-table"></tbody>
                </table>
            </div>

            <div class="card">
                <div class="card-header">
                    <span class="card-title">Recent Events</span>
                    <div class="card-actions">
                        <button class="btn" onclick="refreshEvents()">Refresh</button>
                    </div>
                </div>
                <table>
                    <thead>
                        <tr>
                            <th>Type</th>
                            <th>Source</th>
                            <th>Time</th>
                        </tr>
                    </thead>
                    <tbody id="events-table"></tbody>
                </table>
            </div>

            <div class="card">
                <div class="card-header">
                    <span class="card-title">Thread Detail</span>
                </div>
                <div id="thread-detail">
                    <p style="color: var(--text-secondary)">Click a thread to view details</p>
                </div>
            </div>

            <div class="card full-width">
                <div class="card-header">
                    <span class="card-title">Logs</span>
                    <div class="card-actions">
                        <button class="btn" id="log-orch-btn" onclick="showLog('orchestrator')">Orchestrator</button>
                        <button class="btn" id="log-thread-btn" onclick="showLog('thread')">Thread</button>
                        <button class="btn" onclick="refreshLogs()">Refresh</button>
                    </div>
                </div>
                <div class="log-viewer" id="log-viewer">
                    Select a log source above...
                </div>
            </div>
        </div>
    </div>

    <script>
        const API_BASE = window.location.origin;
        let currentLogType = 'orchestrator';
        let selectedThreadId = null;
        let refreshInterval = null;
        let countdown = 5;

        async function fetchAPI(endpoint) {
            try {
                const res = await fetch(API_BASE + endpoint);
                return await res.json();
            } catch (e) {
                console.error('API error:', e);
                return null;
            }
        }

        function formatTime(timestamp) {
            if (!timestamp) return '-';
            const d = new Date(timestamp);
            return d.toLocaleTimeString();
        }

        function formatTimeAgo(timestamp) {
            if (!timestamp) return '-';
            const now = new Date();
            const then = new Date(timestamp);
            const diff = Math.floor((now - then) / 1000);
            if (diff < 60) return diff + 's ago';
            if (diff < 3600) return Math.floor(diff / 60) + 'm ago';
            if (diff < 86400) return Math.floor(diff / 3600) + 'h ago';
            return Math.floor(diff / 86400) + 'd ago';
        }

        function statusBadge(status) {
            return `<span class="badge badge-${status || 'created'}">${status || 'unknown'}</span>`;
        }

        function colorizeLog(content) {
            if (!content) return '';
            return content
                .split('\\n')
                .map(line => {
                    let cls = '';
                    if (line.includes('INFO')) cls = 'log-info';
                    else if (line.includes('WARN')) cls = 'log-warn';
                    else if (line.includes('ERROR')) cls = 'log-error';
                    else if (line.includes('DEBUG')) cls = 'log-debug';
                    return `<div class="log-line ${cls}">${escapeHtml(line)}</div>`;
                })
                .join('');
        }

        function escapeHtml(str) {
            const div = document.createElement('div');
            div.textContent = str;
            return div.innerHTML;
        }

        async function refreshStatus() {
            const data = await fetchAPI('/api/status');
            if (!data) return;

            document.getElementById('stat-total').textContent = data.threads?.total ?? '-';
            document.getElementById('stat-running').textContent = data.threads?.running ?? '-';
            document.getElementById('stat-ready').textContent = data.threads?.ready ?? '-';
            document.getElementById('stat-events').textContent = data.events_pending ?? '-';

            const orchDot = document.getElementById('orch-status');
            const apiDot = document.getElementById('api-status');
            orchDot.className = 'status-dot' + (data.orchestrator_running ? ' active' : '');
            apiDot.className = 'status-dot' + (data.api_running ? ' active' : '');
        }

        async function refreshThreads() {
            const data = await fetchAPI('/api/threads');
            if (!data) return;

            const tbody = document.getElementById('threads-table');
            tbody.innerHTML = data.map(t => `
                <tr class="thread-row" onclick="selectThread('${t.id}')">
                    <td title="${t.id}">${escapeHtml(t.name || t.id.slice(0, 20))}</td>
                    <td>${t.mode || '-'}</td>
                    <td>${statusBadge(t.status)}</td>
                    <td>${t.phase || '-'}</td>
                    <td>${formatTimeAgo(t.updated_at)}</td>
                </tr>
            `).join('');
        }

        async function refreshWorktrees() {
            const data = await fetchAPI('/api/worktrees');
            if (!data) return;

            const tbody = document.getElementById('worktrees-table');
            tbody.innerHTML = data.map(w => `
                <tr>
                    <td title="${w.thread_id}">${escapeHtml(w.thread_name || w.thread_id?.slice(0, 15) || '-')}</td>
                    <td title="${w.path}">${escapeHtml(w.branch || '-')}</td>
                    <td>${statusBadge(w.status || w.thread_status)}</td>
                </tr>
            `).join('');
        }

        async function refreshEvents() {
            const data = await fetchAPI('/api/events?limit=20');
            if (!data) return;

            const tbody = document.getElementById('events-table');
            tbody.innerHTML = data.map(e => `
                <tr>
                    <td class="event-type">${escapeHtml(e.type || '-')}</td>
                    <td class="event-source">${escapeHtml(e.source || '-')}</td>
                    <td>${formatTime(e.timestamp)}</td>
                </tr>
            `).join('');
        }

        async function selectThread(threadId) {
            selectedThreadId = threadId;
            const data = await fetchAPI('/api/thread/' + threadId);
            if (!data || data.error) {
                document.getElementById('thread-detail').innerHTML = '<p style="color: var(--accent)">Thread not found</p>';
                return;
            }

            let contextPreview = '';
            try {
                const ctx = JSON.parse(data.context || '{}');
                contextPreview = JSON.stringify(ctx, null, 2);
            } catch (e) {
                contextPreview = data.context || '{}';
            }

            document.getElementById('thread-detail').innerHTML = `
                <table>
                    <tr><th>ID</th><td>${escapeHtml(data.id)}</td></tr>
                    <tr><th>Name</th><td>${escapeHtml(data.name)}</td></tr>
                    <tr><th>Mode</th><td>${data.mode}</td></tr>
                    <tr><th>Status</th><td>${statusBadge(data.status)}</td></tr>
                    <tr><th>Phase</th><td>${data.phase || '-'}</td></tr>
                    <tr><th>Session</th><td>${data.session_id || '-'}</td></tr>
                    <tr><th>Template</th><td>${data.template || '-'}</td></tr>
                    <tr><th>Worktree</th><td style="font-size:0.7rem">${data.worktree || '-'}</td></tr>
                    <tr><th>Created</th><td>${data.created_at}</td></tr>
                    <tr><th>Updated</th><td>${data.updated_at}</td></tr>
                </table>
                <details style="margin-top:12px">
                    <summary style="cursor:pointer;color:var(--accent)">Context</summary>
                    <pre style="margin-top:8px;font-size:0.7rem;color:var(--text-secondary)">${escapeHtml(contextPreview)}</pre>
                </details>
                <button class="btn" style="margin-top:12px" onclick="showLog('thread')">View Logs</button>
            `;
        }

        async function refreshLogs() {
            const viewer = document.getElementById('log-viewer');
            let data;

            if (currentLogType === 'orchestrator') {
                data = await fetchAPI('/api/logs?lines=200');
            } else if (currentLogType === 'thread' && selectedThreadId) {
                data = await fetchAPI('/api/thread/' + selectedThreadId + '/logs?lines=100');
            } else {
                viewer.innerHTML = 'Select a thread first to view its logs';
                return;
            }

            if (!data) {
                viewer.innerHTML = 'Failed to load logs';
                return;
            }

            viewer.innerHTML = colorizeLog(data.content) || '<span style="color:var(--text-secondary)">No logs available</span>';
            viewer.scrollTop = viewer.scrollHeight;
        }

        function showLog(type) {
            currentLogType = type;
            document.getElementById('log-orch-btn').classList.toggle('active', type === 'orchestrator');
            document.getElementById('log-thread-btn').classList.toggle('active', type === 'thread');
            refreshLogs();
        }

        async function refreshAll() {
            await Promise.all([
                refreshStatus(),
                refreshThreads(),
                refreshWorktrees(),
                refreshEvents()
            ]);
        }

        function startAutoRefresh() {
            countdown = 5;
            document.getElementById('refresh-countdown').textContent = countdown;

            if (refreshInterval) clearInterval(refreshInterval);

            refreshInterval = setInterval(() => {
                countdown--;
                document.getElementById('refresh-countdown').textContent = countdown;
                if (countdown <= 0) {
                    countdown = 5;
                    refreshAll();
                    refreshLogs();
                }
            }, 1000);
        }

        // Initial load
        refreshAll();
        showLog('orchestrator');
        startAutoRefresh();
    </script>
</body>
</html>
DASHBOARD_HTML
}

# ============================================================
# Request Handler
# ============================================================

handle_request() {
    local request_line
    read -r request_line || return

    # Parse request
    local method path
    method=$(echo "$request_line" | awk '{print $1}')
    path=$(echo "$request_line" | awk '{print $2}' | cut -d'?' -f1)
    local query=$(echo "$request_line" | awk '{print $2}' | cut -d'?' -f2)

    # Read headers (discard)
    while read -r header; do
        [[ -z "$header" || "$header" == $'\r' ]] && break
    done

    # Route request
    case "$path" in
        /|/index.html)
            serve_dashboard | send_html "$(cat)"
            ;;
        /api/status)
            send_json "$(api_status)"
            ;;
        /api/threads)
            send_json "$(api_threads)"
            ;;
        /api/thread/*)
            local thread_id="${path#/api/thread/}"
            thread_id="${thread_id%/logs}"
            if [[ "$path" == */logs ]]; then
                local lines=$(ct_query_param "$query" "lines" "50")
                send_json "$(api_thread_logs "$thread_id" "$lines")"
            else
                send_json "$(api_thread_detail "$thread_id")"
            fi
            ;;
        /api/events)
            local limit=$(ct_query_param "$query" "limit" "50")
            send_json "$(api_events "$limit")"
            ;;
        /api/worktrees)
            send_json "$(api_worktrees)"
            ;;
        /api/logs)
            local lines=$(ct_query_param "$query" "lines" "100")
            send_json "$(api_logs "$lines")"
            ;;
        *)
            send_404
            ;;
    esac
}

# ============================================================
# Server Control
# ============================================================

start_server() {
    if ct_is_pid_running "$PID_FILE"; then
        echo "Debug server already running (PID: $(cat "$PID_FILE"))"
        exit 1
    fi

    # Handle port allocation
    if [[ "$PORT" == "auto" || "$PORT_ALLOCATION" == "auto" ]]; then
        local project_root
        project_root="${CT_PROJECT_ROOT:-$(pwd)}"

        # Try to get port from existing instance
        local existing_port
        existing_port=$(registry_find_by_project "$project_root")
        if [[ -n "$existing_port" ]]; then
            # Add debug service to existing instance
            local debug_port=$((existing_port + 1))
            ALLOCATED_PORT="$debug_port"
            registry_add_service "$existing_port" "debug" "$debug_port" "$$"
            PORT="$debug_port"
        else
            # Allocate new port for debug service
            ALLOCATED_PORT=$(registry_allocate_port "$project_root" "debug")
            if [[ -z "$ALLOCATED_PORT" ]]; then
                echo "Error: Failed to allocate port from registry"
                exit 1
            fi
            PORT="$ALLOCATED_PORT"
        fi
        echo "Allocated port $PORT from registry"

        # Set up cleanup trap
        trap 'cleanup_registry' EXIT INT TERM
    fi

    echo "Starting debug server on port $PORT..."

    # Check if nc supports -l -p or just -l
    if nc -h 2>&1 | grep -q '\-p'; then
        NC_CMD="nc -l -p $PORT"
    else
        NC_CMD="nc -l $PORT"
    fi

    # Start server loop
    while true; do
        $NC_CMD < <(handle_request) 2>/dev/null || true
    done &

    local pid=$!
    echo "$pid" > "$PID_FILE"

    # Start heartbeat if using registry
    if [[ -n "$ALLOCATED_PORT" ]]; then
        HEARTBEAT_PID=$(registry_start_heartbeat "$ALLOCATED_PORT")
    fi

    echo "Debug server started (PID: $pid)"
    echo "Open http://localhost:$PORT in your browser"
}

# Cleanup registry on exit
cleanup_registry() {
    if [[ -n "$HEARTBEAT_PID" ]]; then
        registry_stop_heartbeat "$HEARTBEAT_PID"
    fi
    if [[ -n "$ALLOCATED_PORT" ]]; then
        # If we're attached to an existing instance, just remove our service
        local project_root="${CT_PROJECT_ROOT:-$(pwd)}"
        local instance_port
        instance_port=$(registry_find_by_project "$project_root")
        if [[ -n "$instance_port" && "$instance_port" != "$ALLOCATED_PORT" ]]; then
            registry_remove_service "$instance_port" "debug"
        else
            registry_release_port "$ALLOCATED_PORT"
        fi
    fi
}

stop_server() {
    if ! ct_is_pid_running "$PID_FILE"; then
        echo "Debug server not running"
        return 0
    fi

    local pid
    pid=$(cat "$PID_FILE")
    kill "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"

    # Cleanup registry
    cleanup_registry

    echo "Debug server stopped"
}

show_status() {
    if ct_is_pid_running "$PID_FILE"; then
        echo "Debug server running (PID: $(cat "$PID_FILE"))"
        echo "URL: http://localhost:$PORT"
    else
        echo "Debug server not running"
    fi
}

# ============================================================
# Main
# ============================================================

case "${1:-start}" in
    start)
        shift 2>/dev/null || true
        PORT="${1:-31339}"
        start_server
        ;;
    stop)
        stop_server
        ;;
    status)
        show_status
        ;;
    restart)
        stop_server
        sleep 1
        shift 2>/dev/null || true
        PORT="${1:-31339}"
        start_server
        ;;
    *)
        # If first arg is a number, treat as port
        if [[ "$1" =~ ^[0-9]+$ ]]; then
            PORT="$1"
            start_server
        else
            echo "Usage: $0 {start|stop|status|restart} [port]"
            echo "Default port: 31339"
            exit 1
        fi
        ;;
esac
