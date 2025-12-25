#!/usr/bin/env bash
#
# groups.sh - Thread grouping and consolidated PR creation for claude-threads
#
# Enables grouping threads by time window, epic, parent, or manual assignment.
# Supports consolidated PR creation when all threads in a group complete.
#
# Usage:
#   source lib/groups.sh
#   group_init "$DATA_DIR"
#   group_create "my-group" "time_window" "consolidated"
#   group_add_thread "$group_id" "$thread_id"
#

# Prevent double-sourcing
[[ -n "${_CT_GROUPS_LOADED:-}" ]] && return 0
_CT_GROUPS_LOADED=1

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/db.sh"
source "$(dirname "${BASH_SOURCE[0]}")/git.sh"
source "$(dirname "${BASH_SOURCE[0]}")/blackboard.sh"

# ============================================================
# Configuration
# ============================================================

_GROUPS_INITIALIZED=0

# ============================================================
# Initialization
# ============================================================

group_init() {
    local data_dir="${1:-$(ct_data_dir)}"
    _GROUPS_INITIALIZED=1
    log_debug "Groups library initialized"
}

group_check() {
    if [[ $_GROUPS_INITIALIZED -ne 1 ]]; then
        group_init
    fi
}

# ============================================================
# Group Creation
# ============================================================

# Create a new thread group
# Args: name, type (epic|parent|manual|time_window), pr_strategy (individual|consolidated)
group_create() {
    group_check
    local name="$1"
    local grouping_type="${2:-time_window}"
    local pr_strategy="${3:-}"

    # Get default strategy from config if not provided
    if [[ -z "$pr_strategy" ]]; then
        pr_strategy=$(config_get 'thread_groups.default_pr_strategy' 'individual')
    fi

    # Generate group ID
    local id
    id="group-$(date +%s)-$(head -c 4 /dev/urandom | xxd -p)"

    # For time_window groups, set window start/end
    local window_start="" window_end=""
    if [[ "$grouping_type" == "time_window" ]]; then
        local window_minutes
        window_minutes=$(config_get 'thread_groups.time_window_minutes' '60')
        window_start=$(date -u '+%Y-%m-%d %H:%M:%S')
        window_end=$(date -u -v+${window_minutes}M '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
                     date -u -d "+${window_minutes} minutes" '+%Y-%m-%d %H:%M:%S')
    fi

    # Insert into database
    db_exec "INSERT INTO thread_groups (id, name, grouping_type, pr_strategy, time_window_start, time_window_end)
             VALUES (
                $(db_quote "$id"),
                $(db_quote "$name"),
                $(db_quote "$grouping_type"),
                $(db_quote "$pr_strategy"),
                $(db_quote "$window_start"),
                $(db_quote "$window_end")
             )"

    log_info "Group created: $id ($name, type=$grouping_type, pr_strategy=$pr_strategy)"

    bb_publish "GROUP_CREATED" "{\"group_id\": \"$id\", \"name\": \"$name\", \"type\": \"$grouping_type\"}" "orchestrator"

    echo "$id"
}

# ============================================================
# Group Membership
# ============================================================

