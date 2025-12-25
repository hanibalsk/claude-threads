-- Migration: 005_session_management.sql
-- Adds session persistence, context tracking, and memory management
-- Version: 1.7.0

-- Add session tracking columns to threads table
ALTER TABLE threads ADD COLUMN session_id TEXT;
ALTER TABLE threads ADD COLUMN last_checkpoint_at TEXT;
ALTER TABLE threads ADD COLUMN context_tokens INTEGER DEFAULT 0;
ALTER TABLE threads ADD COLUMN context_compactions INTEGER DEFAULT 0;

-- Create session history table for resume/fork support
CREATE TABLE IF NOT EXISTS session_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    thread_id TEXT NOT NULL,
    session_id TEXT NOT NULL,
    parent_session_id TEXT,          -- For forked sessions
    started_at TEXT DEFAULT (datetime('now')),
    ended_at TEXT,
    status TEXT DEFAULT 'active' CHECK(status IN ('active', 'completed', 'forked', 'expired')),
    context_tokens_start INTEGER DEFAULT 0,
    context_tokens_end INTEGER,
    compactions_count INTEGER DEFAULT 0,
    checkpoint_count INTEGER DEFAULT 0,
    FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE
);

-- Create coordination checkpoints table
CREATE TABLE IF NOT EXISTS checkpoints (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    thread_id TEXT NOT NULL,
    session_id TEXT,
    checkpoint_type TEXT NOT NULL CHECK(checkpoint_type IN (
        'periodic', 'before_compaction', 'manual', 'coordination', 'error_recovery'
    )),
    created_at TEXT DEFAULT (datetime('now')),
    state_summary TEXT,              -- Compressed state for quick resume
    key_decisions TEXT,              -- JSON array of important decisions
    pending_tasks TEXT,              -- JSON array of incomplete tasks
    context_snapshot TEXT,           -- Key context to preserve
    FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE
);

-- Create memory entries table for cross-session persistence
CREATE TABLE IF NOT EXISTS memory_entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    thread_id TEXT,                  -- NULL for global memories
    category TEXT NOT NULL CHECK(category IN (
        'project', 'decision', 'error', 'pattern', 'preference', 'context'
    )),
    key TEXT NOT NULL,
    value TEXT NOT NULL,
    importance INTEGER DEFAULT 5 CHECK(importance BETWEEN 1 AND 10),
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now')),
    expires_at TEXT,                 -- Optional expiration
    access_count INTEGER DEFAULT 0,
    last_accessed_at TEXT,
    UNIQUE(thread_id, category, key)
);

-- Create context management settings per thread
CREATE TABLE IF NOT EXISTS context_settings (
    thread_id TEXT PRIMARY KEY,
    compaction_threshold INTEGER DEFAULT 50000,
    keep_recent_tool_uses INTEGER DEFAULT 5,
    excluded_tools TEXT DEFAULT '["Task"]',  -- JSON array
    memory_enabled INTEGER DEFAULT 1,
    checkpoint_interval_minutes INTEGER DEFAULT 30,
    auto_resume_enabled INTEGER DEFAULT 1,
    FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE
);

-- Add session coordination table for multi-agent sync
CREATE TABLE IF NOT EXISTS session_coordination (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    orchestrator_session_id TEXT NOT NULL,
    agent_thread_id TEXT NOT NULL,
    agent_session_id TEXT,
    coordination_state TEXT DEFAULT 'active' CHECK(coordination_state IN (
        'active', 'paused', 'checkpoint_pending', 'resuming', 'completed'
    )),
    last_sync_at TEXT DEFAULT (datetime('now')),
    next_checkpoint_at TEXT,
    shared_context TEXT,             -- JSON context shared with orchestrator
    FOREIGN KEY (agent_thread_id) REFERENCES threads(id) ON DELETE CASCADE
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_session_history_thread ON session_history(thread_id);
CREATE INDEX IF NOT EXISTS idx_session_history_session ON session_history(session_id);
CREATE INDEX IF NOT EXISTS idx_checkpoints_thread ON checkpoints(thread_id);
CREATE INDEX IF NOT EXISTS idx_checkpoints_session ON checkpoints(session_id);
CREATE INDEX IF NOT EXISTS idx_memory_entries_thread ON memory_entries(thread_id);
CREATE INDEX IF NOT EXISTS idx_memory_entries_category ON memory_entries(category);
CREATE INDEX IF NOT EXISTS idx_memory_entries_key ON memory_entries(key);
CREATE INDEX IF NOT EXISTS idx_session_coordination_orchestrator ON session_coordination(orchestrator_session_id);

-- View for active sessions with context info
CREATE VIEW IF NOT EXISTS v_active_sessions AS
SELECT
    t.id AS thread_id,
    t.name AS thread_name,
    t.session_id,
    t.context_tokens,
    t.context_compactions,
    t.last_checkpoint_at,
    sh.started_at AS session_started,
    cs.compaction_threshold,
    cs.checkpoint_interval_minutes,
    (SELECT COUNT(*) FROM checkpoints c WHERE c.thread_id = t.id) AS checkpoint_count,
    (SELECT COUNT(*) FROM memory_entries m WHERE m.thread_id = t.id) AS memory_count
FROM threads t
LEFT JOIN session_history sh ON t.session_id = sh.session_id AND sh.status = 'active'
LEFT JOIN context_settings cs ON t.id = cs.thread_id
WHERE t.status IN ('running', 'ready', 'waiting');

-- View for memory summary per thread
CREATE VIEW IF NOT EXISTS v_memory_summary AS
SELECT
    thread_id,
    category,
    COUNT(*) AS entry_count,
    AVG(importance) AS avg_importance,
    MAX(updated_at) AS last_updated
FROM memory_entries
GROUP BY thread_id, category;
