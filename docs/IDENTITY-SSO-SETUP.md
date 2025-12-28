# Identity Stack and SSO Setup Guide

## Overview

This guide covers the deployment and configuration of the complete identity management stack for the VMStation cluster, including FreeIPA, Keycloak, and cert-manager for cluster-wide Single Sign-On (SSO).

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     VMStation Cluster                        │
│                                                               │
│  ┌──────────────┐      ┌──────────────┐                     │
│  │   FreeIPA    │─────▶│   Keycloak   │                     │
│  │   (LDAP/CA)  │      │   (SSO/OIDC) │                     │
│  └──────────────┘      └───────┬──────┘                     │
│         │                      │                             │
│         │                      ▼                             │
│         │              ┌──────────────┐                      │
│         │              │  OIDC Clients│                      │
│         │              │  - Grafana   │                      │
│         │              │  - Prometheus│                      │
│         │              │  - Loki      │                      │
│         │              └──────────────┘                      │
│         │                                                     │
│         ▼                                                     │
│  ┌──────────────┐                                            │
│  │ cert-manager │                                            │
│  │ (ClusterIssuer)                                           │
│  └──────────────┘                                            │
│                                                               │
│  All Nodes: LDAP Client + SSSD                               │
│  - masternode (192.168.4.63)                                 │
│  - storagenodet3500 (192.168.4.61)                           │
│  - homelab (192.168.4.62)                                    │
└─────────────────────────────────────────────────────────────┘
```

## Components

### 1. FreeIPA
- **Purpose**: LDAP directory, Kerberos KDC, and Certificate Authority
- **Location**: Kubernetes StatefulSet in `identity` namespace on masternode
- **Access**: https://ipa.vmstation.local
- **Features**:
  - User and group management
  - PKI/CA services for TLS certificates
  - LDAP directory for authentication
  - Kerberos for secure authentication

### 2. Keycloak
- **Purpose**: Identity and Access Management, SSO provider
- **Location**: Kubernetes StatefulSet in `identity` namespace on masternode
- **Access**: http://192.168.4.63:30180/auth
- **Features**:
  - OIDC/SAML SSO
  - LDAP user federation (integrates with FreeIPA)
  - Client management for applications
  - Token-based authentication

### 3. cert-manager
- **Purpose**: Automated TLS certificate management
- **Location**: `cert-manager` namespace
- **Features**:
  - ClusterIssuer using FreeIPA CA
  - Automatic certificate issuance and renewal
  - Integration with Kubernetes Ingress

### 4. PostgreSQL
- **Purpose**: Database backend for Keycloak
- **Location**: Kubernetes StatefulSet in `identity` namespace on masternode
- **Storage**: Persistent volume at `/srv/monitoring-data/postgresql`

## Deployment Steps

### Prerequisites

1. **Kubernetes Cluster**: Running cluster with accessible control plane
2. **Kubectl Access**: Configured `/etc/kubernetes/admin.conf`
3. **Ansible**: Version 2.9+ installed on deployment machine
4. **Storage**: Available at `/srv/monitoring-data/` on masternode
5. **Network**: Connectivity between all nodes on 192.168.4.0/24

### Step 1: Deploy Identity Stack

Run the main deployment playbook:

```bash
cd /path/to/cluster-infra
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml
```

This will deploy:
- PostgreSQL for Keycloak
- Keycloak SSO server
- FreeIPA LDAP server (optional)
- cert-manager with CA ClusterIssuer
- TLS certificates for services
- Administrator account credentials

### Step 2: Verify Deployment

```bash
# Run verification script
./scripts/verify-identity-deployment.sh

# Check all pods are running
kubectl get pods -n identity
kubectl get pods -n cert-manager

# Check services
kubectl get svc -n identity
```

Expected output:
- PostgreSQL pod: Running
- Keycloak pod: Running
- FreeIPA pod: Running (if enabled)
- cert-manager pods: 3 Running

### Step 3: Access Keycloak Admin Console

1. Get node IP:
   ```bash
   kubectl get nodes -o wide
   ```

2. Access Keycloak:
   - URL: `http://192.168.4.63:30180/auth/admin/`
   - Credentials: `/root/identity-backup/cluster-admin-credentials.txt`

### Step 4: Import SSO Realm

This step is **automated** by the deployment playbook (role `identity-sso`) when `keycloak_configure_sso: true`.

Verify in the Keycloak admin console:
1. Open the realm dropdown (top-left)
2. Confirm the `cluster-services` realm exists
3. Confirm clients exist: `grafana`, `prometheus`, `loki`

If you want to disable this automation, run the playbook with:
```bash
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml -e keycloak_configure_sso=false
```

### Step 5: Configure LDAP User Federation

This step is **automated** by the deployment playbook (role `identity-sso`) when `keycloak_configure_sso: true`.

Verify in the Keycloak admin console:
1. Switch to realm `cluster-services`
2. Go to **User Federation**
3. Confirm an LDAP provider named `freeipa` exists
4. (Optional) Use **Test connection** / **Test authentication**, then **Synchronize all users**

### Step 6: Configure FreeIPA LDAP Clients (Optional)

To enable LDAP authentication on all cluster nodes:

1. Uncomment the LDAP client play in `identity-deploy-and-handover.yml`
2. Set FreeIPA admin password:
   ```bash
   export FREEIPA_ADMIN_PASSWORD="your-password"
   ```
3. Run playbook with LDAP client tag:
   ```bash
   ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml --tags freeipa-client
   ```

This will:
- Install FreeIPA client packages on all nodes
- Join nodes to FreeIPA domain
- Configure SSSD for LDAP authentication
- Enable SSH login with LDAP credentials

