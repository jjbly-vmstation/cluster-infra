# Testing Guide for identity-certmanager Role

This document describes how to test the CA handling logic in the identity-certmanager role after the variable scope error fix.

## Prerequisites

- Kubernetes cluster is running
- Ansible is installed
- kubectl is configured with admin access
- You have sudo privileges on the target host

## Test Scenarios

### Scenario 1: CA Already Exists

**Purpose**: Verify that the role uses existing CA files without modification.

**Setup**:
```bash
# Ensure CA exists
ls -la /opt/vmstation-org/cluster-setup/scripts/certs/ca.*.pem
```

**Expected files**:
- `/opt/vmstation-org/cluster-setup/scripts/certs/ca.cert.pem`
- `/opt/vmstation-org/cluster-setup/scripts/certs/ca.key.pem`

**Run**:
```bash
sudo ansible-playbook -i /opt/vmstation-org/cluster-setup/ansible/inventory/hosts.yml \
  playbooks/identity-deploy-and-handover.yml --become \
  --tags certmanager
```

**Expected outcome**:
- CA handling flags should show:
  - `ca_already_exists: true`
  - `ca_was_restored: false`
  - `ca_was_generated: false`
- CA tasks skip
- Existing CA is used
- ClusterIssuer created successfully

### Scenario 2: CA Restored from Backup

**Purpose**: Verify that the role can restore CA from backup when primary files are missing.

**Setup**:
```bash
# Remove CA but leave backup
sudo rm -f /opt/vmstation-org/cluster-setup/scripts/certs/ca.*.pem

# Verify backup exists
ls -la /root/identity-backup/identity-ca-backup.tar.gz
```

**Run**:
```bash
sudo ansible-playbook -i /opt/vmstation-org/cluster-setup/ansible/inventory/hosts.yml \
  playbooks/identity-deploy-and-handover.yml --become \
  --tags certmanager
```

**Expected outcome**:
- CA handling flags should show:
  - `ca_already_exists: false`
  - `ca_was_restored: true`
  - `ca_was_generated: false`
- Restoration message displayed: "CA files restored from backup: /root/identity-backup/identity-ca-backup.tar.gz"
- CA files restored to primary location
- Generation block skipped
- ClusterIssuer created successfully
- **NO variable scope errors**

### Scenario 3: Generate New CA

**Purpose**: Verify that the role can generate a new self-signed CA when none exists.

**Setup**:
```bash
# Remove everything
sudo rm -f /opt/vmstation-org/cluster-setup/scripts/certs/ca.*.pem
sudo rm -f /root/identity-backup/identity-ca-backup.tar.gz
```

**Run**:
```bash
sudo ansible-playbook -i /opt/vmstation-org/cluster-setup/ansible/inventory/hosts.yml \
  playbooks/identity-deploy-and-handover.yml --become \
  --tags certmanager \
  -e identity_generate_ca=true
```

**Expected outcome**:
- CA handling flags should show:
  - `ca_already_exists: false`
  - `ca_was_restored: false`
  - `ca_was_generated: true`
- Generation message displayed: "Self-signed CA generated at ..."
- New CA files created
- ClusterIssuer created successfully

### Scenario 4: No CA and Generation Disabled

**Purpose**: Verify that the role fails gracefully when CA is missing and generation is disabled.

**Setup**:
```bash
# Remove everything
sudo rm -f /opt/vmstation-org/cluster-setup/scripts/certs/ca.*.pem
sudo rm -f /root/identity-backup/identity-ca-backup.tar.gz
```

**Run**:
```bash
sudo ansible-playbook -i /opt/vmstation-org/cluster-setup/ansible/inventory/hosts.yml \
  playbooks/identity-deploy-and-handover.yml --become \
  --tags certmanager \
  -e identity_generate_ca=false
```

**Expected outcome**:
- Playbook should fail with clear error message:
  - "CA certificate not found at ... after restore/generation attempts"
  - OR "CA key not found at ... after restore/generation attempts"
- ClusterIssuer should NOT be created

## Verification Checklist

After running any scenario, verify:

- [ ] No variable scope errors in conditional checks
- [ ] Clear log messages indicate which CA path was taken (existing/restored/generated)
- [ ] Final verification ensures CA files exist before proceeding to Secret creation
- [ ] ClusterIssuer is created successfully (when CA exists)
- [ ] Backup is created after CA handling completes

## Debugging

If tests fail, check:

1. **Variable values**: Look for the "Display CA handling result" task output
2. **File permissions**: Ensure CA files have proper permissions (0600)
3. **Backup directory**: Verify /root/identity-backup exists and is accessible
4. **Kubernetes context**: Ensure kubectl can access the cluster
5. **Namespace**: Verify cert-manager namespace exists

## Success Criteria

All four scenarios should complete successfully with:
- ✅ No variable scope errors
- ✅ Appropriate CA handling flags set
- ✅ Clear log messages
- ✅ CA files exist after handling
- ✅ ClusterIssuer created (except Scenario 4)
