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

# Create or get a base worktree for a PR
# Usage: git_pr_base_create <pr_number> <pr_branch> <target_branch> [remote]
git_pr_base_create() {
    local pr_number="$1"
    local pr_branch="$2"
    local target_branch="${3:-main}"
    local remote="${4:-origin}"

    if [[ -z "$pr_number" || -z "$pr_branch" ]]; then
        ct_error "Usage: git_pr_base_create <pr_number> <pr_branch> [target_branch] [remote]"
        return 1
    fi

    local worktrees_dir
    worktrees_dir=$(git_worktrees_dir)
    local base_id="pr-${pr_number}-base"
    local base_path="$worktrees_dir/$base_id"

    # If base already exists, just update it
    if [[ -d "$base_path" ]]; then
        ct_info "Base worktree exists, updating: $base_path"
        git_pr_base_update "$pr_number"
        echo "$base_path"
        return 0
    fi

    # Create base worktree from PR branch
    mkdir -p "$worktrees_dir"

    # Fetch the PR branch
    ct_debug "Fetching PR branch $pr_branch from $remote..."
    git fetch "$remote" "$pr_branch:$pr_branch" 2>/dev/null || {
        ct_error "Failed to fetch PR branch: $pr_branch"
        return 1
    }

    # Create worktree on PR branch
    ct_info "Creating PR base worktree: $base_path (branch: $pr_branch)"
    if ! git worktree add "$base_path" "$pr_branch" >/dev/null 2>&1; then
        ct_error "Failed to create base worktree"
        return 1
    fi

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
EOF

    ct_info "PR base worktree created: $base_path"
    echo "$base_path"
}

# Update a PR base worktree with latest changes
# Usage: git_pr_base_update <pr_number> [remote]
git_pr_base_update() {
    local pr_number="$1"
    local remote="${2:-origin}"

    local worktrees_dir
    worktrees_dir=$(git_worktrees_dir)
    local base_id="pr-${pr_number}-base"
    local base_path="$worktrees_dir/$base_id"

    if [[ ! -d "$base_path" ]]; then
        ct_error "PR base worktree not found: $base_path"
        return 1
    fi

    ct_info "Updating PR base worktree: $base_path"

    (
        cd "$base_path" || exit 1
        local branch
        branch=$(git rev-parse --abbrev-ref HEAD)

        # Stash any local changes
        git stash -q 2>/dev/null || true

        # Pull latest
        git fetch "$remote" "$branch" 2>/dev/null
        git reset --hard "$remote/$branch" 2>/dev/null

        # Also fetch target branch for merging
        local target_branch
        target_branch=$(grep "base_branch:" ".worktree-info" 2>/dev/null | cut -d' ' -f2)
        if [[ -n "$target_branch" ]]; then
            git fetch "$remote" "$target_branch" 2>/dev/null || true
        fi
    )

    # Update timestamp
    if [[ -f "$base_path/.worktree-info" ]]; then
        local temp_file
        temp_file=$(mktemp)
        grep -v "updated_at:" "$base_path/.worktree-info" > "$temp_file"
        echo "updated_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$temp_file"
        mv "$temp_file" "$base_path/.worktree-info"
    fi

    ct_info "PR base updated"
    return 0
}

