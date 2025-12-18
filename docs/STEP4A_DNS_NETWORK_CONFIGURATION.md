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

### Automated Wrapper Script (Quickest Method)

The automated wrapper script provides a single command to extract FreeIPA DNS records, configure CoreDNS, and verify readiness:

```bash
cd /path/to/cluster-infra

# Standard run (recommended)
./scripts/automate-identity-dns-and-coredns.sh

# With automatic cleanup before redeploy
FORCE_CLEANUP=1 ./scripts/automate-identity-dns-and-coredns.sh
```

**What this script does:**
1. **Optional Cleanup** (only if `FORCE_CLEANUP=1`): Runs the cleanup script to remove existing identity stack resources
2. **Extract DNS Records**: Automatically extracts FreeIPA DNS records from the pod
3. **Configure CoreDNS**: Runs the Ansible playbook `configure-coredns-freeipa.yml` to update CoreDNS configuration
4. **Verify Readiness**: Checks that FreeIPA and Keycloak are ready and accessible

**FORCE_CLEANUP Option:**
- Set `FORCE_CLEANUP=1` to automatically run `cleanup-identity-stack.sh` before extracting DNS records
- Useful when redeploying the identity stack from scratch
- **Warning**: This will delete all identity stack resources (pods, PVCs, PVs, data)
- Only use when you want a complete fresh deployment

**Examples:**
```bash
# First-time setup (no cleanup needed)
./scripts/automate-identity-dns-and-coredns.sh

# Redeploy with cleanup
FORCE_CLEANUP=1 ./scripts/automate-identity-dns-and-coredns.sh

# Check if script components exist
ls -la scripts/extract-freeipa-dns-records.sh
ls -la scripts/verify-freeipa-keycloak-readiness.sh
ls -la ansible/playbooks/configure-coredns-freeipa.yml
```

### Full Ansible Playbook (Alternative Method)

Deploy all Step 4a components using the complete Ansible playbook:

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

*Document Version: 1.0*  
*Last Updated: 2024-12-16*  
*Part of VMStation Cluster Infrastructure*
