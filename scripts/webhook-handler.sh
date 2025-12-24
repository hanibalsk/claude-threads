#!/usr/bin/env bash
#
# webhook-handler.sh - Process webhook events from Python HTTP server
#
# Called by webhook-server.sh's Python mode with environment variables:
#   WEBHOOK_EVENT   - GitHub event type (pull_request, push, etc.)
#   WEBHOOK_PAYLOAD - JSON payload
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

# ============================================================
# Initialization
# ============================================================

DATA_DIR="${CT_DATA_DIR:-$(ct_data_dir)}"

init() {
    # Load configuration
    config_load "$DATA_DIR/config.yaml"

    # Initialize logging
    log_init "webhook-handler" "$DATA_DIR/logs/webhook-handler.log"
    log_set_level "$(config_get 'orchestrator.log_level' 'info')"

    # Initialize database
    db_init "$DATA_DIR"
    bb_init "$DATA_DIR"
}

# ============================================================
# Event Handlers (mirrors webhook-server.sh handlers)
# ============================================================

handle_pull_request() {
    local payload="$1"

    local action pr_number title branch base_branch author
    action=$(echo "$payload" | jq -r '.action')
    pr_number=$(echo "$payload" | jq -r '.pull_request.number')
    title=$(echo "$payload" | jq -r '.pull_request.title')
    branch=$(echo "$payload" | jq -r '.pull_request.head.ref')
    base_branch=$(echo "$payload" | jq -r '.pull_request.base.ref')
    author=$(echo "$payload" | jq -r '.pull_request.user.login')

    log_info "Pull request event: #$pr_number $action"

    local event_type="PR_${action^^}"
    local event_data
    event_data=$(jq -n \
        --arg pr "$pr_number" \
        --arg title "$title" \
        --arg branch "$branch" \
        --arg base "$base_branch" \
        --arg author "$author" \
        --arg action "$action" \
        '{pr_number: $pr, title: $title, branch: $branch, base_branch: $base, author: $author, action: $action}')

    bb_publish "$event_type" "$event_data" "github"
    store_webhook "github" "pull_request" "$payload"
}

handle_pull_request_review() {
    local payload="$1"

    local action pr_number state reviewer
    action=$(echo "$payload" | jq -r '.action')
    pr_number=$(echo "$payload" | jq -r '.pull_request.number')
    state=$(echo "$payload" | jq -r '.review.state')
    reviewer=$(echo "$payload" | jq -r '.review.user.login')

    log_info "PR review event: #$pr_number $state by $reviewer"

    local event_type
    case "$state" in
        approved) event_type="PR_APPROVED" ;;
        changes_requested) event_type="PR_CHANGES_REQUESTED" ;;
        commented) event_type="PR_REVIEW_COMMENT" ;;
        *) event_type="PR_REVIEW_$state" ;;
    esac

    local event_data
    event_data=$(jq -n \
        --arg pr "$pr_number" \
        --arg state "$state" \
        --arg reviewer "$reviewer" \
        '{pr_number: $pr, state: $state, reviewer: $reviewer}')

    bb_publish "$event_type" "$event_data" "github"
    store_webhook "github" "pull_request_review" "$payload"
}

handle_check_run() {
    local payload="$1"

    local action name status conclusion pr_numbers
    action=$(echo "$payload" | jq -r '.action')
    name=$(echo "$payload" | jq -r '.check_run.name')
    status=$(echo "$payload" | jq -r '.check_run.status')
    conclusion=$(echo "$payload" | jq -r '.check_run.conclusion // "pending"')
    pr_numbers=$(echo "$payload" | jq -r '[.check_run.pull_requests[].number] | join(",")')

    log_info "Check run event: $name $status ($conclusion)"

    local event_type
    if [[ "$status" == "completed" ]]; then
        case "$conclusion" in
            success) event_type="CI_PASSED" ;;
            failure|cancelled|timed_out) event_type="CI_FAILED" ;;
            *) event_type="CI_COMPLETED" ;;
        esac
    else
        event_type="CI_RUNNING"
    fi

    local event_data
    event_data=$(jq -n \
        --arg name "$name" \
        --arg status "$status" \
        --arg conclusion "$conclusion" \
        --arg prs "$pr_numbers" \
        '{check_name: $name, status: $status, conclusion: $conclusion, pr_numbers: $prs}')

    bb_publish "$event_type" "$event_data" "github"
    store_webhook "github" "check_run" "$payload"
}

