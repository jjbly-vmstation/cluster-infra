# VMStation Ansible Playbooks

This directory contains all Ansible playbooks for VMStation Kubernetes cluster deployment and management.

## Playbook Overview

### Deployment Playbooks

#### `deploy-cluster.yaml`
**Purpose**: Deploy Kubernetes cluster on Debian nodes using kubeadm  
**Target Hosts**: `monitoring_nodes`, `storage_nodes` (Debian Bookworm)  
**Phases**:
- Phase 0: System Preparation - Install Kubernetes binaries, configure containerd
- Phase 1: Control Plane Initialization - Initialize kubeadm on master node
- Phase 2: Control Plane Validation - Verify API server and control plane pods
- Phase 3: Token Generation - Create join tokens for workers
- Phase 4: Worker Node Join - Join worker nodes with comprehensive error handling
- Phase 5: CNI Deployment - Deploy Flannel networking
- Phase 6: Cluster Validation - Verify all nodes Ready and pods running
- Phase 7: Application Deployment - Deploy monitoring stack (Prometheus, Grafana)

**Usage**:
```bash
./deploy.sh debian           # Via wrapper script
# OR
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml ansible/playbooks/deploy-cluster.yaml
```

**Idempotency**: ✅ Safe to run multiple times
- Checks if control plane already initialized
- Checks if workers already joined
- Handles partial states and cleanup

#### `install-rke2-homelab.yml`
**Purpose**: Deploy RKE2 on homelab RHEL10 node  
**Target Hosts**: `compute_nodes` (homelab - RHEL 10)  
**Features**:
- Downloads and installs RKE2
- Configures Flannel CNI
- Enables RKE2 server service
- Fetches kubeconfig to local artifacts directory

**Usage**:
```bash
./deploy.sh rke2             # Via wrapper script
# OR
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml ansible/playbooks/install-rke2-homelab.yml
```

**Idempotency**: ✅ Safe to run multiple times - skips if already installed

#### `configure-homelab-monitoring.yml`
**Purpose**: Configure promtail and node-exporter on homelab RKE2 cluster to forward logs and metrics to masternode  
**Target Hosts**: `compute_nodes` (homelab - RHEL 10)  
**Features**:
- Deploys Promtail DaemonSet to forward logs to masternode Loki
- Deploys Node Exporter for metric collection
- Configures external labels for cluster identification
- Tests connectivity to masternode Loki

**Usage**:
```bash
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml ansible/playbooks/configure-homelab-monitoring.yml
```

**Prerequisites**: RKE2 must be installed (run `install-rke2-homelab.yml` first)

**Idempotency**: ✅ Safe to run multiple times


### Cleanup Playbooks

#### `reset-cluster.yaml`
**Purpose**: Comprehensive cluster reset - removes all Kubernetes configuration  
**Target Hosts**: `monitoring_nodes`, `storage_nodes`  
**Actions**:
- Runs `kubeadm reset -f`
- Stops kubelet and containerd services
- Kills hanging processes
- Removes Kubernetes directories
- Removes CNI network interfaces
- Flushes iptables rules
- Restarts containerd

**Usage**:
```bash
./deploy.sh reset            # Via wrapper script
# OR
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml ansible/playbooks/reset-cluster.yaml
```

**Idempotency**: ✅ Safe to run multiple times - handles missing files/services gracefully

#### `uninstall-rke2-homelab.yml`
**Purpose**: Remove RKE2 from homelab node  
**Target Hosts**: `compute_nodes` (homelab)  
**Actions**:
- Runs RKE2 uninstall script
- Removes RKE2 directories
- Cleans environment configuration

**Usage**:
```bash
# Called automatically by ./deploy.sh reset
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml ansible/playbooks/uninstall-rke2-homelab.yml
```

#### `cleanup-homelab.yml`
**Purpose**: Cleanup homelab node before RKE2 reset  
**Target Hosts**: `compute_nodes` (homelab)  
**Actions**:
- Stops RKE2 server service
- Kills RKE2 processes
- Removes RKE2 network interfaces

**Usage**:
```bash
# Called automatically by ./deploy.sh rke2 (pre-flight check)
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml ansible/playbooks/cleanup-homelab.yml
```

### Operational Playbooks

#### `fix-loki-config.yaml`
**Purpose**: Fix Loki ConfigMap drift and permission issues  
**Target Hosts**: `monitoring_nodes`  
**Actions**:
- Reapplies Loki manifest from repository to sync ConfigMap
- Ensures `/srv/monitoring_data/loki` has proper ownership (UID 10001)
- Restarts Loki deployment to pick up changes
- Validates Loki becomes ready

**Usage**:
```bash
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml ansible/playbooks/fix-loki-config.yaml
```

**When to use**:
- Loki pods in CrashLoopBackOff with config parse errors
- After detecting ConfigMap drift with `./tests/test-loki-config-drift.sh`
- After manual repository changes to Loki configuration
- As part of routine maintenance to prevent drift

**Idempotency**: ✅ Safe to run multiple times

