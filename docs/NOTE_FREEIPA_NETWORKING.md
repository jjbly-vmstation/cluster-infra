# FreeIPA Networking Configuration: hostNetwork for Node Enrollment

## Overview

This document describes the automated FreeIPA networking configuration that enables cluster nodes to successfully enroll with FreeIPA during identity deployment.

## Problem Statement

When deploying FreeIPA as part of the identity stack, the default configuration uses a ClusterIP service. While this works for in-cluster pod-to-pod communication, it prevents cluster nodes from reaching FreeIPA directly on their host network. This causes `ipa-client-install` to fail during the node enrollment phase because:

1. FreeIPA is only accessible via the Kubernetes ClusterIP (typically 10.x.x.x)
2. Cluster nodes do not have routes to the pod network from their host network
3. Node enrollment requires direct connectivity to FreeIPA on multiple ports

## Solution: hostNetwork Configuration

The identity deployment now automatically configures FreeIPA to use `hostNetwork: true`, which makes FreeIPA listen directly on the node's IP address where it's scheduled (typically the control-plane/infra node).

### What Gets Automated

The `ansible/playbooks/tasks/ensure-freeipa-hostnetwork.yml` task automatically:

1. **Backs up** the current FreeIPA StatefulSet configuration to `/tmp/freeipa-statefulset-backup-<timestamp>.yaml`
2. **Patches** the FreeIPA StatefulSet to add `hostNetwork: true` (idempotent)
3. **Restarts** the FreeIPA StatefulSet to apply the change
4. **Waits** for the FreeIPA pod to become ready (up to 10 minutes)
5. **Verifies** connectivity to FreeIPA on all required ports:
   - TCP: 80 (HTTP), 443 (HTTPS), 389 (LDAP), 636 (LDAPS), 88 (Kerberos), 464 (kpasswd)
   - UDP: 88 (Kerberos), 464 (kpasswd)

### When It Runs

This automation runs automatically during the identity deployment workflow:
- **After** FreeIPA StatefulSet is created
- **Before** cluster node enrollment begins

It is integrated into the `identity-deploy-and-handover.yml` playbook and executes as part of `identity-full-deploy.sh`.

## Security Implications

### What hostNetwork Does

Setting `hostNetwork: true` on a pod causes it to:
- Use the host's network namespace directly
- Listen on the host's IP address and network interfaces
- Bypass Kubernetes network policies and service abstractions
- Share network resources with the host

### Security Considerations

1. **Port Conflicts**: FreeIPA will bind to ports 80, 443, 389, 636, 88, 464 on the host. Ensure no other services are using these ports on the control-plane node.

2. **Network Isolation**: With hostNetwork, FreeIPA bypasses pod network isolation. This is acceptable for identity services that need to be cluster-wide accessible.

3. **Firewall Requirements**: The host firewall may block incoming connections even with hostNetwork enabled. See the Firewall Automation section below.

4. **Node Affinity**: FreeIPA is constrained to run on control-plane nodes via nodeSelector and tolerations, limiting its exposure to the infrastructure node.

5. **Privileged Container**: FreeIPA already runs as a privileged container (required for systemd). Adding hostNetwork does not increase this privilege level significantly.

### Best Practices

- **Limit to infra/control-plane nodes**: FreeIPA should only run on trusted infrastructure nodes
- **Regular updates**: Keep FreeIPA container images up to date
- **Strong passwords**: Use strong, randomly generated passwords for FreeIPA admin accounts
- **Firewall configuration**: Keep host firewall enabled and only open required ports

## Firewall Automation (Optional)

### Default Behavior

By default, firewall automation is **disabled** (`identity_open_firewall: false`). The playbook will verify FreeIPA connectivity and fail with instructions if ports are blocked.

### Enabling Firewall Automation

To automatically open firewall ports when connectivity fails:

**Option 1: Environment Variable**
```bash
sudo IDENTITY_OPEN_FIREWALL=1 ./scripts/identity-full-deploy.sh
```

**Option 2: Ansible Extra Vars**
```bash
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml -e identity_open_firewall=true
```

### What Firewall Automation Does

When enabled, the `ansible/playbooks/tasks/ensure-freeipa-firewall.yml` task will:

