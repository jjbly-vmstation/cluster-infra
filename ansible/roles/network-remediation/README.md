# Network Remediation Role

## Overview

The `network-remediation` role provides automated network validation, diagnostics, and remediation for Kubernetes clusters experiencing DNS/Service connectivity issues.

## Features

- **Pod-to-ClusterIP DNS Validation**: Tests DNS resolution from ephemeral pods to kube-dns ClusterIP
- **Automatic Remediation**: Fixes common network issues on cluster nodes:
  - Enables `ip_forward`
  - Fixes iptables FORWARD chain policy
  - Loads `br_netfilter` kernel module
  - Clears stale IPVS state (when using iptables mode)
  - Restarts kube-proxy
- **Comprehensive Diagnostics**: Collects cluster and node-level network state
- **Idempotent**: Safe to run multiple times
- **Retry Logic**: Attempts validation -> remediation -> validation cycle

## Usage

### Basic Usage

```yaml
- hosts: localhost
  roles:
    - network-remediation
```

### With Custom Configuration

```yaml
- hosts: localhost
  roles:
    - role: network-remediation
      vars:
        remediation_enabled: true
        remediation_max_attempts: 3
        diagnostics_enabled: true
        dns_validation_timeout: 60
```

### Integration in Identity Stack

The role is integrated into the identity deployment playbook and runs before deploying PostgreSQL/FreeIPA/Keycloak to ensure network connectivity is working.

## Variables

### DNS Validation
- `dns_validation_timeout`: Timeout for validation pod (default: `60`)
- `dns_validation_retries`: Number of retries (default: `3`)
- `dns_validation_pod_image`: Container image for validation (default: `nicolaka/netshoot:latest`)
- `dns_validation_namespace`: Namespace for validation pod (default: `kube-system`)

### Remediation
- `remediation_enabled`: Enable automatic remediation (default: `true`)
- `remediation_fix_ip_forward`: Fix ip_forward setting (default: `true`)
- `remediation_fix_iptables`: Fix iptables FORWARD chain (default: `true`)
- `remediation_fix_br_netfilter`: Load br_netfilter module (default: `true`)
- `remediation_restart_kube_proxy`: Restart kube-proxy after fixes (default: `true`)
- `remediation_max_attempts`: Maximum remediation attempts (default: `3`)
- `remediation_retry_delay`: Delay between retries in seconds (default: `10`)

### Diagnostics
- `diagnostics_enabled`: Enable diagnostics collection (default: `true`)
- `diagnostics_base_dir`: Directory for diagnostic files (default: `/tmp/network-diagnostics`)
- `diagnostics_archive_dir`: Archive location (default: `/root/identity-backup`)
- `diagnostics_retention_days`: Days to keep old diagnostics (default: `7`)

### Other
- `kubeconfig`: Path to kubeconfig (default: `/etc/kubernetes/admin.conf`)
- `ipvs_cleanup_enabled`: Clear IPVS state in iptables mode (default: `true`)

## Tasks

### Main Tasks (`tasks/main.yml`)
Orchestrates the validation and remediation workflow.

### Validation (`tasks/validate-pod-to-clusterip.yml`)
- Creates ephemeral pod in cluster
- Tests DNS resolution to kube-dns ClusterIP
- Validates connectivity to `kubernetes.default.svc.cluster.local`

### Remediation Loop (`tasks/remediation-loop.yml`)
- Attempts validation
- On failure: collects diagnostics, runs remediation, retries
- Fails after max attempts with actionable error message

### kube-proxy Mode Detection (`tasks/detect-proxier-mode.yml`)
- Reads kube-proxy ConfigMap
- Extracts configured mode (iptables vs ipvs)
- Sets `proxier_mode` fact for use in remediation tasks

### Sysctl and Modules (`tasks/ensure-sysctls-and-modules.yml`)
Ensures required kernel settings and modules:
- Loads `br_netfilter` kernel module
- Sets `net.ipv4.ip_forward=1`
- Sets `net.bridge.bridge-nf-call-iptables=1`
- Sets `net.bridge.bridge-nf-call-ip6tables=1`
- Persists configuration across reboots

