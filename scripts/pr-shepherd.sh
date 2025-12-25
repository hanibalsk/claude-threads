#!/usr/bin/env bash
#
# pr-shepherd.sh - PR feedback loop manager for claude-threads
#
# Monitors PRs and automatically triggers fix attempts when CI fails
# or reviews request changes. Persists across CI cycles until merged.
#
# Usage:
#   ./scripts/pr-shepherd.sh watch <pr_number>     # Start watching a PR
#   ./scripts/pr-shepherd.sh status [pr_number]   # Show PR status
#   ./scripts/pr-shepherd.sh list                 # List all watched PRs
#   ./scripts/pr-shepherd.sh stop <pr_number>     # Stop watching a PR
#
# The shepherd subscribes to:
#   - CI_FAILED, CI_PASSED events
#   - PR_CHANGES_REQUESTED, PR_APPROVED events
#   - PR_COMMENT events (for @claude mentions)
#
# And triggers fix threads that run Claude to address issues.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Source libraries
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/log.sh"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/db.sh"
source "$ROOT_DIR/lib/git.sh"
source "$ROOT_DIR/lib/state.sh"
source "$ROOT_DIR/lib/blackboard.sh"

# ============================================================
# Configuration
# ============================================================

DATA_DIR=""
MAX_FIX_ATTEMPTS=5
CI_POLL_INTERVAL=30       # seconds between CI checks
IDLE_POLL_INTERVAL=300    # seconds when no active PRs (5 min)
PUSH_COOLDOWN=120         # seconds to wait after push before checking CI

# PR States
readonly PR_STATE_WATCHING="watching"
readonly PR_STATE_CI_PENDING="ci_pending"
readonly PR_STATE_CI_FAILED="ci_failed"
readonly PR_STATE_FIXING="fixing"
readonly PR_STATE_REVIEW_PENDING="review_pending"
readonly PR_STATE_CHANGES_REQUESTED="changes_requested"
readonly PR_STATE_APPROVED="approved"
readonly PR_STATE_MERGED="merged"
readonly PR_STATE_CLOSED="closed"

# ============================================================
# Initialization
# ============================================================

init() {
    DATA_DIR="${CT_DATA_DIR:-$(ct_data_dir)}"

    # Load configuration
    config_load "$DATA_DIR/config.yaml"

    # Initialize logging
    log_init "pr-shepherd" "$DATA_DIR/logs/pr-shepherd.log"
    log_set_level "$(config_get 'orchestrator.log_level' 'info')"

    # Initialize database
    db_init "$DATA_DIR"
    bb_init "$DATA_DIR"
    state_init "$DATA_DIR"

    # Ensure PR tracking table exists
    ensure_pr_table

    # Load config overrides
    MAX_FIX_ATTEMPTS=$(config_get_int 'pr_shepherd.max_fix_attempts' 5)
    CI_POLL_INTERVAL=$(config_get_int 'pr_shepherd.ci_poll_interval' 30)
    IDLE_POLL_INTERVAL=$(config_get_int 'pr_shepherd.idle_poll_interval' 300)
    PUSH_COOLDOWN=$(config_get_int 'pr_shepherd.push_cooldown' 120)

    log_debug "PR Shepherd initialized"
}

ensure_pr_table() {
    db_exec "CREATE TABLE IF NOT EXISTS pr_watches (
        pr_number INTEGER PRIMARY KEY,
        repo TEXT NOT NULL,
        branch TEXT,
        base_branch TEXT,
        worktree_path TEXT,
        state TEXT NOT NULL DEFAULT 'watching',
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
    )"

    db_exec "CREATE INDEX IF NOT EXISTS idx_pr_watches_state ON pr_watches(state)"
}

# ============================================================
# PR State Management
# ============================================================

pr_get() {
    local pr_number="$1"
    db_query "SELECT * FROM pr_watches WHERE pr_number = $pr_number" | jq '.[0] // empty'
}

