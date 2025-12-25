#!/usr/bin/env bash
#
# git.sh - Git worktree management for claude-threads
#
# Provides functions for creating, managing, and cleaning up git worktrees
# to enable isolated parallel development per thread.
#
# Usage:
#   source lib/git.sh
#   git_worktree_create "thread-abc" "feature/abc" "main"
#   git_worktree_remove "thread-abc"
#

# Prevent double-sourcing
[[ -n "${_CT_GIT_LOADED:-}" ]] && return 0
_CT_GIT_LOADED=1

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

# ============================================================
# Configuration
# ============================================================

# Get worktrees base directory
git_worktrees_dir() {
    local data_dir
    data_dir=$(ct_data_dir)
    echo "$data_dir/worktrees"
}

# ============================================================
# Validation
# ============================================================

# Check if we're in a git repository
git_is_repo() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# Check if working directory is clean
git_is_clean() {
    local path="${1:-.}"
    (cd "$path" && git diff --quiet && git diff --cached --quiet) 2>/dev/null
}

# Check if a branch exists locally
git_branch_exists() {
    local branch="$1"
    git show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null
}

# Check if a branch exists on remote
git_remote_branch_exists() {
    local branch="$1"
    local remote="${2:-origin}"
    git ls-remote --exit-code --heads "$remote" "$branch" >/dev/null 2>&1
}

# Get current branch name
git_current_branch() {
    local path="${1:-.}"
    (cd "$path" && git rev-parse --abbrev-ref HEAD 2>/dev/null)
}

# Get repository root
git_repo_root() {
    git rev-parse --show-toplevel 2>/dev/null
}

# ============================================================
# Worktree Operations
# ============================================================

# Create a new worktree for a thread
# Usage: git_worktree_create <thread_id> <branch_name> <base_branch> [remote]
git_worktree_create() {
    local thread_id="$1"
    local branch_name="$2"
    local base_branch="${3:-main}"
    local remote="${4:-origin}"

    if [[ -z "$thread_id" || -z "$branch_name" ]]; then
        ct_error "Usage: git_worktree_create <thread_id> <branch_name> [base_branch] [remote]"
        return 1
    fi

    # Ensure we're in a git repo
    if ! git_is_repo; then
        ct_error "Not in a git repository"
        return 1
    fi

    local worktrees_dir
    worktrees_dir=$(git_worktrees_dir)
    local worktree_path="$worktrees_dir/$thread_id"

    # Check if worktree already exists
    if [[ -d "$worktree_path" ]]; then
        ct_warn "Worktree already exists: $worktree_path"
        echo "$worktree_path"
        return 0
    fi

    # Create worktrees directory
    mkdir -p "$worktrees_dir"

    # Fetch latest from remote
    ct_debug "Fetching from $remote..."
    git fetch "$remote" --prune 2>/dev/null || true

    # Ensure base branch is up to date
    if git_branch_exists "$base_branch"; then
        ct_debug "Updating local $base_branch..."
        git fetch "$remote" "$base_branch:$base_branch" 2>/dev/null || true
    fi

    # Create worktree with new branch
    ct_info "Creating worktree: $worktree_path (branch: $branch_name from $base_branch)"

    local git_result=0
    if git_branch_exists "$branch_name"; then
        # Branch exists, create worktree using existing branch
        git worktree add "$worktree_path" "$branch_name" >/dev/null 2>&1 || git_result=$?
    else
        # Create new branch from base
        git worktree add -b "$branch_name" "$worktree_path" "$base_branch" >/dev/null 2>&1 || git_result=$?
    fi

    if [[ $git_result -ne 0 ]]; then
        ct_error "Failed to create worktree (git exit code: $git_result)"
        return 1
    fi

    # Create metadata file
    cat > "$worktree_path/.worktree-info" <<EOF
thread_id: $thread_id
branch_name: $branch_name
base_branch: $base_branch
remote: $remote
created_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
status: active
EOF

    ct_info "Worktree created: $worktree_path"
    echo "$worktree_path"
}

# Remove a worktree
# Usage: git_worktree_remove <thread_id> [force]
git_worktree_remove() {
    local thread_id="$1"
    local force="${2:-false}"

    if [[ -z "$thread_id" ]]; then
        ct_error "Usage: git_worktree_remove <thread_id> [force]"
        return 1
    fi

    local worktrees_dir
    worktrees_dir=$(git_worktrees_dir)
    local worktree_path="$worktrees_dir/$thread_id"

    if [[ ! -d "$worktree_path" ]]; then
        ct_debug "Worktree not found: $worktree_path"
        return 0
    fi

    # Check for uncommitted changes
    if [[ "$force" != "true" ]] && ! git_is_clean "$worktree_path"; then
        ct_warn "Worktree has uncommitted changes: $worktree_path"
        ct_warn "Use force=true to remove anyway"
        return 1
    fi

    # Get branch name before removal
    local branch_name
    branch_name=$(git_current_branch "$worktree_path")

    ct_info "Removing worktree: $worktree_path"

    # Remove worktree
    if [[ "$force" == "true" ]]; then
        git worktree remove "$worktree_path" --force 2>/dev/null
    else
        git worktree remove "$worktree_path" 2>/dev/null
    fi

    if [[ $? -ne 0 ]]; then
        # Fallback: manual removal
        ct_warn "git worktree remove failed, cleaning up manually"
        rm -rf "$worktree_path"
        git worktree prune 2>/dev/null
    fi

    ct_info "Worktree removed: $thread_id"
    return 0
}

# Get worktree path for a thread
git_worktree_path() {
    local thread_id="$1"
    local worktrees_dir
    worktrees_dir=$(git_worktrees_dir)
    local worktree_path="$worktrees_dir/$thread_id"

    if [[ -d "$worktree_path" ]]; then
        echo "$worktree_path"
        return 0
    fi
    return 1
}

# Check if worktree exists
git_worktree_exists() {
    local thread_id="$1"
    local worktree_path
    worktree_path=$(git_worktree_path "$thread_id")
    [[ -n "$worktree_path" && -d "$worktree_path" ]]
}