# Fork from a PR base worktree for sub-agent work
# Usage: git_worktree_fork <pr_number> <fork_id> <fork_branch>
# Returns: path to the forked worktree
git_worktree_fork() {
    local pr_number="$1"
    local fork_id="$2"
    local fork_branch="$3"

    if [[ -z "$pr_number" || -z "$fork_id" || -z "$fork_branch" ]]; then
        ct_error "Usage: git_worktree_fork <pr_number> <fork_id> <fork_branch>"
        return 1
    fi

    local worktrees_dir
    worktrees_dir=$(git_worktrees_dir)
    local base_id="pr-${pr_number}-base"
    local base_path="$worktrees_dir/$base_id"
    local fork_path="$worktrees_dir/$fork_id"

    # Check base exists
    if [[ ! -d "$base_path" ]]; then
        ct_error "PR base worktree not found: $base_path. Create it first with git_pr_base_create"
        return 1
    fi

    # Check fork doesn't already exist
    if [[ -d "$fork_path" ]]; then
        ct_warn "Fork already exists: $fork_path"
        echo "$fork_path"
        return 0
    fi

    # Get base branch for reference
    local base_branch
    base_branch=$(git_current_branch "$base_path")

    ct_info "Forking from PR base: $base_path -> $fork_path (branch: $fork_branch)"

    # Create new worktree from the base's HEAD
    # This uses git's object sharing so it's memory-efficient
    local base_commit
    base_commit=$(cd "$base_path" && git rev-parse HEAD)

    if ! git worktree add -b "$fork_branch" "$fork_path" "$base_commit" >/dev/null 2>&1; then
        ct_error "Failed to create fork worktree"
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
created_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
status: active
EOF

    # Increment fork count in base
    if [[ -f "$base_path/.worktree-info" ]]; then
        local current_count
        current_count=$(grep "fork_count:" "$base_path/.worktree-info" | cut -d' ' -f2)
        current_count=$((current_count + 1))
        sed -i.bak "s/fork_count:.*/fork_count: $current_count/" "$base_path/.worktree-info" 2>/dev/null || \
            sed -i '' "s/fork_count:.*/fork_count: $current_count/" "$base_path/.worktree-info"
        rm -f "$base_path/.worktree-info.bak"
    fi

    ct_info "Fork created: $fork_path"
    echo "$fork_path"
}

# Merge fork changes back to PR base and push
# Usage: git_fork_merge_back <fork_id> [push]
git_fork_merge_back() {
    local fork_id="$1"
    local push="${2:-true}"

    local worktrees_dir
    worktrees_dir=$(git_worktrees_dir)
    local fork_path="$worktrees_dir/$fork_id"

    if [[ ! -d "$fork_path" ]]; then
        ct_error "Fork worktree not found: $fork_path"
        return 1
    fi

    # Get fork info
    local pr_number base_id fork_branch
    pr_number=$(grep "pr_number:" "$fork_path/.worktree-info" | cut -d' ' -f2)
    base_id=$(grep "forked_from:" "$fork_path/.worktree-info" | cut -d' ' -f2)
    fork_branch=$(grep "branch_name:" "$fork_path/.worktree-info" | cut -d' ' -f2)

    local base_path="$worktrees_dir/$base_id"

    if [[ ! -d "$base_path" ]]; then
        ct_error "Base worktree not found: $base_path"
        return 1
    fi

    local base_branch
    base_branch=$(git_current_branch "$base_path")

    ct_info "Merging fork $fork_id back to base..."

    (
        cd "$base_path" || exit 1

        # Merge fork branch
        if ! git merge "$fork_branch" --no-ff -m "Merge $fork_branch from fork" 2>/dev/null; then
            ct_error "Merge conflict when merging fork back to base"
            git merge --abort 2>/dev/null
            exit 1
        fi

        # Push if requested
        if [[ "$push" == "true" ]]; then
            local remote
            remote=$(grep "remote:" ".worktree-info" | cut -d' ' -f2)
            remote="${remote:-origin}"
            ct_info "Pushing to $remote/$base_branch..."
            git push "$remote" "$base_branch" 2>&1
        fi
    )
}

