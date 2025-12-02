# Inventory Quick Start Guide

## 🎯 TL;DR

The canonical inventory is at `inventory/production/hosts.yml`. Everything is already configured and validated.

## ✅ Quick Commands

```bash
# Validate inventory
./scripts/validate-inventory.sh

# View inventory
ansible-inventory -i production/hosts.yml --graph
ansible-inventory -i production/hosts.yml --list

# Use in playbooks (from ansible/ directory)
cd ../ansible
ansible-playbook playbooks/deploy-cluster.yaml

# Or specify explicitly
ansible-playbook -i ../inventory/production/hosts.yml playbooks/deploy-cluster.yaml
```

## 📋 What Changed?

### Before (Deprecated)
```
inventory.ini                        # Root level, INI format
ansible/inventory/hosts.yml          # Legacy custom groups
```

### After (Current)
```
inventory/production/hosts.yml       # Canonical, Kubespray-compatible
```

## 🏗️ Host Groups

### Kubespray Groups (for Kubespray deployment)
- `kube_control_plane` - Control plane nodes
- `kube_node` - Worker nodes
- `etcd` - etcd cluster
- `k8s_cluster` - All k8s nodes

### Legacy Groups (for existing playbooks)
- `monitoring_nodes` - Monitoring/control plane
- `storage_nodes` - Storage nodes
- `compute_nodes` - Compute nodes

## 🎨 Host Labels and Roles

Hosts have specific roles configured in `host_vars/`:

- **masternode** (192.168.4.63)
  - Control plane + monitoring
  - Labels: `control-plane`, `monitoring`
  
- **storagenodet3500** (192.168.4.61)
  - Storage + Jellyfin
  - Labels: `storage`, `media-server`
  
- **homelab** (192.168.4.62)
  - General compute (RHEL10)
  - Labels: `compute`

## 🔄 Syncing to Other Repos

The canonical inventory can be synced to other repositories:

```bash
# Sync to other repos (creates symlinks)
./scripts/sync-inventory.sh

# Check for drift
./scripts/check-inventory-drift.sh
```

Target repos:
- `~/.vmstation/repos/cluster-config`
- `~/.vmstation/repos/cluster-setup`
- `~/.vmstation/repos/cluster-monitor-stack`
- `~/.vmstation/repos/cluster-application-stack`

## 🛠️ Editing

### Change hosts
Edit `production/hosts.yml`

### Change cluster config
Edit `production/group_vars/all.yml`

### Change host-specific config
Edit `production/host_vars/{hostname}.yml`

### After editing
```bash
./scripts/validate-inventory.sh
git add inventory/
git commit -m "Update inventory: ..."
git push
```

## 📚 More Info

See [README.md](README.md) for complete documentation.
