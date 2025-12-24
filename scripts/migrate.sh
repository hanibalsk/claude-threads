#!/usr/bin/env bash
#
# claude-threads database migration script
# Applies pending SQL migrations to the database
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
SQL_DIR="$(dirname "$SCRIPT_DIR")/sql"
MIGRATIONS_DIR="$SQL_DIR/migrations"

# Source utilities
source "$LIB_DIR/log.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_debug() { :; }
}

# Default database path
DB_PATH="${CT_DB_PATH:-.claude-threads/threads.db}"

usage() {
    cat <<EOF
claude-threads database migration

Usage:
  migrate.sh [options]

Options:
  --db PATH       Path to database (default: .claude-threads/threads.db)
  --status        Show migration status only
  --dry-run       Show what would be applied without running
  --help          Show this help

Examples:
  migrate.sh                    # Apply pending migrations
  migrate.sh --status           # Show current migration status
  migrate.sh --dry-run          # Preview pending migrations
EOF
}

# Parse arguments
DRY_RUN=0
STATUS_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --db)
            DB_PATH="$2"
            shift 2
            ;;
        --status)
            STATUS_ONLY=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Check database exists
if [[ ! -f "$DB_PATH" ]]; then
    log_error "Database not found: $DB_PATH"
    log_info "Run 'ct init' first to create the database"
    exit 1
fi

# Ensure migrations directory exists
if [[ ! -d "$MIGRATIONS_DIR" ]]; then
    log_error "Migrations directory not found: $MIGRATIONS_DIR"
    exit 1
fi

# Initialize schema_migrations table if not exists
sqlite3 "$DB_PATH" "CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    applied_at TEXT DEFAULT (datetime('now'))
);"

# Get current schema version
get_current_version() {
    sqlite3 "$DB_PATH" "SELECT COALESCE(MAX(version), 0) FROM schema_migrations;" 2>/dev/null || echo "0"
}

# Get list of applied migrations
get_applied_migrations() {
    sqlite3 "$DB_PATH" "SELECT version, name, applied_at FROM schema_migrations ORDER BY version;" 2>/dev/null || true
}

# Get list of available migrations
get_available_migrations() {
    find "$MIGRATIONS_DIR" -name "*.sql" -type f | sort | while read -r file; do
        basename "$file" .sql
    done
}

# Extract version number from migration filename
get_migration_version() {
    local filename="$1"
    echo "$filename" | sed 's/_.*//' | sed 's/^0*//' | grep -E '^[0-9]+$' || echo "0"
}

# Show migration status
show_status() {
    local current_version
    current_version=$(get_current_version)

    echo "Database: $DB_PATH"
    echo "Current schema version: $current_version"
    echo ""

    echo "Applied migrations:"
    local applied
    applied=$(get_applied_migrations)
    if [[ -z "$applied" ]]; then
        echo "  (none)"
    else
        echo "$applied" | while IFS='|' read -r version name applied_at; do
            printf "  %03d: %-30s (%s)\n" "$version" "$name" "$applied_at"
        done
    fi
    echo ""

    echo "Available migrations:"
    local has_pending=0
    for file in "$MIGRATIONS_DIR"/*.sql; do
        [[ -f "$file" ]] || continue
        local name
        name=$(basename "$file" .sql)
        local version
        version=$(get_migration_version "$name")

        if [[ "$version" -le "$current_version" ]]; then
            printf "  %03d: %-30s [applied]\n" "$version" "$name"
        else
            printf "  %03d: %-30s [pending]\n" "$version" "$name"
            has_pending=1
        fi
    done

    if [[ $has_pending -eq 0 ]]; then
        echo ""
        echo "All migrations applied."
    fi
}

# Apply a single migration
apply_migration() {
    local file="$1"
    local name
    name=$(basename "$file" .sql)
    local version
    version=$(get_migration_version "$name")

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY-RUN] Would apply migration: $name"
        return 0
    fi

    log_info "Applying migration: $name"

    # Apply migration in a transaction
    if sqlite3 "$DB_PATH" < "$file" 2>&1; then
        # Record migration
        sqlite3 "$DB_PATH" "INSERT INTO schema_migrations (version, name) VALUES ($version, '$name');"
        log_info "Applied: $name"
        return 0
    else
        log_error "Failed to apply migration: $name"
        return 1
    fi
}

# Apply pending migrations
apply_pending() {
    local current_version
    current_version=$(get_current_version)
    local applied_count=0
    local failed=0

    log_info "Current schema version: $current_version"

    for file in "$MIGRATIONS_DIR"/*.sql; do
        [[ -f "$file" ]] || continue
        local name
        name=$(basename "$file" .sql)
        local version
        version=$(get_migration_version "$name")

        # Skip already applied migrations
        if [[ "$version" -le "$current_version" ]]; then
            log_debug "Skipping (already applied): $name"
            continue
        fi

        # Apply migration
        if apply_migration "$file"; then
            ((applied_count++))
        else
            failed=1
            break
        fi
    done

    if [[ $DRY_RUN -eq 1 ]]; then
        if [[ $applied_count -eq 0 ]]; then
            echo "No pending migrations to apply."
        else
            echo ""
            echo "Would apply $applied_count migration(s)."
        fi
    else
        if [[ $applied_count -eq 0 ]]; then
            log_info "No pending migrations."
        else
            log_info "Applied $applied_count migration(s)."
        fi
    fi

    return $failed
}

# Main
if [[ $STATUS_ONLY -eq 1 ]]; then
    show_status
else
    apply_pending
fi