# List all worktrees
git_worktree_list() {
    local worktrees_dir
    worktrees_dir=$(git_worktrees_dir)

    if [[ ! -d "$worktrees_dir" ]]; then
        return 0
    fi

    for dir in "$worktrees_dir"/*/; do
        if [[ -d "$dir" && -f "$dir/.worktree-info" ]]; then
            local thread_id
            thread_id=$(basename "$dir")
            local branch
            branch=$(git_current_branch "$dir")
            local status="active"
            if ! git_is_clean "$dir"; then
                status="dirty"
            fi
            echo "$thread_id|$branch|$status|$dir"
        fi
    done
}

# ============================================================
# Branch Operations
# ============================================================

# Create a branch in worktree
git_create_branch() {
    local worktree_path="$1"
    local branch_name="$2"
    local base="${3:-HEAD}"

    (cd "$worktree_path" && git checkout -b "$branch_name" "$base" 2>/dev/null)
}

# Push branch to remote
git_push_branch() {
    local worktree_path="$1"
    local branch_name="${2:-}"
    local remote="${3:-origin}"
    local force="${4:-false}"

    if [[ -z "$branch_name" ]]; then
        branch_name=$(git_current_branch "$worktree_path")
    fi

    ct_info "Pushing $branch_name to $remote..."

    local push_args=("-u" "$remote" "$branch_name")
    if [[ "$force" == "true" ]]; then
        push_args=("--force-with-lease" "${push_args[@]}")
    fi

    (cd "$worktree_path" && git push "${push_args[@]}" 2>&1)
}

# Delete remote branch
git_delete_remote_branch() {
    local branch_name="$1"
    local remote="${2:-origin}"

    ct_info "Deleting remote branch: $remote/$branch_name"
    git push "$remote" --delete "$branch_name" 2>/dev/null || true
}

# ============================================================
# Merge Operations
# ============================================================

# Check if merge would have conflicts
git_can_merge() {
    local worktree_path="$1"
    local target_branch="$2"

    (
        cd "$worktree_path" || exit 1

        # Try merge with no-commit
        if git merge --no-commit --no-ff "$target_branch" >/dev/null 2>&1; then
            git merge --abort 2>/dev/null || true
            exit 0
        else
            git merge --abort 2>/dev/null || true
            exit 1
        fi
    )
}

# Merge current branch back to base
git_merge_to_base() {
    local worktree_path="$1"
    local base_branch="${2:-main}"
    local squash="${3:-false}"

    local current_branch
    current_branch=$(git_current_branch "$worktree_path")

    ct_info "Merging $current_branch to $base_branch..."

    # Get repo root for main worktree
    local repo_root
    repo_root=$(git_repo_root)

    (
        cd "$repo_root" || exit 1

        # Checkout base branch
        git checkout "$base_branch" || exit 1

        # Pull latest
        git pull origin "$base_branch" 2>/dev/null || true

        # Merge
        if [[ "$squash" == "true" ]]; then
            git merge --squash "$current_branch" || exit 1
            git commit -m "Merge $current_branch (squashed)" || exit 1
        else
            git merge --no-ff "$current_branch" -m "Merge $current_branch" || exit 1
        fi
    )
}

# ============================================================
# Cleanup Operations
# ============================================================

# Prune stale worktrees
git_worktree_prune() {
    ct_info "Pruning stale worktrees..."
    git worktree prune 2>/dev/null
}

# Clean up old worktrees based on age
git_cleanup_old_worktrees() {
    local max_age_days="${1:-7}"
    local worktrees_dir
    worktrees_dir=$(git_worktrees_dir)

    if [[ ! -d "$worktrees_dir" ]]; then
        return 0
    fi

    local now
    now=$(date +%s)
    local max_age_seconds=$((max_age_days * 86400))

    for dir in "$worktrees_dir"/*/; do
        if [[ -d "$dir" && -f "$dir/.worktree-info" ]]; then
            local created_at
            created_at=$(grep "created_at:" "$dir/.worktree-info" | cut -d' ' -f2)

            if [[ -n "$created_at" ]]; then
                local created_ts
                # Parse ISO date - macOS compatible
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    created_ts=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null || echo 0)
                else
                    created_ts=$(date -d "$created_at" +%s 2>/dev/null || echo 0)
                fi

                local age=$((now - created_ts))
                if [[ $age -gt $max_age_seconds ]]; then
                    local thread_id
                    thread_id=$(basename "$dir")
                    ct_warn "Cleaning up old worktree: $thread_id (age: $((age / 86400)) days)"
                    git_worktree_remove "$thread_id" "true"
                fi
            fi
        fi
    done
}

# ============================================================
# PR Base Worktree Operations (Memory Optimization)
# ============================================================
#
# These functions implement a base worktree pattern for PRs:
# - One base worktree per PR that tracks the PR branch
# - Sub-agents (conflict resolver, comment handler) fork from base
# - Forks share git objects with base, reducing memory/disk usage
# - Base worktree stays up-to-date, forks are ephemeral
#
# Security & Reliability:
# - All inputs are sanitized to prevent path injection
# - Database tracking for persistence and auditing
# - File locking to prevent race conditions
# - Automatic cleanup on partial failures
#

# ============================================================
# Input Validation & Sanitization
# ============================================================

# Validate PR number (must be positive integer)
_git_validate_pr_number() {
    local pr_number="$1"
    if [[ ! "$pr_number" =~ ^[0-9]+$ ]] || [[ "$pr_number" -le 0 ]]; then
        ct_error "Invalid PR number: must be a positive integer"
        return 1
    fi
    return 0
}

# Sanitize identifier (alphanumeric, dash, underscore only)
_git_sanitize_id() {
    local id="$1"
    # Remove any path traversal attempts and special characters
    echo "$id" | sed 's/[^a-zA-Z0-9_-]//g' | head -c 64
}

# Validate branch name (basic git ref validation)
_git_validate_branch() {
    local branch="$1"
    # Reject path traversal, control chars, and other dangerous patterns
    if [[ "$branch" =~ \.\. ]] || [[ "$branch" =~ ^/ ]] || [[ "$branch" =~ [[:cntrl:]] ]]; then
        ct_error "Invalid branch name: contains forbidden characters"
        return 1
    fi
    # Check if it's a valid git ref
    if ! git check-ref-format --allow-onelevel "refs/heads/$branch" 2>/dev/null; then
        ct_error "Invalid branch name: not a valid git ref"
        return 1
    fi
    return 0
}

# ============================================================
# File Locking for Concurrency Safety
# ============================================================

