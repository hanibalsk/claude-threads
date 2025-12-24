-- claude-threads SQLite Schema
-- Version: 0.1.0
--
-- Enable WAL mode for concurrent reads
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

-- ============================================================
-- THREADS TABLE
-- Core table for thread state management
-- ============================================================
CREATE TABLE IF NOT EXISTS threads (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    mode TEXT NOT NULL CHECK(mode IN ('automatic', 'semi-auto', 'interactive', 'sleeping')),
    status TEXT NOT NULL DEFAULT 'created' CHECK(status IN ('created', 'ready', 'running', 'waiting', 'sleeping', 'blocked', 'completed', 'failed')),
    phase TEXT,
    template TEXT,
    workflow TEXT,
    session_id TEXT,
    worktree TEXT,                 -- Path to git worktree (if using worktree isolation)
    worktree_branch TEXT,           -- Branch name in worktree
    worktree_base TEXT,             -- Base branch (e.g., 'main')
    config JSON DEFAULT '{}',
    context JSON DEFAULT '{}',
    schedule JSON,
    error TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

-- ============================================================
-- EVENTS TABLE (Blackboard)
-- Append-only event stream for inter-thread communication
-- ============================================================
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT DEFAULT (datetime('now')),
    source TEXT,                    -- Thread ID that created the event
    type TEXT NOT NULL,             -- Event type (e.g., 'STORY_COMPLETED', 'PR_CREATED')
    data JSON DEFAULT '{}',         -- Event payload
    targets TEXT DEFAULT '*',       -- JSON array of target thread IDs or '*' for broadcast
    processed INTEGER DEFAULT 0,    -- Whether event has been processed
    processed_at TEXT,
    FOREIGN KEY (source) REFERENCES threads(id) ON DELETE SET NULL
);

-- ============================================================
-- MESSAGES TABLE
-- Direct inter-thread messaging
-- ============================================================
CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    from_thread TEXT,
    to_thread TEXT NOT NULL,
    type TEXT NOT NULL,             -- Message type
    content JSON DEFAULT '{}',      -- Message payload
    priority INTEGER DEFAULT 0,     -- Higher = more urgent
    created_at TEXT DEFAULT (datetime('now')),
    read_at TEXT,
    FOREIGN KEY (from_thread) REFERENCES threads(id) ON DELETE SET NULL,
    FOREIGN KEY (to_thread) REFERENCES threads(id) ON DELETE CASCADE
);

-- ============================================================
-- SESSIONS TABLE
-- Claude session tracking for resume capability
-- ============================================================
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,            -- Claude session ID
    thread_id TEXT,
    started_at TEXT DEFAULT (datetime('now')),
    last_activity TEXT DEFAULT (datetime('now')),
    turns INTEGER DEFAULT 0,
    tokens_used INTEGER DEFAULT 0,
    status TEXT DEFAULT 'active' CHECK(status IN ('active', 'paused', 'completed', 'expired')),
    FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE SET NULL
);

-- ============================================================
-- ARTIFACTS TABLE
-- Track shared artifacts between threads
-- ============================================================
CREATE TABLE IF NOT EXISTS artifacts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    thread_id TEXT,
    type TEXT NOT NULL,             -- 'file', 'code', 'data', etc.
    name TEXT NOT NULL,
    path TEXT,                      -- Relative path in artifacts directory
    content TEXT,                   -- For small inline artifacts
    metadata JSON DEFAULT '{}',
    created_at TEXT DEFAULT (datetime('now')),
    FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE SET NULL
);

-- ============================================================
-- WEBHOOKS TABLE
-- Track incoming webhooks from GitHub, n8n, etc.
-- ============================================================
CREATE TABLE IF NOT EXISTS webhooks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source TEXT NOT NULL,           -- 'github', 'n8n', etc.
    event_type TEXT NOT NULL,       -- e.g., 'pull_request', 'check_run'
    payload JSON NOT NULL,
    processed INTEGER DEFAULT 0,
    thread_id TEXT,                 -- Thread that processed this webhook
    received_at TEXT DEFAULT (datetime('now')),
    processed_at TEXT,
    FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE SET NULL
);

