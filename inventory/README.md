# VMStation Inventory Management

This directory contains the canonical inventory for all VMStation Kubernetes cluster deployments.

## 🎯 Single Source of Truth

/srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml`** is the authoritative inventory file for the VMStation cluster. All other repositories and tools should reference or symlink to this file to ensure consistency.

## 📁 Structure

```
inventory/
├── README.md                           # This file
├── production/                         # Production environment
│   ├── /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml                       # Main inventory (Kubespray-compatible)
│   ├── group_vars/
│   │   ├── all.yml                     # Global cluster variables
│   │   ├── k8s_cluster/
│   │   │   ├── k8s-cluster.yml        # Kubernetes cluster settings
│   │   │   └── addons.yml             # Addon configurations
│   │   ├── etcd.yml                    # etcd-specific settings
│   │   └── kube_control_plane.yml      # Control plane settings
│   └── host_vars/
│       ├── masternode.yml              # Master node configuration
│       ├── storagenodet3500.yml        # Storage node configuration
│       └── homelab.yml                 # Compute node configuration
├── staging/                            # Staging environment (future)
│   ├── /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml
│   └── group_vars/
│       └── all.yml
└── scripts/
    ├── validate-inventory.sh           # Validate inventory structure
    ├── sync-inventory.sh               # Sync to other repositories
    └── check-inventory-drift.sh        # Detect inventory drift
```

## 🚀 Quick Start

### View Inventory

```bash
# List all hosts and variables
ansible-inventory -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml --list

# Show inventory graph
ansible-inventory -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml --graph

# Show host-specific variables
ansible-inventory -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml --host masternode
```

### Validate Inventory

```bash
./scripts/validate-inventory.sh
```

The validation script checks:
- YAML syntax
- Required groups (kube_control_plane, kube_node, etcd, k8s_cluster)
- Required hosts (masternode, storagenodet3500, homelab)
- Kubespray compatibility (ip, access_ip variables)
- Group and host variable files

### Sync to Other Repositories

```bash
./scripts/sync-inventory.sh
```

This creates symlinks in:
- /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml`
- /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml`
- /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml`
- /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml`

### Check for Drift

```bash
./scripts/check-inventory-drift.sh
```

Compares the canonical inventory with copies in other repositories and reports any differences.

## 📝 Editing the Inventory

### Modify Hosts

Edit /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml` to add, remove, or modify hosts:

```yaml
kube_node:
  hosts:
    newnode:
      ansible_host: 192.168.4.64
      ansible_user: root
      ip: 192.168.4.64
      access_ip: 192.168.4.64
```

### Modify Group Variables

Edit files in `production/group_vars/` to change cluster-wide settings:

- `all.yml` - Settings for all hosts
- `k8s_cluster/k8s-cluster.yml` - Kubernetes cluster settings
- `k8s_cluster/addons.yml` - Addon configurations
- `etcd.yml` - etcd-specific settings
- `kube_control_plane.yml` - Control plane settings

### Modify Host Variables

Edit files in `production/host_vars/` to change host-specific settings:

- `masternode.yml` - Master node labels, taints, and configuration
- `storagenodet3500.yml` - Storage node configuration
- `homelab.yml` - Compute node configuration

### After Editing

1. **Validate** your changes:
   ```bash
   ./scripts/validate-inventory.sh
   ```

2. **Sync** to other repositories:
   ```bash
   ./scripts/sync-inventory.sh
   ```

3. **Commit** and push:
   ```bash
   git add inventory/
   git commit -m "Update inventory: <description>"
   git push
   ```

## 🏗️ Host Groups

### Kubespray Standard Groups

- **kube_control_plane**: Kubernetes control plane nodes
  - `masternode` - Master node (192.168.4.63)

- **kube_node**: Kubernetes worker nodes
  - `storagenodet3500` - Storage node (192.168.4.61)
  - `homelab` - Compute node (192.168.4.62)

- **etcd**: etcd cluster members
  - `masternode` - Runs etcd

- **k8s_cluster**: All Kubernetes nodes (parent group)
  - Contains all nodes in kube_control_plane and kube_node

- **calico_rr**: Calico route reflectors (empty for this cluster)