pr_set_state() {
    local pr_number="$1"
    local state="$2"

    db_exec "UPDATE pr_watches SET state = $(db_quote "$state"), updated_at = datetime('now')
             WHERE pr_number = $pr_number"

    log_info "PR #$pr_number state -> $state"

    # Publish event
    bb_publish "PR_STATE_CHANGED" "{\"pr_number\": $pr_number, \"state\": \"$state\"}" "pr-shepherd"
}

pr_increment_fix_attempts() {
    local pr_number="$1"

    db_exec "UPDATE pr_watches SET
             fix_attempts = fix_attempts + 1,
             last_fix_at = datetime('now'),
             updated_at = datetime('now')
             WHERE pr_number = $pr_number"
}

pr_set_fix_thread() {
    local pr_number="$1"
    local thread_id="$2"

    db_exec "UPDATE pr_watches SET
             current_fix_thread_id = $(db_quote "$thread_id"),
             updated_at = datetime('now')
             WHERE pr_number = $pr_number"
}

pr_record_push() {
    local pr_number="$1"

    db_exec "UPDATE pr_watches SET
             last_push_at = datetime('now'),
             updated_at = datetime('now')
             WHERE pr_number = $pr_number"
}

pr_record_ci_check() {
    local pr_number="$1"

    db_exec "UPDATE pr_watches SET
             last_ci_check_at = datetime('now'),
             updated_at = datetime('now')
             WHERE pr_number = $pr_number"
}

# ============================================================
# GitHub Integration
# ============================================================

gh_get_pr() {
    local pr_number="$1"
    gh pr view "$pr_number" --json number,state,title,headRefName,baseRefName,mergeable,reviewDecision,statusCheckRollup 2>/dev/null
}

gh_get_ci_status() {
    local pr_number="$1"

    local checks
    checks=$(gh pr checks "$pr_number" --json name,state,conclusion 2>/dev/null || echo "[]")

    # Determine overall status
    local pending failed passed total
    pending=$(echo "$checks" | jq '[.[] | select(.state == "pending" or .state == "queued" or .state == "in_progress")] | length')
    failed=$(echo "$checks" | jq '[.[] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out")] | length')
    passed=$(echo "$checks" | jq '[.[] | select(.conclusion == "success")] | length')
    total=$(echo "$checks" | jq 'length')

    if [[ $total -eq 0 ]]; then
        echo "none"
    elif [[ $pending -gt 0 ]]; then
        echo "pending"
    elif [[ $failed -gt 0 ]]; then
        echo "failed"
    else
        echo "passed"
    fi
}

gh_get_review_status() {
    local pr_number="$1"

    local pr_data
    pr_data=$(gh_get_pr "$pr_number")

    if [[ -z "$pr_data" ]]; then
        echo "unknown"
        return
    fi

    local decision
    decision=$(echo "$pr_data" | jq -r '.reviewDecision // "REVIEW_REQUIRED"')

    case "$decision" in
        APPROVED) echo "approved" ;;
        CHANGES_REQUESTED) echo "changes_requested" ;;
        *) echo "pending" ;;
    esac
}

gh_get_failed_checks() {
    local pr_number="$1"

    gh pr checks "$pr_number" --json name,state,conclusion,detailsUrl 2>/dev/null | \
        jq '[.[] | select(.conclusion == "failure" or .conclusion == "cancelled")]'
}

gh_is_merged() {
    local pr_number="$1"

    local state
    state=$(gh pr view "$pr_number" --json state -q '.state' 2>/dev/null || echo "UNKNOWN")

    [[ "$state" == "MERGED" ]]
}

gh_is_closed() {
    local pr_number="$1"

    local state
    state=$(gh pr view "$pr_number" --json state -q '.state' 2>/dev/null || echo "UNKNOWN")

    [[ "$state" == "CLOSED" ]]
}

# ============================================================
# Fix Thread Management
# ============================================================

