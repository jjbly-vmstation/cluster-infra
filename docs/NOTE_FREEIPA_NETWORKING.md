# FreeIPA Network Configuration for Node Enrollment

## Overview

When deploying the identity stack in cluster-infra, FreeIPA is deployed as a Kubernetes StatefulSet with a ClusterIP service. By default, this makes FreeIPA accessible only within the cluster network via pod IPs and ClusterIP addresses. However, during node enrollment (when running `ipa-client-install` on cluster hosts), the nodes need to access FreeIPA using stable, routable IP addresses.

This document describes the automated solution implemented to ensure FreeIPA is reachable from cluster nodes during the enrollment process.

## The Problem

The `identity-full-deploy.sh` orchestrator runs `ipa-client-install` on cluster hosts as part of the node enrollment phase. This command needs to:

1. Resolve the FreeIPA server hostname (e.g., `ipa.vmstation.local`)
2. Connect to FreeIPA on multiple ports:
   - **TCP**: 80 (HTTP), 443 (HTTPS), 389 (LDAP), 636 (LDAPS), 88 (Kerberos), 464 (kpasswd)
   - **UDP**: 88 (Kerberos), 464 (kpasswd)

When FreeIPA runs with the default ClusterIP service, it's only accessible on pod IPs within the cluster network. External hosts (including the cluster nodes themselves when running `ipa-client-install` in the host context) cannot reach FreeIPA, causing enrollment to fail.

## The Solution: hostNetwork

The automated solution patches the FreeIPA StatefulSet to enable `hostNetwork: true`. This configuration change:

1. **Makes FreeIPA bind to the node's network interface** instead of a virtual pod network interface
2. **Exposes FreeIPA on the node's IP address** (the control-plane/infra node where FreeIPA is scheduled)
3. **Enables direct connectivity** from other cluster nodes and the Ansible controller

### How It Works

The playbook `identity-deploy-and-handover.yml` includes automated tasks that run after FreeIPA deployment:

1. **Backup**: Creates a backup of the current FreeIPA StatefulSet YAML to `/tmp/freeipa-backups/`
2. **Patch**: Applies a JSON patch to add `hostNetwork: true` to the StatefulSet spec (idempotent)
3. **Restart**: Rolls out a restart of the FreeIPA StatefulSet to apply the change
4. **Wait**: Waits for the FreeIPA pod to become ready (default timeout: 600s)
5. **Verify**: Tests connectivity from the Ansible controller to the node IP on all required ports
6. **Firewall** (optional): If connectivity fails and `identity_open_firewall=true`, attempts to open firewall ports on the infra node
7. **Fail-fast**: If connectivity still fails, provides clear troubleshooting instructions

## Security Implications

### ⚠️ Important Security Considerations

Enabling `hostNetwork: true` has security implications:

1. **Network Isolation**: The FreeIPA pod shares the host's network namespace, bypassing Kubernetes network policies
2. **Port Conflicts**: FreeIPA ports (80, 443, 389, 636, 88, 464) are bound directly to the node, potentially conflicting with other services
3. **Attack Surface**: Services on the host network are more exposed than those behind a pod network
4. **Firewall Requirements**: Host firewall rules may need adjustment to allow/block traffic appropriately

### Mitigations

- **Node Selector**: FreeIPA is scheduled only on the control-plane/infra node via `nodeSelector` and tolerations
- **Single Instance**: FreeIPA runs as a single replica, minimizing the scope
- **Optional Firewall**: The playbook can automatically configure firewall rules via `identity_open_firewall`
- **Privilege**: FreeIPA already runs privileged (required for systemd), so hostNetwork doesn't add new privilege concerns

### Alternatives Considered

1. **NodePort Service** (already present): Exposes FreeIPA on high ports (30088, 30445, etc.), but `ipa-client-install` expects standard ports
2. **socat/port-forward**: Manual workaround requiring additional processes and complexity
3. **External IPs**: Requires pre-configured external IPs, not suitable for automated deployment
4. **LoadBalancer**: Requires external load balancer support (not available in on-prem environments)

