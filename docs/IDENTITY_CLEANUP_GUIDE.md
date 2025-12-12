# Identity Stack Cleanup and Re-deployment Guide

This guide explains how to clean up the identity stack and re-deploy it for testing idempotency or resolving deployment issues.

## Overview

The identity stack consists of:
- **PostgreSQL**: Database for Keycloak
- **Keycloak**: Identity and access management
- **FreeIPA**: LDAP, Kerberos, and CA services
- **cert-manager**: Certificate management

Storage location: `/srv/monitoring-data/`

## Quick Start: Clean Up and Re-deploy

To perform a complete cleanup and fresh deployment:

```bash
# 1. Clean up existing resources (backs up data automatically)
sudo ./scripts/cleanup-identity-stack.sh

# 2. Re-run the playbook
sudo ansible-playbook -i /opt/vmstation-org/cluster-setup/ansible/inventory/hosts.yml \
  ansible/playbooks/identity-deploy-and-handover.yml --become
```

## What the Cleanup Script Does

The `cleanup-identity-stack.sh` script performs the following actions:

1. **Scales down workloads**: Sets replicas to 0 for all StatefulSets and Deployments
2. **Deletes pods**: Forcefully removes all pods in the identity namespace
3. **Removes PVCs**: Deletes all PersistentVolumeClaims
4. **Deletes PVs**: Removes PersistentVolumes for PostgreSQL and FreeIPA
5. **Backs up data**: Creates timestamped backups of existing data:
   - `/srv/monitoring-data/postgresql.backup.<timestamp>`
   - `/srv/monitoring-data/freeipa.backup.<timestamp>`
6. **Recreates directories**: Creates clean storage directories with proper ownership:
   - PostgreSQL: `999:999` (postgres user)
   - FreeIPA: `root:root`

## Manual Cleanup Steps (Alternative)

If you prefer to clean up manually without using the script:

```bash
# Export kubeconfig
export KUBECONFIG=/etc/kubernetes/admin.conf

# Scale down StatefulSets
kubectl -n identity scale statefulset --all --replicas=0

# Delete pods
kubectl -n identity delete pods --all --force --grace-period=0

# Delete PVCs
kubectl -n identity delete pvc --all

# Delete PVs
kubectl delete pv keycloak-postgresql-pv freeipa-data-pv

# Backup and recreate directories
sudo mv /srv/monitoring-data/postgresql /srv/monitoring-data/postgresql.backup.$(date +%Y%m%d-%H%M%S)
sudo mv /srv/monitoring-data/freeipa /srv/monitoring-data/freeipa.backup.$(date +%Y%m%d-%H%M%S)
sudo mkdir -p /srv/monitoring-data/postgresql /srv/monitoring-data/freeipa
sudo chown 999:999 /srv/monitoring-data/postgresql
sudo chown root:root /srv/monitoring-data/freeipa
sudo chmod 0755 /srv/monitoring-data/postgresql /srv/monitoring-data/freeipa
```

## Troubleshooting Common Issues

### Issue: PVC Remains in Pending State

**Symptoms:**
- PVC `data-keycloak-postgresql-0` or `freeipa-data` is in Pending state
- Pods cannot start due to missing volumes

**Solution:**
```bash
# Check PV availability
kubectl get pv

# If PV exists but has a stale claimRef, patch it:
kubectl patch pv keycloak-postgresql-pv --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'
kubectl patch pv freeipa-data-pv --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'

# Re-run the playbook
sudo ansible-playbook -i /opt/vmstation-org/cluster-setup/ansible/inventory/hosts.yml \
  ansible/playbooks/identity-deploy-and-handover.yml --become
```

### Issue: Pods Not Scheduling Due to Node Affinity

**Symptoms:**
- Pods show `FailedScheduling` events
- Error: "didn't match Pod's node affinity/selector"

**Solution:**
The pods require the control-plane node. Ensure the control-plane node is schedulable:

```bash
# Uncordon the control-plane node
kubectl uncordon $(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}')

# Verify node is Ready and schedulable
kubectl get nodes
```

### Issue: PostgreSQL Rollout Timeout

**Symptoms:**
- PostgreSQL pod doesn't become ready within timeout period
- Error: "timed out waiting for the condition"

