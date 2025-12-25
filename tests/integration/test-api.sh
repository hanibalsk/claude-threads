#!/usr/bin/env bash
#
# test-api.sh - Integration tests for REST API endpoints
#
# Tests the API server, health checks, authentication, and all
# endpoint functionality.
#
# Usage:
#   ./tests/integration/test-api.sh
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

# API config
API_PORT=31338  # Use different port to avoid conflicts
API_URL="http://localhost:$API_PORT"
API_TOKEN=""

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Create temporary test directory
TEST_DIR=""
API_PID=""

cleanup() {
    # Stop API server if running
    if [[ -n "$API_PID" ]]; then
        kill "$API_PID" 2>/dev/null || true
        wait "$API_PID" 2>/dev/null || true
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

assert_contains() {
    local text="$1"
    local pattern="$2"
    local desc="${3:-text contains pattern}"
    (( ++TESTS_RUN )) || true
    if echo "$text" | grep -q "$pattern"; then
        log_pass "$desc"
        return 0
    else
        log_fail "$desc - expected '$pattern' in '$text'"
        return 1
    fi
}

assert_http_code() {
    local actual="$1"
    local expected="$2"
    local desc="${3:-HTTP status code}"
    (( ++TESTS_RUN )) || true
    if [[ "$actual" == "$expected" ]]; then
        log_pass "$desc"
        return 0
    else
        log_fail "$desc - expected HTTP $expected, got HTTP $actual"
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

    # Generate API token
    API_TOKEN=$(openssl rand -hex 16)
    export CT_API_TOKEN="$API_TOKEN"

    # Update config with API settings
    cat >> .claude-threads/config.yaml << EOF

api:
  enabled: true
  port: $API_PORT
  token: $API_TOKEN
EOF

    echo "$test_project"
}

start_api_server() {
    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    # Start API server in background
    CT_API_PORT=$API_PORT CT_API_TOKEN=$API_TOKEN \
        .claude-threads/scripts/api-server.sh &
    API_PID=$!

    # Wait for server to start
    local retries=10
    while [[ $retries -gt 0 ]]; do
        if curl -s "$API_URL/api/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
        (( --retries )) || true
    done

    return 1
}

# ============================================================
# Test Suites
# ============================================================

test_api_health() {
    echo ""
    echo "========================================"
    echo "Testing: API health endpoint"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Checking health endpoint..."
    local response
    local http_code

    response=$(curl -s -w "\n%{http_code}" "$API_URL/api/health" 2>&1) || true
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | head -n -1)

    assert_http_code "$http_code" "200" "Health endpoint returns 200"
    assert_contains "$body" "ok" "Health response contains 'ok'"

    cd "$TEST_DIR"
}

test_api_status() {
    echo ""
    echo "========================================"
    echo "Testing: API status endpoint"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Checking status endpoint with auth..."
    local response
    local http_code

    response=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $API_TOKEN" \
        "$API_URL/api/status" 2>&1) || true
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | head -n -1)

    assert_http_code "$http_code" "200" "Status endpoint returns 200"

    cd "$TEST_DIR"
}

test_api_auth_required() {
    echo ""
    echo "========================================"
    echo "Testing: API authentication required"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Checking protected endpoint without auth..."
    local http_code

    http_code=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL/api/status" 2>&1) || true
    assert_http_code "$http_code" "401" "Unauthenticated request returns 401"

    log_test "Checking protected endpoint with wrong token..."
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer wrong-token" "$API_URL/api/status" 2>&1) || true
    assert_http_code "$http_code" "401" "Wrong token returns 401"

    log_test "Checking protected endpoint with correct token..."
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $API_TOKEN" "$API_URL/api/status" 2>&1) || true
    assert_http_code "$http_code" "200" "Correct token returns 200"

    cd "$TEST_DIR"
}

test_api_threads_list() {
    echo ""
    echo "========================================"
    echo "Testing: API threads list endpoint"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    # Create some threads
    log_test "Creating test threads..."
    .claude-threads/bin/ct thread create api-test-1 --mode automatic >/dev/null 2>&1 || true
    .claude-threads/bin/ct thread create api-test-2 --mode automatic >/dev/null 2>&1 || true

    log_test "Listing threads via API..."
    local response
    local http_code

    response=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $API_TOKEN" \
        "$API_URL/api/threads" 2>&1) || true
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | head -n -1)

    assert_http_code "$http_code" "200" "Threads list returns 200"
    assert_contains "$body" "api-test-1" "Response contains first thread"
    assert_contains "$body" "api-test-2" "Response contains second thread"

    cd "$TEST_DIR"
}

