#!/usr/bin/env bash
#
# claude-threads installer
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "0.1.0")

echo "🧵 claude-threads installer v$VERSION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check prerequisites
echo "📋 Checking prerequisites..."
missing=()
for cmd in sqlite3 jq git; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        missing+=("$cmd")
    fi
done

# Check for Claude (optional but recommended)
if ! command -v claude >/dev/null 2>&1; then
    echo "⚠️  claude CLI not found (optional but recommended)"
fi

if [ ${#missing[@]} -gt 0 ]; then
    echo "❌ Missing required commands: ${missing[*]}"
    echo ""
    echo "Install them first:"
    echo "  sqlite3 - brew install sqlite3 (usually pre-installed)"
    echo "  jq      - brew install jq"
    echo ""
    exit 1
fi
echo "✅ All prerequisites found"
echo ""

# Determine installation type
TARGET_DIR="${1:-$(pwd)}"

echo "Where to install?"
echo "  1) Current project: $TARGET_DIR/.claude-threads"
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

echo ""
echo "📁 Installing to: $INSTALL_DIR"

# Create directories
mkdir -p "$INSTALL_DIR"/{lib,sql,scripts,bin,templates/prompts,templates/workflows,commands,logs,tmp}

# Copy library files
cp -r "$SCRIPT_DIR/lib/"* "$INSTALL_DIR/lib/"
cp -r "$SCRIPT_DIR/sql/"* "$INSTALL_DIR/sql/"
echo "✅ Core libraries installed"

# Copy scripts
if [ -d "$SCRIPT_DIR/scripts" ]; then
    cp -r "$SCRIPT_DIR/scripts/"* "$INSTALL_DIR/scripts/"
    chmod +x "$INSTALL_DIR/scripts/"*.sh
    echo "✅ Scripts installed (orchestrator, thread-runner, webhook-server, api-server)"
fi

# Copy CLI
if [ -f "$SCRIPT_DIR/bin/ct" ]; then
    cp "$SCRIPT_DIR/bin/ct" "$INSTALL_DIR/bin/"
    chmod +x "$INSTALL_DIR/bin/ct"
    echo "✅ CLI tool installed"
fi

# Copy templates
if [ -d "$SCRIPT_DIR/templates" ]; then
    cp -r "$SCRIPT_DIR/templates/"* "$INSTALL_DIR/templates/" 2>/dev/null || true
    echo "✅ Templates installed"
fi

# Copy commands
if [ -d "$SCRIPT_DIR/commands" ]; then
    cp -r "$SCRIPT_DIR/commands/"* "$INSTALL_DIR/commands/" 2>/dev/null || true
    echo "✅ Claude Code commands installed"
fi

# Copy config example
if [ ! -f "$INSTALL_DIR/config.yaml" ]; then
    cp "$SCRIPT_DIR/config.example.yaml" "$INSTALL_DIR/config.yaml"
    echo "✅ Config file created"
else
    echo "ℹ️  Config file already exists, skipping"
fi

# Initialize database
echo ""
echo "🗄️  Initializing database..."
sqlite3 "$INSTALL_DIR/threads.db" < "$INSTALL_DIR/sql/schema.sql"
echo "✅ Database initialized"

# Install CLI to PATH (if global)
if [ "$GLOBAL_INSTALL" = "1" ]; then
    echo ""
    read -p "📦 Install 'ct' command to /usr/local/bin? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        sudo cp "$SCRIPT_DIR/bin/ct" /usr/local/bin/ct
        sudo chmod +x /usr/local/bin/ct
        echo "✅ CLI installed to /usr/local/bin/ct"
    else
        echo "ℹ️  Add $INSTALL_DIR/bin to your PATH to use 'ct' command"
    fi
fi

# Optional: Install integration servers
echo ""
read -p "🔌 Configure GitHub webhook integration? [y/N] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -p "   Webhook port (default: 8080): " WEBHOOK_PORT
    WEBHOOK_PORT="${WEBHOOK_PORT:-8080}"

    # Update config
    if command -v yq >/dev/null 2>&1; then
        yq -i ".github.enabled = true | .github.webhook_port = $WEBHOOK_PORT" "$INSTALL_DIR/config.yaml"
    else
        echo "   ℹ️  Please manually set github.enabled=true in config.yaml"
    fi
    echo "✅ GitHub webhook configured on port $WEBHOOK_PORT"
    echo "   Start with: $INSTALL_DIR/scripts/webhook-server.sh start"
fi

echo ""
read -p "🔌 Configure n8n API integration? [y/N] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -p "   API port (default: 8081): " API_PORT
    API_PORT="${API_PORT:-8081}"

    if command -v yq >/dev/null 2>&1; then
        yq -i ".n8n.enabled = true | .n8n.api_port = $API_PORT" "$INSTALL_DIR/config.yaml"
    else
        echo "   ℹ️  Please manually set n8n.enabled=true in config.yaml"
    fi
    echo "✅ n8n API configured on port $API_PORT"
    echo "   Start with: $INSTALL_DIR/scripts/api-server.sh start"
fi

# Add to .gitignore if local install
if [ "$GLOBAL_INSTALL" = "0" ] && [ -f "$TARGET_DIR/.gitignore" ]; then
    if ! grep -q "^\\.claude-threads/$" "$TARGET_DIR/.gitignore" 2>/dev/null; then
        echo "" >> "$TARGET_DIR/.gitignore"
        echo "# claude-threads" >> "$TARGET_DIR/.gitignore"
        echo ".claude-threads/" >> "$TARGET_DIR/.gitignore"
        echo "✅ Added .claude-threads/ to .gitignore"
    fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 Installation complete!"
echo ""
echo "Quick start:"
if [ "$GLOBAL_INSTALL" = "1" ]; then
    echo "  ct thread create developer --mode automatic --template prompts/developer.md"
    echo "  ct orchestrator start"
else
    echo "  $INSTALL_DIR/bin/ct thread create developer --mode automatic"
    echo "  $INSTALL_DIR/scripts/orchestrator.sh start"
fi
echo ""
echo "Available commands:"
echo "  ct thread list          List all threads"
echo "  ct orchestrator status  Check orchestrator status"
echo "  ct event list           View recent events"
echo ""
echo "Integration servers:"
echo "  webhook-server.sh start  GitHub webhook receiver (port 8080)"
echo "  api-server.sh start      n8n REST API (port 8081)"
echo ""
echo "Documentation: https://github.com/hanibalsk/claude-threads"
echo ""
