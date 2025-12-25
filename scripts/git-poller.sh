#!/usr/bin/env bash
#
# git-poller.sh - Polling-based git/PR status checker for PR lifecycle
#
# Runs as a daemon or single tick, periodically checking:
# - PR status (CI, reviews, mergeability)
# - Merge conflicts
# - Unresolved review comments
#
# Publishes events to blackboard for agents to consume.
#
# Usage:
#   ./scripts/git-poller.sh start [--data-dir DIR]    # Start daemon
#   ./scripts/git-poller.sh stop                       # Stop daemon
#   ./scripts/git-poller.sh status                     # Check status
#   ./scripts/git-poller.sh tick [--pr NUMBER]         # Run one poll cycle
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Source libraries
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/log.sh"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/db.sh"
source "$ROOT_DIR/lib/blackboard.sh"
source "$ROOT_DIR/lib/git.sh"

# ============================================================
# Configuration
# ============================================================

DEFAULT_POLL_INTERVAL=30
POLLER_PID_FILE=""
POLLER_LOG_FILE=""

# ============================================================
# GitHub API helpers
# ============================================================

# Get PR details from GitHub
gh_pr_get() {
    local pr_number="$1"

    gh pr view "$pr_number" --json \
        number,state,title,headRefName,baseRefName,mergeable,mergeStateStatus,\
reviewDecision,statusCheckRollup,isDraft,author,url 2>/dev/null || echo "{}"
}

# Get PR review threads (comments) from GitHub
gh_pr_get_review_threads() {
    local pr_number="$1"
    local repo
    repo=$(git_get_repo_name)

    gh api graphql -f query='
        query($owner: String!, $repo: String!, $pr: Int!) {
            repository(owner: $owner, name: $repo) {
                pullRequest(number: $pr) {
                    reviewThreads(first: 100) {
                        nodes {
                            id
                            isResolved
                            isOutdated
                            path
                            line
                            comments(first: 1) {
                                nodes {
                                    id
                                    databaseId
                                    author { login }
                                    body
                                    createdAt
                                }
                            }
                        }
                    }
                }
            }
        }
    ' -f owner="$(echo "$repo" | cut -d/ -f1)" \
      -f repo="$(echo "$repo" | cut -d/ -f2)" \
      -F pr="$pr_number" 2>/dev/null | jq '.data.repository.pullRequest.reviewThreads.nodes // []'
}

# Get conflicting files for a PR
gh_pr_get_conflicts() {
    local pr_number="$1"
    local worktree_path="$2"
    local base_branch="$3"

    if [[ -z "$worktree_path" || ! -d "$worktree_path" ]]; then
        echo "[]"
        return
    fi

    # Try to merge and capture conflicting files
    cd "$worktree_path"
    git fetch origin "$base_branch" 2>/dev/null || true

    # Attempt merge and capture conflicts
    local conflicts
    if ! git merge --no-commit --no-ff "origin/$base_branch" 2>/dev/null; then
        conflicts=$(git diff --name-only --diff-filter=U 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))')
        git merge --abort 2>/dev/null || true
    else
        git merge --abort 2>/dev/null || true
        conflicts="[]"
    fi

    echo "$conflicts"
}

# ============================================================
# Polling functions
# ============================================================