spawn_fix_thread() {
    local pr_number="$1"
    local fix_type="$2"  # "ci" or "review"
    local details="$3"

    local pr_watch
    pr_watch=$(pr_get "$pr_number")

    local fix_attempts worktree_path branch
    fix_attempts=$(echo "$pr_watch" | jq -r '.fix_attempts // 0')
    worktree_path=$(echo "$pr_watch" | jq -r '.worktree_path // empty')
    branch=$(echo "$pr_watch" | jq -r '.branch // empty')

    if [[ $fix_attempts -ge $MAX_FIX_ATTEMPTS ]]; then
        log_warn "PR #$pr_number has reached max fix attempts ($MAX_FIX_ATTEMPTS)"
        pr_set_state "$pr_number" "blocked"
        bb_publish "PR_MAX_ATTEMPTS_REACHED" "{\"pr_number\": $pr_number, \"attempts\": $fix_attempts}" "pr-shepherd"
        return 1
    fi

    local thread_name="pr-${pr_number}-fix-${fix_type}-$((fix_attempts + 1))"

    # Build context with worktree info
    local context
    context=$(jq -n \
        --arg pr "$pr_number" \
        --arg type "$fix_type" \
        --arg details "$details" \
        --arg attempt "$((fix_attempts + 1))" \
        --arg worktree "$worktree_path" \
        --arg branch "$branch" \
        '{pr_number: $pr, fix_type: $type, details: $details, attempt: ($attempt | tonumber), worktree_path: $worktree, branch: $branch, auto_push: true}')

    local thread_id

    # If we have a worktree, create thread with worktree awareness
    if [[ -n "$worktree_path" && -d "$worktree_path" ]]; then
        # Create thread that will use the existing PR worktree
        thread_id=$(thread_create "$thread_name" "automatic" "prompts/pr-fix.md" "" "$context")

        # Update thread to use existing worktree
        db_exec "UPDATE threads SET
                    worktree = $(db_quote "$worktree_path"),
                    worktree_branch = $(db_quote "$branch")
                 WHERE id = $(db_quote "$thread_id")"

        log_info "Fix thread will use PR worktree: $worktree_path"
    else
        # Fall back to creating thread without worktree
        thread_id=$(thread_create "$thread_name" "automatic" "prompts/pr-fix.md" "" "$context")
    fi

    # Update PR watch
    pr_increment_fix_attempts "$pr_number"
    pr_set_fix_thread "$pr_number" "$thread_id"
    pr_set_state "$pr_number" "$PR_STATE_FIXING"

    # Make thread ready
    db_thread_set_status "$thread_id" "ready"

    log_info "Spawned fix thread $thread_id for PR #$pr_number ($fix_type, attempt $((fix_attempts + 1)))"

    bb_publish "PR_FIX_STARTED" \
        "{\"pr_number\": $pr_number, \"thread_id\": \"$thread_id\", \"fix_type\": \"$fix_type\", \"attempt\": $((fix_attempts + 1))}" \
        "pr-shepherd"

    echo "$thread_id"
}

cleanup_pr_worktree() {
    local pr_number="$1"

    local pr_watch
    pr_watch=$(pr_get "$pr_number")

    local worktree_path
    worktree_path=$(echo "$pr_watch" | jq -r '.worktree_path // empty')

    if [[ -n "$worktree_path" && -d "$worktree_path" ]]; then
        local worktree_id="pr-shepherd-${pr_number}"
        log_info "Cleaning up worktree for PR #$pr_number: $worktree_path"

        if git_worktree_remove "$worktree_id" "true"; then
            db_exec "UPDATE pr_watches SET worktree_path = NULL WHERE pr_number = $pr_number"
            bb_publish "PR_WORKTREE_CLEANED" "{\"pr_number\": $pr_number, \"path\": \"$worktree_path\"}" "pr-shepherd"
        else
            log_warn "Failed to cleanup worktree for PR #$pr_number"
        fi
    fi
}