# Add thread to a group
group_add_thread() {
    group_check
    local group_id="$1"
    local thread_id="$2"
    local merge_order="${3:-}"

    # Get next merge order if not provided
    if [[ -z "$merge_order" ]]; then
        merge_order=$(db_scalar "SELECT COALESCE(MAX(merge_order), 0) + 1
                                 FROM thread_group_members
                                 WHERE group_id = $(db_quote "$group_id")")
    fi

    # Get thread's branch
    local branch
    branch=$(db_scalar "SELECT branch FROM worktrees WHERE thread_id = $(db_quote "$thread_id")")

    # Insert membership
    db_exec "INSERT OR REPLACE INTO thread_group_members (thread_id, group_id, merge_order, branch)
             VALUES (
                $(db_quote "$thread_id"),
                $(db_quote "$group_id"),
                $merge_order,
                $(db_quote "$branch")
             )"

    # Update thread's group_id
    db_exec "UPDATE threads SET group_id = $(db_quote "$group_id") WHERE id = $(db_quote "$thread_id")"

    log_info "Thread $thread_id added to group $group_id (order: $merge_order)"

    bb_publish "GROUP_MEMBER_ADDED" "{\"group_id\": \"$group_id\", \"thread_id\": \"$thread_id\"}" "orchestrator"
}

# Remove thread from group
group_remove_thread() {
    group_check
    local group_id="$1"
    local thread_id="$2"

    db_exec "DELETE FROM thread_group_members
             WHERE group_id = $(db_quote "$group_id")
             AND thread_id = $(db_quote "$thread_id")"

    db_exec "UPDATE threads SET group_id = NULL WHERE id = $(db_quote "$thread_id")"

    log_info "Thread $thread_id removed from group $group_id"
}

# ============================================================
# Auto-Grouping
# ============================================================

# Find or create appropriate group for a new thread
# Based on time_window grouping strategy
group_auto_assign() {
    group_check
    local thread_id="$1"
    local thread_name="$2"

    # Check if grouping is enabled
    local enabled
    enabled=$(config_get 'thread_groups.enabled' 'true')
    if [[ "$enabled" != "true" ]]; then
        return 0
    fi

    local default_grouping
    default_grouping=$(config_get 'thread_groups.default_grouping' 'time_window')

    case "$default_grouping" in
        time_window)
            _group_auto_time_window "$thread_id" "$thread_name"
            ;;
        epic)
            # Extract epic from thread name (e.g., "epic-123-*")
            if [[ "$thread_name" =~ ^epic-([0-9]+) ]]; then
                local epic_id="${BASH_REMATCH[1]}"
                _group_auto_epic "$thread_id" "$epic_id"
            fi
            ;;
        parent)
            # Group by parent thread if spawned
            local parent_id
            parent_id=$(db_scalar "SELECT json_extract(context, '\$.parent_thread')
                                   FROM threads WHERE id = $(db_quote "$thread_id")")
            if [[ -n "$parent_id" && "$parent_id" != "null" ]]; then
                _group_auto_parent "$thread_id" "$parent_id"
            fi
            ;;
        none|manual)
            # No auto-grouping
            return 0
            ;;
    esac
}

# Auto-assign to time window group
_group_auto_time_window() {
    local thread_id="$1"
    local thread_name="$2"

    # Find active time window group
    local group_id
    group_id=$(db_scalar "SELECT id FROM v_active_time_windows LIMIT 1")

    if [[ -z "$group_id" ]]; then
        # Create new time window group
        local group_name="time-window-$(date +%Y%m%d-%H%M)"
        group_id=$(group_create "$group_name" "time_window")
    fi

    if [[ -n "$group_id" ]]; then
        group_add_thread "$group_id" "$thread_id"
    fi
}

