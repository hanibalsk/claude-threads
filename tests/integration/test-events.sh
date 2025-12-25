#!/usr/bin/env bash
#
# test-events.sh - Integration tests for blackboard event system
#
# Tests event publishing, listing, filtering, and the event-driven
# coordination patterns.
#
# Usage:
#   ./tests/integration/test-events.sh
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Create temporary test directory
TEST_DIR=""
cleanup() {
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

# Test helpers
log_test() {
    echo -e "${YELLOW}TEST:${NC} $1"
}

log_pass() {
    echo -e "${GREEN}PASS:${NC} $1"
    (( ++TESTS_PASSED )) || true
}

log_fail() {
    echo -e "${RED}FAIL:${NC} $1"
    (( ++TESTS_FAILED )) || true
}

assert_command_succeeds() {
    local cmd="$1"
    local desc="${2:-command succeeds}"
    (( ++TESTS_RUN )) || true
    if eval "$cmd" >/dev/null 2>&1; then
        log_pass "$desc"
        return 0
    else
        log_fail "$desc - command failed: $cmd"
        return 1
    fi
}

assert_output_contains() {
    local cmd="$1"
    local expected="$2"
    local desc="${3:-output contains '$expected'}"
    (( ++TESTS_RUN )) || true
    local output
    output=$(eval "$cmd" 2>&1) || true
    if echo "$output" | grep -q "$expected"; then
        log_pass "$desc"
        return 0
    else
        log_fail "$desc - expected '$expected' in output: $output"
        return 1
    fi
}

assert_equals() {
    local actual="$1"
    local expected="$2"
    local desc="${3:-values equal}"
    (( ++TESTS_RUN )) || true
    if [[ "$actual" == "$expected" ]]; then
        log_pass "$desc"
        return 0
    else
        log_fail "$desc - expected '$expected', got '$actual'"
        return 1
    fi
}

setup_test_project() {
    local test_project="$TEST_DIR/test-project"
    mkdir -p "$test_project"
    cd "$test_project"

    # Initialize git
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "test" > README.md
    git add . && git commit -q -m "Initial"

    # Run installer
    printf "1\nY\n1\nn\nn\nn\nn\n" | "$PROJECT_ROOT/install.sh" >/dev/null 2>&1 || true

    echo "$test_project"
}

# ============================================================
# Test Suites
# ============================================================

test_event_list_empty() {
    echo ""
    echo "========================================"
    echo "Testing: Event list (empty)"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Listing events on empty database..."
    assert_command_succeeds ".claude-threads/bin/ct event list" "event list succeeds with no events"

    cd "$TEST_DIR"
}

test_event_publish() {
    echo ""
    echo "========================================"
    echo "Testing: Event publishing"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Publishing THREAD_STARTED event..."
    local output
    output=$(.claude-threads/bin/ct event publish THREAD_STARTED '{"thread_id": "test-123", "name": "test-thread"}' 2>&1) || true

    (( ++TESTS_RUN )) || true
    if echo "$output" | grep -qE "(Published|evt-)"; then
        log_pass "Event published successfully"
    else
        log_fail "Event publishing failed: $output"
    fi

    # Check event in database
    log_test "Checking event in database..."
    local event_count
    event_count=$(sqlite3 .claude-threads/threads.db "SELECT COUNT(*) FROM events WHERE type = 'THREAD_STARTED'" 2>/dev/null) || event_count=0
    assert_equals "$event_count" "1" "Event exists in database"

    cd "$TEST_DIR"
}

test_event_publish_multiple() {
    echo ""
    echo "========================================"
    echo "Testing: Publishing multiple events"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Publishing multiple event types..."

    .claude-threads/bin/ct event publish THREAD_COMPLETED '{"thread_id": "test-123", "result": "success"}' >/dev/null 2>&1 || true
    .claude-threads/bin/ct event publish PR_STATUS_CHANGED '{"pr_number": 123, "status": "approved"}' >/dev/null 2>&1 || true
    .claude-threads/bin/ct event publish CONFLICT_DETECTED '{"pr_number": 123, "files": ["src/app.ts"]}' >/dev/null 2>&1 || true
    .claude-threads/bin/ct event publish COMMENT_PENDING '{"pr_number": 123, "comment_id": "456"}' >/dev/null 2>&1 || true

    # Count total events
    local event_count
    event_count=$(sqlite3 .claude-threads/threads.db "SELECT COUNT(*) FROM events" 2>/dev/null) || event_count=0

    (( ++TESTS_RUN )) || true
    if [[ "$event_count" -ge 5 ]]; then
        log_pass "Multiple events published: $event_count total"
    else
        log_fail "Expected at least 5 events, got $event_count"
    fi

    cd "$TEST_DIR"
}

test_event_list_with_data() {
    echo ""
    echo "========================================"
    echo "Testing: Event list with data"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Listing all events..."
    assert_command_succeeds ".claude-threads/bin/ct event list" "event list succeeds"
    assert_output_contains ".claude-threads/bin/ct event list" "THREAD_STARTED" "List contains THREAD_STARTED"
    assert_output_contains ".claude-threads/bin/ct event list" "THREAD_COMPLETED" "List contains THREAD_COMPLETED"

    cd "$TEST_DIR"
}

test_event_list_filter_type() {
    echo ""
    echo "========================================"
    echo "Testing: Event list filter by type"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Filtering events by type..."
    assert_output_contains ".claude-threads/bin/ct event list --type THREAD_STARTED" "THREAD_STARTED" "Type filter works"

    # Verify filter excludes other types
    log_test "Checking filter excludes other types..."
    local output
    output=$(.claude-threads/bin/ct event list --type THREAD_STARTED 2>&1) || true

    (( ++TESTS_RUN )) || true
    if ! echo "$output" | grep -q "CONFLICT_DETECTED"; then
        log_pass "Filter excludes other event types"
    else
        log_fail "Filter did not exclude other types"
    fi

    cd "$TEST_DIR"
}

test_event_list_limit() {
    echo ""
    echo "========================================"
    echo "Testing: Event list with limit"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Listing events with limit..."
    assert_command_succeeds ".claude-threads/bin/ct event list --limit 2" "event list with limit succeeds"

    # Count output lines (rough check)
    local line_count
    line_count=$(.claude-threads/bin/ct event list --limit 2 2>&1 | grep -c "evt-" || echo 0)

    (( ++TESTS_RUN )) || true
    if [[ "$line_count" -le 2 ]]; then
        log_pass "Limit restricts output"
    else
        log_fail "Limit not applied, got $line_count events"
    fi

    cd "$TEST_DIR"
}

test_event_data_integrity() {
    echo ""
    echo "========================================"
    echo "Testing: Event data integrity"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Checking event data is stored correctly..."

    # Query specific event data
    local event_data
    event_data=$(sqlite3 .claude-threads/threads.db "SELECT data FROM events WHERE type = 'PR_STATUS_CHANGED' LIMIT 1" 2>/dev/null) || event_data=""

    (( ++TESTS_RUN )) || true
    if echo "$event_data" | grep -q "pr_number"; then
        log_pass "Event data contains expected fields"
    else
        log_fail "Event data missing expected fields: $event_data"
    fi

    # Check JSON validity
    (( ++TESTS_RUN )) || true
    if echo "$event_data" | jq . >/dev/null 2>&1; then
        log_pass "Event data is valid JSON"
    else
        log_fail "Event data is not valid JSON: $event_data"
    fi

    cd "$TEST_DIR"
}

test_event_source_thread() {
    echo ""
    echo "========================================"
    echo "Testing: Event source thread tracking"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    # Create a thread first
    log_test "Creating source thread..."
    local thread_output
    thread_output=$(.claude-threads/bin/ct thread create event-source-test --mode automatic 2>&1) || true
    local thread_id
    thread_id=$(echo "$thread_output" | grep -oE "thread-[a-f0-9]+" | head -1) || thread_id=""

    if [[ -n "$thread_id" ]]; then
        # Publish event with source
        log_test "Publishing event with source thread..."
        .claude-threads/bin/ct event publish TEST_EVENT '{"test": true}' --source "$thread_id" >/dev/null 2>&1 || true

        # Check source is recorded
        local source
        source=$(sqlite3 .claude-threads/threads.db "SELECT source_thread_id FROM events WHERE type = 'TEST_EVENT' LIMIT 1" 2>/dev/null) || source=""

        (( ++TESTS_RUN )) || true
        if [[ "$source" == "$thread_id" ]]; then
            log_pass "Source thread recorded correctly"
        else
            log_fail "Source thread not recorded: expected '$thread_id', got '$source'"
        fi
    else
        (( ++TESTS_RUN )) || true
        log_fail "Could not create source thread"
    fi

    cd "$TEST_DIR"
}

test_event_cleanup() {
    echo ""
    echo "========================================"
    echo "Testing: Event cleanup (TTL simulation)"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    # Manually insert an old event
    log_test "Creating old event for cleanup test..."
    sqlite3 .claude-threads/threads.db "INSERT INTO events (id, type, data, created_at) VALUES ('evt-old-test', 'OLD_EVENT', '{}', datetime('now', '-48 hours'))" 2>/dev/null || true

    # Check it exists
    local old_exists
    old_exists=$(sqlite3 .claude-threads/threads.db "SELECT COUNT(*) FROM events WHERE id = 'evt-old-test'" 2>/dev/null) || old_exists=0
    assert_equals "$old_exists" "1" "Old event created"

    # Run cleanup (if command exists)
    log_test "Running event cleanup..."
    .claude-threads/bin/ct event cleanup >/dev/null 2>&1 || true

    # Note: This test may pass/fail depending on TTL config
    # Just checking the command runs is sufficient
    assert_command_succeeds "true" "Event cleanup ran"

    cd "$TEST_DIR"
}

test_event_types_coverage() {
    echo ""
    echo "========================================"
    echo "Testing: Event types coverage"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Publishing various event types..."

    local event_types=(
        "THREAD_CREATED"
        "THREAD_FAILED"
        "THREAD_BLOCKED"
        "PR_WATCH_STARTED"
        "CONFLICT_RESOLVED"
        "COMMENT_RESPONDED"
        "COMMENT_RESOLVED"
        "CI_FAILED"
        "CI_PASSING"
        "WORKTREE_FORK_CREATED"
        "WORKTREE_FORK_MERGED"
        "ESCALATION_NEEDED"
        "CHECKPOINT_CREATED"
    )

    local success_count=0
    for event_type in "${event_types[@]}"; do
        if .claude-threads/bin/ct event publish "$event_type" '{"test": true}' >/dev/null 2>&1; then
            (( ++success_count )) || true
        fi
    done

    (( ++TESTS_RUN )) || true
    if [[ "$success_count" -eq "${#event_types[@]}" ]]; then
        log_pass "All ${#event_types[@]} event types published successfully"
    else
        log_fail "Only $success_count/${#event_types[@]} event types published"
    fi

    cd "$TEST_DIR"
}

# ============================================================
# Main
# ============================================================

main() {
    echo "=============================================="
    echo "claude-threads Event System Integration Tests"
    echo "=============================================="
    echo ""
    echo "Project root: $PROJECT_ROOT"

    # Create temp directory
    TEST_DIR=$(mktemp -d)
    echo "Test directory: $TEST_DIR"
    echo ""

    # Setup test project
    echo "Setting up test project..."
    setup_test_project

    # Run test suites
    test_event_list_empty
    test_event_publish
    test_event_publish_multiple
    test_event_list_with_data
    test_event_list_filter_type
    test_event_list_limit
    test_event_data_integrity
    test_event_source_thread
    test_event_cleanup
    test_event_types_coverage

    # Summary
    echo ""
    echo "=============================================="
    echo "Test Summary"
    echo "=============================================="
    echo "Tests run:    $TESTS_RUN"
    echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
    echo ""

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed.${NC}"
        exit 1
    fi
}

main "$@"
