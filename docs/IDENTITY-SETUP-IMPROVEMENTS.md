# Identity Setup Improvements

## Overview

This document describes the improvements made to the identity setup playbook and manifests to simplify and streamline the deployment process, ensuring it cannot fail due to scheduling issues or complex patching logic.

## Key Changes

### 1. Control-Plane Scheduling

**Problem:** Identity components (Keycloak, PostgreSQL, FreeIPA, cert-manager) were scheduled using hostname-based nodeSelectors that required post-deployment patching. This approach was fragile and could fail silently if the patches didn't apply correctly.

**Solution:** 
- Added `nodeSelector` with `node-role.kubernetes.io/control-plane: ""` directly to all identity component manifests
- Added tolerations for `node-role.kubernetes.io/control-plane` taint to ensure pods can be scheduled on control-plane nodes
- Removed post-deployment patching logic that was redundant and could fail silently

**Benefits:**
- Identity pods now **always** schedule on the control-plane (masternode) which is always on
- No dependency on dynamic node detection or post-deployment patching
- Simplified playbook logic with fewer failure points
- Consistent scheduling behavior across all identity components

### 2. Simplified Deployment Flow

**Before:**
1. Deploy resources with basic manifests
2. Detect infra node dynamically
3. Patch resources with nodeSelector based on detected node
4. Hope patches succeed (failed_when: false meant silent failures)

**After:**
1. Deploy resources with complete manifests (nodeSelector + tolerations pre-configured)
2. Resources automatically schedule on control-plane nodes
3. No patching required - resources are correct on first deployment

### 3. Test Account Initialization

**Problem:** No easy way to test Keycloak and FreeIPA functionality after deployment.

**Solution:**
- Added automatic test user creation for Keycloak
  - Username: `testuser` (configurable via `keycloak_test_username`)
  - Auto-generated secure password (or set via `keycloak_test_user_password`)
  - Credentials saved to `/root/identity-backup/keycloak-test-user-credentials.txt`

- Added automatic test user creation for FreeIPA
  - Username: `testuser` (configurable via `freeipa_test_username`)
  - Auto-generated secure password (or set via `freeipa_test_user_password`)
  - Credentials saved to `/root/identity-backup/freeipa-test-user-credentials.txt`

**Benefits:**
- Immediate testing capability after deployment
- Secure password generation by default
- Easy credential access from backup directory
- No manual setup required for basic functionality testing

### 4. Enhanced Verification

**Added Tests:**
- Test 14: Check for test user credentials files
- Test 15: Verify all identity pods are scheduled on control-plane node

**Benefits:**
- Better validation of deployment success
- Early detection of scheduling issues
- Verification that test accounts were created successfully

## Files Modified

### Manifests
1. `manifests/identity/postgresql-statefulset.yaml`
   - Added `nodeSelector: node-role.kubernetes.io/control-plane: ""`
   - Added tolerations for control-plane taint

2. `manifests/identity/freeipa.yaml`
   - Added `nodeSelector: node-role.kubernetes.io/control-plane: ""`
   - Added tolerations for control-plane taint

### Helm Values
3. `helm/keycloak-values.yaml`
   - Added `keycloak.nodeSelector` for control-plane
   - Added `keycloak.tolerations` for control-plane taint

### Playbook
4. `ansible/playbooks/identity-deploy-and-handover.yml`
   - Removed redundant nodeSelector patching for Keycloak
   - Removed redundant nodeSelector patching for FreeIPA
   - Updated cert-manager Helm install with proper nodeSelector and tolerations via --set flags
   - Added Keycloak test user creation block
   - Added FreeIPA test user creation block
   - Updated deployment summary to show test account information
   - Updated final guidance with test credential locations

### Tests
5. `tests/verify-identity-deploy.sh`
   - Added test for test user credentials files
   - Added test for control-plane scheduling verification

## Usage

### Deploy Identity Stack
```bash
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml
```

### Deploy with Custom Test Usernames/Passwords
```bash
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml \
  -e keycloak_test_username=mytest \
  -e keycloak_test_user_password=MySecurePass123 \
  -e freeipa_test_username=mytest \
  -e freeipa_test_user_password=MySecurePass456
```

### Access Test Credentials
```bash
# Keycloak test user
cat /root/identity-backup/keycloak-test-user-credentials.txt

# FreeIPA test user
cat /root/identity-backup/freeipa-test-user-credentials.txt

# Keycloak admin
cat /root/identity-backup/keycloak-admin-credentials.txt
```

### Verify Deployment
```bash
./tests/verify-identity-deploy.sh
```

## Architecture Decisions

### Why Control-Plane Scheduling?

1. **Always On:** The control-plane node is always running, ensuring identity services are always available
2. **Stable:** Control-plane nodes are typically not drained or rescheduled
3. **Consistent:** All identity components are co-located for better performance and reliability
4. **Simplified:** No need to manage scheduling across multiple nodes

### Why Remove Post-Deployment Patching?

1. **Fragile:** Patches could fail silently (failed_when: false)
2. **Race Conditions:** Patching after deployment created timing issues
3. **Complexity:** Added unnecessary complexity to the playbook
4. **Maintainability:** Harder to understand and maintain
5. **Idempotency:** Re-running the playbook could re-patch incorrectly

### Why Automatic Test Accounts?

1. **Immediate Validation:** Test accounts allow immediate functionality testing
2. **Developer Experience:** New users can test the system right away
3. **Documentation:** Demonstrates how to create additional users
4. **Security:** Auto-generated passwords are more secure than manual defaults

## Security Considerations

1. **Test Account Passwords:** Auto-generated with 16 bytes of entropy (128 bits)
2. **Credential Storage:** Saved to `/root/identity-backup` with mode 0600 (root-only)
3. **No Logs:** Passwords are marked with `no_log: true` in playbook
4. **Production Warning:** Test accounts should be deleted or have passwords changed in production

## Troubleshooting

### Identity Pods Not Scheduling

**Check:** Are control-plane nodes schedulable?
```bash
kubectl get nodes -o wide
kubectl describe nodes <control-plane-node>
```

**Fix:** Ensure control-plane taint allows scheduling or pods have proper tolerations
```bash
# Check tolerations
kubectl get pod <pod-name> -n identity -o yaml | grep -A 5 tolerations
```

### Test User Creation Failed

**Check:** Is the service ready?
```bash
# Keycloak
kubectl get pods -n identity -l app.kubernetes.io/name=keycloak

# FreeIPA
kubectl get pods -n identity -l app=freeipa
```

**Fix:** Wait for services to be fully ready and re-run playbook
```bash
kubectl wait --for=condition=ready pod/keycloak-0 -n identity --timeout=300s
```

### Cannot Access Test Credentials

**Check:** Was backup directory created?
```bash
ls -la /root/identity-backup/
```

**Fix:** Re-run playbook to recreate test accounts and credentials
```bash
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml
```

## Future Improvements

1. **LDAP Federation:** Automate Keycloak-FreeIPA LDAP federation setup
2. **Multi-Node Support:** Add option to spread identity components across multiple control-plane nodes
3. **High Availability:** Add support for multi-replica identity deployments
4. **Backup Automation:** Add scheduled backup of identity data
5. **Monitoring:** Add Prometheus metrics and alerting for identity services

## References

- [Kubernetes Node Affinity](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/)
- [Kubernetes Taints and Tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/)
- [Keycloak Documentation](https://www.keycloak.org/documentation)
- [FreeIPA Documentation](https://www.freeipa.org/page/Documentation)
- [cert-manager Documentation](https://cert-manager.io/docs/)
