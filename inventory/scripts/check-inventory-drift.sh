#!/usr/bin/env bash
set -euo pipefail

# Check for inventory drift across repositories
# Compares canonical inventory with copies in other repos

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY_DIR="$(dirname "$SCRIPT_DIR")"
CANONICAL="${INVENTORY_DIR}/production/hosts.yml"

echo "=== VMStation Inventory Drift Detection ==="
echo "Canonical inventory: ${CANONICAL}"
echo ""

# Check if canonical inventory exists
if [[ ! -f "${CANONICAL}" ]]; then
    echo "ERROR: Canonical inventory not found at ${CANONICAL}"
    exit 1
fi

# Workspace base directory
WORKSPACE_BASE="${HOME}/.vmstation/repos"

# Repositories to check
REPOS=(
    "cluster-config"
    "cluster-setup"
    "cluster-monitor-stack"
    "cluster-application-stack"
)

# Track drift status
drift_detected=0

# Function to check a repository for drift
check_repo() {
    local repo_name="$1"
    local repo_path="${WORKSPACE_BASE}/${repo_name}"
    local inventory="${repo_path}/ansible/inventory/hosts.yml"
    
    if [[ ! -d "$repo_path" ]]; then
        echo "⊘ ${repo_name}: Repository not found"
        return 0
    fi
    
    if [[ ! -f "$inventory" ]]; then
        echo "⊘ ${repo_name}: No inventory file found"
        return 0
    fi
    
    # Check if it's a symlink
    if [[ -L "$inventory" ]]; then
        local link_target="$(readlink "$inventory")"
        if [[ "$link_target" == "$CANONICAL" ]]; then
            echo "✓ ${repo_name}: Symlinked to canonical (in sync)"
        else
            echo "⚠ ${repo_name}: Symlinked to unexpected target: ${link_target}"
            drift_detected=1
        fi
        return 0
    fi
    
    # Compare file contents
    if diff -q "$CANONICAL" "$inventory" > /dev/null 2>&1; then
        echo "✓ ${repo_name}: In sync"
    else
        echo "⚠ ${repo_name}: DRIFT DETECTED"
        echo ""
        echo "  Differences:"
        diff --unified=3 "$CANONICAL" "$inventory" || true
        echo ""
        drift_detected=1
    fi
}

# Check all repositories
echo "Checking repositories for drift..."
echo ""

for repo in "${REPOS[@]}"; do
    check_repo "$repo"
done

echo ""
echo "=== Drift Detection Summary ==="
if [[ $drift_detected -eq 0 ]]; then
    echo "✓ No drift detected"
    echo "  All repositories are in sync with canonical inventory"
    exit 0
else
    echo "⚠ Drift detected in one or more repositories"
    echo "  Run './sync-inventory.sh' to sync inventories"
    exit 1
fi
