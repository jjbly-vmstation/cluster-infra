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
│   │   ├── /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml               # Main inventory file
│   │   └── group_vars/             # Group variables
│   │       ├── all.yml.template    # Variables template
│   │       └── secrets.yml.example
│   ├── playbooks/
│   │   ├── deploy-cluster.yaml     # Kubernetes deployment
│   │   ├── identity-deploy-and-handover.yml  # Identity stack deployment
│   │   ├── reset-cluster.yaml      # Cluster cleanup
│   │   ├── cleanup-homelab.yml     # Homelab cleanup
│   │   ├── run-preflight-rhel10.yml# RHEL10 preparation
│   │   ├── verify-cluster.yaml     # Cluster verification
│   │   └── README.md
│   └── roles/
│       ├── identity-admin/         # Administrator account creation
│       ├── identity-backup/        # Identity data backup
│       ├── identity-certmanager/   # cert-manager with FreeIPA CA
│       ├── identity-freeipa/       # FreeIPA LDAP server
│       ├── identity-freeipa-ldap-client/  # FreeIPA client for nodes
│       ├── identity-keycloak/      # Keycloak SSO server
│       ├── identity-postgresql/    # PostgreSQL for Keycloak
│       ├── identity-prerequisites/ # Identity stack prerequisites
│       ├── identity-sso/           # Keycloak SSO automation (realm import, LDAP)
│       ├── identity-storage/       # Persistent storage setup
│       ├── network-remediation/    # Network validation and auto-remediation
│       └── preflight-rhel10/       # RHEL10 preflight role
├── config/
│   └── kubespray-defaults.env      # Kubespray configuration
├── docs/
│   ├── AUTOMATED-IDENTITY-DEPLOYMENT.md  # Automated deployment guide
│   ├── IDENTITY-SSO-SETUP.md       # Identity stack and SSO setup guide
│   ├── KEYCLOAK-INTEGRATION.md     # Application SSO integration guide
│   └── KUBESPRAY_DEPLOYMENT.md     # Kubespray deployment guide
├── helm/
│   └── keycloak-values.yaml        # Keycloak Helm chart values
├── manifests/
│   └── identity/
│       ├── certificates/           # TLS certificates for services
│       ├── freeipa.yaml            # FreeIPA StatefulSet
│       ├── keycloak-postgresql-pv.yaml  # PostgreSQL persistent volume
│       ├── postgresql-statefulset.yaml  # PostgreSQL for Keycloak
│       └── storage-class-manual.yaml    # Manual storage class
├── inventory/
│   ├── production/                 # Production inventory
│   │   ├── /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml               # Single source of truth
│   │   └── group_vars/
│   │       ├── all.yml
│   │       └── k8s_cluster.yml
│   └── staging/                    # Staging inventory
│       ├── /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml
│       └── group_vars/
├── scripts/
│   ├── run-kubespray.sh            # Kubespray setup wrapper
│   ├── activate-kubespray-env.sh   # Environment activation
│   ├── ops-kubespray-automation.sh # CI/CD automation
│   ├── validate-kubespray-setup.sh # Validate environment
│   ├── identity-full-deploy.sh     # Main identity stack orchestrator
│   ├── reset-identity-stack.sh     # Safe identity stack reset
│   ├── bootstrap-identity-admins.sh # Admin account bootstrap
│   ├── request-freeipa-intermediate-ca.sh # CA certificate management
│   ├── enroll-nodes-freeipa.sh     # Node enrollment to FreeIPA
│   ├── verify-identity-deployment.sh  # Identity stack verification
│   ├── verify-ldap-integration.sh  # LDAP connectivity testing
│   ├── verify-sso-integration.sh   # SSO configuration verification
│   ├── test-inventory.sh           # Validate inventory
│   ├── dry-run-deployment.sh       # Test deployment
│   ├── IDENTITY-DEPLOY-SCRIPTS.md  # Identity scripts documentation
│   └── lib/
│       ├── kubespray-common.sh     # Shared functions
│       └── kubespray-validation.sh # Validation functions
├── templates/
│   └── kubeadm-config.yaml.j2      # Kubeadm configuration
├── terraform/
│   └── malware-lab/                # Malware analysis lab IaC
├── /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml                   # Canonical inventory
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

