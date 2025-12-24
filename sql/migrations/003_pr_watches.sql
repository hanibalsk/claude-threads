-- Migration 003: Add PR Shepherd support (v1.1.0 - v1.2.0)
-- Adds PR watching and automatic fix support with worktree isolation

-- ============================================================
-- PR_WATCHES TABLE
-- Track watched PRs for automatic fixing
-- ============================================================
CREATE TABLE IF NOT EXISTS pr_watches (
    pr_number INTEGER PRIMARY KEY,
    repo TEXT NOT NULL,
    branch TEXT,
    base_branch TEXT DEFAULT 'main',
    worktree_path TEXT,
    state TEXT NOT NULL DEFAULT 'watching' CHECK(state IN (
        'watching', 'ci_pending', 'ci_passed', 'ci_failed',
        'fixing', 'review_pending', 'changes_requested',
        'approved', 'merged', 'closed', 'blocked'
    )),
    fix_attempts INTEGER DEFAULT 0,
    last_push_at TEXT,
    last_ci_check_at TEXT,
    last_fix_at TEXT,
    shepherd_thread_id TEXT,
    current_fix_thread_id TEXT,
    error TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now')),
    FOREIGN KEY (shepherd_thread_id) REFERENCES threads(id) ON DELETE SET NULL,
    FOREIGN KEY (current_fix_thread_id) REFERENCES threads(id) ON DELETE SET NULL
);

-- ============================================================
-- INDEXES
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_pr_watches_state ON pr_watches(state);
CREATE INDEX IF NOT EXISTS idx_pr_watches_repo ON pr_watches(repo);

-- ============================================================
-- TRIGGERS
-- ============================================================
CREATE TRIGGER IF NOT EXISTS pr_watches_updated_at
AFTER UPDATE ON pr_watches
BEGIN
    UPDATE pr_watches SET updated_at = datetime('now') WHERE pr_number = NEW.pr_number;
END;