### Step 7: Create Users in FreeIPA

```bash
# Access FreeIPA pod
kubectl exec -it -n identity freeipa-0 -- bash

# Create a user
ipa user-add john --first=John --last=Doe --password

# Add user to admin group (optional)
ipa group-add-member admins --users=john
```

### Step 8: Configure OIDC Clients for Applications


This step is **automated** by the deployment playbook (role `identity-sso`) by default.

It creates/updates these Kubernetes secrets in the `monitoring` namespace:
- `grafana-oidc-secret`
- `prometheus-oidc-secret`
- `loki-oidc-secret`

Each secret contains:
- `client-id`
- `client-secret`

To disable secret export:
```bash
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml -e keycloak_export_oidc_client_secrets=false
```

### Step 9: Test SSO

1. Access Grafana (when deployed): `http://192.168.4.63:30300`
2. Click **Sign in with SSO**
3. Login with FreeIPA user credentials
4. Verify successful authentication

## Verification

### Verify LDAP Integration

```bash
./scripts/verify-ldap-integration.sh
```

Checks:
- FreeIPA server reachability
- LDAP connectivity
- FreeIPA client configuration
- SSSD service status
- User authentication

### Verify SSO Integration

```bash
./scripts/verify-sso-integration.sh
```

Checks:
- Keycloak deployment
- Realm configuration
- OIDC client secrets
- TLS certificates
- ClusterIssuer

## Troubleshooting

### Keycloak Not Starting

**Symptom**: Keycloak pod stuck in CrashLoopBackOff

**Solution**:
```bash
# Check logs
kubectl logs -n identity keycloak-0

# Check PostgreSQL connectivity
kubectl exec -n identity keycloak-0 -- ping keycloak-postgresql

# Verify database credentials match
kubectl get statefulset -n identity keycloak -o yaml | grep -A5 DB_
```

### FreeIPA Pod Not Ready

**Symptom**: FreeIPA pod readiness probe fails

**Solution**:
```bash
# Check FreeIPA logs
kubectl logs -n identity freeipa-0

# FreeIPA initialization can take 5-10 minutes
# Wait for "FreeIPA server configured" message

# Check systemd services inside pod
kubectl exec -n identity freeipa-0 -- systemctl status ipa
```

### LDAP User Federation Not Working

**Symptom**: Users not syncing from FreeIPA to Keycloak

**Solution**:
1. Verify LDAP connection settings in Keycloak
2. Test connection and authentication
3. Check FreeIPA LDAP is accessible:
   ```bash
   kubectl exec -n identity keycloak-0 -- \
     ldapsearch -x -H ldap://freeipa.identity.svc.cluster.local:389 \
     -b "cn=users,cn=accounts,dc=vmstation,dc=local"
   ```
4. Check bind credentials are correct
5. Force user sync in Keycloak UI

### Certificate Not Issued

**Symptom**: Certificate resource shows "Not Ready"

**Solution**:
```bash
# Check certificate status
kubectl describe certificate -n identity keycloak-tls

# Check cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager

# Verify ClusterIssuer
kubectl get clusterissuer freeipa-ca-issuer -o yaml

# Check CA secret exists
kubectl get secret -n cert-manager freeipa-ca-keypair
```

## Security Considerations

### Passwords

- **Replace all CHANGEME passwords** before production deployment
- Use strong, randomly generated passwords (32+ characters)
- Store passwords securely in Ansible Vault or external secret manager
- Rotate passwords regularly

### TLS/SSL

- Use TLS for all external access to Keycloak and FreeIPA
- Configure Ingress with TLS termination
- Use cert-manager to automate certificate renewal
- Ensure certificates have proper SANs for all access paths

### Network Security

- Restrict access to Keycloak admin console (use NetworkPolicies)
- Use LDAPS (636) instead of LDAP (389) for production
- Configure firewall rules on nodes
- Use Kubernetes NetworkPolicies to isolate identity namespace

### Access Control

- Enable Keycloak brute force protection
- Configure session timeouts
- Enable MFA for admin accounts
- Audit user access regularly

## Maintenance

### Backup

Identity data is backed up to `/root/identity-backup/`:
- CA certificate and key
- Administrator credentials
- Configuration files

**Important**: Backup FreeIPA data volume regularly:
```bash
kubectl exec -n identity freeipa-0 -- ipa-backup
kubectl cp identity/freeipa-0:/var/lib/ipa/backup/latest /backup/freeipa/
```

### Updates

To update components:

```bash
# Update Keycloak
helm repo update
helm upgrade keycloak codecentric/keycloak -n identity

# Update cert-manager
helm repo update
helm upgrade cert-manager jetstack/cert-manager -n cert-manager

# Update FreeIPA (requires manual process)
# See FreeIPA documentation for upgrade procedures
```

### Password Rotation

Update passwords in:
1. `helm/keycloak-values.yaml`
2. `manifests/identity/freeipa.yaml`
3. Ansible Vault (if used)
4. Keycloak admin console

After updating, re-run deployment:
```bash
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml
```

## Next Steps

1. **Deploy Monitoring Stack**: See `docs/KEYCLOAK-INTEGRATION.md`
2. **Add More OIDC Clients**: For additional applications
3. **Configure GitLab/GitHub SSO**: For code repositories
4. **Enable MFA**: Add multi-factor authentication
5. **Set Up Automated Backups**: Schedule regular backups

## References

- [Keycloak Documentation](https://www.keycloak.org/documentation)
- [FreeIPA Documentation](https://www.freeipa.org/page/Documentation)
- [cert-manager Documentation](https://cert-manager.io/docs/)
- [OIDC Specification](https://openid.net/connect/)
