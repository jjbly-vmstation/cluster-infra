# Identity Stack Deployment Scripts

This directory contains scripts for deploying, managing, and resetting the identity stack (FreeIPA, Keycloak, PostgreSQL) in the VMStation cluster.

## Overview

The identity deployment workflow is managed by a main orchestration script that calls several helper scripts to perform specific tasks. All scripts support dry-run mode for safe testing and are designed to be idempotent where possible.

## Scripts

### Main Orchestration Script

#### `identity-full-deploy.sh`

Main orchestration wrapper that manages the complete identity stack deployment workflow.

**Features:**
- Optional destructive reset (with explicit confirmation)
- Deployment via existing Ansible playbooks
- Admin account bootstrapping
- CA certificate management
- Cluster node enrollment
- Final verification
- Comprehensive logging to `/opt/vmstation-org/copilot-identity-fixing-automate`

**Usage:**

```bash
# Deploy identity stack (no reset)
sudo ./scripts/identity-full-deploy.sh

# Dry-run mode (no actual changes)
sudo DRY_RUN=1 ./scripts/identity-full-deploy.sh

# Reset and deploy with interactive confirmation
sudo FORCE_RESET=1 ./scripts/identity-full-deploy.sh

# Automated reset and deploy (no prompts)
sudo FORCE_RESET=1 RESET_CONFIRM=yes ./scripts/identity-full-deploy.sh

# Automated with custom passwords
sudo FORCE_RESET=1 RESET_CONFIRM=yes \
  FREEIPA_ADMIN_PASSWORD=mypass \
  KEYCLOAK_ADMIN_PASSWORD=mypass \
  ./scripts/identity-full-deploy.sh

# Reset only (no redeploy)
sudo FORCE_RESET=1 REDEPLOY_AFTER_RESET=0 ./scripts/identity-full-deploy.sh
```

**Environment Variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `DRY_RUN` | 0 | Set to "1" for dry-run mode (no changes) |
| `FORCE_RESET` | 0 | Set to "1" to perform reset before deploy |
| `RESET_CONFIRM` | (prompt) | Set to "yes" to skip confirmation prompt |
| `RESET_REMOVE_OLD` | 0 | Set to "1" to remove old backup directories |
| `REDEPLOY_AFTER_RESET` | 1 | Set to "0" to skip deploy after reset |
| `FREEIPA_ADMIN_PASSWORD` | (auto) | FreeIPA admin password |
| `KEYCLOAK_ADMIN_PASSWORD` | (auto) | Keycloak admin password |
| `SKIP_NODE_ENROLLMENT` | 0 | Set to "1" to skip node enrollment |
| `SKIP_VERIFICATION` | 0 | Set to "1" to skip final verification |
| `ANSIBLE_INVENTORY` | inventory.ini | Path to Ansible inventory file |

**Workflow Phases:**

1. **Preflight Checks** - Verify requirements and prerequisites
2. **Optional Reset** - If `FORCE_RESET=1`, run reset-identity-stack.sh
3. **Deployment** - Run Ansible playbook to deploy identity stack
4. **Admin Bootstrap** - Create/verify admin accounts for FreeIPA and Keycloak
5. **CA Setup** - Create/request CA certificates and update cert-manager
6. **Node Enrollment** - Enroll cluster nodes with FreeIPA for SSO
7. **Verification** - Run verification checks on deployed stack
8. **Summary** - Generate deployment summary and report

### Helper Scripts

#### `reset-identity-stack.sh`

Conservative reset helper that safely removes identity stack resources with timestamped backups.

**Features:**
- Preflight checks for safe execution
- Timestamped backup workspace creation
- Backup of credentials, CA certs, and manifests
- Graceful workload shutdown
- PVC/PV removal with confirmation
- Storage directory backup and cleanup
- Optional removal of old backups

**Usage:**

```bash
# Interactive reset (will prompt for confirmation)
sudo ./scripts/reset-identity-stack.sh

# Automated reset
sudo RESET_CONFIRM=yes ./scripts/reset-identity-stack.sh

# Automated reset and cleanup old backups
sudo RESET_CONFIRM=yes RESET_REMOVE_OLD=1 ./scripts/reset-identity-stack.sh

# Dry-run mode
sudo DRY_RUN=1 ./scripts/reset-identity-stack.sh
```

