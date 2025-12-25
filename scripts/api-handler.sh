#!/usr/bin/env bash
#
# api-handler.sh - API request handler for claude-threads
#
# Called by the Python API server to handle requests.
# Receives handler name and arguments via environment variables.
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

# Initialize
DATA_DIR="${CT_DATA_DIR:-$(ct_data_dir)}"
config_load "$DATA_DIR/config.yaml" 2>/dev/null || true
db_init "$DATA_DIR" 2>/dev/null || true
bb_init "$DATA_DIR" 2>/dev/null || true
state_init "$DATA_DIR" 2>/dev/null || true

# Get handler and args
HANDLER="${API_HANDLER:-}"
ARGS="${API_ARGS:-[]}"

# Validate handler (security: whitelist allowed handlers)
if [[ -n "$HANDLER" ]] && ! ct_validate_api_handler "$HANDLER"; then
    echo '{"error": "Invalid handler"}'
    exit 1
fi

# Validate ARGS is valid JSON
if ! echo "$ARGS" | jq empty 2>/dev/null; then
    ARGS="[]"
fi

# Parse args
arg1=$(echo "$ARGS" | jq -r '.[0] // empty')
arg2=$(echo "$ARGS" | jq -r '.[1] // empty')

case "$HANDLER" in
    status)
        threads_total=$(db_scalar "SELECT COUNT(*) FROM threads")
        threads_running=$(db_scalar "SELECT COUNT(*) FROM threads WHERE status = 'running'")
        events_pending=$(db_scalar "SELECT COUNT(*) FROM events WHERE processed = 0")

        orchestrator_running="false"
        if [[ -f "$DATA_DIR/orchestrator.pid" ]]; then
            pid=$(cat "$DATA_DIR/orchestrator.pid")
            if kill -0 "$pid" 2>/dev/null; then
                orchestrator_running="true"
            fi
        fi

        jq -n \
            --arg total "$threads_total" \
            --arg running "$threads_running" \
            --arg events "$events_pending" \
            --arg orch "$orchestrator_running" \
            '{
                threads: {total: ($total | tonumber), running: ($running | tonumber)},
                events_pending: ($events | tonumber),
                orchestrator_running: ($orch == "true")
            }'
        ;;

    list_threads)
        query_params="$arg1"
        status=""
        mode=""
        limit="50"

        if [[ -n "$query_params" ]]; then
            status=$(ct_query_param "$query_params" "status")
            mode=$(ct_query_param "$query_params" "mode")
            limit=$(ct_query_param "$query_params" "limit" "50")
        fi

        # Security: validate and sanitize inputs
        if [[ -n "$status" ]] && ! ct_validate_status "$status"; then
            status=""  # Invalid status, ignore filter
        fi
        if [[ -n "$mode" ]] && ! ct_validate_mode "$mode"; then
            mode=""  # Invalid mode, ignore filter
        fi
        # Sanitize limit to prevent SQL injection (must be integer 1-1000)
        limit=$(ct_sanitize_int "$limit" 50 1 1000)

        sql="SELECT * FROM threads WHERE 1=1"
        [[ -n "$status" ]] && sql+=" AND status = $(db_quote "$status")"
        [[ -n "$mode" ]] && sql+=" AND mode = $(db_quote "$mode")"
        sql+=" ORDER BY updated_at DESC LIMIT $limit"

        db_query "$sql"
        ;;

    get_thread)
        thread_id="$arg1"

        # Security: validate thread ID format
        if ! ct_validate_thread_id "$thread_id"; then
            echo '{"error": "Invalid thread ID format"}'
            exit 1
        fi

        thread=$(thread_get "$thread_id")

        if [[ -z "$thread" ]]; then
            echo '{"error": "Thread not found"}'
            exit 1
        fi

        echo "$thread"
        ;;

    create_thread)
        body="$arg1"

        name=$(echo "$body" | jq -r '.name // empty')
        mode=$(echo "$body" | jq -r '.mode // "automatic"')
        template=$(echo "$body" | jq -r '.template // empty')
        workflow=$(echo "$body" | jq -r '.workflow // empty')
        context=$(echo "$body" | jq -c '.context // {}')

        # Worktree parameters
        use_worktree=$(echo "$body" | jq -r '.worktree // false')
        worktree_branch=$(echo "$body" | jq -r '.worktree_branch // empty')
        worktree_base=$(echo "$body" | jq -r '.worktree_base // "main"')

        if [[ -z "$name" ]]; then
            echo '{"error": "Name is required"}'
            exit 1
        fi

        thread_id=""
        worktree_path=""

        if [[ "$use_worktree" == "true" ]]; then
            # Create thread with worktree isolation
            thread_id=$(thread_create_with_worktree "$name" "$mode" "$worktree_branch" "$worktree_base" "$template" "$context")
            worktree_path=$(thread_get_worktree "$thread_id" 2>/dev/null || echo "")

            jq -n \
                --arg id "$thread_id" \
                --arg name "$name" \
                --arg mode "$mode" \
                --arg worktree "$worktree_path" \
                '{id: $id, name: $name, mode: $mode, status: "created", worktree: $worktree}'
        else
            thread_id=$(thread_create "$name" "$mode" "$template" "$workflow" "$context")

            jq -n \
                --arg id "$thread_id" \
                --arg name "$name" \
                --arg mode "$mode" \
                '{id: $id, name: $name, mode: $mode, status: "created"}'
        fi
        ;;

    start_thread)
        thread_id="$arg1"

        # Security: validate thread ID format
        if ! ct_validate_thread_id "$thread_id"; then
            echo '{"error": "Invalid thread ID format"}'
            exit 1
        fi

        thread=$(thread_get "$thread_id")
        if [[ -z "$thread" ]]; then
            echo '{"error": "Thread not found"}'
            exit 1
        fi

        status=$(echo "$thread" | jq -r '.status')
        if [[ "$status" == "created" ]]; then
            thread_ready "$thread_id"
        fi

        "$SCRIPT_DIR/thread-runner.sh" --thread-id "$thread_id" --data-dir "$DATA_DIR" --background

        jq -n --arg id "$thread_id" '{id: $id, status: "started"}'
        ;;

    stop_thread)
        thread_id="$arg1"

        # Security: validate thread ID format
        if ! ct_validate_thread_id "$thread_id"; then
            echo '{"error": "Invalid thread ID format"}'
            exit 1
        fi

        pid_file="$DATA_DIR/tmp/thread-${thread_id}.pid"
        if [[ -f "$pid_file" ]]; then
            pid=$(cat "$pid_file")
            kill -TERM "$pid" 2>/dev/null || true
            rm -f "$pid_file"
        fi

        thread_wait "$thread_id" "Stopped via API"

        jq -n --arg id "$thread_id" '{id: $id, status: "stopped"}'
        ;;

    delete_thread)
        thread_id="$arg1"

        # Security: validate thread ID format
        if ! ct_validate_thread_id "$thread_id"; then
            echo '{"error": "Invalid thread ID format"}'
            exit 1
        fi

        # Stop if running
        pid_file="$DATA_DIR/tmp/thread-${thread_id}.pid"
        if [[ -f "$pid_file" ]]; then
            pid=$(cat "$pid_file")
            kill -TERM "$pid" 2>/dev/null || true
            rm -f "$pid_file"
        fi

        thread_delete "$thread_id"

        jq -n --arg id "$thread_id" '{id: $id, deleted: true}'
        ;;

    list_events)
        query_params="$arg1"
        type=""
        source=""
        limit="100"

        if [[ -n "$query_params" ]]; then
            type=$(ct_query_param "$query_params" "type")
            source=$(ct_query_param "$query_params" "source")
            limit=$(ct_query_param "$query_params" "limit" "100")
        fi

        # Security: sanitize limit to prevent SQL injection
        limit=$(ct_sanitize_int "$limit" 100 1 1000)

        bb_history "$limit" "$type" "$source"
        ;;

    publish_event)
        body="$arg1"

        type=$(echo "$body" | jq -r '.type // empty')
        data=$(echo "$body" | jq -c '.data // {}')
        source=$(echo "$body" | jq -r '.source // "api"')
        targets=$(echo "$body" | jq -r '.targets // "*"')

        if [[ -z "$type" ]]; then
            echo '{"error": "Event type is required"}'
            exit 1
        fi

        bb_publish "$type" "$data" "$source" "$targets"

        jq -n --arg type "$type" '{type: $type, published: true}'
        ;;

    get_messages)
        thread_id="$arg1"
        bb_inbox "$thread_id"
        ;;

    send_message)
        body="$arg1"

        to_thread=$(echo "$body" | jq -r '.to // empty')
        type=$(echo "$body" | jq -r '.type // "MESSAGE"')
        content=$(echo "$body" | jq -c '.content // {}')
        priority=$(echo "$body" | jq -r '.priority // 0')

        if [[ -z "$to_thread" ]]; then
            echo '{"error": "Target thread is required"}'
            exit 1
        fi

        bb_send "$to_thread" "$type" "$content" "$priority"

        jq -n --arg to "$to_thread" --arg type "$type" '{to: $to, type: $type, sent: true}'
        ;;

    # =========================================================================
    # PR Lifecycle Management Endpoints
    # =========================================================================

    pr_status)
        # GET /api/pr/:number/status - Complete PR lifecycle status
        pr_number="$arg1"

        # Security: validate PR number
        if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
            echo '{"error": "Invalid PR number"}'
            exit 1
        fi

        # Get lifecycle status from database
        status=$(db_pr_lifecycle_status "$pr_number")

        if [[ -z "$status" || "$status" == "null" ]]; then
            # PR not being watched, return minimal info
            jq -n --arg pr "$pr_number" '{
                pr_number: ($pr | tonumber),
                watched: false,
                error: "PR not being watched"
            }'
        else
            echo "$status"
        fi
        ;;

    pr_comments)
        # GET /api/pr/:number/comments - All comments with states
        pr_number="$arg1"

        # Security: validate PR number
        if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
            echo '{"error": "Invalid PR number"}'
            exit 1
        fi

        comments=$(db_pr_comments_get "$pr_number")

        if [[ -z "$comments" ]]; then
            echo '[]'
        else
            echo "$comments"
        fi
        ;;

    pr_conflicts)
        # GET /api/pr/:number/conflicts - Merge conflict status
        pr_number="$arg1"

        # Security: validate PR number
        if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
            echo '{"error": "Invalid PR number"}'
            exit 1
        fi

        conflict=$(db_merge_conflict_get_active "$pr_number")

        if [[ -z "$conflict" || "$conflict" == "null" ]]; then
            jq -n --arg pr "$pr_number" '{
                pr_number: ($pr | tonumber),
                has_conflict: false
            }'
        else
            echo "$conflict" | jq '. + {has_conflict: true}'
        fi
        ;;

    pr_config)
        # PUT /api/pr/:number/config - Update PR config
        pr_number="$arg1"
        body="$arg2"

        # Security: validate PR number
        if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
            echo '{"error": "Invalid PR number"}'
            exit 1
        fi

        auto_merge=$(echo "$body" | jq -r '.auto_merge // empty')
        interactive=$(echo "$body" | jq -r '.interactive // empty')
        poll_interval=$(echo "$body" | jq -r '.poll_interval // empty')

        # Update config
        db_pr_config_update "$pr_number" "$auto_merge" "$interactive" "$poll_interval"

        # Return updated config
        config=$(db_pr_config_get "$pr_number")
        echo "$config"
        ;;

    pr_watch)
        # POST /api/pr/:number/watch - Start watching a PR
        pr_number="$arg1"
        body="$arg2"

        # Security: validate PR number
        if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
            echo '{"error": "Invalid PR number"}'
            exit 1
        fi

        auto_merge=$(echo "$body" | jq -r '.auto_merge // "false"')
        interactive=$(echo "$body" | jq -r '.interactive // "false"')
        poll_interval=$(echo "$body" | jq -r '.poll_interval // "30"')

        # Get repository info
        repo=$(git remote get-url origin 2>/dev/null | sed 's/.*github.com[:/]\(.*\)\.git/\1/' || echo "")

        if [[ -z "$repo" ]]; then
            echo '{"error": "Could not determine repository"}'
            exit 1
        fi

        # Get PR info from GitHub
        pr_info=$(gh pr view "$pr_number" --json headRefName,baseRefName 2>/dev/null || echo "")

        if [[ -z "$pr_info" ]]; then
            echo '{"error": "PR not found on GitHub"}'
            exit 1
        fi

        branch=$(echo "$pr_info" | jq -r '.headRefName')
        base_branch=$(echo "$pr_info" | jq -r '.baseRefName')

        # Create worktree for the PR
        worktree_path="$DATA_DIR/worktrees/pr-$pr_number"

        if [[ ! -d "$worktree_path" ]]; then
            git worktree add "$worktree_path" "$branch" 2>/dev/null || {
                echo '{"error": "Failed to create worktree"}'
                exit 1
            }
        fi

        # Create PR watch entry
        watch_id=$(db_pr_watch_create "$pr_number" "$branch" "$worktree_path")

        # Set config
        [[ "$auto_merge" == "true" ]] && auto_merge_int=1 || auto_merge_int=0
        [[ "$interactive" == "true" ]] && interactive_int=1 || interactive_int=0
        db_pr_config_update "$pr_number" "$auto_merge_int" "$interactive_int" "$poll_interval"

        # Create context for the PR shepherd
        context=$(jq -n \
            --arg pr "$pr_number" \
            --arg repo "$repo" \
            --arg branch "$branch" \
            --arg base "$base_branch" \
            --arg worktree "$worktree_path" \
            --arg auto_merge "$auto_merge" \
            --arg interactive "$interactive" \
            --arg poll "$poll_interval" \
            '{
                pr_number: ($pr | tonumber),
                repo: $repo,
                branch: $branch,
                base_branch: $base,
                worktree_path: $worktree,
                auto_merge: ($auto_merge == "true"),
                interactive_mode: ($interactive == "true"),
                poll_interval: ($poll | tonumber)
            }')

        # Spawn PR shepherd thread
        thread_id=$(thread_create "pr-shepherd-$pr_number" "automatic" "prompts/pr-lifecycle.md" "" "$context")
        thread_ready "$thread_id"

        # Update watch with shepherd thread ID
        db_exec "UPDATE pr_watches SET shepherd_thread_id = $(db_quote "$thread_id") WHERE id = $watch_id"

        jq -n \
            --arg pr "$pr_number" \
            --arg thread "$thread_id" \
            --arg worktree "$worktree_path" \
            '{
                pr_number: ($pr | tonumber),
                shepherd_thread_id: $thread,
                worktree_path: $worktree,
                watching: true
            }'
        ;;

    pr_unwatch)
        # DELETE /api/pr/:number/watch - Stop watching a PR
        pr_number="$arg1"

        # Security: validate PR number
        if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
            echo '{"error": "Invalid PR number"}'
            exit 1
        fi

        # Get watch info
        watch=$(db_query "SELECT * FROM pr_watches WHERE pr_number = $pr_number AND status != 'completed' LIMIT 1")

        if [[ -z "$watch" || "$watch" == "[]" ]]; then
            echo '{"error": "PR not being watched"}'
            exit 1
        fi

        shepherd_thread=$(echo "$watch" | jq -r '.[0].shepherd_thread_id // empty')
        worktree_path=$(echo "$watch" | jq -r '.[0].worktree_path // empty')

        # Stop shepherd thread if running
        if [[ -n "$shepherd_thread" ]]; then
            pid_file="$DATA_DIR/tmp/thread-${shepherd_thread}.pid"
            if [[ -f "$pid_file" ]]; then
                pid=$(cat "$pid_file")
                kill -TERM "$pid" 2>/dev/null || true
                rm -f "$pid_file"
            fi
            thread_complete "$shepherd_thread" "Unwatched via API"
        fi

        # Update watch status
        db_exec "UPDATE pr_watches SET status = 'completed' WHERE pr_number = $pr_number"

        # Clean up worktree
        if [[ -n "$worktree_path" && -d "$worktree_path" ]]; then
            git worktree remove "$worktree_path" --force 2>/dev/null || true
        fi

        jq -n --arg pr "$pr_number" '{
            pr_number: ($pr | tonumber),
            watching: false
        }'
        ;;

    pr_list)
        # GET /api/pr/list - List all watched PRs
        query_params="$arg1"
        status=""
        limit="50"

        if [[ -n "$query_params" ]]; then
            status=$(ct_query_param "$query_params" "status")
            limit=$(ct_query_param "$query_params" "limit" "50")
        fi

        # Sanitize limit
        limit=$(ct_sanitize_int "$limit" 50 1 100)

        sql="SELECT * FROM pr_watches WHERE 1=1"
        [[ -n "$status" ]] && sql+=" AND status = $(db_quote "$status")"
        sql+=" ORDER BY created_at DESC LIMIT $limit"

        db_query "$sql"
        ;;

    # =========================================================================
    # Orchestrator Control Endpoints
    # =========================================================================

    orchestrator_control)
        # POST /api/orchestrator/control - Start/stop control thread
        body="$arg1"

        action=$(echo "$body" | jq -r '.action // "start"')
        auto_merge=$(echo "$body" | jq -r '.auto_merge // "false"')
        interactive=$(echo "$body" | jq -r '.interactive // "false"')

        case "$action" in
            start)
                # Check if control thread already exists
                if [[ -f "$DATA_DIR/control-thread.id" ]]; then
                    existing_id=$(cat "$DATA_DIR/control-thread.id")
                    thread=$(thread_get "$existing_id" 2>/dev/null || echo "")

                    if [[ -n "$thread" ]]; then
                        status=$(echo "$thread" | jq -r '.status')
                        if [[ "$status" == "running" || "$status" == "ready" ]]; then
                            jq -n \
                                --arg id "$existing_id" \
                                --arg status "$status" \
                                '{
                                    control_thread_id: $id,
                                    status: $status,
                                    message: "Control thread already running"
                                }'
                            exit 0
                        fi
                    fi
                fi

                # Start orchestrator daemon if not running
                if [[ ! -f "$DATA_DIR/orchestrator.pid" ]] || ! kill -0 "$(cat "$DATA_DIR/orchestrator.pid")" 2>/dev/null; then
                    "$SCRIPT_DIR/orchestrator.sh" start --data-dir "$DATA_DIR"
                    sleep 1
                fi

                # Create context for control thread
                [[ "$auto_merge" == "true" ]] && mode="auto-merge" || mode="notify-only"
                [[ "$interactive" == "true" ]] && interactive_flag="true" || interactive_flag="false"

                context=$(jq -n \
                    --arg mode "$mode" \
                    --arg auto_merge "$auto_merge" \
                    --arg interactive "$interactive_flag" \
                    '{
                        mode: $mode,
                        auto_merge: ($auto_merge == "true"),
                        interactive: ($interactive == "true"),
                        poll_interval: 30
                    }')

                # Create and start control thread
                thread_id=$(thread_create "orchestrator-control" "automatic" "prompts/orchestrator-control.md" "" "$context")
                echo "$thread_id" > "$DATA_DIR/control-thread.id"
                thread_ready "$thread_id"

                # Start thread runner
                "$SCRIPT_DIR/thread-runner.sh" --thread-id "$thread_id" --data-dir "$DATA_DIR" --background

                jq -n \
                    --arg id "$thread_id" \
                    '{
                        control_thread_id: $id,
                        status: "started",
                        message: "Control thread started"
                    }'
                ;;

            stop)
                if [[ ! -f "$DATA_DIR/control-thread.id" ]]; then
                    echo '{"error": "No control thread found"}'
                    exit 1
                fi

                thread_id=$(cat "$DATA_DIR/control-thread.id")

                # Stop thread
                pid_file="$DATA_DIR/tmp/thread-${thread_id}.pid"
                if [[ -f "$pid_file" ]]; then
                    pid=$(cat "$pid_file")
                    kill -TERM "$pid" 2>/dev/null || true
                    rm -f "$pid_file"
                fi

                thread_complete "$thread_id" "Stopped via API"
                rm -f "$DATA_DIR/control-thread.id"

                jq -n --arg id "$thread_id" '{
                    control_thread_id: $id,
                    status: "stopped",
                    message: "Control thread stopped"
                }'
                ;;

            status)
                if [[ ! -f "$DATA_DIR/control-thread.id" ]]; then
                    jq -n '{
                        running: false,
                        message: "No control thread"
                    }'
                    exit 0
                fi

                thread_id=$(cat "$DATA_DIR/control-thread.id")
                thread=$(thread_get "$thread_id" 2>/dev/null || echo "")

                if [[ -z "$thread" ]]; then
                    jq -n '{
                        running: false,
                        message: "Control thread not found"
                    }'
                else
                    echo "$thread" | jq '{
                        running: (.status == "running"),
                        control_thread_id: .id,
                        status: .status,
                        created_at: .created_at,
                        updated_at: .updated_at
                    }'
                fi
                ;;

            *)
                echo '{"error": "Invalid action. Use: start, stop, status"}'
                exit 1
                ;;
        esac
        ;;

    orchestrator_agents)
        # GET /api/orchestrator/agents - List active agents
        query_params="$arg1"
        type=""

        if [[ -n "$query_params" ]]; then
            type=$(ct_query_param "$query_params" "type")
        fi

        # Get all threads that are agents (shepherd, conflict-resolver, comment-handler)
        sql="SELECT * FROM threads WHERE (
            name LIKE 'pr-shepherd-%' OR
            name LIKE 'conflict-resolver-%' OR
            name LIKE 'comment-handler-%' OR
            name = 'orchestrator-control'
        )"

        if [[ -n "$type" ]]; then
            case "$type" in
                shepherd)
                    sql="SELECT * FROM threads WHERE name LIKE 'pr-shepherd-%'"
                    ;;
                conflict)
                    sql="SELECT * FROM threads WHERE name LIKE 'conflict-resolver-%'"
                    ;;
                comment)
                    sql="SELECT * FROM threads WHERE name LIKE 'comment-handler-%'"
                    ;;
                control)
                    sql="SELECT * FROM threads WHERE name = 'orchestrator-control'"
                    ;;
            esac
        fi

        sql+=" ORDER BY created_at DESC"

        agents=$(db_query "$sql")

        # Enrich with additional info
        echo "$agents" | jq '[.[] | {
            id: .id,
            name: .name,
            type: (
                if .name | startswith("pr-shepherd-") then "shepherd"
                elif .name | startswith("conflict-resolver-") then "conflict-resolver"
                elif .name | startswith("comment-handler-") then "comment-handler"
                elif .name == "orchestrator-control" then "control"
                else "unknown"
                end
            ),
            status: .status,
            created_at: .created_at,
            updated_at: .updated_at
        }]'
        ;;

    orchestrator_health)
        # GET /api/orchestrator/health - Get orchestrator health status
        orchestrator_running="false"
        orchestrator_pid=""

        if [[ -f "$DATA_DIR/orchestrator.pid" ]]; then
            orchestrator_pid=$(cat "$DATA_DIR/orchestrator.pid")
            if kill -0 "$orchestrator_pid" 2>/dev/null; then
                orchestrator_running="true"
            fi
        fi

        poller_running="false"
        poller_pid=""

        if [[ -f "$DATA_DIR/git-poller.pid" ]]; then
            poller_pid=$(cat "$DATA_DIR/git-poller.pid")
            if kill -0 "$poller_pid" 2>/dev/null; then
                poller_running="true"
            fi
        fi

        control_thread_running="false"
        control_thread_id=""

        if [[ -f "$DATA_DIR/control-thread.id" ]]; then
            control_thread_id=$(cat "$DATA_DIR/control-thread.id")
            thread=$(thread_get "$control_thread_id" 2>/dev/null || echo "")
            if [[ -n "$thread" ]]; then
                status=$(echo "$thread" | jq -r '.status')
                if [[ "$status" == "running" ]]; then
                    control_thread_running="true"
                fi
            fi
        fi

        # Count active agents
        shepherd_count=$(db_scalar "SELECT COUNT(*) FROM threads WHERE name LIKE 'pr-shepherd-%' AND status IN ('running', 'ready')")
        conflict_count=$(db_scalar "SELECT COUNT(*) FROM threads WHERE name LIKE 'conflict-resolver-%' AND status IN ('running', 'ready')")
        comment_count=$(db_scalar "SELECT COUNT(*) FROM threads WHERE name LIKE 'comment-handler-%' AND status IN ('running', 'ready')")

        # Count watched PRs
        watched_prs=$(db_scalar "SELECT COUNT(*) FROM pr_watches WHERE state NOT IN ('completed', 'merged')")

        jq -n \
            --arg orch_running "$orchestrator_running" \
            --arg orch_pid "$orchestrator_pid" \
            --arg poller_running "$poller_running" \
            --arg poller_pid "$poller_pid" \
            --arg control_running "$control_thread_running" \
            --arg control_id "$control_thread_id" \
            --arg shepherds "$shepherd_count" \
            --arg conflicts "$conflict_count" \
            --arg comments "$comment_count" \
            --arg prs "$watched_prs" \
            '{
                orchestrator: {
                    running: ($orch_running == "true"),
                    pid: (if $orch_pid != "" then ($orch_pid | tonumber) else null end)
                },
                git_poller: {
                    running: ($poller_running == "true"),
                    pid: (if $poller_pid != "" then ($poller_pid | tonumber) else null end)
                },
                control_thread: {
                    running: ($control_running == "true"),
                    id: (if $control_id != "" then $control_id else null end)
                },
                agents: {
                    shepherds: ($shepherds | tonumber),
                    conflict_resolvers: ($conflicts | tonumber),
                    comment_handlers: ($comments | tonumber)
                },
                watched_prs: ($prs | tonumber)
            }'
        ;;

    *)
        echo '{"error": "Unknown handler"}'
        exit 1
        ;;
esac
