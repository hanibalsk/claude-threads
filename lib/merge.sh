#!/usr/bin/env bash
#
# merge.sh - Merge strategy implementations for claude-threads
#
# Handles merging completed thread work back to target branches
# using configurable strategies (direct, PR, or none).
#
# Usage:
#   source lib/merge.sh
#   merge_init "$DATA_DIR"
#   merge_on_complete "$thread_id"
#

# Prevent double-sourcing
[[ -n "${_CT_MERGE_LOADED:-}" ]] && return 0
_CT_MERGE_LOADED=1

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

_MERGE_INITIALIZED=0

# ============================================================
# Initialization
# ============================================================

merge_init() {
    local data_dir="${1:-$(ct_data_dir)}"
    _MERGE_INITIALIZED=1
    log_debug "Merge library initialized"
}

merge_check() {
    if [[ $_MERGE_INITIALIZED -ne 1 ]]; then
        merge_init
    fi
}

# ============================================================
# Main Entry Point
# ============================================================

# Handle merge on thread completion
# Called by thread-runner when a thread completes successfully
merge_on_complete() {
    merge_check
    local thread_id="$1"

    # Get thread info
    local thread_json
    thread_json=$(db_thread_get "$thread_id")

    if [[ -z "$thread_json" || "$thread_json" == "null" ]]; then
        log_error "Thread not found: $thread_id"
        return 1
    fi

    local worktree branch name
    worktree=$(echo "$thread_json" | jq -r '.worktree // empty')
    name=$(echo "$thread_json" | jq -r '.name')

    # Check if thread has a worktree
    if [[ -z "$worktree" ]]; then
        log_debug "Thread $thread_id has no worktree, skipping merge"
        return 0
    fi

    # Get worktree info
    local worktree_json
    worktree_json=$(db_query "SELECT * FROM worktrees WHERE thread_id = $(db_quote "$thread_id")" | jq '.[0] // empty')

    if [[ -z "$worktree_json" || "$worktree_json" == "null" ]]; then
        log_warn "Worktree info not found for thread $thread_id"
        return 0
    fi

    branch=$(echo "$worktree_json" | jq -r '.branch')
    local commits_ahead
    commits_ahead=$(echo "$worktree_json" | jq -r '.commits_ahead // 0')

    # Check if there are commits to merge
    if [[ "$commits_ahead" -eq 0 ]]; then
        log_info "No commits to merge for thread $thread_id"
        return 0
    fi

    # Get merge strategy from config
    local strategy target_branch
    strategy=$(config_get 'merge.strategy' 'pr')
    target_branch=$(config_get 'merge.target_branch' 'main')

    log_info "Merging thread $thread_id: strategy=$strategy, branch=$branch, target=$target_branch"

    case "$strategy" in
        direct)
            merge_direct "$thread_id" "$worktree" "$branch" "$target_branch" "$name"
            ;;
        pr)
            merge_create_pr "$thread_id" "$worktree" "$branch" "$target_branch" "$name"
            ;;
        none)
            log_info "Merge strategy is 'none', leaving branch $branch as-is"
            bb_publish "MERGE_SKIPPED" "{\"thread_id\": \"$thread_id\", \"branch\": \"$branch\", \"reason\": \"strategy_none\"}" "$thread_id"
            ;;
        *)
            log_error "Unknown merge strategy: $strategy"
            return 1
            ;;
    esac
}

# ============================================================
# Direct Merge Strategy
# ============================================================

