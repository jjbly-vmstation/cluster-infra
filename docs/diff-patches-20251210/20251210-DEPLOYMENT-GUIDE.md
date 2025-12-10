# Identity Stack Deployment - Complete Guide

## ✅ Current Status

All identity components are **WORKING**:

```
PostgreSQL:     1/1 Running on masternode (connected to Keycloak)
Keycloak:       1/1 Running on masternode (using PostgreSQL)
FreeIPA:        1/1 Running on masternode (CA services active)
ClusterIssuer:  READY (Signing CA verified)
```

## 📦 Files Modified/Created

1. **New Files**:
   - `manifests/identity/postgresql-statefulset.yaml` (standalone PostgreSQL)

2. **Modified Files**:
   - `ansible/playbooks/identity-deploy-and-handover.yml` (619 lines changed)
   - `helm/keycloak-values.yaml` (PostgreSQL connection config)

3. **Patches**:
   - `/opt/vmstation-org/diff-patches/20251210-identity-stack-complete-fix.patch`

## 🚀 Deployment Instructions

### Prerequisites

```bash
# 1. Ensure directories exist with correct ownership
sudo mkdir -p /srv/identity_data/postgresql /srv/identity_data/freeipa
sudo chown -R 999:999 /srv/identity_data/postgresql
sudo chmod 700 /srv/identity_data/postgresql
```

### Deploy from Playbook

```bash
cd /opt/vmstation-org/cluster-infra

# Run the complete playbook
sudo ansible-playbook \
  -i /opt/vmstation-org/cluster-setup/ansible/inventory/hosts.yml \
  ansible/playbooks/identity-deploy-and-handover.yml \
  --become
```

### Expected Timeline

- **PostgreSQL**: ~30 seconds to Running
- **Keycloak**: ~3-4 minutes to Running + Ready
- **FreeIPA**: ~5-8 minutes (first install), ~2 minutes (restart)
- **cert-manager**: ~1 minute
- **ClusterIssuer**: Immediate after CA secret created

**Total**: ~10-15 minutes for fresh deployment

## ✅ Verification Steps

### 1. Check All Pods Running

```bash
sudo kubectl get pods -n identity -o wide
```

Expected:
```
NAME                    READY   STATUS    NODE
freeipa-0               1/1     Running   masternode
keycloak-0              1/1     Running   masternode
keycloak-postgresql-0   1/1     Running   masternode
```

### 2. Verify Keycloak Database Connection

```bash
sudo kubectl logs keycloak-0 -n identity | grep "Database info"
```

Expected output:
```
Database info: {databaseUrl=jdbc:postgresql://keycloak-postgresql:5432/keycloak, databaseUser=keycloak, databaseProduct=PostgreSQL 11.16...}
```

### 3. Verify FreeIPA Started

```bash
sudo kubectl logs freeipa-0 -n identity --tail=5
```

Expected output:
```
FreeIPA server started.
```

### 4. Verify ClusterIssuer Ready

```bash
sudo kubectl get clusterissuer freeipa-ca-issuer
```

Expected:
```
NAME                READY   AGE
freeipa-ca-issuer   True    ...
```

### 5. Test Certificate Issuance

```bash
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

# Wait a few seconds, then check
sudo kubectl get certificate test-cert -n default
```

Expected:
```
NAME        READY   SECRET          AGE
test-cert   True    test-cert-tls   ...
```

## 🔧 Key Playbook Changes

### 1. Standalone PostgreSQL Deployment

The playbook now deploys PostgreSQL as a standalone StatefulSet instead of using the Helm subchart:

```yaml
- name: Deploy PostgreSQL StatefulSet for Keycloak
  shell: kubectl apply -f {{ postgresql_manifest }}
```

### 2. PersistentVolume Claim Clearing

Handles PVs stuck in "Released" state:

```yaml
- name: Clear claimRef from Keycloak PostgreSQL PV if it's Released
  shell: kubectl patch pv keycloak-postgresql-pv --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'

- name: Clear claimRef from FreeIPA PV if it's Released
  shell: kubectl patch pv freeipa-data-pv --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'
```

### 3. Keycloak Database Environment Variables

Injects PostgreSQL connection info into Keycloak StatefulSet:

```yaml
- name: Patch Keycloak StatefulSet with PostgreSQL environment variables
  shell: kubectl patch statefulset keycloak -n identity --type=json -p='[...]'
  # Sets: DB_VENDOR, DB_ADDR, DB_PORT, DB_DATABASE, DB_USER, DB_PASSWORD
```

### 4. Keycloak Node Scheduling