See [LOKI_CONFIG_DRIFT_PREVENTION.md](../../docs/LOKI_CONFIG_DRIFT_PREVENTION.md) for details.

#### `spin-down-cluster.yaml`
**Purpose**: Gracefully shut down cluster workloads without powering off  
**Target Hosts**: `monitoring_nodes`  
**Actions**:
- Cordons all nodes (prevents new pods)
- Drains worker nodes (evicts pods)
- Scales deployments to zero replicas
- Removes CNI network interfaces

**Usage**:
```bash
./deploy.sh spindown         # Via wrapper script
# OR
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml ansible/playbooks/spin-down-cluster.yaml
```

**Note**: Does NOT power off nodes - use this before manual shutdown

#### `setup-autosleep.yaml`
**Purpose**: Configure automatic cluster sleep after inactivity  
**Target Hosts**: `monitoring_nodes`  
**Features**:
- Creates monitoring script that checks for active pods
- Triggers sleep after 2 hours of inactivity
- Installs systemd timer to run every 15 minutes

**Usage**:
```bash
./deploy.sh setup            # Via wrapper script
# OR
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml ansible/playbooks/setup-autosleep.yaml
```

**Configuration**:
- Monitor: `/usr/local/bin/vmstation-autosleep-monitor.sh`
- Sleep script: `/usr/local/bin/vmstation-sleep.sh`
- Timer: `vmstation-autosleep.timer`

### Testing Playbooks

#### `verify-cluster.yaml`
**Purpose**: Verify cluster health and readiness  
**Target Hosts**: `monitoring_nodes`  
**Checks**:
- API server accessibility (port 6443)
- Node Ready status (expects ≥2 nodes)
- CoreDNS pods running
- Flannel pods running
- Basic pod creation/deletion test

**Usage**:
```bash
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml ansible/playbooks/verify-cluster.yaml
```

**Exit Codes**:
- 0: Cluster is healthy
- 1: Cluster verification failed

### Identity Stack Playbooks

#### `identity-deploy-and-handover.yml`
**Purpose**: Deploy FreeIPA, Keycloak, PostgreSQL, and cert-manager for identity management  
**Target Hosts**: `localhost` (runs kubectl commands on control plane)  
**Components Deployed**:
- PostgreSQL StatefulSet (database for Keycloak)
- Keycloak StatefulSet (SSO and OIDC provider)
- FreeIPA StatefulSet (LDAP, Kerberos, CA)
- cert-manager (automated TLS certificates)
- Administrator accounts and credentials

**Usage**:
```bash
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml
```

**Idempotency**: ✅ Safe to run multiple times
**Documentation**: See [IDENTITY-SSO-SETUP.md](../../docs/IDENTITY-SSO-SETUP.md)

#### `configure-coredns-freeipa.yml`
**Purpose**: Configure CoreDNS with FreeIPA DNS records for identity stack integration  
**Target Hosts**: `localhost` for CoreDNS config, optionally `all` for /etc/hosts fallback  
**Phases**:
- Phase 1: Validate prerequisites (kubectl, kubeconfig, FreeIPA pod)
- Phase 1.5: Check CoreDNS installation and install if needed (auto-installs for Calico CNI clusters)
- Phase 2: Extract DNS records from FreeIPA pod
- Phase 3: Update CoreDNS ConfigMap with FreeIPA hostnames
- Phase 4: Restart CoreDNS and validate DNS resolution
- Phase 5: Optional /etc/hosts fallback configuration on all nodes

**Usage**:
```bash
# Configure CoreDNS only
ansible-playbook -i inventory/mycluster/hosts.yaml \
  ansible/playbooks/configure-coredns-freeipa.yml

# Configure CoreDNS + /etc/hosts fallback on all nodes
ansible-playbook -i inventory/mycluster/hosts.yaml \
  ansible/playbooks/configure-coredns-freeipa.yml \
  --tags all,hosts-fallback
```

**Features**:
- **Auto-installs CoreDNS** if not present (handles Calico CNI clusters automatically)
- Detects cluster DNS service IP and configures CoreDNS accordingly
- Extracts DNS records from FreeIPA pod (`/tmp/ipa.system.records.*.db`)
- Parses A records for hostname → IP mappings
- Backs up existing CoreDNS ConfigMap before changes
- Updates CoreDNS with `hosts` plugin section for FreeIPA hostnames
- Restarts CoreDNS pods to pick up configuration
- Validates DNS resolution from within cluster using busybox test pod
- Optionally configures /etc/hosts on all cluster nodes as fallback

**Prerequisites**:
- Identity stack deployed (`identity-deploy-and-handover.yml`)
- FreeIPA pod running and ready in `identity` namespace
- kubectl access with `/etc/kubernetes/admin.conf`

**Idempotency**: ✅ Safe to run multiple times - skips if hosts section already exists

**When to use**:
- After deploying the identity stack (Step 4a in deployment sequence)
- When FreeIPA hostname resolution is needed cluster-wide
- Before deploying infrastructure services or monitoring stack
- To enable Keycloak-FreeIPA LDAP integration

