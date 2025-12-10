# Identity Deploy Playbook Privilege Fix

## 📦 Deliverables

All files located in `/opt/vmstation-org/diff-patches/`:

1. **20251210-identity-deploy-privilege-fix.patch** - Unified diff (433 lines)
2. **20251210-identity-deploy-privilege-fix-RATIONALE.md** - 3-line summary + detailed rationale
3. **20251210-identity-deploy-privilege-fix-GIT_COMMANDS.sh** - Executable script with all git commands
4. **20251210-identity-deploy-privilege-fix-README.md** - This file

## 📝 3-Line Rationale

1. **Added `become: true` to 40+ tasks** requiring elevated privileges (kubectl, helm, tar, cp, sha256sum) to ensure successful execution from non-privileged users.
2. **Enhanced diagnostics on rollout failures** by capturing `kubectl logs --all-containers --tail=100`, describe output, and sorted events into timestamped files in `{{ backup_dir }}`.
3. **Created backup directory upfront** with secure permissions (0700, root:root) to prevent permission errors before any write operations occur.

## 🚀 How to Apply

### Option 1: Run the Git Commands Script
```bash
cd /opt/vmstation-org/cluster-infra
bash /opt/vmstation-org/diff-patches/20251210-identity-deploy-privilege-fix-GIT_COMMANDS.sh
```

### Option 2: Manual Git Commands
```bash
cd /opt/vmstation-org/cluster-infra

# Create and checkout feature branch
git checkout -b fix/identity-deploy-privilege-escalation

# Apply the patch
git apply /opt/vmstation-org/diff-patches/20251210-identity-deploy-privilege-fix.patch

# Stage and commit
git add ansible/playbooks/identity-deploy-and-handover.yml
git commit -m "fix: Add privilege escalation and enhanced diagnostics to identity playbook

- Add become: true to all kubectl/helm/tar/cp/sha256sum tasks
- Add kubectl logs collection to PostgreSQL, Keycloak, cert-manager diagnostics
- Create backup_dir upfront to prevent permission errors
- Ensure all file/copy tasks to /root or backup_dir use secure modes
- No timeout changes, fully backward-compatible

Fixes privilege issues when running playbook as non-privileged user with --become flag.
Ensures comprehensive diagnostics capture on rollout failures.
"

# Push to remote
git push -u origin fix/identity-deploy-privilege-escalation

# Create PR (requires gh CLI)
gh pr create --title "Fix privilege escalation and diagnostics in identity-deploy playbook" --fill
```

## ✅ What Changed

### Privilege Escalation (become: true added to):
- ✅ kubectl commands (all 30+ instances)
- ✅ helm commands (2 instances)
- ✅ File/copy operations to /root and {{ backup_dir }}
- ✅ tar, cp, sha256sum operations

### Enhanced Diagnostics:
- ✅ PostgreSQL rollout failures → collect logs, describe, events
- ✅ Keycloak rollout failures → collect logs, describe, events
- ✅ cert-manager rollout failures → collect ALL pod logs (not just webhook)
- ✅ All diagnostics written to timestamped files in {{ backup_dir }}
- ✅ All diagnostic collection uses become: true

### Proactive Permission Handling:
- ✅ Backup directory created at line 290 (before first use)
- ✅ Directory created with mode: '0700', owner: root, group: root
- ✅ Prevents "Permission denied" errors on first deployment

### Safety & Idempotency:
- ✅ No timeout modifications (rollout_wait_timeout stays 120s)
- ✅ No destructive changes to existing logic
- ✅ Backward compatible with existing workflows
- ✅ All file operations use secure modes (0600 for files, 0700 for dirs)

## 🧪 Testing Commands

```bash
# Test the playbook with the changes
cd /opt/vmstation-org/cluster-infra
sudo ansible-playbook \
  -i /opt/vmstation-org/cluster-setup/ansible/inventory/hosts.yml \
  ansible/playbooks/identity-deploy-and-handover.yml \
  --become

# Verify backup directory permissions
sudo ls -la /root/identity-backup/

# Test with force replace (optional, for recovery testing)
sudo ansible-playbook \
  -i /opt/vmstation-org/cluster-setup/ansible/inventory/hosts.yml \
  ansible/playbooks/identity-deploy-and-handover.yml \
  --become \
  -e identity_force_replace=true
```

## 📊 Statistics

- **Files Modified:** 1 (identity-deploy-and-handover.yml)
- **Lines Changed:** 433
- **Tasks Modified:** 40+
- **New Tasks Added:** 1 (proactive backup dir creation)
- **Timeout Changes:** 0 (none)
- **Breaking Changes:** 0 (fully backward compatible)

## 🔍 Review Checklist

- [x] All kubectl commands use become: true
- [x] All helm commands use become: true
- [x] All file/copy operations to protected dirs use become: true
- [x] Enhanced diagnostics capture pod logs on failures
- [x] Backup directory created upfront with correct permissions
- [x] No timeout increases
- [x] Backward compatible
- [x] Minimal, surgical changes only
- [x] Idempotent and non-destructive

## 📚 Related Files

- **Playbook:** `/opt/vmstation-org/cluster-infra/ansible/playbooks/identity-deploy-and-handover.yml`
- **Patch:** `/opt/vmstation-org/diff-patches/20251210-identity-deploy-privilege-fix.patch`
- **Git Script:** `/opt/vmstation-org/diff-patches/20251210-identity-deploy-privilege-fix-GIT_COMMANDS.sh`

## 🎯 Expected Outcome

After applying this patch:
1. ✅ Playbook runs successfully from non-privileged user with `--become`
2. ✅ No "Permission denied" errors on kubectl/helm commands
3. ✅ No "Permission denied" errors when writing to /root/identity-backup
4. ✅ Comprehensive diagnostics saved on any rollout failures
5. ✅ All backup files created with secure permissions (root:root, 0600/0700)

## 🐛 Issues Fixed

- Fixed: kubectl commands fail with permission denied
- Fixed: helm commands fail with permission denied
- Fixed: Cannot write to /root/identity-backup (directory doesn't exist or wrong perms)
- Fixed: Incomplete diagnostics on rollout failures (missing pod logs)
- Fixed: Backup directory creation race condition

---

**Generated:** 2025-12-10  
**Author:** GitHub Copilot CLI  
**Target Branch:** fix/identity-deploy-privilege-escalation  
**Base Branch:** main