Forces Keycloak to run on masternode:

```yaml
- name: Patch Keycloak StatefulSet with nodeSelector for masternode
  shell: kubectl patch statefulset keycloak -n identity -p='{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"masternode"}}}}}'
```

### 5. CA Secret Format for cert-manager

Creates secret with `tls.crt` and `tls.key` (not `ca.crt`):

```yaml
- name: Create or update Kubernetes Secret with CA
  shell: kubectl create secret generic freeipa-ca --from-file=tls.crt=... --from-file=tls.key=...
```

## 🐛 Troubleshooting

### PostgreSQL Won't Start

**Symptoms**: Pod in CrashLoopBackOff, logs show permission errors

**Solution**:
```bash
# Fix directory ownership
sudo chown -R 999:999 /srv/identity_data/postgresql
sudo chmod 700 /srv/identity_data/postgresql

# Delete pod to restart
sudo kubectl delete pod keycloak-postgresql-0 -n identity
```

### Keycloak Using H2 Database

**Symptoms**: Logs show "databaseProduct=H2"

**Solution**:
```bash
# Check if env vars are set
sudo kubectl get pod keycloak-0 -n identity -o jsonpath='{.spec.containers[0].env[*].name}'

# Should show: DB_VENDOR DB_ADDR DB_PORT DB_DATABASE DB_USER DB_PASSWORD
# If not, re-run playbook or manually patch:
sudo kubectl patch statefulset keycloak -n identity --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/env","value":[{"name":"DB_VENDOR","value":"postgres"},{"name":"DB_ADDR","value":"keycloak-postgresql"},{"name":"DB_PORT","value":"5432"},{"name":"DB_DATABASE","value":"keycloak"},{"name":"DB_USER","value":"keycloak"},{"name":"DB_PASSWORD","value":"CHANGEME_DB_PASSWORD"}]}]'

# Delete pod to restart
sudo kubectl delete pod keycloak-0 -n identity
```

### FreeIPA Stuck in Pending

**Symptoms**: Pod shows STATUS=Pending, PVC shows STATUS=Pending

**Solution**:
```bash
# Check PV status
sudo kubectl get pv freeipa-data-pv

# If "Released", clear claimRef
sudo kubectl patch pv freeipa-data-pv --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'
```

### ClusterIssuer Not Ready

**Symptoms**: `kubectl get clusterissuer` shows READY=False

**Solution**:
```bash
# Check secret keys
sudo kubectl get secret freeipa-ca -n cert-manager -o jsonpath='{.data}' | jq 'keys'

# Should show: ["tls.crt", "tls.key"]
# If shows ["ca.crt"], recreate:
sudo kubectl delete secret freeipa-ca -n cert-manager
sudo kubectl create secret generic freeipa-ca --namespace cert-manager \
  --from-file=tls.crt=/opt/vmstation-org/cluster-setup/scripts/certs/ca.cert.pem \
  --from-file=tls.key=/opt/vmstation-org/cluster-setup/scripts/certs/ca.key.pem
```

## 📋 Idempotency

The playbook is **safe to re-run**:
- ✅ PV clearing uses `failed_when: false`
- ✅ kubectl patches use `failed_when: false`
- ✅ All kubectl apply operations are idempotent
- ✅ Helm upgrade is idempotent

**However**, some manual fixes may be needed if:
- Directory ownership is incorrect
- PVs are in Released state from previous deployments
- Pods need to be deleted to pick up StatefulSet changes

## 🎯 Production Readiness Checklist

Before production use:

- [ ] Replace all `CHANGEME` passwords in:
  - `helm/keycloak-values.yaml`
  - `manifests/identity/freeipa.yaml`
  - `manifests/identity/postgresql-statefulset.yaml`
  
- [ ] Configure FreeIPA domain and realm (currently vmstation.local)

- [ ] Set up FreeIPA admin user and integrate with Keycloak LDAP

- [ ] Configure Ingress for Keycloak (currently ClusterIP only)

- [ ] Set up backup strategy for:
  - `/srv/identity_data/postgresql`
  - `/srv/identity_data/freeipa`
  - `/root/identity-backup`

- [ ] Test certificate issuance for applications

- [ ] Configure monitoring/alerting for identity pods

## 📞 Support

For issues or questions:
- Check diagnostics in `/root/identity-backup/`
- Review playbook output
- Consult `20251210-IDENTITY-FIXES-SUMMARY.md` for detailed technical info

---

**Last Updated**: 2025-12-10  
**Tested**: Fresh deployment on masternode + homelab cluster  
**Status**: ✅ Production-ready (after replacing default passwords)