**Related Playbooks**:
- `configure-dns-network-step4a.yml` - Full DNS and network port configuration
- `identity-deploy-and-handover.yml` - Identity stack deployment

#### `configure-dns-network-step4a.yml`
**Purpose**: Comprehensive DNS and network port configuration for FreeIPA/Keycloak  
**Target Hosts**: `all` cluster nodes  
**Phases**:
- Phase 1: Extract DNS records from FreeIPA pod
- Phase 2: Distribute DNS records to all nodes via /etc/hosts
- Phase 3: Configure firewall rules (firewalld/iptables)
- Phase 4: Verify configuration

**Usage**:
```bash
ansible-playbook -i inventory/mycluster/hosts.yaml \
  ansible/playbooks/configure-dns-network-step4a.yml
```

**Features**:
- Configures DNS via /etc/hosts (traditional approach)
- Configures firewall ports for FreeIPA/Keycloak (TCP: 22, 80, 443, 389, 636, 88, 464, 53; UDP: 88, 464, 53)
- Supports both firewalld (RHEL) and iptables (Debian)
- Trusts cluster network subnets
- Comprehensive verification

**Idempotency**: ✅ Safe to run multiple times

## Deployment Workflow

### Initial Deployment
```bash
# 1. Deploy Debian cluster (control plane + worker)
./deploy.sh debian

# 2. Verify Debian cluster
kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes

# 3. Deploy RKE2 on homelab
./deploy.sh rke2

# 4. Verify RKE2 cluster
kubectl --kubeconfig=ansible/artifacts/rke2-kubeconfig.yaml get nodes
```

### Two-Phase Deployment (All at Once)
```bash
./deploy.sh all --with-rke2 --yes
```

### Reset and Redeploy
```bash
# Reset everything
./deploy.sh reset

# Redeploy
./deploy.sh all --with-rke2 --yes
```

### Idempotency Testing
```bash
# Run multiple times - should work without errors
for i in {1..5}; do
  ./deploy.sh reset
  ./deploy.sh all --with-rke2 --yes
done
```

## Error Handling

All playbooks implement robust error handling:

### Worker Join Errors
If worker join fails, diagnostics are automatically saved to `/var/log/kubeadm-join-failure.log` including:
- Join command output
- Kubelet service status
- Kubelet logs
- Containerd logs
- Network connectivity status

### RKE2 Installation Errors
Check logs at:
- `ansible/artifacts/install-rke2-homelab.log`
- `journalctl -u rke2-server -n 100 --no-pager` (on homelab node)

### General Playbook Errors
All playbooks save detailed logs to `ansible/artifacts/` directory:
- `deploy-debian.log`
- `install-rke2-homelab.log`
- `reset-debian.log`
- `uninstall-rke2.log`

## Prerequisites

### All Nodes
- SSH access configured in inventory
- Python 3 installed
- Sudo/root access

### Debian Nodes (monitoring_nodes, storage_nodes)
- Debian Bookworm
- Firewall: iptables
- Systemd enabled

### RHEL Node (compute_nodes/homelab)
- RHEL 10
- Firewall: nftables
- Systemd enabled
- Vault-encrypted sudo password (if using non-root user)

## Inventory Configuration

Ensure your inventory file /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml`) defines:

```yaml
monitoring_nodes:
  hosts:
    masternode:
      ansible_host: 192.168.4.63
      ansible_user: root

storage_nodes:
  hosts:
    storagenodet3500:
      ansible_host: 192.168.4.61
      ansible_user: root

compute_nodes:
  hosts:
    homelab:
      ansible_host: 192.168.4.62
      ansible_user: jashandeepjustinbains
      ansible_become: true
```

## Variables

Key variables defined in inventory (`all.vars`):
- `kubernetes_version: "1.29"`
- `pod_network_cidr: "10.244.0.0/16"`
- `service_network_cidr: "10.96.0.0/12"`
- `control_plane_endpoint: "192.168.4.63:6443"`
- `cni_plugin: flannel`

## Troubleshooting

### Playbook hangs during worker join
Check `/var/log/kubeadm-join-failure.log` on the worker node for diagnostics.

### Flannel pods not starting
Verify CNI configuration:
```bash
kubectl get pods -n kube-flannel
kubectl describe pod <flannel-pod> -n kube-flannel
```

### RKE2 installation fails
Check RKE2 logs:
```bash
sudo journalctl -u rke2-server -n 100 --no-pager
```

### Nodes not Ready
Check kubelet status:
```bash
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 50 --no-pager
```

## Contributing

When modifying playbooks:
1. Maintain idempotency - playbooks should work multiple times
2. Add proper error handling with diagnostics
3. Update this README with changes
4. Test with `./tests/test-syntax.sh`
5. Test deployment with `./tests/test-idempotence.sh`

## References

- [DEPLOYMENT_SPECIFICATION.md](../../DEPLOYMENT_SPECIFICATION.md) - Full deployment specification
- [deploy.sh](../../deploy.sh) - Main deployment wrapper script
- [tests/](../../tests/) - Test scripts for validation
