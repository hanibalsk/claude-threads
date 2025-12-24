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
mkdir -p "$INSTALL_DIR"/{lib,sql,templates/prompts,templates/workflows,logs,tmp}

# Copy library files
cp -r "$SCRIPT_DIR/lib/"* "$INSTALL_DIR/lib/"
cp -r "$SCRIPT_DIR/sql/"* "$INSTALL_DIR/sql/"

# Copy templates if they exist
if [ -d "$SCRIPT_DIR/templates" ]; then
    cp -r "$SCRIPT_DIR/templates/"* "$INSTALL_DIR/templates/" 2>/dev/null || true
fi

echo "✅ Core libraries installed"

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

# Install CLI (if global)
if [ "$GLOBAL_INSTALL" = "1" ]; then
    echo ""
    read -p "📦 Install 'ct' command to /usr/local/bin? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [ -f "$SCRIPT_DIR/bin/ct" ]; then
            sudo cp "$SCRIPT_DIR/bin/ct" /usr/local/bin/ct
            sudo chmod +x /usr/local/bin/ct
            echo "✅ CLI installed to /usr/local/bin/ct"
        else
            echo "⏭️  CLI not yet available (coming in v0.2.0)"
        fi
    fi
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
echo "Next steps:"
echo "  1. Edit $INSTALL_DIR/config.yaml"
echo "  2. Create templates in $INSTALL_DIR/templates/"
echo "  3. Run the orchestrator (coming in v0.2.0)"
echo ""
echo "Documentation: https://github.com/hanibalsk/claude-threads"
echo ""
