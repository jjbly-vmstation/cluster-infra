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

## Step 4a: DNS and Network Configuration

After deploying the identity stack (Steps 1-3), use these scripts to configure DNS records and network ports for FreeIPA and Keycloak.

### extract-freeipa-dns-records.sh

**Purpose**: Extract DNS records from FreeIPA pod for distribution to cluster nodes.

**Usage**:
```bash
./scripts/extract-freeipa-dns-records.sh -v
```

**Options**:
- `-n, --namespace`: Kubernetes namespace (default: identity)
- `-p, --pod`: FreeIPA pod name (default: freeipa-0)
- `-o, --output`: Output directory (default: /tmp/freeipa-dns-records)
- `-v, --verbose`: Enable verbose output

**Output**:
- DNS record files in BIND format
- Hosts file format at `/tmp/freeipa-dns-records/freeipa-hosts.txt`
- Extraction summary

### configure-dns-records.sh

**Purpose**: Distribute FreeIPA DNS records to /etc/hosts on all cluster nodes.

**Usage**:
```bash
./scripts/configure-dns-records.sh
```

**Options**:
- `-f, --file`: DNS records file (default: /tmp/freeipa-dns-records/freeipa-hosts.txt)
- `-d, --dry-run`: Show what would be done without making changes
- `-v, --verbose`: Enable verbose output

**What it does**:
1. Backs up existing /etc/hosts
2. Removes old FreeIPA entries
3. Adds new FreeIPA DNS records
4. Verifies DNS resolution

### configure-network-ports.sh

**Purpose**: Configure firewall rules for FreeIPA, Keycloak, and cluster communication.

**Usage**:
```bash
./scripts/configure-network-ports.sh
```

**Options**:
- `-d, --dry-run`: Show what would be done without making changes
- `-f, --force`: Force reconfiguration even if rules exist
- `-v, --verbose`: Enable verbose output

**Supported Systems**:
- firewalld (RHEL 10, CentOS, AlmaLinux)
- iptables (Debian 12, Ubuntu)

**Ports Configured**:
- TCP: 22 (SSH), 80, 443, 389, 636, 88, 464, 53
- UDP: 88, 464, 53

### verify-network-ports.sh

**Purpose**: Verify that all required network ports are accessible.

**Usage**:
```bash
./scripts/verify-network-ports.sh
```

**Options**:
- `-v, --verbose`: Enable verbose output
- `-t, --timeout`: Connection timeout in seconds (default: 5)

**Tests Performed**:
1. SSH connectivity to all nodes
2. FreeIPA service ports
3. Keycloak service ports
4. DNS resolution
5. Kerberos ports

### verify-freeipa-keycloak-readiness.sh

**Purpose**: Comprehensive validation of FreeIPA and Keycloak deployment readiness.

**Usage**:
```bash
./scripts/verify-freeipa-keycloak-readiness.sh
```

**Options**:
- `-n, --namespace`: Kubernetes namespace (default: identity)
- `-v, --verbose`: Enable verbose output
- `--test-kerberos`: Test Kerberos authentication

**Checks Performed**:
1. Pod readiness and status
2. DNS resolution
3. Service endpoints
4. Web UI accessibility
5. LDAP connectivity
6. Network ports
7. Optional: Kerberos authentication

### Complete Step 4a Workflow

**Automated (Recommended)**:
```bash
# Using Ansible playbook
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml \
  ansible/playbooks/configure-dns-network-step4a.yml
```

**Manual (Individual scripts)**:
```bash
# 1. Extract DNS records
./scripts/extract-freeipa-dns-records.sh -v

# 2. Configure DNS records
./scripts/configure-dns-records.sh

# 3. Configure firewall rules
./scripts/configure-network-ports.sh

# 4. Verify configuration
./scripts/verify-network-ports.sh
./scripts/verify-freeipa-keycloak-readiness.sh
```

**Documentation**: See [docs/STEP4A_DNS_NETWORK_CONFIGURATION.md](../docs/STEP4A_DNS_NETWORK_CONFIGURATION.md) for detailed instructions.

## Library Functions

The `lib/` subdirectory contains shared shell functions:
- `kubespray-common.sh` - Common functions for Kubespray operations
- `kubespray-validation.sh` - Validation functions for environment checks
