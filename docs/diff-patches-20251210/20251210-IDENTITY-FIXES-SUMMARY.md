# Identity Stack Deployment Fixes - Complete Summary

**Date**: 2025-12-10  
**Status**: ✅ WORKING - PostgreSQL, Keycloak, FreeIPA, ClusterIssuer all functional

## Problems Fixed

### 1. PostgreSQL Deployment
**Problem**: codecentric Keycloak Helm chart's PostgreSQL subchart uses Bitnami-specific paths and images that were not pulling correctly.

**Solution**: 
- Created standalone PostgreSQL StatefulSet manifest (`manifests/identity/postgresql-statefulset.yaml`)
- Uses official `postgres:11` image with standard paths
- Playbook deploys this before Keycloak with `postgresql.enabled=false`

### 2. PersistentVolume Binding Issues
**Problem**: PVs in "Released" state from previous deployments couldn't bind to new PVCs.

**Solution**: 
- Added tasks to clear `spec.claimRef` from PVs after applying manifests
- Applied to both keycloak-postgresql-pv and freeipa-data-pv

### 3. Keycloak Database Connection
**Problem**: Helm chart's `extraEnv` field doesn't work; Keycloak defaulted to H2 embedded database.

**Solution**: 
- Added post-deployment kubectl patch to inject DB environment variables into StatefulSet
- Env vars: DB_VENDOR, DB_ADDR, DB_PORT, DB_DATABASE, DB_USER, DB_PASSWORD

### 4. Keycloak Node Scheduling
**Problem**: Helm chart's `--set keycloak.nodeSelector` doesn't apply correctly; pod scheduled on homelab node.

**Solution**: 
- Added post-deployment kubectl patch to set nodeSelector to masternode
- Ensures Keycloak runs on control-plane with PostgreSQL and FreeIPA

### 5. FreeIPA PersistentVolume Binding
**Problem**: Same as PostgreSQL - PV stuck in Released state.

**Solution**: 
- Added claimRef clearing task after FreeIPA manifest apply
- FreeIPA now starts successfully and completes initialization

### 6. ClusterIssuer CA Secret Format
**Problem**: Secret created with `ca.crt` key, but cert-manager requires `tls.crt` and `tls.key`.

**Solution**: 
- Updated secret creation to use `--from-file=tls.crt` and `--from-file=tls.key`
- ClusterIssuer now verifies CA successfully

## Playbook Changes

### New Files Created:
1. `/opt/vmstation-org/cluster-infra/manifests/identity/postgresql-statefulset.yaml`
   - Standalone PostgreSQL deployment
   - Service, Secret, StatefulSet with volumeClaimTemplates

### Playbook Tasks Added/Modified:

```yaml
# 1. PV claimRef clearing for PostgreSQL (after line 173)
- name: Clear claimRef from Keycloak PostgreSQL PV if it's Released
  shell: kubectl patch pv keycloak-postgresql-pv --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'

# 2. FreeIPA PV claimRef clearing (after FreeIPA apply)
- name: Clear claimRef from FreeIPA PV if it's Released
  shell: kubectl patch pv freeipa-data-pv --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'

# 3. PostgreSQL StatefulSet deployment (before Keycloak)
- name: Deploy PostgreSQL StatefulSet for Keycloak
  shell: kubectl apply -f {{ postgresql_manifest }}

# 4. Keycloak Helm with PostgreSQL disabled
- name: Install/upgrade Keycloak via Helm (PostgreSQL disabled)
  shell: helm upgrade --install keycloak codecentric/keycloak --set postgresql.enabled=false ...

# 5. Keycloak DB env vars patch (after Helm install)
- name: Patch Keycloak StatefulSet with PostgreSQL environment variables
  shell: kubectl patch statefulset keycloak -n identity --type=json -p='[...]'

# 6. Keycloak nodeSelector patch (after env vars)
- name: Patch Keycloak StatefulSet with nodeSelector for masternode
  shell: kubectl patch statefulset keycloak -n identity -p='{"spec":{"template":{"spec":{"nodeSelector":...}}}}'

# 7. CA secret with tls.crt/tls.key (modified existing task)
- name: Create or update Kubernetes Secret with CA (tls.crt and tls.key format)
  shell: kubectl create secret generic freeipa-ca --from-file=tls.crt=... --from-file=tls.key=...
```

### Variables Added:
```yaml
postgresql_manifest: "{{ repo_root }}/manifests/identity/postgresql-statefulset.yaml"
```

## Current Deployment State

```
=== IDENTITY PODS ===
NAME                    READY   STATUS    NODE
freeipa-0               1/1     Running   masternode
keycloak-0              1/1     Running   masternode
keycloak-postgresql-0   1/1     Running   masternode

=== CLUSTERISSUER ===
NAME                READY
freeipa-ca-issuer   True
```

## Verification Commands

```bash
# Check all identity pods
sudo kubectl get pods -n identity -o wide

# Verify Keycloak PostgreSQL connection
sudo kubectl logs keycloak-0 -n identity | grep "Database info"
# Should show: PostgreSQL 11.16

# Verify FreeIPA is running
sudo kubectl logs freeipa-0 -n identity --tail=5
# Should show: "FreeIPA server started."

# Verify ClusterIssuer
sudo kubectl get clusterissuer freeipa-ca-issuer
# Should show: READY = True

# Test certificate issuance
cat <<YAML | sudo kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-cert
  namespace: default
spec:
  secretName: test-cert-tls
  issuerRef:
    name: freeipa-ca-issuer
    kind: ClusterIssuer
  commonName: test.example.com
  dnsNames:
  - test.example.com
YAML

# Check certificate status
sudo kubectl get certificate test-cert -n default
sudo kubectl describe certificate test-cert -n default
```

## Remaining Minor Issues

1. **cert-manager components** (cainjector, webhook) are running on homelab node
   - Not critical but should be on masternode
   - Would need similar nodeSelector patches

2. **PostgreSQL directory ownership**
   - Currently must be manually set to 999:999 before deployment
   - The chown Job in playbook runs but doesn't fix the issue completely

## Idempotency Status

✅ **Safe to re-run**: The playbook can now be re-run multiple times
- PV clearing tasks use `failed_when: false`
- kubectl patch uses `failed_when: false`
- All apply operations are idempotent

⚠️ **Fresh cluster deployment**: Requires one-time manual steps:
1. Create `/srv/identity_data/postgresql` and `/srv/identity_data/freeipa` directories
2. Set ownership: `chown 999:999 /srv/identity_data/postgresql`

## Next Steps

1. Add nodeSelector patches for cert-manager components
2. Improve PostgreSQL directory ownership handling
3. Move all manual patches to proper Helm values or manifest generation
4. Test complete fresh cluster deployment
5. Document recovery procedures

---

**Tested On**: 2025-12-10  
**Cluster**: masternode + homelab nodes  
**Kubernetes Version**: (check with `kubectl version`)