**Environment Variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `RESET_CONFIRM` | (prompt) | Set to "yes" to skip confirmation |
| `RESET_REMOVE_OLD` | 0 | Set to "1" to remove old auto-reset-* directories |
| `DRY_RUN` | 0 | Set to "1" for dry-run mode |
| `KUBECONFIG` | /etc/kubernetes/admin.conf | Path to kubeconfig |
| `NAMESPACE_IDENTITY` | identity | Identity namespace name |
| `STORAGE_PATH` | /srv/monitoring-data | Base storage path |
| `POSTGRESQL_PV_NAME` | keycloak-postgresql-pv | PostgreSQL PV name |
| `FREEIPA_PV_NAME` | freeipa-data-pv | FreeIPA PV name |

**Backup Location:**

Backups are stored in `/root/identity-backup/auto-reset-YYYYMMDD-HHMMSS/` with subdirectories:
- `credentials/` - Admin credentials files
- `ca-certs/` - CA certificates and archives
- `manifests/` - Kubernetes resource manifests
- `logs/` - Operation logs
- `postgresql-data.tar.gz` - PostgreSQL data backup
- `freeipa-data.tar.gz` - FreeIPA data backup
- `reset-summary.txt` - Reset summary and restore instructions

#### `bootstrap-identity-admins.sh`

Bootstrap helper for creating and managing admin accounts for FreeIPA and Keycloak.

**Features:**
- Idempotent - will not recreate existing accounts
- Auto-generates secure passwords if not provided
- Saves credentials to secure location
- Retrieves existing passwords from Kubernetes secrets
- Creates combined credentials file

**Usage:**

```bash
# Auto-generate passwords
sudo ./scripts/bootstrap-identity-admins.sh

# Provide custom passwords
sudo FREEIPA_ADMIN_PASSWORD=secret \
     KEYCLOAK_ADMIN_PASSWORD=secret \
     ./scripts/bootstrap-identity-admins.sh

# Dry-run mode
sudo DRY_RUN=1 ./scripts/bootstrap-identity-admins.sh
```

**Environment Variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `FREEIPA_ADMIN_PASSWORD` | (auto) | FreeIPA admin password |
| `KEYCLOAK_ADMIN_PASSWORD` | (auto) | Keycloak admin password |
| `DRY_RUN` | 0 | Set to "1" for dry-run mode |
| `KUBECONFIG` | /etc/kubernetes/admin.conf | Path to kubeconfig |
| `NAMESPACE_IDENTITY` | identity | Identity namespace name |
| `CREDENTIALS_DIR` | /root/identity-backup | Credentials storage directory |

**Generated Files:**

- `/root/identity-backup/cluster-admin-credentials.txt` - Combined credentials
- `/root/identity-backup/keycloak-admin-credentials.txt` - Keycloak credentials
- `/root/identity-backup/freeipa-admin-credentials.txt` - FreeIPA credentials

#### `request-freeipa-intermediate-ca.sh`

CA certificate helper that creates/requests intermediate CA and updates cert-manager.

**Features:**
- Idempotent - skips if valid CA exists
- Falls back to self-signed CA if FreeIPA unavailable
- Backs up CA certificates
- Updates cert-manager with new CA
- Validates CA expiration (30+ days)

**Usage:**

```bash
# Auto-detect FreeIPA and create CA
sudo ./scripts/request-freeipa-intermediate-ca.sh

# Provide FreeIPA password
sudo FREEIPA_ADMIN_PASSWORD=secret ./scripts/request-freeipa-intermediate-ca.sh

# Dry-run mode
sudo DRY_RUN=1 ./scripts/request-freeipa-intermediate-ca.sh
```

**Environment Variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `FREEIPA_ADMIN_PASSWORD` | (auto) | FreeIPA admin password |
| `DRY_RUN` | 0 | Set to "1" for dry-run mode |
| `KUBECONFIG` | /etc/kubernetes/admin.conf | Path to kubeconfig |
| `NAMESPACE_IDENTITY` | identity | Identity namespace name |
| `NAMESPACE_CERT_MANAGER` | cert-manager | cert-manager namespace |
| `CA_BACKUP_DIR` | /root/identity-backup | CA backup directory |
| `CA_VALIDITY_DAYS` | 3650 | CA validity in days (10 years) |

**CA Locations:**

- Certificate: `/etc/pki/tls/certs/ca.cert.pem`
- Private Key: `/etc/pki/tls/private/ca.key.pem`
- Backup: `/root/identity-backup/identity-ca-backup.tar.gz`

#### `enroll-nodes-freeipa.sh`

Node enrollment helper that enrolls cluster nodes with FreeIPA for authentication.

**Features:**
- Uses existing Ansible role for enrollment
- Idempotent - skips already-enrolled nodes
- Creates temporary playbook for enrollment
- Verifies enrollment after completion
- Supports both RHEL and Debian-based systems

**Usage:**

