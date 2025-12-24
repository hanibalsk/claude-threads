#!/usr/bin/env python3
"""
debug-server.py - Debug web server for claude-threads

Serves a web dashboard showing:
- Active threads and their states
- Thread logs
- Blackboard events
- Orchestrator status

Usage:
    python3 scripts/debug-server.py [port]

Default port: 31339
"""

import http.server
import json
import os
import re
import sqlite3
import subprocess
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from datetime import datetime

# Configuration
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 31339

# Find data directory
def find_data_dir():
    """Find claude-threads data directory"""
    # Check environment
    if os.environ.get('CT_DATA_DIR'):
        return Path(os.environ['CT_DATA_DIR'])

    # Check current directory
    local = Path('.claude-threads')
    if local.exists():
        return local

    # Check home directory
    home = Path.home() / '.claude-threads'
    if home.exists():
        return home

    return local

DATA_DIR = find_data_dir()
DB_PATH = DATA_DIR / 'threads.db'

def get_db():
    """Get database connection"""
    if not DB_PATH.exists():
        return None
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    return conn

def query_db(sql, params=()):
    """Execute query and return results as list of dicts"""
    conn = get_db()
    if not conn:
        return []
    try:
        cursor = conn.execute(sql, params)
        rows = cursor.fetchall()
        return [dict(row) for row in rows]
    except Exception as e:
        print(f"DB error: {e}")
        return []
    finally:
        conn.close()

def scalar_db(sql, params=()):
    """Execute query and return single value"""
    conn = get_db()
    if not conn:
        return 0
    try:
        cursor = conn.execute(sql, params)
        row = cursor.fetchone()
        return row[0] if row else 0
    except Exception as e:
        print(f"DB error: {e}")
        return 0
    finally:
        conn.close()

def is_pid_running(pid_file):
    """Check if process from PID file is running"""
    try:
        with open(pid_file) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
        return True
    except:
        return False

def read_log_file(path, lines=100):
    """Read last N lines of log file"""
    try:
        with open(path, 'r') as f:
            all_lines = f.readlines()
            return ''.join(all_lines[-lines:])
    except:
        return ''

