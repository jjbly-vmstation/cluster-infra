#!/bin/bash
# Git commands to create branch, commit, push, and create PR
# For identity-deploy-and-handover.yml privilege escalation fixes

set -e

cd /opt/vmstation-org/cluster-infra

# Create and checkout feature branch
git checkout -b fix/identity-deploy-privilege-escalation

# Stage the modified file
git add ansible/playbooks/identity-deploy-and-handover.yml

# Commit with descriptive message
git commit -m "fix: Add privilege escalation and enhanced diagnostics to identity playbook

- Add become: true to all kubectl/helm/tar/cp/sha256sum tasks
- Add kubectl logs collection to PostgreSQL, Keycloak, cert-manager diagnostics
- Create backup_dir upfront to prevent permission errors
- Ensure all file/copy tasks to /root or backup_dir use secure modes
- No timeout changes, fully backward-compatible

Fixes privilege issues when running playbook as non-privileged user with --become flag.
Ensures comprehensive diagnostics capture on rollout failures.

Related: identity deployment automation
"

# Push to remote
echo "Pushing to remote..."
git push -u origin fix/identity-deploy-privilege-escalation

# Create PR using gh CLI (if available)
echo "Creating pull request..."
if command -v gh &> /dev/null; then
    gh pr create \
        --title "Fix privilege escalation and diagnostics in identity-deploy playbook" \
        --body "## Problem
The identity-deploy-and-handover.yml playbook fails when run as a non-privileged user (even with --become) because many tasks don't properly escalate privileges for kubectl, helm, and file operations.

## Solution
- Added \`become: true\` to 40+ tasks requiring root access (kubectl, helm, file ops)
- Enhanced rollout failure diagnostics with pod logs (--all-containers --tail=100)
- Created backup directory upfront with correct permissions to prevent issues
- All changes maintain idempotency and backward compatibility

## Changes
- Tasks accessing /etc/kubernetes/admin.conf now use become: true
- Diagnostic collection includes pod logs for PostgreSQL, Keycloak, cert-manager
- Backup directory created at start of playbook with mode 0700, owner root

## Testing
\`\`\`bash
cd /opt/vmstation-org/cluster-infra
sudo ansible-playbook -i /opt/vmstation-org/cluster-setup/ansible/inventory/hosts.yml ansible/playbooks/identity-deploy-and-handover.yml --become
\`\`\`

## Related Issues
Fixes privilege escalation issues in identity stack deployment automation.

## Review Checklist
- [x] No timeout increases
- [x] Backward compatible
- [x] Minimal changes only
- [x] Enhanced diagnostics on failures
- [x] Proactive permission handling
" \
        --base main \
        --head fix/identity-deploy-privilege-escalation
else
    echo "gh CLI not found. Please create PR manually with:"
    echo "  Title: Fix privilege escalation and diagnostics in identity-deploy playbook"
    echo "  Branch: fix/identity-deploy-privilege-escalation"
    echo "  Base: main"
fi

echo ""
echo "✅ Done! Branch created, committed, and pushed."
echo "📝 Patch file: /opt/vmstation-org/diff-patches/20251210-identity-deploy-privilege-fix.patch"
echo "📋 Rationale: /opt/vmstation-org/diff-patches/20251210-identity-deploy-privilege-fix-RATIONALE.md"
