#!/usr/bin/env bash
#
# validate-network-remediation.sh
# 
# Quick validation script to check if network-remediation role is properly integrated
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Network Remediation Role Validation ==="
echo ""

# Check role exists
if [ -d "$REPO_ROOT/ansible/roles/network-remediation" ]; then
    echo "✓ network-remediation role directory exists"
else
    echo "✗ network-remediation role directory NOT found"
    exit 1
fi

# Check required files
REQUIRED_FILES=(
    "ansible/roles/network-remediation/defaults/main.yml"
    "ansible/roles/network-remediation/meta/main.yml"
    "ansible/roles/network-remediation/tasks/main.yml"
    "ansible/roles/network-remediation/tasks/validate-pod-to-clusterip.yml"
    "ansible/roles/network-remediation/tasks/remediate-node-network.yml"
    "ansible/roles/network-remediation/tasks/diagnose-and-collect.yml"
    "ansible/roles/network-remediation/tasks/remediation-loop.yml"
    "ansible/roles/network-remediation/README.md"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [ -f "$REPO_ROOT/$file" ]; then
        echo "✓ $file exists"
    else
        echo "✗ $file NOT found"
        exit 1
    fi
done

# Check integration in main playbook
if grep -q "network-remediation" "$REPO_ROOT/ansible/playbooks/identity-deploy-and-handover.yml"; then
    echo "✓ network-remediation role integrated in identity-deploy-and-handover.yml"
else
    echo "✗ network-remediation role NOT integrated in playbook"
    exit 1
fi

# Check documentation
if [ -f "$REPO_ROOT/docs/AUTOMATED-IDENTITY-DEPLOYMENT.md" ]; then
    echo "✓ AUTOMATED-IDENTITY-DEPLOYMENT.md documentation exists"
else
    echo "✗ Documentation NOT found"
    exit 1
fi

# Syntax check
echo ""
echo "=== Ansible Syntax Check ==="
cd "$REPO_ROOT"

if command -v ansible-playbook >/dev/null 2>&1; then
    if ansible-playbook --syntax-check ansible/playbooks/identity-deploy-and-handover.yml 2>&1 | grep -q "playbook:"; then
        echo "✓ Main playbook syntax is valid"
    else
        echo "✗ Main playbook syntax check failed"
        exit 1
    fi
    
    if ansible-playbook --syntax-check ansible/playbooks/test-network-remediation.yml 2>&1 | grep -q "playbook:"; then
        echo "✓ Test playbook syntax is valid"
    else
        echo "✗ Test playbook syntax check failed"
        exit 1
    fi
else
    echo "⚠ ansible-playbook not found - skipping syntax check"
fi

echo ""
echo "=== Validation Complete ==="
echo "All checks passed! The network-remediation role is properly integrated."
echo ""
echo "Next steps:"
echo "  1. Review changes: git log --oneline"
echo "  2. Test deployment: sudo ./scripts/identity-full-deploy.sh"
echo "  3. Check documentation: docs/AUTOMATED-IDENTITY-DEPLOYMENT.md"