check_fix_thread_status() {
    local pr_number="$1"

    local pr_watch
    pr_watch=$(pr_get "$pr_number")

    local fix_thread_id
    fix_thread_id=$(echo "$pr_watch" | jq -r '.current_fix_thread_id // empty')

    if [[ -z "$fix_thread_id" ]]; then
        return 0  # No fix thread
    fi

    local thread_status
    thread_status=$(db_scalar "SELECT status FROM threads WHERE id = $(db_quote "$fix_thread_id")")

    case "$thread_status" in
        completed)
            log_info "Fix thread $fix_thread_id completed, checking results"
            pr_set_state "$pr_number" "$PR_STATE_CI_PENDING"
            pr_record_push "$pr_number"  # Assume fix pushed changes
            ;;
        failed|blocked)
            log_warn "Fix thread $fix_thread_id failed"
            # Try again if under max attempts
            pr_set_state "$pr_number" "$PR_STATE_CI_FAILED"
            ;;
        running|ready|waiting)
            # Still in progress
            log_debug "Fix thread $fix_thread_id still running"
            ;;
    esac
}

# ============================================================
# Main Shepherd Loop
# ============================================================

shepherd_tick() {
    local pr_number="$1"

    local pr_watch
    pr_watch=$(pr_get "$pr_number")

    if [[ -z "$pr_watch" ]]; then
        log_error "PR #$pr_number not found in watch list"
        return 1
    fi

    local state
    state=$(echo "$pr_watch" | jq -r '.state')

    log_debug "Shepherd tick for PR #$pr_number (state=$state)"

    # Check if PR was merged or closed
    if gh_is_merged "$pr_number"; then
        pr_set_state "$pr_number" "$PR_STATE_MERGED"
        log_info "PR #$pr_number has been merged!"
        bb_publish "PR_MERGED" "{\"pr_number\": $pr_number}" "pr-shepherd"

        # Cleanup worktree on merge
        cleanup_pr_worktree "$pr_number"
        return 0
    fi

    if gh_is_closed "$pr_number"; then
        pr_set_state "$pr_number" "$PR_STATE_CLOSED"
        log_info "PR #$pr_number has been closed"
        bb_publish "PR_CLOSED" "{\"pr_number\": $pr_number}" "pr-shepherd"

        # Cleanup worktree on close
        cleanup_pr_worktree "$pr_number"
        return 0
    fi

    case "$state" in
        "$PR_STATE_WATCHING"|"$PR_STATE_CI_PENDING")
            check_ci_status "$pr_number"
            ;;
        "$PR_STATE_CI_FAILED")
            # Spawn fix thread for CI failure
            local failed_checks
            failed_checks=$(gh_get_failed_checks "$pr_number")
            spawn_fix_thread "$pr_number" "ci" "$failed_checks"
            ;;
        "$PR_STATE_FIXING")
            check_fix_thread_status "$pr_number"
            ;;
        "$PR_STATE_REVIEW_PENDING")
            check_review_status "$pr_number"
            ;;
        "$PR_STATE_CHANGES_REQUESTED")
            # Spawn fix thread for review changes
            spawn_fix_thread "$pr_number" "review" ""
            ;;
        "$PR_STATE_APPROVED")
            # Check if CI passed, then merge
            check_merge_readiness "$pr_number"
            ;;
        "$PR_STATE_MERGED"|"$PR_STATE_CLOSED")
            # Terminal states - no action needed
            return 0
            ;;
    esac
}

