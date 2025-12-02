#!/usr/bin/env bash
set -euo pipefail

# Sync inventory to other repositories
# Creates symlinks to the canonical inventory in other repos

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY_DIR="$(dirname "$SCRIPT_DIR")"
CANONICAL_INVENTORY="${INVENTORY_DIR}/production/hosts.yml"

echo "=== VMStation Inventory Sync ==="
echo "Canonical inventory: ${CANONICAL_INVENTORY}"
echo ""

# Check if canonical inventory exists
if [[ ! -f "${CANONICAL_INVENTORY}" ]]; then
    echo "ERROR: Canonical inventory not found at ${CANONICAL_INVENTORY}"
    exit 1
fi

# Define target repositories
# These paths are relative to the standard VMStation workspace structure
WORKSPACE_BASE="${HOME}/.vmstation/repos"

REPOS=(
    "${WORKSPACE_BASE}/cluster-config"
    "${WORKSPACE_BASE}/cluster-setup"
    "${WORKSPACE_BASE}/cluster-monitor-stack"
    "${WORKSPACE_BASE}/cluster-application-stack"
)

# Function to sync inventory to a repository
sync_to_repo() {
    local repo="$1"
    local repo_name="$(basename "$repo")"
    
    if [[ ! -d "$repo" ]]; then
        echo "⊘ Repository not found: ${repo_name}"
        return 0
    fi
    
    echo "→ Syncing to ${repo_name}..."
    
    # Create inventory directory in target repo
    local target_dir="${repo}/ansible/inventory"
    mkdir -p "$target_dir"
    
    # Create symlink to canonical inventory
    local target_link="${target_dir}/hosts.yml"
    
    # Remove existing file/link if present
    if [[ -e "$target_link" || -L "$target_link" ]]; then
        rm -f "$target_link"
    fi
    
    # Create symlink
    if ln -s "${CANONICAL_INVENTORY}" "$target_link" 2>/dev/null; then
        echo "  ✓ Symlink created: ${target_link} -> ${CANONICAL_INVENTORY}"
    else
        echo "  ⚠ Failed to create symlink, copying file instead"
        cp "${CANONICAL_INVENTORY}" "$target_link"
        echo "  ✓ File copied to: ${target_link}"
    fi
}

# Sync to all repositories
echo "Syncing inventory to configured repositories..."
echo ""

for repo in "${REPOS[@]}"; do
    sync_to_repo "$repo"
done

echo ""
echo "=== Sync Summary ==="
echo "✓ Inventory sync completed"
echo ""
echo "Note: Repositories not found in ${WORKSPACE_BASE} were skipped."
echo "      Clone repositories to ${WORKSPACE_BASE} to enable sync."
