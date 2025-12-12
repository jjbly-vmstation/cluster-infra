# Pull Request Summary

## Title
Refactor identity deployment playbook and fix control-plane taint issue

## Description

This PR completely refactors the identity deployment playbook from a monolithic 1373-line file into a modular architecture with 7 specialized Ansible roles. It also ensures all components properly tolerate the Kubernetes control-plane taint to allow scheduling on the masternode.

## Problem Statement

The original issue had two main problems:

1. **Control-Plane Taint Issue**: Pods could not be scheduled onto the masternode due to the `node-role.kubernetes.io/control-plane:NoSchedule` taint, even though the PersistentVolumes (PVs) with hostPath storage were located on that node.

2. **Monolithic Playbook**: The identity deployment playbook was 1373 lines long with all tasks in a single file, making it difficult to maintain, test, and reuse individual components.

## Solution

### 1. Control-Plane Taint Resolution

Verified that all StatefulSets and Jobs include the proper toleration:

```yaml
tolerations:
- key: node-role.kubernetes.io/control-plane
  operator: Exists
  effect: NoSchedule
```

This allows pods to "tolerate" the control-plane taint and schedule on the masternode where the hostPath storage is located. The tolerations are present in:
- PostgreSQL StatefulSet
- FreeIPA StatefulSet  
- Keycloak deployment (via Helm values)
- cert-manager components (via Helm parameters)
- All chown jobs (via templates)

### 2. Playbook Refactoring

Refactored the monolithic playbook into 7 modular roles:

1. **identity-prerequisites** - Binary checks, node detection, namespaces
2. **identity-storage** - Storage classes, PVs, hostPath ownership
3. **identity-postgresql** - PostgreSQL StatefulSet management
4. **identity-keycloak** - Keycloak Helm deployment
5. **identity-freeipa** - FreeIPA StatefulSet management
6. **identity-certmanager** - cert-manager installation and CA setup
7. **identity-backup** - Backup operations

Main playbook reduced from 1373 lines to 98 lines (93% reduction).

## Changes

### Files Created
- `ansible/roles/identity-prerequisites/` - New role
- `ansible/roles/identity-storage/` - New role with templates
- `ansible/roles/identity-postgresql/` - New role
- `ansible/roles/identity-keycloak/` - New role
- `ansible/roles/identity-freeipa/` - New role
- `ansible/roles/identity-certmanager/` - New role with templates
- `ansible/roles/identity-backup/` - New role
- `ansible/roles/README.md` - Role documentation
- `docs/CONTROL_PLANE_TAINT_FIX.md` - Taint resolution guide
- `docs/IDENTITY_REFACTORING.md` - Refactoring documentation
- `scripts/verify-identity-deployment.sh` - Deployment verification script

### Files Modified
- `ansible/playbooks/identity-deploy-and-handover.yml` - Replaced with refactored version
- `README.md` - Added identity deployment section

### Files Preserved
- `ansible/playbooks/identity-deploy-and-handover-old.yml` - Backup of original playbook

## Benefits

1. **Modularity**: Each component is now a separate role that can be tested and reused independently
2. **Maintainability**: Changes are localized to specific roles, making the codebase easier to maintain
3. **Testability**: Individual roles can be tested in isolation
4. **Flexibility**: Tag-based execution allows selective deployment of components
5. **Documentation**: Comprehensive documentation for roles and taint resolution
6. **Simplicity**: Main playbook is 93% smaller and much easier to understand

## Testing

- ✅ Ansible syntax check passed
- ✅ Code review completed and feedback addressed
- ✅ Security scan completed (no issues found)
- ✅ Verification script created for post-deployment testing
- ⏳ Full deployment test pending (requires live cluster)

## Usage

### Standard deployment:
```bash
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml
```

### Selective deployment:
```bash
# Only PostgreSQL and Keycloak
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml --tags postgresql,keycloak
```

### Verification:
```bash
./scripts/verify-identity-deployment.sh
```

## Migration

The refactored playbook is backward compatible with the original. No changes to usage are required. The original playbook is preserved as `identity-deploy-and-handover-old.yml` for reference.

## Documentation

- [Identity Refactoring Guide](docs/IDENTITY_REFACTORING.md) - Complete refactoring documentation
- [Control-Plane Taint Fix](docs/CONTROL_PLANE_TAINT_FIX.md) - Taint resolution details
- [Roles README](ansible/roles/README.md) - Comprehensive role documentation

## Security Considerations

- No vulnerabilities introduced (verified by CodeQL)
- Improved error handling for PV operations
- Robust node selection logic
- Conditional rendering in templates to prevent misconfigurations

## Breaking Changes

None. The playbook usage remains the same.

## Rollback Plan

If issues arise, the original playbook can be restored:
```bash
cd ansible/playbooks
mv identity-deploy-and-handover.yml identity-deploy-and-handover-new.yml
mv identity-deploy-and-handover-old.yml identity-deploy-and-handover.yml
```

## Next Steps

After merging:
1. Test full deployment in a development environment
2. Update CI/CD pipelines if needed
3. Consider adding Molecule tests for roles
4. Extract user management into a separate role (future enhancement)

## Reviewers

Please review:
- Role structure and organization
- Variable handling and defaults
- Template rendering logic
- Documentation completeness
- Error handling in tasks

## Related Issues

Closes: [Issue regarding identity deployment and control-plane taint]