# Acquire lock for a worktree operation
# Usage: _git_lock_acquire <lock_name> [timeout_seconds]
_git_lock_acquire() {
    local lock_name="$1"
    local timeout="${2:-30}"
    local lock_dir
    lock_dir="$(git_worktrees_dir)/.locks"
    mkdir -p "$lock_dir"
    local lock_file="$lock_dir/${lock_name}.lock"

    local waited=0
    while [[ $waited -lt $timeout ]]; do
        if (set -o noclobber; echo $$ > "$lock_file") 2>/dev/null; then
            # Got the lock
            trap "_git_lock_release '$lock_name'" EXIT
            return 0
        fi
        # Check if lock holder is still alive
        local holder_pid
        holder_pid=$(cat "$lock_file" 2>/dev/null)
        if [[ -n "$holder_pid" ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
            # Holder is dead, remove stale lock
            rm -f "$lock_file"
            continue
        fi
        sleep 1
        ((waited++))
    done

    ct_error "Failed to acquire lock: $lock_name (timeout after ${timeout}s)"
    return 1
}

# Release a lock
_git_lock_release() {
    local lock_name="$1"
    local lock_dir
    lock_dir="$(git_worktrees_dir)/.locks"
    local lock_file="$lock_dir/${lock_name}.lock"
    rm -f "$lock_file"
    trap - EXIT
}

# ============================================================
# Database Integration
# ============================================================

# Insert base worktree record into database
_git_db_insert_base() {
    local pr_number="$1"
    local base_id="$2"
    local path="$3"
    local branch="$4"
    local target_branch="$5"
    local remote="$6"
    local commit="$7"

    db_exec "INSERT OR REPLACE INTO pr_base_worktrees
        (pr_number, base_id, path, branch, target_branch, remote, status, last_commit, fork_count)
        VALUES (
            $(db_quote "$pr_number"),
            $(db_quote "$base_id"),
            $(db_quote "$path"),
            $(db_quote "$branch"),
            $(db_quote "$target_branch"),
            $(db_quote "$remote"),
            'active',
            $(db_quote "$commit"),
            0
        )" 2>/dev/null || true  # Ignore if table doesn't exist yet
}

# Update base worktree record
_git_db_update_base() {
    local pr_number="$1"
    local status="$2"
    local commit="${3:-}"

    local commit_update=""
    if [[ -n "$commit" ]]; then
        commit_update=", last_commit = $(db_quote "$commit")"
    fi

    db_exec "UPDATE pr_base_worktrees
        SET status = $(db_quote "$status")$commit_update
        WHERE pr_number = $pr_number" 2>/dev/null || true
}

# Insert fork record into database
_git_db_insert_fork() {
    local pr_number="$1"
    local fork_id="$2"
    local base_id="$3"
    local path="$4"
    local branch="$5"
    local purpose="$6"
    local thread_id="$7"
    local commit="$8"

    db_exec "INSERT INTO pr_worktree_forks
        (pr_number, fork_id, base_id, path, branch, purpose, handler_thread_id, forked_from_commit, status)
        VALUES (
            $(db_quote "$pr_number"),
            $(db_quote "$fork_id"),
            $(db_quote "$base_id"),
            $(db_quote "$path"),
            $(db_quote "$branch"),
            $(db_quote "$purpose"),
            $(db_quote "$thread_id"),
            $(db_quote "$commit"),
            'active'
        )" 2>/dev/null || true
}

# Update fork status
_git_db_update_fork() {
    local fork_id="$1"
    local status="$2"

    local timestamp_field=""
    case "$status" in
        merged) timestamp_field=", merged_at = datetime('now')" ;;
        removed|abandoned) timestamp_field=", removed_at = datetime('now')" ;;
    esac

    db_exec "UPDATE pr_worktree_forks
        SET status = $(db_quote "$status")$timestamp_field
        WHERE fork_id = $(db_quote "$fork_id")" 2>/dev/null || true
}

# ============================================================
# Event Publishing
# ============================================================

# Publish worktree event
_git_publish_event() {
    local event_type="$1"
    local data="$2"

    # Use blackboard if available
    if type blackboard_publish &>/dev/null; then
        blackboard_publish "$event_type" "$data" 2>/dev/null || true
    fi
}

# ============================================================
# Base Worktree Operations
# ============================================================

# Create or get a base worktree for a PR
# Usage: git_pr_base_create <pr_number> <pr_branch> <target_branch> [remote] [purpose]
git_pr_base_create() {
    local pr_number="$1"
    local pr_branch="$2"
    local target_branch="${3:-main}"
    local remote="${4:-origin}"

    # Validate inputs
    if [[ -z "$pr_number" || -z "$pr_branch" ]]; then
        ct_error "Usage: git_pr_base_create <pr_number> <pr_branch> [target_branch] [remote]"
        return 1
    fi

    _git_validate_pr_number "$pr_number" || return 1
    _git_validate_branch "$pr_branch" || return 1
    _git_validate_branch "$target_branch" || return 1

    # Acquire lock for this PR
    _git_lock_acquire "pr-${pr_number}" || return 1

    local worktrees_dir
    worktrees_dir=$(git_worktrees_dir)
    local base_id="pr-${pr_number}-base"
    local base_path="$worktrees_dir/$base_id"

    # If base already exists, check if it needs update
    if [[ -d "$base_path" ]]; then
        local existing_branch
        existing_branch=$(git_current_branch "$base_path")

        # Check if tracking same branch
        if [[ "$existing_branch" != "$pr_branch" ]]; then
            ct_warn "Base worktree tracks different branch: $existing_branch vs $pr_branch"
            ct_warn "Remove existing base first with: ct worktree base-remove $pr_number"
            _git_lock_release "pr-${pr_number}"
            return 1
        fi

        # Check if there are active forks before updating
        local fork_count=0
        if [[ -f "$base_path/.worktree-info" ]]; then
            fork_count=$(grep "fork_count:" "$base_path/.worktree-info" 2>/dev/null | cut -d' ' -f2 || echo 0)
        fi

        if [[ "$fork_count" -gt 0 ]]; then
            ct_warn "Base has $fork_count active fork(s). Update may affect them."
        fi

        ct_info "Base worktree exists, updating: $base_path"
        git_pr_base_update "$pr_number" "$remote"
        _git_lock_release "pr-${pr_number}"
        echo "$base_path"
        return 0
    fi

    # Ensure we're in a git repo
    if ! git_is_repo; then
        ct_error "Not in a git repository"
        _git_lock_release "pr-${pr_number}"
        return 1
    fi

    # Create base worktree from PR branch
    mkdir -p "$worktrees_dir"

    # Fetch the PR branch
    ct_debug "Fetching PR branch $pr_branch from $remote..."
    if ! git fetch "$remote" "$pr_branch:$pr_branch" 2>/dev/null; then
        ct_error "Failed to fetch PR branch: $pr_branch"
        _git_lock_release "pr-${pr_number}"
        return 1
    fi

    # Create worktree on PR branch
    ct_info "Creating PR base worktree: $base_path (branch: $pr_branch)"
    if ! git worktree add "$base_path" "$pr_branch" >/dev/null 2>&1; then
        ct_error "Failed to create base worktree"
        _git_lock_release "pr-${pr_number}"
        return 1
    fi

    # Get current commit
    local current_commit
    current_commit=$(cd "$base_path" && git rev-parse HEAD 2>/dev/null)

    # Create metadata file
    cat > "$base_path/.worktree-info" <<EOF
thread_id: $base_id
pr_number: $pr_number
branch_name: $pr_branch
base_branch: $target_branch
remote: $remote
type: pr_base
created_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
status: active
fork_count: 0
last_commit: $current_commit
EOF

    # Insert into database
    _git_db_insert_base "$pr_number" "$base_id" "$base_path" "$pr_branch" "$target_branch" "$remote" "$current_commit"

    # Publish event
    _git_publish_event "WORKTREE_BASE_CREATED" "{\"pr_number\": $pr_number, \"base_id\": \"$base_id\", \"path\": \"$base_path\"}"

    _git_lock_release "pr-${pr_number}"
    ct_info "PR base worktree created: $base_path"
    echo "$base_path"
}

