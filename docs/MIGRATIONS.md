# Database Migrations

claude-threads uses SQLite for persistent storage and includes a migration system for managing database schema changes across versions.

## Overview

When upgrading claude-threads, the install script automatically applies any pending database migrations. You can also run migrations manually using the `ct migrate` command.

## Quick Start

```bash
# Check migration status
ct migrate --status

# Apply pending migrations
ct migrate

# Preview what would be applied (dry run)
ct migrate --dry-run
```

## Migration Files

Migrations are stored in `sql/migrations/` with numbered filenames:

```
sql/migrations/
├── 000_schema_version.sql   # Schema versioning table
├── 001_initial.sql          # Initial schema (v1.0.0)
├── 002_worktrees.sql        # Worktree support (v1.2.0)
└── 003_pr_watches.sql       # PR Shepherd support (v1.1.0-v1.2.0)
```

Each migration file is an SQL script that modifies the database schema.

## Migration Status

Check which migrations have been applied:

```bash
$ ct migrate --status

Database: .claude-threads/threads.db
Current schema version: 3

Applied migrations:
  001: 001_initial                    (2024-01-15 10:30:00)
  002: 002_worktrees                  (2024-01-15 10:30:00)
  003: 003_pr_watches                 (2024-01-15 10:30:00)

Available migrations:
  001: 001_initial                    [applied]
  002: 002_worktrees                  [applied]
  003: 003_pr_watches                 [applied]

All migrations applied.
```

## Schema Versioning

The `schema_migrations` table tracks applied migrations:

```sql
CREATE TABLE schema_migrations (
    version INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    applied_at TEXT DEFAULT (datetime('now'))
);
```

Query current schema version:

```bash
sqlite3 .claude-threads/threads.db "SELECT MAX(version) FROM schema_migrations;"
```

## Creating Custom Migrations

If you need to extend the schema for your project:

### Step 1: Create Migration File

```bash
# Create new migration
touch sql/migrations/004_my_changes.sql
```

### Step 2: Write Migration SQL

```sql
-- Migration 004: Add custom table
-- Description of changes

-- Add new column to existing table
ALTER TABLE threads ADD COLUMN my_field TEXT;

-- Create new table
CREATE TABLE IF NOT EXISTS my_table (
    id TEXT PRIMARY KEY,
    thread_id TEXT,
    data JSON DEFAULT '{}',
    created_at TEXT DEFAULT (datetime('now')),
    FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE
);

-- Create index
CREATE INDEX IF NOT EXISTS idx_my_table_thread ON my_table(thread_id);
```

### Step 3: Apply Migration

```bash
ct migrate
```

## Migration Best Practices

1. **Always use IF NOT EXISTS** - Makes migrations idempotent
2. **Never modify applied migrations** - Create new migrations instead
3. **Test migrations locally first** - Use `--dry-run` to preview
4. **Keep migrations small** - One logical change per migration
5. **Document changes** - Add comments explaining the migration

## Rollback (Manual)

SQLite doesn't support transactional DDL for all operations. To rollback:

1. **Backup your database first**:
   ```bash
   cp .claude-threads/threads.db .claude-threads/threads.db.backup
   ```

2. **Remove the migration record**:
   ```bash
   sqlite3 .claude-threads/threads.db "DELETE FROM schema_migrations WHERE version = 4;"
   ```

3. **Manually reverse the changes** or restore from backup:
   ```bash
   cp .claude-threads/threads.db.backup .claude-threads/threads.db
   ```

## Fresh Installation vs Upgrade

### Fresh Installation

When running `ct init` on a new project:
1. Full schema from `schema.sql` is applied
2. All migration versions are recorded as applied
3. Database starts at current schema version

### Upgrade from Previous Version

When reinstalling or upgrading:
1. Existing database is detected
2. `ct migrate` runs automatically
3. Only pending migrations are applied
4. Existing data is preserved

## Troubleshooting

### Migration Failed

If a migration fails:

```bash
# Check error details
ct migrate 2>&1

# Check database state
sqlite3 .claude-threads/threads.db ".schema"

# Restore from backup if needed
cp .claude-threads/backup/<timestamp>.zip backup.zip
unzip backup.zip
```

### Schema Mismatch

If the schema is out of sync:

```bash
# Check current state
ct migrate --status

# Force reapply (careful - may lose data)
# 1. Backup data
# 2. Delete database
# 3. Run ct init
```

### Missing Migration Table

If `schema_migrations` table doesn't exist:

```bash
sqlite3 .claude-threads/threads.db "CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    applied_at TEXT DEFAULT (datetime('now'))
);"
```

## Current Schema Version

As of v1.2.2:

| Version | Name | Description |
|---------|------|-------------|
| 0 | 000_schema_version | Schema versioning table |
| 1 | 001_initial | Initial schema (threads, events, messages, sessions, artifacts, webhooks) |
| 2 | 002_worktrees | Git worktree support (worktrees table, thread columns) |
| 3 | 003_pr_watches | PR Shepherd support (pr_watches table) |

## See Also

- [README.md](../README.md) - Getting started
- [PR-SHEPHERD.md](PR-SHEPHERD.md) - PR Shepherd documentation
- [sql/schema.sql](../sql/schema.sql) - Full schema reference
