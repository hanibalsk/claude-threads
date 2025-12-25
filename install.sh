#!/usr/bin/env bash
#
# claude-threads installer
# Multi-Agent Thread Orchestration Framework for Claude Code
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$(pwd)"
FORCE_INSTALL_MODE="" # "local" | "global" | ""

usage() {
    cat <<EOF
claude-threads installer

Usage:
  ./install.sh [options] [project_dir]

Options:
  --global            Install to ~/.claude-threads (skip install-location prompt)
  --local             Install to <project_dir>/.claude-threads (skip install-location prompt)
  --target DIR        Set project directory (default: current directory)
  --help              Show this help

Examples:
  ./install.sh
  ./install.sh --global
  ./install.sh --target /path/to/project
  ./install.sh /path/to/project
EOF
}

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --global)
            FORCE_INSTALL_MODE="global"
            shift
            ;;
        --local)
            FORCE_INSTALL_MODE="local"
            shift
            ;;
        --target|-t)
            TARGET_DIR="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "" >&2
            usage >&2
            exit 1
            ;;
        *)
            TARGET_DIR="$1"
            shift
            ;;
    esac
done

BACKUP_DIR="$TARGET_DIR/.claude-threads/backup"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"

# Read version from VERSION file
VERSION="1.0.0"
if [[ -f "$SCRIPT_DIR/VERSION" ]]; then
    VERSION=$(cat "$SCRIPT_DIR/VERSION" | tr -d '[:space:]')
fi

echo "🧵 claude-threads installer v$VERSION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check prerequisites
echo "📋 Checking prerequisites..."
missing=()
required_cmds=(sqlite3 jq git)
optional_cmds=(claude gh yq python3 rg zip)

for cmd in "${required_cmds[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        missing+=("$cmd")
    fi
done