handle_check_suite() {
    local payload="$1"

    local action status conclusion pr_numbers
    action=$(echo "$payload" | jq -r '.action')
    status=$(echo "$payload" | jq -r '.check_suite.status')
    conclusion=$(echo "$payload" | jq -r '.check_suite.conclusion // "pending"')
    pr_numbers=$(echo "$payload" | jq -r '[.check_suite.pull_requests[].number] | join(",")')

    log_info "Check suite event: $status ($conclusion)"

    if [[ "$action" == "completed" ]]; then
        local event_type
        case "$conclusion" in
            success) event_type="CI_SUITE_PASSED" ;;
            failure) event_type="CI_SUITE_FAILED" ;;
            *) event_type="CI_SUITE_COMPLETED" ;;
        esac

        local event_data
        event_data=$(jq -n \
            --arg status "$status" \
            --arg conclusion "$conclusion" \
            --arg prs "$pr_numbers" \
            '{status: $status, conclusion: $conclusion, pr_numbers: $prs}')

        bb_publish "$event_type" "$event_data" "github"
    fi

    store_webhook "github" "check_suite" "$payload"
}

handle_issue_comment() {
    local payload="$1"

    local action issue_number body author is_pr
    action=$(echo "$payload" | jq -r '.action')
    issue_number=$(echo "$payload" | jq -r '.issue.number')
    body=$(echo "$payload" | jq -r '.comment.body')
    author=$(echo "$payload" | jq -r '.comment.user.login')
    is_pr=$(echo "$payload" | jq -r 'if .issue.pull_request then "true" else "false" end')

    if [[ "$is_pr" == "true" ]]; then
        log_info "PR comment event: #$issue_number by $author"

        local event_data
        event_data=$(jq -n \
            --arg pr "$issue_number" \
            --arg body "$body" \
            --arg author "$author" \
            --arg action "$action" \
            '{pr_number: $pr, body: $body, author: $author, action: $action}')

        bb_publish "PR_COMMENT" "$event_data" "github"
    fi

    store_webhook "github" "issue_comment" "$payload"
}

handle_push() {
    local payload="$1"

    local ref branch commits_count
    ref=$(echo "$payload" | jq -r '.ref')
    branch="${ref#refs/heads/}"
    commits_count=$(echo "$payload" | jq -r '.commits | length')

    log_info "Push event: $branch ($commits_count commits)"

    local event_data
    event_data=$(jq -n \
        --arg branch "$branch" \
        --arg commits "$commits_count" \
        '{branch: $branch, commits_count: $commits}')

    bb_publish "PUSH" "$event_data" "github"
    store_webhook "github" "push" "$payload"
}

store_webhook() {
    local source="$1"
    local event_type="$2"
    local payload="$3"

    db_exec "INSERT INTO webhooks (source, event_type, payload)
             VALUES ($(db_quote "$source"), $(db_quote "$event_type"), $(db_quote "$payload"))"
}

# ============================================================
# Main
# ============================================================

main() {
    local event_type="${WEBHOOK_EVENT:-}"
    local payload="${WEBHOOK_PAYLOAD:-}"

    if [[ -z "$event_type" || -z "$payload" ]]; then
        echo "Error: WEBHOOK_EVENT and WEBHOOK_PAYLOAD must be set" >&2
        exit 1
    fi

    init

    log_info "Processing webhook event: $event_type"

    # Route to handler
    case "$event_type" in
        pull_request)
            handle_pull_request "$payload"
            ;;
        pull_request_review)
            handle_pull_request_review "$payload"
            ;;
        check_run)
            handle_check_run "$payload"
            ;;
        check_suite)
            handle_check_suite "$payload"
            ;;
        issue_comment)
            handle_issue_comment "$payload"
            ;;
        push)
            handle_push "$payload"
            ;;
        *)
            log_debug "Unhandled event type: $event_type"
            store_webhook "github" "$event_type" "$payload"
            ;;
    esac

    log_debug "Webhook processing complete"
}

main "$@"