1. **Detect the OS family** (RHEL-like or Debian-like)
2. **Check for existing rules** (idempotent - won't duplicate rules)
3. **Apply appropriate firewall commands**:
   - **RHEL/Rocky/AlmaLinux**: Uses `firewalld` commands
   - **Debian/Ubuntu**: Uses `iptables` commands
4. **Persist the rules** so they survive reboots

### Manual Firewall Configuration

If you prefer to configure the firewall manually:

**For RHEL/Rocky/AlmaLinux with firewalld:**
```bash
firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --permanent --add-port=389/tcp
firewall-cmd --permanent --add-port=636/tcp
firewall-cmd --permanent --add-port=88/tcp
firewall-cmd --permanent --add-port=464/tcp
firewall-cmd --permanent --add-port=88/udp
firewall-cmd --permanent --add-port=464/udp
firewall-cmd --reload
```

**For Debian/Ubuntu with iptables:**
```bash
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p tcp --dport 389 -j ACCEPT
iptables -A INPUT -p tcp --dport 636 -j ACCEPT
iptables -A INPUT -p tcp --dport 88 -j ACCEPT
iptables -A INPUT -p tcp --dport 464 -j ACCEPT
iptables -A INPUT -p udp --dport 88 -j ACCEPT
iptables -A INPUT -p udp --dport 464 -j ACCEPT

# Save rules
apt-get install -y iptables-persistent
netfilter-persistent save
```

## Rollback Instructions

If you need to revert FreeIPA to ClusterIP-only mode:

### Step 1: Restore from Backup (Optional)

If you have the backup YAML file:
```bash
kubectl apply -f /tmp/freeipa-statefulset-backup-<timestamp>.yaml
```

### Step 2: Remove hostNetwork Manually

```bash
# Remove the hostNetwork field
kubectl -n identity patch statefulset freeipa --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/hostNetwork"}]'

# Restart the StatefulSet
kubectl -n identity rollout restart statefulset freeipa

# Wait for pod to be ready
kubectl -n identity wait --for=condition=ready pod -l app=freeipa --timeout=600s
```

### Step 3: Verify ClusterIP Access

```bash
# Check that FreeIPA is accessible via ClusterIP
kubectl -n identity get svc freeipa
kubectl -n identity get pods -l app=freeipa

# Test connectivity from within the cluster
kubectl run -it --rm debug --image=busybox --restart=Never -- wget -O- http://freeipa.identity.svc.cluster.local
```

### Step 4: Alternative - Use Socat Proxy

Instead of hostNetwork, you can use a socat proxy on each node:

```bash
# Install socat on each node
apt-get install -y socat  # Debian/Ubuntu
yum install -y socat       # RHEL/Rocky/AlmaLinux

# Get FreeIPA ClusterIP
FREEIPA_IP=$(kubectl -n identity get svc freeipa -o jsonpath='{.spec.clusterIP}')

# Create systemd service for socat proxy (example for port 389)
cat > /etc/systemd/system/freeipa-ldap-proxy.service <<EOF
[Unit]
Description=FreeIPA LDAP Proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:389,fork,reuseaddr TCP:${FREEIPA_IP}:389
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now freeipa-ldap-proxy.service
```

**Note**: You would need separate socat proxies for each required port (80, 443, 389, 636, 88, 464 for both TCP and UDP).

## Troubleshooting

### FreeIPA Pod Not Starting After hostNetwork

**Symptom**: Pod fails to start with port binding errors

**Cause**: Another service is using the same ports on the host

**Solution**:
1. Check what's using the ports: `netstat -tulpn | grep -E ':(80|443|389|636|88|464)'`
2. Stop conflicting services or change their ports
3. Restart FreeIPA: `kubectl -n identity rollout restart statefulset freeipa`

### Connectivity Still Fails After hostNetwork

**Symptom**: Playbook reports FreeIPA is not reachable

**Cause**: Host firewall is blocking ports

**Solution**:
1. Enable firewall automation: `IDENTITY_OPEN_FIREWALL=1`
2. Or manually configure firewall (see Manual Firewall Configuration above)
3. Verify with: `nc -zv <node-ip> 389`

### Node Enrollment Fails with DNS Errors

**Symptom**: `ipa-client-install` reports DNS resolution failures

**Cause**: DNS not configured for FreeIPA

**Solution**:
1. Ensure DNS records point to FreeIPA node IP
2. Or use the `--server` and `--domain` flags with ipa-client-install
3. See `scripts/enroll-nodes-freeipa.sh` for proper configuration

### Want to Use NodePort Instead

**Symptom**: You prefer NodePort over hostNetwork

**Note**: NodePort services in Kubernetes use high port numbers (30000+) by default. FreeIPA protocols require standard ports (389, 636, 88, etc.) which NodePort cannot provide without additional configuration.

**Alternative**: Keep hostNetwork for FreeIPA as it's the most straightforward solution for identity services.

## Integration with Deployment Workflow

The hostNetwork configuration is fully integrated into the identity deployment:

```
identity-full-deploy.sh
  └── ansible-playbook identity-deploy-and-handover.yml
      ├── Deploy FreeIPA (Phase 6)
      ├── Ensure hostNetwork (Phase 6a) ← NEW
      ├── Configure firewall if needed (Phase 6b) ← NEW (optional)
      └── Continue with cert-manager, admin creation, etc.
```

Node enrollment script (`enroll-nodes-freeipa.sh`) expects FreeIPA to be reachable on the node IP and will succeed automatically after this configuration is applied.

## References

- FreeIPA Manifest: `manifests/identity/freeipa.yaml`
- hostNetwork Task: `ansible/playbooks/tasks/ensure-freeipa-hostnetwork.yml`
- Firewall Task: `ansible/playbooks/tasks/ensure-freeipa-firewall.yml`
- Deployment Playbook: `ansible/playbooks/identity-deploy-and-handover.yml`
- Orchestrator Script: `scripts/identity-full-deploy.sh`
- Node Enrollment: `scripts/enroll-nodes-freeipa.sh`

## Summary

The automated hostNetwork configuration ensures FreeIPA is reachable from cluster nodes during enrollment, eliminating manual intervention and making the identity deployment fully automated. The optional firewall automation further streamlines the process while maintaining security best practices through opt-in behavior.