test_api_thread_create() {
    echo ""
    echo "========================================"
    echo "Testing: API thread create endpoint"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Creating thread via API..."
    local response
    local http_code

    response=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"name": "api-created-thread", "mode": "automatic"}' \
        "$API_URL/api/threads" 2>&1) || true
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | head -n -1)

    assert_http_code "$http_code" "201" "Thread create returns 201"
    assert_contains "$body" "thread-" "Response contains thread ID"

    # Verify in database
    local thread_exists
    thread_exists=$(sqlite3 .claude-threads/threads.db \
        "SELECT COUNT(*) FROM threads WHERE name = 'api-created-thread'" 2>/dev/null) || thread_exists=0
    assert_equals "$thread_exists" "1" "Thread exists in database"

    cd "$TEST_DIR"
}

test_api_events_list() {
    echo ""
    echo "========================================"
    echo "Testing: API events list endpoint"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    # Create some events
    log_test "Creating test events..."
    .claude-threads/bin/ct event publish TEST_API_EVENT '{"test": true}' >/dev/null 2>&1 || true

    log_test "Listing events via API..."
    local response
    local http_code

    response=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $API_TOKEN" \
        "$API_URL/api/events" 2>&1) || true
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | head -n -1)

    assert_http_code "$http_code" "200" "Events list returns 200"
    assert_contains "$body" "TEST_API_EVENT" "Response contains test event"

    cd "$TEST_DIR"
}

test_api_event_publish() {
    echo ""
    echo "========================================"
    echo "Testing: API event publish endpoint"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Publishing event via API..."
    local response
    local http_code

    response=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"type": "API_PUBLISHED_EVENT", "data": {"source": "api-test"}}' \
        "$API_URL/api/events" 2>&1) || true
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | head -n -1)

    assert_http_code "$http_code" "201" "Event publish returns 201"
    assert_contains "$body" "evt-" "Response contains event ID"

    # Verify in database
    local event_exists
    event_exists=$(sqlite3 .claude-threads/threads.db \
        "SELECT COUNT(*) FROM events WHERE type = 'API_PUBLISHED_EVENT'" 2>/dev/null) || event_exists=0
    assert_equals "$event_exists" "1" "Event exists in database"

    cd "$TEST_DIR"
}

test_api_worktrees_list() {
    echo ""
    echo "========================================"
    echo "Testing: API worktrees list endpoint"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Listing worktrees via API..."
    local response
    local http_code

    response=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $API_TOKEN" \
        "$API_URL/api/worktrees" 2>&1) || true
    http_code=$(echo "$response" | tail -1)

    assert_http_code "$http_code" "200" "Worktrees list returns 200"

    cd "$TEST_DIR"
}

test_api_not_found() {
    echo ""
    echo "========================================"
    echo "Testing: API 404 handling"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Requesting non-existent endpoint..."
    local http_code

    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $API_TOKEN" \
        "$API_URL/api/nonexistent" 2>&1) || true
    assert_http_code "$http_code" "404" "Non-existent endpoint returns 404"

    cd "$TEST_DIR"
}

test_api_method_not_allowed() {
    echo ""
    echo "========================================"
    echo "Testing: API method not allowed"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Using wrong HTTP method..."
    local http_code

    # DELETE on health endpoint should be 405
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
        "$API_URL/api/health" 2>&1) || true

    (( ++TESTS_RUN )) || true
    if [[ "$http_code" == "405" || "$http_code" == "404" ]]; then
        log_pass "Wrong method returns 405 or 404"
    else
        log_fail "Expected 405 or 404, got $http_code"
    fi

    cd "$TEST_DIR"
}

test_api_json_validation() {
    echo ""
    echo "========================================"
    echo "Testing: API JSON validation"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Sending invalid JSON..."
    local http_code

    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        -d 'not valid json' \
        "$API_URL/api/threads" 2>&1) || true

    (( ++TESTS_RUN )) || true
    if [[ "$http_code" == "400" ]]; then
        log_pass "Invalid JSON returns 400"
    else
        log_fail "Expected 400 for invalid JSON, got $http_code"
    fi

    cd "$TEST_DIR"
}

# ============================================================
# Main
# ============================================================

main() {
    echo "=============================================="
    echo "claude-threads API Integration Tests"
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

    # Start API server
    echo "Starting API server on port $API_PORT..."
    if ! start_api_server; then
        echo -e "${RED}Failed to start API server${NC}"
        exit 1
    fi
    echo "API server started (PID: $API_PID)"
    echo ""

    # Run test suites
    test_api_health
    test_api_status
    test_api_auth_required
    test_api_threads_list
    test_api_thread_create
    test_api_events_list
    test_api_event_publish
    test_api_worktrees_list
    test_api_not_found
    test_api_method_not_allowed
    test_api_json_validation

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