# Update a PR base worktree with latest changes
# Usage: git_pr_base_update <pr_number> [remote]
git_pr_base_update() {
    local pr_number="$1"
    local remote="${2:-origin}"

    # Validate
    _git_validate_pr_number "$pr_number" || return 1

    local worktrees_dir
    worktrees_dir=$(git_worktrees_dir)
    local base_id="pr-${pr_number}-base"
    local base_path="$worktrees_dir/$base_id"

    if [[ ! -d "$base_path" ]]; then
        ct_error "PR base worktree not found: $base_path"
        return 1
    fi

    # Update database status
    _git_db_update_base "$pr_number" "updating"

    ct_info "Updating PR base worktree: $base_path"

    local update_result=0
    local new_commit=""

    (
        cd "$base_path" || exit 1
        local branch
        branch=$(git rev-parse --abbrev-ref HEAD)

        # Check for uncommitted changes
        if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
            ct_warn "Base has uncommitted changes, stashing..."
            git stash -q 2>/dev/null || true
        fi

        # Pull latest
        if ! git fetch "$remote" "$branch" 2>/dev/null; then
            ct_error "Failed to fetch from $remote"
            exit 1
        fi

        if ! git reset --hard "$remote/$branch" 2>/dev/null; then
            ct_error "Failed to reset to $remote/$branch"
            exit 1
        fi

        # Also fetch target branch for merging
        local target_branch
        target_branch=$(grep "base_branch:" ".worktree-info" 2>/dev/null | cut -d' ' -f2)
        if [[ -n "$target_branch" ]]; then
            git fetch "$remote" "$target_branch" 2>/dev/null || true
        fi
    ) || update_result=$?

    if [[ $update_result -ne 0 ]]; then
        _git_db_update_base "$pr_number" "stale"
        return 1
    fi

    # Get new commit
    new_commit=$(cd "$base_path" && git rev-parse HEAD 2>/dev/null)

    # Update metadata file
    if [[ -f "$base_path/.worktree-info" ]]; then
        local temp_file
        temp_file=$(mktemp)
        grep -v -E "^(updated_at|last_commit):" "$base_path/.worktree-info" > "$temp_file"
        {
            echo "updated_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
            echo "last_commit: $new_commit"
        } >> "$temp_file"
        mv "$temp_file" "$base_path/.worktree-info"
    fi

    # Update database
    _git_db_update_base "$pr_number" "active" "$new_commit"

    ct_info "PR base updated to: $new_commit"
    return 0
}

# Fork from a PR base worktree for sub-agent work
# Usage: git_worktree_fork <pr_number> <fork_id> <fork_branch> [purpose] [handler_thread_id]
# Returns: path to the forked worktree
git_worktree_fork() {
    local pr_number="$1"
    local fork_id="$2"
    local fork_branch="$3"
    local purpose="${4:-general}"
    local handler_thread_id="${5:-}"

    if [[ -z "$pr_number" || -z "$fork_id" || -z "$fork_branch" ]]; then
        ct_error "Usage: git_worktree_fork <pr_number> <fork_id> <fork_branch> [purpose] [handler_thread_id]"
        return 1
    fi

    # Validate inputs
    _git_validate_pr_number "$pr_number" || return 1
    _git_validate_branch "$fork_branch" || return 1

    # Sanitize fork_id to prevent path injection
    fork_id=$(_git_sanitize_id "$fork_id")
    if [[ -z "$fork_id" ]]; then
        ct_error "Invalid fork ID after sanitization"
        return 1
    fi

    # Validate purpose
    case "$purpose" in
        conflict_resolution|comment_handler|ci_fix|general) ;;
        *)
            ct_warn "Unknown purpose '$purpose', using 'general'"
            purpose="general"
            ;;
    esac

    local worktrees_dir
    worktrees_dir=$(git_worktrees_dir)
    local base_id="pr-${pr_number}-base"
    local base_path="$worktrees_dir/$base_id"
    local fork_path="$worktrees_dir/$fork_id"

    # Acquire lock for fork operations on this PR
    _git_lock_acquire "pr-${pr_number}-fork" || return 1

    # Check base exists
    if [[ ! -d "$base_path" ]]; then
        ct_error "PR base worktree not found: $base_path. Create it first with git_pr_base_create"
        _git_lock_release "pr-${pr_number}-fork"
        return 1
    fi

    # Check fork doesn't already exist
    if [[ -d "$fork_path" ]]; then
        ct_warn "Fork already exists: $fork_path"
        _git_lock_release "pr-${pr_number}-fork"
        echo "$fork_path"
        return 0
    fi

    # Check if base is stale (hasn't been updated recently)
    local base_updated
    base_updated=$(grep "updated_at:" "$base_path/.worktree-info" 2>/dev/null | cut -d' ' -f2)
    if [[ -z "$base_updated" ]]; then
        base_updated=$(grep "created_at:" "$base_path/.worktree-info" 2>/dev/null | cut -d' ' -f2)
    fi
    # Note: Could add staleness check here if needed

    # Get base branch for reference
    local base_branch
    base_branch=$(git_current_branch "$base_path")

    ct_info "Forking from PR base: $base_path -> $fork_path (branch: $fork_branch, purpose: $purpose)"

    # Create new worktree from the base's HEAD
    # This uses git's object sharing so it's memory-efficient
    local base_commit
    base_commit=$(cd "$base_path" && git rev-parse HEAD)

    if ! git worktree add -b "$fork_branch" "$fork_path" "$base_commit" >/dev/null 2>&1; then
        ct_error "Failed to create fork worktree"
        _git_lock_release "pr-${pr_number}-fork"
        return 1
    fi

    # Create fork metadata
    cat > "$fork_path/.worktree-info" <<EOF