check_ci_status() {
    local pr_number="$1"

    # Check push cooldown
    local last_push
    last_push=$(db_scalar "SELECT last_push_at FROM pr_watches WHERE pr_number = $pr_number")

    if [[ -n "$last_push" ]]; then
        local push_epoch now_epoch
        push_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$last_push" +%s 2>/dev/null || \
                    date -d "$last_push" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)

        if [[ $((now_epoch - push_epoch)) -lt $PUSH_COOLDOWN ]]; then
            log_debug "PR #$pr_number: waiting for push cooldown"
            return
        fi
    fi

    local ci_status
    ci_status=$(gh_get_ci_status "$pr_number")
    pr_record_ci_check "$pr_number"

    log_debug "PR #$pr_number CI status: $ci_status"

    case "$ci_status" in
        passed)
            log_info "PR #$pr_number: CI passed"
            pr_set_state "$pr_number" "$PR_STATE_REVIEW_PENDING"
            bb_publish "CI_PASSED" "{\"pr_number\": $pr_number}" "pr-shepherd"
            ;;
        failed)
            log_info "PR #$pr_number: CI failed"
            pr_set_state "$pr_number" "$PR_STATE_CI_FAILED"
            bb_publish "CI_FAILED" "{\"pr_number\": $pr_number}" "pr-shepherd"
            ;;
        pending)
            log_debug "PR #$pr_number: CI still pending"
            pr_set_state "$pr_number" "$PR_STATE_CI_PENDING"
            ;;
        none)
            log_debug "PR #$pr_number: No CI checks configured"
            pr_set_state "$pr_number" "$PR_STATE_REVIEW_PENDING"
            ;;
    esac
}

check_review_status() {
    local pr_number="$1"

    local review_status
    review_status=$(gh_get_review_status "$pr_number")

    log_debug "PR #$pr_number review status: $review_status"

    case "$review_status" in
        approved)
            log_info "PR #$pr_number: Approved"
            pr_set_state "$pr_number" "$PR_STATE_APPROVED"
            bb_publish "PR_APPROVED" "{\"pr_number\": $pr_number}" "pr-shepherd"
            ;;
        changes_requested)
            log_info "PR #$pr_number: Changes requested"
            pr_set_state "$pr_number" "$PR_STATE_CHANGES_REQUESTED"
            bb_publish "PR_CHANGES_REQUESTED" "{\"pr_number\": $pr_number}" "pr-shepherd"
            ;;
        pending)
            log_debug "PR #$pr_number: Waiting for review"
            ;;
    esac
}

check_merge_readiness() {
    local pr_number="$1"

    # Verify CI still passing
    local ci_status
    ci_status=$(gh_get_ci_status "$pr_number")

    if [[ "$ci_status" != "passed" ]]; then
        log_info "PR #$pr_number: CI no longer passing, rechecking"
        pr_set_state "$pr_number" "$PR_STATE_CI_PENDING"
        return
    fi

    # Check if auto-merge is enabled
    local auto_merge
    auto_merge=$(config_get_bool 'pr_shepherd.auto_merge' false)

    if [[ "$auto_merge" == "true" ]]; then
        log_info "PR #$pr_number: Ready to merge, auto-merging..."
        if gh pr merge "$pr_number" --squash --delete-branch 2>/dev/null; then
            pr_set_state "$pr_number" "$PR_STATE_MERGED"
            bb_publish "PR_MERGED" "{\"pr_number\": $pr_number, \"auto_merged\": true}" "pr-shepherd"
        else
            log_error "Failed to auto-merge PR #$pr_number"
        fi
    else
        log_info "PR #$pr_number: Ready to merge (auto-merge disabled)"
        bb_publish "PR_READY_TO_MERGE" "{\"pr_number\": $pr_number}" "pr-shepherd"
    fi
}

# ============================================================
# Shepherd Daemon
# ============================================================