### IPVS Remediation (`tasks/ipvs-remediation.yml`)
- Detects IPVS modules loaded
- Determines if cleanup is needed (iptables mode + IPVS modules)
- Installs `ipvsadm` if needed
- Flushes IPVS table with `ipvsadm -C`
- Triggers kube-proxy restart via handler

### iptables Remediation (`tasks/iptables-remediation.yml`)
- Detects iptables backend (legacy vs nft)
- Checks FORWARD chain policy
- Validates KUBE-SERVICES chain exists and has traffic
- Checks for MASQUERADE rules
- Validates CNI-specific chains (KUBE-FORWARD, cali-FORWARD)
- Provides diagnostics and warnings

### Node Remediation (`tasks/remediate-node-network.yml`)
Orchestrates remediation on all cluster nodes:
- Detects kube-proxy mode
- Runs per-node remediation tasks
- Restarts kube-proxy DaemonSet

### Per-Node Remediation (`tasks/remediate-node-network-per-node.yml`)
Delegates to modular task files for each node:
- Calls `ensure-sysctls-and-modules.yml`
- Calls `iptables-remediation.yml`
- Calls `ipvs-remediation.yml` (if enabled)

### Diagnostics Collection (`tasks/diagnose-and-collect.yml`)
Collects:
- CoreDNS deployment/pods/logs
- kube-dns Service/Endpoints
- kube-proxy DaemonSet/pods/logs/ConfigMap
- Node-level: sysctls, iptables rules, IPVS state, network interfaces, routes
- Archives diagnostics to tar.gz

### Node Diagnostics Collection (`tasks/collect-node-diagnostics.yml`)
Per-node diagnostics collection:
- Sysctl settings
- Kernel modules
- iptables rules (all tables)
- IPVS state
- Network interfaces and routes
- DNS resolver configuration

## Handlers

### `restart kube-proxy`
Restarts the kube-proxy DaemonSet by performing a rollout restart.

### `wait for kube-proxy rollout`
Waits for the kube-proxy rollout to complete with 180-second timeout.

### `restart calico-node`
Restarts the calico-node DaemonSet (if Calico CNI is in use).

### `wait for calico rollout`
Waits for the calico-node rollout to complete with 180-second timeout.

Handlers are triggered automatically when remediation tasks make changes that require service restarts.

## Diagnostics Output

### Cluster Diagnostics
Location: `{{ diagnostics_base_dir }}/cluster-diagnostics-<timestamp>.txt`

Contains:
- CoreDNS deployment status
- kube-dns Service and Endpoints
- kube-proxy configuration
- Component logs

### Node Diagnostics
Location: `{{ diagnostics_base_dir }}/node-<hostname>-<timestamp>.txt`

Contains per-node:
- ip_forward setting
- br_netfilter status
- iptables rules (FORWARD, NAT)
- IPVS state
- Network interfaces and routes
- DNS resolution tests

### Archive
Location: `{{ diagnostics_archive_dir }}/network-diagnostics-<timestamp>.tar.gz`

## Dependencies

None. This is a standalone role.

## Example Playbook

```yaml
---
- name: Network remediation example
  hosts: localhost
  connection: local
  gather_facts: true
  roles:
    - role: network-remediation
      vars:
        remediation_enabled: true
        remediation_max_attempts: 3
        diagnostics_enabled: true
```

## Troubleshooting

### Validation Fails After Remediation

If validation continues to fail after remediation:

1. Check diagnostics archive: `/root/identity-backup/network-diagnostics-*.tar.gz`
2. Review cluster-diagnostics and node-diagnostics files
3. Common issues:
   - CNI plugin not functioning
   - NetworkPolicy blocking traffic
   - Node-to-node connectivity issues
   - Custom firewall rules

### Manual Verification

```bash
# Check ip_forward on nodes
ansible all -m shell -a "sysctl net.ipv4.ip_forward"

# Check iptables FORWARD policy
ansible all -m shell -a "iptables -L FORWARD -n | head -1"

# Check kube-proxy logs
kubectl -n kube-system logs daemonset/kube-proxy --tail=100

# Test DNS from a pod
kubectl run dns-test --image=nicolaka/netshoot --rm -it -- \
  dig @10.96.0.10 kubernetes.default.svc.cluster.local
```

## License

MIT

## Author

VMStation Copilot
