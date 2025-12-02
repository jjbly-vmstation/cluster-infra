# VMStation Cluster Infrastructure

Infrastructure provisioning and configuration management for VMStation Kubernetes clusters.

This repository contains Ansible playbooks, roles, and scripts for deploying and managing Kubernetes clusters on physical and virtual infrastructure.

## Repository Structure

```
cluster-infra/
├── inventory/                       # 🎯 Canonical inventory (single source of truth)
│   ├── README.md                    # Inventory documentation
│   ├── production/
│   │   ├── hosts.yml                # Main inventory (Kubespray-compatible)
│   │   ├── group_vars/              # Global and group variables
│   │   │   ├── all.yml
│   │   │   ├── k8s_cluster/
│   │   │   ├── etcd.yml
│   │   │   └── kube_control_plane.yml
│   │   └── host_vars/               # Host-specific variables
│   │       ├── masternode.yml
│   │       ├── storagenodet3500.yml
│   │       └── homelab.yml
│   ├── staging/                     # Staging environment (future)
│   └── scripts/                     # Inventory management scripts
│       ├── validate-inventory.sh
│       ├── sync-inventory.sh
│       └── check-inventory-drift.sh
├── ansible/
│   ├── ansible.cfg                  # Ansible configuration
│   ├── inventory/                   # Legacy inventory (deprecated)
│   │   ├── hosts.yml                # Use inventory/production/hosts.yml instead
│   │   └── group_vars/
│   │       ├── all.yml.template     # Variables template
│   │       └── secrets.yml.example
│   ├── playbooks/
│   │   ├── deploy-cluster.yaml      # Kubernetes deployment
│   │   ├── reset-cluster.yaml       # Cluster cleanup
│   │   ├── cleanup-homelab.yml      # Homelab cleanup
│   │   ├── run-preflight-rhel10.yml # RHEL10 preparation
│   │   ├── verify-cluster.yaml      # Cluster verification
│   │   └── README.md
│   └── roles/
│       └── preflight-rhel10/        # RHEL10 preflight role
├── scripts/
│   ├── run-kubespray.sh             # Kubespray setup wrapper
│   ├── activate-kubespray-env.sh    # Environment activation
│   └── ops-kubespray-automation.sh  # CI/CD automation
├── templates/
│   └── kubeadm-config.yaml.j2       # Kubeadm configuration
├── terraform/
│   └── malware-lab/                 # Malware analysis lab IaC
├── inventory.ini                    # ⚠️ DEPRECATED - Use inventory/production/hosts.yml
├── IMPROVEMENTS_AND_STANDARDS.md    # Best practices guide
└── README.md
```

## Prerequisites

### Control Node Requirements
- Ansible 2.9+ (`pip install ansible`)
- Python 3.8+
- SSH access to target nodes
- `jq` for JSON processing

### Target Node Requirements

#### Debian/Ubuntu Nodes
- Debian Bookworm (12) or Ubuntu 22.04+
- Root SSH access or sudo privileges
- Python 3 installed

#### RHEL/AlmaLinux Nodes
- RHEL 10 / AlmaLinux 9
- SSH access with sudo privileges
- Subscription Manager configured (if applicable)

## Quick Start

### 1. Configure Inventory

The canonical inventory is located at `inventory/production/hosts.yml`. For most users, the default configuration is ready to use.

```bash
# View the canonical inventory
ansible-inventory -i inventory/production/hosts.yml --graph

# Validate inventory structure
./inventory/scripts/validate-inventory.sh

# (Optional) Edit hosts or variables if needed
vim inventory/production/hosts.yml
vim inventory/production/group_vars/all.yml

# Copy ansible variables template
cp ansible/inventory/group_vars/all.yml.template ansible/inventory/group_vars/all.yml
```

See [`inventory/README.md`](inventory/README.md) for detailed inventory documentation.

### 2. Run Preflight Checks (RHEL nodes)

```bash
cd ansible
ansible-playbook playbooks/run-preflight-rhel10.yml -l compute_nodes
```

### 3. Deploy Kubernetes Cluster

```bash
cd ansible
# Ensure manifests path is set (points to vmstation repo or local manifests)
ansible-playbook playbooks/deploy-cluster.yaml \
  -e "manifests_path=/path/to/vmstation/manifests"
```