run_shepherd_loop() {
    log_info "Starting PR shepherd loop"

    while true; do
        # Get all active PRs
        local active_prs
        active_prs=$(db_query "SELECT pr_number FROM pr_watches
                               WHERE state NOT IN ('merged', 'closed')
                               ORDER BY updated_at ASC")

        local count
        count=$(echo "$active_prs" | jq 'length')

        if [[ $count -eq 0 ]]; then
            log_debug "No active PRs, sleeping for $IDLE_POLL_INTERVAL seconds"
            sleep "$IDLE_POLL_INTERVAL"
            continue
        fi

        log_debug "Checking $count active PRs"

        echo "$active_prs" | jq -r '.[].pr_number' | while read -r pr_number; do
            shepherd_tick "$pr_number" || true
        done

        sleep "$CI_POLL_INTERVAL"
    done
}

# ============================================================
# Commands
# ============================================================

cmd_watch() {
    local pr_number="$1"
    local use_worktree="${2:-true}"  # Default to using worktrees

    if [[ -z "$pr_number" ]]; then
        echo "Usage: pr-shepherd.sh watch <pr_number> [--no-worktree]"
        exit 1
    fi

    # Check for --no-worktree flag
    if [[ "${2:-}" == "--no-worktree" ]]; then
        use_worktree="false"
    fi

    # Check if already watching
    local existing
    existing=$(pr_get "$pr_number")

    if [[ -n "$existing" ]]; then
        local state
        state=$(echo "$existing" | jq -r '.state')
        echo "Already watching PR #$pr_number (state: $state)"
        exit 0
    fi

    # Get PR info from GitHub
    local pr_data
    pr_data=$(gh_get_pr "$pr_number")

    if [[ -z "$pr_data" ]]; then
        echo "Error: Could not find PR #$pr_number"
        exit 1
    fi

    local branch base_branch repo
    branch=$(echo "$pr_data" | jq -r '.headRefName')
    base_branch=$(echo "$pr_data" | jq -r '.baseRefName')
    repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "unknown")

    # Create worktree for PR if enabled
    local worktree_path=""
    if [[ "$use_worktree" == "true" ]]; then
        local worktree_id="pr-shepherd-${pr_number}"
        worktree_path=$(git_worktree_create "$worktree_id" "$branch" "$base_branch" 2>/dev/null) || true

        if [[ -n "$worktree_path" && -d "$worktree_path" ]]; then
            log_info "Created worktree for PR #$pr_number: $worktree_path"
            echo "  Worktree: $worktree_path"
        else
            log_warn "Could not create worktree for PR #$pr_number, continuing without"
            worktree_path=""
        fi
    fi

    # Create watch entry
    db_exec "INSERT INTO pr_watches (pr_number, repo, branch, base_branch, worktree_path, state)
             VALUES ($pr_number, $(db_quote "$repo"), $(db_quote "$branch"),
                     $(db_quote "$base_branch"), $(db_quote "$worktree_path"), 'watching')"

    log_info "Now watching PR #$pr_number ($repo, branch: $branch)"
    echo "Now watching PR #$pr_number"
    echo "  Repository: $repo"
    echo "  Branch: $branch"
    echo "  Base: $base_branch"
    if [[ -n "$worktree_path" ]]; then
        echo "  Worktree: $worktree_path"
    fi

    # Publish event
    bb_publish "PR_WATCH_STARTED" \
        "{\"pr_number\": $pr_number, \"repo\": \"$repo\", \"branch\": \"$branch\", \"worktree\": \"$worktree_path\"}" \
        "pr-shepherd"

    # Do initial check
    shepherd_tick "$pr_number"
}

cmd_status() {
    local pr_number="${1:-}"

    if [[ -n "$pr_number" ]]; then
        local pr_watch
        pr_watch=$(pr_get "$pr_number")

        if [[ -z "$pr_watch" ]]; then
            echo "PR #$pr_number is not being watched"
            exit 1
        fi

        echo "PR #$pr_number Status"
        echo "===================="
        echo "$pr_watch" | jq -r '
            "State: \(.state)",
            "Repository: \(.repo)",
            "Branch: \(.branch // "unknown")",
            "Fix Attempts: \(.fix_attempts // 0)",
            "Last Push: \(.last_push_at // "never")",
            "Last CI Check: \(.last_ci_check_at // "never")",
            "Current Fix Thread: \(.current_fix_thread_id // "none")",
            "Created: \(.created_at)",
            "Updated: \(.updated_at)"
        '
    else
        cmd_list
    fi
}

cmd_list() {
    echo "Watched PRs"
    echo "==========="

    local prs
    prs=$(db_query "SELECT * FROM pr_watches ORDER BY updated_at DESC")

    local count
    count=$(echo "$prs" | jq 'length')

    if [[ $count -eq 0 ]]; then
        echo "No PRs being watched"
        return
    fi

    echo "$prs" | jq -r '.[] | "#\(.pr_number)\t\(.state)\t\(.fix_attempts) fixes\t\(.repo)"' | column -t -s $'\t'
}

