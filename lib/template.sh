#!/usr/bin/env bash
#
# template.sh - Template rendering for claude-threads
#
# Simple Mustache-like template engine for prompt and workflow templates.
# Supports variable substitution, conditionals, and includes.
#
# Template syntax:
#   {{variable}}           - Variable substitution
#   {{#if variable}}...{{/if}} - Conditional block
#   {{#include file}}      - Include another template
#   {{#json variable}}     - Output variable as JSON
#
# Usage:
#   source lib/template.sh
#   template_render "templates/prompts/developer.md" '{"epic_id": "41"}'
#

# Prevent double-sourcing
[[ -n "${_CT_TEMPLATE_LOADED:-}" ]] && return 0
_CT_TEMPLATE_LOADED=1

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/log.sh"

# ============================================================
# Configuration
# ============================================================

_TEMPLATE_BASE_DIR=""

# ============================================================
# Initialization
# ============================================================

# Set base directory for templates
template_init() {
    _TEMPLATE_BASE_DIR="${1:-$(ct_root_dir)/templates}"
    log_debug "Template base directory: $_TEMPLATE_BASE_DIR"
}

# ============================================================
# Template Loading
# ============================================================

# Load a template file
template_load() {
    local template_path="$1"

    # Resolve path
    local full_path
    if [[ "$template_path" = /* ]]; then
        full_path="$template_path"
    else
        full_path="$_TEMPLATE_BASE_DIR/$template_path"
    fi

    if [[ ! -f "$full_path" ]]; then
        ct_error "Template not found: $full_path"
        return 1
    fi

    cat "$full_path"
}

# Parse template frontmatter (YAML-like header)
template_frontmatter() {
    local content="$1"

    # Check for frontmatter markers
    if [[ "$content" != ---* ]]; then
        echo "{}"
        return
    fi

    # Extract frontmatter
    local frontmatter
    frontmatter=$(echo "$content" | sed -n '/^---$/,/^---$/p' | sed '1d;$d')

    # Simple YAML to JSON conversion
    echo "$frontmatter" | awk '
        BEGIN { print "{" }
        /^[a-zA-Z_]+:/ {
            gsub(/:/, "", $1)
            $1 = "\"" $1 "\":"
            sub(/: */, "", $0)
            if ($0 ~ /^\[/) {
                # Array
                print $1, $0 ","
            } else if ($0 ~ /^[0-9]+$/) {
                # Number
                print $1, $0 ","
            } else {
                # String
                gsub(/^[ \t]+|[ \t]+$/, "", $0)
                print $1, "\"" $0 "\","
            }
        }
        END {
            print "\"_\": null }"
        }
    ' | jq 'del(._)'
}

# Get template body (without frontmatter)
template_body() {
    local content="$1"

    if [[ "$content" != ---* ]]; then
        echo "$content"
        return
    fi

    # Skip frontmatter
    echo "$content" | awk '
        BEGIN { in_fm = 0; skip = 1 }
        /^---$/ {
            if (skip) {
                in_fm = !in_fm
                if (!in_fm) skip = 0
                next
            }
        }
        !skip { print }
    '
}

# ============================================================
# Variable Substitution
# ============================================================

# Substitute variables in template
template_substitute() {
    local content="$1"
    local context="$2"

    # Get list of variables from context
    local vars
    vars=$(echo "$context" | jq -r 'keys[]')

    # Replace each variable
    local result="$content"
    while IFS= read -r var; do
        local value
        value=$(echo "$context" | jq -r --arg v "$var" '.[$v] // ""')

        # Escape special characters for sed
        local escaped_value
        escaped_value=$(printf '%s' "$value" | sed 's/[&/\]/\\&/g')

        # Replace {{variable}} with value
        result=$(echo "$result" | sed "s/{{${var}}}/${escaped_value}/g")
    done <<< "$vars"

    # Handle any remaining unsubstituted variables
    result=$(echo "$result" | sed 's/{{[^}]*}}//g')

    echo "$result"
}

# ============================================================
# Conditional Blocks
# ============================================================

# Process conditional blocks
template_conditionals() {
    local content="$1"
    local context="$2"

    local result="$content"

    # Process {{#if variable}}...{{/if}} blocks
    # This is a simplified implementation
    while [[ "$result" =~ \{\{#if\ ([^}]+)\}\} ]]; do
        local var="${BASH_REMATCH[1]}"
        local value
        value=$(echo "$context" | jq -r --arg v "$var" '.[$v] // ""')

        if [[ -n "$value" && "$value" != "null" && "$value" != "false" ]]; then
            # Variable is truthy - keep block content
            result=$(echo "$result" | sed "s/{{#if ${var}}}//;s/{{\/if}}//")
        else
            # Variable is falsy - remove block
            result=$(echo "$result" | sed "s/{{#if ${var}}}.*{{\/if}}//g")
        fi
    done

    echo "$result"
}

# ============================================================
# Include Processing
# ============================================================

# Process include directives
template_includes() {
    local content="$1"
    local context="$2"
    local depth="${3:-0}"

    # Prevent infinite recursion
    if [[ $depth -gt 10 ]]; then
        ct_warn "Maximum include depth reached"
        echo "$content"
        return
    fi

    local result="$content"

    # Process {{#include file}} directives
    while [[ "$result" =~ \{\{#include\ ([^}]+)\}\} ]]; do
        local include_file="${BASH_REMATCH[1]}"

        local included_content
        if included_content=$(template_load "$include_file"); then
            # Recursively process included template
            included_content=$(template_render_internal "$included_content" "$context" $((depth + 1)))
        else
            included_content="<!-- Include not found: $include_file -->"
        fi

        # Replace include directive with content
        result="${result/\{\{#include ${include_file}\}\}/$included_content}"
    done

    echo "$result"
}

# ============================================================
# JSON Output
# ============================================================

# Process JSON output blocks
template_json() {
    local content="$1"
    local context="$2"

    local result="$content"

    # Process {{#json variable}} directives
    while [[ "$result" =~ \{\{#json\ ([^}]+)\}\} ]]; do
        local var="${BASH_REMATCH[1]}"
        local value
        value=$(echo "$context" | jq --arg v "$var" '.[$v]')

        result="${result/\{\{#json ${var}\}\}/$value}"
    done

    echo "$result"
}

# ============================================================
# Main Render Function
# ============================================================

# Internal render function with depth tracking
template_render_internal() {
    local content="$1"
    local context="$2"
    local depth="${3:-0}"

    # Process includes first
    local result
    result=$(template_includes "$content" "$context" "$depth")

    # Process conditionals
    result=$(template_conditionals "$result" "$context")

    # Process JSON outputs
    result=$(template_json "$result" "$context")

    # Substitute variables last
    result=$(template_substitute "$result" "$context")

    echo "$result"
}

# Render a template file with context
template_render() {
    local template_path="$1"
    local context="${2:-{}}"

    # Initialize if needed
    [[ -z "$_TEMPLATE_BASE_DIR" ]] && template_init

    # Load template
    local content
    content=$(template_load "$template_path") || return 1

    # Extract body (skip frontmatter)
    local body
    body=$(template_body "$content")

    # Merge frontmatter defaults with provided context
    local frontmatter
    frontmatter=$(template_frontmatter "$content")

    local merged_context
    merged_context=$(echo "$frontmatter" | jq --argjson ctx "$context" '. * $ctx')

    # Render
    template_render_internal "$body" "$merged_context" 0
}

# Render a template string (not from file)
template_render_string() {
    local content="$1"
    local context="${2:-{}}"

    template_render_internal "$content" "$context" 0
}

# ============================================================
# Template Validation
# ============================================================

# List variables in a template
template_list_vars() {
    local template_path="$1"

    local content
    content=$(template_load "$template_path") || return 1

    # Extract all {{variable}} patterns
    echo "$content" | grep -oE '\{\{[^#/][^}]*\}\}' | \
        sed 's/{{//g; s/}}//g' | \
        sort -u
}

# Validate template has all required variables
template_validate() {
    local template_path="$1"
    local context="$2"

    local content
    content=$(template_load "$template_path") || return 1

    # Get frontmatter
    local frontmatter
    frontmatter=$(template_frontmatter "$content")

    # Check required variables
    local required
    required=$(echo "$frontmatter" | jq -r '.variables // [] | .[]')

    local missing=()
    while IFS= read -r var; do
        [[ -z "$var" ]] && continue
        local value
        value=$(echo "$context" | jq -r --arg v "$var" '.[$v] // empty')
        if [[ -z "$value" ]]; then
            missing+=("$var")
        fi
    done <<< "$required"

    if [[ ${#missing[@]} -gt 0 ]]; then
        ct_error "Missing required variables: ${missing[*]}"
        return 1
    fi

    return 0
}