# Remove a fork worktree and cleanup
# Usage: git_fork_remove <fork_id> [force]
git_fork_remove() {
    local fork_id="$1"
    local force="${2:-false}"

    local worktrees_dir
    worktrees_dir=$(git_worktrees_dir)
    local fork_path="$worktrees_dir/$fork_id"

    if [[ ! -d "$fork_path" ]]; then
        ct_debug "Fork not found: $fork_path"
        return 0
    fi

    # Get fork info before removal
    local pr_number base_id fork_branch
    if [[ -f "$fork_path/.worktree-info" ]]; then
        pr_number=$(grep "pr_number:" "$fork_path/.worktree-info" | cut -d' ' -f2)
        base_id=$(grep "forked_from:" "$fork_path/.worktree-info" | cut -d' ' -f2)
        fork_branch=$(grep "branch_name:" "$fork_path/.worktree-info" | cut -d' ' -f2)
    fi

    # Remove the worktree
    git_worktree_remove "$fork_id" "$force"

    # Delete the fork branch
    if [[ -n "$fork_branch" ]]; then
        git branch -D "$fork_branch" 2>/dev/null || true
    fi

    # Decrement fork count in base
    if [[ -n "$base_id" ]]; then
        local base_path="$worktrees_dir/$base_id"
        if [[ -f "$base_path/.worktree-info" ]]; then
            local current_count
            current_count=$(grep "fork_count:" "$base_path/.worktree-info" | cut -d' ' -f2)
            current_count=$((current_count - 1))
            [[ $current_count -lt 0 ]] && current_count=0
            sed -i.bak "s/fork_count:.*/fork_count: $current_count/" "$base_path/.worktree-info" 2>/dev/null || \
                sed -i '' "s/fork_count:.*/fork_count: $current_count/" "$base_path/.worktree-info"
            rm -f "$base_path/.worktree-info.bak"
        fi
    fi

    ct_info "Fork removed: $fork_id"
}

# Remove PR base worktree and all its forks
# Usage: git_pr_base_remove <pr_number> [force]
git_pr_base_remove() {
    local pr_number="$1"
    local force="${2:-false}"

    local worktrees_dir
    worktrees_dir=$(git_worktrees_dir)
    local base_id="pr-${pr_number}-base"
    local base_path="$worktrees_dir/$base_id"

    if [[ ! -d "$base_path" ]]; then
        ct_debug "PR base not found: $base_path"
        return 0
    fi

    ct_info "Removing PR base and all forks for PR #$pr_number..."

    # Find and remove all forks first
    for dir in "$worktrees_dir"/*/; do
        if [[ -d "$dir" && -f "$dir/.worktree-info" ]]; then
            local forked_from
            forked_from=$(grep "forked_from:" "$dir/.worktree-info" 2>/dev/null | cut -d' ' -f2)
            if [[ "$forked_from" == "$base_id" ]]; then
                local fork_id
                fork_id=$(basename "$dir")
                ct_info "Removing fork: $fork_id"
                git_fork_remove "$fork_id" "$force"
            fi
        fi
    done

    # Remove base worktree
    git_worktree_remove "$base_id" "$force"

    ct_info "PR base and forks removed for PR #$pr_number"
}

# Get PR base worktree path
# Usage: git_pr_base_path <pr_number>
git_pr_base_path() {
    local pr_number="$1"
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
    local worktrees_dir
    worktrees_dir=$(git_worktrees_dir)
    local base_id="pr-${pr_number}-base"

    for dir in "$worktrees_dir"/*/; do
        if [[ -d "$dir" && -f "$dir/.worktree-info" ]]; then
            local forked_from
            forked_from=$(grep "forked_from:" "$dir/.worktree-info" 2>/dev/null | cut -d' ' -f2)
            if [[ "$forked_from" == "$base_id" ]]; then
                local fork_id branch status
                fork_id=$(basename "$dir")
                branch=$(git_current_branch "$dir")
                status="active"
                if ! git_is_clean "$dir"; then
                    status="dirty"
                fi
                echo "$fork_id|$branch|$status|$dir"
            fi
        fi
    done
}

# Get PR base info as JSON
git_pr_base_info() {
    local pr_number="$1"
    local base_path
    base_path=$(git_pr_base_path "$pr_number")

    if [[ -z "$base_path" ]]; then
        echo "{}"
        return 1
    fi

    local branch status fork_count
    branch=$(git_current_branch "$base_path")
    status=$(git_worktree_status "pr-${pr_number}-base")
    fork_count=$(grep "fork_count:" "$base_path/.worktree-info" 2>/dev/null | cut -d' ' -f2)
    fork_count="${fork_count:-0}"

    # List active forks
    local forks_json="["
    local first=true
    while IFS='|' read -r fork_id fork_branch fork_status fork_path; do
        if [[ -n "$fork_id" ]]; then
            [[ "$first" == "true" ]] || forks_json+=","
            forks_json+="{\"id\":\"$fork_id\",\"branch\":\"$fork_branch\",\"status\":\"$fork_status\"}"
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
  "forks": $forks_json
}
EOF
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