# Poll a single PR's status
poll_pr() {
    local pr_number="$1"

    log_debug "Polling PR #$pr_number"

    # Get PR watch record
    local pr_watch
    pr_watch=$(db_query "SELECT * FROM pr_watches WHERE pr_number = $pr_number" | jq '.[0] // empty')

    if [[ -z "$pr_watch" || "$pr_watch" == "null" ]]; then
        log_warn "PR #$pr_number not found in watches"
        return 1
    fi

    local worktree_path base_branch current_state
    worktree_path=$(echo "$pr_watch" | jq -r '.worktree_path // empty')
    base_branch=$(echo "$pr_watch" | jq -r '.base_branch // "main"')
    current_state=$(echo "$pr_watch" | jq -r '.state // "watching"')

    # Skip terminal states
    if [[ "$current_state" == "merged" || "$current_state" == "closed" ]]; then
        log_debug "PR #$pr_number is in terminal state: $current_state"
        return 0
    fi

    # Get PR details from GitHub
    local pr_data
    pr_data=$(gh_pr_get "$pr_number")

    if [[ -z "$pr_data" || "$pr_data" == "{}" ]]; then
        log_warn "Could not fetch PR #$pr_number from GitHub"
        return 1
    fi

    # Check PR state
    local gh_state mergeable review_decision
    gh_state=$(echo "$pr_data" | jq -r '.state // "OPEN"')
    mergeable=$(echo "$pr_data" | jq -r '.mergeable // "UNKNOWN"')
    review_decision=$(echo "$pr_data" | jq -r '.reviewDecision // "REVIEW_REQUIRED"')

    # Handle closed/merged PRs
    if [[ "$gh_state" == "MERGED" ]]; then
        log_info "PR #$pr_number has been merged"
        db_exec "UPDATE pr_watches SET state = 'merged', updated_at = datetime('now') WHERE pr_number = $pr_number"
        bb_publish "PR_MERGED" "{\"pr_number\": $pr_number}" "git-poller"
        return 0
    elif [[ "$gh_state" == "CLOSED" ]]; then
        log_info "PR #$pr_number has been closed"
        db_exec "UPDATE pr_watches SET state = 'closed', updated_at = datetime('now') WHERE pr_number = $pr_number"
        bb_publish "PR_CLOSED" "{\"pr_number\": $pr_number}" "git-poller"
        return 0
    fi

    # Check for merge conflicts
    if [[ "$mergeable" == "CONFLICTING" ]]; then
        log_info "PR #$pr_number has merge conflicts"

        # Get conflicting files
        local conflicts
        conflicts=$(gh_pr_get_conflicts "$pr_number" "$worktree_path" "$base_branch")

        # Check if we already have an active conflict record
        local existing_conflict
        existing_conflict=$(db_merge_conflict_get_active "$pr_number")

        if [[ -z "$existing_conflict" || "$existing_conflict" == "null" ]]; then
            # Create new conflict record
            local conflict_id
            conflict_id=$(db_merge_conflict_create "$pr_number" "$base_branch" "$conflicts")

            # Update PR watch
            db_pr_watch_set_conflict "$pr_number" 1

            # Publish event
            bb_publish "MERGE_CONFLICT_DETECTED" \
                "{\"pr_number\": $pr_number, \"conflict_id\": $conflict_id, \"files\": $conflicts, \"target_branch\": \"$base_branch\"}" \
                "git-poller"
        fi
    else
        # No conflicts - clear flag if it was set
        db_pr_watch_set_conflict "$pr_number" 0
    fi

    # Check CI status
    local ci_status
    ci_status=$(echo "$pr_data" | jq -r '.statusCheckRollup // []')
    local ci_conclusion
    ci_conclusion=$(echo "$ci_status" | jq -r 'if type == "array" then (if all(.conclusion == "SUCCESS") then "SUCCESS" elif any(.conclusion == "FAILURE") then "FAILURE" elif any(.state == "PENDING") then "PENDING" else "UNKNOWN" end) else "UNKNOWN" end')

    case "$ci_conclusion" in
        SUCCESS)
            if [[ "$current_state" == "ci_pending" || "$current_state" == "ci_failed" ]]; then
                db_exec "UPDATE pr_watches SET state = 'ci_passed', updated_at = datetime('now') WHERE pr_number = $pr_number"
                bb_publish "CI_PASSED" "{\"pr_number\": $pr_number}" "git-poller"
            fi
            ;;
        FAILURE)
            if [[ "$current_state" != "ci_failed" && "$current_state" != "fixing" ]]; then
                db_exec "UPDATE pr_watches SET state = 'ci_failed', updated_at = datetime('now') WHERE pr_number = $pr_number"
                bb_publish "CI_FAILED" "{\"pr_number\": $pr_number, \"checks\": $ci_status}" "git-poller"
            fi
            ;;
        PENDING)
            if [[ "$current_state" != "ci_pending" && "$current_state" != "fixing" ]]; then
                db_exec "UPDATE pr_watches SET state = 'ci_pending', updated_at = datetime('now') WHERE pr_number = $pr_number"
            fi
            ;;
    esac

    # Check review comments
    local review_threads
    review_threads=$(gh_pr_get_review_threads "$pr_number")

    local pending_count=0
    local responded_count=0
    local resolved_count=0

    # Process each review thread
    echo "$review_threads" | jq -c '.[]' | while read -r thread; do
        local thread_id is_resolved is_outdated path line
        thread_id=$(echo "$thread" | jq -r '.id')
        is_resolved=$(echo "$thread" | jq -r '.isResolved')
        is_outdated=$(echo "$thread" | jq -r '.isOutdated')
        path=$(echo "$thread" | jq -r '.path // ""')
        line=$(echo "$thread" | jq -r '.line // 0')

        # Get first comment details
        local comment
        comment=$(echo "$thread" | jq '.comments.nodes[0] // empty')

        if [[ -n "$comment" && "$comment" != "null" ]]; then
            local github_comment_id author body
            github_comment_id=$(echo "$comment" | jq -r '.databaseId // .id')
            author=$(echo "$comment" | jq -r '.author.login // "unknown"')
            body=$(echo "$comment" | jq -r '.body // ""')

            # Skip outdated comments
            if [[ "$is_outdated" == "true" ]]; then
                continue
            fi

            # Upsert comment in database
            db_pr_comment_upsert "$pr_number" "$github_comment_id" "$thread_id" "$path" "${line:-0}" "$body" "$author"

            # Update state based on GitHub resolution status
            if [[ "$is_resolved" == "true" ]]; then
                db_exec "UPDATE pr_comments SET state = 'resolved' WHERE github_comment_id = $(db_quote "$github_comment_id") AND state != 'resolved'"
            fi
        fi
    done

    # Update comment counts
    local counts
    counts=$(db_pr_comments_count "$pr_number")
    pending_count=$(echo "$counts" | jq -r '[.[] | select(.state == "pending")] | .[0].count // 0')
    responded_count=$(echo "$counts" | jq -r '[.[] | select(.state == "responded")] | .[0].count // 0')
    resolved_count=$(echo "$counts" | jq -r '[.[] | select(.state == "resolved")] | .[0].count // 0')

    db_pr_watch_update_comments "$pr_number" "${pending_count:-0}" "${responded_count:-0}" "${resolved_count:-0}"

    # Publish pending comments event if there are unhandled comments
    if [[ "${pending_count:-0}" -gt 0 ]]; then
        local pending_comments
        pending_comments=$(db_pr_comments_pending "$pr_number")
        bb_publish "REVIEW_COMMENTS_PENDING" \
            "{\"pr_number\": $pr_number, \"count\": $pending_count, \"comments\": $pending_comments}" \
            "git-poller"
    fi

    # Check review decision
    case "$review_decision" in
        APPROVED)
            if [[ "$current_state" != "approved" && "$current_state" != "merged" ]]; then
                db_exec "UPDATE pr_watches SET state = 'approved', updated_at = datetime('now') WHERE pr_number = $pr_number"
                bb_publish "PR_APPROVED" "{\"pr_number\": $pr_number}" "git-poller"
            fi
            ;;
        CHANGES_REQUESTED)
            if [[ "$current_state" != "changes_requested" ]]; then
                db_exec "UPDATE pr_watches SET state = 'changes_requested', updated_at = datetime('now') WHERE pr_number = $pr_number"
                bb_publish "CHANGES_REQUESTED" "{\"pr_number\": $pr_number}" "git-poller"
            fi
            ;;
    esac

    # Check if PR is ready to merge (all criteria met)
    local lifecycle_status
    lifecycle_status=$(db_pr_lifecycle_status "$pr_number")
    local lifecycle_state
    lifecycle_state=$(echo "$lifecycle_status" | jq -r '.lifecycle_state // "unknown"')

    if [[ "$lifecycle_state" == "ready_to_merge" ]]; then
        local auto_merge
        auto_merge=$(echo "$lifecycle_status" | jq -r '.effective_auto_merge // 0')

        bb_publish "PR_READY_FOR_MERGE" \
            "{\"pr_number\": $pr_number, \"auto_merge\": $auto_merge}" \
            "git-poller"
    fi

    # Update last poll timestamp
    db_pr_watch_set_polled "$pr_number"

    # Publish general status update
    bb_publish "POLL_PR_STATUS" \
        "{\"pr_number\": $pr_number, \"state\": \"$current_state\", \"lifecycle_state\": \"$lifecycle_state\", \"mergeable\": \"$mergeable\", \"ci\": \"$ci_conclusion\", \"review\": \"$review_decision\"}" \
        "git-poller"

    log_debug "Completed polling PR #$pr_number"
}