# Merge branch directly into target (single-repo workflow)
merge_direct() {
    local thread_id="$1"
    local worktree="$2"
    local branch="$3"
    local target_branch="$4"
    local thread_name="$5"

    local method
    method=$(config_get 'merge.direct_method' 'merge')

    log_info "Direct merge: $branch -> $target_branch (method=$method)"

    # Ensure we're in the main repo, not the worktree
    local main_repo
    main_repo="${CT_PROJECT_ROOT:-$(pwd)}"

    # First, ensure branch is pushed
    if ! _merge_ensure_pushed "$worktree" "$branch"; then
        log_error "Failed to push branch $branch"
        _merge_handle_failure "$thread_id" "$branch" "push_failed"
        return 1
    fi

    # Checkout target branch in main repo
    cd "$main_repo" || return 1

    # Fetch latest
    git fetch origin "$target_branch" 2>/dev/null || true
    git fetch origin "$branch" 2>/dev/null || true

    # Check for conflicts before merging
    if ! _merge_check_conflicts "$branch" "$target_branch"; then
        log_warn "Merge conflict detected between $branch and $target_branch"
        _merge_handle_conflict "$thread_id" "$branch" "$target_branch"
        return 1
    fi

    # Perform merge based on method
    local merge_result=0
    case "$method" in
        merge)
            git checkout "$target_branch" 2>/dev/null || git checkout -b "$target_branch" "origin/$target_branch"
            git merge "origin/$branch" -m "Merge $branch: $thread_name" || merge_result=$?
            ;;
        rebase)
            git checkout "$target_branch" 2>/dev/null || git checkout -b "$target_branch" "origin/$target_branch"
            git rebase "origin/$branch" || merge_result=$?
            ;;
        squash)
            git checkout "$target_branch" 2>/dev/null || git checkout -b "$target_branch" "origin/$target_branch"
            local squash_msg
            squash_msg=$(_merge_format_squash_message "$thread_name" "$thread_id" "$branch")
            git merge --squash "origin/$branch" || merge_result=$?
            if [[ $merge_result -eq 0 ]]; then
                git commit -m "$squash_msg" || merge_result=$?
            fi
            ;;
    esac

    if [[ $merge_result -ne 0 ]]; then
        log_error "Merge failed for $branch -> $target_branch"
        git merge --abort 2>/dev/null || true
        git rebase --abort 2>/dev/null || true
        _merge_handle_failure "$thread_id" "$branch" "merge_failed"
        return 1
    fi

    # Push merged changes
    if ! git push origin "$target_branch"; then
        log_error "Failed to push merged changes"
        _merge_handle_failure "$thread_id" "$branch" "push_failed"
        return 1
    fi

    log_info "Successfully merged $branch into $target_branch"

    # Publish success event
    bb_publish "MERGE_COMPLETED" "{\"thread_id\": \"$thread_id\", \"branch\": \"$branch\", \"target\": \"$target_branch\", \"method\": \"$method\"}" "$thread_id"

    # Optionally delete the merged branch
    local delete_branch
    delete_branch=$(config_get 'merge.pr_delete_branch' 'true')
    if [[ "$delete_branch" == "true" ]]; then
        git push origin --delete "$branch" 2>/dev/null || log_warn "Could not delete branch $branch"
        log_info "Deleted merged branch: $branch"
    fi

    return 0
}

# ============================================================
# PR Strategy
# ============================================================

