-- Migration 007: Work Recovery & Thread Groups (v1.9.0)
-- Enables checkpoint-based work recovery and consolidated PR creation
-- Supports time-window grouping with configurable PR strategies

-- ============================================================
-- WORK_CHECKPOINTS TABLE
-- Stores checkpoints for thread work recovery
-- ============================================================
CREATE TABLE IF NOT EXISTS work_checkpoints (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    thread_id TEXT NOT NULL,
    checkpoint_type TEXT NOT NULL CHECK(checkpoint_type IN (
        'periodic',           -- Regular interval checkpoint
        'signal',             -- Created on SIGTERM/SIGINT
        'state_transition',   -- On thread state change
        'error',              -- Before error handling
        'manual'              -- Manually triggered
    )),
    git_branch TEXT,
    git_commit_sha TEXT,
    has_uncommitted_changes INTEGER DEFAULT 0,
    uncommitted_diff TEXT,          -- Stored diff for recovery
    stash_ref TEXT,                 -- Git stash reference if used
    worktree_path TEXT,
    session_id TEXT,
    context_snapshot TEXT,          -- JSON with thread context
    recovery_status TEXT DEFAULT 'available' CHECK(recovery_status IN (
        'available',    -- Can be restored
        'recovered',    -- Successfully restored
        'abandoned',    -- Marked as not needed
        'expired'       -- Past cleanup threshold
    )),
    created_at TEXT DEFAULT (datetime('now')),
    recovered_at TEXT,
    FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE
);

