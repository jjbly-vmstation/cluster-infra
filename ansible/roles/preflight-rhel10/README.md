# Preflight RHEL10 Role

This Ansible role performs preflight checks and configuration for RHEL10 nodes before Kubernetes deployment (either Kubespray or RKE2).

## Features

- ✅ Installs Python3 and required packages
- ✅ Configures time synchronization (chrony)
- ✅ Sets up sudoers for ansible user
- ✅ Opens required firewall ports
- ✅ Configures SELinux (permissive by default, configurable)
- ✅ Loads required kernel modules
- ✅ Applies sysctl settings for Kubernetes
- ✅ Disables swap

## Requirements

- RHEL 10 (or compatible RHEL-based distribution)
- Ansible 2.9+
- Target node accessible via SSH

## Role Variables

See `defaults/main.yml` for all configurable variables. Key variables:

```yaml
# SELinux configuration
selinux_mode: permissive  # Options: enforcing, permissive, disabled

# Firewall ports (customize as needed)
firewall_ports:
  - 6443/tcp      # Kubernetes API
  - 2379-2380/tcp # etcd
  - 10250/tcp     # Kubelet
  - 30000-32767/tcp # NodePort Services

# Time sync
chrony_enabled: true

# Ansible user sudo
ansible_sudo_nopasswd: true
```

## Example Usage

### Run preflight on compute_nodes group

```bash
ansible-playbook -i ansible/inventory/hosts.yml \
  ansible/playbooks/run-preflight-rhel10.yml
```

### Run preflight on specific host

```bash
ansible-playbook -i ansible/inventory/hosts.yml \
  -l homelab \
  ansible/playbooks/run-preflight-rhel10.yml
```

### Override SELinux mode

```bash
ansible-playbook -i ansible/inventory/hosts.yml \
  -e 'selinux_mode=enforcing' \
  ansible/playbooks/run-preflight-rhel10.yml
```

## Idempotency

This role is idempotent and safe to run multiple times. Re-running the role will:
- Skip already installed packages
- Preserve existing configurations
- Only make changes when necessary

## Post-Execution

After running this role:

1. **If SELinux mode was changed**: Reboot is recommended
   ```bash
   ansible compute_nodes -i ansible/inventory/hosts.yml -m reboot -b
   ```

2. **Verify time sync**:
   ```bash
   ansible compute_nodes -i ansible/inventory/hosts.yml -m shell -a "chronyc tracking"
   ```

3. **Proceed with deployment**:
   - For Kubespray: `./scripts/run-kubespray.sh`
   - For RKE2: `./deploy.sh rke2`

## Integration with VMStation

This role integrates with the existing VMStation deployment workflow:

```bash
# Full workflow
./deploy.sh reset                          # Clean slate
./deploy.sh setup                          # Setup auto-sleep
./deploy.sh debian                         # Deploy Debian cluster

# Run preflight before RKE2 or Kubespray deployment
ansible-playbook -i ansible/inventory/hosts.yml \
  ansible/playbooks/run-preflight-rhel10.yml

# Then deploy with RKE2 (existing flow)
./deploy.sh rke2

# OR deploy with Kubespray (new option)
./scripts/run-kubespray.sh
# ... follow kubespray deployment steps
```

## Safety Features

- **Non-destructive**: No data loss or service disruption
- **Validation**: Checks OS family before proceeding
- **Backup**: Configuration files are backed up before modification
- **Idempotent**: Safe to run multiple times
- **Configurable**: SELinux and firewall can be customized

## Troubleshooting

### Firewall errors

If firewalld is not running:
```bash
sudo systemctl enable --now firewalld
```

### SELinux issues

Check current mode:
```bash
getenforce
```

Temporarily set to permissive without reboot:
```bash
sudo setenforce 0
```

### Module loading failures

Some modules may not be available depending on kernel version. This is normal and can be ignored if not needed by your CNI.

## Author

VMStation Project