if [ ${#missing[@]} -gt 0 ]; then
    echo "❌ Missing required commands: ${missing[*]}"
    echo ""
    echo "Install them first:"
    echo "  sqlite3 - brew install sqlite3 (usually pre-installed)"
    echo "  jq      - brew install jq"
    echo "  git     - brew install git"
    echo ""
    exit 1
fi
echo "✅ Required: sqlite3, jq, git"

# Check optional commands
optional_missing=()
for cmd in "${optional_cmds[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        optional_missing+=("$cmd")
    fi
done

if [ ${#optional_missing[@]} -gt 0 ]; then
    echo "⚠️  Optional (recommended): ${optional_missing[*]}"
    echo "   claude  - Claude Code CLI (required for agent execution)"
    echo "   gh      - GitHub CLI (for PR management)"
    echo "   yq      - YAML processor (for config editing)"
    echo "   python3 - Webhook/API servers"
    echo "   rg      - ripgrep (faster searches)"
    echo "   zip     - Backup compression"
else
    echo "✅ Optional: claude, gh, yq, python3, rg, zip"
fi
echo ""

# Backup existing files before installation
BACKUP_CREATED=false
backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        mkdir -p "$BACKUP_DIR"
        local backup_zip="$BACKUP_DIR/${TIMESTAMP}.zip"
        if [ "$BACKUP_CREATED" = false ]; then
            echo "⚠️  Found existing files, creating backup..."
            BACKUP_CREATED=true
        fi
        echo "   → $(basename "$file")"
        if command -v zip >/dev/null 2>&1; then
            zip -q -u "$backup_zip" "$file" 2>/dev/null || zip -q "$backup_zip" "$file"
        else
            # Fallback: copy to backup dir
            cp "$file" "$BACKUP_DIR/$(basename "$file").$TIMESTAMP"
        fi
    fi
}

backup_dir() {
    local dir="$1"
    if [ -d "$dir" ]; then
        mkdir -p "$BACKUP_DIR"
        local backup_zip="$BACKUP_DIR/${TIMESTAMP}.zip"
        if [ "$BACKUP_CREATED" = false ]; then
            echo "⚠️  Found existing files, creating backup..."
            BACKUP_CREATED=true
        fi
        echo "   → $(basename "$dir")/"
        if command -v zip >/dev/null 2>&1; then
            (cd "$(dirname "$dir")" && zip -q -r -u "$backup_zip" "$(basename "$dir")" 2>/dev/null) || \
            (cd "$(dirname "$dir")" && zip -q -r "$backup_zip" "$(basename "$dir")")
        fi
    fi
}

# Check for existing installation and backup
echo "🔍 Checking for existing installation..."

# Backup claude-threads files
backup_file "$TARGET_DIR/.claude-threads/config.yaml"
backup_file "$TARGET_DIR/.claude-threads/threads.db"
backup_dir "$TARGET_DIR/.claude-threads/templates"

# Backup local Claude commands/skills/agents
backup_dir "$TARGET_DIR/.claude/commands"
backup_dir "$TARGET_DIR/.claude/skills"
backup_dir "$TARGET_DIR/.claude/agents"

# Backup global Claude commands/skills/agents
backup_dir "$HOME/.claude/commands"
backup_dir "$HOME/.claude/skills"
backup_dir "$HOME/.claude/agents"

if [ "$BACKUP_CREATED" = true ]; then
    echo "✅ Backup created: $BACKUP_DIR/${TIMESTAMP}.zip"
else
    echo "✅ No existing installation found"
fi
echo ""

# Determine installation type
if [[ "$FORCE_INSTALL_MODE" == "global" ]]; then
    INSTALL_DIR="$HOME/.claude-threads"
    GLOBAL_INSTALL=1
elif [[ "$FORCE_INSTALL_MODE" == "local" ]]; then
    INSTALL_DIR="$TARGET_DIR/.claude-threads"
    GLOBAL_INSTALL=0
else
    echo "Where to install claude-threads?"
    echo "  1) Current project: $TARGET_DIR/.claude-threads (recommended)"
    echo "  2) Global: ~/.claude-threads"
    read -p "Choose [1/2] (default: 1): " -n 1 -r
    echo ""

    if [[ $REPLY = "2" ]]; then
        INSTALL_DIR="$HOME/.claude-threads"
        GLOBAL_INSTALL=1
    else
        INSTALL_DIR="$TARGET_DIR/.claude-threads"
        GLOBAL_INSTALL=0
    fi
fi

echo ""
echo "📁 Installing to: $INSTALL_DIR"

# Create directories
mkdir -p "$INSTALL_DIR"/{lib,sql,scripts,bin,templates/prompts,templates/workflows,logs,tmp}

# Copy library files
cp -r "$SCRIPT_DIR/lib/"* "$INSTALL_DIR/lib/"
cp -r "$SCRIPT_DIR/sql/"* "$INSTALL_DIR/sql/"
echo "✅ Core libraries installed"

# Copy scripts
if [ -d "$SCRIPT_DIR/scripts" ]; then
    cp -r "$SCRIPT_DIR/scripts/"* "$INSTALL_DIR/scripts/"
    chmod +x "$INSTALL_DIR/scripts/"*.sh 2>/dev/null || true
    echo "✅ Scripts installed"
fi

# Copy CLI
if [ -f "$SCRIPT_DIR/bin/ct" ]; then
    cp "$SCRIPT_DIR/bin/ct" "$INSTALL_DIR/bin/"
    chmod +x "$INSTALL_DIR/bin/ct"
    echo "✅ CLI tool installed"
fi

# Copy VERSION file
if [ -f "$SCRIPT_DIR/VERSION" ]; then
    cp "$SCRIPT_DIR/VERSION" "$INSTALL_DIR/VERSION"
    echo "✅ Version file installed (v$VERSION)"
fi

# Copy templates
if [ -d "$SCRIPT_DIR/templates" ]; then
    cp -r "$SCRIPT_DIR/templates/"* "$INSTALL_DIR/templates/" 2>/dev/null || true
    echo "✅ Templates installed"
fi

# Copy config example
if [ ! -f "$INSTALL_DIR/config.yaml" ]; then
    cp "$SCRIPT_DIR/config.example.yaml" "$INSTALL_DIR/config.yaml"
    echo "✅ Config file created"
else
    echo "ℹ️  Config file already exists, keeping existing"
    # Update example anyway
    cp "$SCRIPT_DIR/config.example.yaml" "$INSTALL_DIR/config.example.yaml"
fi

# Initialize database
echo ""
echo "🗄️  Initializing database..."
if [ -f "$INSTALL_DIR/threads.db" ]; then
    echo "ℹ️  Database already exists"
    # Run migrations for existing database
    if [ -d "$INSTALL_DIR/sql/migrations" ]; then
        echo "🔄 Checking for pending migrations..."
        if "$INSTALL_DIR/scripts/migrate.sh" --db "$INSTALL_DIR/threads.db"; then
            echo "✅ Database migrations complete"
        else
            echo "⚠️  Some migrations failed, check logs"
        fi
    fi
else
    sqlite3 "$INSTALL_DIR/threads.db" < "$INSTALL_DIR/sql/schema.sql"
    # Record all migrations as applied for new database
    sqlite3 "$INSTALL_DIR/threads.db" "CREATE TABLE IF NOT EXISTS schema_migrations (
        version INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        applied_at TEXT DEFAULT (datetime('now'))
    );"
    # Mark all existing migrations as applied
    for migration in "$INSTALL_DIR"/sql/migrations/*.sql; do
        if [ -f "$migration" ]; then
            name=$(basename "$migration" .sql)
            version=$(echo "$name" | sed 's/_.*//' | sed 's/^0*//')
            if [ -n "$version" ] && [ "$version" -gt 0 ] 2>/dev/null; then
                sqlite3 "$INSTALL_DIR/threads.db" "INSERT OR IGNORE INTO schema_migrations (version, name) VALUES ($version, '$name');"
            fi
        fi
    done
    echo "✅ Database initialized with schema v1.2.2"
fi

# Install Claude Code commands, skills, and agents
echo ""
read -p "📦 Install Claude Code commands/skills/agents? [Y/n] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    # Detect previous installation location
    COMMANDS_LOCATION=""
    if [ -d "$TARGET_DIR/.claude/commands" ] && [ -f "$TARGET_DIR/.claude/commands/threads.md" ]; then
        COMMANDS_LOCATION="local"
    elif [ -d "$HOME/.claude/commands" ] && [ -f "$HOME/.claude/commands/threads.md" ]; then
        COMMANDS_LOCATION="global"
    fi

    if [ -n "$COMMANDS_LOCATION" ]; then
        echo "ℹ️  Previous installation detected: $COMMANDS_LOCATION"
        if [ "$COMMANDS_LOCATION" = "local" ]; then
            CLAUDE_DIR="$TARGET_DIR/.claude"
        else
            CLAUDE_DIR="$HOME/.claude"
        fi
    else
        echo ""
        echo "Where to install Claude Code commands/skills/agents?"
        echo "  1) Local  - $TARGET_DIR/.claude/ (this project only)"
        echo "  2) Global - ~/.claude/ (all projects)"
        read -p "Choose [1/2] (default: 1): " -n 1 -r
        echo ""
        if [[ $REPLY = "2" ]]; then
            CLAUDE_DIR="$HOME/.claude"
            echo "Installing to global ~/.claude/"
        else
            CLAUDE_DIR="$TARGET_DIR/.claude"
            echo "Installing to local .claude/"
        fi
    fi

    # Install commands
    if [ -d "$SCRIPT_DIR/commands" ]; then
        mkdir -p "$CLAUDE_DIR/commands"
        cp "$SCRIPT_DIR/commands/"*.md "$CLAUDE_DIR/commands/"
        echo "✅ Commands installed: /threads, /bmad, /ct-connect, /ct-spawn, /ct-debug"
    fi

    # Install skills
    if [ -d "$SCRIPT_DIR/skills" ]; then
        mkdir -p "$CLAUDE_DIR/skills"
        cp -r "$SCRIPT_DIR/skills/"* "$CLAUDE_DIR/skills/"
        echo "✅ Skills installed: threads, bmad-autopilot, thread-orchestrator, thread-spawner, orchestrator-control, ct-debug"
    fi

    # Install agents
    if [ -d "$SCRIPT_DIR/.claude/agents" ]; then
        mkdir -p "$CLAUDE_DIR/agents"
        cp "$SCRIPT_DIR/.claude/agents/"*.md "$CLAUDE_DIR/agents/"
        echo "✅ Agents installed: thread-orchestrator, pr-lifecycle-shepherd, merge-conflict-resolver, review-comment-handler, etc."
    fi
else
    echo "⏭️  Skipped Claude Code integration"
fi

# Install GitHub workflows
echo ""
if [ -d "$SCRIPT_DIR/workflows" ]; then
    WORKFLOWS_DIR="$TARGET_DIR/.github/workflows"

    # Check for existing workflow
    if [ -f "$WORKFLOWS_DIR/auto-approve.yml" ]; then
        echo "ℹ️  GitHub workflow already exists"
        read -p "🔄 Update auto-approve workflow? [y/N] " -n 1 -r
        echo ""
        INSTALL_WORKFLOW=$([[ $REPLY =~ ^[Yy]$ ]] && echo "yes" || echo "no")
    else
        read -p "🤖 Install auto-approve GitHub workflow? [y/N] " -n 1 -r
        echo ""
        INSTALL_WORKFLOW=$([[ $REPLY =~ ^[Yy]$ ]] && echo "yes" || echo "no")
    fi

    if [ "$INSTALL_WORKFLOW" = "yes" ]; then
        mkdir -p "$WORKFLOWS_DIR"
        cp "$SCRIPT_DIR/workflows/"*.yml "$WORKFLOWS_DIR/" 2>/dev/null || true
        echo "✅ GitHub workflow installed"
        echo "   → Auto-approves PRs when CI passes and Copilot review complete"
    else
        echo "⏭️  Skipped GitHub workflow"
    fi
fi

# Install CLI to PATH (if global)
if [ "$GLOBAL_INSTALL" = "1" ]; then
    echo ""
    read -p "📦 Install 'ct' command to /usr/local/bin? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [ -w /usr/local/bin ]; then
            cp "$INSTALL_DIR/bin/ct" /usr/local/bin/ct
            chmod +x /usr/local/bin/ct
        else
            sudo cp "$INSTALL_DIR/bin/ct" /usr/local/bin/ct
            sudo chmod +x /usr/local/bin/ct
        fi
        echo "✅ CLI installed to /usr/local/bin/ct"
    else
        echo "ℹ️  Add $INSTALL_DIR/bin to your PATH to use 'ct' command"
    fi
fi

# Configure integrations
echo ""
read -p "🔌 Configure GitHub webhook integration? [y/N] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -p "   Webhook port (default: 31338): " WEBHOOK_PORT
    WEBHOOK_PORT="${WEBHOOK_PORT:-31338}"

    read -p "   Webhook secret (leave empty to generate): " WEBHOOK_SECRET
    if [ -z "$WEBHOOK_SECRET" ]; then
        WEBHOOK_SECRET=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p)
    fi

    # Update config
    if command -v yq >/dev/null 2>&1; then
        yq -i ".github.enabled = true | .github.webhook_port = $WEBHOOK_PORT | .github.webhook_secret = \"$WEBHOOK_SECRET\"" "$INSTALL_DIR/config.yaml"
        echo "✅ GitHub webhook configured on port $WEBHOOK_PORT"
    else
        echo "   ℹ️  Please manually update config.yaml:"
        echo "       github.enabled: true"
        echo "       github.webhook_port: $WEBHOOK_PORT"
        echo "       github.webhook_secret: $WEBHOOK_SECRET"
    fi
    echo ""
    echo "   Configure in GitHub repository settings:"
    echo "   → Webhook URL: http://your-server:$WEBHOOK_PORT/webhook"
    echo "   → Secret: $WEBHOOK_SECRET"
    echo "   → Events: Pull requests, Check runs, Issue comments"
fi

echo ""
read -p "🔌 Configure n8n API integration? [y/N] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -p "   API port (default: 31337): " API_PORT
    API_PORT="${API_PORT:-31337}"

    read -p "   API token (leave empty to generate): " API_TOKEN
    if [ -z "$API_TOKEN" ]; then
        API_TOKEN=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p)
    fi

    if command -v yq >/dev/null 2>&1; then
        yq -i ".n8n.enabled = true | .n8n.api_port = $API_PORT | .n8n.api_token = \"$API_TOKEN\"" "$INSTALL_DIR/config.yaml"
        echo "✅ n8n API configured on port $API_PORT"
    else
        echo "   ℹ️  Please manually update config.yaml:"
        echo "       n8n.enabled: true"
        echo "       n8n.api_port: $API_PORT"
        echo "       n8n.api_token: $API_TOKEN"
    fi
    echo ""
    echo "   API Token: $API_TOKEN"
    echo "   Use header: Authorization: Bearer $API_TOKEN"
