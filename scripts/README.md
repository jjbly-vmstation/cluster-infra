# Scripts Directory

This directory contains various scripts for managing and maintaining the VMStation cluster infrastructure.

## Identity Stack Management

### cleanup-identity-stack.sh

**Purpose**: Clean up identity stack PV/PVCs and pods for testing idempotency or performing a fresh deployment.

**Usage**:
```bash
sudo ./scripts/cleanup-identity-stack.sh
```

**What it does**:
1. Scales down all StatefulSets and Deployments in the identity namespace
2. Deletes all pods (with force if necessary)
3. Removes all PVCs in the identity namespace
4. Deletes PVs for Keycloak PostgreSQL and FreeIPA
5. Backs up existing data directories to timestamped backups
6. Recreates clean storage directories with proper permissions

**Storage Location**:
- PostgreSQL data: `/srv/monitoring-data/postgresql`
- FreeIPA data: `/srv/monitoring-data/freeipa`

**After cleanup**, you can run the identity deployment playbook again:
```bash
sudo ansible-playbook -i /opt/vmstation-org/cluster-setup/ansible/inventory/hosts.yml \
  ansible/playbooks/identity-deploy-and-handover.yml --become
```

**Important Notes**:
- This script requires root privileges (use `sudo`)
- Data directories are backed up before deletion (not permanently removed)
- Backups are stored with timestamps in the same parent directory
- Use this for testing, troubleshooting, or starting fresh

## Kubespray Management

### run-kubespray.sh
Wrapper script for running Kubespray deployments with proper environment setup.

### activate-kubespray-env.sh
Activates the Kubespray Python virtual environment.

### ops-kubespray-automation.sh
Automation script for CI/CD operations with Kubespray.

### validate-kubespray-setup.sh
Validates that the Kubespray environment is correctly configured.

### test-inventory.sh
Tests and validates Ansible inventory files.

### dry-run-deployment.sh
Performs a dry run of cluster deployment to check for issues.

## Identity Verification

### verify-identity-deployment.sh
Verifies that the identity stack (FreeIPA, Keycloak, PostgreSQL) is properly deployed and operational.

## Library Functions

The `lib/` subdirectory contains shared shell functions:
- `kubespray-common.sh` - Common functions for Kubespray operations
- `kubespray-validation.sh` - Validation functions for environment checks
