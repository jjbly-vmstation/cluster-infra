# Identity Deploy Playbook Privilege Fix - Rationale

## Summary of Changes

This patch ensures the `identity-deploy-and-handover.yml` playbook runs successfully from a non-privileged user by adding `become: true` to all tasks requiring elevated privileges (kubectl, helm, file operations on /root and {{ backup_dir }}), enhancing diagnostics with pod logs on rollout failures, and creating the backup directory upfront to prevent permission issues.

## Detailed Changes

### 1. **Privilege Escalation (become: true)**
   - Added `become: true` to all kubectl commands (accessing /etc/kubernetes/admin.conf requires root)
   - Added `become: true` to all helm commands
   - Added `become: true` to all tasks reading/writing to {{ backup_dir }} (/root/identity-backup)
   - Added `become: true` to all copy/file tasks modifying protected directories
   - Total: 40+ tasks now properly escalate privileges

### 2. **Enhanced Diagnostics on Rollout Failures**
   - PostgreSQL rollout failure: Added `kubectl logs --all-containers --tail=100` collection
   - Keycloak rollout failure: Added `kubectl logs --all-containers --tail=100` collection
   - cert-manager rollout failure: Changed from webhook-only logs to ALL pod logs
   - All diagnostic tasks use `become: true` to ensure kubectl access
   - Diagnostics saved with timestamped filenames in {{ backup_dir }}

### 3. **Proactive Directory Creation**
   - Moved backup directory creation to line 290 (before any usage)
   - Ensures /root/identity-backup exists with correct permissions (0700, root:root) before any task attempts to write
   - Prevents "Permission denied" errors during first-time deployments

### 4. **Idempotency & Safety**
   - No timeouts modified (rollout_wait_timeout remains 120s)
   - All file/copy operations maintain secure modes (0600 for files, 0700 for dirs)
   - All file/copy operations set owner: root for consistency
   - Changes are minimal and non-destructive to existing logic

## Testing Recommendations

1. Run as non-privileged user with `--become` flag (as documented)
2. Test normal deployment flow
3. Test failure scenarios (rollback/recovery) to verify diagnostic collection
4. Verify backup directory permissions after playbook run
5. Check all diagnostic logs are created with correct ownership

## Files Modified

- `ansible/playbooks/identity-deploy-and-handover.yml` (433 lines changed)

## Breaking Changes

None. This is backward-compatible and fixes existing privilege escalation issues.
