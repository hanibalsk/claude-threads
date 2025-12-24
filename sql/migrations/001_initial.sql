-- Migration 001: Initial schema (v1.0.0)
-- This migration creates the base tables for claude-threads

-- ============================================================
-- THREADS TABLE
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
    config JSON DEFAULT '{}',
    context JSON DEFAULT '{}',
    schedule JSON,
    error TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

-- ============================================================
-- EVENTS TABLE (Blackboard)
-- ============================================================
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT DEFAULT (datetime('now')),
    source TEXT,
    type TEXT NOT NULL,
    data JSON DEFAULT '{}',
    targets TEXT DEFAULT '*',
    processed INTEGER DEFAULT 0,
    processed_at TEXT,
    FOREIGN KEY (source) REFERENCES threads(id) ON DELETE SET NULL
);

-- ============================================================
-- MESSAGES TABLE
-- ============================================================
CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    from_thread TEXT,
    to_thread TEXT NOT NULL,
    type TEXT NOT NULL,
    content JSON DEFAULT '{}',
    priority INTEGER DEFAULT 0,
    created_at TEXT DEFAULT (datetime('now')),
    read_at TEXT,
    FOREIGN KEY (from_thread) REFERENCES threads(id) ON DELETE SET NULL,
    FOREIGN KEY (to_thread) REFERENCES threads(id) ON DELETE CASCADE
);

-- ============================================================
-- SESSIONS TABLE
-- ============================================================
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
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
-- ============================================================
CREATE TABLE IF NOT EXISTS artifacts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    thread_id TEXT,
    type TEXT NOT NULL,
    name TEXT NOT NULL,
    path TEXT,
    content TEXT,
    metadata JSON DEFAULT '{}',
    created_at TEXT DEFAULT (datetime('now')),
    FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE SET NULL
);

-- ============================================================
-- WEBHOOKS TABLE
-- ============================================================
CREATE TABLE IF NOT EXISTS webhooks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source TEXT NOT NULL,
    event_type TEXT NOT NULL,
    payload JSON NOT NULL,
    processed INTEGER DEFAULT 0,
    thread_id TEXT,
    received_at TEXT DEFAULT (datetime('now')),
    processed_at TEXT,
    FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE SET NULL
);

-- ============================================================
-- INDEXES
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_threads_status ON threads(status);
CREATE INDEX IF NOT EXISTS idx_threads_mode ON threads(mode);
CREATE INDEX IF NOT EXISTS idx_threads_updated ON threads(updated_at);
CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp);
CREATE INDEX IF NOT EXISTS idx_events_type ON events(type);
CREATE INDEX IF NOT EXISTS idx_events_source ON events(source);
CREATE INDEX IF NOT EXISTS idx_events_processed ON events(processed);
CREATE INDEX IF NOT EXISTS idx_messages_to ON messages(to_thread, read_at);
CREATE INDEX IF NOT EXISTS idx_messages_priority ON messages(to_thread, priority DESC, created_at);
CREATE INDEX IF NOT EXISTS idx_sessions_thread ON sessions(thread_id);
CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(status);
CREATE INDEX IF NOT EXISTS idx_artifacts_thread ON artifacts(thread_id);
CREATE INDEX IF NOT EXISTS idx_artifacts_type ON artifacts(type);
CREATE INDEX IF NOT EXISTS idx_webhooks_processed ON webhooks(processed, received_at);
CREATE INDEX IF NOT EXISTS idx_webhooks_source ON webhooks(source, event_type);

-- ============================================================
-- TRIGGERS
-- ============================================================
CREATE TRIGGER IF NOT EXISTS threads_updated_at
AFTER UPDATE ON threads
BEGIN
    UPDATE threads SET updated_at = datetime('now') WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS sessions_activity
AFTER UPDATE OF turns, tokens_used ON sessions
BEGIN
    UPDATE sessions SET last_activity = datetime('now') WHERE id = NEW.id;
END;

-- ============================================================
-- VIEWS
-- ============================================================
CREATE VIEW IF NOT EXISTS v_active_threads AS
SELECT
    t.*,
    s.turns,
    s.tokens_used,
    s.last_activity as session_activity
FROM threads t
LEFT JOIN sessions s ON t.session_id = s.id
WHERE t.status IN ('ready', 'running', 'waiting');

CREATE VIEW IF NOT EXISTS v_pending_events AS
SELECT * FROM events
WHERE processed = 0
ORDER BY timestamp ASC;

CREATE VIEW IF NOT EXISTS v_inbox AS
SELECT
    m.*,
    t.name as from_name
FROM messages m
LEFT JOIN threads t ON m.from_thread = t.id
WHERE m.read_at IS NULL
ORDER BY m.priority DESC, m.created_at ASC;