# Create a pull request for the completed thread
merge_create_pr() {
    local thread_id="$1"
    local worktree="$2"
    local branch="$3"
    local target_branch="$4"
    local thread_name="$5"

    log_info "Creating PR: $branch -> $target_branch"

    # Ensure branch is pushed
    if ! _merge_ensure_pushed "$worktree" "$branch"; then
        log_error "Failed to push branch $branch"
        _merge_handle_failure "$thread_id" "$branch" "push_failed"
        return 1
    fi

    # Check if gh CLI is available
    if ! command -v gh &>/dev/null; then
        log_error "GitHub CLI (gh) not found, cannot create PR"
        _merge_handle_failure "$thread_id" "$branch" "gh_not_found"
        return 1
    fi

    # Check if PR already exists
    local existing_pr
    existing_pr=$(gh pr list --head "$branch" --base "$target_branch" --json number --jq '.[0].number' 2>/dev/null || echo "")

    if [[ -n "$existing_pr" ]]; then
        log_info "PR #$existing_pr already exists for branch $branch"
        bb_publish "PR_EXISTS" "{\"thread_id\": \"$thread_id\", \"branch\": \"$branch\", \"pr_number\": $existing_pr}" "$thread_id"
        return 0
    fi

    # Generate PR title and body
    local pr_title pr_body
    pr_title="$thread_name"
    pr_body=$(_merge_generate_pr_body "$thread_id" "$thread_name" "$branch")

    # Create the PR
    local pr_url pr_number
    pr_url=$(gh pr create \
        --base "$target_branch" \
        --head "$branch" \
        --title "$pr_title" \
        --body "$pr_body" 2>&1)

    if [[ $? -ne 0 ]]; then
        log_error "Failed to create PR: $pr_url"
        _merge_handle_failure "$thread_id" "$branch" "pr_create_failed"
        return 1
    fi

    # Extract PR number from URL
    pr_number=$(echo "$pr_url" | grep -oE '[0-9]+$' || echo "")

    log_info "Created PR: $pr_url"

    # Store PR info in database
    if [[ -n "$pr_number" ]]; then
        # Check if pr_watches table exists
        if db_scalar "SELECT 1 FROM sqlite_master WHERE type='table' AND name='pr_watches'" 2>/dev/null | grep -q 1; then
            db_exec "INSERT OR REPLACE INTO pr_watches (pr_number, branch, base_branch, thread_id, state)
                     VALUES ($pr_number, $(db_quote "$branch"), $(db_quote "$target_branch"), $(db_quote "$thread_id"), 'open')"
        fi
    fi

    # Publish event
    bb_publish "PR_CREATED" "{\"thread_id\": \"$thread_id\", \"branch\": \"$branch\", \"target\": \"$target_branch\", \"pr_number\": ${pr_number:-0}, \"pr_url\": \"$pr_url\"}" "$thread_id"

    # Check if auto-merge is enabled
    local auto_merge
    auto_merge=$(config_get 'merge.pr_auto_merge' 'false')

    if [[ "$auto_merge" == "true" ]]; then
        log_info "Enabling auto-merge for PR #$pr_number"
        gh pr merge "$pr_number" --auto --merge 2>/dev/null || log_warn "Could not enable auto-merge"
    fi

    return 0
}

# ============================================================
# Helper Functions
# ============================================================

# Ensure branch is pushed to remote
_merge_ensure_pushed() {
    local worktree="$1"
    local branch="$2"

    cd "$worktree" || return 1

    # Check if there are unpushed commits
    local unpushed
    unpushed=$(git log "origin/$branch..$branch" --oneline 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$unpushed" -gt 0 ]]; then
        log_info "Pushing $unpushed commits to $branch"
        if ! git push -u origin "$branch"; then
            return 1
        fi
    fi

    return 0
}

# Check for merge conflicts
_merge_check_conflicts() {
    local source_branch="$1"
    local target_branch="$2"

    # Try a dry-run merge
    git merge-tree $(git merge-base "origin/$target_branch" "origin/$source_branch") \
        "origin/$target_branch" "origin/$source_branch" 2>/dev/null | grep -q "^<<<<<<<" && return 1

    return 0
}

# Handle merge conflict based on config
_merge_handle_conflict() {
    local thread_id="$1"
    local branch="$2"
    local target_branch="$3"

    local on_conflict
    on_conflict=$(config_get 'merge.on_conflict' 'block')

    case "$on_conflict" in
        block)
            log_warn "Blocking thread due to merge conflict"
            db_thread_set_status "$thread_id" "blocked"
            bb_publish "MERGE_CONFLICT_DETECTED" "{\"thread_id\": \"$thread_id\", \"branch\": \"$branch\", \"target_branch\": \"$target_branch\"}" "$thread_id"
            ;;
        resolve)
            log_info "Spawning conflict resolver agent"
            bb_publish "MERGE_CONFLICT_DETECTED" "{\"thread_id\": \"$thread_id\", \"branch\": \"$branch\", \"target_branch\": \"$target_branch\", \"action\": \"spawn_resolver\"}" "$thread_id"
            ;;
        notify)
            log_warn "Merge conflict detected, notifying user"
            bb_publish "MERGE_CONFLICT_DETECTED" "{\"thread_id\": \"$thread_id\", \"branch\": \"$branch\", \"target_branch\": \"$target_branch\", \"action\": \"notify\"}" "$thread_id"
            ;;
    esac
}

