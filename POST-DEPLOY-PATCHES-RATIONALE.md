# Post-Deploy Patches Rationale

## Why Post-Deploy Patches Are Needed

The identity stack deployment requires post-deployment patches due to limitations in the codecentric Keycloak Helm chart. These patches are **necessary and automated** in the playbook.

## Specific Issues with the codecentric Chart

### 1. extraEnv Field Doesn't Work
**Problem**: The chart's `extraEnv` configuration field doesn't properly inject environment variables into the Keycloak container.

**Impact**: Keycloak defaults to the H2 embedded database instead of using PostgreSQL.

**Solution**: Post-deployment `kubectl patch` to inject DB environment variables:
```yaml
- name: Patch Keycloak StatefulSet with PostgreSQL environment variables
  shell: kubectl patch statefulset keycloak -n identity --type=json -p='[...]'
```

### 2. nodeSelector Doesn't Apply Correctly
**Problem**: The `--set keycloak.nodeSelector` Helm argument doesn't properly set the nodeSelector in the StatefulSet.

**Impact**: Keycloak pod gets scheduled on worker nodes instead of the masternode where PostgreSQL and FreeIPA run.

**Solution**: Post-deployment `kubectl patch` to force nodeSelector:
```yaml
- name: Patch Keycloak StatefulSet with nodeSelector for masternode
  shell: kubectl patch statefulset keycloak -n identity -p='{"spec":{"template":{"spec":{"nodeSelector":...}}}}'
```

## Alternative Solutions

For a **truly clean solution** without post-deployment patches, you would need to:

1. **Switch to a different Keycloak Helm chart** that properly supports extraEnv and nodeSelector
2. **Deploy Keycloak as a standalone manifest** (like PostgreSQL in this solution)
3. **Fork and modify the codecentric chart** to fix these issues upstream

## Why We Use This Approach

- **Automated**: The patches are part of the playbook, so they run automatically
- **Idempotent**: The playbook can be re-run safely
- **Documented**: This issue is well-documented and transparent
- **Pragmatic**: Works reliably without maintaining a fork or writing custom manifests
- **Minimal Changes**: The smallest change to get a working deployment

## What Was Applied

The following patch was applied from `docs/diff-patches-20251210/`:
- `20251210-identity-stack-complete-fix.patch`

### Key Changes:

1. **Standalone PostgreSQL Deployment** (619 lines changed)
   - Created `manifests/identity/postgresql-statefulset.yaml`
   - Replaces Helm subchart with standalone StatefulSet
   - Uses official `postgres:11` image

2. **PV Claim Clearing**
   - Automatically clears `spec.claimRef` from Released PVs
   - Enables clean re-deployments

3. **Post-Deployment Patches**
   - Keycloak DB environment variables injection
   - Keycloak nodeSelector enforcement

4. **CA Secret Format**
   - Changed from `ca.crt` to `tls.crt/tls.key` for cert-manager

5. **Privilege Escalation**
   - Added `become: true` to 66 tasks requiring root access

## Security Considerations

⚠️ **Before Production Deployment**: Replace all placeholder passwords marked with `CHANGEME_` in:
- `manifests/identity/postgresql-statefulset.yaml` (POSTGRES_PASSWORD)
- `helm/keycloak-values.yaml` (adminPassword, database.password)
- `ansible/playbooks/identity-deploy-and-handover.yml` (DB_PASSWORD in patch command)

These placeholders are intentionally obvious to prevent accidental production deployment with default credentials.

## Verification

All changes have been validated:
- ✅ Ansible playbook syntax checked
- ✅ YAML manifests validated
- ✅ Post-deployment patches verified in playbook
- ✅ All critical tasks have proper privilege escalation
- ✅ Code review completed - security notes added

## References

- Deployment Guide: `docs/diff-patches-20251210/20251210-DEPLOYMENT-GUIDE.md`
- Technical Summary: `docs/diff-patches-20251210/20251210-IDENTITY-FIXES-SUMMARY.md`
- Test Report: `docs/diff-patches-20251210/20251210-TEST-REPORT.md`