# Poll all PRs that need polling
poll_all() {
    local default_interval
    default_interval=$(config_get 'pr_lifecycle.poll_interval' "$DEFAULT_POLL_INTERVAL")

    local prs_to_poll
    prs_to_poll=$(db_pr_watches_needing_poll "$default_interval")

    local count
    count=$(echo "$prs_to_poll" | jq 'length')

    if [[ "$count" == "0" || -z "$count" ]]; then
        log_trace "No PRs need polling"
        return 0
    fi

    log_debug "Polling $count PRs"

    echo "$prs_to_poll" | jq -c '.[]' | while read -r pr; do
        local pr_number
        pr_number=$(echo "$pr" | jq -r '.pr_number')

        poll_pr "$pr_number" || true
    done
}

# ============================================================
# Daemon management
# ============================================================

start_daemon() {
    if is_running; then
        log_warn "Git poller is already running"
        return 1
    fi

    log_info "Starting git poller daemon..."

    # Daemonize
    nohup bash -c "
        source '$ROOT_DIR/lib/utils.sh'
        source '$ROOT_DIR/lib/log.sh'
        source '$ROOT_DIR/lib/config.sh'
        source '$ROOT_DIR/lib/db.sh'
        source '$ROOT_DIR/lib/blackboard.sh'
        source '$ROOT_DIR/lib/git.sh'

        db_init '$DATA_DIR'

        echo \$\$ > '$POLLER_PID_FILE'

        log_info '[git-poller] Daemon started: PID=\$\$'

        while true; do
            # Source the poll function
            source '$SCRIPT_DIR/git-poller.sh'
            poll_all

            sleep ${DEFAULT_POLL_INTERVAL}
        done
    " >> "$POLLER_LOG_FILE" 2>&1 &

    sleep 1

    if is_running; then
        log_info "Git poller started (PID: $(cat "$POLLER_PID_FILE"))"
    else
        log_error "Failed to start git poller"
        return 1
    fi
}