fi

# Add to .gitignore if local install
if [ "$GLOBAL_INSTALL" = "0" ]; then
    echo ""
    if [ -f "$TARGET_DIR/.gitignore" ]; then
        GITIGNORE_UPDATED=false

        if ! grep -q "^\.claude-threads/$" "$TARGET_DIR/.gitignore" 2>/dev/null; then
            echo "" >> "$TARGET_DIR/.gitignore"
            echo "# claude-threads" >> "$TARGET_DIR/.gitignore"
            echo ".claude-threads/" >> "$TARGET_DIR/.gitignore"
            GITIGNORE_UPDATED=true
        fi

        if [ "$GITIGNORE_UPDATED" = true ]; then
            echo "✅ Added .claude-threads/ to .gitignore"
        else
            echo "✅ .gitignore already configured"
        fi
    else
        echo "⚠️  No .gitignore found - consider adding .claude-threads/ to it"
    fi
fi

# Final summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 Installation complete!"
echo ""
echo "Quick start:"
if [ "$GLOBAL_INSTALL" = "1" ]; then
    echo "  ct init                              # Initialize in a project"
    echo "  ct thread create dev --mode automatic"
    echo "  ct thread create epic --worktree     # Create with isolated git worktree"
    echo "  ct orchestrator start"