**Conclusion**: `hostNetwork: true` is the most reliable and automated solution for this use case.

## Variables

The following Ansible variables control the behavior:

| Variable | Default | Description |
|----------|---------|-------------|
| `identity_open_firewall` | `false` | Enable automatic firewall rule creation if connectivity fails |
| `freeipa_ready_timeout` | `600s` | Timeout for waiting for FreeIPA pod to be ready after restart |

### Using the Variables

To enable automatic firewall configuration:

```bash
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml \
  -e identity_open_firewall=true
```

To adjust the pod readiness timeout:

```bash
ansible-playbook ansible/playbooks/identity-deploy-and-handover.yml \
  -e freeipa_ready_timeout=900s
```

## Firewall Automation

When `identity_open_firewall=true` and connectivity verification fails, the playbook will attempt to open the required ports on the infra node:

### Supported Firewall Tools

1. **firewalld** (RHEL, AlmaLinux, CentOS, Rocky)
   ```bash
   firewall-cmd --permanent --add-port={80,443,389,636,88,464}/tcp
   firewall-cmd --permanent --add-port={88,464}/udp
   firewall-cmd --reload
   ```

2. **ufw** (Debian, Ubuntu)
   ```bash
   ufw allow 80,443,389,636,88,464/tcp
   ufw allow 88,464/udp
   ```

3. **iptables** (fallback)
   - Creates direct iptables rules as a last resort
   - Rules are saved to `/etc/sysconfig/iptables` (RHEL) or `/etc/iptables/rules.v4` (Debian)

### Idempotency

All firewall tasks are idempotent and safe to run multiple times. Existing rules are not duplicated.

## Rollback Instructions

If you need to revert the hostNetwork configuration:

### Option 1: Restore from Backup

```bash
# List available backups
ls -lh /tmp/freeipa-backups/

# Restore from backup
kubectl apply -f /tmp/freeipa-backups/freeipa-sts-backup-<timestamp>.yaml

# Wait for rollout
kubectl rollout status statefulset freeipa -n identity
```

### Option 2: Manual Patch

```bash
# Remove hostNetwork
kubectl patch statefulset freeipa -n identity \
  --type=json -p='[{"op":"remove","path":"/spec/template/spec/hostNetwork"}]'

# Restart
kubectl rollout restart statefulset freeipa -n identity

# Wait for rollout
kubectl rollout status statefulset freeipa -n identity
```

### Option 3: Redeploy

```bash
# Delete and redeploy FreeIPA
kubectl delete statefulset freeipa -n identity
kubectl apply -f manifests/identity/freeipa.yaml
```

**Note**: After rollback, node enrollment will require manual workarounds (port forwarding or socat).

## Manual Fallback: Using socat

If you prefer not to use hostNetwork or firewall automation, you can manually forward ports using socat:

### Setup socat Port Forwarding

On the infra node, for each required port:

```bash
# Install socat
sudo apt-get install socat  # Debian/Ubuntu
sudo yum install socat      # RHEL/CentOS

# Get FreeIPA pod IP
FREEIPA_POD_IP=$(kubectl get pod freeipa-0 -n identity -o jsonpath='{.status.podIP}')

# Forward ports (run in background or use systemd units)
socat TCP-LISTEN:389,fork TCP:${FREEIPA_POD_IP}:389 &
socat TCP-LISTEN:636,fork TCP:${FREEIPA_POD_IP}:636 &
socat TCP-LISTEN:88,fork TCP:${FREEIPA_POD_IP}:88 &
socat TCP-LISTEN:464,fork TCP:${FREEIPA_POD_IP}:464 &
socat TCP-LISTEN:80,fork TCP:${FREEIPA_POD_IP}:80 &
socat TCP-LISTEN:443,fork TCP:${FREEIPA_POD_IP}:443 &

# For UDP ports
socat UDP-LISTEN:88,fork UDP:${FREEIPA_POD_IP}:88 &
socat UDP-LISTEN:464,fork UDP:${FREEIPA_POD_IP}:464 &
```