thread_id: $fork_id
pr_number: $pr_number
branch_name: $fork_branch
forked_from: $base_id
forked_commit: $base_commit
base_branch: $base_branch
type: pr_fork
purpose: $purpose
handler_thread_id: $handler_thread_id
created_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
status: active
EOF

    # Atomically increment fork count using lock (already held)
    if [[ -f "$base_path/.worktree-info" ]]; then
        local temp_file
        temp_file=$(mktemp)
        local current_count
        current_count=$(grep "fork_count:" "$base_path/.worktree-info" 2>/dev/null | cut -d' ' -f2 || echo 0)
        current_count=$((current_count + 1))

        # Rewrite file atomically
        grep -v "fork_count:" "$base_path/.worktree-info" > "$temp_file"
        echo "fork_count: $current_count" >> "$temp_file"
        mv "$temp_file" "$base_path/.worktree-info"
    fi

    # Insert fork into database
    _git_db_insert_fork "$pr_number" "$fork_id" "$base_id" "$fork_path" "$fork_branch" "$purpose" "$handler_thread_id" "$base_commit"

    # Publish event
    _git_publish_event "WORKTREE_FORK_CREATED" "{\"pr_number\": $pr_number, \"fork_id\": \"$fork_id\", \"purpose\": \"$purpose\", \"base_commit\": \"$base_commit\"}"

    _git_lock_release "pr-${pr_number}-fork"
    ct_info "Fork created: $fork_path"
    echo "$fork_path"
}

# Merge fork changes back to PR base and push
# Usage: git_fork_merge_back <fork_id> [push]
# Returns: 0 on success, 1 on merge conflict, 2 on push failure
git_fork_merge_back() {
    local fork_id="$1"
    local push="${2:-true}"

    # Sanitize fork_id
    fork_id=$(_git_sanitize_id "$fork_id")

    local worktrees_dir
    worktrees_dir=$(git_worktrees_dir)
    local fork_path="$worktrees_dir/$fork_id"

    if [[ ! -d "$fork_path" ]]; then
        ct_error "Fork worktree not found: $fork_path"
        return 1
    fi

    # Get fork info
    local pr_number base_id fork_branch
    pr_number=$(grep "pr_number:" "$fork_path/.worktree-info" 2>/dev/null | cut -d' ' -f2)
    base_id=$(grep "forked_from:" "$fork_path/.worktree-info" 2>/dev/null | cut -d' ' -f2)
    fork_branch=$(grep "branch_name:" "$fork_path/.worktree-info" 2>/dev/null | cut -d' ' -f2)

    if [[ -z "$pr_number" || -z "$base_id" || -z "$fork_branch" ]]; then
        ct_error "Invalid fork metadata - missing required fields"
        return 1
    fi

    local base_path="$worktrees_dir/$base_id"

    if [[ ! -d "$base_path" ]]; then
        ct_error "Base worktree not found: $base_path"
        return 1
    fi

    # Acquire lock for merge operations
    _git_lock_acquire "pr-${pr_number}-merge" || return 1

    local base_branch
    base_branch=$(git_current_branch "$base_path")

    # Check if fork has any commits ahead of base
    local commits_ahead
    commits_ahead=$(cd "$base_path" && git rev-list --count "$base_branch..$fork_branch" 2>/dev/null || echo 0)

    if [[ "$commits_ahead" -eq 0 ]]; then
        ct_warn "Fork has no new commits to merge"
        _git_db_update_fork "$fork_id" "merged"
        _git_lock_release "pr-${pr_number}-merge"
        return 0
    fi

    ct_info "Merging fork $fork_id back to base ($commits_ahead commits)..."

    local merge_result=0
    local push_result=0

    (
        cd "$base_path" || exit 1

        # Check for uncommitted changes in base
        if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
            ct_error "Base has uncommitted changes - cannot merge"
            exit 1
        fi

        # Merge fork branch
        if ! git merge "$fork_branch" --no-ff -m "Merge $fork_branch from fork ($fork_id)" 2>&1; then
            ct_error "Merge conflict when merging fork back to base"
            git merge --abort 2>/dev/null || true
            exit 1
        fi
    ) || merge_result=$?

    if [[ $merge_result -ne 0 ]]; then
        ct_error "Merge failed with conflict"
        _git_publish_event "WORKTREE_MERGE_CONFLICT" "{\"fork_id\": \"$fork_id\", \"pr_number\": $pr_number}"
        _git_lock_release "pr-${pr_number}-merge"
        return 1
    fi

    # Push if requested
    if [[ "$push" == "true" ]]; then
        local remote
        remote=$(grep "remote:" "$base_path/.worktree-info" 2>/dev/null | cut -d' ' -f2)
        remote="${remote:-origin}"

        ct_info "Pushing to $remote/$base_branch..."

        local push_output
        if ! push_output=$(cd "$base_path" && git push "$remote" "$base_branch" 2>&1); then
            ct_error "Push failed: $push_output"
            ct_error "Changes are merged locally but NOT pushed to remote"

            # Update fork status to indicate partial success
            _git_db_update_fork "$fork_id" "merged"

            _git_publish_event "WORKTREE_PUSH_FAILED" "{\"fork_id\": \"$fork_id\", \"pr_number\": $pr_number, \"error\": \"push_failed\"}"
            _git_lock_release "pr-${pr_number}-merge"
            return 2  # Different exit code for push failure
        fi

        ct_info "Successfully pushed to remote"
    fi

    # Update fork status
    _git_db_update_fork "$fork_id" "merged"

    # Update metadata
    if [[ -f "$fork_path/.worktree-info" ]]; then
        echo "merged_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$fork_path/.worktree-info"
        echo "status: merged" >> "$fork_path/.worktree-info"
    fi

    # Publish event
    _git_publish_event "WORKTREE_FORK_MERGED" "{\"fork_id\": \"$fork_id\", \"pr_number\": $pr_number, \"pushed\": $push}"

    _git_lock_release "pr-${pr_number}-merge"
    ct_info "Fork merged successfully"
    return 0
}

