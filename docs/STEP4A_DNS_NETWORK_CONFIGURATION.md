# Step 4a: DNS Records and Network Ports Configuration

## Overview

Step 4a configures DNS records and network ports for FreeIPA and Keycloak after the identity stack deployment (Steps 1-3). This step ensures proper communication between cluster nodes, services, and clients.

## Table of Contents

- [Prerequisites](#prerequisites)
- [DNS Configuration](#dns-configuration)
- [Network Ports Configuration](#network-ports-configuration)
- [Automated Deployment](#automated-deployment)
- [Manual Configuration](#manual-configuration)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)
- [Integration Notes](#integration-notes)

---

## Prerequisites

### Required Components

Before starting Step 4a, ensure the following are completed:

1. **Identity Stack Deployed** (Steps 1-3)
   - FreeIPA StatefulSet running
   - Keycloak StatefulSet running
   - PostgreSQL StatefulSet running
   - cert-manager installed

2. **Cluster Access**
   - kubectl configured with `/etc/kubernetes/admin.conf`
   - SSH access to all cluster nodes
   - Sudo privileges on all nodes

3. **Network Connectivity**
   - All nodes can reach each other on 192.168.4.0/24
   - Kubernetes cluster network functioning (10.244.0.0/16)

### Cluster Node Information

| Hostname | IP Address | Role | OS | Firewall |
|----------|------------|------|----|----|
| masternode | 192.168.4.63 | Control Plane | Debian 12 | iptables |
| storagenodet3500 | 192.168.4.61 | Worker | Debian 12 | iptables |
| homelab | 192.168.4.62 | Worker | RHEL 10 | firewalld |

### FreeIPA Configuration

- **Hostname**: `ipa.vmstation.local`
- **Domain**: `vmstation.local`
- **Realm**: `VMSTATION.LOCAL`
- **Pod**: `freeipa-0` in namespace `identity`
- **DNS records location**: `/tmp/ipa.system.records.*.db` inside pod

### Service Endpoints

| Service | Access URL | NodePort |
|---------|-----------|----------|
| FreeIPA HTTP | http://192.168.4.63:30088 | 30088 |
| FreeIPA HTTPS | https://192.168.4.63:30445 | 30445 |
| FreeIPA LDAP | ldap://192.168.4.63:30389 | 30389 |
| FreeIPA LDAPS | ldaps://192.168.4.63:30636 | 30636 |
| Keycloak HTTP | http://192.168.4.63:30180 | 30180 |
| Keycloak HTTPS | https://192.168.4.63:30543 | 30543 |

---

## DNS Configuration

### Overview

DNS configuration ensures that `ipa.vmstation.local` and related hostnames resolve correctly on all cluster nodes. FreeIPA generates DNS records during initialization that must be extracted and distributed.

### DNS Records

The following DNS records are configured:

```
192.168.4.63    ipa.vmstation.local ipa
192.168.4.63    vmstation.local
```

### DNS Record Extraction

FreeIPA stores DNS records in `/tmp/ipa.system.records.*.db` files inside the pod. These files are in BIND zone file format.

#### Automatic Extraction

Use the provided script:

```bash
./scripts/extract-freeipa-dns-records.sh -v
```

**Options**:
- `-n, --namespace`: Kubernetes namespace (default: identity)
- `-p, --pod`: FreeIPA pod name (default: freeipa-0)
- `-o, --output`: Output directory (default: /tmp/freeipa-dns-records)
- `-v, --verbose`: Enable verbose output

**Output**:
- DNS record files: `/tmp/freeipa-dns-records/ipa.system.records.*.db`
- Hosts file format: `/tmp/freeipa-dns-records/freeipa-hosts.txt`
- Summary: `/tmp/freeipa-dns-records/extraction-summary.txt`

#### Manual Extraction

```bash
# List DNS record files
kubectl -n identity exec freeipa-0 -- \
  find /tmp -name "ipa.system.records.*.db"

# Extract DNS records
kubectl -n identity exec freeipa-0 -- \
  cat /tmp/ipa.system.records.<timestamp>.db
```

### DNS Record Distribution

#### Automatic Distribution

Use the configuration script:

```bash
./scripts/configure-dns-records.sh
```

**Options**:
- `-f, --file`: DNS records file (default: /tmp/freeipa-dns-records/freeipa-hosts.txt)
- `-b, --backup-suffix`: Backup suffix (default: .pre-freeipa)
- `-d, --dry-run`: Show changes without applying
- `-v, --verbose`: Enable verbose output

#### Manual Distribution

On each cluster node:

```bash
# Backup existing /etc/hosts
sudo cp /etc/hosts /etc/hosts.pre-freeipa

# Add FreeIPA DNS records
sudo tee -a /etc/hosts > /dev/null << 'EOF'
# FreeIPA DNS Records
192.168.4.63    ipa.vmstation.local ipa
192.168.4.63    vmstation.local
EOF

# Verify
getent hosts ipa.vmstation.local
```

### DNS Resolution Methods

#### Method 1: /etc/hosts (Recommended for small clusters)

**Pros**:
- Simple and reliable
- No additional services required
- Works offline
- Fast resolution

**Cons**:
- Manual updates required
- Not suitable for large, dynamic environments

#### Method 2: DNS Server Integration (For larger deployments)

If using a DNS server (CoreDNS, BIND, dnsmasq):

```bash
# Add to DNS zone file
ipa.vmstation.local.    IN  A   192.168.4.63
vmstation.local.        IN  A   192.168.4.63

# Or configure DNS forwarding to FreeIPA
# (requires FreeIPA DNS service enabled)
```

---

## Network Ports Configuration

### Required Ports

#### TCP Ports

| Port | Service | Required For | Priority |
|------|---------|--------------|----------|
| 22 | SSH | Node management | Critical |
| 80 | HTTP | Web services | High |
| 443 | HTTPS | Secure web services | High |
| 389 | LDAP | Directory queries | High |
| 636 | LDAPS | Secure directory queries | High |
| 88 | Kerberos | Authentication | Medium |
| 464 | Kerberos | Password changes | Medium |
| 53 | DNS | Name resolution | Low |

#### UDP Ports

| Port | Service | Required For | Priority |
|------|---------|--------------|----------|
| 88 | Kerberos | Authentication | Medium |
| 464 | Kerberos | Password changes | Medium |
| 53 | DNS | Name resolution | Low |

### Special Requirements

1. **SSH (Port 22)**
   - Must ALWAYS remain open and unrestricted
   - Required for emergency access and management
   - Should never be blocked by firewall rules

2. **Cluster Networks**
   - Allow all traffic from cluster networks:
     - 192.168.4.0/24 (physical network)
     - 10.244.0.0/16 (pod network)
     - 10.96.0.0/12 (service network)

3. **Kubernetes CNI (Calico/Flannel)**
   - Firewall rules must not interfere with CNI operation
   - Use appropriate firewall zones/chains

### Firewall Systems

#### firewalld (RHEL 10)

**Automatic Configuration**:
```bash
./scripts/configure-network-ports.sh
```

**Manual Configuration**:
```bash
# Add TCP ports
for port in 22 80 443 389 636 88 464 53; do
    sudo firewall-cmd --permanent --add-port=${port}/tcp
done

# Add UDP ports
for port in 88 464 53; do
    sudo firewall-cmd --permanent --add-port=${port}/udp
done

# Add services
for service in ssh http https ldap ldaps kerberos dns; do
    sudo firewall-cmd --permanent --add-service=$service
done

# Trust cluster subnets
for subnet in 192.168.4.0/24 10.244.0.0/16 10.96.0.0/12; do
    sudo firewall-cmd --permanent --add-source=$subnet
done

# Reload
sudo firewall-cmd --reload

# Verify
sudo firewall-cmd --list-all
```

#### iptables (Debian 12)

**Automatic Configuration**:
```bash
./scripts/configure-network-ports.sh
```

**Manual Configuration**:
```bash
# Install iptables-persistent for rule persistence
sudo apt-get install -y iptables-persistent

# Add TCP ports
for port in 22 80 443 389 636 88 464 53; do
    sudo iptables -A INPUT -p tcp --dport $port -j ACCEPT
done

# Add UDP ports
for port in 88 464 53; do
    sudo iptables -A INPUT -p udp --dport $port -j ACCEPT
done

# Allow established connections
sudo iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow loopback
sudo iptables -A INPUT -i lo -j ACCEPT

# Allow cluster subnets
for subnet in 192.168.4.0/24 10.244.0.0/16 10.96.0.0/12; do
    sudo iptables -A INPUT -s $subnet -j ACCEPT
done

# Save rules
sudo iptables-save > /etc/iptables/rules.v4

# Verify
sudo iptables -L -n -v
```

### Firewall Integration

#### With Kubernetes CNI

The firewall rules are designed to work with Kubernetes CNI plugins:

1. **Calico**: Uses iptables for policy enforcement
   - Our rules use INPUT chain, Calico uses FORWARD chain
   - No conflicts expected

2. **Flannel**: Uses VXLAN or host-gw for networking
   - Allow pod network subnet (10.244.0.0/16)
   - Allow service network subnet (10.96.0.0/12)

#### With Existing Baseline Hardening

If you have existing baseline hardening:

1. **Review existing rules**: Check for conflicts
   ```bash
   # firewalld
   sudo firewall-cmd --list-all
   
   # iptables
   sudo iptables -L -n -v
   ```

2. **Merge rules**: Combine with existing security rules
3. **Test connectivity**: Verify no services are blocked
4. **Preserve SSH access**: Always ensure port 22 is open

---

## Automated Deployment

### Full Ansible Playbook (Recommended)

Deploy all Step 4a components in one command:

```bash
cd /path/to/cluster-infra

# Standard deployment
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml \
  ansible/playbooks/configure-dns-network-step4a.yml

# With verbose output
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml \
  ansible/playbooks/configure-dns-network-step4a.yml -v

# Dry run (check mode)
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml \
  ansible/playbooks/configure-dns-network-step4a.yml --check

# Specific phases only
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml \
  ansible/playbooks/configure-dns-network-step4a.yml --tags dns

ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml \
  ansible/playbooks/configure-dns-network-step4a.yml --tags firewall
```

### Individual Scripts

For more control or troubleshooting:

```bash
# Step 1: Extract DNS records
./scripts/extract-freeipa-dns-records.sh -v

# Step 2: Configure DNS records
./scripts/configure-dns-records.sh

# Step 3: Configure network ports
./scripts/configure-network-ports.sh

# Step 4: Verify configuration
./scripts/verify-network-ports.sh
./scripts/verify-freeipa-keycloak-readiness.sh
```

---

## Manual Configuration

### Step-by-Step Manual Process

#### 1. Extract DNS Records

```bash
# Connect to FreeIPA pod
kubectl -n identity exec -it freeipa-0 -- bash

# Find DNS record files
find /tmp -name "ipa.system.records.*.db"

# View DNS records
cat /tmp/ipa.system.records.<timestamp>.db

# Exit pod
exit
```

#### 2. Configure DNS on masternode

```bash
# Backup /etc/hosts
sudo cp /etc/hosts /etc/hosts.backup

# Add FreeIPA records
sudo tee -a /etc/hosts > /dev/null << 'EOF'
# FreeIPA DNS Records
192.168.4.63    ipa.vmstation.local ipa
192.168.4.63    vmstation.local
EOF

# Verify
getent hosts ipa.vmstation.local
ping -c 2 ipa.vmstation.local
```

#### 3. Configure DNS on storagenodet3500

```bash
# SSH to node
ssh root@192.168.4.61

# Repeat step 2 commands
```

#### 4. Configure DNS on homelab

```bash
# SSH to node
ssh jashandeepjustinbains@192.168.4.62

# Switch to root
sudo bash

# Repeat step 2 commands
```

#### 5. Configure Firewall on Debian Nodes (masternode, storagenodet3500)

```bash
# Install iptables-persistent
sudo apt-get update
sudo apt-get install -y iptables-persistent

# Configure ports (see iptables section above)
# ...

# Save rules
sudo iptables-save > /etc/iptables/rules.v4
```

#### 6. Configure Firewall on RHEL Node (homelab)

```bash
# Configure ports (see firewalld section above)
# ...

# Reload firewall
sudo firewall-cmd --reload
```

---

## Verification

### Verification Scripts

Run the provided verification scripts:

```bash
# Verify network ports
./scripts/verify-network-ports.sh

# Verify FreeIPA and Keycloak readiness
./scripts/verify-freeipa-keycloak-readiness.sh --verbose

# Test Kerberos (optional)
./scripts/verify-freeipa-keycloak-readiness.sh --test-kerberos
```

### Manual Verification

#### DNS Resolution

```bash
# Test DNS resolution on all nodes
getent hosts ipa.vmstation.local

# Expected output:
# 192.168.4.63    ipa.vmstation.local

# Test ping
ping -c 2 ipa.vmstation.local
```

#### Network Connectivity

```bash
# Test SSH (critical)
nc -zv 192.168.4.63 22

# Test FreeIPA HTTP
nc -zv 192.168.4.63 30088
curl -I http://192.168.4.63:30088

# Test FreeIPA HTTPS
nc -zv 192.168.4.63 30445
curl -kI https://192.168.4.63:30445/ipa/ui

# Test FreeIPA LDAP
nc -zv 192.168.4.63 30389

# Test Keycloak HTTP
nc -zv 192.168.4.63 30180
curl -I http://192.168.4.63:30180/auth/
```

#### Service Readiness

```bash
# Check pod status
kubectl get pods -n identity

# Expected output:
# NAME                   READY   STATUS    RESTARTS   AGE
# freeipa-0              1/1     Running   0          1h
# keycloak-0             1/1     Running   0          1h
# keycloak-postgresql-0  1/1     Running   0          1h

# Check services
kubectl get services -n identity
```

#### Web UI Access

Test in a web browser:

1. **FreeIPA Web UI**:
   - URL: https://192.168.4.63:30445/ipa/ui
   - Expected: FreeIPA login page
   - Accept self-signed certificate warning

2. **Keycloak Admin Console**:
   - URL: http://192.168.4.63:30180/auth/admin/
   - Expected: Keycloak admin login page
   - Credentials in `/root/identity-backup/`

---

## Troubleshooting

### DNS Issues

#### Issue: ipa.vmstation.local does not resolve

**Diagnosis**:
```bash
# Check /etc/hosts
cat /etc/hosts | grep ipa.vmstation.local

# Test with getent
getent hosts ipa.vmstation.local

# Test with nslookup (if available)
nslookup ipa.vmstation.local
```

**Solution**:
```bash
# Re-run DNS configuration
./scripts/configure-dns-records.sh

# Or manually add to /etc/hosts
echo "192.168.4.63    ipa.vmstation.local ipa" | sudo tee -a /etc/hosts
```

#### Issue: DNS records not extracted

**Diagnosis**:
```bash
# Check FreeIPA pod status
kubectl get pod -n identity freeipa-0

# Check pod logs
kubectl logs -n identity freeipa-0 | tail -50

# Exec into pod
kubectl -n identity exec -it freeipa-0 -- bash
find /tmp -name "*.db"
```

**Solution**:
1. Wait for FreeIPA to fully initialize (can take 5-10 minutes)
2. Check if DNS records exist in alternative locations
3. Review FreeIPA initialization logs

### Network Port Issues

#### Issue: Port not accessible

**Diagnosis**:
```bash
# Test port connectivity
nc -zv 192.168.4.63 30088

# Check firewall rules
## firewalld
sudo firewall-cmd --list-all

## iptables
sudo iptables -L -n -v
```

**Solution**:
```bash
# Reconfigure firewall
./scripts/configure-network-ports.sh --force

# Or manually add port (see firewall sections)
```

#### Issue: SSH access lost

**CRITICAL - Immediate action required**:

```bash
# Physical console access required if SSH is blocked

# On the affected node (physical/console access):
## firewalld
sudo firewall-cmd --permanent --add-service=ssh
sudo firewall-cmd --reload

## iptables
sudo iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT
sudo iptables-save > /etc/iptables/rules.v4
```

**Prevention**:
- SSH (port 22) is always included in our scripts
- Test SSH access after firewall changes
- Maintain console/physical access to nodes

### Service Readiness Issues

#### Issue: FreeIPA pod not ready

**Diagnosis**:
```bash
# Check pod status
kubectl get pod -n identity freeipa-0 -o wide

# Check pod logs
kubectl logs -n identity freeipa-0

# Check events
kubectl get events -n identity --sort-by=.metadata.creationTimestamp | grep freeipa
```

**Solution**:
1. FreeIPA initialization can take 5-15 minutes
2. Check persistent volume is mounted correctly
3. Review logs for initialization errors
4. Ensure adequate resources (CPU, memory)

#### Issue: Keycloak not accessible

**Diagnosis**:
```bash
# Check pod status
kubectl get pods -n identity | grep keycloak

# Check service
kubectl get service -n identity keycloak-nodeport

# Test endpoint
curl -I http://192.168.4.63:30180/auth/
```

**Solution**:
1. Verify PostgreSQL is running
2. Check Keycloak logs for database connection errors
3. Verify NodePort service is configured correctly

### Firewall Conflicts

#### Issue: Firewall rules conflict with Kubernetes CNI

**Diagnosis**:
```bash
# Check pod network connectivity
kubectl run test-pod --image=busybox --restart=Never -- ping -c 2 8.8.8.8

# Check iptables FORWARD chain
sudo iptables -L FORWARD -n -v
```

**Solution**:
```bash
# Ensure pod network is allowed
sudo iptables -I FORWARD 1 -s 10.244.0.0/16 -j ACCEPT
sudo iptables -I FORWARD 1 -d 10.244.0.0/16 -j ACCEPT
```

---

## Integration Notes

### Integration with Existing Infrastructure

#### DNS Integration

**Scenario 1: No existing DNS server**
- Use `/etc/hosts` method (recommended for small clusters)
- Scripts automatically configure `/etc/hosts`

**Scenario 2: Existing internal DNS server**
- Extract DNS records using script
- Add records to existing DNS zone
- Configure nodes to use DNS server

**Scenario 3: FreeIPA as primary DNS**
- Enable FreeIPA DNS service (requires reconfiguration)
- Configure nodes to use FreeIPA as DNS server
- Update `/etc/resolv.conf` on all nodes

#### Firewall Integration

**Scenario 1: No existing firewall rules**
- Scripts configure firewall from scratch
- Safe to run

**Scenario 2: Existing baseline hardening**
- Review existing rules first
- Use `--dry-run` to preview changes
- Merge with existing rules
- Test connectivity after changes

**Scenario 3: Centralized firewall management**
- Extract port requirements from scripts
- Configure centralized firewall
- Verify from all cluster nodes

### Compatibility

#### Operating Systems
- ✅ Debian 12 (iptables)
- ✅ RHEL 10 (firewalld)
- ✅ Ubuntu 22.04+ (iptables)
- ✅ CentOS/AlmaLinux 9+ (firewalld)

#### Kubernetes Versions
- ✅ 1.28+
- ✅ 1.29 (tested)
- ✅ 1.30+

#### CNI Plugins
- ✅ Flannel (tested)
- ✅ Calico
- ⚠️ Cilium (may require additional configuration)

---

## Best Practices

### DNS Configuration

1. **Always backup /etc/hosts** before making changes
2. **Use consistent formatting** in DNS records
3. **Document custom DNS entries** separately
4. **Test resolution** from all nodes after changes
5. **Consider DNS server** for larger deployments

### Firewall Configuration

1. **Never block SSH (port 22)** - maintain emergency access
2. **Test connectivity** after each firewall change
3. **Use firewall logging** for troubleshooting
4. **Keep rules organized** with comments
5. **Save rules persistently** (iptables-persistent, firewalld --permanent)

### Security

1. **Use LDAPS (636)** instead of LDAP (389) when possible
2. **Use HTTPS (443)** instead of HTTP (80) for production
3. **Restrict Kerberos ports (88, 464)** to trusted networks only
4. **Monitor firewall logs** for unauthorized access attempts
5. **Regularly review** and audit firewall rules

### Maintenance

1. **Document any manual changes** to DNS or firewall
2. **Version control** firewall rule sets
3. **Test after updates** to OS or Kubernetes
4. **Keep scripts updated** with cluster changes
5. **Regular verification** runs to ensure configuration drift doesn't occur

---

## Reference

### Script Reference

| Script | Purpose | Location |
|--------|---------|----------|
| extract-freeipa-dns-records.sh | Extract DNS from FreeIPA | scripts/ |
| configure-dns-records.sh | Distribute DNS to nodes | scripts/ |
| configure-network-ports.sh | Configure firewall | scripts/ |
| verify-network-ports.sh | Verify port accessibility | scripts/ |
| verify-freeipa-keycloak-readiness.sh | Comprehensive validation | scripts/ |

### Ansible Playbook Reference

| Playbook | Purpose | Tags |
|----------|---------|------|
| configure-dns-network-step4a.yml | Full Step 4a automation | dns, firewall, verify |

### Port Reference

See [Network Ports Configuration](#network-ports-configuration) section for complete port list.

### Command Reference

```bash
# DNS
getent hosts <hostname>
nslookup <hostname>
dig <hostname>

# Network testing
nc -zv <host> <port>
telnet <host> <port>
curl -I http://<host>:<port>

# Firewall
## firewalld
sudo firewall-cmd --list-all
sudo firewall-cmd --get-active-zones
sudo firewall-cmd --reload

## iptables
sudo iptables -L -n -v
sudo iptables-save
sudo iptables-restore

# Kubernetes
kubectl get pods -n identity
kubectl get services -n identity
kubectl logs -n identity <pod-name>
kubectl describe pod -n identity <pod-name>
```

---

## Automated Verification and Recovery

### Overview

The `automate-identity-dns-and-coredns.sh` wrapper script provides comprehensive automation for Steps 4a→5, including:

1. **DNS Record Extraction**: Automatically extracts FreeIPA DNS records from the pod
2. **CoreDNS Configuration**: Runs the Ansible playbook to configure CoreDNS
3. **Readiness Verification**: Validates FreeIPA and Keycloak are ready
4. **Identity & Certificate Verification**: Comprehensive checks of identity stack and certificate distribution

### Usage

#### Full Automation

Run all steps in sequence:

```bash
sudo ./scripts/automate-identity-dns-and-coredns.sh
```

**With verbose output**:
```bash
sudo ./scripts/automate-identity-dns-and-coredns.sh --verbose
```

**With forced cleanup** (removes previous verification results):
```bash
sudo ./scripts/automate-identity-dns-and-coredns.sh --force-cleanup
```

#### Individual Verification Script

For just the comprehensive identity and certificate verification:

```bash
sudo ./scripts/verify-identity-and-certs.sh --verbose
```

### Workspace and Output Files

All verification results are stored in a secure workspace with restricted permissions:

**Workspace Path**: `/opt/vmstation-org/copilot-identity-fixing-automate`

**Permission Model**:
- Workspace directory: `700` (drwx------)
- All result files: `600` (-rw-------)
- Only accessible by root/owner

**Output Files**:

| File | Purpose | Format |
|------|---------|--------|
| `recover_identity_audit.log` | Human-readable audit log with timestamped actions | Text |
| `recover_identity_steps.json` | Structured JSON array of all verification steps | JSON |
| `keycloak_summary.txt` | Keycloak access verification summary | Key=Value |
| `freeipa_summary.txt` | FreeIPA access verification summary | Key=Value |

### Verification Steps Performed

The comprehensive verification script performs the following checks:

#### 1. Preflight Checks
- Verifies presence of required tools: `kubectl`, `curl`, `openssl`, `jq`, `python3`
- Validates kubeconfig file exists
- Exits immediately on missing tools with clear error

#### 2. Workspace Setup
- Creates workspace directory: `/opt/vmstation-org/copilot-identity-fixing-automate`
- Sets restrictive permissions (mode 700)
- Initializes audit log with header information
- Ensures backup directory exists: `/root/identity-backup`

#### 3. Credentials Discovery
- Searches for Keycloak admin credentials in `/root/identity-backup/keycloak-admin-credentials.txt`
- Searches for FreeIPA admin credentials in `/root/identity-backup/freeipa-admin-credentials.txt`
- Detects Helm release secrets (but does not extract passwords)
- Records findings in audit log

#### 4. Keycloak Admin Recovery
The script follows this recovery priority:

**Priority 1: Backup Credentials**
- If credentials exist in backup directory, verification succeeds
- No actual login test performed to avoid exposing credentials
- Summary file records: `method=backup_credentials`, `success=true`

**Priority 2: Add-User Script**
- Checks for `/opt/jboss/keycloak/bin/add-user-keycloak.sh` or `/opt/keycloak/bin/add-user-keycloak.sh`
- If found, logs remediation guidance (script does not execute add-user automatically)
- Summary file records: `method=add_user_required`, `success=false`
- Provides remediation command for operator

**Priority 3: Database Helper Pod**
- Checks for `keycloak-postgresql` secret
- If found, logs that helper pod method is available
- Summary file records: `method=db_helper_pod_required`, `success=false`
- Provides remediation guidance

**Priority 4: Manual Intervention**
- If no recovery method available, records need for manual intervention
- Summary file records: `method=none`, `success=false`

#### 5. FreeIPA Admin Recovery

**Backup Credentials**
- Searches for credentials in `/root/identity-backup/freeipa-admin-credentials.txt`
- If found, verification succeeds
- Summary file records: `method=backup_credentials`, `success=true`

**Recovery Required**
- If no credentials found, logs remediation steps
- Suggests `ipa-server-install` recovery mode or restore from backup
- Summary file records: `method=recovery_required`, `success=false`

#### 6. Certificate and CA Verification

**ClusterIssuer Detection**
- Searches for ClusterIssuer with name matching `freeipa-ca-issuer` or `freeipa-intermediate-issuer`
- Extracts `spec.ca.secretName` from ClusterIssuer

**CA Certificate Fingerprinting**
- Extracts `tls.crt` from ClusterIssuer secret
- Computes SHA256 fingerprint of cert-manager CA certificate
- Extracts CA cert from FreeIPA pod (checks `/etc/ipa/ca.crt`, `/etc/pki/ca-trust/source/anchors/ipa-ca.crt`)
- Computes SHA256 fingerprint of FreeIPA CA certificate

**Fingerprint Comparison**
- Compares ClusterIssuer CA fingerprint with FreeIPA CA fingerprint
- Records MATCH or MISMATCH in audit log
- If mismatch, provides remediation guidance:
  - Option 1: Update ClusterIssuer secret with FreeIPA CA/key
  - Option 2: Create intermediate CA signed by FreeIPA and update ClusterIssuer

**Certificate Test** (optional, not implemented in basic version)
- Future enhancement: Issue temporary test Certificate using ClusterIssuer
- Verify certificate chains to FreeIPA CA using `openssl verify`
- Clean up test resources

#### 7. Key Distribution Check for Keycloak

**PKCS12 Keystore Verification**
- Checks for keystore at `/etc/keycloak/keystore/keycloak.p12`
- Alternative path: `/opt/jboss/keycloak/standalone/configuration/keycloak.p12`
- Records whether keystore is present

**InitContainer Detection**
- If keystore missing, checks if initContainer exists in pod spec
- Looks for initContainer with command referencing `openssl pkcs12`
- If initContainer exists but keystore missing:
  - Logs remediation: "Rolling restart or re-run initContainer"
- If no initContainer found:
  - Logs remediation: "Add initContainer to create keystore from cert"

### Interpreting Audit and JSON Files

#### Audit Log Format

The audit log (`recover_identity_audit.log`) contains:

```
[2024-12-18T18:45:00Z] === PREFLIGHT CHECKS ===
[2024-12-18T18:45:00Z] Preflight checks PASSED
[2024-12-18T18:45:01Z] === WORKSPACE SETUP ===
[2024-12-18T18:45:01Z] Workspace setup complete
[2024-12-18T18:45:02Z] === CREDENTIALS DISCOVERY ===
[2024-12-18T18:45:02Z] Keycloak credentials found: /root/identity-backup/keycloak-admin-credentials.txt
[2024-12-18T18:45:02Z] FreeIPA credentials NOT FOUND in backup
[2024-12-18T18:45:03Z] === KEYCLOAK ADMIN VERIFICATION ===
[2024-12-18T18:45:03Z] Keycloak backup credentials found
...
```

**Key Sections to Review**:
- Look for `FAILED` or `CRITICAL` entries
- Check for `REMEDIATION REQUIRED` messages
- Review `CA MATCH` or `CA MISMATCH` findings
- Note any warnings about missing credentials or keystores

#### JSON Steps Format

The JSON file (`recover_identity_steps.json`) contains structured step data:

```json
[
  {
    "timestamp": "2024-12-18T18:45:00Z",
    "action": "Preflight checks",
    "command": "verify tools and kubeconfig",
    "result": "SUCCESS",
    "note": "All required tools present"
  },
  {
    "timestamp": "2024-12-18T18:45:02Z",
    "action": "Credentials discovery",
    "command": "check keycloak credentials",
    "result": "FOUND",
    "note": "Backup file exists"
  },
  ...
]
```

**Parsing with jq**:

```bash
# View all steps
cat /opt/vmstation-org/copilot-identity-fixing-automate/recover_identity_steps.json | jq .

# Filter failed steps
cat /opt/vmstation-org/copilot-identity-fixing-automate/recover_identity_steps.json | jq '.[] | select(.result == "FAILED")'

# Filter by action
cat /opt/vmstation-org/copilot-identity-fixing-automate/recover_identity_steps.json | jq '.[] | select(.action | contains("Certificate"))'

# Count successes
cat /opt/vmstation-org/copilot-identity-fixing-automate/recover_identity_steps.json | jq '[.[] | select(.result == "SUCCESS")] | length'
```

#### Summary Files Format

**Keycloak Summary** (`keycloak_summary.txt`):

```
method=backup_credentials
username=admin
success=true
message=Backup credentials file exists at /root/identity-backup/keycloak-admin-credentials.txt
```

**FreeIPA Summary** (`freeipa_summary.txt`):

```
method=recovery_required
username=admin
success=false
message=No backup credentials found
remediation=Use ipa-server-install recovery mode or restore from backup
```

**Fields**:
- `method`: How access was verified or should be recovered
- `username`: Admin username
- `success`: Boolean indicating if access is verified
- `message`: Human-readable status message
- `remediation`: (Optional) Steps to remediate if access is not available

### Security Considerations

#### What the Script Does NOT Do

**Never Written to Logs**:
- Raw passwords
- Authentication tokens
- Secret values from Kubernetes secrets
- Private keys

**Never Performed Automatically**:
- Creating new admin passwords (provides guidance only)
- Modifying Kubernetes secrets
- Executing add-user commands (provides commands only)
- Restarting pods (provides guidance only)

#### What the Script DOES Do

**Safe Operations**:
- Read-only checks of pod contents
- Fingerprint computation of public certificates
- File existence checks
- Read credentials from backup files (but doesn't log contents)
- Generate audit logs with sanitized content

**Credential Handling**:
- If script detects that admin password needs to be created, it:
  - Logs the need for password creation
  - Provides the command for operator to run
  - Does NOT generate or set passwords automatically
- If credentials are found in backup:
  - Records the location
  - Does NOT read or log the actual password values

#### Recommendations

1. **Credential Storage**:
   - Store credentials in `/root/identity-backup/` with mode 600
   - After verification, rotate passwords if they were created
   - Store production credentials in Ansible Vault

2. **Intermediate CA**:
   - For production, use intermediate CA signed by FreeIPA
   - Do NOT place FreeIPA root private key into Kubernetes secrets
   - Create intermediate CA with limited lifetime and scope

3. **Audit Log Retention**:
   - Audit logs do not contain secrets but may contain sensitive metadata
   - Retain logs for troubleshooting but rotate/archive regularly
   - Set appropriate access controls (mode 600)

### Cleanup

#### Standard Cleanup

Remove verification workspace (keeps backups):

```bash
rm -rf /opt/vmstation-org/copilot-identity-fixing-automate
```

#### Force Cleanup with Wrapper

Use `--force-cleanup` to backup and remove previous results:

```bash
sudo ./scripts/automate-identity-dns-and-coredns.sh --force-cleanup
```

This will:
- Backup previous workspace to timestamped directory
- Remove DNS records extraction from `/tmp/freeipa-dns-records`
- Start fresh

#### Cleanup DNS Records

```bash
rm -rf /tmp/freeipa-dns-records
```

### Troubleshooting Verification

#### Issue: Script reports missing tools

**Diagnosis**:
```bash
# Check for missing tools
for tool in kubectl curl openssl jq python3; do
  command -v $tool || echo "Missing: $tool"
done
```

**Solution**:
```bash
# Install missing tools (Debian/Ubuntu)
sudo apt-get install -y kubectl curl openssl jq python3

# Install missing tools (RHEL/CentOS)
sudo dnf install -y kubectl curl openssl jq python3
```

#### Issue: Cannot access workspace

**Diagnosis**:
```bash
ls -la /opt/vmstation-org/copilot-identity-fixing-automate
```

**Solution**:
```bash
# Script must be run as root or with sudo
sudo ./scripts/verify-identity-and-certs.sh

# Or change to root
sudo bash
./scripts/verify-identity-and-certs.sh
```

#### Issue: ClusterIssuer not found

**Diagnosis**:
```bash
kubectl get clusterissuer
kubectl get clusterissuer -o name | grep freeipa
```

**Solution**:
- Verify cert-manager is installed: `kubectl get pods -n cert-manager`
- Check if ClusterIssuer was created during identity stack deployment
- Review identity deployment playbook logs

#### Issue: CA fingerprints mismatch

**Diagnosis**:
```bash
# Review audit log
cat /opt/vmstation-org/copilot-identity-fixing-automate/recover_identity_audit.log | grep "CA"
```

**Solution**:

**Option 1: Update ClusterIssuer secret**
```bash
# Extract FreeIPA CA
kubectl -n identity exec freeipa-0 -- cat /etc/ipa/ca.crt > /tmp/freeipa-ca.crt

# Update ClusterIssuer secret (if you have the private key)
kubectl -n cert-manager create secret tls freeipa-ca-secret \
  --cert=/tmp/freeipa-ca.crt \
  --key=/path/to/freeipa-ca.key \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Option 2: Create intermediate CA** (Recommended)
```bash
# Generate intermediate CA signed by FreeIPA
# (requires access to FreeIPA CA signing)
# See cert-manager documentation for intermediate CA setup
```

#### Issue: Keycloak keystore missing

**Diagnosis**:
```bash
# Check Keycloak pod spec for initContainer
kubectl -n identity get pod <keycloak-pod> -o yaml | grep -A 20 initContainers
```

**Solution**:

**If initContainer exists**:
```bash
# Rolling restart to re-run initContainer
kubectl -n identity delete pod <keycloak-pod>
kubectl -n identity wait --for=condition=ready pod/<keycloak-pod> --timeout=300s
```

**If no initContainer**:
- Review Keycloak Helm values or deployment manifest
- Add initContainer to convert certificate to PKCS12 keystore
- See `manifests/identity/` for examples

---

## FAQ

**Q: Do I need to run Step 4a if I'm using a DNS server?**
A: Yes, but you can skip the `/etc/hosts` configuration and add records to your DNS server instead.

**Q: Will these firewall rules interfere with Kubernetes networking?**
A: No, the rules are designed to work with Kubernetes CNI. We explicitly allow cluster networks.

**Q: What if SSH gets blocked?**
A: The scripts are designed to never block SSH (port 22). If it happens, you'll need physical/console access to fix it.

**Q: Can I run Step 4a multiple times?**
A: Yes, all scripts are idempotent and can be safely re-run.

**Q: Do I need to restart any services after configuration?**
A: No, DNS and firewall changes take effect immediately. Pods don't need to be restarted.

**Q: How do I revert the changes?**
A: 
- DNS: Restore `/etc/hosts.pre-freeipa`
- Firewall: Remove rules or restore from backup

**Q: Can I automate Step 4a in CI/CD?**
A: Yes, the Ansible playbook is designed for automation and CI/CD integration.

---

## Support

For issues or questions:

1. Check [Troubleshooting](#troubleshooting) section
2. Review logs: `kubectl logs -n identity <pod-name>`
3. Run verification scripts with `-v` for verbose output
4. Check [DEPLOYMENT_SEQUENCE.md](DEPLOYMENT_SEQUENCE.md)
5. Review [IDENTITY-SSO-SETUP.md](IDENTITY-SSO-SETUP.md)

---

*Document Version: 1.1*  
*Last Updated: 2024-12-18*  
*Part of VMStation Cluster Infrastructure*