### Legacy Groups (Backward Compatibility)

For backward compatibility with existing playbooks, the following legacy groups are maintained:

- **monitoring_nodes**: Control plane/monitoring node
  - `masternode` - Same as kube_control_plane

- **storage_nodes**: Storage node
  - `storagenodet3500` - Subset of kube_node for storage

- **compute_nodes**: Compute node
  - `homelab` - Subset of kube_node for general compute

These groups map to the same hosts as the Kubespray groups but provide role-specific grouping used by existing playbooks. Host-specific roles and configuration are preserved in `host_vars/`.

## 🔧 Variables

### Global Variables (`group_vars/all.yml`)

- `cluster_name`: vmstation
- `kubernetes_version`: "1.29"
- `pod_network_cidr`: "10.244.0.0/16"
- `service_network_cidr`: "10.96.0.0/12"
- `control_plane_endpoint`: "192.168.4.63:6443"
- `cni_plugin`: flannel
- `container_runtime`: containerd

### Cluster Variables (`group_vars/k8s_cluster/`)

**k8s-cluster.yml**:
- `kube_version`: v1.29.0
- `container_manager`: containerd
- `kube_network_plugin`: calico
- `kube_proxy_mode`: iptables

**addons.yml**:
- `dashboard_enabled`: false
- `helm_enabled`: true
- `metrics_server_enabled`: true
- `ingress_nginx_enabled`: false

### Host-Specific Variables (`host_vars/`)

Each host has custom labels, node roles, and hardware-specific settings like Wake-on-LAN MAC addresses.

## 🔄 Kubespray Compatibility

This inventory is fully compatible with Kubespray. Key compatibility features:

1. **Standard group names**: Uses kube_control_plane, kube_node, etcd, k8s_cluster
2. **Required variables**: All hosts have `ip` and `access_ip` set
3. **Proper structure**: Group hierarchy matches Kubespray expectations
4. **Variable locations**: group_vars/k8s_cluster/ for cluster settings

To use with Kubespray:

```bash
# Clone Kubespray
git clone https://github.com/kubernetes-sigs/kubespray.git
cd kubespray

# Install dependencies
pip install -r requirements.txt

# Use cluster-infra inventory
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml \
    cluster.yml
```

## 📋 Inventory Migration

The canonical inventory replaces:

- ❌ `cluster-infra/inventory.ini` (deprecated, Kubespray-style)
  ✅ Use /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml` as the canonical inventory
- ❌ /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml` (legacy custom groups)
- ❌ Duplicate inventories in other repositories

### Why This Structure?

1. **Single Source of Truth**: One canonical file prevents drift
2. **Kubespray Compatible**: Works with standard Kubernetes deployment tools
3. **Organized**: Clear separation of global, group, and host variables
4. **Maintainable**: Easy to understand and modify
5. **Validated**: Built-in validation and drift detection

## 🛠️ Troubleshooting

### Validation Fails

```bash
# Check detailed errors
./scripts/validate-inventory.sh

# Test with ansible-inventory
ansible-inventory -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml --list
```

### Drift Detected

```bash
# Check what's different
./scripts/check-inventory-drift.sh

# Re-sync inventories
./scripts/sync-inventory.sh
```

### Ansible Can't Find Hosts

Ensure you're using the correct inventory path:

```bash
# Correct
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml playbook.yml

# Or from ansible/ directory with ansible.cfg configured
cd ansible
ansible-playbook playbooks/deploy-cluster.yaml
```

## 📚 References

- [Ansible Inventory Documentation](https://docs.ansible.com/ansible/latest/inventory_guide/)
- [Kubespray Documentation](https://kubespray.io/)
- [VMStation Cluster Infrastructure](../README.md)

## 🔐 Security

- **No secrets in inventory**: Use Ansible Vault for sensitive data
- **SSH key paths**: Reference user-specific SSH keys, not committed keys
- **Vault integration**: See `ansible/inventory/group_vars/secrets.yml.example`

## 📞 Support

For issues or questions:
1. Check this README
2. Run validation: `./scripts/validate-inventory.sh`
3. Check drift: `./scripts/check-inventory-drift.sh`
4. Review Ansible inventory docs
5. Open an issue in the repository
