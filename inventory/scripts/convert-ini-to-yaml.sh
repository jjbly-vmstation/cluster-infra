#!/usr/bin/env bash
set -euo pipefail

# Convert INI inventory to YAML format
# This is a helper script for migrating legacy INI inventories

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Inventory INI to YAML Converter ==="
echo ""

# Check if source file is provided
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <input.ini> [output.yml]"
    echo ""
    echo "Example:"
    echo "  $0 inventory.ini production/hosts.yml"
    exit 1
fi

INPUT_FILE="$1"
OUTPUT_FILE="${2:-hosts.yml}"

# Check if input file exists
if [[ ! -f "$INPUT_FILE" ]]; then
    echo "ERROR: Input file not found: $INPUT_FILE"
    exit 1
fi

# Check if ansible-inventory is available
if ! command -v ansible-inventory &> /dev/null; then
    echo "ERROR: ansible-inventory command not found"
    echo "Please install Ansible: pip install ansible"
    exit 1
fi

echo "Converting ${INPUT_FILE} to ${OUTPUT_FILE}..."
echo ""

# Use ansible-inventory to convert
if ansible-inventory -i "$INPUT_FILE" --list --yaml > "$OUTPUT_FILE" 2>/dev/null; then
    echo "✓ Conversion successful"
    echo "  Output: ${OUTPUT_FILE}"
    echo ""
    echo "Note: You may need to manually adjust:"
    echo "  - Group structure (rename groups to Kubespray standard)"
    echo "  - Add 'ip' and 'access_ip' variables for each host"
    echo "  - Move vars to group_vars/ and host_vars/ files"
    echo "  - Remove auto-generated '_meta' sections"
else
    echo "ERROR: Conversion failed"
    echo ""
    echo "Try manually converting the inventory or check for syntax errors."
    exit 1
fi
