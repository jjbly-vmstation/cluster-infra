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

### automate-identity-dns-and-coredns.sh

**Purpose**: Wrapper script to fully automate steps 4a→5 (DNS extraction, CoreDNS configuration, and verification).

**Usage**:
```bash
sudo ./scripts/automate-identity-dns-and-coredns.sh
```

**Options**:
- `-n, --namespace`: Kubernetes namespace (default: identity)
- `-k, --kubeconfig`: Path to kubeconfig (default: /etc/kubernetes/admin.conf)
- `-i, --inventory`: Ansible inventory file
- `-v, --verbose`: Enable verbose output
- `--force-cleanup`: Force cleanup of previous results

**What it does**:
1. Runs `extract-freeipa-dns-records.sh` to extract DNS records
2. Runs `configure-coredns-freeipa.yml` Ansible playbook
3. Runs `verify-freeipa-keycloak-readiness.sh` for basic readiness checks
4. Runs `verify-identity-and-certs.sh` for comprehensive verification
5. Displays paths to all result files

**Output**:
- All verification results in `/opt/vmstation-org/copilot-identity-fixing-automate/`
- DNS records in `/tmp/freeipa-dns-records/`

### verify-identity-and-certs.sh

**Purpose**: Comprehensive, robust verification of identity stack and certificate distribution.

**Usage**:
```bash
sudo ./scripts/verify-identity-and-certs.sh --verbose
```

**Options**:
- `-n, --namespace`: Kubernetes namespace (default: identity)
- `-k, --kubeconfig`: Path to kubeconfig (default: /etc/kubernetes/admin.conf)
- `-w, --workspace`: Workspace directory (default: /opt/vmstation-org/copilot-identity-fixing-automate)
- `-b, --backup-dir`: Backup directory for credentials (default: /root/identity-backup)
- `-v, --verbose`: Enable verbose output

**Checks Performed**:
1. Preflight: Verify required tools (kubectl, curl, openssl, jq, python3)
2. Workspace: Setup secure workspace with mode 700
3. Credentials: Discover backup credentials for Keycloak and FreeIPA
4. Keycloak: Admin access verification and recovery guidance
5. FreeIPA: Admin access verification and recovery guidance
6. Certificates: ClusterIssuer and FreeIPA CA fingerprint comparison
7. Key Distribution: Verify Keycloak PKCS12 keystore presence
8. Audit: Generate comprehensive, sanitized audit log

**Output Files**:
- `recover_identity_audit.log` - Human-readable audit log (mode 600)
- `recover_identity_steps.json` - Structured JSON array of steps (mode 600)
- `keycloak_summary.txt` - Keycloak verification summary (mode 600)
- `freeipa_summary.txt` - FreeIPA verification summary (mode 600)

**Security Features**:
- Never writes passwords or tokens to logs
- All output files created with mode 600
- Credentials stored only in `/root/identity-backup/`
- Non-destructive checks only
- Provides remediation guidance without executing changes

### Complete Step 4a Workflow

**Fully Automated (Recommended)**:
```bash
# Run the wrapper script to automate everything
sudo ./scripts/automate-identity-dns-and-coredns.sh --verbose
```

**Manual (Individual scripts)**:
```bash
# 1. Extract DNS records
./scripts/extract-freeipa-dns-records.sh -v

# 2. Configure DNS records
./scripts/configure-dns-records.sh

# 3. Configure firewall rules
./scripts/configure-network-ports.sh

# 4. Verify network ports
./scripts/verify-network-ports.sh

# 5. Verify FreeIPA and Keycloak readiness
./scripts/verify-freeipa-keycloak-readiness.sh

# 6. Comprehensive identity and certificate verification
sudo ./scripts/verify-identity-and-certs.sh --verbose
```

**Documentation**: See [docs/STEP4A_DNS_NETWORK_CONFIGURATION.md](../docs/STEP4A_DNS_NETWORK_CONFIGURATION.md) for detailed instructions.

## Library Functions

The `lib/` subdirectory contains shared shell functions:
- `kubespray-common.sh` - Common functions for Kubespray operations
- `kubespray-validation.sh` - Validation functions for environment checks