# Auto-assign to epic group
_group_auto_epic() {
    local thread_id="$1"
    local epic_id="$2"

    # Find existing epic group
    local group_id
    group_id=$(db_scalar "SELECT id FROM thread_groups
                          WHERE grouping_type = 'epic'
                          AND name LIKE 'epic-$epic_id%'
                          AND status = 'active'
                          LIMIT 1")

    if [[ -z "$group_id" ]]; then
        group_id=$(group_create "epic-$epic_id" "epic")
    fi

    if [[ -n "$group_id" ]]; then
        group_add_thread "$group_id" "$thread_id"
    fi
}

# Auto-assign to parent group
_group_auto_parent() {
    local thread_id="$1"
    local parent_id="$2"

    # Find or create group for parent
    local group_id
    group_id=$(db_scalar "SELECT id FROM thread_groups
                          WHERE grouping_type = 'parent'
                          AND name = 'parent-$parent_id'
                          AND status = 'active'
                          LIMIT 1")

    if [[ -z "$group_id" ]]; then
        group_id=$(group_create "parent-$parent_id" "parent")
    fi

    if [[ -n "$group_id" ]]; then
        group_add_thread "$group_id" "$thread_id"
    fi
}

# ============================================================
# Group Status & Queries
# ============================================================

# Get group info
group_get() {
    group_check
    local group_id="$1"
    db_query "SELECT * FROM v_thread_groups WHERE id = $(db_quote "$group_id")" | jq '.[0]'
}

# List all groups
group_list() {
    group_check
    local status="${1:-}"

    if [[ -n "$status" ]]; then
        db_query "SELECT * FROM v_thread_groups WHERE status = $(db_quote "$status")"
    else
        db_query "SELECT * FROM v_thread_groups"
    fi
}

# Get group members
group_members() {
    group_check
    local group_id="$1"

    db_query "SELECT m.*, t.name as thread_name, t.status as thread_status
              FROM thread_group_members m
              JOIN threads t ON m.thread_id = t.id
              WHERE m.group_id = $(db_quote "$group_id")
              ORDER BY m.merge_order"
}

# Check if group is ready for consolidated PR
group_check_ready() {
    group_check
    local group_id="$1"

    # Get group info
    local group_json
    group_json=$(group_get "$group_id")

    local pr_strategy status
    pr_strategy=$(echo "$group_json" | jq -r '.pr_strategy // "individual"')
    status=$(echo "$group_json" | jq -r '.status // "active"')

    # Individual strategy doesn't need group PR
    if [[ "$pr_strategy" == "individual" ]]; then
        return 1
    fi

    # Check if already processed
    if [[ "$status" != "active" && "$status" != "completing" ]]; then
        return 1
    fi

    # Check if all members are completed
    local pending_count
    pending_count=$(db_scalar "SELECT COUNT(*) FROM thread_group_members m
                               JOIN threads t ON m.thread_id = t.id
                               WHERE m.group_id = $(db_quote "$group_id")
                               AND t.status NOT IN ('completed', 'failed')")

    if [[ "$pending_count" -eq 0 ]]; then
        # All complete, update status
        db_exec "UPDATE thread_groups SET status = 'pr_pending' WHERE id = $(db_quote "$group_id")"
        return 0
    fi

    return 1
}

# ============================================================
# Consolidated PR Creation
# ============================================================

# Create consolidated PR for a group
group_create_consolidated_pr() {
    group_check
    local group_id="$1"

    # Get group info
    local group_json
    group_json=$(group_get "$group_id")

    if [[ -z "$group_json" || "$group_json" == "null" ]]; then
        log_error "Group not found: $group_id"
        return 1
    fi

    local group_name pr_strategy
    group_name=$(echo "$group_json" | jq -r '.name')
    pr_strategy=$(echo "$group_json" | jq -r '.pr_strategy')

    if [[ "$pr_strategy" != "consolidated" ]]; then
        log_warn "Group $group_id does not use consolidated PR strategy"
        return 1
    fi

    # Get target branch from config
    local target_branch
    target_branch=$(config_get 'merge.target_branch' 'main')

    # Create consolidated branch name
    local consolidated_branch="consolidated/$group_name"

    log_info "Creating consolidated PR for group $group_id: $consolidated_branch -> $target_branch"

    # Get main repo
    local main_repo="${CT_PROJECT_ROOT:-$(pwd)}"
    cd "$main_repo" || return 1

    # Fetch latest target branch
    git fetch origin "$target_branch" 2>/dev/null || true

    # Create consolidated branch from target
    git checkout -B "$consolidated_branch" "origin/$target_branch" 2>/dev/null || {
        log_error "Failed to create consolidated branch"
        return 1
    }

    # Get merge method from config
    local merge_method
    merge_method=$(config_get 'thread_groups.consolidated_merge_method' 'merge')

    # Merge each member's branch
    local members
    members=$(group_members "$group_id")

    local merge_failed=0
    local merged_count=0
    local all_commits=""

    echo "$members" | jq -c '.[]' | while read -r member; do
        local thread_id thread_name branch merge_status
        thread_id=$(echo "$member" | jq -r '.thread_id')
        thread_name=$(echo "$member" | jq -r '.thread_name')
        branch=$(echo "$member" | jq -r '.branch // empty')
        merge_status=$(echo "$member" | jq -r '.merge_status')

        if [[ -z "$branch" ]]; then
            log_warn "Thread $thread_id has no branch, skipping"
            db_exec "UPDATE thread_group_members SET merge_status = 'skipped'
                     WHERE thread_id = $(db_quote "$thread_id") AND group_id = $(db_quote "$group_id")"
            continue
        fi

        # Fetch branch
        git fetch origin "$branch" 2>/dev/null || {
            log_warn "Could not fetch branch $branch"
            continue
        }

        # Try to merge
        log_info "Merging $branch ($thread_name) into consolidated branch"

        local merge_result=0
        case "$merge_method" in
            merge)
                git merge "origin/$branch" -m "Merge $thread_name ($branch)" --no-edit || merge_result=$?
                ;;
            rebase)
                git rebase "origin/$branch" || merge_result=$?
                ;;
            squash_all)
                git merge --squash "origin/$branch" || merge_result=$?
                [[ $merge_result -eq 0 ]] && git commit -m "Squash merge: $thread_name" --no-edit || merge_result=$?
                ;;
        esac

        if [[ $merge_result -ne 0 ]]; then
            log_error "Merge conflict with $branch"
            git merge --abort 2>/dev/null || git rebase --abort 2>/dev/null || true
            db_exec "UPDATE thread_group_members SET merge_status = 'conflict'
                     WHERE thread_id = $(db_quote "$thread_id") AND group_id = $(db_quote "$group_id")"
            merge_failed=1
            break
        fi

        # Mark as merged
        db_exec "UPDATE thread_group_members SET merge_status = 'merged', merged_at = datetime('now')
                 WHERE thread_id = $(db_quote "$thread_id") AND group_id = $(db_quote "$group_id")"
        merged_count=$((merged_count + 1))

        # Collect commit info
        local commits
        commits=$(git log "origin/$target_branch..origin/$branch" --pretty=format:"- %s" 2>/dev/null | head -10)
        all_commits="${all_commits}\n### $thread_name\n$commits\n"
    done

    if [[ $merge_failed -ne 0 ]]; then
        log_error "Consolidated merge failed due to conflicts"
        git checkout "$target_branch" 2>/dev/null || true
        git branch -D "$consolidated_branch" 2>/dev/null || true

        bb_publish "GROUP_MERGE_CONFLICT" "{\"group_id\": \"$group_id\"}" "orchestrator"
        return 1
    fi

    # Push consolidated branch
    if ! git push -u origin "$consolidated_branch" --force; then
        log_error "Failed to push consolidated branch"
        return 1
    fi

    # Create PR
    if ! command -v gh &>/dev/null; then
        log_error "GitHub CLI (gh) not found"
        return 1
    fi

    # Generate PR body
    local pr_body
    pr_body=$(cat <<EOF
## Consolidated PR: $group_name

This PR combines work from multiple threads:

$(echo "$members" | jq -r '.[] | "- \(.thread_name) (\(.branch // "no branch"))"')

## Changes

$(echo -e "$all_commits")

## Merged Threads

| Thread | Status |
|--------|--------|
$(echo "$members" | jq -r '.[] | "| \(.thread_name) | \(.merge_status) |"')

---
*Created automatically by claude-threads*
EOF
)

    local pr_url
    pr_url=$(gh pr create \
        --base "$target_branch" \
        --head "$consolidated_branch" \
        --title "Consolidated: $group_name" \
        --body "$pr_body" 2>&1)

    if [[ $? -ne 0 ]]; then
        log_error "Failed to create consolidated PR: $pr_url"
        return 1
    fi

    # Extract PR number
    local pr_number
    pr_number=$(echo "$pr_url" | grep -oE '[0-9]+$' || echo "")

    log_info "Created consolidated PR: $pr_url"

    # Update group with PR info
    db_exec "UPDATE thread_groups SET
                status = 'pr_created',
                consolidated_pr_number = ${pr_number:-0},
                consolidated_branch = $(db_quote "$consolidated_branch")
             WHERE id = $(db_quote "$group_id")"

    bb_publish "GROUP_PR_CREATED" "{\"group_id\": \"$group_id\", \"pr_number\": ${pr_number:-0}, \"pr_url\": \"$pr_url\"}" "orchestrator"

    # Return to original branch
    git checkout "$target_branch" 2>/dev/null || true

    return 0
}

