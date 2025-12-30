# Deployment Issue Resolution Summary

This document catalogs common identity stack deployment issues and their automated resolutions.

## Table of Contents

1. [Pod→ClusterIP DNS Failures](#pod-clusterip-dns-failures)
2. [IPVS State Issues](#ipvs-state-issues)
3. [kube-proxy Service CIDR Mismatches](#kube-proxy-service-cidr-mismatches)
4. [iptables/nftables Backend Conflicts](#iptablesnftables-backend-conflicts)
5. [Network Sysctl and Module Issues](#network-sysctl-and-module-issues)

---

## Pod→ClusterIP DNS Failures

### Symptom
- DNS validation pod fails with connection timeout
- Services not reachable from pods via ClusterIP
- CoreDNS logs show no queries received
- Grafana/Prometheus cannot resolve services

### Root Causes

#### 1. ip_forward Disabled

**Cause:** `net.ipv4.ip_forward` is set to 0, preventing packet forwarding between interfaces.

**Impact:** Pods cannot reach services outside their local node.

**Detection:**
```bash
sysctl net.ipv4.ip_forward
# Output: net.ipv4.ip_forward = 0 (BAD)
```

**Automated Fix:**
- Task: `ensure-sysctls-and-modules.yml`
- Sets `net.ipv4.ip_forward=1` in `/etc/sysctl.d/k8s.conf`
- Applies with `sysctl --system`

**Manual Fix:**
```bash
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.d/k8s.conf
sysctl --system
```

#### 2. br_netfilter Module Not Loaded

**Cause:** `br_netfilter` kernel module not loaded, preventing bridge netfilter hooks.

**Impact:** iptables rules for bridged traffic not applied (CNI traffic blocked).

**Detection:**
```bash
lsmod | grep br_netfilter
# Output: (empty) - module not loaded
```

**Automated Fix:**
- Task: `ensure-sysctls-and-modules.yml`
- Loads module with `modprobe br_netfilter`
- Adds to `/etc/modules-load.d/k8s.conf` for persistence

**Manual Fix:**
```bash
modprobe br_netfilter
echo "br_netfilter" >> /etc/modules-load.d/k8s.conf
```

#### 3. iptables FORWARD Chain Policy DROP

**Cause:** iptables FORWARD chain default policy is DROP without CNI accept rules.

**Impact:** All forwarded traffic (including pod→service) is blocked.

**Detection:**
```bash
iptables -L FORWARD -n -v | head -1
# Output: Chain FORWARD (policy DROP ...)
iptables -L KUBE-FORWARD -n 2>/dev/null
# Output: iptables: No chain/target/match by that name
```

**Automated Fix:**
- Task: `iptables-remediation.yml`
- Detects missing CNI chains
- Recommends Calico/kube-proxy restart
- Restart triggered via handlers

**Manual Fix:**
```bash
kubectl -n kube-system rollout restart daemonset/calico-node
kubectl -n kube-system rollout restart daemonset/kube-proxy
```

#### 4. Stale IPVS Mappings (iptables mode)

**Cause:** kube-proxy switched from IPVS to iptables mode, but IPVS kernel state persists.

**Impact:** Packets routed via stale IPVS rules instead of iptables KUBE-SERVICES chain.

**Detection:**
```bash
# Check kube-proxy mode
kubectl -n kube-system get configmap kube-proxy -o yaml | grep mode
# Output: mode: "iptables"

# Check for IPVS modules
lsmod | grep ip_vs
# Output: ip_vs ... (module loaded)

# Check IPVS table
ipvsadm -Ln
# Output: (shows virtual/real servers - stale entries)
```

**Automated Fix:**
- Task: `ipvs-remediation.yml`
- Detects mode mismatch
- Flushes IPVS table with `ipvsadm -C`
- Restarts kube-proxy to reprogram iptables

**Manual Fix:**
```bash
ipvsadm -C
kubectl -n kube-system rollout restart daemonset/kube-proxy
```

---

## IPVS State Issues

### Symptom
- KUBE-SERVICES chain shows zero packet counters
- Services unreachable despite correct iptables rules
- `ipvsadm -Ln` shows stale virtual servers

### Root Cause
kube-proxy mode changed from IPVS to iptables, but kernel IPVS state not cleared.

### Automated Resolution

**Playbook:** `fix-ipvs.yml` or via `network-remediation` role

**Steps:**
1. Detect kube-proxy configured mode from ConfigMap
2. Check if `ip_vs` kernel modules loaded
3. If mode=iptables and IPVS modules present:
   - Install `ipvsadm` (if not present)
   - Dump current IPVS table (for diagnostics)
   - Flush IPVS table: `ipvsadm -C`
   - Restart kube-proxy DaemonSet
   - Wait for rollout completion
   - Verify IPVS table is empty

**Idempotency:** Safe to run multiple times. No-op if not needed.

**Backup:** No backup needed (IPVS state is transient).

---

## kube-proxy Service CIDR Mismatches

### Symptom
- KUBE-SERVICES iptables chain exists but has zero packet counters
- Services defined but iptables rules missing or incorrect
- kube-proxy logs show no errors but services don't work

### Root Cause
kube-proxy ConfigMap `clusterCIDR` doesn't match `kube-apiserver --service-cluster-ip-range`.

This causes kube-proxy to program iptables rules for the wrong CIDR, so actual service IPs don't match.

### Detection

**Automated:**
- Playbook: `fix-kubeproxy-servicecidr.yml`
- Extracts `--service-cluster-ip-range` from apiserver pod spec
- Compares with `clusterCIDR` in kube-proxy ConfigMap

**Manual:**
```bash
# Get apiserver service CIDR
kubectl -n kube-system get pod -l component=kube-apiserver -o yaml | grep service-cluster-ip-range
# Output: - --service-cluster-ip-range=10.233.0.0/18

# Get kube-proxy CIDR
kubectl -n kube-system get configmap kube-proxy -o yaml | grep clusterCIDR
# Output: clusterCIDR: "10.96.0.0/12"  (MISMATCH!)
```

### Automated Resolution

**Playbook:** `fix-kubeproxy-servicecidr.yml`

**Steps:**
1. Detect apiserver `--service-cluster-ip-range`
2. Extract kube-proxy ConfigMap `clusterCIDR`
3. Compare values
4. If mismatch:
   - Backup current ConfigMap to `/root/identity-backup/kube-proxy-configmap-backup-<timestamp>.yaml`
   - Patch ConfigMap with correct CIDR
   - Annotate kube-proxy DaemonSet to force pod restart
   - Restart kube-proxy DaemonSet
   - Wait for rollout completion
   - Verify KUBE-SERVICES chain now has packet counters

**Idempotency:** Safe to run multiple times. No-op if CIDRs match.

**Rollback:**
```bash
kubectl apply -f /root/identity-backup/kube-proxy-configmap-backup-*.yaml
kubectl -n kube-system rollout restart daemonset/kube-proxy
```

---

## iptables/nftables Backend Conflicts

### Symptom
- iptables rules look correct but don't work
- kube-proxy logs show no errors
- Packet counters on rules are zero

### Root Cause
Mixed iptables backends: system using nftables but kube-proxy using legacy iptables (or vice versa).

### Detection

```bash
# Check iptables backend
iptables --version
# Output: iptables v1.8.7 (nf_tables) or iptables v1.8.7 (legacy)

# Check which iptables binaries are in use
update-alternatives --display iptables  # Debian/Ubuntu
alternatives --display iptables         # RHEL/CentOS
```

### Automated Detection

**Task:** `iptables-remediation.yml`

- Detects iptables backend (nft vs legacy)
- Logs backend type for diagnostics
- Checks for KUBE-SERVICES chain and counters
- Warns if backend mismatch suspected

### Resolution

**Manual (requires host access):**

**Switch to legacy mode:**
```bash
# Debian/Ubuntu
update-alternatives --set iptables /usr/sbin/iptables-legacy
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

# RHEL/CentOS
alternatives --set iptables /usr/sbin/iptables-legacy
```

**Switch to nft mode:**
```bash
update-alternatives --set iptables /usr/sbin/iptables-nft
update-alternatives --set ip6tables /usr/sbin/ip6tables-nft
```

**After switch:**
```bash
# Restart kube-proxy to reprogram rules
kubectl -n kube-system rollout restart daemonset/kube-proxy
kubectl -n kube-system rollout restart daemonset/calico-node  # if using Calico
```

---

## Network Sysctl and Module Issues

### Symptom
- Intermittent pod→pod connectivity
- Bridge traffic not filtered
- Packets not forwarded correctly

### Root Causes

#### Missing Sysctl Settings

**Required sysctls:**
- `net.ipv4.ip_forward=1`
- `net.bridge.bridge-nf-call-iptables=1`
- `net.bridge.bridge-nf-call-ip6tables=1`

**Automated Fix:**
- Task: `ensure-sysctls-and-modules.yml`
- Sets all required sysctls in `/etc/sysctl.d/k8s.conf`
- Reloads with `sysctl --system`

#### Missing Kernel Modules

**Required modules:**
- `br_netfilter`
- `overlay` (for container storage)

**Automated Fix:**
- Task: `ensure-sysctls-and-modules.yml`
- Loads modules with `modprobe`
- Adds to `/etc/modules-load.d/k8s.conf` for persistence

---

## Remediation Workflow

The network-remediation role implements this automated workflow:

```
1. Validate pod→ClusterIP DNS connectivity
   ↓ FAIL
2. Attempt 1/3: Remediation
   - Detect kube-proxy mode
   - Ensure sysctls and modules
   - Clear IPVS (if needed)
   - Check iptables rules
   - Restart kube-proxy
   ↓
3. Re-validate connectivity
   ↓ FAIL
4. Collect diagnostics
   ↓
5. Attempt 2/3: Remediation (repeat)
   ↓
6. Re-validate connectivity
   ↓ FAIL
7. Collect diagnostics
   ↓
8. Attempt 3/3: Remediation (repeat)
   ↓
9. Re-validate connectivity
   ↓ FAIL
10. Final diagnostics collection and archival
11. Fail with actionable error message
```

### Diagnostics Collection

**Location:** `/tmp/network-diagnostics/`  
**Archive:** `/root/identity-backup/network-diagnostics-<timestamp>.tar.gz`

**Contents:**
- Cluster-wide diagnostics:
  - CoreDNS deployment and pod status
  - kube-dns Service and Endpoints
  - kube-proxy DaemonSet and pod status
  - kube-proxy and CoreDNS logs (last 500 lines)
  - kube-proxy ConfigMap
  - kube-system Services

- Per-node diagnostics:
  - Sysctl settings (ip_forward, bridge-nf-call-*)
  - Loaded kernel modules (br_netfilter, ip_vs)
  - iptables rules (nat, filter tables)
  - IPVS table (if applicable)
  - Network interfaces and routes
  - DNS resolver configuration

---

## Testing Remediation

### Test Individual Components

```bash
# Test network remediation only
ansible-playbook ansible/playbooks/02-remediate-network-gate.yml

# Test IPVS cleanup
ansible-playbook ansible/playbooks/fix-ipvs.yml

# Test service CIDR fix
ansible-playbook ansible/playbooks/fix-kubeproxy-servicecidr.yml
```

### Test Full Deployment

```bash
# Run full staged deployment
ansible-playbook ansible/playbooks/01-validate-cluster.yml
ansible-playbook ansible/playbooks/02-remediate-network-gate.yml
ansible-playbook ansible/playbooks/03-deploy-db.yml
ansible-playbook ansible/playbooks/05-deploy-keycloak.yml
ansible-playbook ansible/playbooks/06-verify-and-handover.yml
```

### Test Idempotency

```bash
# Verify all steps are idempotent
ansible-playbook ansible/playbooks/test-idempotency.yml
```

---

## Related Documentation

- [Deployment Runbook](DEPLOYMENT_RUNBOOK.md) - Complete deployment guide
- [Network Remediation Verification](../VERIFY_NETWORK_REMEDIATION.md) - Detailed verification steps
- [FreeIPA Networking](NOTE_FREEIPA_NETWORKING.md) - FreeIPA-specific networking issues

---

**Document Version:** 1.0  
**Last Updated:** 2025-12-30  
**Maintained By:** VMStation Infrastructure Team