### Systemd Units for socat (Optional)

Create systemd service files for persistent port forwarding:

```bash
sudo tee /etc/systemd/system/freeipa-port-forward@.service <<EOF
[Unit]
Description=FreeIPA Port Forward for %i
After=network.target

[Service]
Type=simple
Environment="FREEIPA_POD_IP=$(kubectl get pod freeipa-0 -n identity -o jsonpath='{.status.podIP}')"
ExecStart=/usr/bin/socat TCP-LISTEN:%i,fork TCP:\${FREEIPA_POD_IP}:%i
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Enable and start
sudo systemctl enable --now freeipa-port-forward@389.service
sudo systemctl enable --now freeipa-port-forward@636.service
# ... repeat for other ports
```

**Drawback**: socat requires manual setup, is fragile (pod IP can change), and doesn't survive pod restarts without automation.

## Troubleshooting

### Connectivity Test Failed

If the automated connectivity test fails:

1. **Check FreeIPA pod status**:
   ```bash
   kubectl get pod freeipa-0 -n identity
   kubectl logs freeipa-0 -n identity
   ```

2. **Verify hostNetwork is enabled**:
   ```bash
   kubectl get statefulset freeipa -n identity -o jsonpath='{.spec.template.spec.hostNetwork}'
   # Should return: true
   ```

3. **Check node IP and pod IP**:
   ```bash
   kubectl get pod freeipa-0 -n identity -o wide
   ```

4. **Test connectivity manually from controller**:
   ```bash
   nc -vz <node-ip> 389
   nc -vz <node-ip> 636
   nc -vz <node-ip> 88
   ```

5. **Check firewall on infra node**:
   ```bash
   # On RHEL/Alma/CentOS
   sudo firewall-cmd --list-ports
   
   # On Debian/Ubuntu
   sudo ufw status
   
   # General
   sudo iptables -L -n | grep -E '(389|636|88|464)'
   ```

6. **Check SELinux (RHEL/Alma/CentOS)**:
   ```bash
   sudo getenforce
   sudo ausearch -m avc -ts recent | grep -E '(389|636|88|464)'
   ```

### Node Enrollment Still Fails

If `ipa-client-install` fails on nodes even after hostNetwork is enabled:

1. **Verify DNS resolution**:
   ```bash
   # On the target node
   nslookup ipa.vmstation.local
   ```

2. **Check /etc/hosts on target node**:
   ```bash
   grep ipa.vmstation.local /etc/hosts
   # Should point to the infra node IP
   ```

3. **Test connectivity from target node**:
   ```bash
   # On the target node
   telnet <infra-node-ip> 389
   nc -vz <infra-node-ip> 636
   ```

4. **Review ipa-client-install logs**:
   ```bash
   # On the target node
   sudo cat /var/log/ipaclient-install.log
   ```

### FreeIPA Pod Won't Start After Restart

If FreeIPA pod fails to start after applying hostNetwork:

1. **Check for port conflicts**:
   ```bash
   # On the infra node
   sudo netstat -tulpn | grep -E ':(80|443|389|636|88|464)'
   ```

2. **Review pod events**:
   ```bash
   kubectl describe pod freeipa-0 -n identity
   ```

3. **Check pod logs**:
   ```bash
   kubectl logs freeipa-0 -n identity
   ```

4. **Rollback if necessary** (see Rollback Instructions above)

## Summary

The hostNetwork automation ensures FreeIPA is accessible from cluster nodes during enrollment, making the identity deployment fully automated and resilient. The solution:

- ✅ Is fully automated (no manual intervention required)
- ✅ Is idempotent (safe to run multiple times)
- ✅ Includes safety checks and clear error messages
- ✅ Supports optional firewall automation
- ✅ Provides rollback and manual fallback options
- ✅ Includes comprehensive documentation

For questions or issues, refer to the cluster-infra repository documentation or raise an issue.