# ============================================================
# Group Lifecycle
# ============================================================

# Mark member as complete (called when thread completes)
group_member_complete() {
    group_check
    local thread_id="$1"

    # Get group for this thread
    local group_id
    group_id=$(db_scalar "SELECT group_id FROM threads WHERE id = $(db_quote "$thread_id")")

    if [[ -z "$group_id" || "$group_id" == "null" ]]; then
        return 0
    fi

    # Update branch info in case it changed
    local branch
    branch=$(db_scalar "SELECT branch FROM worktrees WHERE thread_id = $(db_quote "$thread_id")")
    if [[ -n "$branch" ]]; then
        db_exec "UPDATE thread_group_members SET branch = $(db_quote "$branch")
                 WHERE thread_id = $(db_quote "$thread_id") AND group_id = $(db_quote "$group_id")"
    fi

    log_info "Thread $thread_id completed in group $group_id"

    # Check if group is ready for PR
    if group_check_ready "$group_id"; then
        log_info "Group $group_id is ready for consolidated PR"

        # Check trigger configuration
        local trigger
        trigger=$(config_get 'thread_groups.consolidated_pr_trigger' 'all_complete')

        if [[ "$trigger" == "all_complete" ]]; then
            group_create_consolidated_pr "$group_id"
        fi
    fi
}

