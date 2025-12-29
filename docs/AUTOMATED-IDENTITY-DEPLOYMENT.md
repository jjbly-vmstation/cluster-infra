# Automated Identity Stack Deployment

## Overview

The identity stack deployment is now fully automated, idempotent, and self-healing. It includes automatic network diagnostics and remediation to handle cluster-level failures (DNS/Service NAT, CNI/policy issues, IPVS stale mappings).

## Quick Start: Single Command Deployment

```bash
cd /opt/vmstation-org/cluster-infra/ansible
sudo FORCE_RESET=1 RESET_CONFIRM=yes \
     FREEIPA_ADMIN_PASSWORD=secret123 \
     KEYCLOAK_ADMIN_PASSWORD=secret123 \
     ../scripts/identity-full-deploy.sh
```

This single command will:
1. Reset any existing identity stack (optional, controlled by `FORCE_RESET`)
2. Validate and remediate pod-to-ClusterIP network connectivity
3. Deploy PostgreSQL → FreeIPA → Keycloak
4. Configure Keycloak realm and LDAP federation via API
5. Bootstrap admin accounts
6. Setup CA certificates
7. Enroll cluster nodes (optional)
8. Verify deployment

## Complete Setup Script

```bash
#!/bin/bash
# Full VMStation cluster infrastructure setup

clear
cd /opt/vmstation-org/

# Configuration
ORG="jjbly-vmstation"
TARGET="/opt/vmstation-org"

# Prepare directory
sudo mkdir -p "$TARGET"
sudo chown jjbly:jjbly /opt/vmstation-org
cd "$TARGET"

# Clone/update all repositories
for repo in cluster-setup cluster-config cluster-cicd cluster-monitor-stack \
            cluster-application-stack cluster-infra cluster-tools cluster-docs; do
    if [ -d "$repo/.git" ]; then
        echo "Updating $repo..."
        cd "$repo" && git pull && cd ..
    else
        echo "Cloning $repo..."
        git clone "https://github.com/$ORG/$repo.git"
    fi
done

# Deploy identity stack with full automation
cd /opt/vmstation-org/cluster-infra/ansible
sudo FORCE_RESET=1 \
     RESET_CONFIRM=yes \
     FREEIPA_ADMIN_PASSWORD=secret123 \
     KEYCLOAK_ADMIN_PASSWORD=secret123 \
     ../scripts/identity-full-deploy.sh
```

## Features

### 1. Network Validation and Remediation

The deployment now includes automatic network validation and remediation via the `network-remediation` role:

**What it does:**
- Validates pod-to-ClusterIP DNS connectivity using ephemeral test pods
- Automatically fixes common network issues:
  - Enables `ip_forward` on nodes
  - Sets iptables FORWARD policy to ACCEPT
  - Loads `br_netfilter` kernel module
  - Clears stale IPVS state (when using iptables mode)
  - Restarts kube-proxy

**Retry Logic:**
- Up to 3 attempts (configurable)
- Collects diagnostics on each failure
- Provides actionable error messages

**Diagnostics Collection:**
- Cluster-level: CoreDNS, kube-dns Service, kube-proxy config/logs
- Node-level: sysctls, iptables rules, IPVS state, network interfaces
- Archived to: `/root/identity-backup/network-diagnostics-<timestamp>.tar.gz`

### 2. Fully Automated Keycloak Realm Import

The Keycloak SSO configuration is now **100% automated via API**:

**What it does:**
- Creates/imports realm from JSON template (idempotent)
- Configures FreeIPA LDAP federation provider
- Exports OIDC client secrets to Kubernetes secrets
- No manual UI steps required

**Realm Configuration:**
- Realm: `cluster-services` (default)
- LDAP Provider: `freeipa`
- Connection: `ldap://freeipa.identity.svc.cluster.local`
- OIDC Clients: Grafana, Prometheus (auto-configured)

### 3. Idempotent Deployment

All playbooks and roles are idempotent:
- Safe to re-run multiple times
- Only applies changes when needed
- Skips already-configured components
- No destructive operations without explicit flags

### 4. Self-Healing on Failures

**Network Failures:**
- Automatic remediation of node network configuration
- Retry logic with diagnostics collection
- Clear error messages with troubleshooting steps

**Service Failures:**
- Waits for pods to become ready
- Validates Service endpoints before proceeding
- Restarts components if needed

## Environment Variables

### Required for Automation

```bash
# Passwords (use strong passwords in production)
FREEIPA_ADMIN_PASSWORD=secret123
KEYCLOAK_ADMIN_PASSWORD=secret123
```