The canonical inventory is located at /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml`. For most users, the default configuration is ready to use.

```bash
# View the canonical inventory
ansible-inventory -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml --graph

# Validate inventory structure
./inventory/scripts/validate-inventory.sh

# (Optional) Edit hosts or variables if needed
vim /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml
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

## Identity Stack & SSO

The cluster includes a comprehensive identity management solution for cluster-wide Single Sign-On (SSO):

### Architecture

```
┌────────────────────────────────────────────────────────────┐
│                    Identity Stack                          │
│                                                             │
│  ┌─────────────┐      ┌─────────────┐                     │
│  │  FreeIPA    │─────▶│  Keycloak   │                     │
│  │  LDAP/CA    │      │  SSO/OIDC   │                     │
│  └──────┬──────┘      └──────┬──────┘                     │
│         │                     │                             │
│         │                     ▼                             │
│         │         ┌───────────────────┐                    │
│         │         │  OIDC Clients     │                    │
│         │         │  - Grafana        │                    │
│         │         │  - Prometheus     │                    │
│         │         │  - Loki           │                    │
│         │         └───────────────────┘                    │
│         │                                                   │
│         ▼                                                   │
│  ┌─────────────┐                                           │
│  │cert-manager │                                           │
│  │ClusterIssuer│                                           │
│  └─────────────┘                                           │
│                                                             │
│  All Nodes: FreeIPA LDAP Client + SSSD                    │
└────────────────────────────────────────────────────────────┘
```

### Components

- **FreeIPA**: LDAP directory, Kerberos, and Certificate Authority
- **Keycloak**: Identity and Access Management, OIDC/SAML SSO provider
- **cert-manager**: Automated TLS certificate management with FreeIPA CA
- **PostgreSQL**: Database backend for Keycloak

### Deployment

**🚀 Fully Automated Deployment (Recommended)**

The identity stack is now **100% automated** with built-in network diagnostics and self-healing:

```bash
# Single command deployment with automatic network remediation
cd /opt/vmstation-org/cluster-infra/ansible
sudo FORCE_RESET=1 RESET_CONFIRM=yes \
     FREEIPA_ADMIN_PASSWORD=secret123 \
     KEYCLOAK_ADMIN_PASSWORD=secret123 \
     ../scripts/identity-full-deploy.sh
```

**Features:**
- ✅ Automatic pod-to-ClusterIP DNS validation
- ✅ Auto-remediation of network issues (ip_forward, iptables, br_netfilter, IPVS)
- ✅ Keycloak realm import via API (no manual UI steps)
- ✅ FreeIPA LDAP federation auto-configured
- ✅ OIDC client secrets exported to Kubernetes
- ✅ Comprehensive diagnostics collection on failures
- ✅ Idempotent - safe to re-run multiple times
- ✅ Retry logic with automatic remediation

**See:** [Automated Identity Deployment Guide](docs/AUTOMATED-IDENTITY-DEPLOYMENT.md) for complete documentation.

**Option 1: Automated Full Deployment**

```bash
# Deploy complete identity stack with all phases
sudo ./scripts/identity-full-deploy.sh

# Or with full reset and redeploy
sudo FORCE_RESET=1 RESET_CONFIRM=yes ./scripts/identity-full-deploy.sh

# Dry-run mode to preview actions
sudo DRY_RUN=1 ./scripts/identity-full-deploy.sh
```

**Option 2: Manual Deployment**

```bash
# Step 1-3: Deploy complete identity stack
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml

# Step 4a: Configure DNS and network ports
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml \
  ansible/playbooks/configure-dns-network-step4a.yml

# Verify deployment
./scripts/verify-identity-deployment.sh
./scripts/verify-freeipa-keycloak-readiness.sh
./scripts/verify-network-ports.sh
```

**Option 3: Reset and Clean Deployment**

```bash
# Reset identity stack (creates timestamped backup)
sudo ./scripts/reset-identity-stack.sh

# Deploy fresh
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml
```

