-- Migration 004: PR Lifecycle Management (v1.5.0 - v1.6.0)
-- Adds comment tracking, merge conflict tracking, and per-PR configuration

-- ============================================================
-- PR_COMMENTS TABLE
-- Track review comments and their resolution states
-- ============================================================
CREATE TABLE IF NOT EXISTS pr_comments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pr_number INTEGER NOT NULL,
    github_comment_id TEXT NOT NULL UNIQUE,
    thread_id TEXT,                    -- GitHub review thread ID (for resolving)
    path TEXT,                         -- File path
    line INTEGER,                      -- Line number
    body TEXT NOT NULL,
    author TEXT NOT NULL,
    state TEXT DEFAULT 'pending' CHECK(state IN (
        'pending',      -- Not yet handled
        'responded',    -- Reply posted but not resolved
        'resolved',     -- Thread marked as resolved
        'dismissed'     -- Dismissed/outdated
    )),
    response_text TEXT,                -- Our response text
    response_at TEXT,                  -- When we responded
    handler_thread_id TEXT,            -- Thread handling this comment
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now')),
    FOREIGN KEY (handler_thread_id) REFERENCES threads(id) ON DELETE SET NULL
);

-- ============================================================
-- MERGE_CONFLICTS TABLE
-- Track merge conflicts and resolution attempts
-- ============================================================
CREATE TABLE IF NOT EXISTS merge_conflicts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pr_number INTEGER NOT NULL,
    target_branch TEXT NOT NULL,
    conflicting_files TEXT NOT NULL,   -- JSON array of file paths
    conflict_type TEXT DEFAULT 'auto' CHECK(conflict_type IN (
        'auto',         -- Simple conflict, auto-resolvable
        'manual',       -- Requires manual intervention
        'complex'       -- Complex conflict, needs human review
    )),
    resolution_status TEXT DEFAULT 'detected' CHECK(resolution_status IN (
        'detected',     -- Conflict detected
        'resolving',    -- Resolution in progress
        'resolved',     -- Successfully resolved
        'failed',       -- Resolution failed
        'manual_required' -- Escalated to human
    )),
    resolution_thread_id TEXT,         -- Thread attempting resolution
    resolution_attempts INTEGER DEFAULT 0,
    detected_at TEXT DEFAULT (datetime('now')),
    resolved_at TEXT,
    resolution_notes TEXT,             -- Notes about resolution
    FOREIGN KEY (resolution_thread_id) REFERENCES threads(id) ON DELETE SET NULL
);

-- ============================================================
-- PR_CONFIG TABLE
-- Per-PR configuration overrides
-- ============================================================
CREATE TABLE IF NOT EXISTS pr_config (
    pr_number INTEGER PRIMARY KEY,
    auto_merge INTEGER DEFAULT 0,           -- 0 = notify only, 1 = auto-merge
    interactive_mode INTEGER DEFAULT 0,     -- 0 = autonomous, 1 = interactive
    max_conflict_retries INTEGER DEFAULT 3,
    max_comment_handlers INTEGER DEFAULT 5, -- Max parallel comment handlers
    poll_interval_seconds INTEGER DEFAULT 30,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

-- ============================================================
-- EXTEND PR_WATCHES TABLE
-- Add new columns for enhanced tracking
-- ============================================================

-- Comments tracking
ALTER TABLE pr_watches ADD COLUMN comments_pending INTEGER DEFAULT 0;
ALTER TABLE pr_watches ADD COLUMN comments_responded INTEGER DEFAULT 0;
ALTER TABLE pr_watches ADD COLUMN comments_resolved INTEGER DEFAULT 0;

-- Conflict tracking
ALTER TABLE pr_watches ADD COLUMN has_merge_conflict INTEGER DEFAULT 0;
ALTER TABLE pr_watches ADD COLUMN conflict_resolution_attempts INTEGER DEFAULT 0;

-- Configuration flags
ALTER TABLE pr_watches ADD COLUMN auto_merge_enabled INTEGER DEFAULT 0;
ALTER TABLE pr_watches ADD COLUMN interactive_mode INTEGER DEFAULT 0;
ALTER TABLE pr_watches ADD COLUMN poll_interval_seconds INTEGER DEFAULT 30;

-- Last poll tracking
ALTER TABLE pr_watches ADD COLUMN last_poll_at TEXT;

-- ============================================================
-- INDEXES
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_pr_comments_pr ON pr_comments(pr_number);
CREATE INDEX IF NOT EXISTS idx_pr_comments_state ON pr_comments(state);
CREATE INDEX IF NOT EXISTS idx_pr_comments_thread ON pr_comments(thread_id);
CREATE INDEX IF NOT EXISTS idx_merge_conflicts_pr ON merge_conflicts(pr_number);
CREATE INDEX IF NOT EXISTS idx_merge_conflicts_status ON merge_conflicts(resolution_status);

-- ============================================================
-- TRIGGERS
-- ============================================================
CREATE TRIGGER IF NOT EXISTS pr_comments_updated_at
AFTER UPDATE ON pr_comments
BEGIN
    UPDATE pr_comments SET updated_at = datetime('now') WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS pr_config_updated_at
AFTER UPDATE ON pr_config
BEGIN
    UPDATE pr_config SET updated_at = datetime('now') WHERE pr_number = NEW.pr_number;
END;

-- ============================================================
-- VIEWS
-- ============================================================

-- View for pending comments that need handling
CREATE VIEW IF NOT EXISTS v_pending_comments AS
SELECT
    pc.*,
    pw.repo,
    pw.branch,
    pw.worktree_path
FROM pr_comments pc
JOIN pr_watches pw ON pc.pr_number = pw.pr_number
WHERE pc.state IN ('pending', 'responded')
ORDER BY pc.created_at ASC;

-- View for active merge conflicts
CREATE VIEW IF NOT EXISTS v_active_conflicts AS
SELECT
    mc.*,
    pw.repo,
    pw.branch,
    pw.worktree_path
FROM merge_conflicts mc
JOIN pr_watches pw ON mc.pr_number = pw.pr_number
WHERE mc.resolution_status NOT IN ('resolved', 'manual_required')
ORDER BY mc.detected_at ASC;

-- View for PR lifecycle status
CREATE VIEW IF NOT EXISTS v_pr_lifecycle_status AS
SELECT
    pw.pr_number,
    pw.repo,
    pw.branch,
    pw.base_branch,
    pw.state,
    pw.worktree_path,
    pw.comments_pending,
    pw.comments_responded,
    pw.comments_resolved,
    pw.has_merge_conflict,
    pw.auto_merge_enabled,
    pw.interactive_mode,
    COALESCE(pc.auto_merge, pw.auto_merge_enabled) as effective_auto_merge,
    COALESCE(pc.interactive_mode, pw.interactive_mode) as effective_interactive,
    COALESCE(pc.poll_interval_seconds, pw.poll_interval_seconds, 30) as effective_poll_interval,
    CASE
        WHEN pw.state IN ('merged', 'closed') THEN 'terminal'
        WHEN pw.has_merge_conflict = 1 THEN 'blocked_conflict'
        WHEN pw.comments_pending > 0 THEN 'comments_pending'
        WHEN pw.comments_responded > pw.comments_resolved THEN 'comments_unresolved'
        WHEN pw.state = 'approved' THEN 'ready_to_merge'
        ELSE pw.state
    END as lifecycle_state
FROM pr_watches pw
LEFT JOIN pr_config pc ON pw.pr_number = pc.pr_number;