### Optional Configuration

```bash
# Inventory location (default: /opt/vmstation-org/cluster-setup/ansible/inventory/hosts.yml)
INVENTORY=/path/to/hosts.yml

# Kubeconfig location (default: /etc/kubernetes/admin.conf)
KUBECONFIG_PATH=/path/to/kubeconfig

# Reset options
FORCE_RESET=1              # Perform reset before deploy
RESET_CONFIRM=yes          # Auto-confirm reset (no prompt)
RESET_REMOVE_OLD=1         # Remove old backups

# Workflow control
SKIP_NODE_ENROLLMENT=1     # Skip FreeIPA node enrollment
SKIP_VERIFICATION=1        # Skip final verification
DRY_RUN=1                  # Dry-run mode (no changes)

# Logging
LOG_DIR=/var/log/identity-deploy  # Log directory
```

## Deployment Phases

### Phase 0: Preflight Checks
- Validates required commands (kubectl, ansible, etc.)
- Checks inventory file exists
- Verifies kubeconfig accessibility

### Phase 1: Optional Reset
- Backs up existing data
- Removes identity stack components
- Cleans up resources

### Phase 2: Network Validation & Remediation
- **NEW**: Validates pod-to-ClusterIP connectivity
- Automatically remediates network issues
- Collects diagnostics on failures

### Phase 3: Prerequisites
- Creates namespaces
- Sets up prerequisites

### Phase 4: Storage
- Creates PersistentVolumes
- Configures storage classes

### Phase 5: PostgreSQL
- Deploys PostgreSQL StatefulSet
- Waits for readiness

### Phase 6: Keycloak
- Deploys Keycloak via Helm
- Configures NodePort service
- Waits for readiness

### Phase 7: FreeIPA
- Deploys FreeIPA StatefulSet
- Configures networking (optional hostNetwork)
- Opens firewall ports (if needed)

### Phase 8: Keycloak SSO Configuration (Automated)
- **NEW**: 100% API-driven, no manual UI steps
- Imports realm from JSON
- Configures FreeIPA LDAP federation
- Exports OIDC client secrets to Kubernetes

### Phase 9: cert-manager
- Installs cert-manager
- Creates ClusterIssuer

### Phase 10: Admin Account Bootstrap
- Creates cluster admin user
- Saves credentials

### Phase 11: CA Certificate Setup
- Requests intermediate CA from FreeIPA
- Configures cert-manager

### Phase 12: Node Enrollment (Optional)
- Enrolls cluster nodes to FreeIPA
- Configures LDAP client on nodes

### Phase 13: Final Verification
- Verifies all components
- Checks connectivity
- Validates configuration

## Access Information

### After Deployment

**Keycloak Admin Console:**
```bash
# Get master node IP
kubectl get nodes -o wide

# Access Keycloak
URL: http://<node-ip>:30180/auth
Username: admin
Password: <KEYCLOAK_ADMIN_PASSWORD>
```

**FreeIPA:**
```bash
URL: https://ipa.vmstation.local
Username: admin
Password: <FREEIPA_ADMIN_PASSWORD>
```

**Credentials Location:**
```
/root/identity-backup/cluster-admin-credentials.txt
/root/identity-backup/keycloak-admin-credentials.txt
/root/identity-backup/freeipa-admin-credentials.txt
```

## Troubleshooting

### Network Validation Fails

If pod-to-ClusterIP validation fails after remediation:

1. **Check diagnostics:**
   ```bash
   ls -lh /root/identity-backup/network-diagnostics-*.tar.gz
   tar -tzf /root/identity-backup/network-diagnostics-<latest>.tar.gz
   ```

2. **Review cluster diagnostics:**
   ```bash
   cat /tmp/network-diagnostics/cluster-diagnostics-*.txt
   ```

3. **Review node diagnostics:**
   ```bash
   cat /tmp/network-diagnostics/node-*-*.txt
   ```

4. **Common issues:**
   - CNI plugin not functioning properly
   - NetworkPolicy blocking traffic
   - Custom firewall rules interfering
   - Node-to-node connectivity issues

### Manual Network Validation

```bash
# Test from ephemeral pod
kubectl run dns-test --image=nicolaka/netshoot --rm -it -- \
  dig @10.96.0.10 kubernetes.default.svc.cluster.local

# Check kube-proxy mode
kubectl -n kube-system get cm kube-proxy -o yaml | grep mode:

# Check kube-proxy logs
kubectl -n kube-system logs daemonset/kube-proxy --tail=100

# Check node ip_forward
ansible all -m shell -a "sysctl net.ipv4.ip_forward"

# Check iptables FORWARD policy
ansible all -m shell -a "iptables -L FORWARD -n | head -1"
```

