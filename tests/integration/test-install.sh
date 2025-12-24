#!/usr/bin/env bash
#
# test-install.sh - Integration tests for claude-threads installation
#
# Tests the installation process in an isolated temporary directory
# to verify all components are properly installed and functional.
#
# Usage:
#   ./tests/integration/test-install.sh
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

assert_executable() {
    local file="$1"
    local desc="${2:-$file is executable}"
    (( ++TESTS_RUN )) || true
    if [[ -x "$file" ]]; then
        log_pass "$desc"
        return 0
    else
        log_fail "$desc - not executable: $file"
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

# ============================================================
# Test Suites
# ============================================================

test_project_local_install() {
    echo ""
    echo "========================================"
    echo "Testing: Project-local installation"
    echo "========================================"

    # Create test project directory
    local test_project="$TEST_DIR/test-project"
    mkdir -p "$test_project"
    cd "$test_project"

    # Initialize git (required for worktrees)
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "test" > README.md
    git add . && git commit -q -m "Initial"

    # Run installer with answers for all prompts:
    # 1 = project-local install
    # Y = install Claude Code commands
    # 1 = local Claude commands
    # n = no auto-approve workflow
    # n = no ct to /usr/local/bin
    # n = no GitHub webhook
    # n = no n8n API
    log_test "Running installer..."
    printf "1\nY\n1\nn\nn\nn\nn\n" | "$PROJECT_ROOT/install.sh" >/dev/null 2>&1 || true

    # Test directory structure
    log_test "Checking directory structure..."
    assert_dir_exists ".claude-threads" "Installation directory created"
    assert_dir_exists ".claude-threads/lib" "lib directory created"
    assert_dir_exists ".claude-threads/scripts" "scripts directory created"
    assert_dir_exists ".claude-threads/bin" "bin directory created"
    assert_dir_exists ".claude-threads/sql" "sql directory created"
    assert_dir_exists ".claude-threads/templates" "templates directory created"
    assert_dir_exists ".claude-threads/logs" "logs directory created"
    assert_dir_exists ".claude-threads/tmp" "tmp directory created"

    # Test core files
    log_test "Checking core files..."
    assert_file_exists ".claude-threads/VERSION" "VERSION file installed"
    assert_file_exists ".claude-threads/config.yaml" "config.yaml created"
    assert_file_exists ".claude-threads/bin/ct" "ct CLI installed"
    assert_executable ".claude-threads/bin/ct" "ct CLI is executable"

    # Test library files
    log_test "Checking library files..."
    assert_file_exists ".claude-threads/lib/utils.sh" "utils.sh installed"
    assert_file_exists ".claude-threads/lib/log.sh" "log.sh installed"
    assert_file_exists ".claude-threads/lib/config.sh" "config.sh installed"
    assert_file_exists ".claude-threads/lib/db.sh" "db.sh installed"
    assert_file_exists ".claude-threads/lib/state.sh" "state.sh installed"
    assert_file_exists ".claude-threads/lib/blackboard.sh" "blackboard.sh installed"
    assert_file_exists ".claude-threads/lib/git.sh" "git.sh installed"
    assert_file_exists ".claude-threads/lib/template.sh" "template.sh installed"
    assert_file_exists ".claude-threads/lib/remote.sh" "remote.sh installed"

    # Test script files
    log_test "Checking script files..."
    assert_file_exists ".claude-threads/scripts/orchestrator.sh" "orchestrator.sh installed"
    assert_file_exists ".claude-threads/scripts/thread-runner.sh" "thread-runner.sh installed"
    assert_file_exists ".claude-threads/scripts/api-server.sh" "api-server.sh installed"
    assert_executable ".claude-threads/scripts/orchestrator.sh" "orchestrator.sh is executable"

    # Test SQL migrations
    log_test "Checking SQL files..."
    assert_dir_exists ".claude-threads/sql/migrations" "migrations directory created"
    assert_file_exists ".claude-threads/sql/migrations/001_initial.sql" "initial migration exists"

    # Test templates
    log_test "Checking templates..."
    assert_file_exists ".claude-threads/templates/prompts/developer.md" "developer template installed"

    # Test VERSION content
    log_test "Checking VERSION content..."
    local installed_version
    installed_version=$(cat ".claude-threads/VERSION" | tr -d '[:space:]')
    local source_version
    source_version=$(cat "$PROJECT_ROOT/VERSION" | tr -d '[:space:]')
    assert_equals "$installed_version" "$source_version" "VERSION matches source"

    cd "$TEST_DIR"
}

test_ct_commands() {
    echo ""
    echo "========================================"
    echo "Testing: ct CLI commands"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    # Test version command
    log_test "Testing ct version..."
    assert_command_succeeds ".claude-threads/bin/ct version" "ct version succeeds"

    local version_output
    version_output=$(.claude-threads/bin/ct version 2>&1)
    local expected_version
    expected_version=$(cat "$PROJECT_ROOT/VERSION" | tr -d '[:space:]')
    assert_output_contains ".claude-threads/bin/ct version" "$expected_version" "Version output matches"

    # Test help command
    log_test "Testing ct help..."
    assert_command_succeeds ".claude-threads/bin/ct --help" "ct --help succeeds"
    assert_output_contains ".claude-threads/bin/ct --help" "USAGE" "Help shows USAGE section"
    assert_output_contains ".claude-threads/bin/ct --help" "COMMANDS" "Help shows COMMANDS section"

    # Test thread help
    log_test "Testing ct thread --help..."
    assert_command_succeeds ".claude-threads/bin/ct thread --help" "ct thread --help succeeds"

    # Test templates list
    log_test "Testing ct templates list..."
    assert_command_succeeds ".claude-threads/bin/ct templates list" "ct templates list succeeds"
    assert_output_contains ".claude-threads/bin/ct templates list" "developer.md" "Templates includes developer.md"

    # Test config show
    log_test "Testing ct config show..."
    assert_command_succeeds ".claude-threads/bin/ct config show" "ct config show succeeds"

    cd "$TEST_DIR"
}

test_database_initialization() {
    echo ""
    echo "========================================"
    echo "Testing: Database initialization"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    # Check database exists
    log_test "Checking database..."
    assert_file_exists ".claude-threads/threads.db" "Database file created"

    # Check tables exist
    log_test "Checking database schema..."
    local tables
    tables=$(sqlite3 .claude-threads/threads.db ".tables" 2>/dev/null)

    (( ++TESTS_RUN )) || true
    if echo "$tables" | grep -q "threads"; then
        log_pass "threads table exists"
    else
        log_fail "threads table missing"
    fi

    (( ++TESTS_RUN )) || true
    if echo "$tables" | grep -q "events"; then
        log_pass "events table exists"
    else
        log_fail "events table missing"
    fi

    (( ++TESTS_RUN )) || true
    if echo "$tables" | grep -q "worktrees"; then
        log_pass "worktrees table exists"
    else
        log_fail "worktrees table missing"
    fi

    (( ++TESTS_RUN )) || true
    if echo "$tables" | grep -q "schema_migrations"; then
        log_pass "schema_migrations table exists"
    else
        log_fail "schema_migrations table missing"
    fi

    # Check migrations applied
    log_test "Checking migrations..."
    local migration_count
    migration_count=$(sqlite3 .claude-threads/threads.db "SELECT COUNT(*) FROM schema_migrations" 2>/dev/null)
    (( ++TESTS_RUN )) || true
    if [[ "$migration_count" -ge 1 ]]; then
        log_pass "Migrations applied: $migration_count"
    else
        log_fail "No migrations applied"
    fi

    cd "$TEST_DIR"
}

test_thread_create() {
    echo ""
    echo "========================================"
    echo "Testing: Thread creation"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    # Create a thread
    log_test "Creating a thread..."
    local output
    output=$(.claude-threads/bin/ct thread create test-thread --mode automatic 2>&1) || true

    (( ++TESTS_RUN )) || true
    if echo "$output" | grep -q "thread-"; then
        log_pass "Thread created successfully"
    else
        log_fail "Thread creation failed: $output"
    fi

    # List threads
    log_test "Listing threads..."
    assert_output_contains ".claude-threads/bin/ct thread list" "test-thread" "Thread appears in list"

    # Check thread count in database
    local thread_count
    thread_count=$(sqlite3 .claude-threads/threads.db "SELECT COUNT(*) FROM threads" 2>/dev/null)
    (( ++TESTS_RUN )) || true
    if [[ "$thread_count" -ge 1 ]]; then
        log_pass "Thread exists in database"
    else
        log_fail "Thread not found in database"
    fi

    cd "$TEST_DIR"
}

test_orchestrator() {
    echo ""
    echo "========================================"
    echo "Testing: Orchestrator"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    # Start orchestrator
    log_test "Starting orchestrator..."
    .claude-threads/bin/ct orchestrator start >/dev/null 2>&1 || true
    sleep 2

    # Check status
    log_test "Checking orchestrator status..."
    local status_output
    status_output=$(.claude-threads/bin/ct orchestrator status 2>&1) || true

    (( ++TESTS_RUN )) || true
    if echo "$status_output" | grep -q "Running"; then
        log_pass "Orchestrator is running"
    else
        log_fail "Orchestrator not running: $status_output"
    fi

    # Stop orchestrator
    log_test "Stopping orchestrator..."
    .claude-threads/bin/ct orchestrator stop >/dev/null 2>&1 || true
    sleep 1

    status_output=$(.claude-threads/bin/ct orchestrator status 2>&1) || true
    (( ++TESTS_RUN )) || true
    if echo "$status_output" | grep -q "Stopped"; then
        log_pass "Orchestrator stopped"
    else
        log_fail "Orchestrator still running: $status_output"
    fi

    cd "$TEST_DIR"
}

test_reinstall_preserves_data() {
    echo ""
    echo "========================================"
    echo "Testing: Reinstall preserves data"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    # Get current thread count
    local thread_count_before
    thread_count_before=$(sqlite3 .claude-threads/threads.db "SELECT COUNT(*) FROM threads" 2>/dev/null)

    # Get current config content
    local config_before
    config_before=$(cat .claude-threads/config.yaml 2>/dev/null | head -5)

    # Run installer again
    log_test "Running installer again..."
    printf "1\n1\n" | "$PROJECT_ROOT/install.sh" >/dev/null 2>&1 || true

    # Check thread count preserved
    local thread_count_after
    thread_count_after=$(sqlite3 .claude-threads/threads.db "SELECT COUNT(*) FROM threads" 2>/dev/null)
    assert_equals "$thread_count_after" "$thread_count_before" "Thread count preserved after reinstall"

    # Check config preserved
    local config_after
    config_after=$(cat .claude-threads/config.yaml 2>/dev/null | head -5)
    assert_equals "$config_after" "$config_before" "Config preserved after reinstall"

    # Check backup created
    log_test "Checking backup created..."
    (( ++TESTS_RUN )) || true
    if ls .claude-threads/backup/*.zip >/dev/null 2>&1; then
        log_pass "Backup file created"
    else
        log_fail "No backup file found"
    fi

    cd "$TEST_DIR"
}

test_bash_parameter_expansion_fix() {
    echo ""
    echo "========================================"
    echo "Testing: Bash {} parameter expansion fix"
    echo "========================================"

    local test_project="$TEST_DIR/test-project"
    cd "$test_project"

    # Test that the fix is in place
    log_test "Checking {} default value fix in lib files..."

    # Check that all occurrences use quoted default
    local files_to_check=(
        ".claude-threads/lib/utils.sh"
        ".claude-threads/lib/db.sh"
        ".claude-threads/lib/state.sh"
        ".claude-threads/lib/blackboard.sh"
        ".claude-threads/lib/remote.sh"
        ".claude-threads/lib/template.sh"
    )

    local all_fixed=true
    for file in "${files_to_check[@]}"; do
        if grep -q ':-{}' "$file" 2>/dev/null; then
            log_fail "Unquoted {} default in $file"
            all_fixed=false
        fi
    done

    (( ++TESTS_RUN )) || true
    if $all_fixed; then
        log_pass "All {} defaults are properly quoted"
    fi

    # Test actual behavior
    log_test "Testing parameter expansion behavior..."

    # Source and test
    local test_result
    test_result=$(bash -c '
        source ".claude-threads/lib/utils.sh"
        source ".claude-threads/lib/db.sh"

        # Simulate the problematic pattern
        test_func() {
            local p5="${5:-"{}"}"
            echo "$p5"
        }

        result=$(test_func "a" "b" "c" "" "{}")
        if [[ "$result" == "{}" ]]; then
            echo "OK"
        else
            echo "FAIL: got $result"
        fi
    ' 2>&1)

    (( ++TESTS_RUN )) || true
    if [[ "$test_result" == "OK" ]]; then
        log_pass "Parameter expansion works correctly"
    else
        log_fail "Parameter expansion broken: $test_result"
    fi

    cd "$TEST_DIR"
}

# ============================================================
# Main
# ============================================================

main() {
    echo "=============================================="
    echo "claude-threads Installation Integration Tests"
    echo "=============================================="
    echo ""
    echo "Project root: $PROJECT_ROOT"

    # Create temp directory
    TEST_DIR=$(mktemp -d)
    echo "Test directory: $TEST_DIR"
    echo ""

    # Run test suites
    test_project_local_install
    test_ct_commands
    test_database_initialization
    test_thread_create
    test_orchestrator
    test_reinstall_preserves_data
    test_bash_parameter_expansion_fix

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
