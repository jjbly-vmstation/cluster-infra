# VMStation Cluster Infrastructure

Infrastructure provisioning and configuration management for VMStation Kubernetes clusters.

This repository contains Ansible playbooks, roles, and scripts for deploying and managing Kubernetes clusters on physical and virtual infrastructure.

## Repository Structure

```
cluster-infra/
├── kubespray/                      # Git submodule (Kubespray official)
├── ansible/
│   ├── ansible.cfg                 # Ansible configuration
│   ├── inventory/
│   │   ├── hosts.yml               # Main inventory file
│   │   └── group_vars/             # Group variables
│   │       ├── all.yml.template    # Variables template
│   │       └── secrets.yml.example
│   ├── playbooks/
│   │   ├── deploy-cluster.yaml     # Kubernetes deployment
│   │   ├── reset-cluster.yaml      # Cluster cleanup
│   │   ├── cleanup-homelab.yml     # Homelab cleanup
│   │   ├── run-preflight-rhel10.yml# RHEL10 preparation
│   │   ├── verify-cluster.yaml     # Cluster verification
│   │   └── README.md
│   └── roles/
│       └── preflight-rhel10/       # RHEL10 preflight role
├── config/
│   └── kubespray-defaults.env      # Kubespray configuration
├── docs/
│   └── KUBESPRAY_DEPLOYMENT.md     # Kubespray deployment guide
├── inventory/
│   ├── production/                 # Production inventory
│   │   ├── hosts.yml               # Single source of truth
│   │   └── group_vars/
│   │       ├── all.yml
│   │       └── k8s_cluster.yml
│   └── staging/                    # Staging inventory
│       ├── hosts.yml
│       └── group_vars/
├── scripts/
│   ├── run-kubespray.sh            # Kubespray setup wrapper
│   ├── activate-kubespray-env.sh   # Environment activation
│   ├── ops-kubespray-automation.sh # CI/CD automation
│   ├── validate-kubespray-setup.sh # Validate environment
│   ├── test-inventory.sh           # Validate inventory
│   ├── dry-run-deployment.sh       # Test deployment
│   └── lib/
│       ├── kubespray-common.sh     # Shared functions
│       └── kubespray-validation.sh # Validation functions
├── templates/
│   └── kubeadm-config.yaml.j2      # Kubeadm configuration
├── terraform/
│   └── malware-lab/                # Malware analysis lab IaC
├── inventory.ini                   # Legacy inventory (backward compat)
├── IMPROVEMENTS_AND_STANDARDS.md   # Best practices guide
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

For production deployments, this repository uses Kubespray as the primary deployment method:

### Quick Start with Kubespray

```bash
# 1. Initialize Kubespray submodule and setup environment
git submodule update --init --recursive
./scripts/run-kubespray.sh

# 2. Validate setup
./scripts/validate-kubespray-setup.sh

# 3. Configure inventory (edit as needed)
vim inventory/production/hosts.yml
vim inventory/production/group_vars/all.yml

# 4. Test inventory
./scripts/test-inventory.sh -e production

# 5. Run preflight checks (RHEL nodes)
cd ansible
ansible-playbook playbooks/run-preflight-rhel10.yml \
  -i ../inventory/production/hosts.yml -l compute_nodes

# 6. Deploy cluster
cd ../kubespray
source ../.cache/kubespray/.venv/bin/activate
ansible-playbook -i ../inventory/production/hosts.yml cluster.yml
```

### Kubespray Scripts

| Script | Purpose |
|--------|---------|
| `run-kubespray.sh` | Initialize Kubespray environment and dependencies |
| `activate-kubespray-env.sh` | Activate Python venv and set KUBECONFIG |
| `ops-kubespray-automation.sh` | Full automated deployment workflow (CI/CD) |
| `validate-kubespray-setup.sh` | Verify Kubespray environment setup |
| `test-inventory.sh` | Validate and test inventory files |
| `dry-run-deployment.sh` | Test deployment configuration without changes |

### Documentation

For complete Kubespray deployment documentation, see [docs/KUBESPRAY_DEPLOYMENT.md](docs/KUBESPRAY_DEPLOYMENT.md)

Topics covered:
- Deployment workflow
- Inventory management
- Operations (scaling, upgrades, certificate rotation)
- Troubleshooting guide
- Best practices

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