# Close a time window group (no more threads can join)
group_close_window() {
    group_check
    local group_id="$1"

    db_exec "UPDATE thread_groups SET
                time_window_end = datetime('now'),
                status = 'completing'
             WHERE id = $(db_quote "$group_id")"

    log_info "Time window closed for group: $group_id"
}

# Abandon a group
group_abandon() {
    group_check
    local group_id="$1"

    db_exec "UPDATE thread_groups SET status = 'abandoned' WHERE id = $(db_quote "$group_id")"
    db_exec "UPDATE thread_group_members SET merge_status = 'skipped'
             WHERE group_id = $(db_quote "$group_id") AND merge_status = 'pending'"

    log_info "Group abandoned: $group_id"

    bb_publish "GROUP_ABANDONED" "{\"group_id\": \"$group_id\"}" "orchestrator"
}

# Complete a group (after PR merged)
group_complete() {
    group_check
    local group_id="$1"

    db_exec "UPDATE thread_groups SET status = 'completed' WHERE id = $(db_quote "$group_id")"

    log_info "Group completed: $group_id"

    bb_publish "GROUP_COMPLETED" "{\"group_id\": \"$group_id\"}" "orchestrator"
}

# ============================================================
# Cleanup
# ============================================================

# Cleanup old/abandoned groups
group_cleanup() {
    group_check
    local days="${1:-30}"

    db_exec "DELETE FROM thread_groups
             WHERE status IN ('completed', 'abandoned')
             AND updated_at < datetime('now', '-$days days')"

    log_info "Cleaned up groups older than $days days"
}

# Close expired time windows
group_close_expired_windows() {
    group_check

    local expired
    expired=$(db_query "SELECT id FROM thread_groups
                        WHERE grouping_type = 'time_window'
                        AND status = 'active'
                        AND datetime(time_window_end) < datetime('now')")

    echo "$expired" | jq -r '.[].id' 2>/dev/null | while read -r group_id; do
        if [[ -n "$group_id" ]]; then
            group_close_window "$group_id"
        fi
    done
}