stop_daemon() {
    if ! is_running; then
        log_warn "Git poller is not running"
        return 0
    fi

    local pid
    pid=$(cat "$POLLER_PID_FILE")

    log_info "Stopping git poller (PID: $pid)..."
    kill "$pid" 2>/dev/null || true

    # Wait for process to exit
    local timeout=10
    while [[ $timeout -gt 0 ]] && kill -0 "$pid" 2>/dev/null; do
        sleep 1
        ((timeout--))
    done

    if kill -0 "$pid" 2>/dev/null; then
        log_warn "Force killing git poller"
        kill -9 "$pid" 2>/dev/null || true
    fi

    rm -f "$POLLER_PID_FILE"
    log_info "Git poller stopped"
}

is_running() {
    if [[ -f "$POLLER_PID_FILE" ]]; then
        local pid
        pid=$(cat "$POLLER_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

show_status() {
    if is_running; then
        local pid
        pid=$(cat "$POLLER_PID_FILE")
        echo "Git poller is running (PID: $pid)"

        # Show stats
        local pr_count
        pr_count=$(db_scalar "SELECT COUNT(*) FROM pr_watches WHERE state NOT IN ('merged', 'closed')" 2>/dev/null || echo "0")
        echo "Active PR watches: $pr_count"
    else
        echo "Git poller is not running"
    fi
}

# ============================================================
# Main
# ============================================================

main() {
    local cmd="${1:-}"
    shift || true

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --data-dir)
                DATA_DIR="$2"
                shift 2
                ;;
            --pr)
                PR_NUMBER="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    # Set defaults
    DATA_DIR="${DATA_DIR:-$(ct_data_dir)}"
    POLLER_PID_FILE="$DATA_DIR/git-poller.pid"
    POLLER_LOG_FILE="$DATA_DIR/logs/git-poller.log"

    # Ensure log directory exists
    mkdir -p "$(dirname "$POLLER_LOG_FILE")"

    # Initialize database
    db_init "$DATA_DIR"

    case "$cmd" in
        start)
            start_daemon
            ;;
        stop)
            stop_daemon
            ;;
        status)
            show_status
            ;;
        tick)
            if [[ -n "${PR_NUMBER:-}" ]]; then
                poll_pr "$PR_NUMBER"
            else
                poll_all
            fi
            ;;
        *)
            echo "Usage: $0 {start|stop|status|tick} [--data-dir DIR] [--pr NUMBER]"
            exit 1
            ;;
    esac
}

# Only run main if this script is being executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