```bash
# Enroll all nodes in inventory
sudo ./scripts/enroll-nodes-freeipa.sh

# Provide FreeIPA password and custom inventory
sudo FREEIPA_ADMIN_PASSWORD=secret \
     ANSIBLE_INVENTORY=/path/to/inventory \
     ./scripts/enroll-nodes-freeipa.sh

# Dry-run mode
sudo DRY_RUN=1 ./scripts/enroll-nodes-freeipa.sh
```

**Environment Variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `FREEIPA_ADMIN_PASSWORD` | (auto) | FreeIPA admin password |
| `ANSIBLE_INVENTORY` | inventory.ini | Path to Ansible inventory |
| `FREEIPA_SERVER_IP` | 192.168.4.63 | FreeIPA server IP address |
| `FREEIPA_DOMAIN` | vmstation.local | FreeIPA domain name |
| `FREEIPA_REALM` | VMSTATION.LOCAL | FreeIPA Kerberos realm |
| `FREEIPA_SERVER_HOSTNAME` | ipa.vmstation.local | FreeIPA server hostname |
| `DRY_RUN` | 0 | Set to "1" for dry-run mode |

**Requirements:**

- Ansible and ansible-playbook installed
- Valid inventory file with cluster nodes
- Network connectivity to FreeIPA server
- FreeIPA must be running and accessible

## Safety Features

### Confirmation Guards

All destructive operations require explicit confirmation:

1. **Interactive Mode**: Scripts prompt for "yes" confirmation before destructive actions
2. **Automated Mode**: Set `RESET_CONFIRM=yes` to bypass prompts
3. **Dry-Run Mode**: Set `DRY_RUN=1` to preview actions without executing

### Backup System

Before any destructive operation:

1. **Timestamped Backups**: All backups use `YYYYMMDD-HHMMSS` timestamps
2. **Comprehensive Backup**: Credentials, CA certs, manifests, and data
3. **Restore Instructions**: Each backup includes restore instructions
4. **Multiple Copies**: Both local and archived backups

### Logging

All operations are logged to `/opt/vmstation-org/copilot-identity-fixing-automate/`:

- Timestamped log files for each run
- Phase markers for easy navigation
- Error and warning capture
- Summary reports with deployment details

## Common Workflows

### Initial Deployment

Deploy identity stack for the first time:

```bash
sudo ./scripts/identity-full-deploy.sh
```

### Complete Reset and Redeploy

Fully reset and redeploy identity stack:

```bash
# Interactive mode (will prompt for confirmation)
sudo FORCE_RESET=1 ./scripts/identity-full-deploy.sh

# Automated mode (no prompts)
sudo FORCE_RESET=1 RESET_CONFIRM=yes ./scripts/identity-full-deploy.sh
```

### Reset Without Redeploy

Reset identity stack but don't redeploy:

```bash
sudo FORCE_RESET=1 REDEPLOY_AFTER_RESET=0 ./scripts/identity-full-deploy.sh
```

### Dry-Run Testing

Test workflow without making changes:

```bash
sudo DRY_RUN=1 FORCE_RESET=1 ./scripts/identity-full-deploy.sh
```

### Bootstrap Admin Accounts Only

Create/update admin accounts without full deployment:

```bash
sudo ./scripts/bootstrap-identity-admins.sh
```

### Update CA Certificates Only

Update CA certificates without full deployment:

```bash
sudo ./scripts/request-freeipa-intermediate-ca.sh
```

### Enroll Nodes Only

Enroll cluster nodes without full deployment:

```bash
sudo ./scripts/enroll-nodes-freeipa.sh
```

## Troubleshooting

### Reset Failed

If reset fails:

1. Check logs in `/opt/vmstation-org/copilot-identity-fixing-automate/`
2. Verify kubectl connectivity: `kubectl cluster-info`
3. Check namespace exists: `kubectl get namespace identity`
4. Try dry-run first: `DRY_RUN=1 ./scripts/reset-identity-stack.sh`

### Deployment Failed

If deployment fails:

1. Check Ansible playbook output in logs
2. Verify prerequisites: kubectl, Helm, storage paths
3. Check pod status: `kubectl get pods -n identity`
4. Review Ansible playbook: `ansible/playbooks/identity-deploy-and-handover.yml`

### Admin Bootstrap Failed

If admin bootstrap fails:

1. Check pods are running: `kubectl get pods -n identity`
2. Wait for pods to be ready (especially FreeIPA - can take 5+ minutes)
3. Verify secrets exist: `kubectl get secrets -n identity`
4. Check logs: `/opt/vmstation-org/copilot-identity-fixing-automate/`