# Remove a fork worktree and cleanup
# Usage: git_fork_remove <fork_id> [force]
git_fork_remove() {
    local fork_id="$1"
    local force="${2:-false}"

    # Sanitize fork_id
    fork_id=$(_git_sanitize_id "$fork_id")

    local worktrees_dir
    worktrees_dir=$(git_worktrees_dir)
    local fork_path="$worktrees_dir/$fork_id"

    if [[ ! -d "$fork_path" ]]; then
        ct_debug "Fork not found: $fork_path"
        # Still update database in case it's out of sync
        _git_db_update_fork "$fork_id" "removed"
        return 0
    fi

    # Get fork info before removal
    local pr_number base_id fork_branch status
    if [[ -f "$fork_path/.worktree-info" ]]; then
        pr_number=$(grep "pr_number:" "$fork_path/.worktree-info" 2>/dev/null | cut -d' ' -f2)
        base_id=$(grep "forked_from:" "$fork_path/.worktree-info" 2>/dev/null | cut -d' ' -f2)
        fork_branch=$(grep "branch_name:" "$fork_path/.worktree-info" 2>/dev/null | cut -d' ' -f2)
        status=$(grep "^status:" "$fork_path/.worktree-info" 2>/dev/null | cut -d' ' -f2)
    fi

    # Acquire lock if we have pr_number
    if [[ -n "$pr_number" ]]; then
        _git_lock_acquire "pr-${pr_number}-fork" || return 1
    fi

    # Check for uncommitted changes if not forcing
    if [[ "$force" != "true" ]]; then
        if ! git_is_clean "$fork_path"; then
            ct_warn "Fork has uncommitted changes: $fork_path"
            if [[ -n "$pr_number" ]]; then
                _git_lock_release "pr-${pr_number}-fork"
            fi
            return 1
        fi

        # Warn if status is not merged
        if [[ -n "$status" && "$status" != "merged" ]]; then
            ct_warn "Fork status is '$status', not 'merged'. Use --force to remove anyway."
            if [[ -n "$pr_number" ]]; then
                _git_lock_release "pr-${pr_number}-fork"
            fi
            return 1
        fi
    fi

    # Remove the worktree
    git_worktree_remove "$fork_id" "$force"

    # Delete the fork branch
    if [[ -n "$fork_branch" ]]; then
        # Check if branch is still used somewhere else
        local branch_users
        branch_users=$(git worktree list 2>/dev/null | grep -c "\[$fork_branch\]" || echo 0)
        if [[ "$branch_users" -eq 0 ]]; then
            git branch -D "$fork_branch" 2>/dev/null || true
        else
            ct_debug "Branch $fork_branch still in use by another worktree"
        fi
    fi

    # Decrement fork count in base (atomically with lock)
    if [[ -n "$base_id" ]]; then
        local base_path="$worktrees_dir/$base_id"
        if [[ -f "$base_path/.worktree-info" ]]; then
            local temp_file
            temp_file=$(mktemp)
            local current_count
            current_count=$(grep "fork_count:" "$base_path/.worktree-info" 2>/dev/null | cut -d' ' -f2 || echo 0)
            current_count=$((current_count - 1))
            [[ $current_count -lt 0 ]] && current_count=0

            # Rewrite file atomically
            grep -v "fork_count:" "$base_path/.worktree-info" > "$temp_file"
            echo "fork_count: $current_count" >> "$temp_file"
            mv "$temp_file" "$base_path/.worktree-info"
        fi
    fi

    # Update database
    _git_db_update_fork "$fork_id" "removed"

    # Publish event
    _git_publish_event "WORKTREE_FORK_REMOVED" "{\"fork_id\": \"$fork_id\", \"pr_number\": ${pr_number:-null}}"

    if [[ -n "$pr_number" ]]; then
        _git_lock_release "pr-${pr_number}-fork"
    fi

    ct_info "Fork removed: $fork_id"
}

# Remove PR base worktree and all its forks
# Usage: git_pr_base_remove <pr_number> [force]
git_pr_base_remove() {
    local pr_number="$1"
    local force="${2:-false}"

    # Validate
    _git_validate_pr_number "$pr_number" || return 1

    local worktrees_dir
    worktrees_dir=$(git_worktrees_dir)
    local base_id="pr-${pr_number}-base"
    local base_path="$worktrees_dir/$base_id"

    # Acquire lock for this PR
    _git_lock_acquire "pr-${pr_number}" || return 1

    if [[ ! -d "$base_path" ]]; then
        ct_debug "PR base not found: $base_path"
        # Clean up database entry if exists
        _git_db_update_base "$pr_number" "removed"
        _git_lock_release "pr-${pr_number}"
        return 0
    fi

    ct_info "Removing PR base and all forks for PR #$pr_number..."

    # Count forks before removal
    local fork_count=0
    local removed_count=0

    # Find and remove all forks first
    for dir in "$worktrees_dir"/*/; do
        if [[ -d "$dir" && -f "$dir/.worktree-info" ]]; then
            local forked_from
            forked_from=$(grep "forked_from:" "$dir/.worktree-info" 2>/dev/null | cut -d' ' -f2)
            if [[ "$forked_from" == "$base_id" ]]; then
                ((fork_count++))
                local fork_id
                fork_id=$(basename "$dir")
                ct_info "Removing fork: $fork_id"
                # Use force for forks when removing base
                if git_fork_remove "$fork_id" "true"; then
                    ((removed_count++))
                else
                    ct_warn "Failed to remove fork: $fork_id"
                fi
            fi
        fi
    done

    if [[ $fork_count -gt 0 ]]; then
        ct_info "Removed $removed_count/$fork_count forks"
    fi

    # Remove base worktree
    git_worktree_remove "$base_id" "$force"

    # Update database
    _git_db_update_base "$pr_number" "removed"

    # Publish event
    _git_publish_event "WORKTREE_BASE_REMOVED" "{\"pr_number\": $pr_number, \"forks_removed\": $removed_count}"

    _git_lock_release "pr-${pr_number}"
    ct_info "PR base and forks removed for PR #$pr_number"
}

# Get PR base worktree path
# Usage: git_pr_base_path <pr_number>
git_pr_base_path() {
    local pr_number="$1"

    # Validate
    _git_validate_pr_number "$pr_number" || return 1

    local worktrees_dir
    worktrees_dir=$(git_worktrees_dir)
    local base_id="pr-${pr_number}-base"
    local base_path="$worktrees_dir/$base_id"

    if [[ -d "$base_path" ]]; then
        echo "$base_path"
        return 0
    fi
    return 1
}

# List all forks for a PR
# Usage: git_pr_forks_list <pr_number>
git_pr_forks_list() {
    local pr_number="$1"

    # Validate
    _git_validate_pr_number "$pr_number" || return 1

    local worktrees_dir
    worktrees_dir=$(git_worktrees_dir)
    local base_id="pr-${pr_number}-base"

    for dir in "$worktrees_dir"/*/; do
        if [[ -d "$dir" && -f "$dir/.worktree-info" ]]; then
            local forked_from
            forked_from=$(grep "forked_from:" "$dir/.worktree-info" 2>/dev/null | cut -d' ' -f2)
            if [[ "$forked_from" == "$base_id" ]]; then
                local fork_id branch status purpose
                fork_id=$(basename "$dir")
                branch=$(git_current_branch "$dir")
                purpose=$(grep "purpose:" "$dir/.worktree-info" 2>/dev/null | cut -d' ' -f2 || echo "general")
                status="active"
                if ! git_is_clean "$dir"; then
                    status="dirty"
                fi
                echo "$fork_id|$branch|$status|$purpose|$dir"
            fi
        fi
    done
}

