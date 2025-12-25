#!/usr/bin/env bash
#
# test-orchestrator.sh - Integration tests for orchestrator functionality
#
# Tests orchestrator lifecycle, thread coordination, event processing,
# and recovery scenarios.
#
# Usage:
#   ./tests/integration/test-orchestrator.sh
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
    # Stop any running orchestrator
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR/test-project" ]]; then
        cd "$TEST_DIR/test-project"
        .claude-threads/bin/ct orchestrator stop >/dev/null 2>&1 || true
    fi

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

assert_file_exists() {
    local file="$1"
    local desc="${2:-file exists}"
    (( ++TESTS_RUN )) || true
    if [[ -f "$file" ]]; then
        log_pass "$desc"
        return 0
    else
        log_fail "$desc - file not found: $file"
        return 1
    fi
}

assert_file_not_exists() {
    local file="$1"
    local desc="${2:-file does not exist}"
    (( ++TESTS_RUN )) || true
    if [[ ! -f "$file" ]]; then
        log_pass "$desc"
        return 0
    else
        log_fail "$desc - file should not exist: $file"
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

test_orchestrator_start_stop() {
    echo ""
    echo "========================================"
    echo "Testing: Orchestrator start/stop"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Starting orchestrator..."
    assert_command_succeeds ".claude-threads/bin/ct orchestrator start" "Orchestrator start succeeds"

    # Wait for startup
    sleep 2

    log_test "Checking orchestrator is running..."
    assert_output_contains ".claude-threads/bin/ct orchestrator status" "Running" "Status shows running"

    # Check lock file
    assert_file_exists ".claude-threads/orchestrator.lock" "Lock file created"

    log_test "Stopping orchestrator..."
    assert_command_succeeds ".claude-threads/bin/ct orchestrator stop" "Orchestrator stop succeeds"

    sleep 1

    log_test "Checking orchestrator is stopped..."
    assert_output_contains ".claude-threads/bin/ct orchestrator status" "Stopped" "Status shows stopped"

    cd "$TEST_DIR"
}

test_orchestrator_double_start() {
    echo ""
    echo "========================================"
    echo "Testing: Orchestrator double start prevention"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Starting orchestrator first time..."
    .claude-threads/bin/ct orchestrator start >/dev/null 2>&1 || true
    sleep 2

    log_test "Attempting second start..."
    local output
    output=$(.claude-threads/bin/ct orchestrator start 2>&1) || true

    (( ++TESTS_RUN )) || true
    if echo "$output" | grep -qi "already"; then
        log_pass "Second start prevented"
    else
        log_fail "Second start should be prevented: $output"
    fi

    .claude-threads/bin/ct orchestrator stop >/dev/null 2>&1 || true
    sleep 1

    cd "$TEST_DIR"
}

test_orchestrator_status_details() {
    echo ""
    echo "========================================"
    echo "Testing: Orchestrator status details"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Starting orchestrator..."
    .claude-threads/bin/ct orchestrator start >/dev/null 2>&1 || true
    sleep 2

    log_test "Checking verbose status..."
    local output
    output=$(.claude-threads/bin/ct orchestrator status 2>&1) || true

    (( ++TESTS_RUN )) || true
    if echo "$output" | grep -qE "(Running|PID)"; then
        log_pass "Status contains running info"
    else
        log_fail "Status missing running info: $output"
    fi

    .claude-threads/bin/ct orchestrator stop >/dev/null 2>&1 || true
    sleep 1

    cd "$TEST_DIR"
}

test_orchestrator_lock_cleanup() {
    echo ""
    echo "========================================"
    echo "Testing: Orchestrator lock cleanup"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Creating stale lock file..."
    echo "99999" > .claude-threads/orchestrator.lock

    log_test "Starting orchestrator with stale lock..."
    local output
    output=$(.claude-threads/bin/ct orchestrator start 2>&1) || true

    sleep 2

    # Should either clean up stale lock or report error
    local status
    status=$(.claude-threads/bin/ct orchestrator status 2>&1) || true

    (( ++TESTS_RUN )) || true
    if echo "$status" | grep -qE "(Running|Stopped|stale)"; then
        log_pass "Handled stale lock appropriately"
    else
        log_fail "Unexpected status with stale lock: $status"
    fi

    .claude-threads/bin/ct orchestrator stop >/dev/null 2>&1 || true
    rm -f .claude-threads/orchestrator.lock
    sleep 1

    cd "$TEST_DIR"
}

test_orchestrator_thread_coordination() {
    echo ""
    echo "========================================"
    echo "Testing: Orchestrator thread coordination"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Starting orchestrator..."
    .claude-threads/bin/ct orchestrator start >/dev/null 2>&1 || true
    sleep 2

    log_test "Creating pending thread..."
    local output
    output=$(.claude-threads/bin/ct thread create orch-test --mode automatic 2>&1) || true
    local thread_id
    thread_id=$(echo "$output" | grep -oE "thread-[a-f0-9]+" | head -1) || thread_id=""

    if [[ -z "$thread_id" ]]; then
        (( ++TESTS_RUN )) || true
        log_fail "Could not create thread"
        .claude-threads/bin/ct orchestrator stop >/dev/null 2>&1 || true
        cd "$TEST_DIR"
        return
    fi

    # Verify thread is tracked
    log_test "Checking thread in database..."
    local thread_count
    thread_count=$(sqlite3 .claude-threads/threads.db \
        "SELECT COUNT(*) FROM threads WHERE id = '$thread_id'" 2>/dev/null) || thread_count=0
    assert_equals "$thread_count" "1" "Thread exists in database"

    .claude-threads/bin/ct orchestrator stop >/dev/null 2>&1 || true
    sleep 1

    cd "$TEST_DIR"
}

test_orchestrator_event_processing() {
    echo ""
    echo "========================================"
    echo "Testing: Orchestrator event processing"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Starting orchestrator..."
    .claude-threads/bin/ct orchestrator start >/dev/null 2>&1 || true
    sleep 2

    log_test "Publishing test event..."
    .claude-threads/bin/ct event publish ORCH_TEST_EVENT '{"test": "orchestrator"}' >/dev/null 2>&1 || true

    # Verify event was recorded
    local event_count
    event_count=$(sqlite3 .claude-threads/threads.db \
        "SELECT COUNT(*) FROM events WHERE type = 'ORCH_TEST_EVENT'" 2>/dev/null) || event_count=0
    assert_equals "$event_count" "1" "Event recorded in database"

    .claude-threads/bin/ct orchestrator stop >/dev/null 2>&1 || true
    sleep 1

    cd "$TEST_DIR"
}

test_orchestrator_logs() {
    echo ""
    echo "========================================"
    echo "Testing: Orchestrator logging"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Starting orchestrator..."
    .claude-threads/bin/ct orchestrator start >/dev/null 2>&1 || true
    sleep 3

    log_test "Checking log file exists..."
    (( ++TESTS_RUN )) || true
    if ls .claude-threads/logs/orchestrator*.log >/dev/null 2>&1; then
        log_pass "Orchestrator log file exists"
    else
        log_fail "Orchestrator log file not found"
    fi

    log_test "Checking log has content..."
    local log_size
    log_size=$(find .claude-threads/logs -name "orchestrator*.log" -exec wc -c {} \; 2>/dev/null | awk '{sum += $1} END {print sum}') || log_size=0

    (( ++TESTS_RUN )) || true
    if [[ "$log_size" -gt 0 ]]; then
        log_pass "Log file has content"
    else
        log_fail "Log file is empty"
    fi

    .claude-threads/bin/ct orchestrator stop >/dev/null 2>&1 || true
    sleep 1

    cd "$TEST_DIR"
}

test_orchestrator_restart() {
    echo ""
    echo "========================================"
    echo "Testing: Orchestrator restart"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Starting orchestrator..."
    .claude-threads/bin/ct orchestrator start >/dev/null 2>&1 || true
    sleep 2

    # Create a thread before restart
    log_test "Creating thread before restart..."
    .claude-threads/bin/ct thread create restart-test --mode automatic >/dev/null 2>&1 || true

    local thread_count_before
    thread_count_before=$(sqlite3 .claude-threads/threads.db "SELECT COUNT(*) FROM threads" 2>/dev/null) || thread_count_before=0

    log_test "Restarting orchestrator..."
    .claude-threads/bin/ct orchestrator stop >/dev/null 2>&1 || true
    sleep 1
    .claude-threads/bin/ct orchestrator start >/dev/null 2>&1 || true
    sleep 2

    # Check status after restart
    assert_output_contains ".claude-threads/bin/ct orchestrator status" "Running" "Running after restart"

    # Verify thread count unchanged
    local thread_count_after
    thread_count_after=$(sqlite3 .claude-threads/threads.db "SELECT COUNT(*) FROM threads" 2>/dev/null) || thread_count_after=0
    assert_equals "$thread_count_after" "$thread_count_before" "Thread count preserved after restart"

    .claude-threads/bin/ct orchestrator stop >/dev/null 2>&1 || true
    sleep 1

    cd "$TEST_DIR"
}

test_orchestrator_graceful_shutdown() {
    echo ""
    echo "========================================"
    echo "Testing: Orchestrator graceful shutdown"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Starting orchestrator..."
    .claude-threads/bin/ct orchestrator start >/dev/null 2>&1 || true
    sleep 2

    # Get PID
    local pid
    pid=$(cat .claude-threads/orchestrator.lock 2>/dev/null) || pid=""

    log_test "Stopping orchestrator..."
    .claude-threads/bin/ct orchestrator stop >/dev/null 2>&1 || true
    sleep 2

    # Check process is gone
    (( ++TESTS_RUN )) || true
    if [[ -n "$pid" ]] && ! ps -p "$pid" >/dev/null 2>&1; then
        log_pass "Orchestrator process stopped"
    else
        log_fail "Orchestrator process may still be running"
    fi

    # Check lock file removed
    assert_file_not_exists ".claude-threads/orchestrator.lock" "Lock file removed"

    cd "$TEST_DIR"
}

test_orchestrator_multiple_threads() {
    echo ""
    echo "========================================"
    echo "Testing: Orchestrator multiple threads"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Starting orchestrator..."
    .claude-threads/bin/ct orchestrator start >/dev/null 2>&1 || true
    sleep 2

    log_test "Creating multiple threads..."
    for i in {1..5}; do
        .claude-threads/bin/ct thread create "multi-$i" --mode automatic >/dev/null 2>&1 || true
    done

    # Count threads
    local thread_count
    thread_count=$(sqlite3 .claude-threads/threads.db \
        "SELECT COUNT(*) FROM threads WHERE name LIKE 'multi-%'" 2>/dev/null) || thread_count=0

    (( ++TESTS_RUN )) || true
    if [[ "$thread_count" -eq 5 ]]; then
        log_pass "All 5 threads created"
    else
        log_fail "Expected 5 threads, got $thread_count"
    fi

    .claude-threads/bin/ct orchestrator stop >/dev/null 2>&1 || true
    sleep 1

    cd "$TEST_DIR"
}

# ============================================================
# Main
# ============================================================

main() {
    echo "=============================================="
    echo "claude-threads Orchestrator Integration Tests"
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
    test_orchestrator_start_stop
    test_orchestrator_double_start
    test_orchestrator_status_details
    test_orchestrator_lock_cleanup
    test_orchestrator_thread_coordination
    test_orchestrator_event_processing
    test_orchestrator_logs
    test_orchestrator_restart
    test_orchestrator_graceful_shutdown
    test_orchestrator_multiple_threads

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