### 4. Verify Cluster Health

```bash
cd ansible
ansible-playbook playbooks/verify-cluster.yaml
```

## Playbooks

### Core Playbooks

| Playbook | Description | Target Hosts |
|----------|-------------|--------------|
| `deploy-cluster.yaml` | Deploy full Kubernetes cluster | monitoring_nodes, storage_nodes |
| `reset-cluster.yaml` | Complete cluster reset | monitoring_nodes, storage_nodes |
| `verify-cluster.yaml` | Health checks and validation | monitoring_nodes |
| `cleanup-homelab.yml` | Homelab node cleanup | compute_nodes |
| `run-preflight-rhel10.yml` | RHEL10 preparation | compute_nodes |

### Deployment Phases

The `deploy-cluster.yaml` playbook implements 8 phases:

1. **Phase 0: System Preparation** - Install binaries, configure containerd
2. **Phase 1: Control Plane Initialization** - kubeadm init
3. **Phase 2: Control Plane Validation** - Verify API server
4. **Phase 3: Token Generation** - Create join tokens
5. **Phase 4: CNI Deployment** - Deploy Flannel
6. **Phase 5: Worker Node Join** - Join worker nodes
7. **Phase 6: Cluster Validation** - Verify nodes Ready
8. **Phase 7: Application Deployment** - Deploy monitoring stack
9. **Phase 8: Wake-on-LAN Validation** (Optional)

## Kubespray Integration

For production deployments, this repository supports Kubespray:

```bash
# Initialize Kubespray
./scripts/run-kubespray.sh

# Activate environment
source ./scripts/activate-kubespray-env.sh

# Follow the printed instructions for deployment
```

## Configuration

### Key Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `kubernetes_version` | `1.29` | Kubernetes version |
| `pod_network_cidr` | `10.244.0.0/16` | Pod network CIDR |
| `service_network_cidr` | `10.96.0.0/12` | Service network CIDR |
| `cni_plugin` | `flannel` | CNI plugin to use |
| `manifests_path` | (sibling vmstation) | Path to K8s manifests |

### Using Ansible Vault

Sensitive data should be stored using Ansible Vault:

```bash
# Create encrypted secrets file
cp ansible/inventory/group_vars/secrets.yml.example ansible/inventory/group_vars/secrets.yml
ansible-vault encrypt ansible/inventory/group_vars/secrets.yml

# Run playbooks with vault password
ansible-playbook playbooks/deploy-cluster.yaml --ask-vault-pass
```

## Testing

### Syntax Validation

```bash
cd ansible
ansible-playbook --syntax-check playbooks/deploy-cluster.yaml
ansible-playbook --syntax-check playbooks/reset-cluster.yaml
ansible-playbook --syntax-check playbooks/verify-cluster.yaml
```

### Dry Run

```bash
cd ansible
ansible-playbook playbooks/deploy-cluster.yaml --check -e "manifests_path=/tmp/manifests"
```

## Related Repositories

- [vmstation](https://github.com/jjbly-vmstation/vmstation) - Main VMStation repository with manifests
- [cluster-apps](https://github.com/jjbly-vmstation/cluster-apps) - Kubernetes applications

## Troubleshooting

### Common Issues

**Nodes not becoming Ready:**
```bash
# Check kubelet status on the node
systemctl status kubelet
journalctl -u kubelet -n 50 --no-pager
```

**Flannel pods not starting:**
```bash
kubectl get pods -n kube-flannel
kubectl describe pod -n kube-flannel kube-flannel-ds-XXXX
```

**Worker join fails:**
Check `/var/log/kubeadm-join-failure.log` on the worker node.

### Reset and Retry

```bash
cd ansible
ansible-playbook playbooks/reset-cluster.yaml
ansible-playbook playbooks/deploy-cluster.yaml -e "manifests_path=/path/to/manifests"
```

## Contributing

1. Follow Ansible best practices (see `IMPROVEMENTS_AND_STANDARDS.md`)
2. Use FQCN for all modules (e.g., `ansible.builtin.shell`)
3. Test with `--syntax-check` before committing
4. Update documentation for any new playbooks

## License

See [LICENSE](LICENSE) file.
