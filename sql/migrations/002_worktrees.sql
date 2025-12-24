-- Migration 002: Add worktree support (v1.2.0)
-- Adds git worktree isolation for parallel thread development

-- ============================================================
-- ADD WORKTREE COLUMNS TO THREADS TABLE
-- ============================================================
ALTER TABLE threads ADD COLUMN worktree TEXT;
ALTER TABLE threads ADD COLUMN worktree_branch TEXT;
ALTER TABLE threads ADD COLUMN worktree_base TEXT;

-- ============================================================
-- WORKTREES TABLE
-- Track git worktrees per thread
-- ============================================================
CREATE TABLE IF NOT EXISTS worktrees (
    id TEXT PRIMARY KEY,
    thread_id TEXT NOT NULL,
    path TEXT NOT NULL,
    branch TEXT NOT NULL,
    base_branch TEXT NOT NULL,
    remote TEXT DEFAULT 'origin',
    status TEXT DEFAULT 'active' CHECK(status IN ('active', 'cleanup_pending', 'deleted')),
    commits_ahead INTEGER DEFAULT 0,
    commits_behind INTEGER DEFAULT 0,
    is_dirty INTEGER DEFAULT 0,
    created_at TEXT DEFAULT (datetime('now')),
    deleted_at TEXT,
    FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE
);

-- ============================================================
-- INDEXES
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_worktrees_thread ON worktrees(thread_id);
CREATE INDEX IF NOT EXISTS idx_worktrees_status ON worktrees(status);

-- ============================================================
-- VIEWS
-- ============================================================
CREATE VIEW IF NOT EXISTS v_active_worktrees AS
SELECT
    w.*,
    t.name as thread_name,
    t.status as thread_status,
    t.mode as thread_mode
FROM worktrees w
JOIN threads t ON w.thread_id = t.id
WHERE w.status = 'active';
