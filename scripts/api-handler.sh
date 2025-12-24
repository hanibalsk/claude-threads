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

        sql="SELECT * FROM threads WHERE 1=1"
        [[ -n "$status" ]] && sql+=" AND status = $(db_quote "$status")"
        [[ -n "$mode" ]] && sql+=" AND mode = $(db_quote "$mode")"
        sql+=" ORDER BY updated_at DESC LIMIT $limit"

        db_query "$sql"
        ;;

    get_thread)
        thread_id="$arg1"
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

        if [[ -z "$name" ]]; then
            echo '{"error": "Name is required"}'
            exit 1
        fi

        thread_id=$(thread_create "$name" "$mode" "$template" "$workflow" "$context")

        jq -n \
            --arg id "$thread_id" \
            --arg name "$name" \
            --arg mode "$mode" \
            '{id: $id, name: $name, mode: $mode, status: "created"}'
        ;;

    start_thread)
        thread_id="$arg1"

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

    *)
        echo '{"error": "Unknown handler"}'
        exit 1
        ;;
esac