### Keycloak Realm Import Issues

The realm import is fully automated. If it fails:

1. **Check Keycloak logs:**
   ```bash
   kubectl -n identity logs statefulset/keycloak --tail=200
   ```

2. **Verify Keycloak is ready:**
   ```bash
   kubectl -n identity get pods -l app.kubernetes.io/name=keycloak
   ```

3. **Check FreeIPA LDAP connectivity:**
   ```bash
   kubectl -n identity exec -it keycloak-0 -- \
     nc -zv freeipa.identity.svc.cluster.local 389
   ```

4. **Re-run SSO configuration:**
   ```bash
   cd /opt/vmstation-org/cluster-infra/ansible
   ansible-playbook playbooks/identity-deploy-and-handover.yml \
     --tags sso \
     -e keycloak_configure_sso=true
   ```

### Deployment Logs

All deployment logs are saved to:
```
/opt/vmstation-org/copilot-identity-fixing-automate/identity-full-deploy-<timestamp>.log
```

Review logs for detailed error messages and troubleshooting information.

## Configuration Customization

### Network Remediation Settings

Edit `ansible/roles/network-remediation/defaults/main.yml`:

```yaml
# Disable auto-remediation (validation only)
remediation_enabled: false

# Increase retry attempts
remediation_max_attempts: 5

# Disable diagnostics collection
diagnostics_enabled: false

# Use different validation image
dns_validation_pod_image: "busybox:1.36"
```

### Keycloak Realm Customization

Edit realm template: `ansible/roles/identity-sso/templates/cluster-realm.json.j2`

Or provide custom variables:
```bash
ansible-playbook playbooks/identity-deploy-and-handover.yml \
  -e keycloak_realm=my-realm \
  -e keycloak_base_path=/auth
```

## Ansible Tags

Run specific phases only using tags:

```bash
# Network validation only
ansible-playbook playbooks/identity-deploy-and-handover.yml --tags network

# SSO configuration only
ansible-playbook playbooks/identity-deploy-and-handover.yml --tags sso

# Skip network validation
ansible-playbook playbooks/identity-deploy-and-handover.yml --skip-tags network

# Multiple phases
ansible-playbook playbooks/identity-deploy-and-handover.yml --tags "postgresql,keycloak,sso"
```

Available tags:
- `prerequisites`
- `network` (network-remediation)
- `dns`, `coredns`, `kube-proxy` (aliases for network)
- `storage`
- `postgresql`, `database`
- `keycloak`
- `freeipa`
- `sso`
- `certmanager`, `ca`
- `admin`, `credentials`

## Advanced Usage

### Reset and Redeploy

```bash
cd /opt/vmstation-org/cluster-infra/ansible
sudo FORCE_RESET=1 RESET_CONFIRM=yes ../scripts/identity-full-deploy.sh
```

### Deploy Only (No Reset)

```bash
cd /opt/vmstation-org/cluster-infra/ansible
sudo ../scripts/identity-full-deploy.sh
```

### Dry-Run Mode

```bash
cd /opt/vmstation-org/cluster-infra/ansible
sudo DRY_RUN=1 ../scripts/identity-full-deploy.sh
```

### Skip Node Enrollment

```bash
cd /opt/vmstation-org/cluster-infra/ansible
sudo SKIP_NODE_ENROLLMENT=1 ../scripts/identity-full-deploy.sh
```

## Best Practices

1. **Use Strong Passwords**: Replace `secret123` with strong passwords in production
2. **Secure Credentials**: Store passwords in Ansible Vault or environment
3. **Review Diagnostics**: Always check diagnostics after failures
4. **Test Changes**: Use dry-run mode before production deployments
5. **Backup Regularly**: The reset script creates backups automatically
6. **Monitor Logs**: Check deployment logs for warnings and errors

## See Also

- [Network Remediation Role README](../ansible/roles/network-remediation/README.md)
- [Identity SSO Setup](IDENTITY-SSO-SETUP.md)
- [Keycloak Integration](KEYCLOAK-INTEGRATION.md)
- [Identity Deploy Scripts](../scripts/IDENTITY-DEPLOY-SCRIPTS.md)
- [FreeIPA Networking Notes](NOTE_FREEIPA_NETWORKING.md)