cmd_stop() {
    local pr_number="$1"
    local keep_worktree="${2:-false}"

    if [[ -z "$pr_number" ]]; then
        echo "Usage: pr-shepherd.sh stop <pr_number> [--keep-worktree]"
        exit 1
    fi

    # Check for --keep-worktree flag
    if [[ "$2" == "--keep-worktree" ]]; then
        keep_worktree="true"
    fi

    local existing
    existing=$(pr_get "$pr_number")

    if [[ -z "$existing" ]]; then
        echo "PR #$pr_number is not being watched"
        exit 1
    fi

    # Stop any running fix thread
    local fix_thread_id
    fix_thread_id=$(echo "$existing" | jq -r '.current_fix_thread_id // empty')

    if [[ -n "$fix_thread_id" ]]; then
        local thread_status
        thread_status=$(db_scalar "SELECT status FROM threads WHERE id = $(db_quote "$fix_thread_id")")

        if [[ "$thread_status" == "running" ]]; then
            log_info "Stopping fix thread $fix_thread_id"
            thread_fail "$fix_thread_id" "PR watch stopped"
        fi
    fi

    # Cleanup worktree if exists
    local worktree_path
    worktree_path=$(echo "$existing" | jq -r '.worktree_path // empty')

    if [[ -n "$worktree_path" && -d "$worktree_path" && "$keep_worktree" != "true" ]]; then
        local worktree_id="pr-shepherd-${pr_number}"
        log_info "Removing worktree: $worktree_path"
        git_worktree_remove "$worktree_id" "true" || log_warn "Failed to remove worktree"
    fi

    db_exec "DELETE FROM pr_watches WHERE pr_number = $pr_number"

    log_info "Stopped watching PR #$pr_number"
    echo "Stopped watching PR #$pr_number"

    bb_publish "PR_WATCH_STOPPED" "{\"pr_number\": $pr_number}" "pr-shepherd"
}

cmd_daemon() {
    local pid_file="$DATA_DIR/pr-shepherd.pid"

    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            echo "PR Shepherd already running (PID: $pid)"
            exit 1
        fi
        rm -f "$pid_file"
    fi

    echo $$ > "$pid_file"
    trap "rm -f '$pid_file'" EXIT

    run_shepherd_loop
}

# ============================================================
# Main
# ============================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  watch <pr_number>     Start watching a PR
  status [pr_number]    Show PR status (or list all if no number)
  list                  List all watched PRs
  stop <pr_number>      Stop watching a PR
  daemon                Run shepherd as daemon
  tick <pr_number>      Run single check for a PR

Options:
  --data-dir DIR        Data directory (default: .claude-threads)
  --help                Show this help

Configuration (config.yaml):
  pr_shepherd:
    max_fix_attempts: 5       # Max auto-fix attempts per PR
    ci_poll_interval: 30      # Seconds between CI checks
    idle_poll_interval: 300   # Seconds when no active PRs
    push_cooldown: 120        # Seconds to wait after push
    auto_merge: false         # Auto-merge when ready
EOF
    exit 0
}

main() {
    local command="${1:-}"
    shift || true

    # Parse global options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --data-dir)
                export CT_DATA_DIR="$2"
                shift 2
                ;;
            --help|-h)
                usage
                ;;
            *)
                break
                ;;
        esac
    done

    init

    case "$command" in
        watch)
            cmd_watch "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        list)
            cmd_list
            ;;
        stop)
            cmd_stop "$@"
            ;;
        daemon)
            cmd_daemon
            ;;
        tick)
            shepherd_tick "$@"
            ;;
        ""|--help|-h)
            usage
            ;;
        *)
            echo "Unknown command: $command"
            usage
            ;;
    esac
}

main "$@"