else
    echo "  $INSTALL_DIR/bin/ct thread list"
    echo "  $INSTALL_DIR/bin/ct thread create dev --mode automatic"
    echo "  $INSTALL_DIR/bin/ct thread create epic --worktree"
    echo "  $INSTALL_DIR/bin/ct orchestrator start"
fi
echo ""
echo "Worktree commands:"
echo "  ct worktree list                     # List active worktrees"
echo "  ct worktree status <id>              # Show worktree status"
echo "  ct worktree cleanup                  # Cleanup orphaned worktrees"
echo ""
echo "Base + Fork Pattern (memory-efficient PR sub-agents):"
echo "  ct worktree base-create <pr> <branch> # Create base worktree for PR"
echo "  ct worktree fork <pr> <id> <branch>   # Fork from base for sub-agent"
echo "  ct worktree merge-back <fork-id>      # Merge fork back to base"
echo "  ct worktree reconcile                 # Check/fix DB consistency"
echo ""
echo "PR Shepherd (auto-fix CI/review):"
echo "  ct pr watch 123                      # Watch PR with worktree isolation"
echo "  ct pr status                         # Show all watched PRs"
echo "  ct pr daemon                         # Run as background daemon"
echo ""
echo "Claude Code commands (if installed):"
echo "  /threads list                        # List all threads"
echo "  /threads create <name>               # Create new thread"
echo "  /bmad 7A                             # Run BMAD autopilot"
echo ""
echo "Available skills (if installed):"
echo "  threads              - Thread orchestration"
echo "  bmad-autopilot       - BMAD autonomous development"
echo "  thread-orchestrator  - Multi-agent coordination"
echo "  orchestrator-control - PR lifecycle management"
echo "  thread-spawner       - Spawn threads from remote"
echo "  ct-debug             - Debug and troubleshoot issues"
echo ""
echo "Available agents (if installed):"
echo "  thread-orchestrator      - Multi-agent coordinator with worktree support"
echo "  pr-lifecycle-shepherd    - PR monitoring with sub-agent spawning"
echo "  merge-conflict-resolver  - Auto-resolve merge conflicts"
echo "  review-comment-handler   - Handle review comments"
echo "  story-developer          - Feature implementation"
echo "  code-reviewer            - Quality review"
echo "  security-reviewer        - Security audit"
echo "  test-writer              - Test automation"
echo "  issue-fixer              - CI/review fixes"
echo "  pr-manager               - PR lifecycle management"
echo "  explorer                 - Fast codebase search"
echo ""
echo "Database management:"
echo "  ct migrate                           # Apply pending migrations"
echo "  ct migrate --status                  # Show migration status"
echo ""
echo "Debug and troubleshoot:"
echo "  /ct-debug                            # Run diagnostics"
echo "  ct worktree reconcile                # Check DB/filesystem sync"
echo ""
echo "Integration servers:"
echo "  ct webhook start                     # GitHub webhook receiver"
echo "  ct api start                         # n8n REST API"
echo ""
echo "Documentation:"
echo "  docs/ARCHITECTURE.md                 # System architecture"
echo "  docs/AGENT-COORDINATION.md           # Multi-agent patterns"
echo "  docs/WORKTREE-GUIDE.md               # Worktree management"
echo "  docs/EVENT-REFERENCE.md              # Event types"
echo "  docs/MULTI-INSTANCE.md               # Distributed deployment"
echo ""
echo "GitHub: https://github.com/hanibalsk/claude-threads"
echo ""