For detailed documentation on identity deployment scripts, see [scripts/IDENTITY-DEPLOY-SCRIPTS.md](scripts/IDENTITY-DEPLOY-SCRIPTS.md)

### Access Points

- **Keycloak Admin**: `http://192.168.4.63:30180/auth/admin/`
- **FreeIPA Web UI**: `https://ipa.vmstation.local`
- **Credentials**: `/root/identity-backup/cluster-admin-credentials.txt`

### Documentation

- [Identity Deployment Scripts](scripts/IDENTITY-DEPLOY-SCRIPTS.md) - Automated deployment and reset scripts
- [Deployment Sequence](docs/DEPLOYMENT_SEQUENCE.md) - Complete deployment workflow
- [Step 4a: DNS and Network Configuration](docs/STEP4A_DNS_NETWORK_CONFIGURATION.md) - DNS and firewall setup
- [Identity SSO Setup Guide](docs/IDENTITY-SSO-SETUP.md) - Complete deployment and configuration guide
- [Keycloak Integration](docs/KEYCLOAK-INTEGRATION.md) - How to integrate applications with SSO

### Features

✅ Cluster-wide Single Sign-On (SSO)  
✅ LDAP authentication on all nodes  
✅ Automated TLS certificate management  
✅ Pre-configured OIDC clients for monitoring stack  
✅ FreeIPA CA integration with cert-manager  
✅ Role-based access control (RBAC)  
✅ Secure credential management  

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
vim /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml
vim inventory/production/group_vars/all.yml

# 4. Test inventory
./scripts/test-inventory.sh -e production

# 5. Run preflight checks (RHEL nodes)
cd ansible
ansible-playbook playbooks/run-preflight-rhel10.yml \
  -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml -l compute_nodes

# 6. Deploy cluster
cd ../kubespray
source ../.cache/kubespray/.venv/bin/activate
ansible-playbook -i /srv/vmstation-org/cluster-setup/ansible/inventory/hosts.yml cluster.yml
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

## Identity Stack Deployment

The identity stack (Keycloak, PostgreSQL, FreeIPA, cert-manager) can be deployed using the refactored modular playbook.

### Quick Start

```bash
# Standard deployment
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml

# With destructive replace (includes backup)
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml -e identity_force_replace=true
```

### Components

The identity deployment includes:
- **PostgreSQL**: Database for Keycloak (hostPath storage on control-plane)
- **Keycloak**: Identity and access management
- **FreeIPA**: Optional LDAP/Kerberos/CA (hostPath storage on control-plane)
- **cert-manager**: Certificate management with custom CA integration

### Modular Roles

The deployment is organized into 7 modular roles:
- `identity-prerequisites`: Binary checks, node detection, namespaces
- `identity-storage`: Storage classes, PVs, hostPath ownership
- `identity-postgresql`: PostgreSQL StatefulSet management
- `identity-keycloak`: Keycloak Helm deployment
- `identity-freeipa`: FreeIPA StatefulSet management (optional)
- `identity-certmanager`: cert-manager installation and CA setup
- `identity-backup`: Backup operations

### Control-Plane Scheduling

All identity components are configured to tolerate the control-plane taint and can schedule on masternode:

```yaml
tolerations:
- key: node-role.kubernetes.io/control-plane
  operator: Exists
  effect: NoSchedule
```

### Selective Deployment

Use tags to deploy specific components:

```bash
# Only PostgreSQL and Keycloak
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml --tags postgresql,keycloak

# Skip FreeIPA
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml --skip-tags freeipa
```

### Verification

```bash
# Run verification script
./scripts/verify-identity-deployment.sh

# Manual verification
kubectl get pods -n identity -o wide
kubectl get pv,pvc -n identity
```

### Documentation

- [Identity Refactoring Guide](docs/IDENTITY_REFACTORING.md) - Detailed refactoring documentation
- [Control-Plane Taint Fix](docs/CONTROL_PLANE_TAINT_FIX.md) - Taint resolution details
- [Roles README](ansible/roles/README.md) - Role documentation

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
