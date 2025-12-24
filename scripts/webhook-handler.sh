#!/usr/bin/env bash
#
# webhook-handler.sh - Webhook event handler for claude-threads
#
# This script is invoked by the Python webhook server (see webhook-server.sh).
# It routes GitHub webhook events and publishes them to the blackboard + stores
# the raw webhook payload.
#
# Environment:
#   CT_DATA_DIR        Data directory (defaults to .claude-threads)
#   WEBHOOK_EVENT      GitHub event type (e.g. pull_request)
#   WEBHOOK_PAYLOAD    JSON payload (string)
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

DATA_DIR="${CT_DATA_DIR:-$(ct_data_dir)}"
EVENT_TYPE="${WEBHOOK_EVENT:-}"
PAYLOAD="${WEBHOOK_PAYLOAD:-}"

init() {
    config_load "$DATA_DIR/config.yaml" 2>/dev/null || true
    log_init "webhook-handler" "$DATA_DIR/logs/webhook-handler.log"
    log_set_level "$(config_get 'orchestrator.log_level' 'info')"
    db_init "$DATA_DIR"
    bb_init "$DATA_DIR"
}

store_webhook() {
    local source="$1"
    local event_type="$2"
    local payload="$3"

    db_exec "INSERT INTO webhooks (source, event_type, payload)
             VALUES ($(db_quote "$source"), $(db_quote "$event_type"), $(db_quote "$payload"))"
}

handle_pull_request() {
    local payload="$1"

    local action pr_number title branch base_branch author
    action=$(echo "$payload" | jq -r '.action')
    pr_number=$(echo "$payload" | jq -r '.pull_request.number')
    title=$(echo "$payload" | jq -r '.pull_request.title')
    branch=$(echo "$payload" | jq -r '.pull_request.head.ref')
    base_branch=$(echo "$payload" | jq -r '.pull_request.base.ref')
    author=$(echo "$payload" | jq -r '.pull_request.user.login')

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

    local pr_number state reviewer
    pr_number=$(echo "$payload" | jq -r '.pull_request.number')
    state=$(echo "$payload" | jq -r '.review.state')
    reviewer=$(echo "$payload" | jq -r '.review.user.login')

    local event_type
    case "$state" in
        approved) event_type="PR_APPROVED" ;;
        changes_requested) event_type="PR_CHANGES_REQUESTED" ;;
        commented) event_type="PR_REVIEW_COMMENT" ;;
        *) event_type="PR_REVIEW_${state^^}" ;;
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

    local name status conclusion pr_numbers
    name=$(echo "$payload" | jq -r '.check_run.name')
    status=$(echo "$payload" | jq -r '.check_run.status')
    conclusion=$(echo "$payload" | jq -r '.check_run.conclusion // "pending"')
    pr_numbers=$(echo "$payload" | jq -r '[.check_run.pull_requests[].number] | join(",")')

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

    local event_data
    event_data=$(jq -n \
        --arg branch "$branch" \
        --arg commits "$commits_count" \
        '{branch: $branch, commits_count: $commits}')

    bb_publish "PUSH" "$event_data" "github"
    store_webhook "github" "push" "$payload"
}

main() {
    init

    if [[ -z "$EVENT_TYPE" ]]; then
        ct_error "WEBHOOK_EVENT not set"
        exit 1
    fi
    if [[ -z "$PAYLOAD" ]]; then
        ct_error "WEBHOOK_PAYLOAD not set"
        exit 1
    fi
    if ! echo "$PAYLOAD" | jq empty >/dev/null 2>&1; then
        ct_error "Invalid JSON in WEBHOOK_PAYLOAD"
        exit 1
    fi

    case "$EVENT_TYPE" in
        pull_request) handle_pull_request "$PAYLOAD" ;;
        pull_request_review) handle_pull_request_review "$PAYLOAD" ;;
        check_run) handle_check_run "$PAYLOAD" ;;
        check_suite) handle_check_suite "$PAYLOAD" ;;
        issue_comment) handle_issue_comment "$PAYLOAD" ;;
        push) handle_push "$PAYLOAD" ;;
        *)
            log_debug "Unhandled event type: $EVENT_TYPE"
            store_webhook "github" "$EVENT_TYPE" "$PAYLOAD"
            ;;
    esac
}

main "$@"
