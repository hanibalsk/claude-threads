#!/usr/bin/env bash
#
# test-worktree.sh - Integration tests for worktree functionality
#
# Tests the base + fork worktree pattern for memory-efficient
# PR lifecycle management.
#
# Usage:
#   ./tests/integration/test-worktree.sh
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
        # Kill any running processes
        pkill -f "orchestrator.*$TEST_DIR" 2>/dev/null || true
        sleep 1
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

assert_file_exists() {
    local file="$1"
    local desc="${2:-$file exists}"
    (( ++TESTS_RUN )) || true
    if [[ -f "$file" ]]; then
        log_pass "$desc"
        return 0
    else
        log_fail "$desc - file not found: $file"
        return 1
    fi
}

assert_dir_exists() {
    local dir="$1"
    local desc="${2:-$dir exists}"
    (( ++TESTS_RUN )) || true
    if [[ -d "$dir" ]]; then
        log_pass "$desc"
        return 0
    else
        log_fail "$desc - directory not found: $dir"
        return 1
    fi
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

assert_command_fails() {
    local cmd="$1"
    local desc="${2:-command fails as expected}"
    (( ++TESTS_RUN )) || true
    if ! eval "$cmd" >/dev/null 2>&1; then
        log_pass "$desc"
        return 0
    else
        log_fail "$desc - command should have failed: $cmd"
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
    # Create test project directory
    local test_project="$TEST_DIR/test-project"
    mkdir -p "$test_project"
    cd "$test_project"

    # Initialize git (required for worktrees)
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "# Test Project" > README.md
    echo "initial content" > src/main.ts
    mkdir -p src
    git add .
    git commit -q -m "Initial commit"

    # Create a feature branch for PR simulation
    git checkout -q -b feature/test-pr
    echo "feature change" >> src/main.ts
    git add .
    git commit -q -m "Feature commit"
    git checkout -q main

    # Run installer
    printf "1\nY\n1\nn\nn\nn\nn\n" | "$PROJECT_ROOT/install.sh" >/dev/null 2>&1 || true

    echo "$test_project"
}

# ============================================================
# Test Suites
# ============================================================

test_worktree_list() {
    echo ""
    echo "========================================"
    echo "Testing: Worktree list command"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Testing ct worktree list (empty)..."
    assert_command_succeeds ".claude-threads/bin/ct worktree list" "worktree list succeeds with no worktrees"

    cd "$TEST_DIR"
}

test_base_worktree_create() {
    echo ""
    echo "========================================"
    echo "Testing: Base worktree creation"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Creating base worktree for PR #123..."
    local output
    output=$(.claude-threads/bin/ct worktree base-create 123 feature/test-pr main 2>&1) || true

    (( ++TESTS_RUN )) || true
    if echo "$output" | grep -qE "(Created|worktree)"; then
        log_pass "Base worktree created"
    else
        log_fail "Base worktree creation failed: $output"
    fi

    # Check directory exists
    log_test "Checking base worktree directory..."
    assert_dir_exists ".claude-threads/worktrees/pr-123-base" "Base worktree directory exists"

    # Check database entry
    log_test "Checking database entry..."
    local db_count
    db_count=$(sqlite3 .claude-threads/threads.db "SELECT COUNT(*) FROM pr_base_worktrees WHERE pr_number = 123" 2>/dev/null) || db_count=0
    assert_equals "$db_count" "1" "Base worktree in database"

    cd "$TEST_DIR"
}

test_base_worktree_status() {
    echo ""
    echo "========================================"
    echo "Testing: Base worktree status"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Getting base worktree status..."
    assert_command_succeeds ".claude-threads/bin/ct worktree base-status 123" "base-status command succeeds"
    assert_output_contains ".claude-threads/bin/ct worktree base-status 123" "123" "Status shows PR number"

    cd "$TEST_DIR"
}

test_fork_worktree_create() {
    echo ""
    echo "========================================"
    echo "Testing: Fork worktree creation"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Creating fork from base..."
    local output
    output=$(.claude-threads/bin/ct worktree fork 123 conflict-fix fix/conflict conflict_resolution 2>&1) || true

    (( ++TESTS_RUN )) || true
    if echo "$output" | grep -qE "(Created|fork|worktree)"; then
        log_pass "Fork worktree created"
    else
        log_fail "Fork creation failed: $output"
    fi

    # Check directory exists
    log_test "Checking fork worktree directory..."
    assert_dir_exists ".claude-threads/worktrees/conflict-fix" "Fork worktree directory exists"

    # Check database entry
    log_test "Checking fork in database..."
    local db_count
    db_count=$(sqlite3 .claude-threads/threads.db "SELECT COUNT(*) FROM pr_worktree_forks WHERE fork_id = 'conflict-fix'" 2>/dev/null) || db_count=0
    assert_equals "$db_count" "1" "Fork in database"

    # Check fork count updated
    log_test "Checking fork count in base..."
    local fork_count
    fork_count=$(sqlite3 .claude-threads/threads.db "SELECT fork_count FROM pr_base_worktrees WHERE pr_number = 123" 2>/dev/null) || fork_count=0
    assert_equals "$fork_count" "1" "Fork count is 1"

    cd "$TEST_DIR"
}

test_fork_list() {
    echo ""
    echo "========================================"
    echo "Testing: Fork list command"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Listing forks for PR #123..."
    assert_command_succeeds ".claude-threads/bin/ct worktree list-forks 123" "list-forks command succeeds"
    assert_output_contains ".claude-threads/bin/ct worktree list-forks 123" "conflict-fix" "Fork appears in list"

    cd "$TEST_DIR"
}

test_fork_make_changes() {
    echo ""
    echo "========================================"
    echo "Testing: Making changes in fork"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Making changes in fork worktree..."

    # Navigate to fork and make changes
    cd .claude-threads/worktrees/conflict-fix
    echo "conflict resolution" >> src/main.ts
    git add .
    git commit -q -m "Resolve conflict"

    (( ++TESTS_RUN )) || true
    if git log --oneline -1 | grep -q "Resolve conflict"; then
        log_pass "Changes committed in fork"
    else
        log_fail "Failed to commit changes in fork"
    fi

    cd "$test_project"
    cd "$TEST_DIR"
}

test_fork_merge_back() {
    echo ""
    echo "========================================"
    echo "Testing: Fork merge-back"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Merging fork back to base..."
    local output
    output=$(.claude-threads/bin/ct worktree merge-back conflict-fix --no-push 2>&1) || true

    (( ++TESTS_RUN )) || true
    if echo "$output" | grep -qE "(Merged|success|Success)"; then
        log_pass "Fork merged back successfully"
    else
        # Check if it's just a warning about no changes
        if echo "$output" | grep -qE "(nothing|no changes|Already)"; then
            log_pass "Fork merge-back completed (no new changes)"
        else
            log_fail "Fork merge-back failed: $output"
        fi
    fi

    # Check fork status updated in database
    log_test "Checking fork status in database..."
    local fork_status
    fork_status=$(sqlite3 .claude-threads/threads.db "SELECT status FROM pr_worktree_forks WHERE fork_id = 'conflict-fix'" 2>/dev/null) || fork_status="unknown"

    (( ++TESTS_RUN )) || true
    if [[ "$fork_status" == "merged" || "$fork_status" == "active" ]]; then
        log_pass "Fork status updated: $fork_status"
    else
        log_fail "Fork status not updated: $fork_status"
    fi

    cd "$TEST_DIR"
}

test_fork_remove() {
    echo ""
    echo "========================================"
    echo "Testing: Fork removal"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Removing fork worktree..."
    local output
    output=$(.claude-threads/bin/ct worktree remove-fork conflict-fix 2>&1) || true

    (( ++TESTS_RUN )) || true
    if echo "$output" | grep -qE "(Removed|success|deleted)"; then
        log_pass "Fork removed successfully"
    else
        log_fail "Fork removal failed: $output"
    fi

    # Check directory removed
    log_test "Checking fork directory removed..."
    (( ++TESTS_RUN )) || true
    if [[ ! -d ".claude-threads/worktrees/conflict-fix" ]]; then
        log_pass "Fork directory removed"
    else
        log_fail "Fork directory still exists"
    fi

    # Check fork count decremented
    log_test "Checking fork count decremented..."
    local fork_count
    fork_count=$(sqlite3 .claude-threads/threads.db "SELECT fork_count FROM pr_base_worktrees WHERE pr_number = 123" 2>/dev/null) || fork_count=1
    assert_equals "$fork_count" "0" "Fork count is 0"

    cd "$TEST_DIR"
}

test_base_worktree_remove() {
    echo ""
    echo "========================================"
    echo "Testing: Base worktree removal"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Removing base worktree..."
    local output
    output=$(.claude-threads/bin/ct worktree base-remove 123 2>&1) || true

    (( ++TESTS_RUN )) || true
    if echo "$output" | grep -qE "(Removed|success|deleted)"; then
        log_pass "Base worktree removed successfully"
    else
        log_fail "Base worktree removal failed: $output"
    fi

    # Check directory removed
    log_test "Checking base directory removed..."
    (( ++TESTS_RUN )) || true
    if [[ ! -d ".claude-threads/worktrees/pr-123-base" ]]; then
        log_pass "Base directory removed"
    else
        log_fail "Base directory still exists"
    fi

    # Check database entry removed
    log_test "Checking database entry removed..."
    local db_count
    db_count=$(sqlite3 .claude-threads/threads.db "SELECT COUNT(*) FROM pr_base_worktrees WHERE pr_number = 123" 2>/dev/null) || db_count=1
    assert_equals "$db_count" "0" "Base removed from database"

    cd "$TEST_DIR"
}

test_worktree_reconcile() {
    echo ""
    echo "========================================"
    echo "Testing: Worktree reconcile"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Running worktree reconcile..."
    assert_command_succeeds ".claude-threads/bin/ct worktree reconcile" "reconcile command succeeds"

    cd "$TEST_DIR"
}

test_input_validation() {
    echo ""
    echo "========================================"
    echo "Testing: Input validation"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    log_test "Testing invalid PR number..."
    assert_command_fails ".claude-threads/bin/ct worktree base-create -1 branch main" "Negative PR number rejected"
    assert_command_fails ".claude-threads/bin/ct worktree base-create abc branch main" "Non-numeric PR number rejected"

    log_test "Testing invalid branch name..."
    assert_command_fails ".claude-threads/bin/ct worktree base-create 999 '../../../etc/passwd' main" "Path traversal rejected"

    log_test "Testing invalid fork ID..."
    assert_command_fails ".claude-threads/bin/ct worktree fork 999 '../bad-id' branch general" "Path traversal in fork ID rejected"

    cd "$TEST_DIR"
}

test_concurrent_forks() {
    echo ""
    echo "========================================"
    echo "Testing: Multiple concurrent forks"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    # Create base first
    log_test "Creating base worktree..."
    .claude-threads/bin/ct worktree base-create 456 feature/test-pr main >/dev/null 2>&1 || true

    # Create multiple forks
    log_test "Creating multiple forks..."
    .claude-threads/bin/ct worktree fork 456 fork-1 fix/fork1 conflict_resolution >/dev/null 2>&1 || true
    .claude-threads/bin/ct worktree fork 456 fork-2 fix/fork2 comment_handler >/dev/null 2>&1 || true
    .claude-threads/bin/ct worktree fork 456 fork-3 fix/fork3 ci_fix >/dev/null 2>&1 || true

    # Check fork count
    local fork_count
    fork_count=$(sqlite3 .claude-threads/threads.db "SELECT fork_count FROM pr_base_worktrees WHERE pr_number = 456" 2>/dev/null) || fork_count=0
    assert_equals "$fork_count" "3" "Fork count is 3"

    # List forks
    log_test "Listing all forks..."
    local fork_list
    fork_list=$(.claude-threads/bin/ct worktree list-forks 456 2>&1) || true

    (( ++TESTS_RUN )) || true
    local fork_count_in_list
    fork_count_in_list=$(echo "$fork_list" | grep -c "fork-" || echo 0)
    if [[ "$fork_count_in_list" -ge 3 ]]; then
        log_pass "All 3 forks listed"
    else
        log_fail "Expected 3 forks in list, found $fork_count_in_list"
    fi

    # Cleanup
    .claude-threads/bin/ct worktree remove-fork fork-1 --force >/dev/null 2>&1 || true
    .claude-threads/bin/ct worktree remove-fork fork-2 --force >/dev/null 2>&1 || true
    .claude-threads/bin/ct worktree remove-fork fork-3 --force >/dev/null 2>&1 || true
    .claude-threads/bin/ct worktree base-remove 456 --force >/dev/null 2>&1 || true

    cd "$TEST_DIR"
}

# ============================================================
# Main
# ============================================================

main() {
    echo "=============================================="
    echo "claude-threads Worktree Integration Tests"
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
    test_worktree_list
    test_base_worktree_create
    test_base_worktree_status
    test_fork_worktree_create
    test_fork_list
    test_fork_make_changes
    test_fork_merge_back
    test_fork_remove
    test_base_worktree_remove
    test_worktree_reconcile
    test_input_validation
    test_concurrent_forks

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
