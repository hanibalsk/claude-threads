#!/usr/bin/env bash
#
# thread-runner.sh - Individual thread executor for claude-threads
#
# Executes a single thread with the appropriate mode and handles
# state transitions, event publishing, and error handling.
#
# Usage:
#   ./scripts/thread-runner.sh --thread-id <id> [--background]
#   ./scripts/thread-runner.sh --create --name <name> --mode <mode> --template <template>
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Source libraries
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/log.sh"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/db.sh"
source "$ROOT_DIR/lib/state.sh"
source "$ROOT_DIR/lib/blackboard.sh"
source "$ROOT_DIR/lib/template.sh"
source "$ROOT_DIR/lib/claude.sh"
source "$ROOT_DIR/lib/merge.sh"
source "$ROOT_DIR/lib/checkpoint.sh"
source "$ROOT_DIR/lib/groups.sh"

# ============================================================
# Configuration
# ============================================================

THREAD_ID=""
THREAD_NAME=""
THREAD_MODE="automatic"
THREAD_TEMPLATE=""
THREAD_WORKFLOW=""
THREAD_CONTEXT="{}"
RUN_BACKGROUND=0
CREATE_MODE=0
DATA_DIR=""
USE_WORKTREE=0
WORKTREE_BRANCH=""
WORKTREE_BASE="main"

# ============================================================
# Argument Parsing
# ============================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run a thread:
  --thread-id ID        Thread ID to run
  --background          Run in background mode

Create and run a thread:
  --create              Create a new thread
  --name NAME           Thread name (required with --create)
  --mode MODE           Thread mode: automatic, semi-auto, interactive, sleeping
  --template FILE       Prompt template file
  --workflow FILE       Workflow file (optional)
  --context JSON        Thread context as JSON

Worktree options:
  --worktree            Create thread with isolated git worktree
  --worktree-branch BR  Branch name for worktree (auto-generated if not specified)
  --worktree-base BASE  Base branch to create from (default: main)

Common options:
  --data-dir DIR        Data directory (default: .claude-threads)
  --help                Show this help

Examples:
  $(basename "$0") --thread-id thread-123456
  $(basename "$0") --create --name "developer" --mode automatic --template prompts/developer.md
  $(basename "$0") --thread-id thread-123456 --background
  $(basename "$0") --create --name "epic-7a" --worktree --worktree-base develop
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --thread-id)
                THREAD_ID="$2"
                shift 2
                ;;
            --name)
                THREAD_NAME="$2"
                shift 2
                ;;
            --mode)
                THREAD_MODE="$2"
                shift 2
                ;;
            --template)
                THREAD_TEMPLATE="$2"
                shift 2
                ;;
            --workflow)
                THREAD_WORKFLOW="$2"
                shift 2
                ;;
            --context)
                THREAD_CONTEXT="$2"
                shift 2
                ;;
            --background)
                RUN_BACKGROUND=1
                shift
                ;;
            --create)
                CREATE_MODE=1
                shift
                ;;
            --data-dir)
                DATA_DIR="$2"
                shift 2
                ;;
            --worktree)
                USE_WORKTREE=1
                shift
                ;;
            --worktree-branch)
                WORKTREE_BRANCH="$2"
                shift 2
                ;;
            --worktree-base)
                WORKTREE_BASE="$2"
                shift 2
                ;;
            --help|-h)
                usage
                ;;
            *)
                ct_die "Unknown option: $1"
                ;;
        esac
    done

    # Validate arguments
    if [[ $CREATE_MODE -eq 1 ]]; then
        if [[ -z "$THREAD_NAME" ]]; then
            ct_die "Thread name required with --create"
        fi
    else
        if [[ -z "$THREAD_ID" ]]; then
            ct_die "Thread ID required (use --thread-id)"
        fi
    fi
}

# ============================================================
# Initialization
# ============================================================

