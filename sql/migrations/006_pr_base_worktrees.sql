-- Migration 006: PR Base Worktree Optimization (v1.8.0)
-- Tracks base worktrees and their forks for memory-efficient PR handling
-- Base worktree pattern: one base per PR, sub-agents fork from base

-- ============================================================
-- PR_BASE_WORKTREES TABLE
-- Track base worktrees for PRs
-- ============================================================
CREATE TABLE IF NOT EXISTS pr_base_worktrees (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pr_number INTEGER NOT NULL UNIQUE,
    base_id TEXT NOT NULL UNIQUE,       -- pr-{number}-base
    path TEXT NOT NULL,                  -- Full path to worktree
    branch TEXT NOT NULL,                -- PR branch name
    target_branch TEXT NOT NULL,         -- Target branch for merge
    remote TEXT DEFAULT 'origin',
    status TEXT DEFAULT 'active' CHECK(status IN (
        'active',       -- Base is active and ready
        'updating',     -- Being updated from remote
        'stale',        -- Needs update
        'removed'       -- Marked for removal
    )),
    fork_count INTEGER DEFAULT 0,        -- Number of active forks
    last_commit TEXT,                    -- Last known commit SHA
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now')),
    FOREIGN KEY (pr_number) REFERENCES pr_watches(pr_number) ON DELETE CASCADE
);

-- ============================================================
-- PR_WORKTREE_FORKS TABLE
-- Track forks created from base worktrees
-- ============================================================
CREATE TABLE IF NOT EXISTS pr_worktree_forks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pr_number INTEGER NOT NULL,
    fork_id TEXT NOT NULL UNIQUE,        -- Unique fork identifier
    base_id TEXT NOT NULL,               -- Reference to base worktree
    path TEXT NOT NULL,                  -- Full path to fork worktree
    branch TEXT NOT NULL,                -- Fork branch name
    purpose TEXT NOT NULL CHECK(purpose IN (
        'conflict_resolution',   -- For resolving merge conflicts
        'comment_handler',       -- For handling review comments
        'ci_fix',               -- For fixing CI issues
        'general'               -- General purpose fork
    )),
    handler_thread_id TEXT,              -- Thread using this fork
    forked_from_commit TEXT,             -- Commit SHA forked from
    status TEXT DEFAULT 'active' CHECK(status IN (
        'active',       -- Fork is in use
        'merged',       -- Changes merged back to base
        'abandoned',    -- Fork abandoned (no merge)
        'removed'       -- Fork cleaned up
    )),
    created_at TEXT DEFAULT (datetime('now')),
    merged_at TEXT,
    removed_at TEXT,
    FOREIGN KEY (pr_number) REFERENCES pr_watches(pr_number) ON DELETE CASCADE,
    FOREIGN KEY (base_id) REFERENCES pr_base_worktrees(base_id) ON DELETE CASCADE,
    FOREIGN KEY (handler_thread_id) REFERENCES threads(id) ON DELETE SET NULL
);

-- ============================================================
-- EXTEND PR_WATCHES TABLE
-- Add base worktree reference
-- ============================================================
ALTER TABLE pr_watches ADD COLUMN base_worktree_id TEXT REFERENCES pr_base_worktrees(base_id);
ALTER TABLE pr_watches ADD COLUMN use_base_worktree INTEGER DEFAULT 1;

-- ============================================================
-- INDEXES
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_pr_base_worktrees_pr ON pr_base_worktrees(pr_number);
CREATE INDEX IF NOT EXISTS idx_pr_base_worktrees_status ON pr_base_worktrees(status);
CREATE INDEX IF NOT EXISTS idx_pr_worktree_forks_pr ON pr_worktree_forks(pr_number);
CREATE INDEX IF NOT EXISTS idx_pr_worktree_forks_base ON pr_worktree_forks(base_id);
CREATE INDEX IF NOT EXISTS idx_pr_worktree_forks_status ON pr_worktree_forks(status);
CREATE INDEX IF NOT EXISTS idx_pr_worktree_forks_thread ON pr_worktree_forks(handler_thread_id);

-- ============================================================
-- TRIGGERS
-- ============================================================

-- Update timestamp on base worktree changes
CREATE TRIGGER IF NOT EXISTS pr_base_worktrees_updated_at
AFTER UPDATE ON pr_base_worktrees
BEGIN
    UPDATE pr_base_worktrees SET updated_at = datetime('now') WHERE id = NEW.id;
END;

-- Track fork count in base worktree
CREATE TRIGGER IF NOT EXISTS pr_fork_created
AFTER INSERT ON pr_worktree_forks
WHEN NEW.status = 'active'
BEGIN
    UPDATE pr_base_worktrees
    SET fork_count = fork_count + 1
    WHERE base_id = NEW.base_id;
END;

-- Decrement fork count when fork is removed/abandoned
CREATE TRIGGER IF NOT EXISTS pr_fork_removed
AFTER UPDATE ON pr_worktree_forks
WHEN NEW.status IN ('removed', 'abandoned', 'merged') AND OLD.status = 'active'
BEGIN
    UPDATE pr_base_worktrees
    SET fork_count = MAX(0, fork_count - 1)
    WHERE base_id = NEW.base_id;
END;

-- ============================================================
-- VIEWS
-- ============================================================

-- View for active base worktrees with fork info
CREATE VIEW IF NOT EXISTS v_pr_base_worktrees AS
SELECT
    pbw.*,
    pw.repo,
    pw.state as pr_state,
    (SELECT COUNT(*) FROM pr_worktree_forks pwf
     WHERE pwf.base_id = pbw.base_id AND pwf.status = 'active') as active_forks
FROM pr_base_worktrees pbw
JOIN pr_watches pw ON pbw.pr_number = pw.pr_number
WHERE pbw.status != 'removed';

-- View for active forks with purpose breakdown
CREATE VIEW IF NOT EXISTS v_active_forks AS
SELECT
    pwf.*,
    pbw.path as base_path,
    pbw.branch as base_branch,
    pw.repo
FROM pr_worktree_forks pwf
JOIN pr_base_worktrees pbw ON pwf.base_id = pbw.base_id
JOIN pr_watches pw ON pwf.pr_number = pw.pr_number
WHERE pwf.status = 'active';

-- View for fork statistics per PR
CREATE VIEW IF NOT EXISTS v_pr_fork_stats AS
SELECT
    pr_number,
    COUNT(*) as total_forks,
    SUM(CASE WHEN status = 'active' THEN 1 ELSE 0 END) as active_forks,
    SUM(CASE WHEN status = 'merged' THEN 1 ELSE 0 END) as merged_forks,
    SUM(CASE WHEN status = 'abandoned' THEN 1 ELSE 0 END) as abandoned_forks,
    SUM(CASE WHEN purpose = 'conflict_resolution' THEN 1 ELSE 0 END) as conflict_forks,
    SUM(CASE WHEN purpose = 'comment_handler' THEN 1 ELSE 0 END) as comment_forks
FROM pr_worktree_forks
GROUP BY pr_number;
