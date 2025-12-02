# Kubespray Deployment Guide

This guide provides comprehensive instructions for deploying and managing Kubernetes clusters using Kubespray within the VMStation infrastructure.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Inventory Management](#inventory-management)
- [Deployment Workflow](#deployment-workflow)
- [Operations](#operations)
- [Troubleshooting](#troubleshooting)
- [Upgrade Procedures](#upgrade-procedures)

## Overview

Kubespray is a production-ready Kubernetes deployment tool that uses Ansible to provision and configure Kubernetes clusters. VMStation uses Kubespray as the primary method for deploying production-grade Kubernetes infrastructure.

### Architecture

- **Control Plane**: masternode (192.168.4.63)
- **Worker Nodes**: 
  - storagenodet3500 (192.168.4.61)
  - homelab (192.168.4.62 - RHEL 10)

### Features

- ✅ Production-grade Kubernetes deployment
- ✅ Multi-node cluster support
- ✅ Multiple CNI plugins (Calico, Flannel)
- ✅ Certificate rotation
- ✅ Cluster upgrades
- ✅ Node scaling (add/remove)
- ✅ RHEL 10 support with preflight checks

## Prerequisites

### Control Node Requirements

The machine running Kubespray (control node) must have:

- **Operating System**: Linux (Ubuntu 20.04+, RHEL 8+, or similar)
- **Python**: 3.8 or higher
- **Ansible**: Installed via Kubespray venv
- **Git**: For submodule management
- **SSH Access**: To all target nodes
- **Network**: Connectivity to all cluster nodes

### Target Node Requirements

All cluster nodes must have:

- **Operating System**: 
  - Ubuntu 20.04/22.04, Debian 11/12
  - RHEL 8/9/10, AlmaLinux 9
- **Resources**:
  - CPU: 2+ cores
  - RAM: 4GB+ (8GB+ for control plane)
  - Disk: 20GB+ free space
- **Network**: 
  - SSH access from control node
  - Unique hostname
  - Internet connectivity (or offline setup)
- **System**:
  - Swap disabled
  - Kernel modules: `br_netfilter`, `overlay`

## Quick Start

### 1. Initialize Kubespray

Clone the repository and initialize the Kubespray submodule:

```bash
# Clone cluster-infra repository
git clone https://github.com/jjbly-vmstation/cluster-infra.git
cd cluster-infra

# Initialize Kubespray submodule
git submodule update --init --recursive

# Run Kubespray setup script
./scripts/run-kubespray.sh
```

This script will:
- Initialize the Kubespray submodule
- Create a Python virtual environment
- Install all required dependencies
- Set up inventory templates

### 2. Validate Setup

```bash
./scripts/validate-kubespray-setup.sh
```

### 3. Configure Inventory

Edit the production inventory:

```bash
vim /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml
vim inventory/production/group_vars/all.yml
vim inventory/production/group_vars/k8s_cluster.yml
```

### 4. Test Inventory

```bash
./scripts/test-inventory.sh -e production -c
```

### 5. Run Preflight Checks (RHEL Nodes)

For RHEL/AlmaLinux nodes, run preflight checks:

```bash
cd ansible
ansible-playbook playbooks/run-preflight-rhel10.yml \
  -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml \
  -l compute_nodes
```

### 6. Deploy Cluster

```bash
# Activate Kubespray environment
source scripts/activate-kubespray-env.sh

# Change to Kubespray directory
cd kubespray

# Run deployment
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml cluster.yml
```

## Inventory Management

### Directory Structure

```
inventory/
├── production/
│   ├── /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml              # Main inventory (single source of truth)
│   └── group_vars/
│       ├── all.yml            # Global variables
│       └── k8s_cluster.yml    # Cluster-specific variables
└── staging/
    ├── /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml
    └── group_vars/
        ├── all.yml
        └── k8s_cluster.yml
```

### Inventory Format

VMStation uses YAML format for inventories (Kubespray native format):

```yaml
# /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml
kube_control_plane:
  hosts:
    masternode:
      ansible_host: 192.168.4.63
      ansible_user: root
      ip: 192.168.4.63

kube_node:
  hosts:
    worker1:
      ansible_host: 192.168.4.61
      ansible_user: root
      ip: 192.168.4.61

etcd:
  hosts:
    masternode:

k8s_cluster:
  children:
    kube_control_plane:
    kube_node:
```

### Required Host Groups

- `kube_control_plane`: Control plane nodes
- `kube_node`: Worker nodes
- `etcd`: etcd cluster members
- `k8s_cluster`: Parent group containing all cluster nodes

### Key Variables

In `group_vars/all.yml`:

```yaml
# Kubernetes version
kube_version: v1.29.0

# Network configuration
kube_service_addresses: 10.96.0.0/12
kube_pods_subnet: 10.244.0.0/16

# Container runtime
container_manager: containerd

# CNI plugin
kube_network_plugin: calico
```

## Deployment Workflow

### Standard Deployment

```bash
# 1. Validate environment
./scripts/validate-kubespray-setup.sh

# 2. Test inventory
./scripts/test-inventory.sh -e production

# 3. Dry run (optional but recommended)
./scripts/dry-run-deployment.sh -e production

# 4. Run preflight checks (RHEL nodes)
cd ansible
ansible-playbook playbooks/run-preflight-rhel10.yml \
  -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml -l compute_nodes

# 5. Deploy cluster
cd ../kubespray
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml cluster.yml
```

### Automated Deployment

Use the automation script for CI/CD environments:

```bash
./scripts/ops-kubespray-automation.sh
```

This script handles:
- Environment preparation
- Inventory validation
- Preflight checks
- Cluster deployment
- Health verification
- Kubeconfig distribution

## Operations

### Accessing the Cluster

After deployment, configure kubectl:

```bash
# Copy kubeconfig from control plane
scp root@192.168.4.63:/etc/kubernetes/admin.conf ~/.kube/config

# Test connectivity
kubectl get nodes
kubectl get pods -A
```

### Adding Worker Nodes

1. Add the new node to inventory:

```yaml
# /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml
kube_node:
  hosts:
    # ... existing nodes ...
    new-worker:
      ansible_host: 192.168.4.64
      ansible_user: root
      ip: 192.168.4.64
```

2. Run scale playbook:

```bash
cd kubespray
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml scale.yml \
  --limit=new-worker
```

### Removing Worker Nodes

1. Drain the node:

```bash
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
```

2. Run remove-node playbook:

```bash
cd kubespray
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml remove-node.yml \
  -e node=<node-name>
```

3. Remove from inventory file

### Certificate Rotation

```bash
cd kubespray
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml cluster.yml \
  --tags=rotate_certificates
```

### Cluster Reset

⚠️ **Warning**: This will destroy the cluster!

```bash
cd kubespray
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml reset.yml
```

## Troubleshooting

### Common Issues

#### Nodes Not Becoming Ready

```bash
# Check node status
kubectl get nodes -o wide
kubectl describe node <node-name>

# Check kubelet logs
ssh <node> journalctl -u kubelet -n 100 --no-pager
```

#### CNI Issues

```bash
# Check CNI pods
kubectl get pods -n kube-system | grep calico

# Restart CNI
kubectl delete pods -n kube-system -l k8s-app=calico-node
```

#### SSH Connection Issues

```bash
# Test SSH connectivity
ansible all -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml -m ping

# Check SSH keys
ssh -i ~/.ssh/id_k3s root@192.168.4.61
```

#### Python/Ansible Issues

```bash
# Rebuild virtual environment
rm -rf kubespray/.venv
./scripts/run-kubespray.sh

# Test Ansible
source kubespray/.venv/bin/activate
ansible --version
```

### Diagnostic Bundle

Create a diagnostic bundle for troubleshooting:

```bash
# Run validation with verbose output
./scripts/test-inventory.sh -e production -v -c

# Check logs
./scripts/ops-kubespray-automation.sh
# Logs saved to: ansible/artifacts/run-*/ansible-run-logs/
```

### Network Diagnostics

```bash
# Test connectivity to all nodes
ansible all -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml -m shell -a "ip addr"

# Check routes
ansible all -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml -m shell -a "ip route"

# Test inter-node connectivity
ansible all -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml -m shell \
  -a "ping -c 3 192.168.4.63"
```

## Upgrade Procedures

### Kubernetes Version Upgrade

1. **Backup Current State**

```bash
# Backup etcd
kubectl -n kube-system exec etcd-masternode -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /tmp/etcd-backup.db

# Copy backup
scp root@192.168.4.63:/tmp/etcd-backup.db ./etcd-backup-$(date +%Y%m%d).db
```

2. **Update Inventory**

```yaml
# inventory/production/group_vars/all.yml
kube_version: v1.29.0  # Update to desired version
```

3. **Run Upgrade Playbook**

```bash
cd kubespray
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml upgrade-cluster.yml
```

4. **Verify Upgrade**

```bash
kubectl get nodes
kubectl version
```

### Kubespray Version Upgrade

1. **Check Current Version**

```bash
cd kubespray
git describe --tags
```

2. **Update to New Version**

```bash
cd kubespray
git fetch --tags
git checkout v2.24.1  # Replace with desired version
cd ..
./scripts/run-kubespray.sh  # Reinstall dependencies
```

3. **Test with Dry Run**

```bash
./scripts/dry-run-deployment.sh -e production
```

## Best Practices

### Pre-Deployment

- ✅ Always validate inventory before deployment
- ✅ Run dry-run first for new configurations
- ✅ Backup existing cluster state
- ✅ Document any custom configurations
- ✅ Test SSH connectivity to all nodes

### During Deployment

- ✅ Monitor deployment progress
- ✅ Keep deployment logs
- ✅ Have rollback plan ready
- ✅ Test in staging first

### Post-Deployment

- ✅ Verify all nodes are Ready
- ✅ Check all system pods are running
- ✅ Test pod networking
- ✅ Validate DNS resolution
- ✅ Deploy test workload
- ✅ Document deployment specifics

## Configuration Files

### Location Reference

- **Kubespray**: `kubespray/` (git submodule)
- **Scripts**: `scripts/` and `scripts/lib/`
- **Inventory**: `inventory/production/` and `inventory/staging/`
- **Config**: `config/kubespray-defaults.env`
- **Ansible Roles**: `ansible/roles/preflight-rhel10/`
- **Playbooks**: `ansible/playbooks/`

### Environment Variables

Load default configuration:

```bash
source config/kubespray-defaults.env
```

Key variables:
- `KUBESPRAY_VERSION`: Kubespray version tag
- `KUBE_VERSION`: Kubernetes version
- `KUBE_NETWORK_PLUGIN`: CNI plugin (calico/flannel)
- `CONTAINER_MANAGER`: Container runtime (containerd)

## Support and Resources

### Documentation

- [Kubespray Official Docs](https://kubespray.io/)
- [Kubespray GitHub](https://github.com/kubernetes-sigs/kubespray)
- VMStation cluster-infra README.md

### Scripts Reference

| Script | Purpose |
|--------|---------|
| `run-kubespray.sh` | Initialize Kubespray environment |
| `activate-kubespray-env.sh` | Activate Python venv and set KUBECONFIG |
| `ops-kubespray-automation.sh` | Automated deployment workflow |
| `validate-kubespray-setup.sh` | Verify environment setup |
| `test-inventory.sh` | Validate inventory files |
| `dry-run-deployment.sh` | Test deployment without changes |

### Getting Help

For issues specific to VMStation infrastructure:
1. Check this documentation
2. Review logs in `ansible/artifacts/`
3. Run validation scripts
4. Check the main README.md

For Kubespray-specific issues:
1. Check Kubespray documentation
2. Search Kubespray GitHub issues
3. Review Kubespray troubleshooting guide