init() {
    # Set project root first (must be absolute path for worktree support)
    export CT_PROJECT_ROOT="${CT_PROJECT_ROOT:-$(pwd)}"

    # Ensure CT_PROJECT_ROOT is absolute
    if [[ ! "$CT_PROJECT_ROOT" = /* ]]; then
        CT_PROJECT_ROOT="$(cd "$CT_PROJECT_ROOT" && pwd)"
    fi

    # Set data directory (must be absolute path for worktree support)
    if [[ -z "$DATA_DIR" ]]; then
        DATA_DIR=$(ct_data_dir)
    fi

    # Ensure DATA_DIR is absolute
    if [[ ! "$DATA_DIR" = /* ]]; then
        DATA_DIR="$(cd "$(dirname "$DATA_DIR")" && pwd)/$(basename "$DATA_DIR")"
    fi

    # Load configuration
    config_load "$DATA_DIR/config.yaml"

    # Initialize components
    log_init "thread-runner" "$DATA_DIR/logs/thread-runner.log"
    log_set_level "$(config_get 'orchestrator.log_level' 'info')"

    db_init "$DATA_DIR"
    bb_init "$DATA_DIR"
    template_init "$DATA_DIR/templates"
    claude_init "$DATA_DIR"

    log_info "Thread runner initialized"
}

# ============================================================
# Thread Creation
# ============================================================

create_thread() {
    log_info "Creating thread: $THREAD_NAME (mode=$THREAD_MODE)"

    if [[ $USE_WORKTREE -eq 1 ]]; then
        # Create thread with worktree
        log_info "Creating with worktree (base=$WORKTREE_BASE)"
        THREAD_ID=$(thread_create_with_worktree "$THREAD_NAME" "$THREAD_MODE" "$WORKTREE_BRANCH" "$WORKTREE_BASE" "$THREAD_TEMPLATE" "$THREAD_CONTEXT")

        if [[ -z "$THREAD_ID" ]]; then
            ct_die "Failed to create thread with worktree"
        fi
    else
        # Create thread in database
        THREAD_ID=$(thread_create "$THREAD_NAME" "$THREAD_MODE" "$THREAD_TEMPLATE" "$THREAD_WORKFLOW" "$THREAD_CONTEXT")
    fi

    log_info "Thread created: $THREAD_ID"

    # Auto-assign to group based on configuration
    group_auto_assign "$THREAD_ID" "$THREAD_NAME"

    # Transition to ready
    thread_ready "$THREAD_ID"
}

# ============================================================
# Thread Execution
# ============================================================

run_thread() {
    local thread_id="$1"

    # Set current thread context
    export CT_CURRENT_THREAD="$thread_id"

    # Load thread info
    local thread_json
    thread_json=$(thread_get "$thread_id")

    if [[ -z "$thread_json" ]]; then
        ct_die "Thread not found: $thread_id"
    fi

    local name mode status template context worktree
    name=$(printf '%s' "$thread_json" | jq -r '.name')
    mode=$(printf '%s' "$thread_json" | jq -r '.mode')
    status=$(printf '%s' "$thread_json" | jq -r '.status')
    template=$(printf '%s' "$thread_json" | jq -r '.template // empty')
    # Parse context from JSON string, keep as compact JSON
    context=$(printf '%s' "$thread_json" | jq -c '(.context // "{}") | if type == "string" then fromjson else . end')
    worktree=$(printf '%s' "$thread_json" | jq -r '.worktree // empty')

    log_info "Running thread: $thread_id ($name, mode=$mode, status=$status)"

    # If thread has a worktree, change to that directory
    local original_dir=""
    if [[ -n "$worktree" && -d "$worktree" ]]; then
        original_dir=$(pwd)
        log_info "Using worktree: $worktree"
        cd "$worktree"
        export CT_WORKTREE_PATH="$worktree"

        # Add worktree info to context for templates
        context=$(printf '%s' "$context" | jq --arg wt "$worktree" '. + {worktree_path: $wt}')

        # Update worktree status
        thread_update_worktree_status "$thread_id"
    fi

    # Check status
    local session_id=""
    case "$status" in
        created)
            thread_ready "$thread_id"
            status="ready"
            ;;
        running)
            # Already running (set by run_in_background), get existing session
            session_id=$(echo "$thread_json" | jq -r '.session_id // empty')
            log_info "Thread already running (session=$session_id)"
            ;;
        completed|failed)
            log_warn "Thread already in terminal state: $status"
            return 0
            ;;
        blocked)
            log_error "Thread is blocked, cannot run"
            return 1
            ;;
    esac

    # Start running (if not already)
    if [[ -z "$session_id" ]]; then
        session_id=$(thread_run "$thread_id")
    fi

    # Render prompt template if specified
    local prompt=""
    if [[ -n "$template" ]]; then
        if prompt=$(template_render "$template" "$context"); then
            log_debug "Template rendered: ${#prompt} chars"
        else
            log_error "Failed to render template: $template"
            thread_fail "$thread_id" "Template rendering failed"
            return 1
        fi
    fi

    # Execute based on mode
    local exit_code=0
    case "$mode" in
        automatic)
            run_automatic "$thread_id" "$session_id" "$prompt"
            exit_code=$?
            ;;
        semi-auto)
            run_semi_auto "$thread_id" "$session_id" "$prompt"
            exit_code=$?
            ;;
        interactive)
            run_interactive "$thread_id" "$session_id" "$prompt"
            exit_code=$?
            ;;
        sleeping)
            # Just mark as sleeping, orchestrator handles wake
            thread_sleep "$thread_id" "$(config_get 'threads.default_timeout' 3600)s"
            return 0
            ;;
    esac

    # Handle result
    if [[ $exit_code -eq 0 ]]; then
        # If using worktree, update status and handle merge
        if [[ -n "$worktree" && -d "$worktree" ]]; then
            thread_update_worktree_status "$thread_id"

            # Check if we should auto-push (legacy, merge handles this now)
            local auto_push
            auto_push=$(echo "$context" | jq -r '.auto_push // false')
            if [[ "$auto_push" == "true" ]]; then
                log_info "Auto-pushing worktree changes"
                thread_push_worktree "$thread_id" || log_warn "Auto-push failed"
            fi

            # Check if thread is part of a group with consolidated PR strategy
            local group_id
            group_id=$(db_scalar "SELECT group_id FROM threads WHERE id = $(db_quote "$thread_id")")

            if [[ -n "$group_id" && "$group_id" != "null" ]]; then
                local pr_strategy
                pr_strategy=$(db_scalar "SELECT pr_strategy FROM thread_groups WHERE id = $(db_quote "$group_id")")

                if [[ "$pr_strategy" == "consolidated" ]]; then
                    log_info "Thread is part of consolidated PR group, deferring merge"
                    # Just push the branch, let group handle PR
                    thread_push_worktree "$thread_id" || log_warn "Push failed"
                else
                    # Individual PR strategy - use normal merge flow
                    log_info "Executing merge strategy for completed thread"
                    if ! merge_on_complete "$thread_id"; then
                        log_warn "Merge strategy execution had issues, thread still completing"
                    fi
                fi
            else
                # Not in a group - use normal merge flow
                log_info "Executing merge strategy for completed thread"
                if ! merge_on_complete "$thread_id"; then
                    log_warn "Merge strategy execution had issues, thread still completing"
                fi
            fi
        fi

        thread_complete "$thread_id"

        # Notify group of completion (triggers consolidated PR check)
        group_member_complete "$thread_id"
    else
        log_error "Thread execution failed with exit code: $exit_code"
        thread_fail "$thread_id" "Execution failed with exit code $exit_code"
    fi

    # Restore original directory
    if [[ -n "$original_dir" ]]; then
        cd "$original_dir"
    fi

    return $exit_code
}

# ============================================================
# Execution Modes
# ============================================================

run_automatic() {
    local thread_id="$1"
    local session_id="$2"
    local prompt="$3"

    log_info "Running in automatic mode"

    local output_file="$DATA_DIR/tmp/thread-${thread_id}-output.txt"
    local max_turns
    max_turns=$(config_get_int 'threads.default_max_turns' 80)

    # Execute with Claude
    if [[ -n "$prompt" ]]; then
        claude_execute "$prompt" "automatic" "$session_id" "$output_file"
    else
        log_warn "No prompt provided for automatic execution"
        return 1
    fi

    local exit_code=$?

    # Process output for events
    if [[ -f "$output_file" ]]; then
        process_output "$thread_id" "$output_file"
    fi

    return $exit_code
}

run_semi_auto() {
    local thread_id="$1"
    local session_id="$2"
    local prompt="$3"

    log_info "Running in semi-auto mode"

    # Semi-auto runs in foreground with prompt
    if [[ -n "$prompt" ]]; then
        claude_execute "$prompt" "semi-auto" "$session_id"
    else
        claude_resume "$session_id"
    fi

    return $?
}

run_interactive() {
    local thread_id="$1"
    local session_id="$2"
    local prompt="$3"

    log_info "Running in interactive mode"

    # Interactive is fully foreground
    if [[ -n "$prompt" ]]; then
        claude_execute "$prompt" "interactive" "$session_id"
    else
        claude_resume "$session_id"
    fi

    return $?
}

# ============================================================
# Output Processing
# ============================================================

process_output() {
    local thread_id="$1"
    local output_file="$2"

    log_debug "Processing output: $output_file"

    local output
    output=$(cat "$output_file")

    # Look for event markers in output
    local events
    events=$(claude_parse_events "$output")

    while IFS= read -r event_json; do
        [[ -z "$event_json" ]] && continue

        local event_type
        event_type=$(echo "$event_json" | jq -r '.event // empty')

        if [[ -n "$event_type" ]]; then
            log_info "Publishing event from output: $event_type"
            bb_publish "$event_type" "$event_json" "$thread_id"

            # Handle special events
            case "$event_type" in
                BLOCKED)
                    local reason
                    reason=$(echo "$event_json" | jq -r '.reason // "Unknown"')
                    thread_block "$thread_id" "$reason"
                    ;;
                PHASE_COMPLETED|STORY_COMPLETED)
                    # Update thread phase if specified
                    local next_phase
                    next_phase=$(echo "$event_json" | jq -r '.next_phase // empty')
                    if [[ -n "$next_phase" ]]; then
                        thread_set_phase "$thread_id" "$next_phase"
                    fi
                    ;;
            esac
        fi
    done <<< "$events"

    # Check for completion/error indicators
    if claude_is_complete "$output"; then
        log_info "Thread completed successfully"
        return 0
    elif claude_is_blocked "$output"; then
        log_warn "Thread is blocked"
        return 2
    elif claude_is_error "$output"; then
        log_error "Thread encountered an error"
        return 1
    fi

    return 0
}

# ============================================================
# Background Execution
# ============================================================

run_in_background() {
    local thread_id="$1"

    log_info "Starting thread in background: $thread_id"

    # Mark as running BEFORE spawning background process
    # This prevents the orchestrator from trying to start it again
    local session_id
    session_id=$(ct_generate_uuid)
    db_thread_set_status "$thread_id" "running"
    db_thread_set_session "$thread_id" "$session_id"
    db_session_upsert "$session_id" "$thread_id"

    # Create PID file
    local pid_file="$DATA_DIR/tmp/thread-${thread_id}.pid"

    # Run in background (thread_run will see it's already running and use the session)
    (
        run_thread "$thread_id"
        rm -f "$pid_file"
    ) &

    local pid=$!
    echo "$pid" > "$pid_file"

    log_info "Thread started in background: PID=$pid"
    echo "$pid"
}

# ============================================================
# Signal Handling
# ============================================================

# Track the signal received for checkpoint
_SIGNAL_RECEIVED=""

cleanup() {
    local signal="${_SIGNAL_RECEIVED:-UNKNOWN}"
    log_info "Thread runner shutting down (signal: $signal)..."

    if [[ -n "$THREAD_ID" ]]; then
        local status
        status=$(db_scalar "SELECT status FROM threads WHERE id = $(db_quote "$THREAD_ID")")

        if [[ "$status" == "running" ]]; then
            log_warn "Thread interrupted, creating checkpoint before exit"

            # Create checkpoint to preserve work
            local checkpoint_id
            checkpoint_id=$(checkpoint_on_signal "$THREAD_ID" "$signal")

            if [[ -n "$checkpoint_id" ]]; then
                log_info "Checkpoint created: $checkpoint_id"
            fi

            # Mark as waiting (can be resumed later)
            thread_wait "$THREAD_ID" "Interrupted by $signal"
        fi
    fi

    exit 0
}

handle_sigterm() {
    _SIGNAL_RECEIVED="SIGTERM"
    cleanup
}

handle_sigint() {
    _SIGNAL_RECEIVED="SIGINT"
    cleanup
}

trap handle_sigterm SIGTERM
trap handle_sigint SIGINT

# ============================================================
# Main
# ============================================================

main() {
    parse_args "$@"
    init

    # Create thread if requested
    if [[ $CREATE_MODE -eq 1 ]]; then
        create_thread
    fi

    # Run thread
    if [[ $RUN_BACKGROUND -eq 1 ]]; then
        run_in_background "$THREAD_ID"
    else
        run_thread "$THREAD_ID"
    fi
}

main "$@"