### CA Setup Failed

If CA setup fails:

1. Check FreeIPA availability: `kubectl get pods -n identity -l app=freeipa`
2. Verify cert-manager: `kubectl get pods -n cert-manager`
3. Check existing CA: `ls -la /etc/pki/tls/certs/ca.cert.pem`
4. Falls back to self-signed CA automatically

### Node Enrollment Failed

If node enrollment fails:

1. Verify FreeIPA is running: `kubectl get pods -n identity -l app=freeipa`
2. Check network connectivity to FreeIPA server
3. Verify Ansible inventory is correct
4. Check FreeIPA server is accessible: `ping ipa.vmstation.local`
5. Review Ansible output in logs

### Pods Won't Start

If pods won't start after deployment:

1. Check storage paths exist and have correct permissions
2. Verify PVs and PVCs: `kubectl get pv,pvc -n identity`
3. Check node taints/tolerations: `kubectl get nodes -o json | jq '.items[].spec.taints'`
4. Review pod events: `kubectl describe pod <pod-name> -n identity`

## Recovery Procedures

### Restore from Backup

To restore from a timestamped backup:

```bash
# Find backup directory
ls -la /root/identity-backup/auto-reset-*/

# Restore data
cd /root/identity-backup/auto-reset-YYYYMMDD-HHMMSS/
tar -xzf postgresql-data.tar.gz -C /srv/monitoring-data
tar -xzf freeipa-data.tar.gz -C /srv/monitoring-data

# Restore CA certificates
cp ca-certs/ca.cert.pem /etc/pki/tls/certs/
cp ca-certs/ca.key.pem /etc/pki/tls/private/
chmod 644 /etc/pki/tls/certs/ca.cert.pem
chmod 600 /etc/pki/tls/private/ca.key.pem

# Redeploy identity stack
./scripts/identity-full-deploy.sh
```

### Manual Reset

To manually reset identity stack:

```bash
# Scale down workloads
kubectl -n identity scale statefulset --all --replicas=0
kubectl -n identity scale deployment --all --replicas=0

# Delete resources
kubectl -n identity delete pods --all --force --grace-period=0
kubectl -n identity delete pvc --all
kubectl delete pv keycloak-postgresql-pv freeipa-data-pv

# Clean storage
rm -rf /srv/monitoring-data/postgresql
rm -rf /srv/monitoring-data/freeipa
mkdir -p /srv/monitoring-data/{postgresql,freeipa}
chown 999:999 /srv/monitoring-data/postgresql
```

### Emergency CA Regeneration

To force CA regeneration:

```bash
# Remove existing CA
rm -f /etc/pki/tls/certs/ca.cert.pem
rm -f /etc/pki/tls/private/ca.key.pem

# Regenerate
./scripts/request-freeipa-intermediate-ca.sh
```

## Security Considerations

### Credentials

- All credential files have `0600` permissions (root only)
- Credentials directory has `0700` permissions (root only)
- Auto-generated passwords use secure random generation
- Passwords are stored in Kubernetes secrets and files

### CA Certificates

- Private keys have `0600` permissions (root only)
- Certificates are backed up in multiple locations
- CA validity is checked and enforced (minimum 30 days)
- Self-signed fallback when FreeIPA unavailable

### Best Practices

1. **Change Default Passwords**: Always change auto-generated passwords in production
2. **Use Ansible Vault**: Store passwords in Ansible Vault for automation
3. **Backup Regularly**: Keep backups of credentials and CA certificates
4. **Test in Staging**: Test reset/deploy in staging before production
5. **Review Logs**: Always review logs after operations
6. **Secure Log Files**: Logs may contain sensitive information

## Related Documentation

- [Identity SSO Setup Guide](../docs/IDENTITY-SSO-SETUP.md)
- [Keycloak Integration Guide](../docs/KEYCLOAK-INTEGRATION.md)
- [Identity Stack Validation](../docs/IDENTITY-STACK-VALIDATION.md)
- [Ansible Playbook README](../ansible/playbooks/README.md)

## Support

For issues or questions:

1. Check logs in `/opt/vmstation-org/copilot-identity-fixing-automate/`
2. Review backup summaries in `/root/identity-backup/auto-reset-*/`
3. Check pod status: `kubectl get pods -n identity -o wide`
4. Review events: `kubectl get events -n identity --sort-by=.metadata.creationTimestamp`

## Script Maintenance

When updating scripts:

1. Maintain backward compatibility with environment variables
2. Add new features as opt-in (default to safe behavior)
3. Update this documentation
4. Test in dry-run mode first
5. Test all workflows (reset, deploy, bootstrap, etc.)