# Get PR base info as JSON
git_pr_base_info() {
    local pr_number="$1"

    # Validate
    _git_validate_pr_number "$pr_number" || return 1

    local base_path
    base_path=$(git_pr_base_path "$pr_number")

    if [[ -z "$base_path" ]]; then
        echo "{}"
        return 1
    fi

    local branch status fork_count last_commit
    branch=$(git_current_branch "$base_path")
    status=$(git_worktree_status "pr-${pr_number}-base")
    fork_count=$(grep "fork_count:" "$base_path/.worktree-info" 2>/dev/null | cut -d' ' -f2)
    fork_count="${fork_count:-0}"
    last_commit=$(grep "last_commit:" "$base_path/.worktree-info" 2>/dev/null | cut -d' ' -f2)
    last_commit="${last_commit:-unknown}"

    # List active forks with purpose
    local forks_json="["
    local first=true
    while IFS='|' read -r fork_id fork_branch fork_status fork_purpose fork_path; do
        if [[ -n "$fork_id" ]]; then
            [[ "$first" == "true" ]] || forks_json+=","
            forks_json+="{\"id\":\"$fork_id\",\"branch\":\"$fork_branch\",\"status\":\"$fork_status\",\"purpose\":\"${fork_purpose:-general}\"}"
            first=false
        fi
    done < <(git_pr_forks_list "$pr_number")
    forks_json+="]"

    cat <<EOF
{
  "pr_number": $pr_number,
  "base_id": "pr-${pr_number}-base",
  "path": "$base_path",
  "branch": "$branch",
  "status": "$status",
  "fork_count": $fork_count,
  "last_commit": "$last_commit",
  "forks": $forks_json
}
EOF
}

# ============================================================
# Reconciliation & Cleanup
# ============================================================