-- ============================================================
-- WORKTREES TABLE
-- Track git worktrees per thread
-- ============================================================
CREATE TABLE IF NOT EXISTS worktrees (
    id TEXT PRIMARY KEY,            -- Same as thread_id
    thread_id TEXT NOT NULL,
    path TEXT NOT NULL,             -- Full path to worktree directory
    branch TEXT NOT NULL,           -- Branch name in worktree
    base_branch TEXT NOT NULL,      -- Base branch (e.g., 'main')
    remote TEXT DEFAULT 'origin',   -- Git remote
    status TEXT DEFAULT 'active' CHECK(status IN ('active', 'cleanup_pending', 'deleted')),
    commits_ahead INTEGER DEFAULT 0,
    commits_behind INTEGER DEFAULT 0,
    is_dirty INTEGER DEFAULT 0,     -- Has uncommitted changes
    created_at TEXT DEFAULT (datetime('now')),
    deleted_at TEXT,
    FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE
);

-- ============================================================
-- INDEXES
-- ============================================================

-- Thread lookups
CREATE INDEX IF NOT EXISTS idx_threads_status ON threads(status);
CREATE INDEX IF NOT EXISTS idx_threads_mode ON threads(mode);
CREATE INDEX IF NOT EXISTS idx_threads_updated ON threads(updated_at);

-- Event queries
CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp);
CREATE INDEX IF NOT EXISTS idx_events_type ON events(type);
CREATE INDEX IF NOT EXISTS idx_events_source ON events(source);
CREATE INDEX IF NOT EXISTS idx_events_processed ON events(processed);

-- Message inbox
CREATE INDEX IF NOT EXISTS idx_messages_to ON messages(to_thread, read_at);
CREATE INDEX IF NOT EXISTS idx_messages_priority ON messages(to_thread, priority DESC, created_at);

-- Session lookups
CREATE INDEX IF NOT EXISTS idx_sessions_thread ON sessions(thread_id);
CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(status);

-- Artifact lookups
CREATE INDEX IF NOT EXISTS idx_artifacts_thread ON artifacts(thread_id);
CREATE INDEX IF NOT EXISTS idx_artifacts_type ON artifacts(type);

-- Webhook processing
CREATE INDEX IF NOT EXISTS idx_webhooks_processed ON webhooks(processed, received_at);
CREATE INDEX IF NOT EXISTS idx_webhooks_source ON webhooks(source, event_type);

-- Worktree lookups
CREATE INDEX IF NOT EXISTS idx_worktrees_thread ON worktrees(thread_id);
CREATE INDEX IF NOT EXISTS idx_worktrees_status ON worktrees(status);

-- ============================================================
-- TRIGGERS
-- ============================================================

-- Auto-update updated_at timestamp
CREATE TRIGGER IF NOT EXISTS threads_updated_at
AFTER UPDATE ON threads
BEGIN
    UPDATE threads SET updated_at = datetime('now') WHERE id = NEW.id;
END;

-- Auto-update session last_activity
CREATE TRIGGER IF NOT EXISTS sessions_activity
AFTER UPDATE OF turns, tokens_used ON sessions
BEGIN
    UPDATE sessions SET last_activity = datetime('now') WHERE id = NEW.id;
END;

-- ============================================================
-- VIEWS
-- ============================================================

-- Active threads view
CREATE VIEW IF NOT EXISTS v_active_threads AS
SELECT
    t.*,
    s.turns,
    s.tokens_used,
    s.last_activity as session_activity
FROM threads t
LEFT JOIN sessions s ON t.session_id = s.id
WHERE t.status IN ('ready', 'running', 'waiting');

-- Unprocessed events view
CREATE VIEW IF NOT EXISTS v_pending_events AS
SELECT * FROM events
WHERE processed = 0
ORDER BY timestamp ASC;

-- Thread inbox view
CREATE VIEW IF NOT EXISTS v_inbox AS
SELECT
    m.*,
    t.name as from_name
FROM messages m
LEFT JOIN threads t ON m.from_thread = t.id
WHERE m.read_at IS NULL
ORDER BY m.priority DESC, m.created_at ASC;

-- Active worktrees view
CREATE VIEW IF NOT EXISTS v_active_worktrees AS
SELECT
    w.*,
    t.name as thread_name,
    t.status as thread_status,
    t.mode as thread_mode
FROM worktrees w
JOIN threads t ON w.thread_id = t.id
WHERE w.status = 'active';