**Diagnosis:**
```bash
# Check pod status
kubectl get pods -n identity

# Check pod logs
kubectl logs -n identity keycloak-postgresql-0

# Check pod events
kubectl describe pod -n identity keycloak-postgresql-0

# Check diagnostics (automatically saved)
sudo cat /root/identity-backup/postgres-diagnostics-*.log
```

**Solution:**
If PostgreSQL is still starting, wait longer. If there's a persistent issue:
```bash
# Use the cleanup script to start fresh
sudo ./scripts/cleanup-identity-stack.sh

# Re-run with higher timeout
sudo ansible-playbook -i /opt/vmstation-org/cluster-setup/ansible/inventory/hosts.yml \
  ansible/playbooks/identity-deploy-and-handover.yml --become \
  -e rollout_wait_timeout=600
```

### Issue: Control-Plane Taint Prevents Scheduling

**Symptoms:**
- Pods show `FailedScheduling` events
- Error: "had untolerated taint"

**Solution:**
The manifests already include tolerations for the control-plane taint. If pods still can't schedule:

```bash
# Option 1: Remove the taint (not recommended for production)
kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-

# Option 2: Verify tolerations are present (recommended)
kubectl get statefulset -n identity keycloak-postgresql -o yaml | grep -A3 tolerations

# The playbook should add tolerations automatically on re-run
```

## Storage Management

### Current Storage Locations

- **PostgreSQL**: `/srv/monitoring-data/postgresql` (owned by `999:999`)
- **FreeIPA**: `/srv/monitoring-data/freeipa` (owned by `root:root`)
- **Backups**: `/root/identity-backup/`

### Checking Storage Usage

```bash
# Check directory sizes
sudo du -sh /srv/monitoring-data/*

# Check available space
df -h /srv
```

### Restoring from Backup

If you need to restore data from a backup:

```bash
# Stop the identity stack
sudo ./scripts/cleanup-identity-stack.sh

# Restore from backup (replace <timestamp> with your backup)
sudo rm -rf /srv/monitoring-data/postgresql
sudo rm -rf /srv/monitoring-data/freeipa
sudo mv /srv/monitoring-data/postgresql.backup.<timestamp> /srv/monitoring-data/postgresql
sudo mv /srv/monitoring-data/freeipa.backup.<timestamp> /srv/monitoring-data/freeipa

# Fix permissions
sudo chown -R 999:999 /srv/monitoring-data/postgresql
sudo chown -R root:root /srv/monitoring-data/freeipa

# Re-deploy
sudo ansible-playbook -i /opt/vmstation-org/cluster-setup/ansible/inventory/hosts.yml \
  ansible/playbooks/identity-deploy-and-handover.yml --become
```

## Verifying Deployment

After deployment, verify the identity stack is working:

```bash
# Run the verification script
./tests/verify-identity-deploy.sh

# Or manually check components:
kubectl get pods -n identity
kubectl get pvc -n identity
kubectl get pv
kubectl get svc -n identity
```

## Best Practices

1. **Always backup before cleanup**: The cleanup script automatically creates backups, but you can create manual backups too
2. **Test in non-production first**: Test the cleanup and deployment process in a development environment
3. **Monitor disk space**: Ensure `/srv/monitoring-data` has sufficient space (PostgreSQL: 8Gi, FreeIPA: 20Gi minimum)
4. **Keep backups**: Old backups are not automatically deleted; clean them up periodically
5. **Use idempotent deployments**: The playbook is designed to be idempotent; re-running it should be safe

## Advanced: Selective Cleanup

If you only want to clean up specific components:

```bash
# Clean up only PostgreSQL
kubectl -n identity scale statefulset keycloak-postgresql --replicas=0
kubectl -n identity delete pod keycloak-postgresql-0 --force
kubectl -n identity delete pvc data-keycloak-postgresql-0
kubectl delete pv keycloak-postgresql-pv

# Clean up only FreeIPA
kubectl -n identity scale statefulset freeipa --replicas=0
kubectl -n identity delete pod freeipa-0 --force
kubectl -n identity delete pvc freeipa-data
kubectl delete pv freeipa-data-pv

# Clean up only Keycloak (keeps database)
kubectl -n identity scale statefulset keycloak --replicas=0
kubectl -n identity delete pod keycloak-0 --force
```

## Getting Help

If you encounter issues not covered in this guide:

1. Check the diagnostics logs in `/root/identity-backup/`
2. Review the main README at the repository root
3. Check the CHANGELOG for recent changes
4. Review the specific component documentation in `manifests/identity/README.md`