# Handle merge failure
_merge_handle_failure() {
    local thread_id="$1"
    local branch="$2"
    local reason="$3"

    bb_publish "MERGE_FAILED" "{\"thread_id\": \"$thread_id\", \"branch\": \"$branch\", \"reason\": \"$reason\"}" "$thread_id"
}

# Format squash commit message
_merge_format_squash_message() {
    local thread_name="$1"
    local thread_id="$2"
    local branch="$3"

    local template
    template=$(config_get 'merge.squash_message_template' 'feat: {thread_name}')

    # Get commit summary from branch
    local summary
    summary=$(git log "origin/main..origin/$branch" --pretty=format:"- %s" 2>/dev/null | head -10)

    # Replace placeholders
    template="${template//\{thread_name\}/$thread_name}"
    template="${template//\{thread_id\}/$thread_id}"
    template="${template//\{branch\}/$branch}"
    template="${template//\{summary\}/$summary}"

    echo "$template"
}

# Generate PR body
_merge_generate_pr_body() {
    local thread_id="$1"
    local thread_name="$2"
    local branch="$3"

    # Get commit list
    local commits
    commits=$(git log "origin/main..origin/$branch" --pretty=format:"- %s" 2>/dev/null | head -20)

    cat <<EOF
## Summary
Thread: $thread_name
Thread ID: $thread_id

## Changes
$commits

## Test Plan
- [ ] Tests pass
- [ ] Code review completed

---
*Created automatically by claude-threads*
EOF
}

# ============================================================
# Manual Merge Commands
# ============================================================

# Manually trigger merge for a thread
merge_thread() {
    merge_check
    local thread_id="$1"
    local strategy="${2:-}"

    if [[ -z "$strategy" ]]; then
        strategy=$(config_get 'merge.strategy' 'pr')
    fi

    # Temporarily override strategy
    local original_strategy
    original_strategy=$(config_get 'merge.strategy' 'pr')

    # This is a simple approach - for more complex override, we'd need
    # to pass strategy as parameter through the merge functions
    log_info "Manually merging thread $thread_id with strategy: $strategy"

    merge_on_complete "$thread_id"
}

# Get merge status for a thread
merge_status() {
    merge_check
    local thread_id="$1"

    local thread_json
    thread_json=$(db_thread_get "$thread_id")

    if [[ -z "$thread_json" || "$thread_json" == "null" ]]; then
        echo "Thread not found: $thread_id"
        return 1
    fi

    local branch
    branch=$(db_query "SELECT branch FROM worktrees WHERE thread_id = $(db_quote "$thread_id")" | jq -r '.[0].branch // empty')

    if [[ -z "$branch" ]]; then
        echo "No worktree branch for thread"
        return 0
    fi

    echo "Branch: $branch"

    # Check if PR exists
    if command -v gh &>/dev/null; then
        local pr_info
        pr_info=$(gh pr list --head "$branch" --json number,state,url --jq '.[0]' 2>/dev/null || echo "")

        if [[ -n "$pr_info" && "$pr_info" != "null" ]]; then
            local pr_number pr_state pr_url
            pr_number=$(echo "$pr_info" | jq -r '.number')
            pr_state=$(echo "$pr_info" | jq -r '.state')
            pr_url=$(echo "$pr_info" | jq -r '.url')

            echo "PR: #$pr_number ($pr_state)"
            echo "URL: $pr_url"
        else
            echo "PR: None"
        fi
    fi

    # Check merge events
    echo ""
    echo "Merge Events:"
    db_query "SELECT type, timestamp FROM events
              WHERE source = $(db_quote "$thread_id")
              AND type LIKE 'MERGE%' OR type LIKE 'PR_%'
              ORDER BY timestamp DESC LIMIT 5" | \
        jq -r '.[] | "  \(.timestamp) - \(.type)"' 2>/dev/null || echo "  (none)"
}