-- ============================================================
-- THREAD_GROUPS TABLE
-- Groups threads for consolidated PR creation
-- ============================================================
CREATE TABLE IF NOT EXISTS thread_groups (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    grouping_type TEXT NOT NULL CHECK(grouping_type IN (
        'epic',           -- Threads working on same epic
        'parent',         -- Threads spawned by same parent
        'manual',         -- Manually created group
        'time_window'     -- Threads started within time window
    )),
    pr_strategy TEXT DEFAULT 'individual' CHECK(pr_strategy IN (
        'individual',     -- Each thread creates own PR
        'consolidated'    -- Single PR for all threads
    )),
    consolidated_pr_number INTEGER,
    consolidated_branch TEXT,
    status TEXT DEFAULT 'active' CHECK(status IN (
        'active',         -- Group is active, accepting threads
        'completing',     -- Waiting for threads to complete
        'pr_pending',     -- Ready for consolidated PR
        'pr_created',     -- Consolidated PR created
        'completed',      -- All work merged
        'abandoned'       -- Group abandoned
    )),
    time_window_start TEXT,         -- For time_window grouping
    time_window_end TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

-- ============================================================
-- THREAD_GROUP_MEMBERS TABLE
-- Tracks thread membership in groups
-- ============================================================
CREATE TABLE IF NOT EXISTS thread_group_members (
    thread_id TEXT NOT NULL,
    group_id TEXT NOT NULL,
    merge_order INTEGER DEFAULT 0,  -- Order for consolidated merge
    merge_status TEXT DEFAULT 'pending' CHECK(merge_status IN (
        'pending',        -- Not yet merged
        'merged',         -- Successfully merged to consolidated branch
        'conflict',       -- Merge conflict encountered
        'skipped'         -- Skipped (no changes or abandoned)
    )),
    branch TEXT,                    -- Thread's branch for merging
    added_at TEXT DEFAULT (datetime('now')),
    merged_at TEXT,
    PRIMARY KEY (thread_id, group_id),
    FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE,
    FOREIGN KEY (group_id) REFERENCES thread_groups(id) ON DELETE CASCADE
);

-- ============================================================
-- EXTEND THREADS TABLE
-- Add recovery and group tracking columns
-- ============================================================
ALTER TABLE threads ADD COLUMN group_id TEXT REFERENCES thread_groups(id);
ALTER TABLE threads ADD COLUMN interrupted_at TEXT;
ALTER TABLE threads ADD COLUMN interrupt_reason TEXT;
ALTER TABLE threads ADD COLUMN last_checkpoint_id INTEGER REFERENCES work_checkpoints(id);

-- ============================================================
-- INDEXES
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_checkpoints_thread ON work_checkpoints(thread_id);
CREATE INDEX IF NOT EXISTS idx_checkpoints_status ON work_checkpoints(recovery_status);
CREATE INDEX IF NOT EXISTS idx_checkpoints_type ON work_checkpoints(checkpoint_type);
CREATE INDEX IF NOT EXISTS idx_checkpoints_created ON work_checkpoints(created_at);

CREATE INDEX IF NOT EXISTS idx_groups_status ON thread_groups(status);
CREATE INDEX IF NOT EXISTS idx_groups_type ON thread_groups(grouping_type);
CREATE INDEX IF NOT EXISTS idx_groups_window ON thread_groups(time_window_start, time_window_end);

CREATE INDEX IF NOT EXISTS idx_members_group ON thread_group_members(group_id);
CREATE INDEX IF NOT EXISTS idx_members_status ON thread_group_members(merge_status);

CREATE INDEX IF NOT EXISTS idx_threads_group ON threads(group_id);
CREATE INDEX IF NOT EXISTS idx_threads_interrupted ON threads(interrupted_at);

-- ============================================================
-- TRIGGERS
-- ============================================================

-- Update thread_groups timestamp on changes
CREATE TRIGGER IF NOT EXISTS thread_groups_updated_at
AFTER UPDATE ON thread_groups
BEGIN
    UPDATE thread_groups SET updated_at = datetime('now') WHERE id = NEW.id;
END;

-- Update group status when member status changes
CREATE TRIGGER IF NOT EXISTS check_group_completion
AFTER UPDATE OF merge_status ON thread_group_members
BEGIN
    -- Check if all members are merged or skipped
    UPDATE thread_groups
    SET status = 'pr_pending'
    WHERE id = NEW.group_id
    AND status = 'completing'
    AND pr_strategy = 'consolidated'
    AND NOT EXISTS (
        SELECT 1 FROM thread_group_members
        WHERE group_id = NEW.group_id
        AND merge_status NOT IN ('merged', 'skipped')
    );
END;

-- Track latest checkpoint on thread
CREATE TRIGGER IF NOT EXISTS update_thread_checkpoint
AFTER INSERT ON work_checkpoints
BEGIN
    UPDATE threads SET last_checkpoint_id = NEW.id WHERE id = NEW.thread_id;
END;

-- ============================================================
-- VIEWS
-- ============================================================

-- View for threads with recovery available
CREATE VIEW IF NOT EXISTS v_recoverable_threads AS
SELECT
    t.id,
    t.name,
    t.status,
    t.interrupted_at,
    t.interrupt_reason,
    wc.id as checkpoint_id,
    wc.checkpoint_type,
    wc.git_branch,
    wc.git_commit_sha,
    wc.has_uncommitted_changes,
    wc.worktree_path,
    wc.created_at as checkpoint_created,
    w.path as current_worktree_path,
    w.is_dirty
FROM threads t
LEFT JOIN work_checkpoints wc ON wc.id = t.last_checkpoint_id
LEFT JOIN worktrees w ON w.thread_id = t.id
WHERE (t.interrupted_at IS NOT NULL OR t.status = 'running')
AND wc.recovery_status = 'available';

-- View for active groups with member counts
CREATE VIEW IF NOT EXISTS v_thread_groups AS
SELECT
    g.*,
    COUNT(DISTINCT m.thread_id) as member_count,
    SUM(CASE WHEN t.status = 'completed' THEN 1 ELSE 0 END) as completed_count,
    SUM(CASE WHEN t.status = 'running' THEN 1 ELSE 0 END) as running_count,
    SUM(CASE WHEN m.merge_status = 'merged' THEN 1 ELSE 0 END) as merged_count,
    SUM(CASE WHEN m.merge_status = 'conflict' THEN 1 ELSE 0 END) as conflict_count
FROM thread_groups g
LEFT JOIN thread_group_members m ON g.id = m.group_id
LEFT JOIN threads t ON m.thread_id = t.id
WHERE g.status NOT IN ('completed', 'abandoned')
GROUP BY g.id;

-- View for time window groups accepting new threads
CREATE VIEW IF NOT EXISTS v_active_time_windows AS
SELECT *
FROM thread_groups
WHERE grouping_type = 'time_window'
AND status = 'active'
AND datetime(time_window_end) > datetime('now')
ORDER BY time_window_start DESC;

-- View for groups ready for consolidated PR
CREATE VIEW IF NOT EXISTS v_groups_ready_for_pr AS
SELECT
    g.*,
    COUNT(m.thread_id) as total_members,
    GROUP_CONCAT(m.branch) as branches
FROM thread_groups g
JOIN thread_group_members m ON g.id = m.group_id
WHERE g.status = 'pr_pending'
AND g.pr_strategy = 'consolidated'
GROUP BY g.id;

-- View for checkpoint statistics
CREATE VIEW IF NOT EXISTS v_checkpoint_stats AS
SELECT
    thread_id,
    COUNT(*) as total_checkpoints,
    SUM(CASE WHEN recovery_status = 'available' THEN 1 ELSE 0 END) as available,
    SUM(CASE WHEN recovery_status = 'recovered' THEN 1 ELSE 0 END) as recovered,
    MAX(created_at) as latest_checkpoint,
    SUM(has_uncommitted_changes) as uncommitted_checkpoints
FROM work_checkpoints
GROUP BY thread_id;