# Dashboard HTML
DASHBOARD_HTML = '''<!DOCTYPE html>
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
        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.5; }
        }
        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(450px, 1fr));
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
        .badge-sleeping { background: #8b5cf6; color: #fff; }
        .badge-blocked { background: #f97316; color: #fff; }
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
        .thread-row { cursor: pointer; transition: background 0.2s; }
        .thread-row:hover { background: var(--bg-card); }
        .thread-row.selected { background: var(--bg-card); border-left: 3px solid var(--accent); }
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
        .full-width { grid-column: 1 / -1; }
        .event-type { color: var(--info); }
        .event-source { color: var(--text-secondary); font-size: 0.7rem; }
        .scrollable { max-height: 300px; overflow-y: auto; }
        pre {
            background: var(--bg-card);
            padding: 8px;
            border-radius: 4px;
            font-size: 0.7rem;
            overflow-x: auto;
            white-space: pre-wrap;
        }
        .detail-table th { width: 100px; color: var(--text-secondary); }
        .detail-table td { color: var(--text-primary); word-break: break-all; }
        .worktree-path { font-size: 0.65rem; color: var(--text-secondary); max-width: 200px; overflow: hidden; text-overflow: ellipsis; }
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
                    Auto-refresh: <span id="refresh-countdown">3</span>s
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
                        <button class="btn" onclick="refreshThreads()">⟳ Refresh</button>
                    </div>
                </div>
                <div class="scrollable">
                    <table>
                        <thead>
                            <tr>
                                <th>Name</th>
                                <th>Mode</th>
                                <th>Status</th>
                                <th>Updated</th>
                            </tr>
                        </thead>
                        <tbody id="threads-table"></tbody>
                    </table>
                </div>
            </div>

            <div class="card">
                <div class="card-header">
                    <span class="card-title">Thread Detail</span>
                </div>
                <div id="thread-detail">
                    <p style="color: var(--text-secondary)">Click a thread to view details</p>
                </div>
            </div>

            <div class="card">
                <div class="card-header">
                    <span class="card-title">Worktrees</span>
                    <div class="card-actions">
                        <button class="btn" onclick="refreshWorktrees()">⟳ Refresh</button>
                    </div>
                </div>
                <div class="scrollable">
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
            </div>

            <div class="card">
                <div class="card-header">
                    <span class="card-title">Recent Events</span>
                    <div class="card-actions">
                        <button class="btn" onclick="refreshEvents()">⟳ Refresh</button>
                    </div>
                </div>
                <div class="scrollable">
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
            </div>

            <div class="card full-width">
                <div class="card-header">
                    <span class="card-title">Logs</span>
                    <div class="card-actions">
                        <button class="btn active" id="log-orch-btn" onclick="showLog('orchestrator')">Orchestrator</button>
                        <button class="btn" id="log-thread-btn" onclick="showLog('thread')">Thread</button>
                        <button class="btn" onclick="refreshLogs()">⟳ Refresh</button>
                    </div>
                </div>
                <div class="log-viewer" id="log-viewer">Loading logs...</div>
            </div>
        </div>
    </div>

    <script>
        let currentLogType = 'orchestrator';
        let selectedThreadId = null;
        let refreshInterval = null;
        let countdown = 3;

        async function fetchAPI(endpoint) {
            try {
                const res = await fetch(endpoint);
                return await res.json();
            } catch (e) {
                console.error('API error:', e);
                return null;
            }
        }

        function formatTimeAgo(timestamp) {
            if (!timestamp) return '-';
            const now = new Date();
            const then = new Date(timestamp.replace(' ', 'T') + 'Z');
            const diff = Math.floor((now - then) / 1000);
            if (diff < 0) return 'just now';
            if (diff < 60) return diff + 's ago';
            if (diff < 3600) return Math.floor(diff / 60) + 'm ago';
            if (diff < 86400) return Math.floor(diff / 3600) + 'h ago';
            return Math.floor(diff / 86400) + 'd ago';
        }

        function formatTime(timestamp) {
            if (!timestamp) return '-';
            try {
                const d = new Date(timestamp.replace(' ', 'T') + 'Z');
                return d.toLocaleTimeString();
            } catch { return timestamp; }
        }

        function statusBadge(status) {
            const s = status || 'created';
            return `<span class="badge badge-${s}">${s}</span>`;
        }

        function escapeHtml(str) {
            if (!str) return '';
            const div = document.createElement('div');
            div.textContent = str;
            return div.innerHTML;
        }

        function colorizeLog(content) {
            if (!content) return '<span style="color:var(--text-secondary)">No logs available</span>';
            return content.split('\\n').map(line => {
                let cls = '';
                if (line.includes('INFO')) cls = 'log-info';
                else if (line.includes('WARN')) cls = 'log-warn';
                else if (line.includes('ERROR')) cls = 'log-error';
                else if (line.includes('DEBUG') || line.includes('TRACE')) cls = 'log-debug';
                return `<div class="log-line ${cls}">${escapeHtml(line)}</div>`;
            }).join('');
        }

        async function refreshStatus() {
            const data = await fetchAPI('/api/status');
            if (!data) return;
            document.getElementById('stat-total').textContent = data.threads?.total ?? '-';
            document.getElementById('stat-running').textContent = data.threads?.running ?? '-';
            document.getElementById('stat-ready').textContent = data.threads?.ready ?? '-';
            document.getElementById('stat-events').textContent = data.events_pending ?? '-';
            document.getElementById('orch-status').className = 'status-dot' + (data.orchestrator_running ? ' active' : '');
            document.getElementById('api-status').className = 'status-dot' + (data.api_running ? ' active' : '');
        }

        async function refreshThreads() {
            const data = await fetchAPI('/api/threads');
            if (!data) return;
            const tbody = document.getElementById('threads-table');
            tbody.innerHTML = data.map(t => `
                <tr class="thread-row ${t.id === selectedThreadId ? 'selected' : ''}" onclick="selectThread('${t.id}')">
                    <td title="${t.id}">${escapeHtml(t.name || t.id.slice(0, 20))}</td>
                    <td>${t.mode || '-'}</td>
                    <td>${statusBadge(t.status)}</td>
                    <td>${formatTimeAgo(t.updated_at)}</td>
                </tr>
            `).join('') || '<tr><td colspan="4" style="color:var(--text-secondary)">No threads</td></tr>';
        }

        async function refreshWorktrees() {
            const data = await fetchAPI('/api/worktrees');
            if (!data) return;
            const tbody = document.getElementById('worktrees-table');
            tbody.innerHTML = data.map(w => `
                <tr>
                    <td>${escapeHtml(w.thread_name || w.thread_id?.slice(0, 12) || '-')}</td>
                    <td title="${w.path || ''}">${escapeHtml(w.branch || '-')}</td>
                    <td>${statusBadge(w.status || w.thread_status || 'active')}</td>
                </tr>
            `).join('') || '<tr><td colspan="3" style="color:var(--text-secondary)">No worktrees</td></tr>';
        }

        async function refreshEvents() {
            const data = await fetchAPI('/api/events?limit=30');
            if (!data) return;
            const tbody = document.getElementById('events-table');
            tbody.innerHTML = data.map(e => `
                <tr>
                    <td class="event-type">${escapeHtml(e.type || '-')}</td>
                    <td class="event-source">${escapeHtml(e.source || '-')}</td>
                    <td>${formatTime(e.timestamp)}</td>
                </tr>
            `).join('') || '<tr><td colspan="3" style="color:var(--text-secondary)">No events</td></tr>';
        }

        async function selectThread(threadId) {
            selectedThreadId = threadId;
            document.querySelectorAll('.thread-row').forEach(r => r.classList.remove('selected'));
            event.currentTarget?.classList.add('selected');

            const data = await fetchAPI('/api/thread/' + threadId);
            if (!data || data.error) {
                document.getElementById('thread-detail').innerHTML = '<p style="color:var(--accent)">Thread not found</p>';
                return;
            }

            let ctx = '{}';
            try { ctx = JSON.stringify(JSON.parse(data.context || '{}'), null, 2); }
            catch { ctx = data.context || '{}'; }

            document.getElementById('thread-detail').innerHTML = `
                <table class="detail-table">
                    <tr><th>ID</th><td style="font-size:0.7rem">${escapeHtml(data.id)}</td></tr>
                    <tr><th>Name</th><td>${escapeHtml(data.name)}</td></tr>
                    <tr><th>Mode</th><td>${data.mode}</td></tr>
                    <tr><th>Status</th><td>${statusBadge(data.status)}</td></tr>
                    <tr><th>Phase</th><td>${data.phase || '-'}</td></tr>
                    <tr><th>Session</th><td style="font-size:0.65rem">${data.session_id || '-'}</td></tr>
                    <tr><th>Worktree</th><td class="worktree-path" title="${data.worktree || ''}">${data.worktree || '-'}</td></tr>
                    <tr><th>Created</th><td>${data.created_at}</td></tr>
                    <tr><th>Updated</th><td>${data.updated_at}</td></tr>
                </table>
                <details style="margin-top:12px">
                    <summary style="cursor:pointer;color:var(--accent)">Context JSON</summary>
                    <pre style="margin-top:8px">${escapeHtml(ctx)}</pre>
                </details>
                <button class="btn" style="margin-top:12px" onclick="showLog('thread')">View Thread Logs</button>
            `;
        }

        async function refreshLogs() {
            const viewer = document.getElementById('log-viewer');
            let data;
            if (currentLogType === 'orchestrator') {
                data = await fetchAPI('/api/logs?lines=200');
            } else if (selectedThreadId) {
                data = await fetchAPI('/api/thread/' + selectedThreadId + '/logs?lines=100');
            } else {
                viewer.innerHTML = '<span style="color:var(--text-secondary)">Select a thread to view its logs</span>';
                return;
            }
            if (!data) { viewer.innerHTML = 'Failed to load logs'; return; }
            viewer.innerHTML = colorizeLog(data.content);
            viewer.scrollTop = viewer.scrollHeight;
        }

        function showLog(type) {
            currentLogType = type;
            document.getElementById('log-orch-btn').classList.toggle('active', type === 'orchestrator');
            document.getElementById('log-thread-btn').classList.toggle('active', type === 'thread');
            refreshLogs();
        }

        async function refreshAll() {
            await Promise.all([refreshStatus(), refreshThreads(), refreshWorktrees(), refreshEvents()]);
        }

        function startAutoRefresh() {
            countdown = 3;
            document.getElementById('refresh-countdown').textContent = countdown;
            if (refreshInterval) clearInterval(refreshInterval);
            refreshInterval = setInterval(() => {
                countdown--;
                document.getElementById('refresh-countdown').textContent = countdown;
                if (countdown <= 0) {
                    countdown = 3;
                    refreshAll();
                    if (currentLogType === 'orchestrator') refreshLogs();
                }
            }, 1000);
        }

        refreshAll();
        refreshLogs();
        startAutoRefresh();
    </script>
</body>
</html>
'''

class DebugHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress logging

    def send_json(self, data):
        body = json.dumps(data, default=str).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(body))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)

    def send_html(self, content):
        body = content.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', len(body))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        if path == '/' or path == '/index.html':
            self.send_html(DASHBOARD_HTML)

        elif path == '/api/status':
            self.send_json(self.api_status())

        elif path == '/api/threads':
            self.send_json(self.api_threads())

        elif path.startswith('/api/thread/') and path.endswith('/logs'):
            thread_id = path.replace('/api/thread/', '').replace('/logs', '')
            lines = int(query.get('lines', [50])[0])
            self.send_json(self.api_thread_logs(thread_id, lines))

        elif path.startswith('/api/thread/'):
            thread_id = path.replace('/api/thread/', '')
            self.send_json(self.api_thread_detail(thread_id))

        elif path == '/api/events':
            limit = int(query.get('limit', [50])[0])
            self.send_json(self.api_events(limit))

        elif path == '/api/worktrees':
            self.send_json(self.api_worktrees())

        elif path == '/api/logs':
            lines = int(query.get('lines', [100])[0])
            self.send_json(self.api_logs(lines))

        else:
            self.send_error(404)

    def api_status(self):
        return {
            'threads': {
                'total': scalar_db("SELECT COUNT(*) FROM threads"),
                'running': scalar_db("SELECT COUNT(*) FROM threads WHERE status = 'running'"),
                'ready': scalar_db("SELECT COUNT(*) FROM threads WHERE status = 'ready'"),
            },
            'events_pending': scalar_db("SELECT COUNT(*) FROM events WHERE processed = 0"),
            'orchestrator_running': is_pid_running(DATA_DIR / 'orchestrator.pid'),
            'api_running': is_pid_running(DATA_DIR / 'api-server.pid'),
            'timestamp': datetime.utcnow().isoformat() + 'Z'
        }

    def api_threads(self):
        return query_db("""
            SELECT id, name, mode, status, phase, template, session_id, worktree,
                   context, created_at, updated_at
            FROM threads ORDER BY updated_at DESC LIMIT 100
        """)

    def api_thread_detail(self, thread_id):
        rows = query_db("SELECT * FROM threads WHERE id = ?", (thread_id,))
        return rows[0] if rows else {'error': 'Thread not found'}

    def api_thread_logs(self, thread_id, lines=50):
        log_file = DATA_DIR / 'logs' / f'thread-{thread_id}.log'
        content = read_log_file(log_file, min(lines, 500))
        return {
            'thread_id': thread_id,
            'lines': lines,
            'content': content
        }

    def api_events(self, limit=50):
        return query_db("""
            SELECT id, type, source, target, data, processed, timestamp
            FROM events ORDER BY timestamp DESC LIMIT ?
        """, (min(limit, 500),))

    def api_worktrees(self):
        return query_db("""
            SELECT w.id, w.thread_id, w.path, w.branch, w.base_branch, w.status,
                   t.name as thread_name, t.status as thread_status
            FROM worktrees w
            LEFT JOIN threads t ON w.thread_id = t.id
            ORDER BY w.created_at DESC
        """)

    def api_logs(self, lines=100):
        log_file = DATA_DIR / 'logs' / 'orchestrator.log'
        content = read_log_file(log_file, min(lines, 1000))
        return {
            'file': 'orchestrator.log',
            'lines': lines,
            'content': content
        }

def main():
    print(f"🧵 claude-threads Debug Dashboard")
    print(f"   Data dir: {DATA_DIR}")
    print(f"   Database: {DB_PATH}")
    print(f"")
    print(f"   Starting server on port {PORT}...")
    print(f"   Open http://localhost:{PORT} in your browser")
    print(f"")
    print(f"   Press Ctrl+C to stop")

    server = http.server.HTTPServer(('', PORT), DebugHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()

if __name__ == '__main__':
    main()