# Reconcile database with filesystem state
# This is a recovery function to fix inconsistencies
# Usage: git_pr_worktree_reconcile [fix]
git_pr_worktree_reconcile() {
    local fix="${1:-false}"
    local worktrees_dir
    worktrees_dir=$(git_worktrees_dir)

    local issues_found=0
    local issues_fixed=0

    ct_info "Reconciling PR worktrees..."

    # 1. Check all filesystem worktrees have database entries
    for dir in "$worktrees_dir"/*/; do
        if [[ -d "$dir" && -f "$dir/.worktree-info" ]]; then
            local worktree_type
            worktree_type=$(grep "type:" "$dir/.worktree-info" 2>/dev/null | cut -d' ' -f2)

            if [[ "$worktree_type" == "pr_base" ]]; then
                local pr_number base_id branch target_branch remote
                pr_number=$(grep "pr_number:" "$dir/.worktree-info" 2>/dev/null | cut -d' ' -f2)
                base_id=$(grep "thread_id:" "$dir/.worktree-info" 2>/dev/null | cut -d' ' -f2)
                branch=$(grep "branch_name:" "$dir/.worktree-info" 2>/dev/null | cut -d' ' -f2)
                target_branch=$(grep "base_branch:" "$dir/.worktree-info" 2>/dev/null | cut -d' ' -f2)
                remote=$(grep "remote:" "$dir/.worktree-info" 2>/dev/null | cut -d' ' -f2)

                # Check if in database
                local db_entry
                db_entry=$(db_scalar "SELECT base_id FROM pr_base_worktrees WHERE pr_number = $pr_number" 2>/dev/null || echo "")

                if [[ -z "$db_entry" ]]; then
                    ct_warn "Base worktree $base_id exists on disk but not in database"
                    ((issues_found++))

                    if [[ "$fix" == "true" ]]; then
                        local current_commit
                        current_commit=$(cd "$dir" && git rev-parse HEAD 2>/dev/null || echo "unknown")
                        _git_db_insert_base "$pr_number" "$base_id" "$dir" "$branch" "$target_branch" "$remote" "$current_commit"
                        ct_info "  -> Added to database"
                        ((issues_fixed++))
                    fi
                fi

            elif [[ "$worktree_type" == "pr_fork" ]]; then
                local fork_id pr_number base_id branch purpose
                fork_id=$(grep "thread_id:" "$dir/.worktree-info" 2>/dev/null | cut -d' ' -f2)
                pr_number=$(grep "pr_number:" "$dir/.worktree-info" 2>/dev/null | cut -d' ' -f2)
                base_id=$(grep "forked_from:" "$dir/.worktree-info" 2>/dev/null | cut -d' ' -f2)
                branch=$(grep "branch_name:" "$dir/.worktree-info" 2>/dev/null | cut -d' ' -f2)
                purpose=$(grep "purpose:" "$dir/.worktree-info" 2>/dev/null | cut -d' ' -f2 || echo "general")

                # Check if in database
                local db_entry
                db_entry=$(db_scalar "SELECT fork_id FROM pr_worktree_forks WHERE fork_id = $(db_quote "$fork_id")" 2>/dev/null || echo "")

                if [[ -z "$db_entry" ]]; then
                    ct_warn "Fork $fork_id exists on disk but not in database"
                    ((issues_found++))

                    if [[ "$fix" == "true" ]]; then
                        local forked_commit
                        forked_commit=$(grep "forked_commit:" "$dir/.worktree-info" 2>/dev/null | cut -d' ' -f2 || echo "unknown")
                        _git_db_insert_fork "$pr_number" "$fork_id" "$base_id" "$dir" "$branch" "$purpose" "" "$forked_commit"
                        ct_info "  -> Added to database"
                        ((issues_fixed++))
                    fi
                fi
            fi
        fi
    done

    # 2. Check database entries have corresponding filesystem directories
    # (Only if database is initialized)
    if type db_query &>/dev/null 2>&1; then
        # Check base worktrees
        local db_bases
        db_bases=$(db_scalar "SELECT base_id || '|' || path FROM pr_base_worktrees WHERE status = 'active'" 2>/dev/null || echo "")

        if [[ -n "$db_bases" ]]; then
            while IFS='|' read -r base_id path; do
                if [[ -n "$base_id" && ! -d "$path" ]]; then
                    ct_warn "Base $base_id in database but directory missing: $path"
                    ((issues_found++))

                    if [[ "$fix" == "true" ]]; then
                        local pr_num
                        pr_num=$(echo "$base_id" | sed 's/pr-\([0-9]*\)-base/\1/')
                        _git_db_update_base "$pr_num" "removed"
                        ct_info "  -> Marked as removed in database"
                        ((issues_fixed++))
                    fi
                fi
            done <<< "$db_bases"
        fi

        # Check forks
        local db_forks
        db_forks=$(db_scalar "SELECT fork_id || '|' || path FROM pr_worktree_forks WHERE status = 'active'" 2>/dev/null || echo "")

        if [[ -n "$db_forks" ]]; then
            while IFS='|' read -r fork_id path; do
                if [[ -n "$fork_id" && ! -d "$path" ]]; then
                    ct_warn "Fork $fork_id in database but directory missing: $path"
                    ((issues_found++))

                    if [[ "$fix" == "true" ]]; then
                        _git_db_update_fork "$fork_id" "removed"
                        ct_info "  -> Marked as removed in database"
                        ((issues_fixed++))
                    fi
                fi
            done <<< "$db_forks"
        fi
    fi

    # 3. Verify fork counts in base worktrees match reality
    for dir in "$worktrees_dir"/*/; do
        if [[ -d "$dir" && -f "$dir/.worktree-info" ]]; then
            local worktree_type
            worktree_type=$(grep "type:" "$dir/.worktree-info" 2>/dev/null | cut -d' ' -f2)

            if [[ "$worktree_type" == "pr_base" ]]; then
                local base_id recorded_count actual_count
                base_id=$(grep "thread_id:" "$dir/.worktree-info" 2>/dev/null | cut -d' ' -f2)
                recorded_count=$(grep "fork_count:" "$dir/.worktree-info" 2>/dev/null | cut -d' ' -f2 || echo 0)

                # Count actual forks
                actual_count=0
                for fork_dir in "$worktrees_dir"/*/; do
                    if [[ -d "$fork_dir" && -f "$fork_dir/.worktree-info" ]]; then
                        local forked_from
                        forked_from=$(grep "forked_from:" "$fork_dir/.worktree-info" 2>/dev/null | cut -d' ' -f2)
                        if [[ "$forked_from" == "$base_id" ]]; then
                            ((actual_count++))
                        fi
                    fi
                done

                if [[ "$recorded_count" != "$actual_count" ]]; then
                    ct_warn "Fork count mismatch for $base_id: recorded=$recorded_count, actual=$actual_count"
                    ((issues_found++))

                    if [[ "$fix" == "true" ]]; then
                        local temp_file
                        temp_file=$(mktemp)
                        grep -v "fork_count:" "$dir/.worktree-info" > "$temp_file"
                        echo "fork_count: $actual_count" >> "$temp_file"
                        mv "$temp_file" "$dir/.worktree-info"
                        ct_info "  -> Fixed fork count"
                        ((issues_fixed++))
                    fi
                fi
            fi
        fi
    done

    echo ""
    if [[ $issues_found -eq 0 ]]; then
        ct_info "No issues found - database and filesystem are in sync"
    else
        ct_warn "Found $issues_found issue(s)"
        if [[ "$fix" == "true" ]]; then
            ct_info "Fixed $issues_fixed issue(s)"
        else
            ct_info "Run with 'fix' argument to automatically repair"
        fi
    fi

    return $issues_found
}

# ============================================================
# Status Operations
# ============================================================

# Get worktree status
git_worktree_status() {
    local thread_id="$1"
    local worktree_path
    worktree_path=$(git_worktree_path "$thread_id")

    if [[ -z "$worktree_path" ]]; then
        echo "not_found"
        return 1
    fi

    if ! git_is_clean "$worktree_path"; then
        echo "dirty"
    else
        echo "clean"
    fi
}

# Get worktree info as JSON
git_worktree_info() {
    local thread_id="$1"
    local worktree_path
    worktree_path=$(git_worktree_path "$thread_id")

    if [[ -z "$worktree_path" ]]; then
        echo "{}"
        return 1
    fi

    local branch
    branch=$(git_current_branch "$worktree_path")
    local status
    status=$(git_worktree_status "$thread_id")
    local commits_ahead=0
    local commits_behind=0

    # Get commit counts
    if [[ -f "$worktree_path/.worktree-info" ]]; then
        local base_branch
        base_branch=$(grep "base_branch:" "$worktree_path/.worktree-info" | cut -d' ' -f2)
        if [[ -n "$base_branch" ]]; then
            commits_ahead=$(cd "$worktree_path" && git rev-list --count "$base_branch..$branch" 2>/dev/null || echo 0)
            commits_behind=$(cd "$worktree_path" && git rev-list --count "$branch..$base_branch" 2>/dev/null || echo 0)
        fi
    fi

    cat <<EOF
{
  "thread_id": "$thread_id",
  "path": "$worktree_path",
  "branch": "$branch",
  "status": "$status",
  "commits_ahead": $commits_ahead,
  "commits_behind": $commits_behind
}
EOF
}
